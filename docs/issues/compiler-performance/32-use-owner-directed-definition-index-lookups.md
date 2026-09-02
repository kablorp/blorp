# Use Owner-Directed Definition-Index Lookups

**Status:** Completed by `8c42de27`

## Objective

Stop resolving a type-definition reference by collecting every source
definition with the same name from every loaded module. Use the existing
`DefinitionIndex` module and name dimensions to query only the known owner's
bucket, then validate the exact definition kind and module identity inside that
small bucket.

This is a bounded Stage 06 performance and code-quality change. It should
remove a measured graph-wide scan, temporary list construction, and sorting
without changing definition-ID assignment, module visibility, name resolution,
diagnostics, or the index representation.

## Required Reading

Before editing, read:

1. `docs/LEARN_BLORP_IN_Y_MINUTES.md`;
2. the Stage 06 portion of `docs/ARCHITECTURE.md`;
3. `blorp/src/compiler/stage_06_typecheck/graph/definition_identity.brp`;
4. `blorp/src/compiler/stage_06_typecheck/graph/definition_index.brp`;
5. `blorp/src/compiler/stage_06_typecheck/graph/indexed_graph.brp`;
6. `blorp/src/compiler/stage_06_typecheck/state.brp`; and
7. `blorp/src/compiler/stage_06_typecheck/type_occurrence.brp`.

Read the existing definition-index unit test and benchmark before designing a
new fixture:

- `blorp/test/compiler/stage_06_typecheck/test_definition_index.brp`;
- `blorp/test/compiler/pipeline/test_definition_index_benchmark.brp`; and
- `blorp/benchmark/compiler/compiler_definition_index_profile_fixture.brp`.

## Profile Evidence

The Phase 01-06 self-check profile at revision
`db73f12416f3593f32ccc4701e8dd134c6573baa` ran:

```bash
blorp/build/_build/blorp-cli/blorp check --no-format blorp/src/main.brp
```

The unsampled run took 52.077 seconds. A macOS `sample` run collected 47,026
samples at 1 ms, and LLVM instrumentation supplied exact function-entry counts.

`definition_index_source_definition_bindings` accounted for:

- 1,666 samples;
- 3.5427% of Phase 01-06 samples; and
- 75,233 exact calls.

The raw profile and report are under the ignored directory:

```text
logs/compiler-through-typecheck-profile-2026-09-02-db73f124/
```

The measured percentage is an upper bound, not a promised speedup. The change
should remove most of this function's work, but total latency also includes
parsing, graph construction, header completion, environment construction, and
body inference.

## Definition-Index Construction And Ownership

`DefinitionIndex` is already a graph-wide product. It is constructed once when
the accepted `LoadedModuleSet` becomes an `IndexedGraph`.

`definition_index_for_loaded_modules` receives:

- the target `LoadedModule`;
- every loaded dependency module;
- each module's exact `ModuleIdentity` and `ParsedProgram`; and
- a `DefinitionIndexSeed` whose allocation frontier follows compiler builtins.

It processes the target first, then dependencies sorted by canonical path, so
definition-ID assignment is deterministic rather than discovery-order
dependent. It walks parsed declarations and reserves IDs for functions,
foreign functions, types, constructors, fields, aliases, traits,
implementations, explicit/default methods, and globals.

Each non-callable source definition is represented by a
`SourceDefinitionKey` containing:

```text
module identity + definition kind + name + optional owner + source span
```

The source-definition portion of `DefinitionIndexRep` is already organized as:

```blorp
Dict[String, Dict[String, List[SourceDefinitionIdEntry]]]
```

Conceptually:

```text
module search bucket
    -> declaration name
        -> exact key/definition-ID collision bucket
```

The outer module string and declaration name are search accelerators. Exact
key or identity comparison remains required because diagnostic display names
are not globally unique identity keys, and multiple declaration categories can
share a spelling.

Every `PreparedModuleScope` retains the same `IndexedGraph`, and therefore the
same `DefinitionIndex`. Do not build or cache another index for this issue.

## Current Problem

`type_occurrence.brp` resolves a parsed type spelling to the definition ID used
by semantic navigation. At that point it already knows either:

- the exact local `ModuleIdentity`; or
- the imported module's canonical path, resolved from a qualified or selective
  import.

Despite that owner information, `type_definition_id_for_owner` currently calls:

```blorp
for binding in typecheck_state_source_definition_bindings_for_name(state, name):
	-- Filter the graph-wide result back down to the already-known owner.
```

The state helper is a passthrough to:

```blorp
pure func definition_index_source_definition_bindings(
	index: DefinitionIndex,
	name: String,
) -> List[(SourceDefinitionKey, Int)]:
	var bindings: List[(SourceDefinitionKey, Int)] = []

	for name_buckets in index.source_definition_ids_by_module_bucket_and_name.values():
		for entry in name_buckets.get_or(name, []):
			bindings = bindings.append((entry.key, entry.def_id))

	bindings.sort_by(func(binding): binding[1])
```

Thus a request equivalent to “find type `Widget` in module X” performs:

1. enumeration of every module bucket;
2. a name lookup in every module;
3. allocation and repeated growth of a combined result list;
4. sorting by definition ID; and
5. a second pass that discards entries not owned by X or not representing a
   type.

The desired operation is already supported by the index's physical shape:

1. select X's module bucket;
2. select the `Widget` name bucket;
3. validate exact owner identity/path and `TypeDefinition` kind; and
4. return the unique matching ID.

The complexity should change from approximately:

```text
O(module count + same-name matches + result sorting)
```

to:

```text
O(1) expected dictionary lookup + O(small collision bucket)
```

The collision bucket is normally one entry. It must still be checked rather
than assumed to contain a unique type.

## Required Design

### 1. Add owner-directed type-definition queries

Add focused queries at the `DefinitionIndex` abstraction boundary. Exact names
may be adjusted to match local conventions, but distinguish exact identity
from loaded canonical-path lookup in the type system rather than with boolean
flags or paired options.

Illustrative API:

```blorp
pure func definition_index_find_type_definition_id(
	index: DefinitionIndex,
	module_identity: ModuleIdentity,
	name: String,
) -> Option[Int]


pure func definition_index_find_loaded_type_definition_id(
	index: DefinitionIndex,
	canonical_path: String,
	name: String,
) -> Option[Int]
```

The first query should derive the same outer search bucket used when the entry
was inserted, then require `module_identities_equal` and `TypeDefinition`.

The loaded-path query may use the canonical path to select the outer bucket
because `LoadedModuleIdentityRep` deliberately exposes that path as its display
name. It must then use `module_identity_matches_canonical_path` on the entry;
it must not treat an arbitrary display string as semantic identity. Direct,
surface, and anonymous identities must not match a loaded canonical-path query.

Both queries must preserve the existing uniqueness behavior. Return `Some(id)`
only when exactly one matching type definition exists; return `None` for zero
or multiple matches. Do not silently choose the first duplicate.

A shared private helper may avoid duplicating bucket traversal, but do not add
a public generic callback API solely for these two call sites.

Illustrative internal shape:

```blorp
private pure func type_definition_id_in_entries(
	entries: List[SourceDefinitionIdEntry],
	matches_owner: (ModuleIdentity) -> Bool,
) -> Option[Int]:
	var result: Option[Int] = None
	var matches: Int = 0

	for entry in entries:
		key = entry.key

		if (
			source_definition_key_kind(key) == TypeDefinition
			and source_definition_key_owner(key).is_none()
			and matches_owner(source_definition_key_module_identity(key))
		):
			result = Some(entry.def_id)
			matches += 1

	if matches == 1:
		result
	else:
		None
```

This sample describes behavior, not a requirement to allocate a closure. If a
closure appears in generated hot-path code, prefer two small explicit loops or
an internal owner union with data-carrying variants.

### 2. Route semantic type-occurrence lookup through the new queries

Refactor `resolved_type_definition_id` so each valid branch calls the precise
query directly:

```blorp
private pure func resolved_type_definition_id(
	state: TypecheckState,
	visible_name: String,
	qualified_module: Option[String],
) -> Option[Int]:
	index = typecheck_state_definition_index(state)

	match qualified_module:
		Some(module_alias):
			module_path ?= typecheck_state_find_module_alias(state, module_alias)
			definition_index_find_loaded_type_definition_id(
				index,
				module_path,
				visible_name,
			)
		None:
			match typecheck_state_find_imported_name(state, visible_name):
				Some(imported):
					definition_index_find_loaded_type_definition_id(
						index,
						imported.module_path,
						imported.original_name,
					)
				None:
					definition_index_find_type_definition_id(
						index,
						typecheck_state_module_identity(state),
						visible_name,
					)
```

Use syntax accepted by the current compiler; the `?=` expression above is
illustrative. Preserve the existing qualified, selectively imported, renamed,
and local lookup behavior exactly.

### 3. Delete accidental indirection and invalid intermediate states

As part of this focused cutover:

- remove `typecheck_state_source_definition_bindings_for_name` if it has no
  remaining semantic consumer;
- reuse the existing `typecheck_state_definition_index` boundary rather than
  replacing the removed passthrough with two new passthrough getters;
- remove `local_type_binding_matches` and `imported_type_binding_matches` when
  their behavior is owned by the new index queries;
- remove `type_definition_id_for_owner` and its pair of
  `Option[ModuleIdentity]` / `Option[String]` parameters if direct branching
  makes it unnecessary; and
- do not preserve dead helpers for compatibility. Blorp is pre-0.1.

The paired options currently admit meaningless combinations: both set, both
absent, local identity paired with imported path, and so on. The new control
flow should make those states unrepresentable without inventing a new public
type.

### 4. Keep broad projections out of semantic hot paths

`definition_index_source_definition_bindings` is useful for deterministic
diagnostics, tests, and tooling that genuinely ask for all modules. It does not
need to be deleted if those consumers remain.

Clarify its comment so future semantic code does not treat it as the normal
lookup API. The Phase 01-06 production path must no longer call it.

## Correctness Requirements

- Definition-ID allocation order and values must not change.
- `DefinitionIndexRep` and its insertion path must not gain another map.
- A local type reference resolves only to the current exact `ModuleIdentity`.
- A qualified import resolves through the alias to its loaded canonical path.
- A selective or renamed import resolves the original declaration name in the
  imported module.
- Same-named types in different modules resolve to their respective IDs.
- Constructors, fields, globals, traits, and implementations sharing a name
  cannot be returned as a type definition.
- Duplicate matching type definitions must fail closed with `None`, preserving
  current ambiguity behavior.
- Loaded canonical-path lookup must not match direct, surface, or anonymous
  identities that merely have similar display text.
- Existing semantic-index output, source spans, and LSP navigation must remain
  unchanged.
- Error text and diagnostic ordering must remain unchanged.
- Do not infer identity kinds from string prefixes or filenames.

## Test-First Plan

### Definition-index tests

Add failing tests for the new API to
`blorp/test/compiler/stage_06_typecheck/test_definition_index.brp` before the
implementation. Cover:

1. exact identity lookup of a local type;
2. canonical-path lookup of a loaded dependency type;
3. two modules declaring the same type name and returning different IDs;
4. a constructor, field, global, or trait with the same spelling not matching;
5. a missing module, name, and type kind returning `None`;
6. duplicate matching type entries returning `None`; and
7. direct/surface/anonymous identities not matching a loaded-path query.

Prefer extending existing loaded-module fixtures over adding another fixture
framework.

### Semantic occurrence and LSP tests

Extend the existing semantic-index owner only where coverage is missing:

- an unqualified local type;
- `module_alias.Type`;
- a selectively imported type;
- a selectively renamed type;
- the same type spelling in two dependencies; and
- local shadowing of an imported spelling.

Assert the actual definition ID or definition/navigation target. A test that
only asserts that typechecking succeeds is insufficient for this lookup change.

### Benchmark contract

The repository already has a focused definition-index benchmark with logical
counters for exact lookups and broad name scans. Extend it with an
owner-directed type-query mode rather than adding a separate benchmark.

At minimum, report:

- owner-directed query count;
- owner-directed hits;
- module buckets visited;
- collision entries examined;
- temporary result-list entries created;
- sort calls;
- checksum;
- allocations and bytes allocated; and
- elapsed microseconds.

For N owner-directed queries, the expected logical work is:

```text
module buckets visited = N
temporary result-list entries = 0
sort calls = 0
```

Increasing unrelated module count must not increase buckets visited per query.

Keep the existing broad-source-name benchmark and tests intact: it represents
a different, legitimate API contract and provides the before-shape comparison.

## Fast Feedback Loop

Do not repeatedly rebuild the compiler while editing. Use the currently built
`bin/blorp` to check the changed sources and focused suites:

```bash
bin/blorp check --no-format \
  blorp/src/compiler/stage_06_typecheck/graph/definition_index.brp

bin/blorp check --no-format \
  blorp/src/compiler/stage_06_typecheck/type_occurrence.brp

bin/blorp test --timeout 180 \
  blorp/test/compiler/stage_06_typecheck/test_definition_index.brp

bin/blorp test --timeout 180 \
  blorp/test/compiler/pipeline/test_definition_index_benchmark.brp

bin/blorp test --timeout 180 \
  blorp/test/lsp/analysis/test_lsp_semantic_index.brp
```

Use `scripts/compiler-check --changed` only after the focused loop is green.
It will select the manifest-owned suites and rebuild once.

### Focused performance loop

Before implementation, record one broad-name baseline with enough queries to
dominate timer granularity:

```bash
bin/blorp run --release --no-format \
  blorp/benchmark/compiler/compiler_definition_index_profile.brp \
  -- 1 64 1 0 100000 32
```

The current positional arguments are iterations, modules, functions per
module, exact source queries, broad source-name queries, and same-name matches.
When extending the fixture, append an owner-directed-query argument rather than
reordering the existing CLI. An illustrative candidate invocation is:

```bash
bin/blorp run --release --no-format \
  blorp/benchmark/compiler/compiler_definition_index_profile.brp \
  -- 1 64 1 0 0 32 100000
```

Record the exact argument contract in the benchmark header and output. One
baseline and one candidate run are sufficient when the logical counters prove
the algorithmic change and the workload is long enough to be stable. Do not
spend time collecting repetitions unless the result is noisy or contradictory.

Inspect the focused result before doing a whole-compiler measurement. If the
candidate still visits every module bucket or performs a sort, fix the design
rather than attempting to explain away the result.

### Integrated check

After the focused tests and benchmark pass:

```bash
scripts/compiler-check --changed

/usr/bin/time -lp \
  bin/blorp check --no-format blorp/src/main.brp
```

Only Phase 01-06 matters for this issue. Do not run or profile full C emission.
A second macOS `sample` run is optional; use it only if the exact call counter
or wall result suggests the broad lookup remains on the production path.

## Expected Result

The production type-occurrence path should perform two expected-constant-time
dictionary lookups followed by a very small exact-match scan. It should no
longer enumerate every loaded module, allocate a combined bindings list, or
sort that list.

Expected focused results:

- one module bucket visited per owner-directed query;
- zero temporary projection entries;
- zero sort calls;
- allocation count substantially below the equivalent broad-name workload;
- elapsed time insensitive to unrelated module count; and
- identical query checksums and resolved definition IDs.

Expected Phase 01-06 result:

- zero production calls to
  `definition_index_source_definition_bindings` from type-occurrence
  resolution;
- the previously attributed 3.5427% hotspot becomes immaterial; and
- total latency improves modestly, plausibly around 1-3.5%, without a
  regression in peak memory.

Do not reject an otherwise clear algorithmic win solely because one wall-clock
run is noisy. Conversely, do not claim a speedup if allocations, logical work,
or whole-compiler latency regress.

## Acceptance Criteria

1. Owner-directed exact-identity and loaded-canonical-path lookup APIs exist on
   `DefinitionIndex`.
2. Both APIs select one module bucket and one name bucket before examining
   entries.
3. Exact module and `TypeDefinition` validation remains inside the selected
   bucket.
4. Zero or multiple matching type definitions return `None`.
5. `resolved_type_definition_id` uses the owner-directed APIs for local,
   qualified-import, selective-import, and renamed-import paths.
6. The Phase 01-06 production path no longer calls the graph-wide source-name
   projection for semantic type occurrences.
7. Paired optional owner parameters and obsolete passthrough helpers are
   removed rather than retained as compatibility code.
8. Definition-ID values, typed references, source spans, diagnostics, and LSP
   targets remain unchanged in focused tests.
9. The focused benchmark proves one module bucket per query, zero projection
   entries, zero sorts, stable checksums, and no allocation regression.
10. Performance is insensitive to unrelated module count and Phase 01-06 wall
    time does not regress.
11. `scripts/compiler-check --changed` passes.
12. No generated C, benchmark binary, log, or scratch file is committed.

## Relationship To The Declaration Catalog Roadmap

`DefinitionIndex` remains the authority for source-definition identity,
definition IDs, and semantic-navigation targets. This issue only makes a query
for that existing identity owner-directed and allocation-free.

The declaration catalog roadmap gives accepted semantic declarations one
canonical storage product and uses module views for source visibility. When
Issue 37 cuts over accepted type-family facts, catalog entries must reuse the
`DefinitionIndex` IDs established here. It does not supersede this lookup with
a second identity namespace, and this issue does not make `DefinitionIndex`
the storage authority for accepted semantic type facts.

## Out Of Scope

- changing definition-ID allocation or deterministic module ordering;
- replacing `DefinitionIndexRep` or adding a second persistent index;
- caching by source spelling alone;
- changing `ModuleIdentity` representation or assigning numeric module IDs;
- activating or redesigning `AcceptedDeclarationCatalog`;
- changing import visibility, prelude behavior, or ambiguity rules;
- redesigning `Env`/`Scope` construction;
- optimizing callable, field, constructor, trait, or implementation lookups;
- deleting graph-wide projection APIs still used by diagnostics or tooling;
- Stage 07 CTFE, Core, ownership, or backend work; and
- full-compiler code-generation profiling.

## Implementation Report Requirements

The handoff must include:

- the exact new lookup APIs and why both identity forms are required;
- deleted passthrough or invalid-state helpers;
- focused test names and assertion totals;
- baseline and candidate benchmark commands and complete output;
- logical bucket, collision, projection, and sort counters;
- allocation and byte deltas;
- the Phase 01-06 wall-time and peak-RSS comparison;
- confirmation that definition IDs and LSP targets are unchanged;
- production versus test/benchmark diffstat; and
- any remaining broad projection consumer or rough edge discovered.
