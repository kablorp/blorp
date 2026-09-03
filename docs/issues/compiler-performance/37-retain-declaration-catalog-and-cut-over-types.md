# Retain The Declaration Catalog And Cut Over Types

**Status:** Ready for implementation

**Dependencies:** Issues 34 and 36 (complete)

**Parallel work:** None required. Issue 35 was rejected after its production-
path audit and introduces no graph-facts product or integration conflict.

## Objective

Build one accepted declaration catalog as a production Stage 06 graph product,
retain compact module visibility projections, and make the catalog/module view
the sole accepted-semantic authority for aliases, types, constructors, and
fields.

This issue must replace work immediately. It is not acceptable to retain a
catalog while continuing to publish the same type declarations into every
module `Env`.

## Context

Issue 36 provides a builder that consumes pre-assembly graph products. Issue 34
provides a narrow reusable module product that can refer to graph-level
authority without retaining an entire prior typecheck session.

The current module-view/type projections and definition identities should be
reused. Do not create a second index keyed by display strings.

## Required Change

1. Build the catalog once after accepted headers and completed global types are
   available and before final graph facts are published.
2. Retain it in shared `TypecheckGraphFacts`, used by both accepted and
   recoverable graph wrappers.
3. Build one compact canonical module view per accepted module. A view contains
   only identities/projections required for visibility, qualification, aliases,
   and deterministic ambiguity handling.
4. Add category-specific exact and visible-name queries for:
   - aliases;
   - type declarations;
   - constructors; and
   - fields.
5. Route all production accepted-semantic readers for those categories through
   catalog/view queries.
6. Delete their imported and local graph-symbol writes to `Env`, along with any
   category indexes that no longer have lexical consumers.
7. Apply the same catalog authority to canonical preparation and the existing
   CTFE artifact preparation path while preserving dependency-only CTFE
   visibility. Do not create or assume a retained CTFE prepared environment;
   Issue 35 rejected that product after proving no repeated production build.

Exact lookup must validate nominal kind and owner. Visible-name lookup must use
the current module view and preserve ambiguity behavior. Do not expose a
generic untyped declaration query.

`DefinitionIndex` remains authoritative for source-definition identity and
navigation IDs, including Issue 32's owner-directed type-occurrence lookup.
Catalog entries and views must carry and reuse those established IDs; they must
not create a second identity namespace or reroute navigation through copied
semantic records.

For recoverable completion, build the catalog and views in shared facts from
accepted headers plus only the successfully completed global subset. Preserve
`global_completion_failures` and the existing failed-module exclusion before a
prepared module can be used. Add a fixture proving an unaffected module still
typechecks without seeing a failed or partial global as completed.

## Non-Goals

- Do not migrate globals, callables, overloads, traits, implementations, or
  UFCS.
- Do not redesign type identity or import semantics.
- Do not retain parallel `Env` reads as a fallback.
- Do not optimize lexical scopes.
- Do not change error wording or winner selection.
- Do not replace `DefinitionIndex` as source/navigation identity authority.

## TDD And Structural Proof

First add assertions requiring:

```text
accepted_declaration_catalog_builds == 1
catalog_type_entries == accepted_type_family_declarations
canonical_module_views_built == accepted_module_count
legacy_type_family_graph_symbol_installs == 0
```

Cover local, selective, aliased, qualified, and ambiguous type names;
same-spelling declarations owned by different modules; constructors and fields;
rejected declarations; and wrong-kind IDs. Add an unrelated module to the graph
and prove an exact query visits no additional candidates.

## Acceptance Criteria

- One catalog is built and retained per accepted graph.
- One canonical visibility view is built per accepted module.
- Type-family declarations are stored once in the catalog, not copied into
  module `Env` values.
- All type-family production reads use typed catalog/view queries.
- Legacy type-family writes, reads, indexes, and adapters are deleted.
- Exact results, ambiguity behavior, and diagnostics are unchanged.
- Accepted and recoverable graphs share catalog/views; recovery excludes failed
  modules and keeps unaffected modules usable.
- Increasing body count does not increase catalog or view construction.
- Focused Stage 06 tests and `scripts/compiler-check --changed` pass.
- `docs/ARCHITECTURE.md` describes the new type-family authority boundary in
  this same merge.

## Verification

Run catalog, type occurrence, import visibility, constructor/field, prepared
module, CTFE visibility, and frontend benchmark fixtures. Inspect logical
construction and query counters. Build once before merge and run the affected
Stage 06 manifest/tests. Record the controlled milestone latency comparison
here because Issue 35 produced no implementation or integration boundary.
