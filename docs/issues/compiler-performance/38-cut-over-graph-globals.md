# Cut Over Graph Globals To The Declaration Catalog

**Status:** Blocked on Issues 35 and 37

**Dependencies:** Issues 35 and 37

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
