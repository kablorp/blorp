# Normalize Qualified Module Alias Targets

**Status:** Complete

**Roadmap:** [Normalized Semantic Compilation Roadmap](NORMALIZED_SEMANTIC_COMPILATION_ROADMAP.md), Step 2b

**Depends on:** Step 2a accepted module membership (`74e9c504`)

**One-sentence packet:** Replace canonical module-path strings retained by
graph-bound qualified aliases with graph-issued `ModuleId` values, carry those
IDs through CTFE, and materialize paths only at diagnostics, JSON, and the
current Core compatibility boundary.

## Why This Is The Next Bounded Packet

Step 2a made graph-owned module visibility authoritative, but qualified imports
still copied a resolved canonical path into three `ModuleView` structures and
into the generic import-binding stream:

```blorp
private record ModuleViewRep {
	module_aliases: List[(String, String)],
	module_aliases_by_local_name: Dict[String, String],
	import_bindings: List[ImportBinding]
}

union ImportBinding:
	QualifiedModuleBinding(String, String)
	SelectiveDefinitionBinding(String, String, String)
```

The second string in every qualified binding was no longer source spelling. It
was the result of graph resolution, so using it as semantic identity repeated
hashing and string comparisons and allowed later consumers to rediscover a
module that the loader had already identified exactly. It also kept canonical
path references in the hot typed product even though `ModuleTable` already
owned the canonical row.

The entire visibility-row design is still too large for one change. Selective
imports retain source names and paths used by many value/type lookup APIs, and
introducing `SourceNameId` before those consumers can delete their strings would
increase memory. This packet therefore changes only the resolved target of a
qualified module alias. It deliberately leaves local alias spelling as a
`String` while source-level lookup is active and leaves selective-definition
normalization for Step 2c.

## Existing Semantic Rules To Preserve

- A qualified import with no explicit alias uses the request's default alias.
- Repeating the same alias for the same module is idempotent.
- Reusing an alias for another module reports the existing canonical path.
- A selective name and module alias may coexist only when they refer to the
  same module.
- Local declarations still conflict with module aliases in the same order and
  with byte-identical diagnostics.
- Standalone syntax/typecheck tools can record unresolved import spelling even
  though they do not own a loaded graph.
- Import-binding order and JSON output remain source-compatible.
- CTFE receives an exact `ModuleId`; Core currently receives a canonical path
  because its import resolver has not yet moved to graph identity.

## Target Contract

The retained alias rows distinguish graph identity from standalone recovery:

```blorp
type alias ModuleAliasBinding = (String, ModuleId)

union ImportBinding:
	GraphQualifiedModuleBinding(String, ModuleId)
	StandaloneQualifiedModuleBinding(String, String)
	SelectiveDefinitionBinding(String, String, String)

private enum ImportBindingDomain:
	NoImportBindings
	GraphImportBindings
	StandaloneImportBindings
```

`ModuleView` stores graph aliases in the dense `ModuleAliasBinding` inventory,
the exact `Dict[String, ModuleId]` index, and the graph import-binding variant.
Standalone binding has no loaded graph and therefore retains a path-backed
`Dict[String, String]` exact index plus its ordered import-binding row. It does
not retain a third ordered alias list: source order comes from the binding
stream, while type canonicalization and conflict checks query the dictionary
directly. Step 2c broadened `ModuleAliasMode` into `ImportBindingDomain`, which
prevents a view from combining graph and standalone qualified or selective
bindings.

The transient input surface carries provenance in its case rather than
allocating a second target object per import:

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

`importable_module_to_surface` is the graph-aware constructor: it takes the
definition table, ID, and validated targets from the imported module's
`PreparedModuleScope`. The public
`importable_module_surface(path, origin, surface)` constructor deliberately
creates only `StandaloneImportableModuleSurface`. A caller cannot manufacture
graph authority from path spelling alone.

## Table Provenance And Validation

Raw integer equality is not enough: unrelated module tables can both issue
zero. Graph binding therefore accepts only a state reserved for the exact
`PreparedModuleScope`; a structurally equal scope from another allocation is
rejected. Alias registration receives the active table, the issuing table, the
expected canonical path, and the ID. It verifies compatible table identity and
that the issuing table's canonical row matches the resolved path before it
retains only the ID.

The table reference is not duplicated in every `ModuleView`:
`TypecheckModuleScope`, `PreparedModuleScope`, and `BoundModuleGraph` already
retain the issuing `ModuleTable`, and consumers take the table from those graph
owners. The Step 2c binding-domain guard rejects any graph binding in a view
containing standalone bindings, and vice versa, so no later lookup has to guess
which provenance rules apply.

At later boundaries:

- bound-module joins use the graph table and `bound_module_graph_find_for_id`;
- CTFE forwards graph-qualified IDs directly and resolves only standalone or
  selective path-backed bindings;
- path projection reads the canonical row from the scope- or graph-owned table; and
- Core lowering rejects the compilation if a qualified target cannot be
  projected from the graph table.

The standalone binding is resolved by canonical path only when a consumer
explicitly supplies a table. The implementation does not store both an ID and
a path in one retained alias row.

## String-Lifetime Budget

At module-binding entry, parsed request spelling, resolved canonical paths, and
local alias names are live. They are still needed for resolution, source-order
diagnostics, and first-time-user messages.

At accepted `ModuleView` exit:

- the qualified target is a `ModuleId` in the ordered alias inventory;
- the exact graph alias index maps local spelling directly to `ModuleId`;
- `GraphQualifiedModuleBinding` carries the same ID directly;
- the issuing `ModuleTable` owns the one canonical path row;
- no qualified alias container retains a canonical path string; and
- the local alias spelling remains live because body inference still begins
  from source names.

During header resolution, qualified type dependencies and qualified global
dependencies join directly to bound-module rows by ID. Body inference still
projects a canonical path for accepted tables whose lookup APIs remain
path-keyed; that is an explicit later migration boundary, not a new authority.

At CTFE entry, qualified imports are `CtfeQualifiedModuleBinding(String,
ModuleId)`. At Core entry, Stage 06 projects the path once because
`CoreQualifiedModuleImport` is still string-based. Step 2b does not claim that
Core is string-free; it makes that remaining last-use boundary visible for a
later Core import-resolution packet.

Late strings remain classified as follows:

| String | Why it remains | Last responsible boundary |
| --- | --- | --- |
| local alias spelling | source lookup and diagnostics | after typed source references are resolved |
| selective module path/source name | selective lookup still path/name keyed | Step 2c visibility rows |
| diagnostic module path | human-facing explanation | diagnostic rendering |
| JSON module path | stable external schema | bridge serialization |
| Core module path | current Core resolver input | Core import normalization |

## Implementation Strategy

1. Add a failing graph-binding test that resolves a qualified import, inspects
   its stored graph alias row, and proves the target ID is the dependency
   scope's ID from the same indexed graph.
2. Introduce `ModuleAliasBinding` and split graph/standalone `ImportBinding`
   variants. Keep the standalone path case explicit; add no sentinel ID,
   nullable ID/path pair, string prefix, or guessed provenance.
3. Make `ImportableModuleSurface` a graph/standalone union. Carry the table and
   ID in the graph surface that already crosses the binding boundary, avoiding
   a nested heap target allocation. Keep the public surface constructor
   standalone-only.
4. Change `ModuleView` graph alias inventory and exact alias dictionary to
   carry `ModuleId`. Retain standalone paths in one exact path dictionary and
   the source-ordered import-binding stream, but delete the old third ordered
   alias list. Track a single alias mode so mixed graph/path authority is
   rejected at the construction boundary. Preserve conflict behavior by
   projecting a graph path only when a diagnostic or a same-module
   selective/alias comparison requires it.
5. Keep path-oriented state helpers as compatibility projections for the body
   inference APIs that have not yet normalized. Change qualified type
   canonicalization to consume `ModuleAliasBinding` plus its table without
   rebuilding a list of path pairs.
6. Cut qualified type-dependency, type-header, and global-header joins over
   from canonical-path dictionaries to the existing provenance-checked
   `ModuleId` lookup.
7. Change CTFE import conversion to consume graph-qualified IDs directly. Keep
   standalone and selective path lookup at this explicit boundary.
8. Project a canonical path only in the JSON bridge and Stage 09 Core resolver
   compatibility adapter. Core lowering returns an error for an invalid target
   rather than emitting a magic path.
9. Update structural fixtures and benchmark fingerprints. Fingerprints project
   the canonical row only for checksum compatibility, so parent and candidate
   verify identical semantic module selection.
10. Format, run the focused owner suites, run `scripts/compiler-check
    --changed`, then capture one direct parent/candidate measurement pair.

## Before And After

### Registration

Before, graph binding discarded exact identity and retained the path:

```blorp
typecheck_state_register_module_alias(
	state,
	alias_name,
	imported_module.module_path,
)
```

After, it preserves the already-resolved target:

```blorp
match importable_module_surface_rep(imported_module):
	GraphImportableModuleSurface(module_path, definition_table, module_id, _, _, _):
		typecheck_state_register_graph_module_alias(
			state,
			alias_name,
			module_path,
			definition_table_module_table(definition_table),
			module_id,
		)
	StandaloneImportableModuleSurface(module_path, _, _):
		typecheck_state_register_standalone_module_alias(
			state,
			alias_name,
			module_path,
		)
```

### Header join

Before:

```blorp
module_path ?= module_view_find_module_alias(view, qualifier)
module ?= bound_module_graph_find_canonical_path(bound_graph, module_path)
```

After:

```blorp
module_id ?= module_view_find_graph_module_alias(view, qualifier)
module ?= bound_module_graph_find_for_id(
	bound_graph,
	bound_module_graph_module_table(bound_graph),
	module_id,
)
```

### CTFE handoff

Before, CTFE re-resolved every qualified path:

```blorp
QualifiedModuleBinding(local_name, module_path):
	module_id ?= module_table_find_id_by_canonical_path(module_table, module_path)
```

After, graph compilation forwards the ID whose provenance was established by
the graph binder:

```blorp
GraphQualifiedModuleBinding(local_name, module_id):
	CtfeQualifiedModuleBinding(local_name, module_id)
```

## Fast Feedback Loop

The shortest red/green loop is one declaration-binding suite:

```bash
bin/blorp test blorp/test/compiler/stage_06_typecheck/test_typecheck_decl.brp
```

The next narrow checks cover representation, standalone compatibility, CTFE,
and the first ID-based header joins:

```bash
bin/blorp test blorp/test/compiler/stage_06_typecheck/test_module_view.brp
bin/blorp test blorp/test/compiler/stage_06_typecheck/test_typecheck_state.brp
bin/blorp test blorp/test/compiler/stage_07_ctfe/test_ctfe_context.brp
bin/blorp test blorp/test/compiler/stage_06_typecheck/test_type_header_dependencies.brp
bin/blorp test blorp/test/compiler/pipeline/test_type_header_graph.brp
```

Only after those pass:

```bash
scripts/compiler-check --changed
```

The measurement loop intentionally uses one direct pair per affected mode, not
a large sample matrix:

```bash
compiler-module-binding-profile 10 64 16
compiler-typecheck-phase-profile bound 1 32 4 16 16 memory
```

The first command covers standalone surface binding and exact alias lookup. The
second covers graph binding with 408 aliases. Each worker is executed directly
under macOS `/usr/bin/time -lp` so managed allocation counters, maximum RSS,
peak footprint, retired instructions, and cycles describe the isolated
workload. Wall time is recorded as a noisy guard, not promoted to a claim when
host contention is visible.

## Metric Contract

| Family | Classification | Expected signal |
| --- | --- | --- |
| focused/full latency | guard | no material regression; one-shot wall time is not a primary claim |
| managed allocations and bytes | primary | no per-alias target allocation; standalone binding should win after deleting its ordered duplicate |
| retained memory and peak RSS | primary/guard | no per-alias graph target object; standalone retains only its required exact index and ordered stream |
| retired instructions | primary/guard | standalone exact lookup should win; graph construction remains a guard because later header/CTFE joins are outside that window |
| semantic work | primary | qualified header joins use ID rows; graph CTFE performs no canonical-path lookup |
| product/native/code size | primary/guard | compact alias targets; worker and compiler artifacts within 1% |
| tooling/standalone binding cost | primary | preserve exact lookup and avoid rebuilding an alias list during source-oriented type canonicalization |

The primary mechanism families are managed allocation/retention, standalone
binding work, and semantic graph work. Graph retired instructions, artifact
size, latency, and OS peak memory are guards because the graph benchmark does
not execute the migrated header and CTFE consumers. Generated C and host C
compilation are not applicable: this is an internal compiler representation
change and emitted program C must remain byte-identical.

## Acceptance Criteria

- A graph-bound qualified alias stores `ModuleId`, not a canonical path, in its
  alias inventory, exact index, and import-binding row.
- The structural fixture compares that ID to the imported prepared scope; the
  issuing table remains owned by the existing scope/graph rather than being
  copied into every `ModuleView`.
- Standalone binding stores `StandaloneQualifiedModuleBinding(String, String)`
  plus one exact path dictionary, does not invent graph identity, and preserves
  constant-time registration and lookup without reconstructing an alias list.
- The alias inventory, exact alias index, and qualified import-binding stream no
  longer retain graph canonical-path targets.
- Qualified type-dependency, type-header, and global-header module joins use the
  bound graph's ID index.
- CTFE receives the existing graph ID directly; path lookup remains only for
  standalone and selective bindings.
- JSON and Core compatibility output preserve exact canonical paths and order.
- Alias/selective/local collision diagnostics remain byte-identical.
- Parent and candidate benchmark checksums and output counts are identical;
  generated program C remains outside this internal representation packet.
- The primary mechanism wins: graph alias paths are deleted from every retained
  graph alias authority, qualified headers and CTFE no longer rediscover graph
  IDs, no per-alias target allocation remains, and standalone registration and
  lookup retain their exact dictionary. The standalone guard improves managed
  operations, retained memory, and retired instructions; graph construction
  remains within the resource thresholds. Any artifact threshold crossing is
  investigated and documented against the full compiler artifact.
- Focused tests and the manifest-owned changed gate pass.
- Raw results and the accept/reject decision are checked in before the roadmap
  marks Step 2b complete.

## Measured Result

Both final pairs matched their semantic checksums and deterministic work. The
standalone binding guard improved allocations by 2.8116%, releases by 2.7585%,
retained objects by 4.3919%, retained bytes by 4.5726%, and retired instructions
by 0.7331%. Its RSS, peak footprint, and cycles also moved downward. This proves
the exact standalone dictionary removes the quadratic lookup hazard without
restoring the old ordered duplicate.

In the graph pair, allocations, releases, and retained objects were exactly
neutral. Retained bytes grew by 264 bytes (0.2820%), retired instructions by
0.2034%, RSS by 0.5413%, and peak footprint by 0.3606%; cycles improved by
0.5571%. The graph worker grew by 0.5556% and the full compiler by 0.0973%, both
inside the 1% artifact threshold.

The specialized standalone worker grew by 17,888 bytes (1.0149%), crossing the
investigation threshold by 0.0149 percentage points. Inspection attributes the
absolute increase to compiling both explicit graph/standalone binding variants
and provenance checks into this narrow worker, while the actual full compiler
grew only 18,720 bytes (0.0973%). The worker's managed memory and instruction
wins are substantially larger, so this narrowly explained guard crossing is
accepted rather than weakening the representation.

The first measured representation retained one heap record per alias and was
rejected immediately: it added exactly 408 retained objects and 13,056 retained
bytes for the fixture's 408 alias rows. A second design removed that retained
record but still allocated one transient target per alias. The accepted design
folds provenance into `ImportableModuleSurface`, stores the graph alias row as
an inline named tuple, and keeps standalone paths in one exact dictionary plus
the import-binding stream. That removed the remaining 408 transient graph
allocations and releases. The final exact standalone dictionary then removed
the review-discovered linear scans without restoring the old ordered alias
list.

The graph benchmark's managed-memory window covers bound-stage construction.
It does not execute the qualified header or CTFE consumers, so their eliminated
path lookups are structural and direct-test evidence, not an attribution for
the measured instruction delta. One-shot wall time and the short internal
windows were noisy and support no latency claim. See
[`compiler_module_alias_targets_step2b_2026-09-10.md`](../../../benchmarks/results/compiler_module_alias_targets_step2b_2026-09-10.md)
for raw counters, hashes, commands, and interpretation.

## Rollback Rule

Reject or narrow the packet if the graph view must retain both the canonical
path and `ModuleId`, if a consumer silently falls back to path hashing for a
semantic join, if diagnostics or bridge output drift, or if deterministic
resource metrics regress materially. Do not hide a regression by adding a
global string interner or preserving a parallel path-keyed alias authority.

## Next Packet

Step 2c is complete in
[`70-normalize-selective-definition-targets.md`](70-normalize-selective-definition-targets.md).
It normalizes ordinary graph selective-definition bindings to exact module and
definition identities without prematurely introducing a source-name table.
Step 2d should normalize the remaining visibility rows, determine the last
source-resolution consumer of local alias spelling, and remove the current
Stage 09 path/name projection when Core can consume exact import targets.
