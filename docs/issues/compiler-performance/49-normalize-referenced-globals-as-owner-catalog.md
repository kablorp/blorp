# Normalize Referenced Globals As An Owner Catalog

**Status:** Implemented (2026-09-04)

**Roadmap:** Perceus ownership optimization, Tranche 4B

**Dependencies:** Issue 48 and Perceus Tranches 2–3

**Parallel work:** Do not implement in parallel with Issues 48, 50, or 51.

## Objective

Replace the per-referenced-global call, aggregate, and result rewrite loop with
owner-indexed passes over one catalog containing only the exact managed globals
returned by the current referenced-global discovery authority.

Apply the change to ordinary function bodies and global initializers. Lambda
regions remain on their existing path until Issue 50. Keep the existing
parameter catalog and the new referenced-global catalog as separate sequential
phases in this issue: parameter normalization completes first, then global
normalization runs over its own catalog.

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
union BorrowedOwnerOrigin:
	FunctionParameterOwner(Int)
	ReferencedGlobalOwner(Int)

record BorrowedOwnerEntry {
	value: CoreParam,
	origin: BorrowedOwnerOrigin
}
```

The actual type may preserve the existing `owners: List[CoreParam]` projection
for query code, but owner origin and deterministic order must be explicit at
construction boundaries.

Prefer storing an entry containing both value and origin over parallel lists
whose positions can diverge. The origin index is the existing parameter index
or global index, not a newly inferred identity. It must be available to debug
counters without changing production rewrite behavior.

### Separate catalog boundary

Issue 49 must not combine parameter and global owners into one rewrite catalog.
The current function order is:

```text
parameter calls -> parameter aggregates -> parameter results
-> discover globals from the retained body
-> global calls/aggregates/results
```

Preserve that boundary exactly. Build the global catalog from the
parameter-normalized `retained_body`, then run the three all-owner global
passes. A combined parameter/global traversal changes phase ordering and may
change ownership-node nesting even when the same values are eventually
retained. Issue 51 may combine these phases only after it has its own exact
event-order proof.

### Exact referenced-global discovery

Only exact resolved global reads may add owners. Preserve:

- full `(name, def_id)` identity;
- same-spelling/different-definition rejection;
- duplicate-reference deduplication;
- deterministic global-index order;
- function-parameter shadow exclusion; and
- exclusion of the global currently being initialized.

Do not add every program global to every function catalog.

Parameter exclusion must examine the complete declared parameter list, not
only the borrowed-parameter catalog. A consumed or unmanaged parameter with
the same exact identity still participates in the existing exclusion rule.
Likewise, do not use spelling alone to exclude a global: a same-spelling
parameter with a different `def_id` does not suppress an exact resolved global
read.

Initially it is acceptable to keep `CoreDce.value_references` as a separate
read-only discovery pass. If measurements show discovery itself material, a
follow-up commit inside this issue may replace only the resolved-global
projection with a targeted collector using a `Dict[Int, Bool]` seen index and
one final ordered projection. The old and new discovery lists must compare
exactly in focused tests before cutover.

`CoreDce.value_references` currently traverses nested lambda bodies. Therefore
the preserved discovery result can over-approximate the globals used by the
outer ownership region even though the borrowed-boundary rewrites themselves
treat a lambda as opaque. Do not silently change that boundary in this issue.
The extra catalog entries are allowed compatibility work; Issue 50 owns lambda
region discovery and normalization.

### Owner ordering

For functions, the existing parameter phase retains declaration order and the
following global catalog uses ascending existing global index. For global
initializers, referenced globals use ascending global index after excluding the
initialized global itself.

Within Issue 49 these are two catalogs, not one concatenated catalog. Parameter
owners retain declaration order in the existing parameter phase. Global owners
retain ascending global-index order in the following global phase. The exact
post-Perceus Core oracle must prove both the owner order within the global phase
and the parameter-before-global phase boundary.

## Required Implementation Sequence

1. Add the referenced-global fixture, counters, and failing scaling assertions
   without changing normalization. Commit that instrumentation-only state and
   capture its timing and counter workers; those workers are the immediate
   behavioral baseline for the cutover.
2. Add an explicit referenced-global catalog constructor from the existing
   discovery result.
3. Use all-owner call, aggregate, and Issue 48 result traversal for globals in
   function bodies.
4. Preserve the separate parameter-before-global phase boundary and exact
   global-index owner order. Do not attempt the Issue 51 combined traversal.
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
global reference/transfer sites per function=32, fixed
global reference/transfer sites across fixture=64, fixed
function parameters=0
managed function result
worker invocation disabled
```

At every point each function has exactly 32 reference sites, for 64 sites
across the two-function fixture. Cycle each function's sites through 1, 8, or
32 exact global identities so body size and actual boundary density do not
change. Each function uses 12 consuming-call sites, 12 transferring
record/collection slots, and 8 branch-local result terminals. Validate those
per-function counts, the 64-site fixture total, and the exact 256-node census
before collecting timing.

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

Define the discovery counters precisely:

- `referenced_global_discovery_node_visits` counts the nodes inspected by the
  discovery authority and is constant across the fixed body shape;
- `referenced_global_read_candidates` counts distinct exact
  `resolved_reads` after DCE's identity deduplication, so the matrix expects
  1, 8, and 32 per function, or 2, 16, and 64 across this two-function
  fixture, rather than 32 at every point; and
- `referenced_global_exact_matches` counts those distinct candidates that map
  to exact global indices and likewise expects 2, 16, and 64 across this
  fixture.

The fixed 32-per-function source occurrence count is a fixture structural
assertion, not `referenced_global_read_candidates`. Do not introduce another
production body walk merely to count occurrences. Retain operation-specific
call, aggregate, and result counters as well; global work must not disappear
into one undifferentiated counter before Issue 51.
`borrowed_global_normalization_visits` is composed by the isolated fixture from
the identical call, aggregate, and result node-visit counters in the scalar
baseline and catalog candidate. This makes the 75% visit gate a direct
comparison rather than an inferred estimate.

Because the direct fixture deliberately leaves workers uncalled, generated-C
equivalence must use a second rooted emission request that invokes every worker.
The direct unrooted fixture remains the timing and allocation authority.

## TDD And Fast Feedback

Add focused tests for:

- one global referenced repeatedly enters the catalog once;
- 32 declared but unreferenced globals enter zero owner slots;
- same spelling with a different `def_id` is rejected;
- colliding global spellings resolve by exact `def_id`;
- a same-spelling parameter does not suppress a distinct resolved global;
- an exact parameter/global identity collision preserves current exclusion;
- consumed and unmanaged exact-collision parameters also preserve that
  exclusion even though they are absent from the borrowed-parameter catalog;
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
the captured instrumentation-only workers. Do not use end-to-end compilation
as the iteration loop. After direct work, artifact, and allocation gates pass,
run one rooted generated-C comparison and then one production self-compilation
smoke.

## Acceptance Criteria

- Function and global-initializer normalization no longer run a complete
  call/aggregate/result rewrite once per referenced global.
- Only exact, referenced, managed globals enter the owner catalog; declared but
  unreferenced globals contribute zero catalog slots and zero normalization
  queries.
- Candidate reconstructing visits are constant across the fixed 1/8/32-global
  fixture. Discovery node visits remain fixed, while distinct read candidates,
  exact matches, and catalog slots are exactly 1/8/32 per function and
  2/16/64 across the two-function fixture; no discovery or normalization
  dimension scales with 384 declared globals.
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
- Parameter-before-global phase ordering, ascending global-index owner order,
  collision behavior, global self-exclusion, ownership events, and
  post-Perceus Core are byte-identical to the captured instrumentation-only
  parent. Generated C is byte-identical for the separate rooted fixture at all
  three matrix points.
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

## Implementation Result

Implemented on 2026-09-04. Function parameters and referenced globals use
separate sequential catalogs. Each owner entry carries an explicit parameter
or global origin, exact referenced-global discovery remains DCE-authoritative,
and empty discovery results return an empty entry list without constructing a
catalog. Every nonempty ordinary function/global region uses the same dense
all-owner catalog. Nested lambdas remain on the named scalar path for Issue 50.

At 32 referenced globals, the fixed fixture reduced reconstructing visits from
35,176 to 1,082 (96.9%), the paired direct-Perceus median by 41.1%, allocations
by 41.2%, and releases by 42.5%. The one-global control remained within its
guard at +0.32% allocations and +0.34% releases. Post-Perceus Core and rooted
generated C were byte-identical at 1, 8, and 32 globals.

Discovery remained the existing `CoreDce.value_references` projection and
sorted-list deduplication. Its node count was fixed at 897 for all matrix
points, while exact candidate work was only 2, 16, and 64 across the fixture;
it showed no dependence on the 384 declared-but-unreferenced globals and was
not material enough to justify a second discovery implementation here.

See
[`compiler_perceus_tranche4b_2026-09-04.md`](../../../benchmarks/results/compiler_perceus_tranche4b_2026-09-04.md)
for the full measurements and reproduction hashes.
