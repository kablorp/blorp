# Phase 6: Independently Check Every Body

## Issue Summary

Replace whole-module, shared-state body materialization with one immutable
`BodyCheckContext`, one fresh body-local `InferSession`, and an explicit
accepted/rejected body artifact per definition.

This issue implements
[Phase 6 of the typechecking migration](../../COMPILER_PRIORITIES.md#phase-6-independent-body-checking).
It creates the stable body-check facade used by ordinary compilation and CTFE.

## Implementation Status (2026-08-25)

The production vertical cut is implemented:

- accepted modules construct opaque, exact-identity `BodyCheckContext` values;
- accepted modules prepare and retain their immutable body base once, so exact
  body-context requests and traced compilation do not replay import or local
  header registration;
- context construction rejects foreign owners, unknown identities, non-source
  bodies, unsupported sources, and missing accepted signatures explicitly;
- body contexts retain only an immutable session seed, never another body's
  solver bindings, diagnostics, or type-shape memo;
- ordinary functions, explicit implementation methods, and concrete default
  methods produce accepted/recovered artifacts through one facade;
- default implementation headers retain the accepted trait-method slot and
  derive its receiver-substituted signature when constructing a context, which
  avoids storing a second semantic signature that could drift from the graph;
- implementation methods are resolved by module-qualified callable identity,
  and their body signatures compose implementation-owner parameters with
  method-owned parameters explicitly;
- the public exact-body facade supports ordinary functions, explicit methods,
  and concrete inherited defaults through the same constructor used by the
  whole-module scheduler;
- default method headers retain their owning `ImplId` and reject pairing with
  another implementation before receiver substitution;
- source, reverse, and deterministic shuffled schedules produce identical
  typed output and diagnostics, including when one body is rejected;
- source-order assembly consumes an exact-definition-ID artifact index; and
- traced compilation and CTFE's accepted-module path use the same body facade.

Expression inference now carries one nominal `InferSession` that owns its
immutable `InferModuleFacts`; the previous independently pairable session/facts
owners no longer exist, and `InferContext` cannot contain a complete
`TypecheckState`.
The recursive inference path updates the session directly and reconstructs the
compatibility state only once when returning to declaration checking. The
expected type and value-slot constraint are represented by one union, so a slot
constraint without its required expected type is not representable. The
retained whole-module body functions are lower-level standalone test entrypoints
and source-order artifact assembly. Accepted production compilation never
selects their standalone body-inference policy.

The accepted `bodies` stage profile on 2026-08-24 initially completed 20
iterations of the 8-module fixture in 0.725 seconds after 0.238 seconds of
fixture setup. Two final runs measured 0.811 and 1.523 seconds while setup
varied from 0.233 to 0.458 seconds, so host load currently dominates the small
sample. Each measured iteration still constructs the accepted module before it
checks bodies; this is a body-stage envelope, not isolated inference. The
structural metric is stable: accepted-module construction prepares the body
base once, and exact body checks perform no import or local-header registration.
Do not claim a wall-time speedup from these noisy measurements; the separate
inference-performance issue owns an exact-`BodyCheckContext` harness.

Final closure validation against the integrated `main` passed on 2026-08-25:

- `scripts/compiler-check --stage typecheck`: 39 sources, 25 suites, and the
  stage leak check passed in 456.75 seconds; and
- `scripts/test compiler-blorp-sanitize`: all 3,783 compiler-owned tests passed
  under ASan and UBSan in 29 minutes 58 seconds; and
- `make quality`: passed. C static analysis retained five pre-existing
  `runtime.c` cleanup-frame stack-address warnings outside Phase 6's changed
  surface.

## State Ownership Inventory

| Value or field | Semantic owner | Phase 6 handling |
| --- | --- | --- |
| accepted header graphs, bound module, import inventory | graph/module immutable | retained once by `AcceptedBodyModuleBase`; queried to construct exact contexts |
| `Context` package/type/resource/trait homes | module immutable | copied into `BodyInferSessionSeed` |
| `Context` metas, substitutions, and fresh-meta counter | body session | cleared whenever a context creates its inference state |
| `Context` lowering/Core counters | post-typecheck compatibility | preserved but never mutated intentionally by body checking; later phase ownership cleanup |
| `Env` installed module symbols, traits, implementations, overloads | module immutable compatibility view | installed once per accepted module and shared by value |
| `Env` lexical scopes and local/resource bindings | body session | each check starts from the immutable module environment; its result is never reused by another body |
| errors and diagnostics | body session, then module assembly | start empty, live in accepted/recovered outcome, assembled in source declaration order |
| module view, reserved definition scope, known-type index, type homes | module immutable | stored in the session seed; callable identities come from the reserved graph index |
| scoped trait functions | implementation-body immutable | implementation contexts receive their implementation-specific seed |
| type-shape memo | body session | starts empty for every body and is discarded with the session |
| expected type/value slot and loop/debug controls | expression context | one `InferExpectation` union couples slot constraints to their required type; session updates preserve expression context |

The important current invariant is that `BodyCheckContext` cannot contain a
completed or partially used body session. `fresh_body_infer_session` is the only
constructor from its seed. Expression inference nests immutable
`InferModuleFacts` inside the fresh body-local `InferSession`, so callers cannot
pair a session from one owner with facts from another. Recombination consumes
that one coherent session value.

## Context

Phases 1-4 established accepted graph facts. Phase 5 completes inferred global
headers. Body checking should therefore be a query over immutable graph facts,
not another declaration-registration pass.

Current production behavior, verified on 2026-08-23:

- `AcceptedTypecheckGraph` combines accepted implementation headers with a
  compatible importable graph.
- `AcceptedTypecheckModule` still stores `TypecheckState` alongside the graph
  and bound module.
- `typecheck_program_with_accepted_type_headers` and its traced variant rebuild
  import type facts and declarations in `Env`, then install local builtin,
  record, union, alias, global, trait, callable, and implementation headers.
- `typecheck_materialize_standalone_program_bodies_with_import_modules` iterates every
  parsed declaration in source order while threading one mutable
  `TypecheckState`.
- `InferContext` directly embeds `TypecheckState` plus expected-type and control
  Booleans.
- `TypecheckState` owns graph/module facts, diagnostics, `Env`, private
  implementations, type homes, and memo state. `Env` owns scopes, traits,
  implementations, overloads, UFCS methods, and identity allocation state.

This arrangement makes an individual body difficult to construct, test, cache,
or schedule without replaying module setup.

## Relationship To Other Issues

### Prerequisite

- [Phase 5: Global Header Completion](phase-05-global-header-completion.md) must
  provide completed global types before this issue makes independent body entry
  authoritative.

### Stable Facade For Later Work

- [Phase 7: Demand-Driven CTFE](phase-07-demand-driven-ctfe.md) schedules and
  memoizes this issue's complete body outcomes.
- [Phase 8: Solver And Finalization](phase-08-solver-finalization.md) replaces
  the internals of the facade with explicit inferred/solved products.
- [Phase 9: Semantic Validation](phase-09-semantic-validation.md) replaces the
  final acceptance step with a validated-body product.
- [Phase 10: Checked And Codegen-Ready Graphs](phase-10-checked-codegen-graphs.md)
  assembles these per-definition outcomes.

Phase 8 and Phase 9 must not force CTFE to understand partial bodies. The public
Phase 6 facade always returns a complete accepted body or an explicit recovery
result.

## Problem Statement

The current API is module-sized even when the semantic work is body-sized. This
causes:

1. repeated installation and copying of accepted graph facts into `Env`;
2. implicit dependence on declaration and body iteration order;
3. graph-wide and body-local mutable state sharing one record;
4. CTFE requiring complete dependency modules rather than requested bodies;
5. poor unit-test ergonomics for one function or method; and
6. a large ownership/lifetime surface that retains unrelated module state.

## What This Solves

- A function or method can be checked from exact immutable inputs.
- Each body owns fresh scopes, metas, resource state, local IDs, and diagnostics.
- Scheduling order cannot affect accepted identities, output, or diagnostics.
- CTFE and ordinary compilation call the same complete body-check API.
- Accepted graph facts are queried rather than reinstalled per body.
- Broad state fields and whole-module compatibility adapters can be deleted.

## Expected Performance And Cleanup Impact

This is expected to be one of the largest **general** typechecking improvements,
but it does not yet have a clean isolated baseline. The current CTFE profile
provides directional evidence: in one instrumented 24-by-32 workload, complete
body materialization consumed 0.702 seconds and imported-module registration
consumed 0.183 seconds. Those inclusive figures mix Phase 6 and Phase 7 work and
must not be treated as a Phase 6 speedup forecast.

The direct optimization mechanisms are:

- replace repeated importer/local header installation with immutable graph
  queries;
- stop copying/threading graph-wide `TypecheckState` through unrelated bodies;
- allocate and release lexical/meta/resource state per body;
- avoid resetting and retaining body-local memo/counter state at module scope;
  and
- check only requested bodies once scheduling is separated from assembly.

Expected impact is **medium to high for multi-module and many-body projects**,
with lower impact on tiny single-body programs. Peak memory should fall because
one body session no longer retains or rewrites unrelated module state. The
change may initially be neutral or slower if new contexts copy header indexes,
which is why contexts must retain/query accepted graphs rather than duplicate
them.

This phase enables optimizations that are not safe with the current shared
state:

- Phase 7 demand-driven CTFE;
- per-body memoization and content-addressable caching;
- checking independent bodies in parallel;
- releasing failed/completed body sessions promptly; and
- incremental rechecking of only changed definitions and dependents.

Expected cleanup includes broad-state fields, repeated import/local declaration
registration, whole-module body entry APIs, reset/copy helpers, and transitional
adapters. Success requires environment/header installation counts at body entry
to approach zero, one context/session per checked body, stable output under
reordered scheduling, and measured wall-time/RSS improvement on representative
many-body fixtures.

## Proposed Architecture

```text
BodyCheckContext {
    headers: CompletedHeaderGraph,
    module_view: ModuleView,
    body_identity: CallableId or exact body identity,
    body_header: accepted callable/method header,
    policy: BodyCheckPolicy
}

InferSession {
    lexical_scopes,
    metas_and_substitutions,
    local_and_resource_ids,
    resource_scopes,
    local_diagnostics,
    expected_return,
    control_context
}

BodyCheckOutcome =
    BodyCheckAccepted(CheckedBodyArtifact)
    BodyCheckRejected(RecoveredBodyArtifact, diagnostics)
```

The exact storage types may evolve, but the ownership split is mandatory:

- graph facts are immutable and shared;
- module bindings are immutable and shared;
- body state is fresh and private;
- expression context is a narrow value layered over the body session; and
- lowering/Core counters are not part of typechecking.

`CheckedBodyArtifact` is opaque. During Phase 6 it wraps the complete result of
the current inference, finalization, and validation path. Phases 8 and 9 later
strengthen its construction internally.

## Implementation Plan

The numbered sections are ordered work, not necessarily one commit each. Form
mergepoints from vertical slices that include a focused test, a production
consumer, and deletion of the replaced path. Do not merge a dormant parallel
model.

### 1. Write Failing Independence Tests

Add focused suites before introducing the new API:

- `test_compiler_body_check_order.brp` for accepted/rejected construction,
  graph ownership, fresh-session reuse, stale identity rejection, and
  source/reverse/shuffled scheduling; and
- focused additions to `test_compiler_infer.brp` and
  `test_compiler_typecheck_decl.brp` for current body semantics.

The order test must compare exact callable identities, stable typed projections,
and diagnostics in their emitted source order. A test that compares only pass/fail counts is
insufficient.

### 2. Inventory State Ownership

For every field in `TypecheckState`, `Context`, `Env`, and `InferContext`, record:

- semantic owner;
- readers and writers;
- required lifetime;
- whether it is graph immutable, module immutable, body local, expression
  contextual, post-typecheck, or obsolete; and
- the production consumer that prevents deletion.

Pay particular attention to:

- definition and local identity counters;
- type homes and known-type indexes;
- trait/implementation/overload lookup;
- scoped resource tracking;
- expected type, loop, and debug context;
- type-shape memoization; and
- diagnostics currently accumulated in broad state.

Do not move fields mechanically without understanding whether assignment copies
large records or retains shared values.

### 3. Add Immutable Graph Query APIs

Define the minimum queries needed for one body:

- resolve a type or callable by exact identity;
- enumerate applicable trait/implementation candidates;
- resolve global types and visibility;
- resolve imported/qualified bindings through the accepted module view;
- retrieve body signature, type parameters, and bounds; and
- retrieve source provenance for diagnostics.

Queries must read accepted graphs directly. Do not project all facts into a new
per-body `Env`, and do not reconstruct signatures from parsed declarations.

### 4. Introduce `BodyCheckContext`

Construct it only from:

- an accepted completed header graph;
- a compatible bound module/module view;
- one exact body-bearing declaration identity; and
- an explicit policy.

Construction must fail closed for a mismatched graph, module, identity,
category, owner, or source body. Use opaque construction so callers cannot pair
unrelated products manually.

Initially adapt the current inference kernel behind this boundary. The first
vertical slice should check one ordinary function through the new context and
produce byte/structure-equivalent typed output.

### 5. Introduce A Fresh `InferSession`

Move body-local state incrementally:

1. lexical scopes and local bindings;
2. metavariables, substitutions, and origins;
3. expected return/value state;
4. local/resource identities and resource scopes;
5. control context such as loop/debug/detach/select state; and
6. body-local diagnostics and memoization.

Replace invalid Boolean combinations with precise variants. For example,
loop/debug/suppression state should remain separate only when combinations are
actually valid and independently meaningful.

Do not move graph-wide type ownership, module discovery, Core counters, or
cross-body diagnostic aggregation into the session.

### 6. Define The Complete Body Facade

The facade must:

1. create a fresh session;
2. infer the body through the existing kernel;
3. run the current finalization and validation required for acceptance;
4. return `BodyCheckAccepted` only for a complete accepted body; and
5. retain a distinct recovered artifact and diagnostics on failure.

Do not encode rejection as `TYPE_VOID`, missing fields, empty lists, or a
success Boolean. Keep body-local IDs nominally distinct from graph definition
identities.

### 7. Cut Over Body Categories Vertically

Recommended order:

1. ordinary source functions;
2. trait and implementation methods;
3. default methods;
4. lambdas/nested body artifacts where independently addressable;
5. remaining body-bearing declarations; and
6. CTFE callers after all required categories use the facade.

After each category moves, delete its old registration/materialization path.
Do not leave two production implementations selected by a Boolean.

### 8. Separate Scheduling From Output Order

Body checks may run in any deterministic schedule, but final module output and
diagnostics must remain in stable module/declaration order. Store artifacts by
exact identity and assemble source order separately.

This separation is required for Phase 7 worklists and future parallelism. Do
not rely on mutation order to assign semantic identity.

### 9. Delete And Reorganize

Remove migrated fields from `TypecheckState`, `Context`, and `Env`. Delete:

- local/import header installation performed only for body entry;
- whole-module body APIs after all consumers move;
- parsed-declaration semantic reconstruction;
- reset/copy helpers made obsolete by fresh sessions; and
- forwarding wrappers introduced during migration.

Only after the ownership boundary is stable, consider moving typed AST and
generic traversal code out of `infer.brp`/`decl.brp`. Extract acyclic owners;
do not split mutually recursive inference into callback-heavy modules merely to
reduce file size.

## Likely Files To Touch

- `compiler/src/stage_05_types/context.brp`
- `compiler/src/stage_05_types/env.brp`
- `compiler/src/stage_06_typecheck/state.brp`
- `compiler/src/stage_06_typecheck/infer.brp`
- `compiler/src/stage_06_typecheck/decl.brp`
- `compiler/src/stage_06_typecheck/bridge.brp`
- `compiler/src/stage_06_typecheck/headers/`
- `compiler/src/stage_06_typecheck/modules/`
- `compiler/tests/test_compiler_infer.brp`
- `compiler/tests/test_compiler_typecheck_decl.brp`
- `compiler/tests/test_compiler_typecheck_state.brp`
- `compiler/benchmarks/compiler_typecheck_phase_profile.brp`
- compiler-test ownership manifest entries for new modules and suites

Suggested new production ownership, if the dependency graph supports it:

```text
stage_06_typecheck/body/context.brp
stage_06_typecheck/body/session.brp
stage_06_typecheck/body/artifact.brp
```

Do not create these files until at least one production body category can use
them without a circular forwarding layer.

## How To Test

### Focused Correctness

```bash
make
./blorp test --timeout 180 compiler/tests/test_compiler_body_check_order.brp
./blorp test --timeout 180 compiler/tests/test_compiler_infer.brp
./blorp test --timeout 180 compiler/tests/test_compiler_typecheck_decl.brp
./blorp test --timeout 180 compiler/tests/test_compiler_typecheck_state.brp
```

Cover ordinary functions, methods/defaults, generics, overloads, closures,
resources, `with`, concurrency, loops, matches, callbacks, and recovery.
The focused inference and declaration suites own feature semantics, including
resource and `with` rules. The scheduling suite combines constructs that stress
body-local state and checks exact body identities and emitted diagnostic order;
it should not duplicate every semantic fixture.

### Independence Contract

For the same body set, compare source, reverse, and fixed shuffled schedules:

- accepted/rejected outcome per exact identity;
- typed body projection;
- resolved call and function-reference identities;
- local/resource identity behavior where externally observable;
- graph fingerprint before and after checks; and
- diagnostics in their emitted source order.

### Ownership And Sanitizers

```bash
scripts/test compiler-blorp-sanitize
scripts/test leak
```

Add focused leak tests for retained contexts/artifacts. Verify checking one body
does not retain complete unrelated module programs or another body's session.

### Performance

Use or extend `benchmarks/compiler_typecheck_phase_profile` with many small
independent bodies and call/generic/resource-heavy controls. Record:

- body context constructions;
- accepted graph queries;
- environment copies and declaration installations;
- local symbol and meta operations;
- typed-node visits;
- wall time; and
- peak memory.

The cutover should remove graph rebuilding at body entry. A timing result alone
does not prove that property.

### Gates

```bash
scripts/compiler-check --stage typecheck
make quality
git diff --check
```

## Acceptance Criteria

- Every body is checked from one immutable context and one fresh session.
- Body scheduling order does not affect semantic identity, typed output, or
  diagnostics.
- Body code cannot mutate accepted graph facts.
- CTFE and ordinary compilation use one complete body-check facade.
- `InferContext` no longer embeds complete `TypecheckState`.
- Body entry no longer rebuilds all imported/local declarations in `Env`.
- Accepted production compilation has no whole-module shared body-inference
  path; retained whole-program traversal only assembles independently checked
  artifacts, while explicitly named standalone entrypoints remain test-only.
- Focused tests, sanitizer/leak coverage, benchmarks, stage checks, and quality
  pass.

## Pitfalls And Non-Goals

- Do not redesign solver algorithms in this issue; Phase 8 owns that work.
- Do not move final-type semantic rules merely for file organization; Phase 9
  owns rule placement.
- Do not expose an inferred or partially zonked body through the public facade.
- Do not create a CTFE-specific body checker.
- Do not assign identities from body scheduling order.
- Do not retain both the old broad module path and new body path after a
  category has cut over.
- Do not split recursive inference into artificial modules with forwarding
  wrappers or callback indirection.

## Handoff Checklist

- [x] Verify Phase 5's completed-global product is authoritative.
- [x] Inventory every broad-state field and its production consumers.
- [x] Add order-independence and fail-closed construction tests first.
- [x] Migrate one ordinary function end to end before generalizing.
- [x] Measure the accepted body-stage envelope and guard against hot-path state reconstruction.
- [x] Cut over ordinary, explicit implementation, and concrete default bodies.
- [x] Run final full sanitizer/leak and quality gates after integrating current
      main.
- [x] Update roadmap status only after all production body callers use the new
      facade.
