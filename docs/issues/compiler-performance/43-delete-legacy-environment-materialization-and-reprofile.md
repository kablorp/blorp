# Delete Legacy Environment Materialization And Reprofile

**Status:** Blocked on Issue 42

**Dependencies:** Issues 33, 34, and 36-42. Issue 35 was rejected after its
production-path audit and is not an implementation dependency.

**Parallel work:** None. This is the mandatory cleanup and proof step after all
declaration families have one authority.

## Objective

Delete every obsolete graph-to-`Env` materialization path, adapter, dead field,
fallback, and migration-only comparison. Make `Env`'s lexical responsibility
explicit, add permanent regression assertions, and measure the completed
architecture using a controlled Phase 01-06 compiler self-check.

## Precondition

Before deleting code, produce an inventory showing that every accepted
declaration category has:

| Category | Catalog storage | Module-view visibility | Production readers | Legacy readers | Legacy writers |
| --- | --- | --- | --- | --- | --- |

Include aliases, types, constructors, fields, globals, functions, foreign
functions, builtins, overloads, traits, trait methods, implementations,
implementation methods, UFCS candidates, resource facts, and debug-only facts.

Every row must have catalog/view readers and zero required legacy readers.

## Required Deletion Order

Delete in this order so compiler errors reveal missed consumers:

1. imported-module graph declaration publication loops;
2. accepted local-header graph publication loops;
3. category-specific graph insertion helpers;
4. generic mixed-symbol batching helpers with no lexical caller;
5. graph-only fields/indexes in `Scope`, `Env`, `TypecheckState`, prepared
   modules, and graph facts;
6. adapters that reconstruct legacy symbols or overload records;
7. fallback and dual-read branches;
8. migration-only old/new answer comparisons;
9. tests that exist only to create an obsolete graph-materialized state; and
10. stale imports, wrappers, comments, counters, and documentation.

Use `rg` after each family. Do not leave deprecated aliases or compatibility
wrappers; Blorp is pre-0.1.

## Lexical `Env` End State

Every remaining `Scope`/`Env` field and helper must have one documented owner:

- lexical variables, parameters, or local functions;
- nested scope order and shadowing;
- local type parameters and bounds;
- flow-sensitive refinements;
- inference state with one explicit session lifetime; or
- another body-local fact that genuinely varies per check.

Accepted module declarations, visibility, and graph identity must not remain in
`Env`.

## Permanent Structural Assertions

Keep stable counters or focused production-shaped observations requiring:

```text
accepted_declaration_catalog_builds == 1
canonical_module_views_built == accepted_module_count
legacy_graph_symbol_installs == 0
legacy_imported_declaration_publications == 0
legacy_local_declaration_publications == 0
ordinary_body_environment_rebuilds == 0
exact_catalog_query_graph_scans == 0
```

Also prove that catalog construction scales with accepted declarations, module
views with actual visibility edges, and lexical insertion with body-local
declarations—not body count times each module's full visible graph closure.

## Controlled Reprofile

Use the same bootstrap compiler, source revision relationship, build mode,
fixture, stop-after Phase 06 behavior, and sampling/counting procedure as the
baseline. Capture:

- unsampled wall latency over repeated comparable runs;
- macOS 1 ms sample stacks;
- LLVM exact function-entry counts;
- allocations, releases, retained objects, and bytes;
- catalog, view, prepared-environment, session, and legacy-install counters;
  and
- the new top Stage 06 bottlenecks.

Report overlap honestly. Inclusive stack percentages are not additive and are
not predicted speedups. Do not add an unrelated optimization to improve the
final number.

## Documentation

Update `docs/ARCHITECTURE.md` with:

- the catalog authority boundary;
- canonical versus CTFE dependency-view lifetimes;
- prepared module versus session responsibilities; and
- lexical-only `Env` ownership.

Issues 37-42 must already have kept the per-family authority description
accurate at every merge point. This issue consolidates the final lexical-only
description and removes transitional wording; it is not the first architecture
update in the sequence.

Remove or archive superseded performance issues and claims whose premises no
longer match source.

## Acceptance Criteria

- The precondition inventory has no legacy reader/writer.
- All obsolete builders, fields, adapters, and fallbacks are deleted.
- `Env` is lexical/session-only and documented.
- Permanent zero-work/scaling assertions pass.
- Exact compiler results and diagnostics remain unchanged.
- Focused and proportionate ownership/leak/sanitizer checks pass.
- The controlled Phase 01-06 report records the real improvement and remaining
  bottlenecks with no material latency regression.
- No generated artifacts remain in the repository.

## Verification

At minimum, run the Stage 06 manifest, compiler-owned fixtures, relevant leak
and sanitizer tests, frontend catalog/profile tests, `scripts/compiler-check
--changed`, and `make quality` when the deleted surfaces affect C-facing code.
Use the repository's current premerge gate if it is proportionate at the final
revision.
