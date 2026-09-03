# Decouple Accepted Declaration Catalog Construction

**Status:** Implemented

**Dependencies:** None

**Parallel work:** May run alongside Issues 32 and 33. This issue must remain
inside the isolated catalog builder/tests and must not add fields to production
graph facts; Issue 37 owns that integration.

## Objective

Refactor the existing accepted declaration catalog so it can be built from the
concrete completed Stage 06 products without importing `decl.brp` or consuming
an already-assembled `AcceptedTypecheckGraph`.

This is dependency inversion only. It prepares the catalog for production
retention without creating recursive graph ownership or adding a second
catalog.

## Required Reading

Read `docs/LEARN_BLORP_IN_Y_MINUTES.md`, the roadmap, and:

- `blorp/src/compiler/stage_06_typecheck/headers/declaration_catalog.brp`;
- the definition of `AcceptedTypecheckGraph` in `decl.brp`;
- `TypecheckGraphFacts` and completed global-header products;
- `blorp/test/compiler/stage_06_typecheck/test_declaration_catalog.brp`; and
- `blorp/benchmark/compiler/compiler_declaration_catalog_profile.brp`.

Inventory every graph accessor currently used by
`accepted_declaration_catalog_build` before designing its replacement input.

## Current Problem

`AcceptedDeclarationCatalog` exists and has focused tests and a benchmark, but
its builder takes `AcceptedTypecheckGraph`. The catalog module also imports
`CompletedGlobalHeader`, `CompletedGlobalHeaderGraph`, and their accessors from
`decl.brp`. Removing only the accepted-graph parameter would therefore leave
the same module dependency problem in a less obvious form.

A production accepted graph cannot cleanly own a product whose module imports
that graph's assembly module. Attaching it directly would create an import
cycle; rebuilding it elsewhere would create duplicate authority.

## Required Design

Define one narrow build input from the products already available immediately
before accepted graph assembly. An illustrative shape is:

```blorp
struct AcceptedDeclarationCatalogInput {
	implementation_headers: ImplementationHeaders,
	importable_graph: ImportableGraph,
	completed_globals: List[AcceptedDeclarationCatalogGlobalInput],
	accepted_module_identities: List[ModuleIdentity]
}
```

Use the actual minimal fields discovered by the inventory. Prefer a precise
record over a long positional parameter list. It must not contain an
`AcceptedTypecheckGraph`, a `decl.brp`-owned completed-global type, or a callback
that reaches back into either.

Define a catalog-owned immutable input projection for completed globals with
only the IDs, canonical binding type, visibility, and dependency facts the
catalog actually stores. The caller at the graph-assembly boundary may project
`CompletedGlobalHeaderGraph` into that input; the catalog module must not know
the source representation. Alternatively move the completed-global product to
a lower-level header module if that is independently cleaner. In either case,
the result must be an acyclic dependency direction:

```text
lower-level header/import products -> declaration catalog -> decl graph assembly
```

The input must support a partial successfully completed global set. It must not
invent placeholder catalog entries for failed or incomplete globals; recovery
failure and module exclusion remain owned by graph completion.

Then:

1. make the catalog builder consume that input;
2. adapt the isolated tests and benchmark to construct the input from their
   fixture products;
3. remove every `declaration_catalog.brp` import from `../decl`, including
   completed-global records and accessors;
4. preserve catalog IDs, deterministic order, duplicate handling, metrics, and
   exact errors; and
5. remove the graph-consuming builder instead of retaining an overload or
   compatibility wrapper.

Do not store the resulting catalog in production graph facts yet. This keeps
the issue independent from prepared-module lifetime changes.

## Non-Goals

- Do not change declaration representation or query semantics.
- Do not cut over production lookups.
- Do not add module visibility views.
- Do not alter `Env` or body preparation.
- Do not build the catalog more than once in a production path for measurement
  purposes.

## TDD And Fast Feedback

Before refactoring, strengthen the catalog test to compare the complete
category counts, identity checksum, deterministic order, duplicate diagnostics,
and wrong-category behavior produced from a known accepted fixture.

After changing the builder, the same expected values must hold. The isolated
catalog benchmark must retain:

```text
builder_visits == unique_entries * iterations
duplicate_checks == unique_entries * iterations
error_count == 0
workload_valid == true
```

Add an `rg`-based or compile-time proof that `declaration_catalog.brp` neither
imports `decl.brp` nor accepts `AcceptedTypecheckGraph` or decl-owned completed-
global products.

## Acceptance Criteria

- Catalog construction depends only on pre-assembly Stage 06 products.
- The catalog module has no import or type dependency on `decl.brp`, including
  `AcceptedTypecheckGraph` and completed-global products/accessors.
- The resulting module dependency direction can support `decl.brp` retaining a
  catalog without an import cycle.
- Exactly one catalog representation and one builder API remain.
- IDs, ordering, metrics, and diagnostics match the baseline.
- No production graph field or lookup is changed.
- Focused catalog tests, benchmark, and `scripts/compiler-check --changed`
  pass.

## Verification

Run the catalog unit test and isolated benchmark, typecheck the changed Stage 06
sources, and run `scripts/compiler-check --changed`. A full compiler performance
run is not required because this issue does not put the builder on a new
production path; compare isolated construction counts and latency only.
