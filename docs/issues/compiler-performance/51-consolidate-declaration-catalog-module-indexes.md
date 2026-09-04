# Consolidate Declaration Catalog Module Indexes If Measured

**Status:** Deferred until a production catalog-retention milestone,
measurement-gated

**Dependencies:** Issue 43, or another accepted milestone that retains and
queries `AcceptedDeclarationCatalog` in production, must be complete. Issues
46-50 must also be complete or explicitly rejected. Reprofile from the
immediate parent before implementation.

**Blocks:** None.

**Parallel work:** None in declaration catalog construction, accepted category
authorities, or declaration identity lookup.

## Objective

Determine whether the accepted declaration catalog can replace eight separate
outer module dictionaries and repeated module storage-key construction with one
module-bucketed index that preserves category-specific inner lookup.

This issue begins with a cost-share and strategy comparison. It is not approved
to implement a dense representation merely because the current shape is
verbose. The retained form may be a dense module list, one consolidated
descriptive module dictionary, or no change. Evidence chooses the result.

## Required Reading

Read `AGENTS.md`, Issues 15, 36-47, and:

- `headers/declaration_catalog.brp`;
- `headers/declaration_skeleton.brp`;
- `headers/type_header_graph.brp`;
- `headers/callable_headers.brp`;
- `headers/trait_headers.brp`;
- `headers/implementation_headers.brp`;
- accepted alias/record/union/global/callable authorities;
- definition identity/index and semantic occurrence code; and
- declaration catalog/profile tests and ownership manifest.

## Current Shape

`AcceptedDeclarationCatalogRep` owns ordered entry lists plus separate indexes:

```text
type_index_by_module_and_name
constructor_index_by_module_and_definition_id
callable_index_by_module_and_definition_id
global_index_by_module_and_name
trait_index_by_module_and_definition_id
trait_method_index_by_module_owner_and_slot
implementation_index_by_module_and_definition_id
implementation_method_index_by_module_owner_and_callable
```

Each index has an outer `Dict[String, ...]` keyed by
`module_identity_storage_key`. Catalog construction also builds temporary
visibility and runtime-category dictionaries with the same outer dimension.
The file currently contains approximately 17 module storage-key call sites.

The entry lists and returned `TypeId`, `GlobalId`, `CallableId`, `TraitId`, and
`ImplId` are durable products. Public exact-find APIs accept those identities,
not a prepared scope. In the current tree, repository-wide search finds no
production call to `accepted_declaration_catalog_build` or any catalog find
API outside its defining module. Calls exist only in the benchmark and tests.
Its current production cost share is therefore exactly zero, and this issue
must not start implementation against the present tree. A future retained
catalog can still make a dense graph slot costly unless real callers already
own graph provenance.

Issue 46 measured and rejected separate global and callable module-index
prototypes. This issue must not recreate either candidate unchanged.

## Mandatory Measurement Gate

After the production-retention dependency is met and before production edits:

1. capture exact catalog construction calls, entries by category/module,
   storage-key constructions, outer/inner persistent updates, allocations,
   releases, retained bytes, and retired instructions;
2. capture exact production calls to every catalog find API;
3. report empty-module and category-density distributions for the compiler
   self-check; and
4. identify which callers, if any, already own a compatible prepared scope.

If repository-wide call-site search still finds no production builder and
reader, close the issue as dependency-blocked without a benchmark. Otherwise,
stop after documentation if catalog construction plus reads account for less
than 0.5% of Stage 06 retired instructions and less than 0.5% of Stage 06
allocations. Do not create a benchmark-only consumer to inflate the share.

## Candidate Strategies

Compare all three with identical semantic inputs:

### A. Current independent outer dictionaries

This is the baseline. Record exact outer COW updates and key construction.

### B. One descriptive module bucket dictionary

Use one outer module key to select a private record containing category-specific
inner dictionaries. This preserves durable query admission and can remove
parallel outer dictionary updates without graph-slot conversion.

### C. Dense graph-owned module buckets

Use one exact-length list of private module buckets, addressed only through a
compatible prepared scope. Preserve a narrow durable-identity boundary for
public find functions. This strategy is eligible only if production callers
can avoid repeated identity-to-slot conversion and empty module buckets do not
erase the allocation gain.

Do not compare a hand-written model to production. Temporary strategy selection
must execute the actual candidate builders/readers and must be removed before
commit.

## Possible Bucket Shape

The following is illustrative, not pre-approved:

```blorp
private record DeclarationCatalogModuleIndices {
	types_by_name: Dict[String, Int],
	constructors_by_definition_id: Dict[Int, Int],
	callables_by_definition_id: Dict[Int, Int],
	globals_by_name: Dict[String, Int],
	traits_by_definition_id: Dict[Int, Int],
	trait_methods_by_owner_and_slot: Dict[Int, Dict[Int, Int]],
	implementations_by_definition_id: Dict[Int, Int],
	implementation_methods_by_owner_and_callable: Dict[Int, Dict[Int, Int]]
}
```

If Blorp record allocation makes one empty bucket per module expensive, compare
an optional bucket or consolidated descriptive dictionary. Do not introduce a
heuristic density threshold; choose one representation from the measured
matrix or reject the issue.

## Implementation Plan

### 1. Pin all category semantics

Before altering the catalog, add exact public tests for every entry/find API,
all duplicate errors, runtime definition-category reuse, product provenance,
visibility matching, and deterministic metrics/checksum.

### 2. Build a table-driven comparison fixture

Generate canonical modules and declarations once, then feed the same input to
all strategies. Vary category density independently. The expected checksum and
duplicate outcomes must be derived from fixture declarations, not copied from
one strategy.

### 3. Select one strategy before cutover

Use allocation counts and retired instructions as primary evidence. Report
results by module count, declaration count, category mix, and empty-module
density. If no strategy wins the predeclared representative region, restore
all production experiments and close the issue as rejected.

### 4. Cut over construction, then reads

Keep entry lists and insertion order unchanged. Replace duplicate checks and
indexes category by category inside the selected module bucket, running exact
tests after each category. Preserve public durable-identity find signatures.
Add a scope-aware read only for a real production caller that already has the
scope; do not add speculative API.

### 5. Delete old indexes and measurement surface

Remove every superseded outer dictionary, helper, fallback, strategy switch,
and test-only accessor. Keep temporary visibility indexes descriptive unless
the same measurement proves their conversion wins as part of the selected
construction window.

## Non-Goals

- Do not change declaration entry records, durable IDs, definition-ID
  allocation, diagnostics, visibility, overload order, or semantic occurrence.
- Do not merge accepted global/callable authority tables into the catalog.
- Do not change `Env`, `Scope`, module views, or declaration publication.
- Do not expose module buckets, slots, or catalog internals.
- Do not add caching, mutable tables, lazy initialization, or a density
  heuristic.
- Do not retain both descriptive and dense indexes after cutover.

## TDD Plan

Required tests:

1. empty catalog and modules with no declarations;
2. one entry for each of all eight categories;
3. mixed categories in exact source order;
4. same names and definition IDs in different modules;
5. private/public visibility provenance;
6. every duplicate error variant with exact identity/order;
7. runtime definition-ID reuse across categories;
8. trait owner/method slot and implementation owner/callable nesting;
9. first/middle/final module lookup;
10. wrong graph/origin and direct/provisional behavior;
11. exact metrics, builder visits, duplicate checks, and checksum; and
12. semantic occurrence/LSP projection remains byte-identical.

## Measurement Matrix

```text
modules:              1, 8, 32, 128
declarations/module:  0, 1, 16, 64, 256
category mix:         each category alone, even mixed, callable-heavy,
                      type-heavy, trait/implementation-heavy
populated modules:    10%, 50%, 100%
query count/entry:    0, 1, 16
query position:       first, middle, final, missing
```

Every row records module/category dimensions, entries, exact duplicate checks,
storage-key constructions, outer/inner updates, bucket publications, list/dict
reads, candidates visited, semantic checksum, errors, elapsed, allocations,
releases, current objects/bytes, retired instructions, cycles, and RSS.

Run strategies paired or rotating by configuration. Use one warmup and at
least three measured pairs for every representative 256-header sentinel and
production row. Require identical responses and allocator availability for
replay.

## Fast Feedback

1. Run the existing declaration catalog suite and record baseline counts.
2. Add one table test covering all categories and duplicates.
3. Run the cost-share scout before production representation edits.
4. Compare 8x16 mixed and 128x1 sparse rows first.
5. Reject immediately if both candidate strategies allocate more in either
   representative row without offsetting retired-instruction improvement.
6. Inspect generated C for outer COW updates, record allocations, one final
   bucket product, and absence of parallel indexes.
7. Only after strategy selection run the full matrix, changed/typecheck/LSP
   gates, and production replay.
8. Finish with code-reviewer, test-runner, and code-optimizer.

## Acceptance Criteria

- The pre-edit cost-share gate is met by real production construction/queries.
- All category entries, duplicate errors, metrics, order, checksums, and public
  lookup results remain exact.
- The selected strategy reduces median catalog-window allocations or retired
  instructions by at least 15% for the 8x16 mixed and 256-declaration
  representative workloads.
- No populated-density region regresses both median allocations and retired
  instructions by more than 5%.
- Empty-module retained bytes and object counts are reported; production median
  peak RSS must not regress by more than 0.5%.
- Production Stage 06 allocations/releases improve by at least 0.10% or
  whole-compiler median retired instructions improve by at least 0.10%.
- Whole-compiler retired instructions do not regress by more than 0.05% when
  accepting on allocations.
- Production median elapsed must not regress by more than 1.0%.
- Production replay and semantic/LSP projections are byte-identical.
- Generated C proves the selected one-bucket boundary and absence of old outer
  indexes.
- No alternate implementation or benchmark-only public surface remains.
- All required reviews approve.

If the cost-share or performance gates fail, document the three-way comparison
and restore production. The rejected result is useful evidence; an unused
dense catalog is not.
