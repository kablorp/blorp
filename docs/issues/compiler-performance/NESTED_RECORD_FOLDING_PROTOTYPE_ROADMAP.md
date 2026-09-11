# Nested Record Allocation Folding Prototype Roadmap

**Status:** Proposed prototype; admission-gated, not a production
representation commitment

**Primary owners:** `stage_09_core/tuple_sroa.brp`, the post-projection early
Core layout boundary, and `stage_10_backend/emit.brp`

**Current state:** Heap-record fields use independent managed objects. Existing
tuple SROA removes nonescaping local containers, but deliberately rejects a
child stored in another aggregate. Manual compiler refactors prove that
flattening can remove allocations; they do not prove a general optimization is
worth its analysis and ABI complexity. No current representation supports a
headerless embedded child that is materialized only when it needs an independent
owner.

**Next action:** Build the census-only analyzer and per-site dynamic profile in
Step 2, including separate counts for fused construction and later
materialization. Do not implement either layout strategy until a real compiler
workload passes the admission gate.

## Decision To Make

Determine whether a heap record stored in another heap record can share the
parent's allocation often enough to improve the self-hosted compiler without
weakening value semantics, COW behavior, cancellation cleanup, ownership, or
the uniform C ABI of named records.

The prototype must answer, in order:

1. Which direct child-to-parent construction edges are statically safe?
2. How often does each safe edge execute in representative compiler work?
3. How often would a folded child later cross a boundary requiring a standalone
   owned record?
4. Does the measured saving exceed analysis, materialization, copying, ARC, and
   code-size costs?

A synthetic win is insufficient. If production coverage is negligible, record
the result and stop.

## Motivation And Context

Every emitted heap-record constructor calls `blorp_alloc` for a C structure
beginning with the 16-byte `blorp_Object` header. A separately allocated child
also occupies a pointer in its parent. On a 64-bit target, folding one edge can
remove one allocation/release pair, one ARC interval, one pointer indirection,
and roughly 24 bytes of raw structural overhead before allocator metadata,
alignment, and padding.

Blorp has a close manual result. Flattening `CoreSourceSpan` into
`KnownSourceLoc` removed 20,300 allocations, 20,200 retained objects, and
646,400 retained bytes from a 10,200-location Core request. Median peak RSS and
elapsed time moved by 0.65% and 0.69%; only the allocation result was treated
as conclusive. See
[`compiler_compact_metadata_2026-08-04.md`](../../../benchmarks/results/compiler_compact_metadata_2026-08-04.md).

Another production replay removed 11,114 intermediate record allocations from
more than 306 million total allocations without establishing a timing win. See
[`compiler_infer_session_reconstruction_2026-08-26.md`](../../../benchmarks/results/compiler_infer_session_reconstruction_2026-08-26.md).
Occurrence rate, not source-level neatness, decides viability.

Related work has narrower contracts:

- [token and token-kind fusion](30-fuse-token-and-token-kind-storage.md)
  manually redesigns one Stage 02 representation;
- [Perceus Tranche 9](PERCEUS_OWNERSHIP_OPTIMIZATION_ROADMAP.md#tranche-9-remove-nonescaping-container-allocations)
  removes a local record that is never stored in another aggregate; and
- tuple SROA preserves the heap tuple ABI whenever the tuple escapes.

This prototype instead allows the parent to survive or escape. It compares a
projection-only control with a broader **copy-on-escape** strategy: store a
headerless child payload inside the parent, keep ordinary projections as
`Alias(parent)`, and materialize a normal boxed child only at a boundary that
requires an independent owner. Source-level COW semantics remain unchanged;
"copy-on-escape" is the more precise name for the representation strategy.

## Initial Scope And Strategies

Both strategies start with one folded level and require:

- named, monomorphic, internal heap-record parent and child types;
- a directly constructed child, possibly through immutable aliases, stored in
  exactly one parent field;
- one declaration-wide physical layout for every construction and use of the
  selected parent type;
- non-materializing child reads limited to exact nested field projections;
- no independently observable child lifetime after transfer into the parent
  until an explicit Strategy B materialization; and
- child fields that can remain ordinary Core values for Perceus and cleanup.

**Strategy A — projection-only folding** admits only exact nested field reads.
Any whole-child use rejects the parent declaration. This is the control because
it can prove the allocation and ownership machinery without materialization.

**Strategy B — copy on owning escape** admits an exact whole-child use when the
compiler can insert an explicit shallow materialization. Its first slice
requires every child field to have known unmanaged post-specialization storage;
those fields are copied into a new ordinary heap record. The boxed result then
follows the existing ARC/COW ABI. A projection that remains borrowed continues
to be `Alias(parent)` and does not allocate.

Managed child fields are census-only for Strategy B. Materialization would add
an owner of each managed grandchild while the parent remains live, which can
change observable refcounts and COW paths. A later extension requires its own
gate, exact duplication by field ownership policy, and transitive memory-
observation analysis; a generic "retain every managed field" rule is invalid.

For an admitted parent declaration, nested storage is always inline. The
one-allocation construction win applies when the child is `FreshOwned` and
transferred directly into the parent. A pre-existing boxed or shared child may
already have allocated and may make inline copying more expensive; reject that
input shape in both initial strategies.

Exclude unions, tuples, closures, collections, foreign layouts, recursive
edges, unresolved generic layouts, multiple parents, record update/reuse, and
source `is_unique`, `refcount`, or `size_of` observations of the parent or
child. Strategy A also excludes every whole-child call, return, storage, match,
or capture. Strategy B may materialize at a return, owning storage, closure/task
capture, or call requiring the boxed ABI, but initially rejects foreign
boundaries, managed child fields, and any ownership boundary it cannot
classify exactly.

Reject a parent declaration used by a global or static construction because
those values have a separate materialization path. Reject any cancellable
construction or materialization whose field-local cleanup cannot already be
expressed exactly.

The prototype adds no source syntax and does not change `record` or `struct`.
It must not special-case a compiler type name.

## Examples And Required Layout

An eligible source pattern is:

```blorp
record Position {
	line: Int,
	column: Int
}

record Diagnostic {
	message: String,
	position: Position
}

pure func diagnostic_line(message: String, line: Int, column: Int) -> Int:
	position: Position = {line = line, column = column}
	diagnostic: Diagnostic = {message = message, position = position}
	diagnostic.position.line
```

Today, `Diagnostic` holds `Position*` and each constructor allocates. An
eligible declaration-wide representation is conceptually:

```c
typedef struct Diagnostic {
  blorp_Object header;
  blorp_String* message;
  long position_line;
  long position_column;
} Diagnostic;
```

`diagnostic.position.line` becomes `diagnostic->position_line`; it must not box
a temporary `Position`. The embedded payload has no ARC header and is never
passed to `blorp_retain`, `blorp_release`, or an ordinary `Position*` ABI.

Strategy A rejects `position_of`; Strategy B materializes a standalone
`Position` at its return:

```blorp
pure func position_of(diagnostic: Diagnostic) -> Position:
	diagnostic.position                 -- Strategy B copies here
```

The materialization is conceptually:

```c
Position* result = Position_make(
  diagnostic->position_line,
  diagnostic->position_column
);
```

Both strategies initially reject pre-existing/two-parent input and nested COW
update:

```blorp

pure func shared_position(message: String, position: Position) -> (Diagnostic, Diagnostic):
	(
		{message = message, position = position},
		{message = message, position = position}, -- two parents
	)

updated = {
	diagnostic |
	position = {diagnostic.position | line = diagnostic.position.line + 1}
}                                            -- COW/update interaction
```

A named parent cannot silently have boxed and folded field layouts at different
sites. Standalone `Position` remains boxed, while `Diagnostic.position` has one
explicit embedded-payload representation. Strategy B is the only boundary that
converts that payload to the ordinary boxed representation.

Represent the decision explicitly before rewriting. An illustrative contract
is:

```blorp
union NestedRecordFieldLayout:
	IndirectNestedRecordField
	FoldedNestedRecordField(FoldedRecordFieldPlan)

enum FoldedChildEscapePolicy:
	RejectWholeChildUse
	MaterializeOnOwningEscape

record FoldedRecordFieldPlan {
	parent_declaration: CoreRecordDeclarationId,
	parent_field: CoreRecordFieldId,
	child_declaration: CoreRecordDeclarationId,
	child_fields: List[CoreRecordFieldId],
	escape_policy: FoldedChildEscapePolicy
}
```

Names may follow the eventual Core identity model, but facts must not be
inferred from field strings, C names, source order alone, or an allowlist. Add
or reuse phase-specific declaration and field identities if Core lacks them at
this boundary.

Keep physical layout separate from source semantic types. Ownership insertion,
record-update lowering, reuse, backend preparation, and C emission must consume
the same plan; the emitter must not rediscover eligibility. Strategy B also
needs an explicit Core materialization expression or binding carrying the
embedded owner, field plan, result type, and ownership transfer. Do not encode
materialization as an ordinary `RecordExpr` whose embedded source is inferred
later.

The natural owner is the existing post-projection aggregate-SROA boundary at
the end of early Core, after concrete template projection and before Perceus.
Extend and, if its responsibility broadens, rename `tuple_sroa.brp` rather than
adding an overlapping scalar-replacement pass.

## Prototype Steps

### 1. Pin Failing Contracts

Add a focused runtime fixture with `N` direct child/parent constructions. Check
its result and require current main to perform `N` child allocations that the
prototype must remove. Add Stage 09 and generated-C tests whose positive shape
still contains an indirect child field and child `RecordExpr` on current main.

Add Strategy A rejection tests for whole-child use, two-parent sharing, COW
update, recursive and foreign layouts, global/static construction, parent and
child memory observations, and cancellation cleanup that cannot be expressed.
Add behavioral preservation tests for managed-field initializer order and
cancellation after each initializer position. Strategy B adds fixtures with
zero, conditional, and every-iteration escape. A returned/materialized child
must remain valid after its parent is released. Negative tests must assert the
exact reason. Add Strategy B near-misses for a managed child field and a
no-release field whose storage is not proven unmanaged.

### 2. Build A Census And Dynamic Profile Without Rewriting

Return explicit facts with a stable `NestedRecordFoldSiteId`, distinct
`ProjectionOnlyCandidate` and `MaterializeOnEscapeCandidate` variants, and a
rejection enum covering at least `UnsupportedWholeChildBoundary`,
`MultipleParentUse`, `PreexistingChildUse`, `CowUpdateUse`,
`ChildMemoryObservationUse`, `ParentLayoutObservationUse`,
`CancellationCleanupUnsupported`, `GlobalConstructionUnsupported`,
`ManagedChildMaterializationUnsupported`, `UnknownUnmanagedFieldLayout`,
`ForeignLayout`, `RecursiveLayout`, `UnprojectedLayout`, and
`MixedParentLayout`. Closure/task capture is an owning materialization boundary
only when existing ownership and cancellation rules can be preserved exactly;
otherwise classify it as unsupported.

Report nested edges inspected, affected declarations, candidates by strategy,
rejections, nested projections, owning escapes, boxed-ABI borrowing calls, and
child fields partitioned by `NoReleasePolicy`, `ArcReleasePolicy`,
`ArcReleaseOnlyPolicy`, and `StackResultReleasePolicy`, plus analysis
expression/declaration visits. Keep the pure result explicit; do not use
mutable global state or an environment-name side channel.

Static sites cannot identify a hot shape. Assign each eligible site a profile
ID in a benchmark-only instrumented compiler and count its executions at the
child-to-parent handoff. The emitted profiling hook may use the existing
runtime profiling mechanism, but it must map back to exact Core declaration,
field, and site identities. Record per-site fused constructions, projection
reads, materializations by boundary, copied payload bytes, and managed-field
duplication operations that a future extension would require for the fallback
frontend fixture and a self-host compile. Select each oracle only from those
dynamic counts; do not use the instrumented run as latency evidence.

### 3. Measure Separate Hand-Flattened Oracles

On disposable prototype branches, select two shapes from dynamic counts:

- the hottest projection-only Strategy A candidate; and
- the hottest Strategy B-only candidate with at least one owning escape and
  only unmanaged child fields.

Manually flatten each shape. For Strategy B, explicitly materialize the child
at the same classified escape boundaries. These are separate benefit ceilings:
an A-eligible shape cannot prove B because B's distinguishing path never runs.
Do not preselect `TokenKind` merely because Issue 30 names it, and do not add an
unmeasured compatibility wrapper.

Prefer an early-frontend shape. Extend `compiler_typecheck_profile.brp` so its
configuration has an explicit allocation or timing measurement mode. Allocation
mode resets and reports `MemStats` allocations, releases, current objects, and
retained live bytes alongside its checksum; timing mode does not touch memory
instrumentation. Request construction remains outside both windows. Compare at
least five alternating fallback/retained samples in each mode: fallback includes
parsing and retained is the typecheck control.

Admit Strategy A only if its oracle removes at least 0.5% of whole-workload
allocations or 5% in the owning phase. Admit Strategy B only if its targeted
child-container saving is positive after materialization and it independently
passes the same whole-workload or owning-phase gate. Also report copied bytes
and ownership operations. If no distinct B-only production candidate passes,
stop with Strategy A. These named thresholds justify compiler complexity; they
are not performance forecasts.

### 4. Implement Strategy A As The Control

Plan a declaration-wide layout for the positive fixture and one measured
compiler shape, selected by facts rather than names. Rewrite direct child
construction and nested projections. Emit one parent allocation, no child ARC
header or constructor/destructor call, and direct parent destruction of managed
child fields in source order.

Hoist child initializers into ordinary Core lets in their original order so
Perceus and cancellation cleanup see every live managed field. If the existing
cleanup representation cannot express every interruption point, reject the
candidate. Do not add fallback reboxing.

### 5. Add Strategy B: Copy On Owning Escape

Keep the same headerless parent layout. Nested projections remain
`Alias(parent)`. At each proven boundary requiring an owned boxed child, emit
the explicit materialization operation and return `FreshOwned` storage governed
by the ordinary child-record ABI. Copy a field only when it has both
`NoReleasePolicy` and an exact known-unmanaged post-specialization layout fact;
reject no-release fields with unknown storage and every other field policy.

Never expose an interior pointer as an ARC object, put an ARC header inside the
parent, or keep the entire parent alive through a child backpointer. Those
approaches save a `malloc` but add global retain/release branching and can pin a
large parent after only its child is needed.

Calls using the existing boxed child ABI materialize even when their source
parameter is borrowing. A specialized borrowed embedded-record ABI may be
evaluated later, but is out of scope. Record these avoidable materializations
separately so they can inform that decision.

A future managed-field extension must duplicate each field according to its
exact post-specialization ownership policy. It must separately reject or prove
safe every `is_unique`, `refcount`, and `size_of` observation reachable through
the child or a managed grandchild while both parent and materialized child are
live. Do not generalize Strategy B merely because unmanaged fields pass.

The direct fixture must satisfy:

```text
targeted child-container allocations removed = fused fresh-child constructions
                                               - child materializations
```

Any deviation must be explained by named setup or ownership operations. If
materializations approach or exceed fused constructions, stop; locality alone
does not admit the added representation.

### 6. Measure And Decide

Compare identical baseline, Strategy A, and Strategy B sources and host-C
flags. Record allocation/releases, fused constructions, materializations,
copied bytes, and ownership operations first; then measure uninstrumented
retired instructions, phase time, RSS, generated-C bytes, and binary bytes.
Report targeted child-container and total managed-allocation deltas separately.
Treat sub-percent wall-time movement as directional unless alternating samples
are stable.

If admitted, write a bounded production issue for the exact accepted layout
family. If rejected, retain the measurements under `benchmarks/results/` and
delete rewrite/debug scaffolding, scratch files, and generated C.

## Fast Feedback Loop

Before rebuilding, exercise working-tree modules directly:

```bash
bin/blorp check --no-format blorp/src/compiler/stage_09_core/tuple_sroa.brp
bin/blorp test blorp/test/compiler/stage_09_core/test_core_tuple_sroa.brp
bin/blorp test blorp/test/compiler/stage_10_backend/test_core_emit.brp
```

If the pass is renamed, rename the focused test with it. Add a direct benchmark
under `blorp/benchmark/compiler/` that constructs Core in memory and measures
only census/rewrite work; keep fixture construction outside the reset window.
Run the runtime fixture at zero, conditional, and 100% child-escape rates and
report the allocation equation from Step 5.

After one candidate rebuild, stop at the layout boundary to omit Perceus and
backend work while checking real-source coverage and analysis cost:

```bash
fusion_core=$(mktemp "${TMPDIR:-/tmp}/blorp-record-fold.json.XXXXXX")
bin/blorp compile --no-format --time-phases --stop-after=fusion \
  --dump-core-file="$fusion_core" blorp/src/main.brp
rm -f "$fusion_core"
```

`--stop-after` renders a large Core snapshot. Redirect it with
`--dump-core-file` and remove it when only census and timing rows are under
comparison.

Use the extended allocation-capable frontend loop for the selected early-stage
shape. Run it once without `BLORP_TYPECHECK_PROFILE_SKIP_BUILD` after changing
compiler or benchmark source so the content-keyed artifact is current, then use
the cached alternating loops. The final argument is the benchmark measurement
mode added in Step 3:

```bash
benchmarks/compiler_typecheck_profile 1 1 16 256 fallback timing
BLORP_TYPECHECK_PROFILE_SKIP_BUILD=1 \
  benchmarks/compiler_typecheck_profile 5 1 16 256 fallback allocations
BLORP_TYPECHECK_PROFILE_SKIP_BUILD=1 \
  benchmarks/compiler_typecheck_profile 5 1 16 256 retained allocations
BLORP_TYPECHECK_PROFILE_SKIP_BUILD=1 \
  benchmarks/compiler_typecheck_profile 5 1 16 256 fallback timing
BLORP_TYPECHECK_PROFILE_SKIP_BUILD=1 \
  benchmarks/compiler_typecheck_profile 5 1 16 256 retained timing
```

Compile the positive and copy-on-escape fixtures to temporary C and inspect
allocation, explicit materialization, layout, and destruction:

```bash
fold_c=$(mktemp "${TMPDIR:-/tmp}/blorp-record-fold.c.XXXXXX")
bin/blorp compile --no-format --no-embed-runtime -o "$fold_c" \
  blorp/test/compiler/pipeline/codegen_audit/should_pass/nested_record_fold.brp
rg -n 'blorp_alloc|Position_make|Position_destroy|materialize|position_' "$fold_c"
rm -f "$fold_c"
```

Once stable, compare a retained baseline compiler and candidate with
`BLORP_COMPILER_MEMORY_PROFILE=1`, then run the relevant ownership, reuse,
cancellation, sanitizer, and codegen-audit gates before broad validation.

## Things To Look Out For

- **COW and memory observations:** uniqueness, refcount, ABI size, record update,
  and reuse may require an independent child or make layout visible. A managed
  grandchild can also gain an owner during materialization and change its
  observable refcount.
- **Cancellation:** removing the container creates separate field-owner
  intervals before parent construction; every interruption must clean them.
- **Materialization storms:** passing, returning, storing, matching, or
  capturing the child may replace every saved allocation; count each boundary.
- **Borrowed calls:** the current boxed ABI may force a copy even when the
  callee does not retain the child. Do not silently retain the parent instead.
- **Pre-existing children:** copying an already boxed/shared child into an
  inline payload can add field retains without removing its allocation.
- **Uniform ABI:** globals, cross-module calls, and every constructor of a named
  parent must agree on one layout; reject global/static construction initially.
- **Managed grandchildren:** preserve exact transfer, retain, release, and
  destruction order for strings, collections, closures, and records.
- **Evaluation order:** evaluate each initializer once, left to right.
- **Parent copy cost:** a larger parent may cost more to clone than copying and
  retaining one pointer to a shared child.
- **Recursion and padding:** prohibit cycles and report parent size/alignment
  growth before considering deeper folding.
- **Code and analysis size:** specialized helpers or an allocating whole-Core
  scan can erase locality and allocation gains.
- **Pass interaction:** SROA, record update, Perceus, reuse, closure/resource/
  cancellation lowering, preparation, and emission must preserve one plan.

## Prototype Acceptance Criteria

The prototype is viable only when all of the following hold:

1. Static eligibility, rejection, and per-site dynamic counts are deterministic,
   identity-based, exhaustive for the prototype, and focused-test covered.
2. Strategy A removes 100% of targeted child allocations, releases, ARC
   headers, and destructor calls without materialization elsewhere.
3. Results, initializer effects, managed-field destruction, cancellation
   cleanup, COW, memory-observation rejection, and leak counts match baseline.
4. Strategy B's targeted child-container allocation delta equals fused
   fresh-child constructions minus explicit materializations; total managed
   allocation delta is reported separately, and materialized children survive
   parent release.
5. Every admitted parent has one explicit declaration-wide field layout;
   embedded and boxed child representations and conversions are explicit, with
   no name or spelling heuristic.
6. Each strategy proposed for automatic implementation has a distinct
   production candidate and oracle. Each passes the 0.5% whole-workload or 5%
   owning-phase allocation gate independently; Strategy A may proceed alone.
7. Each selected automatic strategy reproduces at least 90% of its own oracle
   allocation reduction; every lost dynamic site is rejected or materialized
   for a named reason.
8. No interior child pointer reaches ARC, and an escaping child neither pins its
   parent nor embeds a second ARC header in the parent.
9. A no-candidate control shows no per-node instrumentation in the production
   path, no more than 0.25% allocation growth, and no more than 1% early-Core
   time growth.
10. Generated-C and binary growth are reported. More than 1% growth requires a
   corresponding instruction or latency benefit, not allocation counts alone.
11. A representative compiler workload shows either a 1% total allocation
   reduction or a stable 0.5% improvement in instructions, phase latency, or
   peak RSS. Otherwise reject production complexity.
12. Focused Core, emitter, ownership, leak, cancellation, sanitizer,
    codegen-audit, and `scripts/compiler-check --changed` gates pass.
13. The benchmark result records hashes, commands, raw samples, counters, exact
    output hashes, census totals, and the admit-or-reject decision.
14. Strategy B initially admits only fields proven both known-unmanaged and
    `NoReleasePolicy`; no-release fields with unknown layouts are rejected and
    tested. Any managed-field extension has separate transitive memory-
    observation and field-policy tests and admission evidence.
15. No scratch/generated artifacts, type-name special case, implicit dual
    layout, compatibility materializer, or parent-retaining interior reference
    remains in a proposed production change.

Acceptance authorizes a production design issue, not automatic merging of the
experimental rewrite.
