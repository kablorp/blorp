# Cut Over Graph Globals To The Declaration Catalog

**Status:** Implemented

**Dependencies:** Issue 37

**Parallel work:** Later-family inventories may proceed, but implementation
should integrate serially with Issues 39-41 because they share `Env`, module
view, and declaration-query surfaces.

## Objective

Make the accepted declaration catalog and module views the sole authority for
graph-owned globals. Remove completed global declaration records from module
`Env` storage while preserving initializer dependency ordering and lexical
shadowing.

Globals are isolated from callable overload and UFCS semantics, so they are the
smallest value-category cutover after type families.

## Required Change

1. Inventory every production global lookup and publication path, including:
   - exact global identity;
   - unqualified, selective, aliased, and qualified source names;
   - global initializer dependency planning;
   - completed versus merely declared global types;
   - lexical shadowing; and
   - CTFE dependency visibility.
2. Add typed catalog queries for exact global identity and module-view queries
   for visible global source names.
3. Preserve the distinction between a declared global header and a completed
   inferred global type. The catalog must not expose a global as completed
   before the current dependency plan permits it.
4. Route production reads through catalog/view queries.
5. Delete imported and local graph-global writes and indexes from `Env`.
6. Delete adapters that reconstruct a legacy global `Symbol` solely for old
   lookup APIs.

Session-local variables remain in lexical `Env` and retain current precedence
over visible graph globals.

## Non-Goals

- Do not migrate function values or callables.
- Do not change initializer cycle detection or dependency order.
- Do not make incomplete globals visible to simplify caching.
- Do not merge lexical variables into the catalog.
- Do not preserve old global lookups as fallback.

## TDD And Structural Proof

Add or strengthen tests for:

- a local variable shadowing an imported global;
- direct, selective, aliased, and qualified global imports;
- same-name globals from different modules and exact ambiguity diagnostics;
- initializer dependency ordering and cycle errors;
- incomplete globals remaining unavailable;
- CTFE dependency visibility excluding target-only globals;
- rejected globals never entering views; and
- wrong-kind nominal IDs failing closed.

Require:

```text
catalog_global_entries == accepted_completed_globals
legacy_graph_global_installs == 0
global_exact_query_graph_scans == 0
```

## Acceptance Criteria

- Accepted graph globals are stored once in the catalog.
- Module views carry only global identity/visibility projections.
- Lexical locals still shadow graph globals correctly.
- Global completion order and exact diagnostics are unchanged.
- No graph-global record or index remains in `Env`.
- No compatibility wrapper or dual read remains.
- Focused global, initializer, CTFE, and import tests pass.
- Logical work decreases and latency does not clearly regress.
- Recoverable graphs expose only successfully completed globals to unaffected
  modules and continue to exclude failed modules.
- `docs/ARCHITECTURE.md` describes catalog-owned globals in this same merge.

## Verification

Run focused global-header, initializer, import, CTFE, prepared-module, and
frontend benchmark tests, followed by `scripts/compiler-check --changed` and
the affected Stage 06 manifest/tests. Inspect the completed/incomplete global
state explicitly rather than relying only on successful typechecking.

The completed implementation passed `scripts/compiler-check --changed`: five
production sources selected ten focused suites and five declaration-catalog
boundary checks. `scripts/test compiler-blorp` also passed all 4,152 tests.

Three alternating Phase 01-06 self-check pairs against `origin/main` at
`475e42ed` produced:

```text
control:   27.30s / 462,508,263,801 instructions
candidate: 27.23s / 458,443,713,787 instructions
control:   28.40s / 463,216,016,325 instructions
candidate: 27.23s / 458,312,167,467 instructions
control:   27.04s / 462,623,943,076 instructions
candidate: 26.94s / 458,164,295,018 instructions
```

Median wall time fell from 27.30 to 27.23 seconds. Median retired instructions
fell from 462,623,943,076 to 458,312,167,467, a reduction of 4,311,775,609
instructions (0.93%). Peak RSS remained within 0.2%.

## Implementation Result

Stage 06 now retains one category-specific accepted-global table alongside the
completed initializer graph. Canonical module facts retain compact source-name
to table-slot views. Initializer sessions reuse those views with an exact
dependency availability set; canonical and CTFE body sessions switch the same
view to completed-only availability.

Accepted local and imported globals are no longer published into `Env`.
Unqualified, selectively aliased, and qualified reads query the retained
authority directly, while lexical `Env` bindings keep precedence. Mutation,
capture, resource-capability, and range-refinement checks also consult the
typed global binding without reconstructing a legacy `Symbol`.

Canonical module views populate owner-local globals from the table's module
index and resolve selective imports from its module-path index. They do not
rescan the graph-global list per module; selective imports owned by other
declaration categories are ignored at this category boundary.

Annotated globals obtain their definition IDs directly from the prepared
module scope's definition index. Table construction does not create a throwaway
`TypecheckState` for each global. Completed bindings are attached to the table
in one final update, and owner-local type spelling is projected once when the
immutable table is built rather than on every source lookup.

The structural counters require one completed catalog entry per accepted
completed global, zero legacy graph-global installations, and zero graph scans
for exact queries. The legacy module-variable lookup and its graph publication
helpers were deleted.
