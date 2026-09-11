# Normalize Qualified-Alias Source-Name Identities

**Status:** Complete

**Roadmap:** [Normalized Semantic Compilation Roadmap](NORMALIZED_SEMANTIC_COMPILATION_ROADMAP.md), Step 2e, first packet

**Depends on:** Step 2b graph-qualified module targets (`e5fb245d`)

## Outcome

Stage 06 now owns one compilation-local table for source spellings that have
entered the qualified-module-alias relation:

```blorp
opaque type SourceNameId = Int
opaque type SourceNameTable = SourceNameTableRep

private record SourceNameTableRep {
	spellings: List[String],
	id_by_spelling: Dict[String, Int]
}
```

The graph `ModuleView` lookup index is now keyed by the dense table position:

```blorp
private record ModuleViewRep {
	module_aliases: List[ModuleAliasBinding],
	source_name_table: Option[SourceNameTable],
	graph_module_aliases_by_source_name_id: Dict[Int, ModuleId],
	standalone_module_aliases_by_local_name: Dict[String, String],
	-- Unmigrated visibility relations remain explicit.
}
```

This replaces the former graph `Dict[String, ModuleId]`; it does not retain
that dictionary as a fallback. A graph alias is admitted only when its local
spelling was cataloged from parsed imports in the same indexed graph. Unknown
spellings fail closed as an internal invalid-target result.

`SourceNameId` is spelling identity, not semantic identity. Once an import has
resolved, the target remains a `ModuleId`; definitions remain `DefinitionId`,
and later category identities remain their precise types. Code must not use
numeric equality between source-name IDs issued by unrelated tables.

## Why This Is A Separate Packet

Step 2e ultimately needs a normalized visibility table covering local,
selective, qualified, prelude, and builtin candidates with explicit precedence.
Introducing IDs for every declaration and imported spelling in one change was
tempting, but measurement showed that it pre-paid table construction and added
ID probes while most consumers still required strings. That made the change
larger, harder to validate, and slower without retiring the corresponding
source-oriented representations.

The qualified-module-alias exact index is the smallest complete retained-index
migration:

- their semantic target is already a `ModuleId`;
- the graph has parsed every alias before Stage 06 binding begins;
- direct lookup and namespace-conflict checks share one exact index; and
- standalone source helpers have an intentionally different, path-backed
  contract that can remain visibly string-based.

The packet therefore establishes table ownership, provenance, and fail-closed
admission while changing exactly one production index. Ordered
`ModuleAliasBinding` rows still retain local spellings, and qualified type
resolution still consumes that ordered projection; migrating those consumers
belongs to a later visibility-row packet. This is a foundation, not a claim
that Step 2e or source-string retirement is complete.

## Source-Name Admission Contract

The indexed graph catalogs only spellings that can create a qualified module
binding:

```blorp
import:
	pkg/math as Math  -- catalogs "Math"
	pkg/text          -- catalogs default alias "text"
	pkg/list: map     -- does not catalog "map" in this packet
```

Explicit module aliases are included even when the import also has a selective
symbol list. Imports without an explicit alias receive the language's existing
default alias only when they are qualified imports. Selective symbol names,
top-level declarations, constructors, and trait methods are deferred until
their complete query families can migrate.

Default alias derivation has one implementation shared by graph cataloging and
module binding:

```blorp
pure func source_name_default_module_alias(module_path: String) -> String:
	parts = module_path.split("/")
	raw_name = parts.last().get_or(module_path)

	if raw_name.ends_with(".brp"):
		raw_name.substring(0, raw_name.length() - 4)
	else:
		raw_name
```

This is a syntax rule, not a heuristic. Keeping one implementation prevents a
catalog key from diverging from the spelling later registered by the binder.

Candidates are interned in deterministic first-occurrence order. Duplicate
spellings receive the same ID. The table preserves the spelling projection for
diagnostics, debugging, and future tooling queries:

```blorp
table = source_name_table(["Math", "text", "Math"])
source_name_table_count(table)                  -- 2
source_name_table_find_id(table, "Math")        -- Some(SourceNameId(0))
source_name_table_spelling(table, SourceNameId(0)) -- Some("Math")
```

The issuing table is retained by `IndexedGraph` and installed into each
graph-backed `ModuleView`. No process-global or cross-compilation interner is
introduced.

## Registration And Lookup

Graph alias registration converts the source-visible local spelling at the
boundary, then retains and queries the integer relation:

```blorp
table ?= representation.source_name_table
name_id ?= source_name_table_find_id(table, local_name)

representation.graph_module_aliases_by_source_name_id
	.get(source_name_id_table_index(name_id))
```

The registration path also validates that the supplied `ModuleId` belongs to
the active `ModuleTable` and matches the expected canonical path. These checks
remain semantic provenance checks; a valid spelling ID cannot make a foreign
module ID valid.

Conflict ordering is unchanged. Existing alias, imported-name, and local-name
checks run in the same order and report the same diagnostics. The only changed
access path is the graph qualified-alias lookup. Standalone registration keeps
`Dict[String, String]`, because it has neither an `IndexedGraph` nor a
compilation-owned `ModuleTable`/source-name table. Standalone tooling that
reuses a graph-reserved typecheck state must cross one explicit adapter: it
first proves there are no graph import bindings, then drops the graph spelling
capability before source-only registration. Direct standalone registration on
a graph-branded view is rejected even before the first graph import.

## Implementation Strategy

The bounded implementation sequence was:

1. Add a failing table test requiring stable, dense, first-occurrence IDs and
   a reverse spelling projection.
2. Add a failing indexed-graph test proving that explicit and default
   qualified aliases are cataloged while declarations and selective symbols
   are not.
3. Add `SourceNameTable` to `IndexedGraph` and expose it through
   `PreparedModuleScope`, preserving table provenance through state entry.
4. Split `ModuleView` into explicit graph and standalone alias indexes.
5. Replace only the graph alias dictionary with an integer-keyed dictionary;
   migrate lookup and both collision-query sites.
6. Make graph registration reject a local spelling absent from the active
   table, with a regression test proving there is no string-key fallback.
7. Centralize the pre-existing default-alias spelling rule so graph admission
   and import binding use the same function.
8. Reject standalone registration on a graph-branded view and make the
   standalone binder cross an explicit, validated adapter that removes the
   graph spelling capability.
9. Run the four directly affected suites and a production qualified-alias
   fixture before rebuilding the compiler.
10. Retain one baseline/candidate pair for the mixed graph workload and one
   baseline/candidate production check. Wall time is recorded but is not an
   acceptance signal.

## Fast Feedback Loop

The edit loop is intentionally small:

```bash
bin/blorp test \
	blorp/test/compiler/stage_06_typecheck/test_indexed_graph.brp
bin/blorp test \
	blorp/test/compiler/stage_06_typecheck/test_module_view.brp
bin/blorp test \
	blorp/test/compiler/stage_06_typecheck/test_typecheck_state.brp
bin/blorp test \
	blorp/test/compiler/stage_06_typecheck/test_typecheck_decl.brp
bin/blorp check --no-format \
	blorp/test/compiler/stage_06_typecheck/infer_fixtures/infer/should_pass/qualified_alias_sort.brp
```

These checks cover table issuance, scope installation, graph/standalone domain
separation, invalid provenance, namespace conflicts, default aliases, and the
real binder. They complete much faster than the broad repository gate.

After the narrow loop is green:

```bash
make -j2
/usr/bin/time -lp benchmarks/compiler_typecheck_profile 1 8 32 64 mixed 4
/usr/bin/time -lp bin/blorp check --no-format \
	blorp/test/compiler/stage_06_typecheck/infer_fixtures/infer/should_pass/qualified_alias_sort.brp
scripts/compiler-check --changed
```

Only the final measurement is retained. Repeating short wall-time samples
would add delay without improving the decision; retired instructions, RSS,
peak footprint, artifact size, test semantics, and the exact removed map are
the useful signals for this packet.

## Rejected Broader Designs

Three correct prototypes were discarded before the final gate:

1. Catalog every declaration spelling while migrating only module aliases.
   Mixed-workload retired instructions increased by 1.27% because the table
   performed work for names with no ID consumer.
2. Build the table through repeated immutable updates. Instructions increased
   by 3.45%; private single-owner construction is the appropriate boundary.
3. Convert graph imported-name and local-name maps in the same packet while
   their public consumers still supplied strings. Instructions increased by
   1.57% because the new table probes were added without deleting enough
   downstream string work.

The final design catalogs only qualified aliases and leaves the other maps
untouched. This is the concrete feedback-loop lesson for subsequent packets:
migrate one relation and delete its old access path before expanding table
coverage.

## Acceptance Criteria

- [x] `SourceNameId` and `SourceNameTable` are opaque, compilation-local, and
  retain a spelling projection for diagnostics and debugging.
- [x] IDs are dense, stable in first-occurrence order, and duplicate spellings
  map to one ID.
- [x] Explicit and default qualified aliases from every prepared module are
  cataloged by the indexed graph.
- [x] Declarations and selective imported names are not pre-cataloged before
  their query families migrate.
- [x] Graph `ModuleView` deletes `Dict[String, ModuleId]` and uses one
  `Dict[Int, ModuleId]` keyed by the active source-name table.
- [x] No graph alias lookup falls back to the standalone string/path map.
- [x] An uncataloged graph alias fails closed and cannot enter the view.
- [x] Default alias derivation has one implementation shared by admission and
  binding.
- [x] Existing alias/import/local conflict precedence is unchanged.
- [x] Standalone source-oriented binding remains explicitly string-backed.
- [x] Fresh graph views reject both standalone alias and standalone selective
  registration; the standalone binder uses the only production adapter that
  can discard an unused graph spelling capability.
- [x] Four focused suites pass and the production qualified-alias fixture
  typechecks.
- [x] Mixed graph and production instructions, cycles, RSS, peak footprint,
  and compiler size remain within a 1% investigation threshold.
- [x] The changed-owner compiler gate passes: six production sources, thirteen
  focused suites, and one special leak check completed with zero failures.
- [x] Independent review reports no unresolved correctness, architecture, or
  test issues.

## Measurements

The immutable baseline is Step 2d commit `71a5a2fe`. One final
baseline/candidate pair is retained for each workload. The mixed benchmark
kept `workload_valid=True`, checksum `3270`, nine artifacts, 1,078 source and
typed declarations, and 30 resolved imports.

| Mixed graph metric | Step 2d | Step 2e alias packet | Change |
| --- | ---: | ---: | ---: |
| setup microseconds | 128,335 | 128,883 | +0.43% |
| measured window microseconds | 327,585 | 330,117 | +0.77% |
| instructions retired | 7,299,171,293 | 7,311,818,742 | +0.17% |
| cycles | 1,837,668,667 | 1,825,624,723 | -0.66% |
| maximum RSS | 33,914,880 | 33,947,648 | +0.10% |
| peak footprint | 26,050,896 | 26,034,536 | -0.06% |

| Production qualified-alias check metric | Step 2d | Step 2e alias packet | Change |
| --- | ---: | ---: | ---: |
| instructions retired | 2,940,697,677 | 2,944,278,603 | +0.12% |
| cycles | 729,016,379 | 735,296,408 | +0.86% |
| maximum RSS | 30,785,536 | 30,851,072 | +0.21% |
| peak footprint | 24,658,280 | 24,756,584 | +0.40% |
| compiler executable bytes | 19,318,976 | 19,336,224 | +0.09% |

The result is intentionally described as bounded, not faster. The primary
structural improvement is replacing the graph alias relation's repeated string
key with a compact compilation-local identity and establishing the retained
spelling table required by later consumers. Native counters and artifact size
remain within 0.87%; memory movements are small and mixed in direction.
One-shot wall time is not used to claim either improvement or regression.

Raw commands, hashes, and counters are retained in
[`compiler_qualified_alias_source_names_step2e_2026-09-11.md`](../../../benchmarks/results/compiler_qualified_alias_source_names_step2e_2026-09-11.md).

## Next Packet

Completed by
[`73-normalize-local-source-name-identities.md`](73-normalize-local-source-name-identities.md).
That packet catalogs the exact declaration-name inventory, changes the graph
local-name relation to `SourceNameId`, migrates its collision consumers, and
deletes its string-keyed graph map while preserving standalone source tooling.
