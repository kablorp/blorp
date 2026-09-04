# Establish Graph-Local Module IDs

**Status:** Rejected after focused and production measurement

**Dependencies:** This is the first issue in `GRAPH_MODULE_ID_ROADMAP.md`.
Begin from then-current main and audit any declaration-catalog changes that
integrated after this issue was written.

**Downstream consequence:** This experiment did not establish its proposed
`GraphModuleId` substrate. Issue 46 later introduced a different, narrower
private scope-slot substrate together with one measured TypeHeader consumer.
Downstream work must not assume that Issue 45's rejected type or broad graph
conversion exists.

**Parallel work:** Do not change shared graph/module identity types in parallel
with this issue. Unrelated work may proceed when ownership manifests do not
overlap.

## Objective

Create one dense, immutable module table for each accepted Stage 06 graph and
use graph-local integer IDs for prepared/bound-module ownership, scopes, and
repeated module lookup. In the same production slice, replace the current
linear `prepared_module_environment_find` with module-ID addressing so the
foundation removes measured work immediately. Keep Stage 4 resolution and
validation on durable descriptive identities.

This issue must remove current graph-addressing work immediately. It must not
land a dormant numeric ID beside unchanged production reads.

## Required Reading

Before editing, read:

1. `AGENTS.md`;
2. `docs/ARCHITECTURE.md`, through Stage 06;
3. `docs/issues/compiler-performance/GRAPH_MODULE_ID_ROADMAP.md`;
4. Issues 32, 34, 37, and 38, plus any later declaration-authority issues that
   are implemented on current main;
5. `blorp/src/compiler/stage_04_modules/loaded_module.brp`;
6. `blorp/src/compiler/stage_04_modules/frontend_graph.brp`;
7. `blorp/src/compiler/stage_04_modules/frontend_graph_service.brp`;
8. `blorp/src/compiler/stage_06_typecheck/graph/indexed_graph.brp`;
9. `blorp/src/compiler/stage_06_typecheck/modules/bound_module_graph.brp`;
10. `blorp/src/compiler/stage_06_typecheck/frontend_graph_typecheck.brp`;
11. `blorp/src/compiler/stage_06_typecheck/state.brp`; and
12. the corresponding Stage 04/06 tests and compiler module-binding benchmark.

## Context

`ResolvedModuleIdentity` is an opaque record containing canonical path and
origin. Later, `ModuleIdentity` is an opaque union:

```blorp
private union ModuleIdentityRep:
	LoadedModuleIdentityRep(String, ModuleOrigin)
	DirectModuleIdentityRep(String, String)
	SurfaceModuleIdentityRep(String)
	AnonymousModuleIdentityRep
```

Repeated equality unwraps both values and compares their strings/origins.
Module dictionaries usually call `module_identity_storage_key`, which allocates
or combines length-prefixed string components before dictionary hashing.

The frontend graph already validates the complete accepted module set. After
that validation, most Stage 06 graph operations need only exact owner equality
and addressing; they do not need paths or origins at every use site.

At revision `0e25482b`, exact function instrumentation of the production
self-check observed 2,692,273 calls to `prepared_module_scope_identity` and
210,241 calls to `bound_module_graph_find`. The same source contains the linear
`prepared_module_environment_find`, although the fixed exact-profiler registry
filled before that private function was exposed. Instrumentation elapsed time
is distorted by function-entry profiling and must not be treated as production
latency; these counts justify a focused construction/query window, not a
promised speedup.

## Scope Audit Before Editing

Produce a checked inventory table with these columns:

| Current operation | Caller | Identity form | Needs metadata? | Can use graph ID? | Ordering/diagnostic constraint |
| --- | --- | --- | --- | --- | --- |

Include every call in the in-scope files to:

- `module_identities_equal`;
- `resolved_module_identities_equal`;
- `module_identity_storage_key`;
- `resolved_module_identity_storage_key`;
- `prepared_module_identity` and `prepared_module_scope_identity`;
- `bound_module_identity` and graph find/membership helpers; and
- canonical-path/origin/display accessors.

Classify canonical-path import resolution and duplicate detection as durable
identity work. Do not force those operations through IDs before the accepted
set exists.

## Implementation Plan

### 1. Introduce an opaque graph-local ID

The intended shape is:

```blorp
opaque type GraphModuleId = Int
```

The type, constructor, and integer representation remain private to
`indexed_graph.brp`. Do not expose free-standing cross-graph equality or a
generic integer conversion. Equality and raw indexing occur only behind the
owning graph product.

Compile a small fixture and inspect generated C before production cutover. It
must prove that copying/comparing `GraphModuleId` does not allocate, retain, or
release a managed wrapper. If `opaque type` does not erase to the integer
representation, use an established stack-valued alternative and document it.

### 2. Build one authoritative table

Prefer making the existing prepared-module list the table instead of retaining
a second descriptor collection. An illustrative final graph shape is:

```blorp
private record IndexedGraphRep {
	target_id: GraphModuleId,
	module_table: GraphModuleTable,
	dependencies_by_path: Dict[String, GraphModuleId],
	definition_index: DefinitionIndex
}

private record PreparedModuleScopeRep {
	graph: IndexedGraph,
	module_id: GraphModuleId
}
```

The path dictionary remains necessary because the current Stage 4 graph is
flattened into a string-based `TypecheckGraphRequest`, and Stage 06 reconstructs
import binding from parsed canonical paths. Its values become small IDs.
Ordinary graph ownership and selection after that lookup use IDs and direct
module-list access.

Illustrative internal construction shape:

```blorp
opaque type GraphModuleTable = List[PreparedModule]

private record GraphModuleAssignment {
	target_id: GraphModuleId,
	table: GraphModuleTable
}

private pure func assign_graph_module_ids(
	target: LoadedModule,
	modules: List[LoadedModule],
) -> Result[GraphModuleAssignment, List[GraphModuleTableError]]

private pure func indexed_graph_module(
	graph: IndexedGraph,
	id: GraphModuleId,
) -> Option[PreparedModule]
```

The implementation must:

- derive entries only from the validated complete typecheck universe;
- reject duplicate semantic identities and canonical-path/origin conflicts
  consistently with existing validation;
- assign the target first and dependencies in the existing validated storage
  order, without adding a semantic-key sort solely for internal ID stability;
- preserve the existing target/dependency processing order through table-order
  accessors, without retaining a second ordered module or ID list;
- store each prepared module and its durable identity/path/origin once in the
  table;
- retain exactly one canonical-path-to-ID index required by the current
  typecheck request/import-binding boundary;
- bounds-check every ID before descriptor access.

Direct-program, compiler-surface, and anonymous identities currently exist
outside this accepted graph table. Pin that boundary with tests and leave them
descriptive. Do not reserve undocumented integer values or invent a second
table for graphless state.

### 3. Make graph products table-owned

`IndexedGraph`, the accepted frontend typecheck product, or the narrowest
existing common graph owner should retain the table. Do not add the table to
every `TypecheckState` copy if it already exists in shared graph facts.

Products containing a `GraphModuleId` must be constructed from the same graph
owner. Cross-module compiler queries accept provenance-bearing scopes rather
than a freely pairable graph and ID. Direct numeric lookup remains private to
the graph implementation. Add exactly one narrow cross-module primitive:

```blorp
pure func prepared_module_scope_compatible_index(
	owner: PreparedModuleScope,
	requested: PreparedModuleScope,
) -> Option[Int]
```

The primitive first applies the existing `prepared_module_scopes_are_compatible`
semantics, including separately allocated structurally equivalent graphs. It
returns `None` for incompatible graphs and otherwise returns the requested
scope's bounds-checked table slot. Consumers use that slot immediately against
a product built in the owner's table order. Do not expose `GraphModuleId`
outside `indexed_graph.brp` or add a generic unvalidated list-index helper.

Construction privacy and graph-owned query APIs are the defense against
cross-graph integer collisions. A bare integer cannot carry a type-level table
lifetime in current Blorp, so no free-standing nominal identity or public
cross-graph equality API may contain this ID. Do not imply that an in-range ID
from another graph can be detected dynamically.

### 4. Cut over graph addressing

Migrate, at minimum:

- the Stage 06 handoff from accepted descriptive module products;
- prepared module identity/addressing;
- prepared module-scope identity/addressing;
- bound module identity/addressing;
- module graph find, membership, dependency, and visibility traversal; and
- any string-keyed lookup whose key exists solely to address one accepted
  module in the current graph.

Also migrate `TypecheckGraphFacts.prepared_environments` to an aligned
graph-owned module product, or add the narrowest equivalent module-ID index, so
`prepared_module_environment_find` no longer performs a linear identity scan.
Preserve the exact missing/failed module distinctions and avoid a second copy
of each prepared environment.

Audit every hot `prepared_module_scope_identity` caller. Calls that only test
same-graph module ownership must use compatible scope provenance plus internal
ID equality; calls that render diagnostics or construct durable nominal IDs
may resolve the prepared module. The candidate must not replace millions of
identity comparisons with millions of descriptor-table projections.

Keep descriptive identity in the module descriptor and use it only for
diagnostics, display, canonical-path matching, and later external projection.

Do not rewrite `FrontendGraph` roots/edges or import resolution in this issue.
Those Stage 4 products legitimately establish identity from canonical path and
origin. Convert to graph-local IDs only at the accepted Stage 06 graph
construction boundary.

The final issue diff must not retain parallel integer and string lookup paths
for a migrated graph operation.

## Non-Goals

- Do not change freely comparable nominal declaration IDs; they retain durable
  module identity.
- Do not migrate declaration-catalog tables; Issue 46 owns that work.
- Do not alter import resolution, visibility, source order, or declaration
  processing order.
- Do not introduce process-global state, a cross-compilation interner, caching,
  or path hashing as identity.
- Do not serialize `GraphModuleId` or publish it to the LSP.
- Do not change `ModuleOrigin`, canonical path semantics, or duplicate policy.
- Do not modify declaration-category authority as part of this issue.

## TDD Plan

Write failing tests before production cutover for:

1. the same accepted modules discovered in different orders produce
   byte-identical semantic output even though internal ordinals are not an
   observable contract;
2. dense IDs cover exactly `0..module_count-1` through a primitive test
   observation, without exposing table internals;
3. durable identities with the same canonical path and different origins
   remain unequal, while attempting to place both in one graph preserves the
   current exact conflicting-origin rejection;
4. duplicate semantic identities fail with exact existing diagnostic text,
   span, and source ordering;
5. chain, fan-out, layered/diamond, and dense edges resolve to the same exact
   modules as the descriptive-identity baseline;
6. target-first definition/callable ID allocation is unchanged while graph
   module IDs follow existing validated target/dependency order;
7. direct, anonymous, prelude/compiler-surface, stdlib, native-package,
   source-package, and user-module cases either receive explicit valid IDs or
   remain proven outside the migrated boundary;
8. every produced scope resolves to a bounded table slot, compile-fail privacy
   tests prevent callers from forging/unwrapping IDs, and cross-module
   production APIs use `prepared_module_scope_compatible_index` rather than
   table-plus-ID or free-standing ID equality;
9. separately allocated but structurally equivalent graphs with the same
   validated module order preserve the current positive scope-compatibility
   result and align corresponding internal IDs;
10. structurally different graphs fail compatibility before an internal ID is
    interpreted;
11. recoverable graphs exclude failed modules exactly as before; and
12. diagnostics and semantic occurrence identities remain byte-identical.

Use public graph/module behavior for equivalence. Do not expose module table
lists or representation fields solely for tests.

## Benchmark Plan

The existing module-binding fixture calls `register_program_imports` directly
and does not execute `IndexedGraph`; it is not sufficient acceptance evidence.
Extend the production import-graph fixture with distinct graph-construction and
prepared-environment-query windows. Add a new fixture only if that production
path cannot expose both windows compactly.

Replace its count-only checksum with an adjacency-derived checksum that mixes
each exact module owner and edge. Add real table-driven chain, star/fan-out,
layered/diamond, and dense graphs rather than mapping names onto approximate
fan-out values. Emit allocator fields in the runner.

For each row record:

- workload validity and semantic checksum;
- module count, edge count, and topology;
- exact production function counts for descriptive comparisons/storage-key
  helpers where the existing LLVM instrumentation exposes them;
- modeled/expected integer comparisons only when derived from fixture shape,
  clearly labeled as modeled rather than exact production counts;
- graph module-table constructions;
- descriptor lookups;
- graph module-index lookups;
- descriptor/metadata projections from module scopes;
- elapsed time;
- allocations, releases, current objects, and bytes; and
- peak RSS where the runner supports it.

Emit those fields as the four tagged evidence classes defined by
`GRAPH_MODULE_ID_ROADMAP.md`: semantic, modeled work, exact production, and
measured cost. Do not combine them into one untyped counter record.

Required dimensions:

```text
modules:       1, 8, 32, 128
topology:      chain, star/fan-out, layered/diamond, dense
declarations:  1, 16, 64 per module
```

Module count and declarations per module must vary independently. Baseline and
candidate rows must have identical semantic checksums and edge/module counts.

## Fast Feedback

Use this loop after each small edit:

```bash
bin/blorp test blorp/test/compiler/stage_04_modules/test_frontend_graph.brp
bin/blorp test blorp/test/compiler/stage_06_typecheck/test_indexed_graph.brp
bin/blorp test blorp/test/compiler/stage_06_typecheck/test_frontend_graph_typecheck.brp
```

Adjust exact paths only if the ownership manifest names different current
suites. Then run the three smallest benchmark rows: one module, eight-module
chain, and eight-module dense graph. Do not rebuild the full compiler for each
field migration.

At a production checkpoint:

1. run formatting and `git diff --check`;
2. run `scripts/compiler-check --changed`;
3. inspect generated C for integer equality/indexing and no per-ID allocation;
4. run the full synthetic matrix; and
5. request a clean timing slot before matched self-check workers.

## Acceptance Criteria

- One immutable graph-local module table is built per accepted Stage 06 graph.
- Migrated graph products carry a dense stack-valued integer ID.
- Prepared/bound-module addressing and prepared-environment lookup no longer
  structurally compare descriptive identities.
- Same-module scope checks use graph provenance plus internal integer equality;
  descriptor projections do not increase on ownership-only paths.
- `GraphModuleId` remains private to the indexed graph module; only a
  compatibility-validated integer slot crosses into aligned product queries.
- No graph-local ID/slot can be serialized or retained by LSP state.
- Assignment follows existing validated target/dependency order without
  changing observable semantic work order.
- Direct and compiler-surface behavior is explicitly preserved outside the
  graph-local table.
- Exact diagnostics, IDs, visibility, recoverable behavior, and responses are
  unchanged.
- Generated C shows integer copy/equality and no per-ID managed allocation.
- Focused allocations or retired instructions improve.
- The prepared-environment lookup window removes its linear module scan and
  materially improves allocation or retired-instruction scaling.
- Whole-compiler median retired instructions improve by approximately 1% or
  more, and no clear elapsed/RSS regression appears.
- Old string-key graph addressing is deleted for every migrated operation.
- Code-reviewer, test-runner, and final code-optimizer reviews approve.

If the production gate does not show a defensible win, reject the issue and do
not proceed to Issue 46 merely to justify the new representation.

## Experimental Result

The candidate was implemented on base `8b507154a891172981c62a9096e8a7095c38a408`,
measured, reviewed, and rejected. All production, benchmark, and test changes
were restored after the production gate failed. No `GraphModuleId`, numeric
module table, or module-ID-indexed environment product remains in production.

### Pre-implementation dependency audit

The broad textual inventory is retained in the ignored measurement directory
as `preimplementation-identity-inventory.txt`. It contains 291 search matches,
including imports and declarations as well as reads. The decision table below
classifies those matches by semantic purpose; it does not relabel durable
identity work as graph addressing.

| Current operation | Principal callers | Identity form | Needs metadata? | Candidate graph ID use | Ordering or diagnostic constraint |
| --- | --- | --- | --- | --- | --- |
| accepted module validation and conflict detection | `indexed_graph_build` helpers | resolved identity, canonical path, origin | yes | no | exact existing duplicate/conflicting-origin errors and input order |
| dependency selection by canonical path | `indexed_graph_find_dependency`, prepared-scope selection | canonical path | yes at the import boundary | ID only as the path-index value | exact selected module and missing-target errors |
| prepared scope metadata projection | state, binding, declaration, diagnostics | scope-owned `PreparedModule` | yes for identity/path/origin readers | yes after bounds/provenance validation | durable output remains descriptive |
| prepared-scope compatibility | state and graph-owned products | graph structure plus module identity | no for same-module checks | yes | separately allocated equivalent graphs remain compatible |
| bound graph identity lookup | global completion, accepted body selection, CTFE | `ModuleIdentity` plus path dictionary | yes at caller boundary | yes after exact durable identity validation | wrong-origin same-path requests fail closed |
| bound graph canonical-path lookup | import/module-view construction | canonical path | yes | ID after path resolution | import precedence and visibility unchanged |
| importable graph scope membership | module registration and accepted bodies | prepared-scope identity | no | yes | accepted subset membership, not whole-graph membership |
| reserved-state same-module check | `typecheck_state_is_reserved_for_scope` | compatible scopes plus descriptive identity | no | yes | no change to definition-ID ownership |
| state scope switching | imported/prepared module entry | canonical path and prepared scope | partly | yes, but retain the state owner's graph allocation | equivalent-graph behavior and restoration order unchanged |
| prepared environment lookup | global initializer and body preparation | linear `ModuleIdentity` scan | no after request admission | yes | failed/missing environment distinctions preserved |
| nominal declaration/global/callable ownership | declaration authorities and diagnostics | durable `ModuleIdentity` | yes or cross-graph | no | IDs remain serializable and externally comparable |
| storage-key construction for scheduling/indexes | global completion and durable category indexes | `module_identity_storage_key` | yes | no in this issue | stable ordering and collision validation unchanged |

### Candidate shape

The discarded candidate:

- assigned target slot `0` and dependency slots `1..N` inside `IndexedGraph`;
- stored a private opaque `GraphModuleId = Int` in prepared scopes;
- changed path dictionaries to map canonical paths to IDs;
- aligned bound modules, importable membership, and prepared environments with
  the graph slot range;
- replaced both global-initializer and body-preparation environment scans with
  scope-to-slot lookup; and
- retained all durable identity checks at free-standing request boundaries.

Generated C represented `GraphModuleId` as a plain C `long`, so copying and
comparing an ID did not allocate. It also showed that the candidate's nested
`GraphModuleTable` record allocated once per graph. An early list-range form
typechecked but failed during bootstrap C emission; replacing it with list
iteration plus a scalar ordinal compiled. This backend discrepancy is a
compiler rough edge, not a reason to retain the candidate.

### Focused validation before restore

The candidate passed `scripts/compiler-check --changed`: 5 production sources,
8 selected suites, and the leak check in 275.63 seconds. Direct focused results
included:

| Suite | Result |
| --- | ---: |
| indexed graph | 13/13 |
| bound module graph | 16/16 |
| typecheck state | 19/19 |
| declaration/typecheck | 119/119 |
| frontend graph typecheck | 4/4 |
| declaration catalog | 11/11 |
| import graph benchmark contract | 4/4 |

The compile-fail privacy fixture produced the exact expected diagnostic that
`GraphModuleId` was private. Formatting and `git diff --check` were clean. The
fixture and all implementation tests were removed with the rejected code.

### Controlled synthetic measurement

The control and candidate used the same benchmark-only patch, SHA-256
`4a1f52481337f936679e0d9f159cb234342045a48c6ad3ddef6248fd205e05ba`.
The control worker SHA-256 was
`f0d2831c7fdf319f322c5ceaa69e93e4477baa3b939a7a1704aca70f8f750c3d`;
the final optimized candidate worker SHA-256 was
`fb0a15c1ecddedc1b94892a973a34be621e92f41a76426b51e0dc51c2e549768`.

The 48-row matrix independently varied configured dependency modules
`1, 8, 32, 128`, declarations per module `1, 16, 64`, and `chain`, `star`,
`layered`, and `dense` topology. Each row ran one control and one candidate in
alternating order. All 96 executions emitted zero errors and valid semantic,
modeled-work, construction-cost, and query-cost rows. All 48 pairs had exact
matching graph-module count, edge count, and checksum.

The high-end row contained 129 graph modules and 8,256 exact edges. A full
typecheck version exceeded ten minutes and about 3.7 GB RSS, so the complete
matrix used an `addressing-only` mode that exercised production
`indexed_graph_build`, dependency-scope lookup, and scope metadata projection
without the unrelated full typecheck. The benchmark mode was discarded with
the candidate.

| Dimension | Rows | Construction allocations | Construction bytes | Query allocations | Query elapsed |
| --- | ---: | ---: | ---: | ---: | ---: |
| all | 48 | +0.010% | +0.013% | -44.746% | -23.928% |
| 1 configured module | 12 | +0.030% | +0.463% | -23.881% | -10.227% |
| 8 configured modules | 12 | +0.023% | +0.068% | -41.026% | -19.649% |
| 32 configured modules | 12 | +0.012% | +0.017% | -44.444% | -24.038% |
| 128 configured modules | 12 | +0.004% | +0.004% | -45.390% | -24.559% |

Topology did not change the deterministic allocation delta. Aggregated
external instructions for harness setup plus both measured windows were flat
at -0.008%. The focused result therefore proves an indexed-scope lookup
improvement only. It does **not** measure `PreparedModuleEnvironmentTable` or
prove removal of the production prepared-environment scan. Exact function
instrumentation did not expose that private lookup in the previously saturated
registry, and modeled query counts were not substituted for exact production
counts.

Raw ignored evidence is under `logs/issue45/`:

- `addressing-matrix-raw.log` and `addressing-matrix.tsv`;
- `addressing-pairs.tsv` and `addressing-summary.tsv`;
- generated C, native harnesses, `hashes.txt`, and build logs; and
- the ten-minute high-end full-typecheck scout output.

### Whole-compiler gate

After one warmup per worker, three control/candidate pairs alternated order and
ran `check --no-format blorp/src/main.brp`. Every response was byte-identical,
SHA-256 `c1758b804e292be62860bce968c8cee14b4b6a8fec681ff19c5318e5195c0963`.

| Worker | Wall samples (s) | Median | Retired-instruction samples | Median | Median peak footprint |
| --- | --- | ---: | --- | ---: | ---: |
| control | 40.12, 35.70, 31.51 | 35.70 | 437,723,175,871; 437,950,978,141; 438,116,527,725 | 437,950,978,141 | 1,087,292,520 bytes |
| candidate | 41.32, 36.18, 32.01 | 36.18 | 439,347,234,257; 439,190,825,957; 439,540,277,779 | 439,347,234,257 | 1,081,607,272 bytes |

Median wall time regressed 1.34%, median retired instructions regressed 0.319%,
and median peak footprint improved 0.52%. Median cycles were effectively flat
at +0.047%. The ordinary check command does not expose Blorp allocator object
counters, so no allocator totals are claimed for this production replay.

### Review and decision

Final optimizer review found additional avoidable candidate costs: eager
evaluation of the target fallback during valid scope metadata lookup,
redundant same-module validation after environment slot selection, managed
module projection solely for bounds checks, one nested graph-table allocation,
and one affine membership list. It also found that directly retaining a scope
from a separately allocated equivalent graph changed which graph allocation a
state owned. Those are real implementation findings, but the reviewer judged
them insufficient to move the measured result from +0.319% instructions to the
required approximately -1%.

**Decision: reject.** Physical indexed-scope queries became cheaper, but the
complete compiler did more instruction work and the required
prepared-environment query window was not measured directly. The production
candidate, benchmark extensions, and tests were restored. Issue 46 must not
start from or recreate this API. Any replacement proposal needs a predeclared
production consumer, an exact measurement window for that consumer, and a
whole-compiler gate that passes before downstream representation work begins.
