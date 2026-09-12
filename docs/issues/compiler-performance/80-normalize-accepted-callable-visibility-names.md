# Normalize Accepted-Callable Visibility Names

**Status:** Complete

**Roadmap:** [Normalized Semantic Compilation Roadmap](NORMALIZED_SEMANTIC_COMPILATION_ROADMAP.md), Step 2e, ninth packet

**Depends on:** Accepted-callable exact selective targets (Issue 79)

## Outcome

Accepted-callable visibility rows now retain a compilation-local
`SourceNameId` instead of copying a source `String`:

```blorp
private record AcceptedVisibleCallableBindingRep {
	source_name_id: SourceNameId,
	targets: List[CallableId]
}
```

The accepted callable table derives its module, definition, and source-name
tables from one `PreparedModuleScope`, then owns the `SourceNameTable` that
gives those IDs meaning. Visibility construction resolves a spelling at the
boundary, retains only the ID, and fails closed if the name was not admitted
to the graph's source-name domain.

The existing string-keyed callable authority remains a compatibility consumer
for this packet. Authority construction projects the spelling from the table
at that boundary; it does not retain a second spelling in the visibility row.
This is a smaller forward step after broader replacement prototypes regressed
allocation calls.

## Context

Issue 79 replaced descriptive imported-callable targets with exact ordered
`CallableId` values, but its row still mixed semantic identity and source text:

```blorp
private record AcceptedVisibleCallableBindingRep {
	source_name: String,
	targets: List[CallableId]
}
```

The local spelling is needed only because the current authority exposes
string-keyed unqualified and UFCS queries. Retaining that spelling in every
visibility row made the compatibility detail look like part of the normalized
relationship. It also allowed a spelling and the compilation-local source-name
domain to drift independently.

The normalized relationship is instead:

```text
SourceNameId -> ordered CallableId targets
```

Strings remain in the single `SourceNameTable` spelling projection for source
admission, diagnostics, debugging, and compatibility APIs. They no longer ride
through this accepted visibility edge.

## Why This Packet Does Not Add Generic Integer Dictionaries

A generic `Dict[Int, List[Int]]` is not the desired final representation. It
boxes and manages generic values and can cost more than the string work it
replaces. Issue 79 already rejected one such prototype at about +2.4%
allocations/releases.

Two additional list-oriented prototypes were evaluated before this packet:

1. parallel flat scalar arrays layered beside the existing table added 7,650
   allocations (+2.75%) and 7,679 releases (+4.05%);
2. grouped canonical slots layered beside the existing table added 14,801
   allocations (+5.32%) and 14,834 releases (+7.83%).

Those results do not reject lists. They reject constructing a second relation
after the old dictionary table is already built. The final list relation must
be built once at the producing boundary and replace the old container.

The intended compact shape is CSR-like:

```text
module_offsets:       List[Int]
source_name_ids:      List[SourceNameId]  # sorted within each module range
target_offsets:       List[Int]
callable_targets:     List[CallableId]
```

`module_offsets[m]..module_offsets[m + 1]` selects a module's rows. A binary
search over that small sorted range finds the `SourceNameId`, and
`target_offsets[row]..target_offsets[row + 1]` selects its overload targets.
This avoids a dense modules-by-all-source-names matrix while keeping strings,
hashing, and generic integer dictionaries out of steady-state lookup.

## Invariants

1. Every retained visibility name is a `SourceNameId`, not a copied `String`.
2. The accepted callable table derives the module, definition, and source-name
   capabilities from one graph-owned `PreparedModuleScope`; callers cannot
   combine tables from independent graphs.
3. The accepted callable table retains the `SourceNameTable` that issued and
   projects those IDs.
4. Every accepted callable's declared spelling must exist in that table before
   the accepted table is published.
5. Every imported local spelling must exist in the same table before its
   visibility row is published.
6. Exact ordered `CallableId` targets and all Issue 79 provenance, category,
   ownership, visibility, and ordering checks remain unchanged.
7. A missing ID or spelling projection invalidates the product; no raw integer
   or guessed spelling is accepted.
8. The string-keyed callable authority is a temporary compatibility boundary,
   not the normalized relationship.
9. This packet adds no parallel generic integer-keyed dictionary or duplicated
   list index.

## Implementation Strategy

### 1. Lock the retained row shape first

Add a millisecond-scale boundary test requiring `source_name_id: SourceNameId`,
rejecting `source_name: String`, requiring the accepted table to retain its
`SourceNameTable`, and requiring table input to be one `PreparedModuleScope`
rather than three independently supplied tables. The test fails on Issue 79
before production changes.

### 2. Derive all table capabilities from one prepared scope

The declaration adapter already owns a prepared module scope. Pass that single
capability rather than independently passing tables that merely appear
compatible:

```blorp
accepted_callable_table({
	scope = bound_module_scope(bound_module_graph_target(bound_graph)),
	callables = callable_records,
})
```

The constructor derives `ModuleTable`, `DefinitionTable`, and `SourceNameTable`
from this scope. A reordered or same-spelling table from another graph is no
longer representable at this API boundary.

### 3. Validate names at table construction

Reject an accepted callable row whose declared spelling is outside the source
name table:

```blorp
source_name_table_find_id(source_name_table, item.source_name).is_none()
```

This pushes the invariant to the publication boundary. Later visibility rows
may rely on the accepted table's name domain.

### 4. Retain IDs in visibility rows

Resolve each graph local spelling once while constructing the visibility
aggregate and store only its `SourceNameId` beside the exact callable targets.
An uncataloged name makes the aggregate invalid.

### 5. Project spelling only for the compatibility authority

The current authority still owns `Dict[String, List[Int]]` lookup. Project the
spelling immediately before inserting into that legacy relation:

```blorp
match source_name_table_spelling(table.source_name_table, binding.source_name_id):
	Some(source_name):
		visible_indices_by_source_name =
			visible_indices_by_source_name.set(source_name, indices)
	None:
		valid = False
```

Do not cache the projection on the normalized row. A later producer-side CSR
packet will replace the compatibility dictionary rather than layering another
container beside it.

## Fast Feedback Loop

Run the structural boundary test first:

```bash
python3 -m unittest \
  blorp.test.compiler.stage_06_typecheck.support.test_declaration_boundary.\
DeclarationBoundaryTests.test_callable_visibility_uses_source_name_ids
```

Then run the focused authority behavior suite:

```bash
bin/blorp test \
  blorp/test/compiler/stage_06_typecheck/test_typecheck_decl.brp
```

Once those pass, run the manifest-owned changed-source gate once:

```bash
scripts/compiler-check --changed
```

Take one accepted-stage guard sample. Do not collect many wall-time pairs:

```bash
env BLORP_COMPILER_BENCHMARK_SKIP_BUILD=1 /usr/bin/time -lp \
	benchmarks/compiler_typecheck_phase_profile accepted 1 32 4 16 16 memory
```

Compare deterministic allocation counts and bytes first, then retired
instructions, RSS, peak footprint, and executable size. Record a one-shot cycle
or elapsed-time movement as noise unless a repeatable mechanism justifies it.

## Acceptance Criteria

- [x] The boundary test fails on the old string-bearing visibility row.
- [x] Accepted visibility rows retain `SourceNameId + List[CallableId]`.
- [x] Table construction accepts one `PreparedModuleScope`, derives all three
  graph capabilities from it, and explicitly owns the `SourceNameTable`.
- [x] Accepted callable spellings and imported local spellings fail closed when
  absent from the table.
- [x] The compatibility authority projects spelling from the table rather than
  retaining it in the normalized visibility row.
- [x] Exact selective target, overload ordering, visibility, and provenance
  behavior remains covered by the declaration suite.
- [x] The changed-owner gate passes: two production sources, nine focused
  suites, one declaration-boundary check, and zero failures.
- [x] Allocations, releases, retained objects, and allocated bytes are exactly
  neutral in the accepted-stage guard.
- [x] Retired instructions and compiler size remain within 0.13%; RSS and peak
  footprint improve slightly.
- [x] The broader generic-dictionary and duplicate-list prototypes remain
  rejected and are documented as evidence for producer-side construction.
- [x] Independent review reports no unresolved issue.

## Measurements

Both accepted-stage samples produced the same semantic results.

| Metric | Issue 79 baseline | Candidate | Change |
| --- | ---: | ---: | ---: |
| Allocations | 278,382 | 278,382 | 0.0000% |
| Releases | 189,380 | 189,380 | 0.0000% |
| Retained objects | 89,002 | 89,002 | 0.0000% |
| Allocated bytes | 6,490,056 | 6,490,056 | 0.0000% |
| Retired instructions | 8,460,316,056 | 8,467,018,989 | +0.0792% |
| Cycles | 2,322,167,528 | 2,344,974,502 | +0.9821% (one-shot noise) |
| Maximum RSS | 40,206,336 | 40,108,032 | -0.2445% |
| Peak footprint | 33,620,280 | 33,554,744 | -0.1950% |
| Compiler bytes | 19,406,144 | 19,406,176 | +0.0002% |

Detailed evidence is retained in
[`compiler_accepted_callable_source_names_step2e_2026-09-11.md`](../../../benchmarks/results/compiler_accepted_callable_source_names_step2e_2026-09-11.md)
and its TSV companion. The cycle sample is retained for reproducibility and is
not a latency claim.

## Next Packet

Move accepted-callable local visibility and UFCS lookup to a compact list
relation constructed directly from accepted callable records. The implemented
follow-up is
[`81-replace-accepted-callable-string-index.md`](81-replace-accepted-callable-string-index.md):
stable-group source names within each producer-owned module list, retain one
canonical slot range per dense module ID, and replace—not accompany—the old
`indices_by_module_and_name` dictionary.
