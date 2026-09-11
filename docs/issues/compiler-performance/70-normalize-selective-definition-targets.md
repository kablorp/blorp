# Normalize Selective-Definition Targets

**Status:** Complete

**Roadmap:** [Normalized Semantic Compilation Roadmap](NORMALIZED_SEMANTIC_COMPILATION_ROADMAP.md), Step 2c

**Depends on:** Step 2a accepted module membership (`74e9c504`) and Step 2b exact qualified module aliases (`e5fb245d`)

## Outcome

Ordinary selective imports in a graph-owned compilation now retain the
semantic result of import resolution:

```blorp
GraphSelectiveDefinitionBinding(
	local_name: String,
	module_id: ModuleId,
	definition_ids: List[DefinitionId],
)
```

The replaced graph row stored `module_path` and `source_name`. Those strings
were useful while resolving the source import, but became redundant join keys
once the compiler had selected a prepared module and its exact exported
definitions. The new row retains one module identity and the ordered overload
set issued by the same compilation's `DefinitionTable`.

Two deliberately explicit exceptions remain:

```blorp
GraphSelectiveTraitMethodBinding(String, ModuleId, String)
StandaloneSelectiveDefinitionBinding(String, String, String)
```

`TraitMethodId` is issued after this binding boundary. A graph trait-method
row therefore keeps its source name rather than pretending it owns a generic
`DefinitionId`. Standalone compilation has no graph identity tables, so its
compatibility row remains path/name backed. These variants make the remaining
string lifetimes visible and give Step 2d concrete deletion targets.

## Context

Step 2b normalized qualified imports to `ModuleId`, but selective imports still
crossed typechecking as `(module_path, source_name)`. Late consumers could
therefore repeat resolution from descriptive text, and the row could not prove
that the selected spelling belonged to the active module and definition
domain. An overloaded function also means a single `DefinitionId` is not
sufficient: the semantic target is an ordered, nonempty list.

The accepted module surface and the definition table describe different facts.
The surface determines whether a declaration is public and what public kind it
has. The definition table supplies exact identity and provenance. Step 2c joins
both once, at the importable-module boundary, and publishes only validated
targets.

## Representation And Provenance

The transient surface is opaque. Callers cannot combine a module identity from
one graph with exported targets from another:

```blorp
private union ImportableModuleSurfaceRep:
	GraphImportableModuleSurface(
		String,
		DefinitionTable,
		ModuleId,
		ModuleOrigin,
		ModuleSurface,
		ExportedDefinitionTargets,
	)
	StandaloneImportableModuleSurface(String, ModuleOrigin, ModuleSurface)

opaque type ImportableModuleSurface = ImportableModuleSurfaceRep
```

`ExportedDefinitionTargets` is also opaque. Its constructor is private to the
definition index, so arbitrary surface symbols and definition IDs cannot be
paired outside the validating join.

An ordinary graph binding is accepted only when:

1. the active and issuing `DefinitionTable` share provenance;
2. `module_id` projects to the accepted canonical module path;
3. `definition_ids` is nonempty;
4. every ID exists in the issuing table;
5. every ID belongs to `module_id`; and
6. every ID projects to the expected source name.

The export join additionally checks public surface kind and exact source span.
This excludes private declarations, record fields, and unrelated same-named
implementation rows that happen to share a module/name bucket. Public
implementation methods remain callable exports and receive exact IDs.

Nested constructors use an owner-aware query:

```blorp
definition_index_constructor_definition_ids_for_export(
	index,
	issuing_table,
	module_id,
	constructor_name,
	union_name,
)
```

This prevents `First(Shared)` from selecting `Second.Shared`. A missing nested
constructor produces a source diagnostic at the import, not an internal
invariant failure.

## Sparse Export-Target Index

Step 2c does introduce one new normalized lookup product; it does not copy the
whole definition table. `ImportableModuleGraph` first collects the source names
used by selective imports in its accepted scopes. Each prepared module then
indexes only public exports whose spelling occurs in that graph-wide request
set. Registration becomes an exact map lookup instead of rescanning a module's
declarations for every importer.

The graph-wide spelling filter may index the same spelling in more than one
module. Exact module selection still happens before publication, so this is a
bounded construction optimization rather than semantic ambiguity. The public
single-scope `importable_module` adapter passes `None` and builds all public
targets because it has no whole-graph request inventory. The standalone
surface constructor has no definition index and builds none.

Qualified-only graphs take a zero-work path:

```blorp
match requested_names:
	Some(names):
		if names.is_empty():
			Some(EXPORTED_DEFINITION_TARGETS_EMPTY)
		else:
			build_requested_export_targets(...)
	None:
		build_all_export_targets(...)
```

The shared empty value avoids an export scan and one retained empty map per
module.

## Trait Methods And Binding Domains

Trait methods are selected from the explicit `TraitMethodSurfaceSymbol` case.
A trait-only import publishes `GraphSelectiveTraitMethodBinding`; it does not
silently turn an empty ordinary-definition lookup into a trait method. If one
spelling denotes both a trait method and an ordinary public function, the
ordinary function receives exact definition IDs while the trait visibility row
retains its explicit source spelling.

`ModuleView` also records one `ImportBindingDomain`:

```blorp
private enum ImportBindingDomain:
	NoImportBindings
	GraphImportBindings
	StandaloneImportBindings
```

Graph and standalone selective/qualified bindings cannot be mixed in one view.
Late consumers never need to guess which provenance rules apply.

## Downstream Data Flow

```text
parsed selective import
        |
        v
accepted public ModuleSurfaceSymbol + exact source span
        |
        v
sparse ExportedDefinitionTargets + DefinitionTable provenance
        |
        +-- ordinary --> GraphSelectiveDefinitionBinding(ModuleId, [DefinitionId])
        |
        `-- trait method --> GraphSelectiveTraitMethodBinding(ModuleId, source name)
                    |
                    +--> Stage 07 retains ModuleId/[DefinitionId]
                    |    but projects the name for its current string-keyed global env
                    +--> Core consumes [DefinitionId] directly (Step 2d)
                    `--> typed JSON projects public spelling at the external boundary
```

CTFE no longer resolves a graph selective module path from a string. Its
binding carries `ModuleId` and definition IDs, but imported-global lookup is
still source-name keyed and therefore calls
`definition_table_selective_definition_name`. This is partial normalization,
not a claim that CTFE is string-free.

Typed JSON preserves its public behavior by projecting a canonical path and
source name from the authoritative tables. Core's initial Step 2c compatibility
projection was removed by
[`71-normalize-core-selective-definition-targets.md`](71-normalize-core-selective-definition-targets.md).
The graph JSON test continues to assert the projected `answer / dep / answer`
binding at that external boundary.

## Implementation Strategy

The bounded implementation sequence was:

1. Add a surface traversal that pairs public surface symbols with exact parsed
   source spans.
2. Build an opaque exported-target map from surface kind/span and definition
   table rows.
3. Collect graph-wide requested selective spellings and keep the map sparse.
4. Split ordinary graph, trait-method graph, and standalone binding variants.
5. Validate table provenance, module ownership, name, and nonempty ID lists at
   `ModuleView` construction.
6. Add owner-aware constructor resolution and user-facing invalid-constructor
   diagnostics.
7. Correct the formatter's invalid internal import that grouped three
   `FunctionBody` constructors under the unrelated `Declaration` union; exact
   constructor ownership intentionally rejects that old source shape.
8. Carry exact ordinary bindings through CTFE, projecting strings only where
   existing Core, JSON, and CTFE-global APIs still require them.
9. Seal graph/standalone construction and binding domains with opaque products
   and an explicit domain enum.

An eager first design indexed every export of every accepted module. The
isolated importable-phase screen exposed the mistake immediately: allocations
rose 85.6%, retained objects 42.7%, and allocated bytes 39.2%. That design was
discarded. The sparse request filter reduced the final deltas to +3 allocations,
+3 releases, unchanged retained objects, and +0.30% allocated bytes across 33
module slots. A second small feedback pass found that qualified-only graphs
were retaining 33 empty maps; the shared-empty fast path removed all 33.

## Code Examples

Graph registration validates, then publishes, one exact row:

```blorp
if (
	definition_tables_share_provenance(active_table, issuing_table)
	and module_table_canonical_path(module_table, module_id) == Some(module_path)
	and definition_table_selective_definition_name(
		issuing_table,
		module_id,
		definition_ids,
	) == Some(source_name)
):
	GraphSelectiveDefinitionBinding(local_name, module_id, definition_ids)
```

Step 2c initially used this compatibility projection:

```blorp
GraphSelectiveDefinitionBinding(local_name, module_id, definition_ids):
	module_path ?= module_table_canonical_path(module_table, module_id)
	source_name ?= definition_table_selective_definition_name(
		definition_table,
		module_id,
		definition_ids,
	)
	Some(CoreSelectiveDefinitionImport(local_name, module_path, source_name))
```

Step 2d changed the Core consumer contract and deleted this projection. The
replacement passes `definition_ids.map(definition_id_runtime_value)` directly;
see
[`71-normalize-core-selective-definition-targets.md`](71-normalize-core-selective-definition-targets.md).

## Fast Feedback Loop

The implementation loop is intentionally smaller than the final gate:

```bash
make -j2
bin/blorp test blorp/test/compiler/stage_06_typecheck/test_definition_index.brp
bin/blorp test blorp/test/compiler/stage_06_typecheck/test_frontend_graph_typecheck.brp
bin/blorp test blorp/test/compiler/stage_06_typecheck/test_typecheck_state.brp
bin/blorp test blorp/test/compiler/stage_07_ctfe/test_ctfe_context.brp
bin/blorp test blorp/test/compiler/pipeline/test_ctfe_global_eval.brp
```

The retained performance loop uses one baseline/candidate pair, not repeated
wall-time sampling:

```bash
BLORP_BENCHMARK_CACHE_DIR=/tmp/blorp_step2c_cache \
	benchmarks/compiler_typecheck_phase_profile importable 1 32 4 16 16 memory

/usr/bin/time -lp bin/blorp check --no-format \
	blorp/benchmark/compiler/selective_import_graph_fixture/main.brp
/usr/bin/time -lp bin/blorp check --no-format \
	blorp/benchmark/compiler/selective_import_graph_fixture/qualified_main.brp
```

The isolated phase reports deterministic allocation/release/retained counts.
The two static fixtures distinguish a 32-name selective import from a
qualified-only import over the same dependency. Retired instructions, cycles,
RSS, peak footprint, and compiler size are guard metrics. One-shot wall time is
not used for acceptance. Once the narrow loop is stable, run exactly one broad
owner gate:

```bash
scripts/compiler-check --changed
```

## Acceptance Criteria

- [x] Every ordinary graph selective import retains an exact `ModuleId` and a
  nonempty ordered `DefinitionId` set.
- [x] Publication validates one issuing `DefinitionTable`, exact module owner,
  source name, public kind, and source span.
- [x] Overloads preserve source order and exclude private/same-name collisions.
- [x] Nested constructors use exact union ownership and invalid selections
  produce a user-facing diagnostic.
- [x] The formatter's mismatched internal constructor import is migrated to
  the owning `FunctionBody` union and its focused suite passes.
- [x] Trait methods use an explicit graph variant; a same-name ordinary export
  still retains its exact IDs.
- [x] Graph and standalone import binding domains cannot mix.
- [x] CTFE removes the graph module-path lookup and honestly retains its current
  name projection for imported-global lookup.
- [x] Core and JSON project strings from authoritative tables only at their
  compatibility boundaries; graph JSON projection has direct test coverage.
- [x] Standalone adapters remain explicit and do not perform a graph scan.
- [x] Qualified-only graphs perform no export scan and retain no per-module
  empty target map.
- [x] Semantic checksums, diagnostics, typed output, and CTFE results remain
  exact in focused tests.
- [x] Final deterministic retained objects are neutral; allocation work and
  bytes are within 0.31% of Step 2b in the isolated importable phase.
- [x] Selective and qualified compiler-level retired-instruction, RSS, and peak
  footprint screens have no regression at or above 1%; unstable cycle samples
  are reported but are not acceptance evidence.
- [x] Full compiler size remains within the 1% guard.
- [x] The changed-owner compiler gate passes: 12 production owners, 31 focused
  suites, five special checks, and zero failures.

## Measurements

The immutable baseline is Step 2b commit `e5fb245d`. One final baseline/candidate
pair is retained for each workload. Deterministic phase counters are primary;
no wall-time claim is made.

| Metric | Step 2b | Step 2c | Change |
| --- | ---: | ---: | ---: |
| importable allocations | 7,571 | 7,574 | +0.0396% |
| importable releases | 2,666 | 2,669 | +0.1125% |
| importable retained objects | 4,905 | 4,905 | 0 |
| importable allocated bytes | 350,008 | 351,064 | +0.3017% |
| selective retired instructions | 2,982,777,919 | 2,991,086,966 | +0.2786% |
| selective cycles | 750,098,727 | 755,759,311 | +0.7546% |
| selective maximum RSS | 31,195,136 | 31,326,208 | +0.4202% |
| selective peak footprint | 25,182,592 | 25,166,160 | -0.0653% |
| qualified retired instructions | 2,980,259,190 | 2,986,354,435 | +0.2045% |
| qualified cycles | 744,464,465 | 765,998,030 | +2.8925% |
| qualified maximum RSS | 31,145,984 | 31,358,976 | +0.6839% |
| qualified peak footprint | 25,100,624 | 25,215,336 | +0.4570% |
| full compiler bytes | 19,264,128 | 19,300,176 | +0.1871% |

The importable semantic checksum remained `3225153837847304234`; its
constructor checksum remained `4522423758094903886`. The one-shot importable
window changed from 1,773 to 1,844 microseconds (+4.0%), which is recorded but
not accepted as a clean latency measurement. Qualified cycles likewise moved
from -1.40% to +2.89% across same-binary screens while retired instructions
remained below +0.21%; cycle count is therefore treated as host noise, not a
compiler regression or improvement. Raw commands, hashes, and counters are in
[`compiler_selective_definition_targets_step2c_2026-09-11.md`](../../../benchmarks/results/compiler_selective_definition_targets_step2c_2026-09-11.md).

## Next Packet

Step 2d completed the bounded Core cutover to exact definition identities.
Step 2e should now normalize Stage 06 visibility rows and identify the last
source-resolution consumer of local alias spelling. It should introduce a
compilation-local source-name identity only where that table deletes retained
strings. CTFE's string-keyed imported-global environment, trait-method identity,
and qualified Core lookup should migrate as independently measured consumers of
that table rather than expanding one packet across several phase boundaries.
