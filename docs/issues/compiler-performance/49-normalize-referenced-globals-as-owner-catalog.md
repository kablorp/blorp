# Normalize Referenced Globals As An Owner Catalog

**Status:** Proposed

**Roadmap:** Perceus ownership optimization, Tranche 4B

**Dependencies:** Issue 48 and Perceus Tranches 2–3

**Parallel work:** Do not implement in parallel with Issues 48, 50, or 51.

## Objective

Replace the per-referenced-global call, aggregate, and result rewrite loop with
owner-indexed passes over one catalog containing only the exact managed globals
referenced by the current ownership region.

Apply the change to ordinary function bodies and global initializers. Lambda
regions remain on their existing path until Issue 50.

## Why This Issue Exists

`unshadowed_global_values` first discovers referenced globals. Then
`retain_borrowed_values` runs this sequence once for every managed global:

```blorp
result = protect_borrowed_param_calls(env, value, result)
result = retain_borrowed_param_aggregate_members(env, value, result)
result = retain_borrowed_param_result(env, value, result)
```

With `G` referenced managed globals and `N` body nodes, the dominant work is
approximately `O(3 * G * N)`. This remains after Tranches 2–3 because their
catalog currently contains function parameters only.

Global discovery also materializes `CoreDce.value_references(body).resolved_reads`,
deduplicates candidate indices with repeated `List.contains`, scans shadowing
values, and sorts the result. Preserve this exact discovery authority first;
optimize it only behind its own counters and without changing which globals
enter the catalog.

## Required Reading

Read Issue 48, the roadmap, and inspect:

- `retain_borrowed_values`;
- `exact_global_index` and `exact_global_value`;
- `global_candidate_indices` and `unshadowed_global_values`;
- `rewrite_function` and `rewrite_global`;
- `PerceusGlobal`, `PerceusGlobalLookup`, and global catalog construction;
- exact-global collision and mutable-global tests in the Perceus suite; and
- DCE `value_references` semantics for resolved reads.

## Required Design

### Explicit owner origin

Extend the borrowed-owner representation so parameter and global identity are
not distinguished only by list position or comments. An illustrative shape is:

```blorp
union BorrowedOwnerKind:
	FunctionParameterOwner(Int)
	ReferencedGlobalOwner(Int)

record BorrowedOwnerEntry {
	value: CoreParam,
	kind: BorrowedOwnerKind
}
```

The actual type may preserve the existing `owners: List[CoreParam]` projection
for query code, but owner origin and deterministic order must be explicit at
construction boundaries.

### Exact referenced-global discovery

Only exact resolved global reads may add owners. Preserve:

- full `(name, def_id)` identity;
- same-spelling/different-definition rejection;
- duplicate-reference deduplication;
- deterministic global-index order;
- function-parameter shadow exclusion; and
- exclusion of the global currently being initialized.

Do not add every program global to every function catalog.

Initially it is acceptable to keep `CoreDce.value_references` as a separate
read-only discovery pass. If measurements show discovery itself material, a
follow-up commit inside this issue may replace only the resolved-global
projection with a targeted collector using a `Dict[Int, Bool]` seen index and
one final ordered projection. The old and new discovery lists must compare
exactly in focused tests before cutover.

### Owner ordering

For functions, parameter owners retain declaration order and referenced globals
follow them in ascending existing global index. For global initializers,
referenced globals use ascending global index after excluding the initialized
global itself.

The combined catalog may replace the separate parameter/global phases only
when the immediate-parent Core oracle proves the ordering produces identical
ownership events. Do not assume semantic equivalence from spelling or from the
fact that both sources are managed.

## Required Implementation Sequence

1. Add the referenced-global fixture, counters, and failing scaling assertions.
2. Add an explicit referenced-global catalog constructor from the existing
   discovery result.
3. Use all-owner call, aggregate, and Issue 48 result traversal for globals in
   function bodies.
4. Preserve exact parameter-before-global behavior. If a combined catalog is
   byte-identical, use it; otherwise retain separate parameter and global
   catalogs and document the ordering constraint for Issue 51.
5. Cut global initializers over, preserving self-global exclusion.
6. If discovery counters show material avoidable work, replace repeated list
   deduplication with an indexed collector as a separately measured commit.
7. Delete the function/global-initializer uses of `retain_borrowed_values` and
   any now-dead global-only wrapper.
8. Do not change lambda normalization in this issue.

## Benchmark Contract

Add `referenced_global_boundary` and `--referenced-global-matrix` to
`benchmarks/compiler_perceus_memory`.

Use:

```text
declared managed globals=384, fixed
referenced managed globals=1,8,32
functions=2
body_nodes=256, exact and fixed
global reference/transfer sites=32, fixed
function parameters=0
managed function result
worker invocation disabled
```

At every point there are exactly 32 reference sites. Cycle those sites through
1, 8, or 32 exact global identities so body size and actual boundary density do
not change. Use 12 consuming-call sites, 12 transferring record/collection
slots, and 8 branch-local result terminals per function. Validate those counts
and the exact 256-node census before collecting timing.

Add counters for:

```text
referenced_global_discovery_node_visits
referenced_global_read_candidates
referenced_global_exact_matches
borrowed_global_catalog_slots
borrowed_global_normalization_visits
borrowed_global_alias_fallback_requests
borrowed_global_rewrite_actions
```

If parameter and global catalogs are combined, retain operation-specific call,
aggregate, and result counters as well; do not make their work disappear into
one undifferentiated counter before Issue 51.

## TDD And Fast Feedback

Add focused tests for:

- one global referenced repeatedly enters the catalog once;
- 32 declared but unreferenced globals enter zero owner slots;
- same spelling with a different `def_id` is rejected;
- colliding global spellings resolve by exact `def_id`;
- a same-spelling parameter does not suppress a distinct resolved global;
- an exact parameter/global identity collision preserves current exclusion;
- mutable and immutable managed globals preserve current ownership behavior;
- a global initializer cannot retain itself as a borrowed source;
- one initializer referencing another global is normalized; and
- globals used in calls, aggregate storage, and result branches retain exact
  current event order.

Use this loop until the matrix is ready:

```bash
bin/blorp check --no-format blorp/src/compiler/stage_09_core/perceus.brp
bin/blorp test blorp/test/compiler/stage_09_core/test_core_perceus.brp
python3 -m unittest blorp.test.compiler.benchmark.test_perceus_memory
```

Build candidate workers once, then run seven warmed alternating pairs against
explicit immediate-parent workers. Do not use end-to-end compilation as the
iteration loop. Run it once after direct work, artifact, and allocation gates
pass.

## Acceptance Criteria

- Function and global-initializer normalization no longer run a complete
  call/aggregate/result rewrite once per referenced global.
- Only exact, referenced, managed globals enter the owner catalog; declared but
  unreferenced globals contribute zero catalog slots and zero normalization
  queries.
- Candidate reconstructing visits are constant across the fixed 1/8/32-global
  fixture. Discovery candidate work scales with 32 fixed reference sites, not
  with 384 declared globals.
- Scalar alias fallbacks are zero on the ownership-ready benchmark.
- The 32-global candidate performs at least 75% fewer borrowed-global
  reconstructing visits than the immediate parent.
- The 32-global direct-Perceus paired median is at least 15% faster and its
  direct-window allocation count is at least 20% lower than the immediate
  parent. If the exact fixed fixture cannot expose those gains, stop and
  reassess catalog construction before merging.
- One-global allocations and releases do not regress by more than 2%.
- Global discovery uses no repeated linear deduplication if its measured work
  is material; otherwise the retained discovery implementation and its cost
  are documented explicitly.
- Parameter/global ordering, collision behavior, global self-exclusion,
  ownership events, post-Perceus Core, and generated C are byte-identical to
  the immediate parent.
- Function/global-initializer callers of scalar `retain_borrowed_values` are
  deleted; lambda callers remain clearly identified for Issue 50.
- Focused tests, benchmark contracts, `scripts/compiler-check --changed`, and
  `git diff --check` pass.

## Expected Result

Referenced-global normalization changes from approximately `O(G * N)` per
operation family to fixed owner-independent traversals plus exact candidate
queries. The controlled 32-global fixture should show an obvious reduction in
direct Perceus time and allocation without making functions pay for unrelated
program globals.
