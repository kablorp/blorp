# Make Fixed-Arity Ownership Normalization Change-Aware

**Status:** Implemented 2026-09-08

**Roadmap:** Perceus ownership optimization, post-Tranche-4 transition

**Dependencies:** The change-aware leaf/shell, managed-let, call, and aggregate
checkpoints recorded in `PERCEUS_OWNERSHIP_OPTIMIZATION_ROADMAP.md`

## Objective

Let Perceus retain the exact source root for a proven ownership-neutral subset
of `UnboxExpr`, `BinaryExpr`, `FieldExpr`, and `TupleFieldExpr` nodes. Preserve
the established ownership normalization for sensitive or unproved forms and
reconstruct a root whenever normalization or recursive insertion changes any
child.

This is the last automatically admitted change-aware insertion checkpoint.
After it lands, reprofile compiler self-compilation before beginning Tranche 5
or adding match-specific identity machinery.

## Why This Issue Exists

`insert_drops_non_binding_expr` currently treats these four roots as opaque:

```blorp
UnboxExpr(_, _, _, _) | BinaryExpr(_, _, _, _, _) |
FieldExpr(_, _, _, _) | TupleFieldExpr(_, _, _, _):
	opaque_inserted_non_binding_expr(
		env,
		insert_drops_ownership_node(env, expr),
	)
```

`insert_drops_ownership_node` first normalizes ownership and then recursively
rebuilds the normalized expression. Even when both operations are exact
identities, the caller reports `reuses_source = False`. That forces unchanged
ancestors—including the managed lets, calls, and aggregates already made
change-aware—to rebuild.

These roots are a coherent final slice because each has a fixed number of
children. They do not require list patching, binder scopes, branch joins, or
fallback variants.

## Existing Semantic Obligations

The implementation must preserve these existing authorities rather than
reimplementing their rules from syntax guesses.

### Unbox

`bind_borrowed_owned_temporary_args_through_unbox` protects an unbox of a call
or casted call when the unbox copies an alias and the call result may alias an
argument. Contract lookup, borrowed-view variables, binding order, and
explicit-drop behavior remain authoritative.

### Binary

`protect_consuming_field_aliases` protects managed direct-field operands for a
consuming collection equality. Then
`bind_borrowed_owned_temporary_binary_operands` materializes owned temporaries
for borrowed operands. Left-to-right operand evaluation and synthetic-binding
order must remain exact.

### Field and tuple-field projections

`bind_owned_temporary_field_projection` preserves a temporary owner long enough
to copy or retain the projection. A variable-rooted or otherwise borrowed
projection may be neutral; a call-rooted projection may require a synthetic
owner binding, retain, and drop. Nested projection chains must retain their
current ownership order.

## Required Design

Do not add a second set of predicates that merely predicts what the existing
normalizers will do. Make the normalization operation itself report exact
source identity with a private typed result:

```blorp
private union PerceusOwnershipNormalization:
	UnchangedPerceusOwnershipNormalization
	ChangedPerceusOwnershipNormalization(CoreExpr)
```

Equivalent naming is acceptable, but the unchanged variant must be fieldless.
The changed variant carries the normalized replacement. Do not compare trees
structurally and do not carry the source expression inside the unchanged
variant.

Introduce narrow normalizers for the three proof surfaces:

```blorp
private pure func normalize_unbox_ownership_change_aware(
	env: PerceusEnv,
	source: CoreExpr,
) -> PerceusOwnershipNormalization

private pure func normalize_binary_ownership_change_aware(
	env: PerceusEnv,
	source: CoreExpr,
) -> PerceusOwnershipNormalization

private pure func normalize_projection_ownership_change_aware(
	env: PerceusEnv,
	source: CoreExpr,
) -> PerceusOwnershipNormalization
```

They should reuse or refactor the existing preparation/materialization helpers
so one function constructs the ownership rewrite and decides whether it
changed the source. Do not maintain parallel implementations of contract,
alias, or temporary-materialization logic.

`UnchangedPerceusOwnershipNormalization` is a conservative proof result, not a
requirement to recognize every semantic no-op. An uncertain form must run the
existing normalizer and return `ChangedPerceusOwnershipNormalization`, even
when that path happens to serialize identically today. At minimum, the proof
must cover:

- an unbox whose input is not an alias-returning direct call or casted direct
  call requiring argument protection;
- a binary operation with unmanaged variable or literal operands and no
  consuming direct-field alias protection;
- field and tuple-field projections rooted directly in a borrowed local; and
- field and tuple-field projections whose owner is a direct call with an
  explicit borrowed or argument-alias result contract. Unknown and owned call
  results remain conservative.

The unchanged branch must not first construct and then discard a replacement
root, rewritten operand list, or synthetic-binding list. Put the proof and the
changed construction in the same normalizer, with the construction reachable
only from the changed branch. A structural equality check after construction
does not satisfy this issue's allocation objective.

For an unchanged normalization:

1. recursively call `insert_drops_expr_inner_result` on the fixed children;
2. retain the source root only when every child reports `reuses_source`;
3. otherwise rebuild exactly that root from the rewritten children; and
4. pass the result through `inserted_non_binding_expr` so result ownership is
   classified exactly as today.

For a changed normalization, preserve the existing conservative route:

```blorp
opaque_inserted_non_binding_expr(
	env,
	insert_drops_normalized_expr(env, normalized),
)
```

This avoids claiming identity across a normalization that introduced
bindings or ownership actions.

Delete the old opaque cases only after all four roots use the new helper.
Keep `normalize_ownership_node` only for remaining real consumers; delete it
if this cutover leaves it unused.

## Explicit Non-Goals

- Do not make literal, accessor, length, or constructor matches change-aware.
- Do not introduce a universal Core rewrite result or visitor framework.
- Do not change call contracts, direct-field alias rules, ownership event
  order, synthetic names, or transfer behavior.
- Do not move match analysis forward from Tranches 5–6.
- Do not change public Core IR or serialize source-identity metadata.
- Do not claim a runtime or generated-C improvement; output must remain exact.

## TDD And Behavioral Matrix

Begin with failing benchmark-contract tests and a fixed compiler-bridge body
shape, for example `fixed_ownership_change_matrix`.

The closed behavioral matrix must contain, for each of the four roots:

1. an ownership-neutral root in the explicitly supported proof subset whose
   normalization is the exact source and whose children are unchanged;
2. a root whose child changes only through recursive insertion; and
3. an ownership-sensitive root that triggers the existing normalization.

For each projection family, make item 2 a projection over an explicitly
borrowed- or argument-alias-returning call whose call child is reconstructed
because one of its own children changes. Projection normalization must remain
neutral in that case. This exercises parent/child identity composition without
silently broadening the proof to an owned or unknown call result.

Required sensitive cases:

- unbox of an aliasing call result that needs borrowed-temporary protection;
- consuming collection equality with at least one managed direct-field alias;
- a managed call-rooted field projection; and
- a managed call-rooted tuple-field projection.

The returned post-Perceus Core must be inspected. Assert per root family that:

- the neutral form remains direct;
- the recursive-child form contains the expected rewritten child;
- the sensitive form contains the established ownership wrapper; and
- the sensitive ownership-event order matches the parent compiler.

Add debug-only counters that partition every visit:

```text
insert_fixed_ownership_visits
insert_fixed_ownership_original_nodes_reused
insert_fixed_ownership_reconstructions
insert_fixed_ownership_normalization_rewrites
```

Require:

```text
original_nodes_reused + reconstructions == visits
normalization_rewrites <= reconstructions
```

The matrix must assert exact expected values, not merely nonzero counts. Repeat
the counter run and reject nondeterministic results.

Keep performance density separate from behavioral coverage. Add a scaled
workload that repeats ownership-neutral instances until at least 90% of its
eligible fixed-arity roots are expected to be reusable. Use this workload for
allocation and timing claims; do not distort the closed matrix merely to make
its aggregate percentage look favorable.

## Fast Feedback Loop

Keep iteration inside the narrowest available boundaries:

```bash
bin/blorp check --no-format blorp/src/compiler/stage_09_core/perceus.brp
python3 -m unittest blorp.test.compiler.benchmark.test_perceus_memory
bin/blorp test blorp/test/compiler/stage_09_core/test_core_perceus.brp
```

Use an already-built direct-parent timing worker and a separately built
debug-counter worker. Run the fixed matrix with one sample while developing.
Do not rebuild or compile the entire compiler for each edit.

Once the implementation and exact counters are stable:

1. run seven alternating parent/candidate samples of the scaled neutral-density
   workload and one deterministic counter sample of the closed matrix;
2. run the existing aggregate-escape and managed-let-transfer fixtures as
   composition controls;
3. run the default direct-Perceus fixture;
4. compile `blorp/src/main.brp` through Perceus once with each compiler and
   compare the snapshots byte-for-byte; and
5. only then run the changed compiler gate and sanitizer.

## Measurement And Landing Criteria

Record timing-worker and counter-worker hashes separately. The timing workers
must have debug counters erased. Compare against the committed aggregate
checkpoint, not an older Tranche baseline.

The change may land only when:

- every matrix visit has one exact reuse/reconstruction decision;
- every ownership-sensitive case reproduces the parent's ordered ownership
  events;
- candidate and parent post-Perceus Core are byte-identical for the fixed
  matrix, composition controls, default fixture, and compiler self-host;
- the scaled neutral-density workload reuses at least 90% of its eligible
  fixed-arity roots;
- measured-window allocations and releases decrease by at least 1% on that
  workload—the explicit ROI floor for retaining the additional production
  code;
- default and self-host measured allocations do not regress;
- across seven alternating samples, both measured-window and whole-worker
  candidate/parent median ratios are at most 1.05 and their MADs are reported;
- no fixed-arity root remains routed unconditionally through its old opaque
  case, and no redundant normalization authority remains; and
- focused Perceus, benchmark-contract, changed-source, and sanitizer checks
  pass.

If the focused allocation reduction misses the ROI floor, keep any genuine
simplification only when it deletes more production machinery than it adds;
otherwise revert the production change and retain the fixture as profiling
infrastructure.

## Required Handoff

Update the Perceus roadmap and add a dated result under `benchmarks/results/`.
The report must state whether matches or Tranche 5 are admitted by the new
self-host profile. Do not create a match-specific production issue without
that evidence.

## Implementation Result

Implemented with a fieldless `UnchangedPerceusOwnershipNormalization` result
and one changed payload variant. All four fixed roots now share a bounded
change-aware insertion helper; ownership-sensitive and uncertain forms retain
the prior normalization route.

The two-worker behavioral matrix reports exactly 32 visits, 16 source reuses,
16 reconstructions, and 8 normalization rewrites. The scaled neutral workload
reuses all 584 eligible roots and removes 3,360 direct-window allocations
(-8.42%) and releases (-8.85%). Parent and candidate Core are byte-identical
for the matrix, scaled workload, controls, and compiler self-compilation.

The post-change self-host sample makes the fixed helper negligible (10 of
50,115 inclusive samples at its hottest call path). It does not cleanly split
the remaining `insert_drops_ownership_node` time between match roots and
ownership-sensitive calls, and it identifies no material scalar-summary family
that would pay for Tranche 5. Consequently neither match identity work nor
Tranche 5 is admitted automatically.

See
[`compiler_perceus_change_aware_fixed_ownership_2026-09-08.md`](../../../benchmarks/results/compiler_perceus_change_aware_fixed_ownership_2026-09-08.md)
for commands, worker identities, measurements, controls, and the admission
decision.
