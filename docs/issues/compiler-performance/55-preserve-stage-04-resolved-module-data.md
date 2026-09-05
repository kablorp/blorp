# Preserve Stage 04 Resolved Module Data Through Typecheck

**Status:** Implemented by maintainer decision after matched production measurement

**Dependencies:** Issue 50 is complete. Issues 45-47 provide measurement and
representation history but do not supply a reusable broad graph-ID API. Issues
48 and 49 were rejected and must not be resurrected implicitly.

**Blocks:** Further measured reuse of graph-owned module/reference products.
Issue 51 remains independently blocked on a real production declaration-catalog
consumer.

**Parallel work:** Coordinate changes to `FrontendGraph`, direct Stage 06 graph
preparation, and import-reference validation.

## Experimental Outcome

The bounded candidate was implemented, behavior-checked, and measured. It did
not satisfy the predeclared 0.10% whole-compiler instruction gate and was
initially discarded. The maintainer subsequently directed that it be retained
because it removes a real descriptive reconstruction boundary and establishes
the graph-owned module/reference substrate for incremental follow-up work. The
measurement remains below the original gate and must not be presented as a
meaningful whole-compiler speedup.

The retained implementation:

- retained opaque module and import-reference IDs, a canonical module list,
  exact resolved/unresolved outcomes, accepted edge occurrences grouped by
  module, and direct root membership in `FrontendGraph`; source import order
  remains authoritative in each retained `ModuleSurface`;
- reused the graph validator's identity index rather than constructing an
  additional membership table;
- corrected validation so two identical source import occurrences can own two
  resolution outcomes while preserving missing, duplicate, and undeclared
  diagnostic order;
- added a direct accepted-frontend entrypoint that selected graph modules by
  ID and bypassed `frontend_module_index`, composite import-fact keys,
  `accepted_resolved_imports`, and `TypecheckGraphRequest`; and
- converged direct and replay paths immediately after `IndexedGraph`
  construction.

Exact focused tests passed before measurement:

| Suite | Result |
| --- | ---: |
| frontend graph | 10/10 |
| frontend graph service | 10/10 |
| direct/replay frontend graph typecheck | 6/6 |
| indexed graph | 14/14 |
| typecheck bridge | 110/110 |

The direct/replay suite compared typed-program JSON, canonical module-surface
order, import bindings, errors, exact diagnostic spans, dependency module
order, and the definition-ID frontier. Its adversarial row included repeated
imports and resolver edges stored in a different order from source imports.

### Matched production measurement

Both compilers were built from base commit
`5454a4bdfac7d86e088e32e2fee8b4ba91494e8d` with the same bootstrap. The
baseline compiler was built in a detached worktree; the original candidate
compiler was built from the final experimental production source. Both checked
the exact same candidate-tree `blorp/src/main.brp` workload. After one warmup
per worker, three baseline/candidate pairs ran serially with:

```bash
/usr/bin/time -lp <worker> check --no-format blorp/src/main.brp
```

| Identity | SHA-256 |
| --- | --- |
| baseline compiler | `a1e7a7f27431be0d4f0ec1a538687b9bde0eb58273a6ac7e816bb48f8bea5d6c` |
| original measured candidate compiler | `f3877977cdfa8ef0c239ddcd183a64c3af4f4fc05ee69e536f90007a2a929e97` |
| every response stdout | `c1758b804e292be62860bce968c8cee14b4b6a8fec681ff19c5318e5195c0963` |

The subsequently resurrected implementation produced compiler SHA-256
`d19ec2e7390d136ea74bd447bc9d15d03e524d6a2f7c2600cc259381b00b03e5`.
It was reconstructed from the final reviewed source captures and passed the
behavioral validation listed above, but it was not a byte-identical recovery of
the original candidate patch and was not remeasured. The measurements below
therefore describe only the original measured candidate and are not attributed
to the resurrected compiler binary.

| Pair | Baseline elapsed | Candidate elapsed | Baseline instructions | Candidate instructions | Baseline max RSS | Candidate max RSS |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 18.13 s | 17.89 s | 292,220,303,429 | 292,154,980,333 | 840,237,056 | 840,073,216 |
| 2 | 17.77 s | 18.91 s | 292,200,012,356 | 292,077,000,595 | 841,039,872 | 840,892,416 |
| 3 | 18.39 s | 19.16 s | 292,183,075,422 | 292,247,037,893 | 841,023,488 | 840,925,184 |
| median | 18.13 s | 18.91 s | 292,200,012,356 | 292,154,980,333 | 841,023,488 | 840,892,416 |

Median retired instructions improved by only 0.0154%, below the required
0.10%. Median max RSS improved by 0.0156%. Elapsed time was noisy and its
median regressed by 4.3%. Darwin `/usr/bin/time` did not expose allocator
allocation/release counts for this process, so no allocation claim is made.
Raw stdout and `time -lp` logs are ignored under:

```text
logs/issue55-matched-selfcheck/
```

The earlier apparent 11.5% elapsed improvement was rejected as evidence: its
baseline `bin/blorp` predated the exact base build. Only the matched data above
is admissible.

### Retention decision and follow-up boundary

No synthetic matrix or production replay was run after the matched production
gate failed. The replay worker consumes `TypecheckGraphRequest`, so it would
not exercise this direct frontend handoff in any case. Continuing would have
measured the wrong boundary.

The remaining work was not a mechanical extension of the candidate. The
direct path still created canonical import rewrite records, copied finalized
program/surface import paths, built `ModuleLoadCandidate` values, validated a
new `LoadedModuleSet`, and built `IndexedGraph` plus importable indexes. A safe
`LoadedModuleSet` bypass would require `IndexedGraph` to own `PreparedModule`
directly and a neutral definition-index module input. A public “trusted loaded
module” constructor was rejected because it would weaken the duplicate
identity invariant. Removing the larger remaining costs would require module
binding, CTFE dependency discovery, and visibility to consume graph reference
facts directly, which is not a bounded follow-up to this experiment.

The graph-local ID tables and direct adapter are retained by explicit maintainer
decision despite the failed performance gate. A follow-up must still isolate
one remaining reconstruction consumer, measure its whole-compiler instruction
or allocation share, and predeclare a narrow removal gate. This result is not
evidence that broader ID-table migration is automatically beneficial.

The rest of this document records the implementation contract and why the
candidate was evaluated.

## Objective

Preserve the modules and resolved import facts already produced by Stage 04
when the in-process compiler enters Stage 06. Assign graph-local integer module
and module-reference IDs during discovery, retain one authoritative module
table and reference-resolution table in the accepted `FrontendGraph`, and make
the normal compiler path consume that graph-owned data without flattening it to
canonical-path strings and reconstructing equivalent indexes.

This is reuse within one compiler invocation. It is not a cache, global module
interner, durable numeric identity, or broad rewrite of semantic IDs.

The normal direction after accepted graph construction should be:

```text
FrontendModuleId          -> modules[id]
FrontendModuleReferenceId -> references[id]
FrontendModuleReferenceId -> resolved target ModuleId, or explicit unresolved outcome
FrontendModuleId          -> references/dependencies owned by that module
```

Strings remain authoritative at source parsing, source-provider resolution,
diagnostic, replay serialization, package, and LSP boundaries. Inside the
accepted graph and its direct Stage 06 consumer, IDs should be the default and
descriptive data should be read from the module table only when needed.

## Required Reading

Before editing, read `AGENTS.md`, Issues 45-51, the graph-module-ID
roadmap, and the current versions of:

- `blorp/src/compiler/pipeline.brp`;
- `blorp/src/compiler/stage_04_modules/frontend_graph.brp`;
- `blorp/src/compiler/stage_04_modules/frontend_graph_service.brp`;
- `blorp/src/compiler/stage_04_modules/frontend_import_plan.brp`;
- `blorp/src/compiler/stage_04_modules/loaded_module.brp`;
- `blorp/src/compiler/stage_04_modules/module_surface.brp`;
- `blorp/src/compiler/stage_06_typecheck/frontend_graph_typecheck.brp`;
- `blorp/src/compiler/stage_06_typecheck/bridge.brp`;
- `blorp/src/compiler/stage_06_typecheck/graph/indexed_graph.brp`;
- `blorp/src/compiler/stage_06_typecheck/modules/module_binding.brp`;
- `blorp/src/compiler/stage_06_typecheck/modules/module_visibility.brp`;
- CLI, package, purify, lint, test, and LSP users of `FrontendGraph`; and
- the matching frontend graph, indexed graph, bridge, import, package, and LSP
  tests and compiler benchmark fixtures.

Do a fresh call-site inventory before implementation. The function and record
names below describe the current tree and are not permission to ignore newer
callers.

## Current Data Flow

### Stage 04 already computes the expensive source products once

`frontend_graph_discover` begins with roots and seed modules and performs a
deterministic pending-module walk. `discover_frontend_source` parses each newly
discovered source into `FinalizedTypecheckProgram` and computes its
`ModuleSurface`. For each surface import path, the source-provider callback
returns either an unresolved outcome or a canonical
`ResolvedModuleIdentity` plus source.

During this walk, the compiler currently maintains:

```blorp
var discovered: List[DiscoveredFrontendSource]
var discovered_by_identity: Dict[String, DiscoveredFrontendSource]
var pending: List[DiscoveredFrontendSource]
var edges: List[FrontendImportEdge]
```

This is already close to the required construction point. The missing part is
normalization: `discovered_by_identity` stores another complete source product,
and each edge repeats complete importer and target identities.

### The accepted Stage 04 graph remains descriptive

The accepted graph currently owns:

```blorp
private record FrontendGraphRep {
	modules: List[FrontendModule],
	roots: List[ResolvedModuleIdentity],
	import_edges: List[FrontendImportEdge]
}
```

`FrontendModule` already contains the canonical resolved identity, finalized
program, and module surface. These products must remain authoritative; do not
parse source or reconstruct a surface in order to assign IDs.

Graph construction and validation rebuild string-keyed membership,
identity-to-module, path-conflict, declared-import, and import-outcome indexes.
Some are temporary validation products, but the accepted graph retains none of
the useful identity-to-module or reference-to-resolution normalization.

### The normal compiler path denormalizes before Stage 06

`frontend_graph_typecheck.brp` rebuilds a
`Dict[String, FrontendModule]`, constructs composite
`identity + requested_path` string keys, rewrites module-surface import paths,
and emits a `TypecheckGraphRequest` containing:

```blorp
target: TypecheckImportModule
modules: List[TypecheckImportModule]
module_targets: List[String]
resolved_imports: List[TypecheckResolvedImport]
```

The in-process path therefore projects an already resolved graph back into the
same descriptive shape needed by the JSON replay boundary.

Stage 06 then constructs `LoadedModuleSet`, `IndexedGraph`, and
`ImportableModuleGraph`. These products create further module lists and path
indexes. `ImportableModuleGraph` currently builds both a dependency-only index
and an all-modules index. Issue 50 retained ordinal adjacency inside each
`ImportableModuleIndex`, but source requests still pass through:

```text
requested string
  -> candidate canonical-path strings
  -> canonical path-to-ordinal dictionary
  -> module list slot
```

### Replay is a real but separate boundary

`TypecheckGraphRequest` and its JSON encoder/decoder are used by the exact
typecheck replay worker. A replay capture cannot contain process-local graph
IDs without its issuing module table. The replay form must remain descriptive,
or version atomically with a self-contained module table.

This requirement does not justify making the ordinary in-process compiler
flatten and reconstruct its graph. The direct frontend path and replay path
should converge at one normalized Stage 06 preparation boundary:

```text
accepted FrontendGraph -----------+
                                  +-> normalized Stage 06 graph preparation
decoded descriptive replay request+
```

## Required Representation

The exact private record layout may follow language constraints discovered by
tests and generated C, but the semantic model must be equivalent to:

```blorp
opaque type FrontendModuleId = Int
opaque type FrontendModuleReferenceId = Int

record FrontendModuleReference {
	importer: FrontendModuleId,
	requested_path: String
}

union FrontendModuleReferenceResolution:
	ResolvedFrontendModuleReference(FrontendModuleId)
	UnresolvedFrontendModuleReference

private record FrontendGraphRep {
	modules: List[FrontendModule],
	module_ids_by_identity: Dict[String, FrontendModuleId],
	module_ids_by_canonical_path: Dict[String, FrontendModuleId],
	roots: List[FrontendModuleId],
	references: List[FrontendModuleReference],
	resolution_by_reference: List[FrontendModuleReferenceResolution],
	reference_ids_by_module: List[List[FrontendModuleReferenceId]],
	reference_ids_by_requested_path_by_module:
		List[Dict[String, List[FrontendModuleReferenceId]]]
}
```

`FrontendModuleId` is an index into this graph's `modules`. A
`FrontendModuleReferenceId` is an index into both the reference and resolution
tables. If parallel reference/resolution lists make invalid lengths too easy to
construct, use one private slot record instead. The public behavior, direct
indexed access, and exact one-outcome-per-reference invariant matter more than
the illustrative field layout.

The accepted graph constructor must prove:

1. every module ID is in bounds;
2. each accepted resolved identity maps to exactly one module ID;
3. each accepted canonical path maps to exactly one module ID;
4. every root ID names a module in this graph;
5. reference and resolution cardinalities agree exactly;
6. every reference has an in-bounds importer ID;
7. every resolved outcome has an in-bounds target ID;
8. `reference_ids_by_module` has exactly one slot per module;
9. each reference ID appears exactly once under its importer and nowhere else;
10. each requested-path index contains only references owned by that module and
    preserves duplicate-reference source order;
11. references preserve source import order; and
12. existing duplicate, conflict, reserved-path, missing-outcome, and
    undeclared-outcome diagnostics are unchanged in content and order.

Do not use `-1`, an empty string, a path hash, or an arbitrary default module
as an unresolved sentinel.

## Construction Contract

Module IDs are provisional, graph-local construction facts until graph
validation succeeds. They are not user-visible and need not be stable across
compiler invocations.

The discovery loop should perform the following in existing deterministic
order:

1. append each initial root and seed candidate in the current order;
2. assign its provisional list index;
3. populate first-identity and canonical-path validation indexes with that
   integer, retaining enough original candidate data for exact conflict
   diagnostics;
4. parse and construct the surface exactly once for each newly accepted source;
5. process each module's import paths in source order;
6. append one module-reference fact per processed import occurrence;
7. call the existing source-provider resolver exactly once for that reference;
8. record an explicit unresolved outcome, or intern the resolved target and
   record its module ID;
9. append a newly discovered target to the module table and pending queue only
   when the identity has not already been accepted; and
10. freeze the validated accumulator into one opaque graph product.

Initial duplicate roots/seeds and same-identity/different-source results must
still be diagnosable. Do not deduplicate input before capturing the evidence
needed by current diagnostics. A graph that fails validation may discard all
provisional IDs.

Populate only indexes with demonstrated readers:

- identity-to-module ID is required for interning and exact identity lookup;
- canonical-path-to-module ID is required after path uniqueness is validated;
- source-order reference IDs per importer are required for Stage 06 binding;
- the current outcome-validation/request-matching readers may use a dense outer
  module list containing requested-path-to-reference-ID dictionaries, replacing
  the current composite importer-identity string keys; and
- alias/name dictionaries remain string-keyed but should contain module IDs,
  never duplicate complete modules or canonical paths as their values.

Do not retain both the requested-path index and another equivalent global
reference dictionary. If every production reader can associate a parsed import
declaration with its graph reference by source order, omit the per-module
dictionary too. The final graph must retain only indexes with actual readers,
and every retained dictionary value must be an ID or ordered list of IDs rather
than another complete module/reference value.

## Ownership And Identity Rules

A numeric ID is meaningful only with the `FrontendGraph` that issued it.
Blorp has no dependent types, so a bare integer from one graph could otherwise
index another graph accidentally.

Required safeguards:

- IDs are constructed only by the opaque graph owner.
- APIs that dereference an ID receive the owning graph and perform checked list
  access.
- Higher-level phase products containing IDs also retain or are constructed
  from the same opaque graph owner.
- Arbitrary callers cannot forge a graph selection from a list of integers.
- Cross-graph comparisons continue to use `ResolvedModuleIdentity` or
  `ModuleIdentity`.
- Diagnostics, replay captures, artifacts, package output, and LSP semantic
  output materialize descriptive identity from `modules[id]`.
- Definition IDs, callable IDs, type-variable IDs, and declaration order are
  not derived from numeric module IDs.

Confirm in generated C that the chosen ID representation is an unboxed integer
with no retain/release or allocation per copy. If an opaque wrapper introduces
boxing, choose the narrowest phase-owned representation that remains type-safe
and document the compromise before proceeding.

## Mandatory Pre-Edit Equivalence Audit

Before changing either graph representation or publication, trace every current
consumer of `FrontendImportEdge`, `TypecheckResolvedImport`, rewritten
`ModuleSurface.import_paths`, `candidate_paths_by_request`, and
`dependency_ordinals_by_module`.

Produce a table with one row for each import source:

| Import source | Stage 04 fact | Current Stage 06 fact | Can reuse directly? |
| --- | --- | --- | --- |
| explicit bare import | exact requested spelling and resolver outcome | module lookup plus binding | prove |
| explicit qualified alias | resolved source module | local alias binding | prove module target; keep alias binding |
| explicit selective import | resolved source module | selected declaration binding | prove module target; keep declaration binding |
| compiler prelude injection | identify whether an edge exists | implicit module and name binding | do not assume |
| tuple implementation injection | identify whether an edge exists | compiler-owned ambient module | do not assume |
| unresolved source import | explicit unresolved edge | recovery diagnostic/binding behavior | prove |
| parsed recovery module | surface-dependent outcome | recovery module contents | prove |
| CTFE artifact dependency | identify graph/reference owner | artifact preparation selection | prove |

Stage 04 source-provider resolution may select the canonical source module, but
Stage 06 still owns language-level alias registration, selective-name binding,
privacy, ambiguity diagnostics, prelude filtering, and module-view conflicts.
This issue may reuse the resolved module target; it must not move those semantic
operations into Stage 04.

Stop and report before implementation if any ordinary explicit import can
resolve to a different canonical module in Stage 06 than the accepted Stage 04
edge. Do not reconcile such a mismatch with fallback lookup or a shadow cache.
For compiler-injected modules that do not have Stage 04 source references,
retain a separate explicit phase-owned input or add compiler-issued reference
facts during graph construction. Never pretend they came from source text.

## Expected File Scope

| File | Expected responsibility |
| --- | --- |
| `blorp/src/compiler/pipeline.brp` | assign/intern IDs during discovery and call the direct frontend typecheck path |
| `stage_04_modules/frontend_graph.brp` | own opaque IDs, module/reference tables, validated construction, and checked projections |
| `stage_04_modules/frontend_graph_service.brp` | validate exact import outcomes using retained reference facts |
| `stage_06_typecheck/frontend_graph_typecheck.brp` | construct the direct normalized Stage 06 input without descriptive reconstruction |
| `stage_06_typecheck/bridge.brp` | converge direct and replay inputs before shared graph preparation |
| `stage_06_typecheck/graph/indexed_graph.brp` | consume preserved module ordering/selection without rebuilding identity indexes where possible |
| `stage_06_typecheck/modules/module_binding.brp` | consume resolved target IDs while retaining Stage 06 binding semantics |
| `blorp/source_ownership.json` | map any new production module if the implementation introduces one |
| `blorp/test/compiler/compiler_test_ownership.json` | map every changed/new focused suite |
| existing graph/module benchmark fixture and runner | expose deterministic direct/replay work and cost evidence |

Do not create a new production module merely to match this table. If the shared
normalization boundary fits an existing owner cleanly, keep the smaller file
set. Ask before changing source-provider APIs, the replay schema, or any shared
semantic identity representation.

## Bounded Implementation Plan

### 1. Establish structural and semantic baselines

Before production changes, add exact tests and benchmark counters for the
current graph. Derive expected module/reference order independently from named
fixture sources. Do not use a candidate graph as the baseline oracle.

Record current counts for:

- modules parsed and surfaces constructed;
- import references processed;
- provider resolution calls;
- resolved and unresolved outcomes;
- module identity storage keys constructed;
- identity/path dictionary reads and writes;
- frontend module-index reconstructions;
- composite import-fact keys constructed;
- surface import-path rewrites;
- Stage 06 module table/index constructions; and
- importable dependency/all-index constructions.

Temporary counters must be benchmark-only or use the existing compiler
instrumentation. Do not add process globals or fields to ordinary module,
environment, typecheck-state, or semantic records.

### 2. Normalize `FrontendGraph` without changing consumers

Introduce the graph-local module/reference ID representation and construct it
during discovery and validation. Preserve the existing descriptive accessors
temporarily by projecting `FrontendModule` and `FrontendImportEdge` values from
the table. Existing CLI, package, source-graph, lint, purify, test, and LSP
callers must remain behaviorally unchanged at this checkpoint.

Add narrow ID-based accessors needed by the Stage 06 consumer. Do not expose
the private table representation or return unchecked integer lists.

### 3. Add one normalized Stage 06 preparation boundary

Separate the current `TypecheckGraphRequest` replay envelope from the internal
normalized preparation input.

- The accepted-frontend entrypoint consumes `FrontendGraph`, an exact root
  selection issued by that graph, and ordered module target selections.
- The replay entrypoint decodes descriptive source data and constructs an
  equivalent normalized graph once.
- Both paths converge before declaration indexing, import binding, CTFE
  dependency planning, and body checking.
- Do not duplicate binding or typechecking logic between the two entrypoints.

The normal compiler, lint, purify, and in-process LSP analysis paths must use
the accepted-frontend entrypoint. The request-producing function may remain
only for capture/replay or another proven external consumer.

### 4. Consume preserved module and reference facts

Cut over the direct Stage 06 path in this order:

1. select the target by graph-owned module ID rather than identity scan;
2. preserve the current target/dependency/other-root processing order as an
   explicit list of module IDs;
3. create Stage 06 prepared modules from the retained finalized programs and
   surfaces without parsing or rebuilding surfaces;
4. consume resolved import targets from the reference-resolution table;
5. retain requested source spelling for alias binding and diagnostics;
6. convert module aliases and import candidate indexes to string-to-module-ID
   values where they are still needed; and
7. use table lookup to materialize `PreparedModule`, canonical path, origin,
   or identity only at an API that still requires it.

Multiple roots require special care. Existing definition and declaration ID
allocation order is observable. The module table may remain in Stage 04
discovery order while a separate checked `List[FrontendModuleId]` carries the
existing per-typecheck processing order. Do not physically rebuild or reorder
the module table for each selected root.

### 5. Delete direct-path reconstruction

After all direct readers migrate, remove direct-path use of:

- `frontend_module_index` reconstruction;
- `resolved_import_fact_key` and its composite string keys;
- `resolved_surface_import_index`;
- `resolved_module_surface` import-path rewriting;
- `accepted_resolved_imports` reconstruction;
- conversion of module targets to canonical path strings;
- path-to-module dictionaries duplicated solely from the Stage 04 table; and
- dependency/all module-table duplication that no remaining reader needs.

Do not delete descriptive replay encoding/decoding or public descriptive graph
projections while real boundary callers remain. There must be no hidden
fallback from the direct path to the legacy reconstruction.

### 6. Reprofile and retain only a complete vertical win

Remove temporary alternate implementations and instrumentation after evidence
is captured. If the direct path still constructs both old and new tables, the
issue is incomplete even if tests pass.

## Required Tests

### Stage 04 graph ownership

Add or extend table-driven tests for:

1. empty source set where supported by the API;
2. one root with no imports;
3. roots and seeds preserving current order;
4. repeated references resolving to one module ID;
5. two different requested spellings resolving to one module ID;
6. unresolved references retaining an explicit outcome;
7. chain, star, fan-out, layered, diamond, and dense graphs;
8. duplicate imports and exact source reference order;
9. same identity and same source rediscovery;
10. same identity with different source conflict;
11. same canonical path with distinct origins;
12. reserved standard-library path conflicts;
13. missing root, importer, target, and import outcome;
14. duplicate and undeclared import outcomes; and
15. deterministic IDs and checksums under the existing deterministic discovery
    order.

Assert exact IDs only inside one fixture-owned graph. Public semantic tests
must not make numeric ID stability part of the language contract.

### Stage 06 equivalence

For every direct graph fixture, execute the accepted-frontend path and a
descriptive replay/request oracle built from the same source inputs. Assert:

- byte-identical typecheck output;
- exact diagnostic messages, help text, spans, and order;
- exact next definition-ID frontier;
- exact declaration, overload, trait, implementation, and body order;
- exact local/import visibility and privacy;
- exact module alias and selective import behavior;
- exact prelude and tuple-implementation injection;
- accepted and recovery module behavior;
- target-only, dependency, and all-root selection;
- repeated imports and diamond deduplication;
- user, stdlib, source-package, native-package, direct, anonymous, and compiler
  surface identities; and
- CTFE artifact dependency behavior.

Include at least one multi-root regression where Stage 04 table order differs
from the existing per-root Stage 06 processing order.

### Boundary and ownership coverage

Run and extend package, CLI, lint, purify, generated-test, and LSP graph tests
that consume descriptive `FrontendGraph` projections. Add leak/ownership
coverage proving that the graph releases modules, references, indexes, and
finalized parse products without cycles or retained temporary builders.

Update `blorp/test/compiler/compiler_test_ownership.json` for every new test or
production owner. Do not create a parallel test manifest.

## Benchmark And Measurement Plan

Extend the existing import graph/module binding fixture rather than creating a
second profiling framework. The fixture must execute the production Stage 04
discovery-to-Stage 06 preparation path.

Use a deterministic stratified matrix rather than the full Cartesian product.
Start from this base row:

```text
modules=64, topology=chain, imports_per_module=1, roots=1,
reference_spelling=canonical, resolution=resolved, origin=user
```

Vary one axis at a time:

```text
modules:              1, 8, 32, 128, 256
topology:             empty, chain, star, layered, diamond, dense
imports per module:   0, 1, 4, 16, all eligible
roots:                1, 4, 16 where roots <= modules
reference spelling:   canonical only, alias-heavy, mixed
resolution outcome:   all resolved, controlled unresolved recovery
origin mix:           user only, mixed stdlib/source/native/user
```

Add only the pairwise interaction rows needed to cover alias-heavy dense input,
multi-root diamond input, unresolved recovery, and mixed-origin resolution.
Generate only valid configurations and report requested versus effective
dimensions. This should remain approximately 25-35 configurations, not
thousands of combinations. Pair or alternate baseline and candidate by
configuration. Use at least one warmup and three measured pairs for 128- and
256-module sentinels.

Each row must report:

- workload validity and exact semantic checksum;
- module count, reference count, resolved count, and unresolved count;
- module-table appends and reference-table appends;
- identity/path index reads and writes;
- direct module/reference list reads;
- legacy frontend module-index builds;
- composite import-fact key constructions;
- surface import-path rewrites;
- Stage 06 module/index publications;
- parse and surface construction counts;
- diagnostics and next definition-ID frontier;
- elapsed time;
- allocations, releases, retained objects, and retained bytes;
- retired instructions and cycles where available; and
- peak RSS for production replay.

Counters must distinguish facts preserved from Stage 04 from values rebuilt by
the replay path. A modeled list length is not an exact production invocation
count.

### Production replay

If the focused sentinel passes, build matched baseline and candidate compilers
from the same source and bootstrap toolchain. Capture
`blorp/src/main.brp` once per required request schema, warm both workers, and
run at least three alternating pairs.

Require:

- byte-identical response bytes and hashes;
- identical request and bridge hashes;
- identical diagnostics and semantic counters;
- allocator statistics in every measured run;
- clean timeout and memory status; and
- compiler, worker, capture, source-patch, and generated-C hashes recorded in
  the issue.

Do not claim a compiler-wide improvement from the synthetic matrix alone.

## Original Acceptance Gates

The following gates governed the original automatic retain/reject decision.
The matched whole-compiler result failed gate 11, and the broader surface-copy
retirement in gate 5 was not completed. The later maintainer direction to keep
the bounded implementation overrides the automatic restoration rule; it does
not retroactively mark the unmet gates as passed.

All of the following are required:

1. Stage 04 parses each discovered module and computes its surface exactly once.
2. The accepted graph owns one canonical module table and one exact reference
   resolution per source import reference.
3. The normal in-process frontend-to-typecheck path performs zero
   `ResolvedModuleIdentity` storage-key constructions solely to rediscover a
   module already in that table.
4. The normal path performs zero composite importer-identity/requested-path key
   constructions solely to rediscover an accepted import edge.
5. No normal-path module surface is copied merely to replace an already
   resolved import path.
6. Module/reference IDs are unboxed integers in generated C and produce no
   per-ID allocation or retain/release work.
7. Existing source, declaration, identity, diagnostic, visibility, and ordering
   behavior is exact.
8. Direct and replay paths produce byte-identical responses for the same input.
9. At 128 modules, the focused discovery-to-preparation sentinel reduces
   either median allocations or retired instructions by at least 15%, while
   neither metric regresses by more than 5% in any representative topology.
10. At 256 modules, the candidate must not show a worse growth class for
    allocations, instructions, or identity-key construction.
11. Whole-compiler self-check improves median allocations by at least 0.10% or
    retired instructions by at least 0.10%, with neither regressing by more
    than 0.05% and no material peak-RSS regression.
12. All temporary compatibility mirrors, strategy switches, counters, and
    benchmark-only public APIs are removed before commit.

The original rule required restoration when these gates failed. The retained
implementation is an explicit exception based on architectural reuse value.
It still uses one graph representation and one shared post-`IndexedGraph`
typecheck path; no parallel graph architecture or benchmark-only API is kept.

## Fast Feedback Loop

Use this sequence and stop at the first unexplained failure:

```bash
bin/blorp test blorp/test/compiler/stage_04_modules/test_frontend_graph.brp
bin/blorp test blorp/test/compiler/stage_04_modules/test_frontend_graph_service.brp
bin/blorp test blorp/test/compiler/stage_06_typecheck/test_frontend_graph_typecheck.brp
bin/blorp test blorp/test/compiler/stage_06_typecheck/test_indexed_graph.brp
bin/blorp test blorp/test/compiler/stage_06_typecheck/test_typecheck_bridge.brp
bin/blorp test blorp/test/compiler/pipeline/test_module_binding_benchmark.brp
```

After every representation checkpoint:

1. run format and source checks for only changed `.brp` files;
2. run untimed one-module, eight-module chain, diamond, and dense fixtures;
3. compare direct/replay checksums and exact diagnostics;
4. inspect generated C for the ID representation and direct list reads;
5. run `benchmarks/compiler_module_binding_profile 1 8 4` as a smoke row;
6. run the 128-module sentinel before requesting a broad build/timing slot; and
7. stop if the candidate merely adds IDs while retaining all descriptive
   reconstruction.

When focused evidence is green:

```bash
scripts/compiler-check --changed
scripts/compiler-check --stage modules
scripts/compiler-check --stage typecheck
scripts/test lsp
scripts/test compiler-tools
scripts/test cli
scripts/test package
git diff --check
```

Run build, full matrix, sanitizer/leak gates, and production replay serially in
a coordinated clean timing window. Store raw logs under an ignored
`logs/issue55-*` directory and commit only deterministic summaries.

Use the performance workflow required by `AGENTS.md`: code-optimizer before
implementation, then test-runner, code-reviewer, and a final code-optimizer
verification before commit.

## Generated-C Inspection

Compile an executable fixture that imports the production discovery and
typecheck path. Confirm:

- module and reference IDs are emitted as plain integers;
- one accepted module table owns the retained Stage 04 module values;
- each discovered module causes at most one normal-path table append;
- each source import occurrence causes one reference append and one resolution
  write;
- accepted graph traversal uses integer list reads;
- the direct Stage 06 entrypoint does not allocate a descriptive
  `TypecheckGraphRequest`;
- no loop reconstructs `resolved_module_identity_storage_key` for every Stage
  04 module or edge; and
- no legacy and candidate module/reference tables coexist after cutover.

Read the generated functions, not merely symbol names. Record the relevant C
function names and line excerpts in the completed issue.

## Non-Goals

- No process-global module interner, cache, or persistent numeric ID.
- No change to source-provider resolution, package precedence, implicit prelude
  policy, canonical path rules, or module-origin semantics.
- No change to import syntax, alias semantics, selective imports, privacy,
  ambiguity, or diagnostics.
- No replacement of durable `ResolvedModuleIdentity`, `ModuleIdentity`,
  `TypeId`, `GlobalId`, `CallableId`, trait, implementation, artifact, or LSP
  identities.
- No migration of declaration catalogs or accepted authorities unless required
  solely to consume the preserved graph product and separately measured.
- No reordering of modules, declarations, identities, overloads, diagnostics,
  or source references.
- No integer sentinel for unresolved imports.
- No parallel generic graph framework or public access to table internals.
- No change to replay response schema unless preserving the existing schema is
  proven impossible and the coordinator approves a versioned migration.
- No compiler-wide speedup claim based only on reduced string-key counts.

## Expected Outcome

The issue should remove a specific architectural reversal: Stage 04 resolves,
parses, and indexes a module graph; the normal path then serializes that graph
conceptually into strings; Stage 06 reconstructs equivalent module and import
relationships. The completed path should preserve the accepted Stage 04 graph
as the owner of module and reference identity, while allowing diagnostics and
external boundaries to recover descriptive data through checked table lookup.

This does not complete the broader integer-ID migration. It establishes the
clean handoff needed for later Stage 06 products to replace module-keyed
dictionaries with lists without each product inventing its own ordinal
universe.
