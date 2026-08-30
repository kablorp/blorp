# Batch Imported Module Publication

**Status:** Deferred pending catalog evidence

## Context And Dependencies

Issue 16 reduced publication within one mixed-symbol scope batch. Issue 17's
local callable-header publication candidate was rejected after focused
measurement: it collapsed physical publication groups but reduced allocations
by only 0.56% at 256 target headers, far below the 25% gate. This issue is
therefore deferred until Issue 19 identifies a repeated imported-module
materialization path whose measured allocation/time share can plausibly clear a
predeclared gate. This issue must not assume Issue 17's rejected callable
batching API exists.

It is the final bounded batching issue before frozen catalog work begins. It
must demonstrate how much cost batching alone can recover and how much repeated
cross-module materialization remains.

## Current Production Path

In `blorp/src/compiler/stage_06_typecheck/decl.brp`:

1. `prepare_accepted_body_module` calls
   `typecheck_register_import_modules_from`.
2. Every compatible visible module passes through
   `typecheck_register_import_module_types`.
3. Every compatible direct module passes through
   `typecheck_register_direct_import_module_decls`.
4. Signature declarations, implementation declarations, type headers,
   constructors, containment facts, traits, and overload metadata are installed
   through multiple persistent `TypecheckState` and `Env` publications.

Module scope is temporarily changed during definition-owned registration and
then restored. That ownership/provenance behavior must remain explicit.

## Problem Statement

Even after per-declaration batching, one imported module can publish several
independent intermediate states:

- records;
- unions and constructors;
- aliases and opaque aliases;
- globals;
- callables;
- traits; and
- implementations.

The caller already knows the complete accepted module surface. Publishing each
category separately leaves avoidable `Env` and `TypecheckState` reconstruction.

This issue does not remove repeated installation of the same module into
different consumers. It reduces the cost of each remaining installation and
provides a clean module-level product for catalog construction.

## Goal

Prepare one ordered, validated imported-module declaration plan and commit its
scope/index updates through the minimum number of publications allowed by
current semantic boundaries.

## Required Product

Create a private phase product equivalent to:

```blorp
private record PreparedImportedModuleDeclarations {
	module_identity: ModuleIdentity,
	module_path: String,
	type_symbols: List[Symbol],
	callable_registrations: List[PreparedCallableHeaderRegistration],
	global_registrations: List[PreparedGlobalHeaderRegistration],
	traits: List[TraitDef],
	implementations: List[ImplInstance],
	containment_facts: List[PreparedContainmentFact],
	ordered_events: List[ImportedDeclarationEvent]
}
```

Use existing identity and semantic types. `ordered_events` is required only if
diagnostics, ID claims, or cross-category visibility depend on source order.
Do not duplicate every declaration into both category lists and ordered events;
store references/indices or choose one canonical representation.

## Mechanical Sequence

1. Extend Issue 15 counters to report publications by imported module and
   category.
2. Add an oracle that captures all public lookup, ID, containment, trait,
   implementation, overload, and diagnostic projections after legacy module
   registration.
3. Extract preparation for one imported module without changing publication.
4. Validate module identity and prepared scope once at the preparation
   boundary.
5. Publish all scope symbols through Issue 16's mixed batch.
6. If Issue 19 identifies a qualified imported callable path, evaluate callable
   metadata publication with a fresh measured boundary; do not rely on Issue
   17's rejected API.
7. Use local accumulators for traits, implementations, containment facts, and
   overload metadata; publish each `Env` field once where possible.
8. Restore the target definition scope exactly once.
9. Compare the complete oracle projection.
10. Migrate `typecheck_register_import_module_types` and
    `typecheck_register_direct_import_module_decls` to the plan.
11. Remove the old per-category module publication helpers when no callers
    remain.

Do not group multiple imported modules in this issue. Module order can affect
visibility and diagnostics and belongs to the later catalog/view model.

## Required Invariants

- Canonical transitive types remain available exactly where required.
- Values, traits, and implementations remain limited to current direct-import
  visibility rules.
- Private declarations never become importable.
- Module aliases and selective imports remain governed by `ModuleView`.
- Definition ownership uses the imported module scope during claims and is
  restored afterward.
- Constructor IDs, callable IDs, global IDs, and source spans are unchanged.
- Same-name and overload ordering is unchanged.
- Failed preparation cannot expose a partially installed module.
- Diagnostic order remains deterministic and byte-identical.

## TDD Matrix

Add focused fixtures for:

1. One empty imported module.
2. One module containing every declaration category.
3. A module with same-name callable overloads and constructors.
4. Direct versus transitive visibility.
5. Selective import, alias, and qualified import.
6. Private declarations.
7. Trait plus implementation methods.
8. Generic aliases and resource containment facts.
9. Reserved and generated IDs.
10. A malformed declaration in the middle of the module.
11. Two imported modules with colliding source names.
12. Scope restoration after successful and rejected module preparation.

Use existing suites where possible:

- `blorp/test/compiler/stage_06_typecheck/test_typecheck_decl.brp`
- `blorp/test/compiler/stage_06_typecheck/test_callable_headers.brp`
- `blorp/test/compiler/test_compiler_type_header_install.brp`
- `blorp/test/compiler/test_compiler_module_binding.brp`
- `blorp/test/compiler/stage_05_types/test_env.brp`

## Measurement

Use Issue 15's chain, star, layered, and dense fixtures. Compare:

```text
scope publications per imported module
env publications per imported module
dictionary/list copies per imported module
symbols published
semantic conversions
identity claims
diagnostics
allocations
elapsed time
```

The logical declaration installation count is expected to remain unchanged;
only publication and copying should fall. If installation multiplicity also
falls, prove that the old work was duplicate rather than semantically required.

Run the production replay with three alternating pairs and byte-identical
responses.

## Acceptance Criteria

- One imported module is prepared as one checked phase product.
- Scope and environment publications scale with modules/categories rather than
  declarations.
- Existing registration helpers are removed when replaced.
- Exact semantic and diagnostic projections match the legacy oracle.
- Focused allocations improve materially on 64+ declaration modules.
- Production replay does not regress elapsed time, RSS, or allocator bytes.
- Issue 15 counters clearly quantify the still-repeated cross-module
  installation factor after batching.

## Merge Point

This is independently mergeable. Every body module still receives a complete
materialized environment, but each imported module is installed more cheaply.
