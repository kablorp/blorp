# Phase 5: Complete Global Initializer Headers

## Issue Summary

Infer every unannotated global initializer exactly once and replace pending or
placeholder global types with an accepted completed-header product before
ordinary body checking begins.

This is the first unfinished phase in the
[typechecking migration roadmap](../../COMPILER_PRIORITIES.md#phase-5-global-initializers-and-header-completion).
It is an architectural cutover, not an optimization-only change.

## Context

Phases 1-4 established accepted module, declaration, type, callable, trait, and
implementation products. Global declarations are already definition-owned and
identified by `GlobalId`, but the callable-header phase intentionally stops
short of inferring unannotated initializer types.

Current production behavior, verified on 2026-08-23:

- `GlobalHeader` distinguishes `AnnotatedGlobalHeader` from
  `PendingGlobalInitializer` in
  `compiler/blorp/src/stage_06_typecheck/headers/callable_headers.brp`.
- `register_global_header` in
  `compiler/blorp/src/stage_06_typecheck/decl.brp` installs a pending global in
  `Env` with `TYPE_VOID`.
- `typecheck_materialize_global_var_body` later infers the initializer, zonks
  it, derives its binding type, and replaces the environment binding.
- Mutable top-level initializers already have startup-work restrictions:
  function calls and subscript operations are rejected while calls nested in a
  lambda remain legal.
- Stage 07 separately enforces CTFE source-order and availability rules. Header
  completion must not absorb value evaluation or silently change those rules.

The temporary `TYPE_VOID` registration means accepted headers are not yet a
complete immutable input for independently checking arbitrary bodies.

## Relationship To Other Issues

### Prerequisites

- Phases 1-4 must remain authoritative. Use existing `GlobalId`, declaration
  skeletons, `TypeHeaderGraph`, `CallableHeaderGraph`, trait topology, and
  implementation headers. Do not create parallel identity or header systems.

### Unlocks

- [Phase 6: Independent Body Checking](phase-06-independent-body-checking.md)
  can rely on every accepted global having a real type.
- [Phase 7: Demand-Driven CTFE](phase-07-demand-driven-ctfe.md) can reuse the
  typed initializer and dependency facts instead of re-running inference.
- [Phase 10: Checked And Codegen-Ready Graphs](phase-10-checked-codegen-graphs.md)
  can distinguish completed headers from recoverable pending/rejected ones.

### Sequencing Constraint

Phase 6 preparatory types may be developed in parallel, but its production
body-check path must not become authoritative until this issue removes the
pending-global placeholder from accepted inputs.

## Problem Statement

Global type inference currently happens as part of broad declaration-body
materialization. This creates four problems:

1. A body may observe `TYPE_VOID` for a global whose initializer has not yet
   been materialized.
2. Source order and shared `TypecheckState` affect when inferred global types
   become visible.
3. Importers and CTFE preparation can rebuild semantic state to rediscover
   global facts that should have been completed once.
4. A pending global is representable inside an otherwise accepted header graph,
   so later phases must rely on conventions rather than type-enforced input.

## What This Solves

- Every accepted global header has a resolved semantic type.
- Every unannotated initializer is inferred at most once per graph.
- Global dependency and cycle behavior is deterministic.
- Ordinary body checking cannot observe placeholder global types.
- CTFE receives an already typed initializer and exact dependency identities.
- Tools can retain rejected or pending initializer information without making
  it codegen-valid.

## Expected Performance And Cleanup Impact

There is not yet a Phase 5-specific production baseline, so this issue must not
promise a percentage speedup before adding counters. The performance hypothesis
is nevertheless concrete:

- initializer inference changes from late, consumer-coupled work to one check
  per `GlobalId`;
- accepted inferred types stop triggering placeholder binding replacement;
- importers stop rebuilding or reinstalling facts solely to discover global
  types; and
- CTFE reuses the retained typed initializer instead of causing another
  inference/materialization path.

The expected direct improvement is **small to moderate for ordinary projects**
and potentially larger for projects with many unannotated globals, broad import
fan-out, or repeated CTFE preparation. The more important benefit is removing a
prerequisite that currently prevents Phase 6 and Phase 7 from eliminating much
larger repeated work.

This phase enables:

- immutable completed-header sharing across all body checks;
- order-independent and cacheable body construction;
- exact CTFE root/dependency scheduling; and
- future graph-level reuse keyed by stable global identity.

Expected cleanup includes the pending-global `TYPE_VOID` path, late binding
replacement, duplicate initializer inference, and importer setup that exists
only because the global type was unavailable earlier.

Success requires counter evidence that every initializer is checked once and
that duplicate/importer-driven inference and placeholder updates reach zero,
plus before/after wall time and peak memory on a global/import-heavy fixture.

## Proposed Architecture

The names below describe roles; adjust names only when a current local
convention provides a clearer equivalent.

```text
HeaderCompletionOutcome =
    HeaderGraphAccepted(CompletedHeaderGraph)
    HeaderGraphRejected(RecoverableHeaderGraph, diagnostics)

CompletedGlobalHeader =
    AnnotatedGlobalHeader(...)
    InferredGlobalHeader(GlobalId, SemanticType, TypedExpr, dependencies, ...)
```

`CompletedHeaderGraph` must contain no pending value type. A
`RecoverableHeaderGraph` may contain explicit pending/rejected entries for
diagnostics, `check`, and LSP, but cannot construct an accepted body context or
a codegen-ready graph.

Introduce a restricted `InitializerCheckContext` containing only:

- accepted type, callable, trait, and implementation facts needed by an
  initializer;
- the owning module view and exact `GlobalId`;
- already available completed global headers;
- the initializer dependency plan;
- source-level policy such as debug-only and mutable-startup restrictions; and
- fresh initializer-local inference state.

It must not expose graph mutation, arbitrary declaration registration, Core
counters, or a completed graph that is still being built.

## Implementation Plan

The numbered sections are ordered work, not necessarily one commit each. Form
mergepoints from vertical slices that include a focused test, a production
consumer, and deletion of the replaced path. Do not merge a dormant parallel
model.

### 1. Write Failing Boundary Tests

Add `compiler/blorp/tests/test_compiler_global_header_completion.brp` before
changing production behavior. Prove at minimum:

- an accepted completed graph cannot contain a pending global;
- a rejected/recoverable graph cannot be passed to accepted body entry;
- two unannotated globals with a dependency are completed in dependency order,
  not caller iteration order; and
- the initializer is checked once even when multiple bodies and CTFE reference
  it.

Use focused source-language fixtures under `tests/test_compiler/typecheck/`
when the behavior includes a user-visible diagnostic.

### 2. Characterize Initializer Dependencies

Inventory and test:

- direct references to local and imported globals;
- references through selective and qualified imports;
- calls made by immutable initializers;
- mutable initializer restrictions;
- annotation-present and annotation-absent declarations;
- source-order constraints currently enforced by CTFE;
- self-reference, later-global reference, and cross-module cycles; and
- initializer expressions containing lambdas whose bodies are not executed at
  initialization time.

Build dependency nodes and edges by `GlobalId`. Do not infer dependencies from
textual names after resolution. If current typed metadata cannot express an
edge exactly, add the missing identity-bearing metadata at the earliest phase
that knows it.

Header dependency cycles and value-evaluation cycles are different contracts.
An annotated cycle may have known header types while still being unevaluable by
CTFE. Phase 5 classifies header completion; Stage 07 remains responsible for
rejecting value cycles or unavailable values.

### 3. Add The Restricted Initializer Context

Adapt existing initializer inference rather than creating a second inference
engine. Initially, the adapter may call the current inference kernel, but its
public input must be the restricted context and its output must be an explicit
accepted/rejected initializer result.

Preserve current behavior from `typecheck_materialize_global_var_body`,
including:

- annotation compatibility;
- zonked typed initializer metadata;
- binding versus source type;
- exact definition identity; and
- mutable startup-work diagnostics.

### 4. Complete Headers Deterministically

Process dependency components in stable module/global order. For each pending
initializer:

1. construct a fresh initializer session;
2. infer and finalize the initializer once;
3. validate its declared type when present;
4. collect exact global and callable dependencies;
5. retain the typed initializer for CTFE and later graph assembly; and
6. append either an accepted inferred header or an explicit rejected result.

Only the completion builder may construct `CompletedHeaderGraph`.

### 5. Cut Over Production Consumers

Update, in this order:

1. accepted typecheck-module/body entry;
2. imported global projection;
3. CTFE root and initializer preparation;
4. graph diagnostics and summaries; and
5. CLI/LSP recovery projections.

Each consumer must handle the accepted or recovery product explicitly. Do not
convert rejection back into `Option`, a Boolean, an empty type, or `TYPE_VOID`.

### 6. Delete The Replaced Path

Remove:

- pending-global `TYPE_VOID` registration in `register_global_header`;
- late environment replacement used only to publish an inferred global type;
- importer reconstruction needed only because global headers were incomplete;
- duplicate initializer inference from body and CTFE paths; and
- temporary adapters introduced during the vertical cutover.

Keep `PendingGlobalInitializerHeader` only if it remains necessary in the
recoverable pre-completion product. It must not remain in the accepted completed
graph.

## Likely Files To Touch

- `compiler/blorp/src/stage_06_typecheck/headers/callable_headers.brp`
- `compiler/blorp/src/stage_06_typecheck/decl.brp`
- `compiler/blorp/src/stage_06_typecheck/state.brp`
- `compiler/blorp/src/stage_06_typecheck/bridge.brp`
- `compiler/blorp/src/stage_07_ctfe/globals.brp`
- `compiler/blorp/src/stage_07_ctfe/env.brp`
- `compiler/blorp/tests/test_compiler_callable_headers.brp`
- `compiler/blorp/tests/test_compiler_typecheck_decl.brp`
- `compiler/blorp/tests/test_compiler_ctfe_globals.brp`
- the compiler-test ownership manifest for every new production/test module

Do not move unrelated inference or CTFE code as part of this issue.

## How To Test

### Focused Correctness

```bash
make
./blorp test --timeout 180 compiler/blorp/tests/test_compiler_global_header_completion.brp
./blorp test --timeout 180 compiler/blorp/tests/test_compiler_callable_headers.brp
./blorp test --timeout 180 compiler/blorp/tests/test_compiler_typecheck_decl.brp
./blorp test --timeout 180 compiler/blorp/tests/test_compiler_ctfe_globals.brp
```

Add should-fail fixtures that assert exact diagnostics for inferred cycles,
annotation mismatches, self-reference, and unavailable imported values.

### Order And Ownership

- Run the same initializer graph in source, reverse, and fixed shuffled order.
- Assert identical completed types, dependency identities, and sorted
  diagnostics.
- Add a leak-check regression if a new graph or retained typed initializer owns
  managed values.
- Run `scripts/test compiler-blorp-sanitize` for new recursive graph traversal
  or ownership-bearing products.

### Performance

Extend `benchmarks/compiler_typecheck_phase_profile` if it can isolate global
completion; otherwise add one focused initializer-graph fixture. Record:

- initializer checks;
- dependency probes;
- header updates;
- imported installations;
- duplicate initializer requests;
- wall time; and
- peak memory.

### Gates

```bash
scripts/compiler-check --stage typecheck
make quality
git diff --check
```

## Acceptance Criteria

- Every accepted global header has a real type.
- Pending or rejected globals cannot construct accepted body/Core input.
- Every initializer is inferred at most once per graph.
- Dependency ordering and diagnostics are deterministic.
- Mutable-global startup restrictions remain unchanged.
- CTFE consumes the retained typed initializer without re-running inference.
- The `TYPE_VOID` pending-global fallback and replaced adapters are deleted.
- Focused tests, sanitizer coverage, typecheck stage checks, and quality pass.

## Pitfalls And Non-Goals

- Do not evaluate global values in Phase 5; that remains CTFE ownership.
- Do not treat annotation presence as proof that a value-dependency cycle is
  evaluable.
- Do not key dependencies by names, source offsets, or legacy integer IDs when
  `GlobalId` is available.
- Do not build a second initializer typechecker.
- Do not make Phase 5 depend on the final Phase 6 session representation. A
  narrow adapter to the current inference kernel is acceptable and can later
  share body-local mechanics.
- Do not preserve compatibility shims after all production consumers move.

## Handoff Checklist

- [ ] Re-read the Phase 1-4 accepted-product constructors before designing new
      types.
- [ ] Add failing boundary and order-independence tests first.
- [ ] Baseline initializer counts, time, and memory.
- [ ] Implement one production vertical slice before adding broad abstractions.
- [ ] Verify CTFE diagnostics and mutable startup restrictions are unchanged.
- [ ] Delete placeholder registration and duplicate inference.
- [ ] Update the roadmap status only after production callers use the completed
      graph.
