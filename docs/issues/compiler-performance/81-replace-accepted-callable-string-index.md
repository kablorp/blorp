# Replace the Accepted-Callable String Index

**Status:** Complete

**Roadmap:** [Normalized Semantic Compilation Roadmap](NORMALIZED_SEMANTIC_COMPILATION_ROADMAP.md), Step 2e, tenth packet

**Depends on:** Accepted-callable visibility source-name IDs (Issue 80)

## Outcome

The accepted callable table no longer retains a dictionary for every module
and source spelling:

```blorp
indices_by_module_and_name: List[Dict[String, List[Int]]]
```

Canonical callable slots now retain `SourceNameId`, and one dense list maps a
`ModuleId` table index to its contiguous canonical slot range:

```blorp
private record AcceptedCallableSlot {
	id: CallableId,
	source_name_id: SourceNameId,
	visibility: DeclarationVisibility,
	entry: OverloadEntry
}

private struct AcceptedCallableModuleRange {
	start: Int,
	count: Int
}

private record AcceptedCallableTableRep {
	module_table: ModuleTable,
	definition_table: DefinitionTable,
	source_name_table: SourceNameTable,
	slots: List[AcceptedCallableSlot],
	indices_by_definition_id: Dict[Int, List[Int]],
	slot_range_by_module: List[AcceptedCallableModuleRange]
}
```

This is the compact list relation requested after Issue 79's generic integer
dictionary regression. It is built directly at the accepted-callable producer
boundary and replaces the old string index. It is not layered over that index.

## Context

The old table retained one `Dict[String, List[Int]]` per module. It performed
fast name lookup, but it duplicated source spellings and created many managed
dictionary/list nodes that survived for the accepted graph's lifetime.

Issue 80 removed strings from selective visibility rows but retained this
table as a compatibility boundary. Two attempts to add a list representation
beside it failed because building both structures increased allocations by
2.75%-5.32%. The migration strategy, rather than lists themselves, was wrong.

The producing path already collects accepted callables one module at a time.
Within each module, source-name order has no cross-name semantic meaning, while
overload order for the same name does. A stable sort by source name therefore
makes equal-name callables contiguous without changing overload precedence.
That permits one canonical slot list plus one range per module.

## Why a Range List Instead of a Generic Integer Dictionary

`ModuleId` table indices are dense from `0` to `module_table_count - 1`. A
dictionary adds hashing, boxing, nodes, and failure states to an already dense
domain. A list is the natural representation:

```text
slot_range_by_module[module_id.index] -> { start, count }
slots[start .. start + count]         -> that module's callables
```

No second list of callable targets is necessary: the canonical slots are
already the flat target storage. This is a CSR-style adjacency relation with
fixed-size range rows and no duplicated edge array.

Names are stable-grouped by numeric `SourceNameId` inside each module range.
Authority construction walks one group at a time and publishes one
compatibility dictionary entry per name, avoiding the repeated dictionary
updates that caused the first range prototype to allocate 3.16% more bytes.

Qualified lookup resolves the query spelling to `SourceNameId` once, then scans
the sorted canonical slots with a lower-bound binary search. Only the matching
overload group is scanned. It does not linearly scan every callable in the
module, scan the graph, or reconstruct a `(module path, source name)` table key.

## Invariants

1. Accepted callable slots retain `SourceNameId`, not source `String`.
2. `slot_range_by_module` has exactly one entry per `ModuleTable` row.
3. Every nonempty module range points into the canonical `slots` list.
4. A module's callables form one contiguous range; a module may not re-enter
   after another module begins.
5. Source names are nondecreasing within a module range, so equal names form
   one contiguous group.
6. Sorting is stable; overloads with the same source name preserve declaration
   order. Reverse-precedence lookup behavior remains unchanged.
7. Exact definition-ID lookup retains its existing category-safe
   `indices_by_definition_id` relation.
8. Local callables remain visible regardless of public/private visibility;
   qualified and directly imported UFCS candidates remain public-only.
9. Missing slots, invalid ranges, uncataloged IDs, and malformed producer order
   fail closed.
10. No generic integer dictionary or parallel string membership index is
    retained.

## Implementation Strategy

### 1. Lock the target representation with a failing test

Add a millisecond-scale structural test that requires:

```text
AcceptedCallableSlot.source_name_id: SourceNameId
AcceptedCallableTableRep.slot_range_by_module:
    List[AcceptedCallableModuleRange]
```

It also rejects both `AcceptedCallableSlot.source_name: String` and
`indices_by_module_and_name`. The test fails on Issue 80 before production
changes.

### 2. Stable-group records at the producer

Each prepared module already owns its accepted callable record list. Resolve
the callable spelling through the prepared scope's `SourceNameTable`, retain
the resulting ID in the record, and stable-sort that one module's records by
the ID's numeric table index before concatenating it into the table input:

```blorp
callable_records = callable_records.concat(base.callables.sort_by(
	func(item): source_name_id_table_index(item.source_name_id),
))
```

Equal-name overloads retain their original order. No source string crosses the
accepted-callable record boundary.

### 3. Validate grouping while constructing canonical slots

Track the previously accepted module index and source name. Reject a module
that re-enters or a source name that moves backward within its module. This
turns the producer ordering convention into a checked table invariant rather
than an undocumented assumption.

Validate the record's `SourceNameId` against the graph-owned definition row and
store only that ID in `AcceptedCallableSlot`.

### 4. Build ranges directly

Initialize one empty range for every module. On the first callable for a module,
record its canonical slot index; on each following callable, increment the
range count. No per-name dictionary or nested module list is constructed.

### 5. Rebuild compatibility authorities group-by-group

The public inference APIs still query unqualified callable and UFCS candidates
with strings. Walk each module range from newest to oldest, accumulate a single
equal-name overload group, project its spelling once, and insert that complete
list into the compatibility authority.

Local visible and local UFCS dictionaries initially share the same completed
group lists. Selective imports then extend only visible lookup, while direct
module imports extend only UFCS lookup, preserving the old separation.

### 6. Make qualified lookup ID-aware

For qualified callable and UFCS queries:

1. resolve the module path to exact `ModuleId`;
2. resolve the source spelling to `SourceNameId`;
3. read only that module's canonical range;
4. lower-bound binary-search the range by numeric source-name ID;
5. scan only the equal-ID overload group and apply public visibility and
   receiver-type filters.

No retained source-name index participates in the lookup.

## Fast Feedback Loop

First run the structural test, which completes in milliseconds:

```bash
python3 -m unittest \
  blorp.test.compiler.stage_06_typecheck.support.test_declaration_boundary.\
DeclarationBoundaryTests.test_callable_module_membership_uses_compact_ranges
```

Then run the authority behavior suite:

```bash
bin/blorp test \
  blorp/test/compiler/stage_06_typecheck/test_typecheck_decl.brp
```

The exact-target fixture deliberately separates two same-name overloads with a
different callable. This proves stable grouping preserves overload order rather
than merely passing for already-adjacent declarations. A direct table fixture
also proves that descending source-name IDs and module re-entry fail closed.

Once stable, run the changed-owner gate once:

```bash
scripts/compiler-check --changed
```

Finally take one accepted-stage guard sample:

```bash
env BLORP_COMPILER_BENCHMARK_SKIP_BUILD=1 /usr/bin/time -lp \
	benchmarks/compiler_typecheck_phase_profile accepted 1 32 4 16 16 memory
```

Reject a form that improves allocation count by duplicating large byte buffers
or materially increasing retained memory. One-shot elapsed time and cycles are
recorded but are not acceptance claims.

## Acceptance Criteria

- [x] The compact-range boundary test fails against the Issue 80 table shape.
- [x] Canonical callable slots retain `SourceNameId` and no source string.
- [x] `slot_range_by_module` replaces `indices_by_module_and_name`.
- [x] The producer stable-groups names within each module.
- [x] Table construction validates module contiguity and source-name ordering.
- [x] Local, selective, qualified, and UFCS behavior preserves visibility and
  precedence.
- [x] The exact-target fixture covers same-name overloads separated by another
  declaration before table construction.
- [x] Qualified lookup is `O(log n + k)` for `n` module slots and `k` matching
  overloads; it does not linearly scan all module callables per query.
- [x] Direct malformed-input tests reject descending source-name IDs and module
  re-entry.
- [x] All 142 declaration tests pass.
- [x] The changed-owner gate passes: two production sources, nine focused
  suites, one declaration-boundary check, and zero failures.
- [x] Retained objects, allocated bytes, cycles, RSS, and peak footprint
  improve; compiler size remains effectively neutral.
- [x] Allocation and release call regressions remain below 0.5%.
- [x] Retired instructions remain below the 1% regression guard.
- [x] Independent review reports no unresolved issue.

## Measurements

Both accepted-stage samples produced identical semantic checksums, output
counts, and accepted catalog counts.

| Metric | Issue 80 baseline | Candidate | Change |
| --- | ---: | ---: | ---: |
| Allocations | 278,382 | 279,265 | +0.3172% |
| Releases | 189,380 | 190,297 | +0.4842% |
| Retained objects | 89,002 | 88,968 | -0.0382% |
| Allocated bytes | 6,490,056 | 6,485,968 | -0.0630% |
| Retired instructions | 8,467,018,989 | 8,547,658,201 | +0.9524% |
| Cycles | 2,344,974,502 | 2,343,688,140 | -0.0549% |
| Maximum RSS | 40,108,032 | 40,042,496 | -0.1634% |
| Peak footprint | 33,554,744 | 33,505,616 | -0.1464% |
| Compiler bytes | 19,406,176 | 19,406,448 | +0.0014% |

Two structurally incomplete forms were rejected before this candidate. A
module-range-only form had favorable counters but made qualified lookup
`O(n * q)` across `q` queries. A second form restored logarithmic lookup with a
parallel per-name range list, but raised allocations 0.32%, releases 0.49%, and
allocated bytes 0.32%. The retained form lower-bound searches the canonical
slots directly, so it has neither the linear query path nor the duplicate name
range.

Detailed evidence is retained in
[`compiler_accepted_callable_compact_ranges_step2e_2026-09-11.md`](../../../benchmarks/results/compiler_accepted_callable_compact_ranges_step2e_2026-09-11.md)
and its TSV companion.

## Next Packet

The implemented follow-up is
[`82-retain-exact-accepted-callable-visibility-inputs.md`](82-retain-exact-accepted-callable-visibility-inputs.md):
remove the remaining string-keyed `AcceptedCallableAuthorityRep` dictionaries
without replacing them with generic integer dictionaries, dense lists, or
sparse per-name copies. Retain exact owner, selective-binding, and direct-module
inputs and reuse the canonical table's searchable ranges on demand.
