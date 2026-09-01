# Retain Frontend Module Facts And Delete The CLI Graph Roundtrip

**Status:** Implemented and validated

## Implementation Result

The implementation now has one invocation-local frontend product:

```text
SourceFile
  -> FinalizedTypecheckProgram
  -> FrontendModule(identity, program, source-spelled ModuleSurface)
  -> validated FrontendGraph
  -> TypecheckImportModule(program=Some, resolved ModuleSurface=Some)
```

Raw JSON and direct stage-6 requests continue to set both optional in-memory
products to `None` and use the named parse/surface fallback. No compiler
product is cached across invocations.

The CLI now carries `FrontendCompilationGraph(context, graph, diagnostics)`
directly. The parallel `FrontendModuleGraph`, `FrontendGraphSource`,
`FrontendSourceImportEdge`, and `FrontendModuleOrigin` representations,
`frontend_graph_adapter.brp`, its test, and their ownership entries are
deleted.

### Corrected Synthetic Evidence

Baseline and candidate workers were built serially from `491dff8a`. The
corrected candidate additionally uses linear identity indexes for root and
dependency projections; this avoids reintroducing a multi-root
roots-times-modules scan.

```text
baseline source/fixture hash:
  7ee41b627d2914fb5c8d6c384ac86c3b51ecc6edd4cf6c87bd731b9544daa33e
candidate source/fixture hash:
  2b3ee3dfa17566fdd6d7c90424982188766c6924e99491b218aee609399b6f8e
baseline worker:
  61e1f7c1b91b6595b070cd9e6eaaef4c6d3b96cd3bd17442bfa16e7f15a94346
candidate worker:
  fdd0f38336b1d448ca3d73d63e1625bc4fbd7dfd0b8edef3a0a9e85041d7a6d2
```

The final 10-configuration matrix used three alternating baseline/candidate
pairs per configuration. All 60 rows reported `workload_valid=True`, zero
errors, balanced allocations/releases, zero retained objects/allocator bytes,
and identical strong checksums over module identity, source path/name/text,
declaration count, and every edge importer/requested path/resolution target.

| Configuration | Baseline median us | Candidate median us | Elapsed change | Baseline allocations | Candidate allocations | Allocation change |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| chain, M=1, D=16 | 1,020 | 1,119 | +9.7% | 1,900 | 2,003 | +5.4% |
| chain, M=16, D=1 | 3,163 | 3,451 | +9.1% | 6,093 | 6,838 | +12.2% |
| chain, M=16, D=16 | 16,642 | 17,277 | +3.8% | 33,639 | 35,632 | +5.9% |
| chain, M=16, D=64 | 59,910 | 64,947 | +8.4% | 122,343 | 128,208 | +4.8% |
| chain, M=16, D=256 | 240,677 | 261,044 | +8.5% | 481,863 | 503,120 | +4.4% |
| chain, M=64, D=16 | 70,443 | 72,049 | +2.3% | 135,689 | 143,730 | +5.9% |
| chain, M=256, D=16 | 318,529 | 295,950 | -7.1% | 546,534 | 578,767 | +5.9% |
| star, M=64, D=16, F=16 | 61,486 | 66,653 | +8.4% | 124,012 | 130,223 | +5.0% |
| layered, M=64, D=16, F=16 | 93,113 | 89,429 | -4.0% | 144,918 | 154,075 | +6.3% |
| dense, M=64, D=16, F=16 | 560,719 | 121,807 | -78.3% | 279,468 | 280,061 | +0.2% |

On the dense row, exact function instrumentation reports
`module_surface_import_paths` falling from 1,016 calls to 64 calls. The
candidate constructs `module_surface_for_program` exactly 64 times, once per
module. This directly demonstrates removal of the edge-times-importer AST
projection.

The allocation increases in sparse rows are not an end-to-end compiler result:
this fixture stops after stage-4 graph discovery, so it charges the candidate
for retaining complete surfaces but never executes the stage-6 reuse or deleted
CLI conversion/revalidation path. It is useful for structural scaling and
leak checks only. Production-shaped compilation remains the acceptance source
for aggregate allocation and RSS impact.

Raw logs are ignored under `logs/issue24-frontend-reuse/matrix-final/`; the
deterministic summary is
`logs/issue24-frontend-reuse/matrix-final-summary.txt`.

### Production-Shaped Self-Compilation

One warmup and three alternating measured pairs compiled each worker's own
`blorp/src/main.brp` with `--no-format --no-embed-runtime --time-phases`
and schema-1 compiler memory checkpoints.

| Metric | Baseline samples | Candidate samples | Median change |
| --- | --- | --- | ---: |
| frontend ms | 96,127; 87,068; 103,299 | 98,183; 92,943; 101,842 | +2.1% |
| total wall seconds | 144.21; 137.80; 154.14 | 152.17; 139.25; 159.01 | +5.5% |
| final total allocations | 633,197,450 (all runs) | 632,303,228 (all runs) | -0.14% |
| frontend allocation delta | 364,446,610 | 363,755,087 | -0.19% |
| frontend live-object delta | 7,594,495 | 7,587,735 | -0.09% |
| frontend allocator-byte delta | 569,306,368 | 568,899,040 | -0.07% |
| process peak RSS bytes | 2,285,633,536; 2,331,885,568; 2,332,049,408 | 2,333,933,568; 2,333,638,656; 2,333,704,192 | +0.08% |

The host carried unrelated long-running jobs, so elapsed values are diagnostic,
not a clean speedup claim. Deterministic allocator counts show a small net
reduction and peak RSS is neutral under the issue's 3% gate. The workers compile
different compiler source trees, so their self-generated C is not expected to
be byte-identical. As an independent semantic control, both workers emitted
byte-identical C for the unchanged `empty_main.brp` fixture, SHA-256
`31d61463d4be20d026e7fa26508206c085cff548c6576fa28a86ab8fcf588281`.

Raw self-compilation logs are ignored under
`logs/issue24-frontend-reuse/self-compile/`.

### Raw Typecheck Replay Control

A single 11,580,960-byte production request captured from the baseline
compiler's `blorp/src/main.brp` was replayed through separately built baseline
and candidate typecheck workers. The request SHA-256 is
`d1a322cbff1bce3afea988185577b99c27762f7ce7610fe575d9ffb7b06bfdec`.
The worker SHA-256 values are:

```text
baseline:  def6917526dbb0539dfef84c3679a2cbb9b46e834a81e5e072a4c1e81725f4b2
candidate: e8083e8d836810f0f2a5a95b2a3676cf78d862603cf82c1c4a0ac817105baeac
```

After one warmup per worker, three alternating measured pairs all reported
`verified=true`, exit code 0, no timeout or memory-limit failure, available
allocator statistics, identical request/replay-request hashes, and the same
873,098,293-byte response with SHA-256
`b5f2fc6cb094846bb8ff94c796849c7e8bbaf5f02adefee54c46e36e4099e62e`.

| Metric | Baseline range; median | Candidate range; median | Median change |
| --- | ---: | ---: | ---: |
| elapsed seconds | 101.96-106.11; 105.01 | 103.81-106.85; 105.82 | +0.8% |
| graph parse us | 4,832,481-4,980,139; 4,889,819 | 4,869,355-5,021,997; 4,928,365 | +0.8% |
| declaration skeleton us | 3,853,185-3,913,531; 3,856,665 | 3,894,225-4,033,187; 4,020,594 | +4.3% |
| typecheck us | 6,359,529-6,805,939; 6,427,655 | 6,517,635-6,901,264; 6,680,025 | +3.9% |
| projection us | 44,950,117-47,324,321; 46,736,548 | 46,185,772-48,268,894; 46,763,061 | +0.1% |
| peak RSS bytes | 1,130,446,848-1,131,347,968; 1,130,610,688 | 1,130,299,392-1,130,676,224; 1,130,348,544 | -0.02% |
| allocations at projection | 607,688,433 | 607,688,433 | 0.0% |
| releases at projection | 598,891,207 | 598,891,207 | 0.0% |
| current objects at projection | 8,873,032 | 8,873,032 | 0.0% |
| allocator bytes at projection | 696,842,672 | 696,853,712 | +0.002% |

This bridge request contains source text rather than a compiler-owned
`FrontendGraph`, so `TypecheckImportModule.module_surface` is deliberately
`None` and the raw replay exercises the preserved ordinary fallback. It is a
semantic and regression control, not evidence for the retained-surface fast
path. Exact dense-graph function counts above and production-path structural
tests provide the retained-path evidence; the self-compilation measurements
provide the end-to-end allocation/RSS evidence. No compiler-wide elapsed-time
improvement is claimed.

Raw replay JSON and stderr are ignored under
`logs/issue24-frontend-reuse/replay/`.

### Validation Result

- `make`: passed.
- `scripts/compiler-check --changed`: passed, 22 sources, 32 suites, 508
  tests, and 5 special checks with no failures. The final added CLI regression
  brings the current affected-suite total to 509 tests.
- Focused stage-4 service, stage-6 graph typecheck, test-plan, LSP cache/index/
  query, bridge, import-plan, and native-feature suites passed.
- CLI suite: 44/44, including exact generated-root rejection messages for
  collision, duplicate binding, distinct-source ambiguity, explicit and
  implicit absence, and implicit retained-identity ambiguity.
- Formatting and `git diff --check`: passed. Ownership manifests were admitted
  by the changed compiler gate. The standalone layout check reports only the
  pre-existing unrelated top-level `compiler/` and `tests/` paths.
- Code-reviewer, test-runner, and code-optimizer verification completed; all
  blocking findings were addressed.

## Objective

Build one compiler-owned frontend module product immediately after parsing and
finalization, retain its syntactic module surface through typechecking, and make
the CLI carry the compiler-owned `FrontendGraph` directly.

The completed change must remove repeated discovery of import and module-surface
facts and delete the transitional CLI graph conversion/revalidation path. This
is reuse within one compiler invocation, not cross-invocation caching.

## Why This Issue Exists

`FrontendModule` currently retains only a resolved identity and a finalized
program:

```blorp
record FrontendModule {
	identity: ResolvedModuleIdentity,
	program: FinalizedTypecheckProgram
}
```

The compiler therefore repeatedly scans the same finalized declarations to
recover facts already available after the first parse:

1. `frontend_graph_discover` calls `module_surface_import_paths` to discover
   dependencies.
2. `frontend_graph_for_sources` calls it again for every module while checking
   that every declared import has exactly one outcome.
3. `edge_without_import_errors` calls it once per edge while checking that each
   outcome corresponds to a declared import.
4. The CLI converts the accepted compiler graph into `FrontendModuleGraph`, then
   `frontend_graph_adapter.brp` converts it back and invokes
   `frontend_graph_for_sources` again.
5. Stage 6 calls `module_surface_for_program` when constructing each accepted
   `ImportableModule`, rebuilding imports, exports, private names, and private
   trait facts.

For `M` modules and `E` import edges, the ordinary initial CLI path performs
approximately `4M + 2E` import-path projections before accounting for retained
root projections, generated roots, or direct artifact helpers. The earlier
344-module/1,619-edge self-compile inventory therefore implied about 4,614
import-path projections where one surface construction per module should have
been sufficient. The executing agent must refresh these dimensions on its
starting revision rather than treating the historical numbers as a baseline.

This repetition is not required for correctness. It is a consequence of two
incomplete ownership transitions:

- the stage-4 graph stores the AST but not its stage-4 syntactic facts; and
- the CLI still carries a parallel source/edge graph after discovery has already
  produced an accepted compiler graph.

## Existing Authority And Phase Boundaries

### Stage 3

`FinalizedTypecheckProgram` is the parser/finalizer-owned AST product. Parsing
and finalization must remain responsible for syntax and normalization only.
Do not move module resolution or graph policy into the parser.

`parser_bridge.brp` independently emits a module surface in parse-artifact JSON.
That standalone bridge is not the production graph path. It may continue to
call `module_surface_for_program`; do not couple parser-artifact serialization
to a stage-4 graph that does not exist for that API.

### Stage 4

`ModuleSurface` is already explicitly documented as a syntactic module surface.
It contains:

```text
module_name
import_paths
exports
private_names
private_traits
```

Its symbol sources use decoded declaration and method indexes. Preserving those
indexes and list orders is mandatory because later consumers map surface facts
back to parsed declarations.

`frontend_graph_discover` is the first production boundary that owns both a
finalized program and a resolved module identity. It is the correct place to
construct and retain the source-spelled surface exactly once.

### Stage 6

`prepare_typecheck_module` rewrites import declaration paths from source spelling
to canonical resolved module paths. The rewrite changes import paths only. It
does not change the module name, exports, private names, private traits, symbol
kinds, symbol order, or decoded source indexes.

Stage 6 therefore needs a resolved-path view of the retained surface, not a new
whole-program surface scan. The resolved import paths must be derived from the
validated `FrontendImportEdge` outcomes in source order. An unresolved import
retains its source-spelled path, matching the existing AST rewrite behavior.

### CLI

`FrontendModuleGraph` is a parallel graph containing `FrontendGraphSource` and
`FrontendSourceImportEdge`. `source_graph.brp` projects an accepted
`FrontendGraph` into this shape, and `frontend_graph_adapter.brp` reconstructs
and revalidates a compiler graph from it. The adapter header already calls this
transitional and says it should be deleted.

CLI planning still needs source-resolution context and setup diagnostics. Those
facts are not part of compiler graph semantics. They should live in a thin CLI
envelope around the accepted `FrontendGraph`, not in a second module/edge graph.

## Required Final Architecture

### Retained Frontend Module Product

Change `FrontendModule` to retain its source-spelled surface:

```blorp
record FrontendModule {
	identity: ResolvedModuleIdentity,
	program: FinalizedTypecheckProgram,
	surface: ModuleSurface
}
```

Use one private constructor/helper in the stage-4 graph service so production
code cannot parse a source and forget to construct its surface. The helper must:

1. parse the source once;
2. finalize it once;
3. unwrap the finalized AST once for surface construction;
4. call `module_surface_for_program` once; and
5. return the paired `FrontendModule`.

Tests that manually construct `FrontendModule` must use a focused test helper
that performs the same pairing. Do not add a fallback constructor that accepts
an AST without a surface.

### Graph Validation Index

`frontend_graph_for_sources` must validate import outcomes using retained facts.
It must not call `finalized_typecheck_program_ast` or
`module_surface_import_paths`.

Build compact indexes once per validation call:

- modules by `resolved_module_identity_storage_key`;
- declared import membership by importer identity and requested path; and
- outcome count by importer identity and requested path.

Preserve current validation order and diagnostic order:

1. structural `frontend_graph` errors first;
2. missing/duplicate outcomes in module order and each surface's import order;
3. undeclared outcomes in edge order.

Do not deduplicate repeated source imports. If the current source surface lists
the same requested path more than once, preserve the existing count and
diagnostic behavior exactly. Indexing may accelerate membership/count queries,
but it must not redefine what constitutes one declared import or one outcome.

### Resolved Surface For Typechecking

Extend `TypecheckImportModule` with:

```blorp
module_surface: Option[ModuleSurface]
```

The option is required because JSON/replay/direct bridge requests carry source
text and may not originate from a compiler-owned `FrontendGraph`.

`typecheck_request_for_frontend_graph` must populate `Some(surface)` for every
module. Before storing it, replace only `surface.import_paths` using the exact
validated edges for that module:

- process retained source import paths in source order;
- select the one matching edge by exact importer identity and requested path;
- use the target's canonical path for `FrontendResolvedImport`;
- retain the source path for `FrontendUnresolvedImport`; and
- preserve all other surface fields byte-for-byte and in the same list order.

Do not reconstruct this list from a dictionary, sort it, or derive names from
filesystem paths. Graph validation already proves one outcome for every
declared import.

The typecheck request JSON encoder must continue to omit in-memory parser
products. The decoder must set both `typecheck_program` and `module_surface` to
`None`. Production replay therefore continues to exercise the documented raw
bridge fallback; ordinary in-process CLI and LSP compilation must carry both.

Carry `Option[ModuleSurface]` through `ModuleLoadCandidate`, `LoadedModule`, and
`PreparedModule` with narrow accessors. Keep the existing
`module_load_candidate(identity, program)` constructor for direct tests and raw
bridge paths, producing `None`. Add one clearly named constructor for the
compiler-owned paired product; do not add a boolean or a parallel side table.

`importable_module` must use the retained resolved surface when present. It may
call `module_surface_for_program` only when the prepared module has no retained
surface. Parse-error recovery must retain its existing deliberately empty
recovery surface and diagnostics.

Direct typecheck-artifact helpers at the existing stage-6 fallback sites may
continue to construct a surface because they do not receive a stage-4 graph.
These exceptions must be named in tests and documentation. Do not pretend they
are production graph reuse failures.

### CLI Graph Envelope

Replace the parallel graph with one envelope. The exact final name may follow
nearby naming, but use one name consistently; the recommended shape is:

```blorp
record FrontendCompilationGraph {
	context: FrontendGraphContext,
	graph: FrontendGraph,
	diagnostics: List[String]
}
```

`FrontendGraphContext` and `FrontendSourcePackage` remain source-resolution
configuration. The following legacy semantic representations must be deleted:

- `FrontendGraphSource`;
- `FrontendSourceImportEdge`;
- `FrontendModuleOrigin`; and
- the old roots/modules/import_edges fields of `FrontendModuleGraph`.

If `FrontendModuleGraph` is temporarily retained during migration, it must be
removed before completion. Do not leave aliases, deprecated constructors, or
dual graph ownership.

Add only the narrow `FrontendGraph` accessors needed by migrated consumers:

- roots in their existing order;
- modules in their existing order;
- import edges in their existing order; and
- exact module lookup by `ResolvedModuleIdentity` if repeated callers need it.

Do not expose `FrontendGraphRep` or add generic graph mutation APIs.

### Initial CLI Discovery

`source_graph_walk_for_roots` currently calls `frontend_graph_discover`, projects
the result to CLI modules/edges, creates `FrontendModuleGraph`, then calls
`validated_cli_frontend_graph`.

Replace that sequence with:

1. build root and seed `FrontendSourceCandidate` values;
2. call `frontend_graph_discover` once;
3. return `FrontendCompilationGraph { context, graph, diagnostics }` directly.

`source_graph_modules_for_roots` may project read-only `CliParsedSourceFile`
values from retained compiler modules for its existing utility contract. Such a
projection must not reconstruct or validate a graph.

### Retained-Root Projection

Migrate `frontend_module_graph_for_retained_roots` to operate on the compiler
graph:

1. match `FrontendGraphSourceKey` against each retained module's source path and
   module name;
2. preserve the existing missing/duplicate/root ordering behavior;
3. compute the dependency closure from retained exact edges;
4. retain modules and edges in their original graph order; and
5. construct one projected compiler graph through `frontend_graph_for_sources`.

This final validation is allowed because projection creates a genuinely new
graph. It must use retained surfaces and indexed validation, so it performs no
AST surface scans. Do not roundtrip through source/edge DTOs.

### Generated Root

Migrate `frontend_module_graph_with_generated_root` without weakening any
collision, ambiguity, or error behavior:

1. parse/finalize the generated root once;
2. construct its retained surface once;
3. derive generated import requests from that retained surface;
4. resolve each explicit generated binding to an existing retained
   `FrontendModule` by exact source path/module identity rules;
5. create compiler `FrontendImportEdge` values directly;
6. combine the generated root, existing modules, and retained edges; and
7. validate the genuinely new compiler graph once.

The current generated-module origin maps to compiler `UserModule`. Preserve that
behavior unless a separate language-design issue explicitly introduces a
generated compiler origin.

### Compiler And CLI Consumers

Migrate consumers to derive source facts from `FrontendModule.program` and
origin facts from `FrontendModule.identity`:

- `compiler/pipeline.brp` must use
  `typecheck_request_for_frontend_graph`/`typecheck_compiler_frontend_graph`
  instead of rebuilding a `TypecheckGraphRequest` from legacy graph sources;
- `frontend_validation.brp` must enumerate exact compiler roots and preserve
  graph/setup diagnostic ordering;
- `native_features.brp` must inspect `resolved_module_origin` and canonical
  module identity without path/name heuristics;
- `cli_plan.brp`, `main.brp`, package checking, purify, lint, and test planning
  must carry the envelope and use retained module source fields; and
- generated test harness construction must enumerate compiler graph roots.

Do not change command behavior, batching policy, root selection, native feature
selection, package lookup, test runtime injection, or diagnostic presentation.

### Mandatory Deletion

After all consumers migrate:

1. delete `blorp/src/lib/frontend_graph_adapter.brp`;
2. delete `blorp/test/lib/test_frontend_graph_adapter.brp`;
3. remove their ownership-manifest entries;
4. delete conversion helpers in `source_graph.brp`, including graph-to-CLI edge
   projection used only by the old roundtrip;
5. delete legacy request-model records and origin conversions with no remaining
   consumer; and
6. use `rg` to prove the deleted type/function names have no production or test
   references.

The issue is not complete while both graph representations remain.

## Invariants That Must Not Change

- A source is parsed and finalized no more often because of this change.
- Module and root order remain deterministic and unchanged.
- Import edges retain source request spelling and existing edge order.
- Resolved module identity and origin are compiler-issued, never reconstructed
  from display names.
- Missing, duplicate, undeclared, unresolved, collision, and ambiguity errors
  retain exact text and ordering.
- Public/private export visibility and private-trait implementation filtering
  remain unchanged.
- Decoded declaration/method source indexes remain unchanged.
- Stage-6 AST import rewriting remains unchanged.
- Definition ID allocation and typecheck order remain unchanged.
- Native feature detection remains unchanged.
- Parse diagnostics precede rendered typecheck diagnostics exactly as before.
- JSON/replay wire formats remain byte-compatible unless an existing golden
  test proves an intentional internal-only field was serialized. The retained
  surface must not be added to request JSON.
- No cross-invocation cache, process global, mutable shared state, or filesystem
  freshness mechanism is introduced.

## Non-Goals

- Do not cache products across compiler invocations.
- Do not solve the separate CLI-root preparse/reparse issue in this change.
- Do not redesign `ModuleSurface`, visibility semantics, or import syntax.
- Do not retain typed programs, `Env`, `Scope`, or body-check state in stage 4.
- Do not optimize unrelated declaration catalog or module-view work.
- Do not change LSP workspace caching or invalidation.
- Do not serialize `ModuleSurface` into typecheck replay requests.
- Do not replace exact identities with path/name heuristics.
- Do not keep the old adapter as a compatibility shim; Blorp is pre-0.1.

## Required TDD Sequence

Follow this order. Keep each checkpoint compiling before broadening the patch.

### 1. Pin Current Behavior Before Representation Changes

Add or strengthen tests for:

- source-order import paths, including repeated paths;
- exports, private names, private traits, trait methods, implementation methods,
  foreign functions, and decoded source indexes;
- missing, duplicate, and undeclared outcome errors with exact list order;
- unresolved edge preservation;
- cycles and deterministic discovery order;
- exact resolved identity/origin across user, std, source-package, and native
  package modules;
- retained-root closure/order and exclusion of unrelated roots;
- generated-root collisions, ambiguous bindings, unresolved imports, and
  explicit source-path bindings;
- parse-diagnostic and typecheck-diagnostic ordering;
- native feature detection; and
- directory/test batching behavior.

Record the baseline checksums for graph modules, roots, edges, surfaces, and
diagnostics from deterministic fixtures. Do not obtain candidate expectations
by copying candidate output; derive them from the named fixture inputs or compare
against the unchanged baseline binary.

### 2. Add Failing Retention And Propagation Tests

Before production edits, add tests that require:

- every discovered `FrontendModule` to expose the exact source-spelled surface;
- graph validation to accept the retained surface without rebuilding it;
- typecheck request surfaces to contain canonical resolved import paths while
  all non-import fields equal the stage-4 surface;
- unresolved imports to remain source-spelled in the resolved surface;
- a compiler-graph typecheck to expose the same `TypecheckedModule.module_surface`
  as the old reconstruction;
- raw JSON/direct bridge requests to work with `module_surface = None`; and
- parse-error recovery to retain its existing empty recovery surface.

At least one fixture must contain every surface symbol category and both public
and private declarations so equality cannot pass accidentally on empty fields.

### 3. Retain The Stage-4 Surface

Implement the paired module construction and change discovery/validation to use
it. Run only stage-4 focused suites until green.

### 4. Thread The Product Through Stage 6

Add the optional bridge/candidate/loaded-module surface, resolved-path projection,
and accepted `ImportableModule` consumption. Keep raw/direct fallbacks. Run the
stage-4 and named stage-6 suites until green.

### 5. Introduce The CLI Envelope Alongside The Legacy Graph

Add `FrontendCompilationGraph`, migrate initial discovery and one compiler
pipeline consumer, and prove behavioral equivalence. This is a temporary
development checkpoint only, not a valid merge point.

### 6. Migrate Projections And All Remaining Consumers

Migrate retained roots first, then generated roots, then native features and
tool/test consumers. Keep conversion isolated while callers remain. Do not mix
unrelated cleanup into these edits.

### 7. Delete The Legacy Graph And Adapter

Delete all old types, helpers, adapter code, tests, imports, and ownership rows.
Only after deletion should the patch be formatted and broad gates run.

### 8. Measure And Document

Refresh synthetic and production measurements using the same built baseline and
candidate conditions. Do not claim compiler-wide speedup from structural counts
alone.

## File-Level Change Plan

### Production Compiler

`blorp/src/compiler/stage_04_modules/frontend_graph.brp`

- Add `surface` to `FrontendModule`.
- Add only required root/module lookup accessors.
- Keep representation opaque and graph validation semantics unchanged.

`blorp/src/compiler/stage_04_modules/frontend_graph_service.brp`

- Construct program plus surface once in `discover_frontend_source`.
- Replace AST import scans with retained surface reads.
- Add per-validation identity/import indexes.
- Preserve exact error ordering and duplicate semantics.

`blorp/src/compiler/stage_04_modules/module_surface.brp`

- Prefer no semantic changes.
- Add a narrow helper for replacing import paths only if it makes the invariant
  explicit; it must preserve every other field unchanged.

`blorp/src/compiler/stage_04_modules/loaded_module.brp`

- Carry `Option[ModuleSurface]` through candidates and loaded modules.
- Preserve the current two-argument raw/direct constructor as the `None` path.
- Add one paired-product constructor and narrow accessor.

`blorp/src/compiler/stage_06_typecheck/graph/indexed_graph.brp`

- Expose the optional retained surface through `PreparedModule` without exposing
  loaded-module representation.

`blorp/src/compiler/stage_06_typecheck/frontend_graph_typecheck.brp`

- Build resolved surfaces from validated graph edges.
- Populate `TypecheckImportModule.module_surface = Some(...)`.
- Preserve source/root/module/edge order and exact identity matching.

`blorp/src/compiler/stage_06_typecheck/bridge.brp`

- Add the optional in-memory surface field.
- Decode raw requests with `None` and omit it from JSON.
- Carry it into `ModuleLoadCandidate`.
- Keep named direct-artifact fallbacks.

`blorp/src/compiler/stage_06_typecheck/modules/module_binding.brp`

- Consume the retained surface for accepted modules.
- Keep recovery behavior and direct/raw fallback exact.

`blorp/src/compiler/frontend_request.brp`

- Retain source-resolution context/package records.
- Introduce the thin compiler-graph envelope.
- Delete old parallel graph/source/edge/origin records after migration.

`blorp/src/compiler/pipeline.brp`

- Delete legacy graph-to-typecheck request construction.
- Compile/typecheck exact roots through the compiler graph path.
- Derive source metadata from retained modules.

### CLI And Tooling

`blorp/src/lib/source_graph.brp`

- Return the compiler graph directly from discovery.
- Rewrite retained-root and generated-root operations over compiler modules and
  edges.
- Delete compiler-to-CLI-to-compiler projection helpers.
- Use retained generated-root surface instead of another import AST scan.

`blorp/src/lib/frontend_graph_adapter.brp`

- Delete after all callers migrate.

`blorp/src/lib/cli_plan.brp`

- Carry `FrontendCompilationGraph` in check/compile/run/purify/lint plans.
- Read root source metadata through compiler graph accessors.

`blorp/src/lib/frontend_validation.brp`

- Enumerate compiler roots and preserve diagnostic ordering.
- Keep request JSON behavior byte-compatible.

`blorp/src/lib/native_features.brp`

- Detect features from resolved compiler origins and canonical identities.

The mechanical fallout includes `blorp/src/main.brp`, `blorp/src/package/check.brp`,
`blorp/src/purify/command.brp`, `blorp/src/test/plan.brp`,
`blorp/src/test/command.brp`, and `blorp/src/test/generated_test_harness.brp`.
Change only graph field access and types in those files.

### Tests And Ownership

Primary suites:

- `blorp/test/compiler/stage_04_modules/test_module_surface.brp`
- `blorp/test/compiler/stage_04_modules/test_frontend_graph.brp`
- `blorp/test/compiler/stage_04_modules/test_frontend_graph_service.brp`
- `blorp/test/compiler/stage_06_typecheck/test_frontend_graph_typecheck.brp`
- `blorp/test/compiler/stage_06_typecheck/test_typecheck_bridge.brp`
- `blorp/test/compiler/stage_04_modules/test_imports.brp`
- `blorp/test/cli/test_main.brp`
- `blorp/test/lib/test_native_features.brp`
- `blorp/test/check/test_command.brp`
- `blorp/test/check/test_capture.brp`
- `blorp/test/lint/test_command.brp`
- `blorp/test/test/test_plan.brp`

Delete `blorp/test/lib/test_frontend_graph_adapter.brp`. Update
`blorp/test/compiler/compiler_test_ownership.json` for changed/new ownership and
remove deleted adapter rows. Do not create a second manifest or a parallel test
framework.

LSP already consumes the compiler graph directly, but adding `surface` to
`FrontendModule` will require focused fixture updates. Run the LSP graph,
planner, compiler-service, workspace, and protocol gates affected by ownership.
Do not change LSP invalidation or semantic-index behavior.

## Structural And Measurement Evidence

### Exact Work Counters

Before implementation, obtain exact production-path counts for:

```text
sources_parsed
frontend_modules_built
module_surfaces_built
import_path_ast_projections
graph_validation_calls
graph_validation_module_checks
graph_validation_edge_checks
legacy_graph_projection_calls
legacy_graph_adapter_calls
stage6_retained_surface_reads
stage6_surface_fallback_builds
```

Use the repository's existing exact function/LLVM instrumentation where it can
distinguish these boundaries. A temporary benchmark-only observation entrypoint
is acceptable only when exact instrumentation cannot express a logical count;
it must return primitive counts/checksums, must execute the production helpers,
and must be removed before commit unless reviewers approve durable precedent.
Do not add process globals or fields to normal persistent compiler state.

Expected candidate invariants for ordinary in-process CLI self-compilation:

```text
frontend_modules_built == discovered_module_count
module_surfaces_built == discovered_module_count
import_path_ast_projections == module_surfaces_built
legacy_graph_projection_calls == 0
legacy_graph_adapter_calls == 0
stage6_retained_surface_reads == typecheck_prepared_module_count
stage6_surface_fallback_builds == 0
```

Raw replay/direct artifact fixtures are expected to report fallback builds. Keep
their rows separate; do not mix them into the production graph invariant.

### Synthetic Matrix

Vary graph and declaration dimensions independently:

- modules: 1, 4, 16, 64, 256;
- imports per module: 0, 1, 4, 16 where topology permits;
- declarations per module: 1, 16, 64, 256;
- topologies: chain, star/fan-out, layered diamond, and dense; and
- surfaces: imports only, mixed public/private declarations, foreign functions,
  traits/private traits/impl methods, and mixed compiler-shaped declarations.

For every row record graph/module/edge/surface checksums, diagnostics checksum,
all logical counters, elapsed time, allocations, releases, current objects, and
allocator bytes. Require every baseline/candidate semantic checksum to match.

Analyze module count, edge count, and declarations per module independently.
The candidate should remove the edge-times-declaration import projection. Do not
rely on wall time alone.

### Production Replay And Self-Compilation

Because raw JSON replay intentionally lacks retained in-memory surfaces, use two
separate production measurements:

1. the existing replay verifies byte-identical typecheck behavior and fallback
   correctness; and
2. an in-process CLI self-compilation measures retained-product performance and
   proves the ordinary CLI path uses no fallback.

For replay, run a warmup and at least three alternating baseline/candidate pairs
with identical request, worker, and response hashes. Record elapsed, named
typecheck checkpoints, allocations, releases, current objects, allocator bytes,
and peak RSS. Expect correctness equivalence; do not expect replay to realize
the retained-surface saving.

For CLI self-compilation, build baseline and candidate from controlled trees
with the same bootstrap compiler. Run one warmup and at least three alternating
pairs compiling `blorp/src/main.brp` with the same options.
Require byte-identical generated C before comparing timing. Record frontend,
backend, total compiler time, wall time, allocations, releases, retained
objects/bytes, peak RSS, module/edge counts, and exact work counters.

Coordinate a clean timing window before builds or measured runs. Store raw logs
under an ignored `logs/issue24-*` directory and document worker/source hashes and
summary locations in this issue.

## Focused And Broad Validation

During implementation, run focused suites after each numbered TDD phase. Before
final review run, serially:

```bash
make
scripts/compiler-check --validate-manifest
scripts/compiler-check --stage modules
scripts/compiler-check --stage typecheck
scripts/compiler-check --changed
scripts/test compiler-blorp
scripts/test compiler-tools
scripts/test cli
scripts/test lsp
scripts/test package
scripts/test runtime
scripts/test leak
scripts/test std-check
```

Run `scripts/test compiler-blorp-sanitize` if candidate/loaded-module ownership
changes affect generated ARC behavior. Run the generated-C audit if compiler
pipeline graph types alter generated C beyond names and dead adapters.

Always run formatting, `git diff --check`, manifest validation, and a generated
artifact cleanup scan. Read generated C for the retained surface carrier and
confirm no accidental deep-copy loop is introduced at graph-to-typecheck
translation.

Use `code-reviewer`, `test-runner`, and `code-optimizer` before commit. Ask the
reviewers explicitly to inspect:

- surface source/resolved path distinction;
- repeated-import diagnostic semantics;
- raw/direct fallback isolation;
- decoded source-index preservation;
- retained/generated root behavior;
- complete deletion of the legacy graph; and
- whether any new carrier copies the complete surface per consumer.

## Acceptance Criteria

Accept only if all of the following are true:

1. every discovered production `FrontendModule` owns one paired source-spelled
   `ModuleSurface`;
2. graph discovery and validation consume retained import facts without AST
   rescans;
3. edge validation is indexed and no longer scales as edge count times importer
   declaration scanning;
4. ordinary compiler-graph typechecking consumes resolved retained surfaces and
   reports zero stage-6 surface fallbacks;
5. raw JSON/direct artifact paths remain correct through explicit fallbacks;
6. the CLI carries one compiler-owned `FrontendGraph` plus context/diagnostics,
   with no parallel module/edge representation;
7. `frontend_graph_adapter.brp`, its test, and all legacy graph DTOs are deleted;
8. diagnostic text/order, identity/origin, roots/modules/edges, surfaces,
   definition IDs, typecheck responses, and generated C are unchanged;
9. synthetic work counters show one surface build per discovered module and zero
   legacy roundtrips;
10. self-compilation allocations decrease or remain neutral with a measured
    frontend-time improvement; any retained-memory increase above 3% rejects the
    candidate pending explanation/redesign;
11. one-module/single-import workloads show no material regression; and
12. focused, broad, ownership, sanitizer-as-required, leak, CLI, package, and LSP
    gates pass.

If the final CLI envelope requires preserving a second semantic graph, stop and
report the blocker rather than weakening the deletion requirement. If retaining
the surface adds more allocation/live memory than it removes, compare whether
surface strings/lists can safely share AST-owned values; do not introduce an
unbounded cache or silently drop the retained product.

## Required Final Report

Return:

- commit SHA and exact diff scope;
- final data ownership diagram;
- deleted legacy types/functions/files;
- exact source and worker hashes;
- raw and summary measurement locations;
- synthetic matrix summary by module/edge/declaration dimensions;
- all self-compile samples and medians;
- replay identity/equivalence results;
- exact logical/function counter table before and after;
- focused and broad test pass counts;
- generated-C findings;
- reviewer/test-runner/optimizer verdicts;
- known direct/raw fallback limitations; and
- recommendation for the next compile-time bottleneck.

Do not merge or push unless the coordinator explicitly requests it.
