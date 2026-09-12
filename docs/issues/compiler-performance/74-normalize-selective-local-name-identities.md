# Normalize Selective Local-Name Identities

**Status:** Complete

**Roadmap:** [Normalized Semantic Compilation Roadmap](NORMALIZED_SEMANTIC_COMPILATION_ROADMAP.md), Step 2e, third packet

**Depends on:** Local source-name identities, included in cumulative commit
`eeef5803`

## Outcome

Graph-backed selective imported-name lookup no longer retains a
`Dict[String, ImportedNameBinding]`. The indexed graph catalogs every local
spelling that can enter selective visibility, and each graph `ModuleView`
stores the accepted rows as:

```blorp
private record ModuleViewRep {
	imported_names: List[ImportedNameBinding]
	graph_imported_names_by_source_name_id: Dict[Int, ImportedNameBinding]
	standalone_imported_names_by_local_name: Dict[String, ImportedNameBinding]
}
```

The ordered `imported_names` rows deliberately retain source spellings. They
are still consumed by Stage 06 diagnostics and compatibility projections. The
normalized map is the semantic lookup relation: its graph keys are dense,
compilation-local `SourceNameId` table positions rather than repeated source
strings. Standalone parser and typechecker helpers remain explicitly
string-backed because they do not own an indexed compilation graph.

This is a bounded representation packet, not a claim that selective imports
or typechecking are string-free. It removes one complete graph string-keyed
index and makes catalog admission authoritative. Later packets can move
callers to ID-aware APIs and narrow or delete the string-rich ordered rows once
diagnostics and bridge consumers have explicit projections.

## Context

After the first two Step 2e packets, qualified aliases and local declarations
used the graph's `SourceNameTable`, but selective imported names still used a
shared string relation:

```blorp
private record ModuleViewRep {
	imported_names: List[ImportedNameBinding]
	imported_names_by_local_name: Dict[String, ImportedNameBinding]
}
```

That map served graph compilations and standalone helpers simultaneously. It
also made every namespace collision path return to string hashing even when a
graph-local name or alias had already been resolved to its source-name ID.
Keeping it would undermine the roadmap's central invariant: once source text
has been admitted, later semantic relations should use values derived from the
compilation and retain text only as a diagnostic projection.

Selective visibility contains more spelling forms than either prior packet:

```blorp
import:
	pkg/math: answer                  -- local spelling: answer
	pkg/math: answer as compute       -- local spelling: compute
	pkg/math: Number(Some, None)      -- local spellings: Number, Some, None
	pkg/math as Math: answer          -- local spellings: Math, answer
```

Trait methods also enter the same selective namespace. Their
`TraitMethodId` is issued after the current import-binding boundary, so this
packet normalizes their local visibility key without pretending the target's
source spelling is already a semantic method identity.

## Source-Name Admission Contract

`source_name_candidates_for_import` now catalogs:

- every explicit module alias, including an alias on a combined qualified and
  selective import;
- each selected symbol's local spelling, using its alias when present;
- each explicitly selected constructor spelling; and
- a default module alias only for imports with neither an explicit alias nor a
  selective symbol list.

Selected trait methods follow the same import rule as every other selected
symbol. Unselected trait method declarations remain outside the table; this
avoids pre-paying source-name rows for methods with no visibility consumer.

Fields and parameters remain excluded because they enter neither module-local
nor selective-import visibility. Implementation method declarations are not
pre-cataloged from impl bodies, but a selected implementation method is
cataloged from its import's local spelling like any other selected symbol.
Duplicate spellings continue to share one deterministic first-occurrence ID.

## Target Representation And Invariants

The graph and standalone relations are separate fields rather than a Boolean
mode over one ambiguous container:

```blorp
graph_imported_names_by_source_name_id: Dict[Int, ImportedNameBinding]
standalone_imported_names_by_local_name: Dict[String, ImportedNameBinding]
```

The following invariants hold at the registration boundary:

1. A graph selective local name must resolve through the exact
   `SourceNameTable` installed by its indexed graph.
2. An uncataloged name returns `SelectiveNameInvalidSourceName`; it never
   falls back to a string map.
3. The resolved integer key is reused for duplicate-import, qualified-alias,
   and local-declaration collision probes.
4. Graph target validation still proves definition-table provenance,
   canonical module identity, and exact definition membership.
5. Standalone registration cannot write to a graph-branded view, and graph
   registration cannot coexist with standalone import bindings.
6. Collision precedence remains imported name, module alias, then local
   declaration.
7. A qualified module alias and selective name may coexist only when they
   target the same canonical module, preserving existing language behavior.
8. Removing unqualified names clears both graph and standalone imported-name
   indexes together with the ordered projection.
9. `ImportedNameBinding` remains the diagnostic/source projection; its strings
   are not treated as target semantic identity.

## Implementation Strategy

### 1. Define failure before changing storage

The first regression extends the indexed-graph catalog fixture with a combined
import and requires its selective alias to receive a source-name ID. A second
regression attempts graph registration with a valid target but an uncataloged
local alias and requires this diagnostic:

```text
internal typecheck error: selective import local name 'renamed_value' is not cataloged by the active module graph
```

It also proves no import binding was added. These tests failed before the
implementation and distinguish catalog correctness from target provenance.

### 2. Make selective admission complete

Expand the existing import admission function rather than creating a second
selective-name scan. Combined imports append both their explicit module alias
and selected local names. Constructor spellings are admitted from the parser's
explicit constructor list. Trait methods are admitted only when selected by an
import, through the same local-name path; their declarations do not enlarge
the table speculatively.

### 3. Split graph and standalone storage

Replace the shared map with graph-ID and standalone-string fields. Separate
graph and standalone registration helpers make the storage domain explicit in
their signatures. A prototype used an `ImportedNameStorage` carrier union, but
it added one transient allocation for every selective import without adding a
useful invariant, so the final implementation removed it.

### 4. Resolve once, then reuse the key

Both graph selective-definition and graph selective-trait-method registration
resolve `local_name` once:

```blorp
name_index = module_view_graph_source_name_index(representation, local_name)

match name_index:
	None:
		SelectiveNameInvalidSourceName
	Some(source_name_index):
		module_view_register_graph_selective_name(
			representation,
			module_table,
			source_name_index,
			local_name,
			module_path,
			source_name,
			import_binding,
		)
```

The helper uses `source_name_index` directly for all three graph collision
queries. It retains `local_name`, `module_path`, and `source_name` only when it
constructs the ordered diagnostic row and current import-binding projection.

### 5. Preserve source-oriented compatibility at the boundary

`module_view_find_imported_name` still accepts a `String`. In a graph view it
projects that spelling through the table and queries the integer map; in a
standalone view it queries the standalone string map. There is no fallback
between domains.

This compatibility function is intentionally visible as remaining work. A
later packet should pass `SourceNameId` from graph admission into callers that
already operate on graph-owned names, reducing repeated projections without
forcing diagnostics to give up their reverse spelling table.

### 6. Preserve every namespace consumer

Qualified module-alias registration now probes the appropriate imported-name
map directly. Local declaration registration selects the graph or standalone
map from its existing `LocalNameStorage` capability. Clearing unqualified
names clears both maps. The replaced `imported_names_by_local_name` field is
deleted; no parallel graph string index survives.

## Fast Feedback Loop

The edit loop stays within the directly affected ownership boundary:

```bash
bin/blorp test blorp/test/compiler/stage_06_typecheck/test_indexed_graph.brp
bin/blorp test blorp/test/compiler/stage_06_typecheck/test_typecheck_state.brp
bin/blorp test blorp/test/compiler/stage_06_typecheck/test_module_view.brp
bin/blorp test blorp/test/compiler/stage_06_typecheck/test_typecheck_decl.brp
bin/blorp test blorp/test/compiler/stage_06_typecheck/test_frontend_graph_typecheck.brp
bin/blorp check --no-format \
	blorp/test/compiler/stage_06_typecheck/infer_fixtures/infer/should_pass/selective_import_alias.brp
```

The first two tests isolate catalog admission and fail-closed registration.
The module-view suite protects collision precedence and graph/standalone
separation. Declaration and frontend suites exercise the production binder,
and the existing fixture provides a short public-language smoke test.

Only after that loop is green:

```bash
make -j2
env BLORP_COMPILER_BENCHMARK_SKIP_BUILD=1 /usr/bin/time -lp \
	benchmarks/compiler_module_binding_profile 1 64 16
/usr/bin/time -lp bin/blorp check --no-format \
	blorp/benchmark/compiler/selective_import_graph_fixture/main.brp
scripts/compiler-check --changed
```

The retained evidence is one immutable baseline/candidate pair, not repeated
wall-time sampling. The module-binding harness reports exact semantic work and
managed-memory counters; the production fixture checks the real loader and
typechecker. Retired instructions, allocations, retained objects, allocated
bytes, RSS, peak footprint, and executable size are the decision signals.
Short elapsed and cycle samples are retained but not averaged into a claim.

## Acceptance Criteria

- [x] Selective symbol aliases, unaliased symbols, explicit constructors, and
  combined module aliases enter the graph source table; selected trait methods
  use the same import admission while unselected methods remain excluded.
- [x] Graph imported-name storage is keyed by the active source-name table's
  integer IDs.
- [x] The replaced graph `Dict[String, ImportedNameBinding]` is deleted rather
  than retained as a parallel index.
- [x] Standalone imported-name lookup remains separately named and
  string-backed.
- [x] Graph registration fails closed on an uncataloged local name and reports
  an actionable internal diagnostic.
- [x] Selective-definition and selective-trait-method target provenance checks
  remain intact.
- [x] Duplicate, alias, and local-name conflicts reuse the resolved graph key
  and preserve precedence.
- [x] Ordered diagnostic/import projections retain required source text.
- [x] Focused graph, state, module-view, declaration, and frontend suites pass.
- [x] The production selective-import fixture typechecks.
- [x] Retained objects are neutral, allocated bytes remain effectively flat,
  RSS and peak footprint have no material regression, and compiler size stays
  below the 1% investigation threshold.
- [x] Production retired instructions stay below the 1% investigation
  threshold; the isolated binding harness remains below 1% instructions with
  identical workload counters.
- [x] The changed-owner gate completes with no failure: three production
  sources, six focused suites, and zero failures.
- [x] Independent review reports no unresolved correctness, architecture, or
  test issue.

## Measurements

The immutable baseline is the cumulative main commit `eeef5803`. The binding
workload is identical in both runs: 64 modules, 1,024 exports, 64 aliases, 64
selective imported names, 128 import bindings, zero errors,
`workload_valid=True`, and checksum `12608`.

| Module-binding metric | Baseline | Candidate | Change |
| --- | ---: | ---: | ---: |
| allocations | 6,743 | 6,807 | +0.95% |
| releases | 5,328 | 5,392 | +1.20% |
| retained objects | 1,415 | 1,415 | 0.00% |
| allocated bytes | 97,016 | 97,024 | +0.01% |
| instructions retired | 240,324,656 | 242,102,310 | +0.74% |
| maximum RSS | 4,063,232 | 4,079,616 | +0.40% |
| peak footprint | 2,457,888 | 2,441,504 | -0.67% |

The 64 additional allocation/release pairs are exactly one per graph
selective-name registration. A raw integer missing-sentinel prototype was
measured and removed because it did not change that count. The allocation is
therefore not the `Option` lookup wrapper. Retained objects are unchanged and
allocated bytes differ by only eight bytes, so the packet does not increase
the retained memory ceiling in this screen.

The one-shot binding cycles increased 15.06%, while instructions increased
only 0.74%, RSS changed 0.40%, peak footprint improved 0.67%, and the harness
reported 41 rather than 58 involuntary context switches. The cycle sample is
treated as noisy and not as evidence of either a regression or improvement;
it is retained in the raw results rather than hidden by additional sampling.

| Production selective check metric | Baseline | Candidate | Change |
| --- | ---: | ---: | ---: |
| instructions retired | 2,998,057,875 | 3,013,813,549 | +0.53% |
| cycles | 727,318,828 | 751,760,201 | +3.36% |
| maximum RSS | 31,096,832 | 31,178,752 | +0.26% |
| peak footprint | 24,985,960 | 25,051,520 | +0.26% |
| compiler executable bytes | 19,370,576 | 19,387,424 | +0.09% |

The production screen remains below 0.53% in instructions and memory. Its
one-shot cycle count is +3.36%. Neither its elapsed sample nor the binding
harness's build-dominated elapsed sample is used as an acceptance claim.

Raw commands, hashes, and counters are retained in
[`compiler_selective_local_source_names_step2e_2026-09-11.md`](../../../benchmarks/results/compiler_selective_local_source_names_step2e_2026-09-11.md).

## Next Packet

Completed by
[`75-normalize-accepted-global-visibility-names.md`](75-normalize-accepted-global-visibility-names.md).
The allocation experiment showed that moving the same registration lookup
earlier would not remove Issue 74's transient pairs. Issue 75 instead migrates
the next retained downstream consumer: accepted-global unqualified visibility.
