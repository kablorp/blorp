# Normalize Accepted Trait-Method Visibility

**Status:** Complete

**Roadmap:** [Normalized Semantic Compilation Roadmap](NORMALIZED_SEMANTIC_COMPILATION_ROADMAP.md), Step 2e, twenty-first packet

**Depends on:** Exact accepted trait-method selection and accepted call identity (Issues 87-91)

## Outcome

Accepted bare trait-method visibility is now a compact relation of exact source
and semantic identities:

```blorp
private record AcceptedVisibleTraitMethodRow {
	source_name_id: SourceNameId,
	method_id: TraitMethodId
}
```

The accepted authority retains these rows sorted by `SourceNameId` and uses a
lower-bound binary search for bare method lookup. The former
`Dict[String, TraitMethodId]` is deleted rather than retained beside the new
relation.

Selective method imports are resolved from `ModuleId + original spelling` to
an exact `TraitMethodId` once, while accepted visibility is being constructed
against the published accepted trait table. Authority construction and lookup
therefore no longer rescan all public traits in an imported module to recover
semantic identity from text.

Strings remain where they still have a legitimate role:

- parsing and import binding supply source spellings;
- a `SourceNameTable` maps a lookup spelling to compilation-local
  `SourceNameId` at the source boundary;
- ambiguity and invalid-table diagnostics project spellings and trait names;
- compatibility-only graphless resolution remains explicitly string-backed.

## Context

Issue 87 made `TraitMethodId` the accepted method identity, but the visibility
adapter still retained a late recipe:

```blorp
AcceptedVisibleTraitMethodBinding(String, ModuleId, String)
```

When the target authority was built, it used that recipe to scan every public
trait in the module, traverse inherited methods, compare method spellings, and
populate another string-keyed dictionary:

```blorp
trait_method_id_by_name: Dict[String, TraitMethodId]
```

That representation was transitional. By that point the compiler already had
all three normalized domains needed to express the fact directly:

1. `SourceNameTable` had assigned a compact identity to the local spelling.
2. `AcceptedTraitImplementationTable` had published topology-backed
   `TraitMethodId` values.
3. `ImportBinding` preserved the exact imported module and original spelling
   needed to join those tables.

Leaving the recipe in the authority delayed a deterministic join, repeated
semantic discovery for every module authority, and kept managed source strings
in a product that should operate on values derived by compilation. It also
made the dictionary look authoritative even though it was reconstructed from a
mix of local, selective, and compiler-prelude visibility rules.

## Invariants

1. `SourceNameId` is source-spelling identity only; `TraitMethodId` is semantic
   method identity. Neither substitutes for the other.
2. Every accepted visible method row contains both identities and no managed
   string.
3. Selective method imports are converted to exact rows only after the accepted
   trait table is available.
4. A selective method import must identify a public method in the exact
   imported module or accepted visibility construction fails.
5. Local, inherited, selectively imported, aliased, and compiler-prelude bare
   methods preserve their existing visibility.
6. Direct qualified-module imports remain UFCS evidence but do not create bare
   method rows.
7. Rows are sorted by `SourceNameId`; lookup does not linearly scan method rows.
8. Duplicate rows with the same source and method identity collapse to one row.
9. The same source identity pointing at distinct methods remains an explicit
   preparation error with source and declaring-trait spellings.
10. Exact lookup validates the selected `TraitMethodId` against the authority's
    accepted table before returning a binding.
11. The old string dictionary is removed. No parallel integer dictionary,
    generic integer map, magic sentinel, or spelling heuristic is introduced.
12. The source-name table and accepted table remain compilation-local and
    provenance-bound; no process-global interner is created.

## Code Examples

### Selective alias

Given:

```blorp
import:
	dep: render as display

pure func show[T: dep.Renderable](value: T) -> String:
	display(value)
```

the module binder still publishes the source-facing import row:

```blorp
GraphSelectiveTraitMethodBinding(
	"display",
	dep_module_id,
	"render",
	overlapping_definition_ids,
)
```

Accepted visibility immediately joins it with the compilation source-name
table and accepted trait topology:

```blorp
AcceptedVisibleTraitMethodBinding(display_source_name_id, render_method_id)
```

The accepted authority retains the same pair as a normalized row. Later bare
lookup crosses the string boundary once and searches by the compact source ID:

```blorp
source_name_id ?= source_name_table_find_id(source_names, method_name)
row ?= visible_trait_method_for_source_name(visible_trait_methods, source_name_id)
found ?= table_find_trait_method_by_id(authority, row.method_id)
```

### Collision diagnostics

Two genuinely unqualified traits may still expose the same source spelling:

```blorp
trait Left:
	pure func measure(value: Self) -> Int

trait Right:
	pure func measure(value: Self) -> Int
```

Normalization detects that one `SourceNameId` maps to two distinct
`TraitMethodId` values. Only the error path projects text:

```text
method 'measure' is already registered under trait 'Left'; cannot also register under 'Right'
```

## Implementation Strategy

### 1. Prove the representation before changing it

The millisecond structural test first required:

- an `AcceptedVisibleTraitMethodRow` containing exactly `SourceNameId` and
  `TraitMethodId`;
- an exact `AcceptedVisibleTraitMethodBinding(SourceNameId, TraitMethodId)`;
- authority storage as `List[AcceptedVisibleTraitMethodRow]`;
- lookup through `source_name_table_find_id` and the compact row relation; and
- absence of the old `Dict[String, TraitMethodId]`.

Those assertions failed against Issue 91 before implementation. This keeps the
packet honest: behavior tests alone could pass while a new ID index merely sat
beside the old string authority.

### 2. Catalog trait method source names at graph construction

`source_name_candidates_for_decl` now includes declared trait method names.
They are source-visible bare names in their owner module, so they belong in the
compilation source-name domain. The catalog still excludes record fields,
parameters, and implementation method bodies; those are different lexical or
semantic domains.

Selective imported aliases were already cataloged from their import syntax.
This preserves the rule that graph admission, rather than late typechecking,
owns the compilation-local source-name domain.

### 3. Resolve selective imports at the accepted boundary

`accepted_visible_trait_bindings` now receives the graph's `SourceNameTable`.
For each `GraphSelectiveTraitMethodBinding`, it:

1. converts the local spelling to `SourceNameId`;
2. selects only traits owned by the exact imported `ModuleId`;
3. filters out private traits;
4. traverses inherited accepted methods;
5. matches the original imported spelling; and
6. emits `SourceNameId + TraitMethodId`.

If any identity is absent or incompatible, the visibility product is rejected.
The authority does not retain an unresolved scan recipe or silently fall back
to a name-only match.

### 4. Normalize all bare-method sources into one relation

Authority construction contributes exact rows from three legitimate sources:

- local visible traits;
- compiler-linked prelude traits; and
- exact selective method bindings.

The candidates are stable-sorted by the numeric table position underlying
`SourceNameId`. A single traversal collapses identical duplicates and reports
distinct semantic collisions. The final authority owns one compact list, not a
list plus a dictionary.

### 5. Search the compact relation at the boundary

`accepted_trait_find_function_method` maps its public string parameter through
the retained source-name table, performs a lower-bound binary search, and then
validates the exact method ID through the accepted table. A regression arranges
three rows whose construction order differs from source-ID order, then verifies
the first, middle, and last rows independently. This protects sorting and both
sides of the lower-bound search.

### 6. Keep diagnostics descriptive, not authoritative

Collision reporting projects the source spelling with
`source_name_table_spelling` and declaring trait names with `trait_id_name`.
Those projections occur only after exact IDs demonstrate the collision. Text
therefore explains a semantic fact instead of deciding one.

## Fast Feedback Loops

Use the narrowest loop that matches the layer being changed:

```bash
# Representation contract; approximately milliseconds.
python3 blorp/test/compiler/stage_06_typecheck/support/test_declaration_boundary.py

# Source-name admission.
bin/blorp test blorp/test/compiler/stage_06_typecheck/test_indexed_graph.brp

# Visibility construction, sorting, collision, inheritance, and lookup.
bin/blorp test blorp/test/compiler/stage_06_typecheck/test_typecheck_decl.brp

# End-to-end accepted selection through inference.
bin/blorp test blorp/test/compiler/stage_06_typecheck/test_typecheck_bridge.brp
```

The retained performance loop is one baseline/candidate pair, not repeated wall
time sampling:

```bash
/usr/bin/time -lp benchmarks/compiler_typecheck_phase_profile \
  accepted 1 32 4 16 16 memory
```

Compare deterministic checksums and allocation counters first, then retired
instructions, cycles, RSS, peak footprint, and executable size. Treat one-shot
wall time as an observation. If verbose exact-profile output can block its
caller, omit wall time and use a quiet counter-only run before making any
latency claim.

Once the narrow suites and one measurement pair are stable, run the manifest
owner gate once:

```bash
scripts/compiler-check --changed
```

This sequence keeps ordinary edit feedback under seconds and reserves the
multi-minute gate for the completed packet.

## Acceptance Criteria

- [x] A failing structural test proves the old string dictionary and scan
  recipe before implementation.
- [x] Declared trait method spellings receive `SourceNameId` values, while
  fields and implementation method bodies remain outside this source domain.
- [x] Accepted selective method bindings retain exact
  `SourceNameId + TraitMethodId` pairs.
- [x] The authority stores a sorted compact row list and no
  `Dict[String, TraitMethodId]`.
- [x] Local, inherited, selectively imported, aliased, private, qualified-only,
  compiler-prelude, and collision behavior remains covered.
- [x] A multi-row regression covers first, middle, last, and absent lower-bound
  lookup outcomes when construction order differs from source-ID order.
- [x] Invalid imported modules, private methods, missing source IDs, and foreign
  table provenance fail instead of selecting by heuristic.
- [x] Focused structural, indexed-graph, declaration, and bridge suites pass.
- [x] The production compiler checks itself without formatting or type errors.
- [x] The manifest-owned changed check passes.
- [x] One direct authority measurement pair preserves semantic checksums and
  keeps retained memory, instructions, cycles, RSS, peak footprint, and compiler
  size within the 2% investigation threshold.
- [x] Independent code review passes; independent test review's only identified
  lookup-coverage gap is closed by the multi-row regression.

## Measurements

The direct accepted-authority screen preserves all semantic checksums and work
counts. Retained objects and allocated bytes are exactly neutral. It adds 396
transient allocations and releases across 66 authority constructions
(+0.1497% allocations), retired instructions increase 0.3251%, cycles increase
1.2606%, maximum RSS increases 0.0871%, and peak footprint increases 0.0529%.
Compiler size grows 448 bytes (+0.0023%).

The broad checked-bodies screen is exactly neutral for allocations, releases,
retained objects, allocated bytes, and peak footprint. Retired instructions,
cycles, and RSS remain within 0.20%; setup improves 0.16%. Its one-shot window
is +1.07% and is not treated as a latency claim.

The direct run's verbose exact-profile output blocked while the calling tool
was not draining its pipe, invalidating external wall time. The internal
one-shot accepted window was +5.54%, so this packet makes no latency-improvement
claim. The deterministic memory and machine-work counters show no material
regression, and the representation removes a managed string dictionary without
adding a parallel index.

Full evidence and raw values are recorded in
[`compiler_accepted_trait_method_visibility_rows_step2e_2026-09-12.md`](../../../benchmarks/results/compiler_accepted_trait_method_visibility_rows_step2e_2026-09-12.md)
and
[`compiler_accepted_trait_method_visibility_rows_step2e_2026-09-12.tsv`](../../../benchmarks/results/compiler_accepted_trait_method_visibility_rows_step2e_2026-09-12.tsv).

## Validation Evidence

- `make -j1` rebuilt the self-hosted compiler successfully.
- `scripts/compiler-check --changed` passed 3 production sources, 12 focused
  suites, and 1 special check in 20.37 seconds.
- The structural suite passed all 48 checks.
- The indexed-graph suite passed all 22 tests.
- The declaration suite passed all 147 tests.
- The typecheck bridge suite passed all 123 tests.
- Independent code review found no correctness, architecture, or maintainability
  issue. Independent test review requested a multi-row lower-bound regression;
  that regression now passes in the declaration suite.

## Performance Expectations And Rollback

The long-term gain is representation and lifetime discipline: accepted
authority state no longer retains source strings as semantic method identity,
does not duplicate a new numeric index beside the old dictionary, and does not
repeat the selective-import module scan after visibility construction. These
properties should improve locality and reduce retained managed state as more
accepted queries migrate to table rows.

This fixture contains relatively few visible trait methods, so table creation
and exact import joining dominate the removed dictionary cost. The packet is
accepted because retained objects and bytes are neutral and all direct machine
counters remain within 2%, not because a noisy one-shot latency moved in a
favorable direction.

Rollback should remove the packet as one coherent unit. Do not restore the old
string dictionary while retaining numeric rows, and do not paper over a future
regression with a second generic integer dictionary. If a trait-heavy workload
shows material cost, first retain a focused fixture that exposes the cost, then
optimize the compact row construction or source-name lookup directly.

## Next Packet

Completed by
[`93-normalize-accepted-trait-definition-visibility.md`](93-normalize-accepted-trait-definition-visibility.md):
accepted trait-definition visibility now retains compact `SourceNameId + TraitId`
rows and deletes the displaced visible-trait string map. Semantic-name
compatibility and graphless Env migration remain separate work.
