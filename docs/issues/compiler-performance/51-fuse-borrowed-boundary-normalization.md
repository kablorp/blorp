# Fuse Borrowed Boundary Normalization

**Status:** Proposed

**Roadmap:** Perceus ownership optimization, Tranche 4D

**Dependencies:** Issues 48–50

**Parallel work:** None. This issue replaces shared traversal authorities and
must be implemented after every ownership region uses the all-owner paths.

## Objective

Replace the independent all-owner call, aggregate-transfer, and result-position
reconstruction passes with one post-order borrowed-boundary normalizer per
ownership region.

The result must be simpler as well as faster: one traversal owns binder and
compiled-match descent, operation-specific boundary actions remain explicit,
and the superseded traversal/helper families are deleted.

## Why This Issue Exists

Issues 48–50 remove owner-multiplied work but intentionally leave three
owner-independent passes so each semantic family can be validated in isolation.
Those passes still reconstruct overlapping portions of the same body and
duplicate substantial binder, match, resource, and collection traversal code.

Fusion removes that fixed repeated work. It must not flatten distinct ownership
rules into a heuristic visitor. Call contracts, storage metadata, and result
position remain separate typed boundary modes even though one structural walk
applies them.

## Required Reading

Read Issues 48–50, their benchmark reports, and inspect every helper reachable
from:

- `protect_borrowed_calls`;
- `retain_borrowed_aggregate_transfers`;
- the all-owner result traversal introduced by Issue 48;
- `first_borrowed_owner_aliasing_expr`;
- compiled-match and lexical-shadow context helpers; and
- all incoming ownership-node compatibility fallbacks.

Create an inventory mapping every Core variant to the child boundary mode used
by each of the three passes. Review that inventory before implementation. A
generic `map_core_expr_children` fallback is allowed only for variants whose
three existing authorities all traverse identically.

## Required Design

### Orthogonal context

Boundary kind, lexical visibility, and result satisfaction are independent.
Represent them independently rather than as one overloaded boolean or an
exclusive union pretending to contain all traversal state:

```blorp
union BorrowedBoundary:
	OrdinaryBorrowedBoundary
	ConsumingCallArgumentBoundary(OwnershipArgMode, Int)
	OwnershipTransferringStorageBoundary
	FunctionResultBoundary

record BorrowedNormalizationContext {
	env: PerceusEnv,
	owners: BorrowedOwnerCatalog,
	shadowed_owner_ids: Dict[Int, Bool],
	result_satisfied_owner_ids: Dict[Int, Bool]
}
```

The exact names may differ. The design must be able to express:

- lexical shadowing disables an owner for every boundary family;
- an existing `DupExpr` satisfies only that owner's result obligation below
  the node;
- a call/aggregate retain can make an evaluated subtree owned without changing
  unrelated lexical identity; and
- match bindings affect only the regions where their definitions are live.

### Post-order action sequence

At each expression:

1. descend into each child under its explicit boundary mode;
2. rebuild the parent once;
3. apply consuming-call ownership to the relevant evaluated child;
4. apply ownership-transferring storage rules from prepared-Core metadata; and
5. apply result ownership at terminal result expressions.

This order must reproduce the effective call → aggregate → result behavior of
the immediate parent. Where an old pass inserted a wrapper that caused a later
pass to stop, model that ownership transition explicitly; do not depend on a
second traversal observing the rewritten syntax.

### Region boundaries

Run the normalizer once for each independently owned body:

- ordinary function body;
- lambda body; and
- dynamic global initializer.

Nested lambda bodies remain opaque to the outer region and are normalized by
their own invocation. Match and loop local-owner balancing remains outside this
normalizer until Tranches 5–6 unless an earlier issue explicitly moved it.

### Compatibility islands

Incoming `DupExpr`/`DropExpr` or unresolved identity may still require exact
scalar compatibility queries. They must be:

- selected by an explicit variant or condition;
- counted by boundary family;
- absent from ownership-ready benchmark fixtures; and
- prevented from reopening the entire region once per owner.

## Required Implementation Sequence

1. Add the complete boundary fixture and failing fused-visit assertion.
2. Add a fused traversal counter while preserving separate call, aggregate,
   result, candidate, fallback, and action counters.
3. Write and test the Core-variant child-mode inventory.
4. Implement the fused normalizer alongside the three-pass production path.
5. Compare complete ownership events for overlapping-boundary fixtures before
   cutover.
6. Cut over one region kind at a time: functions, global initializers, then
   lambdas.
7. Delete the three independent production walkers and merge/delete their
   duplicated binder, match, resource, and collection helpers.
8. Confirm no public or phase-crossing generic visitor API was introduced.
9. Reprofile and run the broad output-preserving gates once.

Do not begin Tranche 5 fact collection or alter emitted ownership operations in
this issue.

## Benchmark Contract

Add `borrowed_boundary_fusion` and `--borrowed-boundary-fusion-matrix` to the
existing Perceus benchmark.

Use a fixed ownership-ready body containing all three overlapping families:

```text
functions=2
body_nodes=512, exact
borrowed owners=32, fixed
referenced globals=8, fixed
consuming call sites=32, fixed
transferring storage sites=32, fixed
result terminals=32, fixed
match/resource/sequence/conditional carriers in fixed proportions
nested lambda regions=2, fixed
```

Add density points at 8, 32, and 96 sites per boundary family while holding
body nodes, owner count, and region count fixed by replacing inactive sites
with structurally equivalent non-boundary expressions. Density is the primary
axis; do not vary owner count in the same matrix.

Record:

```text
legacy call visits
legacy aggregate visits
legacy result visits
fused normalization visits
candidate/fallback queries by boundary kind
rewrite actions by boundary kind
reconstructed nodes
allocations and releases
post-Perceus artifact hash
```

The immediate parent for this issue is the completed three-pass Issue 50
implementation, not pre-Tranche-4 main.

## TDD And Fast Feedback

Add overlap regressions before implementation:

- a consuming call whose argument is a transferring aggregate;
- a transferring aggregate containing a consuming call;
- a returned aggregate containing parameter and global projections;
- a returned aliasing call with consuming arguments;
- conditionals selecting different owners in call, storage, and result modes;
- existing `DupExpr` and `DropExpr` wrappers at overlapping boundaries;
- match/resource binder shadowing of only one owner;
- prepared tuple masks, boxed `needs_release`, and list-set
  `transfers_ownership` in returned/consumed positions;
- nested lambda opacity; and
- incoming ownership-node compatibility paths.

During implementation:

```bash
bin/blorp check --no-format blorp/src/compiler/stage_09_core/perceus.brp
bin/blorp test blorp/test/compiler/stage_09_core/test_core_perceus.brp
python3 -m unittest blorp.test.compiler.benchmark.test_perceus_memory
```

Use counter assertions and immediate-parent artifact comparison as the primary
loop. Build timing/counter workers once after focused correctness passes. Do not
run full compiler compilation repeatedly; perform compiler self-compilation and
broad gates only after fusion satisfies its direct benchmark.

## Acceptance Criteria

- Exactly one borrowed-boundary reconstruction traversal runs per function,
  lambda, or dynamic-global-initializer ownership region.
- Nested lambdas are counted as separate regions and are not traversed through
  by the outer region normalizer.
- Fused visit count is independent of borrowed-owner and referenced-global
  catalog size for a fixed body.
- On every fusion-matrix point, fused visits are at least 50% lower than the
  immediate parent's sum of call, aggregate, and result visits. The fixture is
  deliberately constructed so all three old traversals materially overlap.
- At the 32-site density point, the direct-Perceus paired median is at least
  10% faster and direct-window allocations are at least 15% lower than the
  immediate parent. If fusion cannot expose those gains on the fixed
  overlapping fixture, stop rather than retaining a more complicated visitor.
- The lowest-density point does not regress time beyond paired noise and does
  not increase allocations or releases by more than 2%.
- Call, aggregate, and result action counters exactly equal the immediate
  parent. Scalar fallbacks remain zero on ownership-ready fixtures.
- Every Core variant in the reviewed child-mode inventory is handled explicitly
  or is covered by a proven identical-child-mapping category.
- Ownership-event ordering, post-Perceus Core, generated C, and runtime output
  are byte-identical to the immediate parent. There is no canonicalization
  exception in this output-preserving tranche.
- `protect_borrowed_calls`, `retain_borrowed_aggregate_transfers`, the Issue 48
  standalone result walker, and helpers used only by those traversals are
  deleted or consolidated. No second production traversal remains as a
  compatibility path.
- Final production source has less duplicated traversal code than Issue 50;
  code size is reported but is not a performance landing gate.
- Compiler self-compilation records direct Perceus time, allocations, peak RSS,
  event counts, post-Perceus hash, and generated-C hash against the immediate
  parent.
- Focused Perceus, Core sanitizer, compiler, runtime, leak, and codegen-audit
  gates pass.

## Expected Result

The final Tranche 4 architecture performs one explicit borrowed-boundary walk
per ownership region. The controlled overlapping fixture should show an
observable fixed-cost improvement even though owner-scaling has already been
removed, and the production code should lose the duplicated match/binder
traversal families accumulated during the safe incremental migration.
