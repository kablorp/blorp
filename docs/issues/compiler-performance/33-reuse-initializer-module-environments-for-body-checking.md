# Reuse Initializer Module Environments For Ordinary Body Checking

**Status:** Ready for implementation

**Dependencies:** None

**Parallel work:** May run alongside Issues 32 and 36. Coordinate changes to
`decl.brp` and the Stage 06 preparation-observation fields before integration.

## Objective

Retain each accepted module's already-constructed initializer base through
global completion and reuse it when preparing ordinary function bodies.
`prepare_accepted_body_module` must stop rebuilding substantially the same
imported and local declaration environment.

This is intentionally a small first step. It removes one duplicate canonical
construction path without redesigning `Env`, changing CTFE visibility, or
introducing the final declaration catalog authority.

## Required Reading

Read `docs/LEARN_BLORP_IN_Y_MINUTES.md`, the Stage 06 section of
`docs/ARCHITECTURE.md`, the roadmap, and these production paths:

- `blorp/src/compiler/stage_06_typecheck/decl.brp`;
- `blorp/src/compiler/stage_06_typecheck/state.brp`;
- `blorp/src/compiler/stage_06_typecheck/type_system/env.brp`; and
- the graph-facts/global-completion records used by `complete_planned_global_headers`.

Read the existing frontend declaration-catalog benchmark and test before
adding a fixture.

## Current Problem

Global initializer checking already constructs one base per module through
`initializer_module_base_state`. Individual initializer sessions derive from
that base while adding only completed dependency globals allowed by the
dependency plan.

After global completion, those bases are discarded. Ordinary body preparation
later calls `prepare_accepted_body_module`, which repeats imported declaration
registration and accepted local-header installation for the same module.

The issue should remove that second canonical build. It should not claim to
remove per-module graph declaration materialization; later issues do that.

## Required Change

1. Add logical counters that independently report:
   - initializer/canonical base builds;
   - ordinary-body environment rebuilds; and
   - body sessions derived from prepared modules.
2. Rename or generalize `InitializerModuleContext` to express that the value
   survives initializer checking, for example `PreparedModuleEnvironment`.
3. Return retained prepared-module values from global completion alongside its
   current completed headers, failures, and metrics.
4. Store them in shared `TypecheckGraphFacts` by exact module identity so both
   `AcceptedTypecheckGraph` and `RecoverableTypecheckGraph` use the same
   prepared products.
5. Derive ordinary body state from the matching retained value, adding
   completed globals exactly as current body semantics require.
6. Reset every per-body field. Reused state must not leak errors, diagnostics,
   containment, refinements, inference bindings, or mutable observations.
7. Delete the ordinary-body import/local-header reconstruction call. Do not
   keep a fallback path for supposedly unusual modules.

Reuse must validate exact accepted graph and module provenance. Do not infer
compatibility from a display name or canonical-path string alone.

When global completion is recoverable, retain only successfully completed
global facts. Preserve `recoverable_graph_typecheck_module`'s existing check
that refuses a module represented in `global_completion_failures`; unaffected
modules must continue from the shared prepared facts without observing a failed
or partial global as completed.

## Non-Goals

- Do not narrow `TypecheckState`; Issue 34 owns that cleanup.
- Do not change CTFE artifact preparation; Issue 35 owns it.
- Do not introduce or retain the declaration catalog in production.
- Do not change import visibility, overload ordering, global completion order,
  diagnostics, or generated results.
- Do not optimize lexical scopes.

## TDD And Fast Feedback

Extend the existing production-shaped benchmark fixture with several bodies
per module. First make it fail by requiring:

```text
canonical_module_base_builds == accepted_module_count
ordinary_body_environment_rebuilds == 0
body_sessions_created == accepted_bodies_checked
```

Before implementation, the reconstruction assertion should fail. Afterward,
run body counts 0, 1, 8, and 32 on sparse and dense graphs. Canonical base
builds must be independent of body count.

Preserve focused cases for direct, selective, aliased, and qualified imports;
global dependencies; rejected headers; debug-only behavior; and exact
diagnostic ordering.

Add a recoverable graph with one module-global failure. Assert that the failed
module remains unavailable, an unaffected module still typechecks, and its
derived body session contains only the successful subset of completed globals.

## Acceptance Criteria

- One canonical base is built for each accepted module.
- Ordinary body preparation performs zero full environment reconstructions.
- Body sessions are fresh and cannot observe state from another body.
- Initializer visibility of only completed dependency globals is unchanged.
- Accepted and recoverable graphs share prepared facts; failed modules remain
  excluded and unaffected modules continue with partial successful completion.
- Existing Stage 06 fixtures and exact diagnostics pass.
- The frontend benchmark reports less construction/publication work.
- Repeated Phase 01-06 latency shows no material regression.
- No compatibility adapter or alternate reconstruction path is left behind.

## Verification

Use the shortest relevant commands supported at implementation time, including:

```bash
bin/blorp test blorp/test/compiler/stage_06_typecheck/test_frontend_declaration_catalog_profile_benchmark.brp
scripts/compiler-check --changed
```

Build once before merge, run the affected Stage 06 manifest/tests, and record
the benchmark counters plus repeated Phase 01-06 timings.
