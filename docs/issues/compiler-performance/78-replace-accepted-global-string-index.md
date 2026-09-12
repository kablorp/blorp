# Replace the Accepted-Global String Index

**Status:** Complete

**Roadmap:** [Normalized Semantic Compilation Roadmap](NORMALIZED_SEMANTIC_COMPILATION_ROADMAP.md), Step 2e, seventh packet

**Depends on:** Accepted-global visibility inputs (Issue 77)

## Outcome

The accepted-global table now retains one exact per-module relation:

```blorp
private record AcceptedGlobalTableRep {
	definition_table: DefinitionTable,
	source_name_table: SourceNameTable,
	slots: List[AcceptedGlobalSlot],
	completed_count: Int,
	index_by_global_definition_id: Dict[Int, Int],
	slot_indices_by_module_and_source_name_id: List[Dict[Int, Int]]
}
```

This replaces `List[Dict[String, Int]]`; it is not a second index beside it.
Local visibility enumerates exact slot indexes directly. Qualified source lookup
projects its spelling once through the retained graph `SourceNameTable` and uses
the same integer-keyed relation.

## Context

Issue 77 stopped source-name strings from crossing the accepted-global
visibility boundary, but its adapter still obtained local globals through:

```blorp
local_indices = representation.indices_by_module_and_name
	.get(module_id_table_index(owner_module_id))
	.get_or({})

for index in local_indices.values():
	...
```

The adapter did not enumerate the dictionary's keys, but the table still
retained a duplicated string key for every global. That representation mixed
two responsibilities:

1. exact per-module membership and deterministic enumeration; and
2. source-facing qualified lookup by `(module_path, name)`.

Both responsibilities can share one normalized relation keyed by the graph's
compilation-local `SourceNameId`. Retaining a string dictionary for all modules
made a source spelling the semantic key and repeated string hashing/comparison
after the graph had already cataloged that spelling.

## Invariants

1. `index_by_global_definition_id` remains the sole exact global-ID lookup.
2. `slot_indices_by_module_and_source_name_id[module_id]` is the sole per-module
   membership, duplicate-validation, qualified-lookup, and enumeration relation.
3. Every stored slot index resolves to an accepted slot whose `GlobalId` maps to
   a `DefinitionTable` global row owned by that module.
4. Each global definition and each source name occurs at most once per module.
5. Per-module dictionaries preserve accepted-table insertion order.
6. Local visibility consumes stored `SourceNameId` keys and slot values without
   reconstructing either identity from a source string.
7. Qualified lookup preserves public/private owner behavior, projects its input
   spelling to `SourceNameId` once, and performs no global-row string scan.
8. No parallel string or slot-list index is retained by this packet.
9. Missing modules, names, slots, or definition rows fail closed.

## Before and After

Before, table construction inserted a string key into a persistent dictionary:

```blorp
indices_by_module_and_name = indices_by_module_and_name.set(
	module_index,
	module_indices.set(row.name, index),
)
```

After, it inserts the exact graph source-name ID and slot index into the module's
canonical relation:

```blorp
slot_indices_by_module_and_source_name_id = (
	slot_indices_by_module_and_source_name_id.set(
		module_index,
		module_slot_indices.set(source_name_index, index),
	)
)
```

Qualified lookup projects the requested name once and performs an integer probe:

```blorp
source_name_id ?= source_name_table_find_id(table.source_name_table, name)
module_slot_indices ?= table.slot_indices_by_module_and_source_name_id.get(
	module_id_table_index(module_id),
)
index ?= module_slot_indices.get(source_name_id_table_index(source_name_id))
```

An initial list-only implementation was rejected during review because repeated
duplicate scans made construction quadratic within a global-heavy module. The
final representation preserves expected constant-time construction and lookup
while making exact integer IDs the retained key.

## Implementation Strategy

### 1. Lock the representation boundary first

Add a declaration-boundary test requiring
`slot_indices_by_module_and_source_name_id: List[Dict[Int, Int]]` and rejecting both
`indices_by_module_and_name` and any `Dict[String, ...]` in
`AcceptedGlobalTableRep`. The old table fails this test before implementation.

### 2. Replace construction, not just consumption

Thread the graph `SourceNameTable` into accepted-table construction and initialize
one empty integer dictionary per `ModuleId`. Project each authoritative global
row name once, reject duplicate `SourceNameId` entries in expected constant
time, and insert the exact slot. Preserve the existing definition-ID index
because it serves a different exact-key query.

### 3. Move local visibility to exact enumeration

Select the owner's dictionary with `prepared_module_scope_id(owner_scope)` and
iterate its integer keys. Reconstitute the branded `SourceNameId` only through
the retained source-name table's checked index accessor, and obtain each exact
slot from the same dictionary. Keep the Issue 77 row, module-owner, source-name
catalog, and provenance validation unchanged.

### 4. Preserve qualified lookup at the compatibility edge

Resolve the requested path to `ModuleId`, project the requested spelling through
the table's graph `SourceNameTable`, and probe only that module's integer map.
Do not cache another spelling or rebuild a graph-wide dictionary.

### 5. Preserve the source-name issuer across table replacement

The accepted table retains the `SourceNameTable` that issued its integer keys.
When a completed table replaces the authority's initial table, require both
`DefinitionTable` provenance compatibility and an identical source-name layout.
This prevents locators built in one name-ID domain from being reinterpreted by a
same-definition table with coincident but reordered integer IDs.

### 6. Measure the representation trade

Reuse the retained Issue 77 accepted-stage sample as the parent. Take one
candidate sample after the compiler is rebuilt. Treat allocation, release,
retained-object, allocated-byte, RSS, peak-memory, instruction, and executable
size counters as guards. Record wall time and cycles without claiming their
single-sample movement.

## Fast Feedback Loop

The table-shape test runs in well under a second:

```bash
python3 -m unittest \
  blorp.test.compiler.stage_06_typecheck.support.test_declaration_boundary.\
DeclarationBoundaryTests.test_global_authority_uses_one_exact_per_module_slot_relation
```

Then exercise direct authority construction and qualified/global behavior:

```bash
bin/blorp test \
	blorp/test/compiler/stage_06_typecheck/test_declaration_skeleton_graph.brp
bin/blorp test blorp/test/compiler/stage_06_typecheck/test_typecheck_decl.brp
```

Once stable, run the changed-owner gate once:

```bash
scripts/compiler-check --changed
```

Measure once against the retained parent sample:

```bash
env BLORP_COMPILER_BENCHMARK_SKIP_BUILD=1 /usr/bin/time -lp \
	benchmarks/compiler_typecheck_phase_profile accepted 1 32 4 16 16 memory
```

## Acceptance Criteria

- [x] A failing boundary test is written before the representation change.
- [x] `AcceptedGlobalTableRep` retains no string-keyed dictionary.
- [x] One `List[Dict[Int, Int]]` keyed by `SourceNameId` replaces, rather than
  supplements, the old index.
- [x] Local visibility enumerates exact slots without string work.
- [x] Construction and qualified lookup use expected constant-time integer
  probes rather than per-module scans.
- [x] Qualified global lookup retains public/private owner behavior.
- [x] Exact duplicate table entries fail closed, duplicate source globals are
  rejected before table construction, and same spellings in different modules
  select the requested module.
- [x] A qualified private global is visible only to its owner.
- [x] Direct authority and declaration suites pass: 16 and 140 tests.
- [x] Retained objects and allocated bytes are neutral; retired instructions
  and peak footprint improve slightly.
- [x] Allocations and releases remain within 0.02%; RSS and compiler size remain
  within 0.09%, well
  below the roadmap investigation threshold.
- [x] Changed-owner checks pass: three production sources, ten focused suites,
  one declaration-boundary check, and zero failures.
- [x] Post-`main` reconciliation retains the 57-fixture compiler gate update;
  compiler-owned tests pass 4,450/4,450 and runtime tests pass 4,469/4,469
  without restoring a string lookup fallback.
- [x] Independent review reports no unresolved issue.

## Measurements

Both accepted-stage runs report semantic checksum `-6362768653699369705`,
constructor checksum `-2142865109331864226`, 1,257 primary outputs, 65 secondary
outputs, 136 accepted constructor rows, and 353 accepted field rows.

| Metric | Issue 77 baseline | Candidate | Change |
| --- | ---: | ---: | ---: |
| allocations | 278,317 | 278,349 | +0.01% |
| releases | 189,315 | 189,347 | +0.02% |
| retained objects | 89,002 | 89,002 | 0.00% |
| allocated bytes | 6,490,056 | 6,490,056 | 0.00% |
| instructions retired | 8,462,326,045 | 8,459,585,105 | -0.03% |
| cycles | 2,353,452,184 | 2,341,500,832 | -0.51% |
| maximum RSS | 40,042,496 | 40,075,264 | +0.08% |
| peak footprint | 33,538,408 | 33,489,232 | -0.15% |
| compiler executable bytes | 19,388,768 | 19,405,296 | +0.09% |

The one-shot measured window moves from 170,044 to 151,832 microseconds. Wall
time and cycles remain noisy and are not performance claims. Retained objects
and allocated bytes are neutral, instructions and peak footprint improve
slightly, and every guard movement remains within 0.15%. Raw evidence is in
[`compiler_accepted_global_exact_module_slots_step2e_2026-09-11.md`](../../../benchmarks/results/compiler_accepted_global_exact_module_slots_step2e_2026-09-11.md).

## Main Integration

Commit `f2157d8c` restored CI by rolling back the then-incomplete Issues 74-76
identity chain and updating the compiler fixture inventory from 56 to 57. The
post-Issue-78 reconciliation retains those fixture-count and harness changes,
restores the normalized identity chain, and keeps the Issue 77-78 exact target
and visibility boundaries. The combined tree passes the 57-fixture
`compiler-blorp` gate and the complete runtime gate, including the emission path
that previously reached an unresolved `unknown` call kind. Its changed-owner
selection also passes across five production sources, fifteen focused suites,
and the declaration-boundary check.

The integration rebuild changes the executable's embedded commit metadata and
therefore its SHA, but not its byte size or compiler production source relative
to the measured Issue 78 candidate. The retained performance sample remains
tied to its recorded `5b94cf7f...` measured binary rather than being relabeled
as a new sample.

## Next Packet

Continue with
[`79-normalize-accepted-callable-selective-targets.md`](79-normalize-accepted-callable-selective-targets.md).
Carry the graph's exact callable overload targets across the accepted authority
boundary before changing its remaining string-keyed visibility maps. Do not add
another accepted-global name or enumeration index: the exact
`SourceNameId -> slot` relation now owns both responsibilities.
