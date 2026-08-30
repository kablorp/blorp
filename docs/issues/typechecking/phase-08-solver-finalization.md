# Phase 8: Separate Solving And Type Finalization

## Issue Summary

Introduce explicit inferred and solved body products, make metavariable state
body-local and nominally typed, and guarantee that no unresolved inference fact
can escape into semantic validation or Core-facing artifacts.

This issue implements
[Phase 8 of the typechecking migration](../../COMPILER_PRIORITIES.md#phase-8-constraint-solving-and-type-finalization).

## Context

Phase 6 establishes a stable complete body-check facade. Its first
implementation may still call the current combined inference/finalization path.
Phase 8 changes the internals of that facade without exposing partial bodies to
CTFE or ordinary compilation.

Current production behavior, verified on 2026-08-23:

- `stage_05_types/context.brp` defines a broad `Context` containing package/type
  homes, resource cleanups, trait homes, metavariable origins and bindings,
  definition allocation, and numerous Core/lowering/desugar/SSA counters.
- Metavariable identities are raw `Int` values stored in
  `SemanticMetaType(Int)` and `MetaBindingEntry`.
- `meta_bindings` is a `List[MetaBindingEntry]`; lookup linearly scans the list,
  and replacement rebuilds the list.
- `fresh_meta_with_origin`, `bind_meta`, occurs checks, unification, dimension
  solving, and `zonk_type` all operate through the broad `Context`.
- `infer.brp` owns a complete recursive `zonk_typed_expr` traversal and
  `finalize_infer_result` simply applies it to the inferred expression.
- `TypecheckState` embeds `Context`, so solver data currently shares lifetime
  and ownership with graph/module and post-typecheck state.

There is no type-level distinction between a typed tree that still contains
metas and a fully resolved tree accepted by later semantic checks.

## Relationship To Other Issues

### Prerequisite

- [Phase 6: Independent Body Checking](phase-06-independent-body-checking.md)
  provides fresh body-local sessions and the complete accepted/rejected facade.

### Independent But Sequenced Work

- [Phase 7: Demand-Driven CTFE](phase-07-demand-driven-ctfe.md) is scheduled
  before this issue because it addresses a measured major cost. It consumes the
  complete Phase 6 facade and should not depend on solver internals.

### Unlocks

- [Phase 9: Semantic Validation](phase-09-semantic-validation.md) accepts only
  `SolvedBody`.
- [Phase 10: Checked And Codegen-Ready Graphs](phase-10-checked-codegen-graphs.md)
  can rely on accepted bodies being meta-free.

## Problem Statement

Inference, solving, and finalization are currently one implicit protocol over a
broad mutable record. This causes:

1. raw integer IDs from unrelated domains being representationally compatible
   with metavariable IDs;
2. body-local solver state sharing ownership with graph and lowering state;
3. downstream code relying on convention that finalization has already run;
4. linear meta lookup/replacement and potentially repeated resolution chains;
5. complete typed-tree zonking without an explicit solved-product boundary; and
6. no API-level way to reject an inferred body where a solved body is required.

## What This Solves

- `InferredBody` and `SolvedBody` become distinct, opaque states.
- Every meta belongs to exactly one body-local solver table.
- Raw definition/local/resource IDs cannot be passed as `MetaId`.
- Validators receive a mechanically verified meta-free body.
- Solver failures and recovery artifacts are explicit.
- Solver costs can be counted and optimized independently.
- Lowering counters and graph state leave the type solver's ownership surface.

## Expected Performance And Cleanup Impact

There is no current isolated solver baseline, so the initial goal is a
mechanical ownership and representation improvement with measured follow-up.
The current meta store has clear scaling costs:

- lookup scans `meta_bindings`, making a probe linear in the number of body
  metas;
- binding replacement rebuilds the list;
- resolution may revisit binding chains; and
- finalization recursively rebuilds the complete typed expression and nested
  metadata.

Dense body-local meta allocation makes indexed lookup the expected first
optimization, changing lookup from linear scan toward constant-time indexed
access. Updates must still be measured under Blorp's value/COW semantics; a
dense representation that copies its entire table on every update would not
deliver the intended benefit.

Expected impact is **moderate to high for generic, overload-heavy, callback,
range, and tensor-dimension workloads**, and likely small for bodies that create
few metas. Separating solver state also reduces copying and retained memory by
removing package, graph, and lowering counters from each solver operation.

This phase enables:

- accurate per-body solver profiling;
- safe path compression or union-find if chain measurements justify it;
- caching only fully solved body artifacts;
- prompt release of failed solver sessions; and
- removing repeated zonk/finalization passes behind one solved-body invariant.

Expected cleanup includes raw integer meta APIs, list lookup/replacement
helpers, broad `Context` meta fields, meta reset helpers, duplicate zonk paths,
and lowering counters accidentally threaded through solver calls. Success
requires lower meta-probe/update work on controlled meta-heavy fixtures without
removing the final meta-freedom guard, plus wall-time and peak-memory evidence.

## Proposed Architecture

```text
opaque MetaId

SolverState {
    bindings: dense table indexed by MetaId,
    origins: dense table indexed by MetaId,
    ...body-local solver facts
}

opaque InferredBody {
    body: typed body that may contain MetaId,
    solver: SolverState
}

opaque SolvedBody {
    body: fully resolved typed body
}

solve_body(InferredBody) -> Result[SolvedBody, BodySolveFailure]
```

The public Phase 6 API remains:

```text
BodyCheckOutcome = Accepted(CheckedBodyArtifact) | Rejected(...)
```

Callers outside body checking never receive `InferredBody`. The accepted
artifact is constructed only after solving and Phase 9 validation.

## Implementation Plan

The numbered sections are ordered work, not necessarily one commit each. Form
mergepoints from vertical slices that include a focused test, a production
consumer, and deletion of the replaced path. Do not merge a dormant parallel
model.

### 1. Write Failing Product-Boundary Tests

Add `blorp/test/compiler/test_compiler_body_solver.brp` with compile-time and
runtime contracts proving:

- `InferredBody` cannot be passed to a solved-body consumer;
- only the solver constructor can create `SolvedBody`;
- an unresolved nested meta causes `BodySolveFailure`;
- meta IDs from separate sessions cannot be mixed; and
- source origins survive an unresolved-meta diagnostic.

Add focused source-language fixtures for occurs-check, unresolved overload,
dimension, callback, and generic diagnostics where exact output is part of the
public contract.

### 2. Inventory Current Solver Ownership

Build a call/ownership inventory for:

- `fresh_meta` and `fresh_meta_with_origin`;
- `lookup_meta`, `bind_meta`, and binding replacement;
- head/full resolution and resolution-cycle handling;
- occurs checks and unification;
- dimension solver integration;
- overload deferral and final selection;
- `zonk_type`, `zonk_typed_expr`, and all nested typed metadata traversed;
- unresolved-meta diagnostics; and
- every reader of `Context.meta_*` and `fresh_meta_counter`.

Separately classify non-solver `Context` fields. Package roots, type/trait homes,
resource cleanup metadata, definition allocation, and Core/lowering counters
must not move into the solver merely because they currently share the record.

### 3. Introduce Nominal `MetaId`

Use an opaque representation whose only constructors belong to the body-local
solver. Conversion to an integer index may remain private for dense storage and
diagnostic rendering.

Update `SemanticMetaType` and solver APIs to use `MetaId`. If changing
`SemanticType` in one step is too disruptive, add one checked transitional
boundary and delete it in this issue. Do not leave public `Int -> MetaId` or
`MetaId -> Int -> other ID` reinterpretation paths.

Session identity must be enforced structurally or by construction. A meta from
one body must fail closed if presented to another body's solver.

### 4. Separate `SolverState` From Broad `Context`

Move only body-local solver fields:

- fresh-meta frontier;
- meta origins;
- meta bindings/equivalence state;
- deferred constraints/overloads if currently body-local; and
- solver counters used for measurement.

Keep stable semantic type operations in Stage 05 where they belong. A type
utility should accept an explicit solver query when resolution is required
rather than depending on the complete compiler `Context`.

After the final solver consumer moves, remove meta fields and reset helpers from
the broad `Context`.

### 5. Establish `InferredBody`

Change expression/body inference to return an opaque inferred product containing
the typed tree plus its exact solver state. It may contain unresolved metas and
must not implement or expose accessors expected by validators/Core.

Preserve all typed metadata currently zonked by `zonk_typed_expr`, including:

- expression value/source types and value slots;
- resolved call instantiated parameters and return types;
- patterns and match metadata;
- lambda parameters and return annotations;
- collection/record field types;
- concurrent/select/with metadata;
- dimensions and range/proof facts; and
- nested declaration expression metadata.

### 6. Implement The Solved-Body Constructor

The constructor must:

1. resolve binding chains with cycle protection;
2. resolve all semantic types and nested metadata;
3. retain exact call/definition identities;
4. preserve source origins and diagnostic locations;
5. perform a final recursive meta-freedom check; and
6. return `BodySolveFailure` rather than fabricating `TYPE_VOID` or a partial
   accepted body.

The final meta-freedom check is intentionally redundant with normal resolution:
it is the constructor invariant for `SolvedBody`.

### 7. Improve Storage Mechanically, Then Measure

The current list representation makes lookup linear and replacement rebuild the
list. Because metas are allocated densely within a body, a dense indexed table
is the expected first replacement.

Do not combine this representation cutover with a new solver algorithm. First
preserve current unification and occurs-check behavior using exact indexed
storage. Then measure resolution-chain depth and repeated probes. Add path
compression or union-find only if the measured workload justifies it and the
implementation preserves useful origin diagnostics.

### 8. Cut Over Phase 9 And Delete Old Finalization

Make all post-inference validators accept only `SolvedBody`. Remove:

- public/raw meta integer APIs;
- `Context` meta fields and reset helpers;
- old `finalize_infer_result` and duplicate zonk traversals;
- optional/partial solved-body conventions; and
- adapters that expose inferred typed trees to CTFE or graph assembly.

## Likely Files To Touch

- `blorp/src/compiler/stage_05_types/context.brp`
- `blorp/src/compiler/stage_05_types/semantic_type.brp`
- `blorp/src/compiler/stage_05_types/dim_solver.brp`
- `blorp/src/compiler/stage_05_types/type_widening.brp`
- Phase 6 body session/artifact modules
- `blorp/src/compiler/stage_06_typecheck/state.brp`
- `blorp/src/compiler/stage_06_typecheck/infer.brp`
- `blorp/src/compiler/stage_06_typecheck/decl.brp`
- `blorp/test/compiler/stage_06_typecheck/test_infer.brp`
- `blorp/test/compiler/stage_06_typecheck/test_typecheck_types.brp`
- tensor/range/overload focused compiler suites
- compiler-test ownership manifest entries for new modules and suites

Suggested ownership after the cutover:

```text
stage_06_typecheck/body/solver/meta_id.brp
stage_06_typecheck/body/solver/state.brp
stage_06_typecheck/body/solver/solve.brp
stage_06_typecheck/body/solver/finalize.brp
```

Use fewer files if the dependency graph does not justify this split. The
product boundary matters more than file count.

## How To Test

### Focused Solver Tests

```bash
make
./blorp test --timeout 180 blorp/test/compiler/test_compiler_body_solver.brp
./blorp test --timeout 180 blorp/test/compiler/stage_06_typecheck/test_infer.brp
./blorp test --timeout 180 blorp/test/compiler/stage_06_typecheck/test_typecheck_types.brp
./blorp test --timeout 180 blorp/test/compiler/stage_06_typecheck/test_typecheck_decl.brp
```

Cover:

- direct and chained bindings;
- occurs-check failures and recursive types;
- generic inference and overload selection;
- callbacks and higher-order calls;
- ranges and tensor dimensions;
- nested lambda/match/collection metadata;
- unresolved and cyclic meta failures; and
- independent sessions with overlapping local meta indexes.

### Meta-Freedom Contract

Add an exhaustive typed-tree test that attempts to place a meta in each metadata
location handled by finalization. The solved constructor must reject or resolve
every case. The test must evolve when a new typed-expression variant or metadata
field is added.

### Diagnostics

For error fixtures, assert exact diagnostic lines and locations. Compare the
baseline and candidate output for generic, overload, occurs-check, range, and
dimension failures.

### Ownership And Sanitizers

```bash
scripts/test compiler-blorp-sanitize
scripts/test leak
```

Exercise long binding chains and failed solves. Ensure solver tables and
inferred recovery artifacts are released after each body.

### Performance

Add counters for:

- meta allocations;
- binding lookups and updates;
- occurs checks and visited nodes;
- resolution-chain steps and maximum depth;
- zonk/finalization typed-node visits; and
- final invariant-check visits.

Use generic, overload, callback, range, and dimension-heavy bodies. Record wall
time and peak memory alongside counters. Do not remove the final meta-freedom
check merely because it has a measurable cost without proving an equivalent
invariant.

### Gates

```bash
scripts/compiler-check --stage typecheck
make quality
git diff --check
```

## Acceptance Criteria

- `MetaId`, `InferredBody`, and `SolvedBody` are opaque, distinct products.
- All solver state is body-local and no longer stored in broad compiler
  `Context`/`TypecheckState`.
- Validators cannot accept `InferredBody`.
- Every nested solved-body fact is mechanically meta-free.
- Solver failures and diagnostics retain exact source origins.
- Current generic, overload, callback, range, and dimension semantics remain
  unchanged.
- Old finalization/meta APIs and duplicate zonk paths are deleted.
- Focused tests, sanitizer/leak checks, measurements, typecheck stage checks,
  and quality pass.

## Pitfalls And Non-Goals

- Do not change type inference semantics while extracting ownership.
- Do not move Core/lowering counters into body-local solver state.
- Do not use a type alias for `MetaId` if aliases are not nominally distinct.
- Do not expose unchecked integer conversion APIs.
- Do not add union-find/path compression before measuring the dense mechanical
  representation.
- Do not remove the final recursive meta-freedom guard without an equally strong
  construction invariant.
- Do not move lexical safety validation out of inference; Phase 9 defines rule
  placement.

## Handoff Checklist

- [ ] Verify the Phase 6 facade and session ownership are complete.
- [ ] Inventory all meta, unification, dimension, and zonk consumers.
- [ ] Add product-boundary and nested meta-freedom tests first.
- [ ] Separate `MetaId` and solver state without changing algorithms.
- [ ] Establish `InferredBody -> SolvedBody` for one body category.
- [ ] Measure dense storage before considering more complex algorithms.
- [ ] Cut over validators and delete old finalization APIs.
- [ ] Store any performance evidence under `benchmarks/results/`.
