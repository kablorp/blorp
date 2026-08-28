# Retain One Catalog And Build Module Declaration Views

**Status:** Blocked on Issue 19

## Context And Dependencies

Issue 19 proves the declaration catalog representation without production
retention. This issue builds it once per accepted typecheck graph, stores it in
the graph lifetime, and constructs identity-based module declaration views.

No body lookup is cut over yet. Issues 21 and 22 consume these views by
declaration category.

## Problem Statement

A graph-owned catalog is useful only if each module can express exactly which
catalog entries are visible and under which source names. Reusing existing
string-keyed environment materialization would defeat the purpose; replacing it
without a checked visibility projection would risk language regressions.

This issue must establish catalog ownership and module-view semantics while
keeping the legacy `Env` path authoritative.

## Goal

1. Build `AcceptedDeclarationCatalog` exactly once after accepted graph
   completion.
2. Store one graph-scoped catalog reference.
3. Build one compact `ModuleDeclarationView` per accepted module from
   `BoundModule`, `ModuleView`, and nominal catalog identities.
4. Validate each view against legacy visible declarations in focused tests.
5. Pass catalog and view references to `AcceptedBodyModuleBase` without copying
   catalog entries into body contexts.

## Required Ownership

The graph owns:

```blorp
private record AcceptedTypecheckGraphFacts {
	...
	declaration_catalog: AcceptedDeclarationCatalog,
	module_declaration_views: Dict[ModuleId, ModuleDeclarationView]
}
```

Use the repository's actual graph record and module identity. A body base owns
or borrows one view plus the graph/catalog lifetime. Do not place the full
catalog in every module record if that increments or copies large structures
per module; verify generated ownership behavior.

## Module View Responsibilities

An opaque `ModuleDeclarationView` must encode:

- local declarations;
- direct public value imports;
- selective imports and aliases;
- qualified module aliases;
- transitive canonical type access required by accepted semantic types;
- private visibility;
- overload and UFCS candidate order;
- visible traits and implementations; and
- deterministic source-name ambiguity information.

Store nominal references or compact indices into the catalog. Do not copy full
`Symbol`, `TraitDef`, `ImplInstance`, or parsed declaration records.

The view must distinguish:

```text
unqualified local name
unqualified imported name
qualified module member
exact identity reference
ambiguous source-name projection
```

Do not infer those categories from string formatting.

## Mechanical Sequence

1. Add `catalog_builds` and `module_views_built` counters.
2. Build the catalog in `complete_typecheck_graph` after accepted graph facts
   are available.
3. Validate catalog provenance against the same indexed/bound graph.
4. Add the opaque module-view builder next to module binding/visibility code,
   not inside inference.
5. Build views in deterministic accepted module order.
6. Add category counts and a stable checksum for every view.
7. Compare each view with the declarations currently installed by
   `typecheck_register_import_modules_from` and local header installation.
8. Store catalog and views in accepted graph facts.
9. Thread only references through `AcceptedTypecheckModule` and
   `AcceptedBodyModuleBase`.
10. Keep legacy `Env` lookup authoritative until Issues 21 and 22.

Do not run both catalog and legacy projection algorithms inside every body.
Build each graph-level product once.

## TDD Matrix

Required module graphs:

1. No imports.
2. One direct import.
3. Transitive type visibility without transitive value visibility.
4. Diamond import.
5. Selective import and alias.
6. Qualified import alias.
7. Private/public collisions.
8. Same-name declarations from two modules.
9. Overloads spread across local and imported modules.
10. Trait and implementation visibility.
11. Builtin/prelude declarations.
12. Recovery module with parse/type errors.

For each module compare:

- visible nominal identities;
- source names and aliases;
- ordering;
- ambiguity classification;
- private filtering;
- exact diagnostic provenance; and
- deterministic checksum across discovery-order perturbations.

## Memory Gate

This is temporarily additive because legacy environments still exist. Measure
the production replay from Issue 15 before merging.

Required conditions:

- `catalog_builds == 1` per graph execution;
- `module_views_built == accepted module count`;
- no catalog entry copies in body contexts;
- response bytes and hash are identical;
- peak RSS increase is below 3%; and
- allocator bytes/current objects are recorded and explained.

If peak RSS exceeds 3%, compact duplicated source/provenance fields before
merging. Do not defer a large additive representation to later cutover.

## Verification

```bash
./blorp test --timeout 180 compiler/tests/test_compiler_declaration_catalog.brp
./blorp test --timeout 180 compiler/tests/test_compiler_module_binding.brp
./blorp test --timeout 180 compiler/tests/test_compiler_module_visibility.brp
./blorp test --timeout 180 compiler/tests/test_compiler_typecheck_decl.brp
scripts/compiler-check --stage typecheck
scripts/test compiler-blorp-sanitize
```

Run three alternating production replay pairs and preserve response/worker
hashes.

## Pitfalls

- Do not key views by display module name.
- Do not duplicate the existing stringly module identity hierarchy.
- Do not make session-assigned IDs part of serialized artifacts or cache keys.
- Do not let recovery modules poison accepted catalog invariants.
- Do not copy catalog records into every module or body context.
- Do not switch lookup behavior in this issue.

## Acceptance Criteria

- Exactly one catalog and one view per accepted module are retained.
- Views match legacy visibility and ordering through exhaustive focused tests.
- Catalog/view construction is deterministic and identity-based.
- The production replay is byte-identical and stays within the 3% memory gate.
- No body lookup behavior changes.

## Merge Point

This is a valid temporary additive merge point only if the memory gate passes.
It establishes production ownership and validated views for category-by-category
cutover.
