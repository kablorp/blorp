# Parallel Vector Roadmap

Status: proposed

This roadmap describes a scoped `ParallelVector` API for fixed-size vectors and
the compiler/runtime work needed to implement it without introducing
intermediate vector allocations. The goal is to align vector parallelism with
the scoped `List.parallel` model while taking advantage of vector-specific
shape guarantees.

## Goals

- Give vector parallelism a scoped API, similar to `List.parallel`.
- Keep the public surface small and shape-preserving.
- Allocate at most one output vector for a parallel vector pipeline.
- Avoid materializing intermediate vectors between stages.
- Borrow input and captured vectors when they are already variables.
- Preserve fixed-size shape information through the API and lowering.
- Keep illegal operations unrepresentable after typechecking.
- Fit the existing Core IR pipeline instead of adding ad hoc codegen paths.

## Non-Goals

- No `filter`, `filter_map`, `flat_map`, `partition`, `take`, or `drop`.
- No generic `fold_parallel`.
- No `reverse`, `rotate`, or `shift` in the first scoped API.
- No public `_with` thread-count variants.
- No broad optimization of arbitrary higher-order functions.
- No source-storage reuse in the first implementation. In-place reuse is a
  later ownership optimization.

Filtering is intentionally excluded because it destroys the fixed-size
invariant. A filter needs masks, compaction, or runtime-sized output, which is
list behavior rather than vector behavior.

## Proposed API

`std/vector.brp` owns the gateway and the scoped type:

```blorp
type ParallelVector[T, #N] = builtin

pure func parallel[T, U, #N](
	self: T[#N],
	body: pure (ParallelVector[T, #N]) -> ParallelVector[U, #N],
) -> U[#N]
```

`std/parallel_vector.brp` owns the scoped operations:

```blorp
pure func map[T, U, #N](
	self: ParallelVector[T, #N],
	f: pure (T) -> U,
) -> ParallelVector[U, #N]

pure func map_indexed[T, U, #N](
	self: ParallelVector[T, #N],
	f: pure (..#N, T) -> U,
) -> ParallelVector[U, #N]

pure func zip_map[A, B, C, #N](
	self: ParallelVector[A, #N],
	other: B[#N],
	f: pure (A, B) -> C,
) -> ParallelVector[C, #N]
```

Example:

```blorp
result: Float[#1024] = xs.parallel(pure func(v):
	v
		.map(pure func(x): x * x)
		.zip_map(bias, pure func(x, b): x + b)
)
```

The invariant is simple: every stage produces exactly one output element for
each input element.

## Vector-Specific Advantages

Fixed-size vectors give parallel lowering advantages that lists do not:

- The output length is known before execution.
- The compiler can prove `zip_map` inputs have the same `#N`.
- The runtime can allocate one `U[#N]` result up front.
- Workers can write disjoint output slices directly.
- `map_indexed` can pass a range-refined index, allowing safe indexing of
  captured `T[#N]` vectors.
- Captured same-sized vectors can be borrowed once and reused through the
  whole pipeline.
- Pipeline chains can be lowered to one kernel with no intermediate vectors.

## Current Implementation Precedents

The current system has useful pieces to reuse:

- `List.parallel` already establishes a scoped-view API pattern.
- `std/parallel_list.brp` shows how scoped operations live in a separate
  module.
- `Core_list_pipeline` builds a pass-local explicit plan for recognized list
  pipelines, then lowers it immediately.
- `Core_collection_pipeline` runs in the Fusion stage, before specialization,
  Perceus, reuse, and closure conversion.
- Existing vector runtime kernels already allocate exact-length vector results:
  `blorp_vmap_parallel`, `blorp_vmap_indexed_parallel`, and
  `blorp_vzip_parallel`.
- `Core_specialize` already appends vector parallel result-layout metadata.
- `Core_emit` already knows how to render vector parallel layout arguments.
- `CBorrowLet` lets compiler-synthesized aliases borrow existing variables
  without adding retain/drop noise.

These should be reused where they match the new invariant.

## Important IR Constraint

Do not start by adding a persistent `Core.desc` variant such as
`CVectorParallelPipeline`.

The existing list pipeline precedent is better: build an explicit
pass-local plan in a Fusion-stage module, then lower that plan to ordinary
Core. This avoids expanding every Core traversal, pretty printer, invariant,
Perceus path, closure path, and emitter before we know we need a long-lived IR
node.

The implementation should add a module such as:

```text
compiler/lib/core_parallel_vector_pipeline.ml
```

with a plan model like:

```ocaml
type source =
  | SourceVector of {
      expr : Core.core;
      elem_ty : Ast.type_expr;
      dim : Ast.type_expr;
    }

type stage =
  | StageMap of {
      callback : Core.core;
      input_ty : Ast.type_expr;
      output_ty : Ast.type_expr;
    }
  | StageMapIndexed of {
      callback : Core.core;
      input_ty : Ast.type_expr;
      output_ty : Ast.type_expr;
      dim : Ast.type_expr;
    }
  | StageZipMap of {
      other : Core.core;
      callback : Core.core;
      left_ty : Ast.type_expr;
      right_ty : Ast.type_expr;
      output_ty : Ast.type_expr;
      dim : Ast.type_expr;
    }

type t = {
  source : source;
  stages : nonempty_stages;
  result_ty : Ast.type_expr;
  loc : Ast.loc;
}
```

This plan should not survive the Fusion stage.

## Pipeline Placement

Run vector pipeline fusion in `Core_stage.Fusion`, after call resolution and
before specialization:

```ocaml
|> Core_string_pipeline.fuse_program ~reg
|> Core_collection_pipeline.fuse_program ~reg
|> Core_parallel_vector_pipeline.fuse_program ~reg
|> Core_tensor_fusion.fuse_program ~reg
|> Core_tuple_sroa.rewrite_program ~reg
```

This stage is appropriate because:

- Monomorphization has already run.
- Synthesized std bodies are available.
- Match and trait resolution have already run.
- `Core_resolve` has concrete call identities.
- Closures have not been hoisted yet.
- Perceus has not inserted RC operations yet.
- Specialization has not added layout/release metadata yet.

## Recognition Strategy

Prefer DefId-based recognition:

- `std/vector.parallel`
- `std/parallel_vector.map`
- `std/parallel_vector.map_indexed`
- `std/parallel_vector.zip_map`

Recognize resolved calls with `CKUser (_, Some def_id)` where possible. Keep a
small source-name fallback only for focused unit tests that construct Core by
hand and bypass normal resolution.

Avoid string prefixes and generated C names in correctness logic. If the pass
needs to distinguish a stage, represent it as a `StageMap`, `StageMapIndexed`,
or `StageZipMap` variant.

## Lowering Strategy

The first optimized lowering should reduce each recognized pipeline to one
existing vector parallel runtime kernel by composing callbacks.

### Map-only chains

Source:

```blorp
xs.parallel(pure func(v):
	v.map(f).map(g).map(h)
)
```

Lower to one `blorp_vmap_parallel` with a composed callback:

```blorp
pure func(x):
	h(g(f(x)))
```

### Indexed map chains

Source:

```blorp
xs.parallel(pure func(v):
	v.map_indexed(f).map(g)
)
```

Lower to one `blorp_vmap_indexed_parallel` with:

```blorp
pure func(i, x):
	g(f(i, x))
```

### One zip_map chain

Source:

```blorp
xs.parallel(pure func(v):
	v.map(f).zip_map(ys, g).map(h)
)
```

Lower to one `blorp_vzip_parallel` with:

```blorp
pure func(x, y):
	h(g(f(x), y))
```

This gives the core performance target:

- one output allocation
- zero intermediate vector allocations
- one parallel runtime boundary
- no tuple-vector allocation
- borrowed source and captured vectors

## Initial Supported Pipeline Shapes

Start with these shapes:

- `map+`
- `map_indexed -> map*`
- `map* -> zip_map -> map*`
- `map_indexed -> map* -> zip_map -> map*`

Where `map+` means one or more `map` stages, and `map*` means zero or more
`map` stages.

Defer these shapes:

- multiple `zip_map` stages
- `zip_map` before `map_indexed`
- `zip_map` with non-variable captured vector expressions unless they are
  bound once before lowering
- in-place output reuse

Multiple `zip_map` stages are possible, but they need an indexed kernel or a
generated C loop that can read several captured vectors safely. That can come
after the scoped API and single-zip fusion are stable.

## Borrowing And Single Evaluation

The lowering must preserve single evaluation and avoid unnecessary ownership
traffic.

Rules:

- If the source vector is a `CVar`, bind it with `CBorrowLet`.
- If the source vector is not a `CVar`, bind it with owned `CLet`.
- If a captured `zip_map` vector is a `CVar`, bind it with `CBorrowLet`.
- If a captured `zip_map` vector is not a `CVar`, bind it with owned `CLet`.
- Reuse the same borrowed/owned binding anywhere the vector is referenced in the
  composed callback.
- Do not retain/copy a vector just because it appears in multiple stages.

This keeps the one-allocation goal intact for code like:

```blorp
var weights: Float[#1024] = ...
out = xs.parallel(pure func(v):
	v
		.zip_map(weights, pure func(x, w): x * w)
		.zip_map(weights, pure func(x, w): x + w)
)
```

The multiple-`zip_map` shape may be deferred, but when implemented it should
borrow `weights` once.

## Typechecking And Inference Work

Add `ParallelVector` as a builtin type with a dimension parameter:

```blorp
ParallelVector[T, #N]
```

Required behavior:

- `vector.parallel(...)` should pass a scoped `ParallelVector[T, #N]` view to
  the callback.
- `parallel` returns the callback result materialized as `U[#N]`.
- `map` and `map_indexed` preserve `#N`.
- `zip_map` requires the other vector to have the same `#N`.
- callbacks must be pure.
- `map_indexed` callback receives `..#N` if range types support that directly.
  If parser/type support does not yet accept this in function parameters, use
  `Int` first and add the range refinement in a follow-up.
- `ParallelVector` should not support ordinary vector/list operations.

Negative diagnostics should reject:

- `pv.length()`
- `pv.get(0)`
- `pv.set_index(0, x)`
- `for x in pv`
- `pv.filter(...)`
- `pv.fold(...)`
- impure callbacks
- nested parallelism
- mismatched dimensions in `zip_map`

## Nested Parallelism

`parallel` is already marked as a parallel boundary in builtin metadata. Keep
that model and make sure `vector.parallel` participates in the same nested
parallelism check as `List.parallel`.

Old direct vector parallel functions are also currently marked as parallel
boundaries. During migration, keep this protection until those public entry
points are removed.

## Std And Module Loading

Add:

```text
std/parallel_vector.brp
```

Wire module resolution similarly to `ParallelList`:

- A `ParallelVector` method should load `std/parallel_vector`.
- The scoped type should be known to typecheck/import logic.
- The normal user should not need to explicitly import `parallel_vector`.

Decide whether `ParallelVector` is prelude-visible. Prefer inference over
requiring callback parameter annotations. If annotations are needed, either add
it to the prelude or improve inference enough to avoid annotation pressure.

## Runtime Work

Reuse existing vector kernels for the first implementation:

- `blorp_vmap_parallel`
- `blorp_vmap_indexed_parallel`
- `blorp_vzip_parallel`

Audit and adjust:

- `blorp_vzip_parallel` currently uses the minimum runtime length of the two
  inputs. The typed path should have equal `#N`; keep a defensive check if
  needed, but typed generated code should rely on static equality.
- `blorp_vfold_parallel` is effectively sequential and should not remain a
  public vector API.
- `_with` thread-count variants should not be part of the new std surface.

Avoid a generic stage-interpreter runtime in the first implementation. A
stage-interpreter would add dynamic dispatch per element and can erase much of
the benefit of fusion. Composed callbacks plus existing kernels are a better
fit for the current IR.

## Migration

Remove or deprecate these public `std/vector.brp` functions:

- `map_parallel`
- `map_indexed_parallel`
- `zip_parallel`
- `fold_parallel`
- `map_parallel_with`
- `map_indexed_parallel_with`
- `zip_parallel_with`
- `fold_parallel_with`

Replacement examples:

```blorp
-- Old
result = map_parallel(xs, pure func(x): x * 2)

-- New
result = xs.parallel(pure func(v):
	v.map(pure func(x): x * 2)
)
```

```blorp
-- Old
result = map_indexed_parallel(xs, pure func(i, x): x + weights[i])

-- New
result = xs.parallel(pure func(v):
	v.map_indexed(pure func(i, x): x + weights[i])
)
```

```blorp
-- Old
result = zip_parallel(xs, ys, pure func(x, y): x + y)

-- New
result = xs.parallel(pure func(v):
	v.zip_map(ys, pure func(x, y): x + y)
)
```

Add should-fail tests for old imports with migration guidance.

## Test Plan

Compiler should-pass:

- `parallel_vector_map.brp`
- `parallel_vector_map_indexed.brp`
- `parallel_vector_zip_map.brp`
- `parallel_vector_chain_map_zip_map.brp`
- `parallel_vector_infers_callback_param.brp`
- `parallel_vector_zip_map_dimension_match.brp`

Compiler should-fail:

- `parallel_vector_filter_unavailable.brp`
- `parallel_vector_fold_unavailable.brp`
- `parallel_vector_length_unavailable.brp`
- `parallel_vector_get_unavailable.brp`
- `parallel_vector_for_unavailable.brp`
- `parallel_vector_impure_callback.brp`
- `parallel_vector_nested_parallelism.brp`
- `parallel_vector_zip_map_dim_mismatch.brp`
- `vector_map_parallel_removed.brp`
- `vector_zip_parallel_removed.brp`
- `vector_fold_parallel_removed.brp`

Runtime tests:

- map over primitive vectors
- map over managed element vectors
- map_indexed with captured same-sized vector
- zip_map over primitive vectors
- zip_map over managed element vectors
- chained map/zip_map/map
- empty or zero-sized vector if the type system supports it
- large vector enough to hit the thread-pool path

Memory tests:

- managed map result releases nested elements
- zip_map managed result releases nested elements
- captured vector used in more than one stage is not copied/materialized per
  stage
- no leaks with chained callbacks

Codegen audit:

- chained pipeline emits one `blorp_vmap_parallel` or `blorp_vzip_parallel`
- chained pipeline does not emit intermediate `blorp_vmap_parallel` calls
- `zip_map` pipeline does not emit a tuple vector
- old public `zip_parallel` does not appear in generated C from new API tests
- result layout metadata is appended once

Core unit tests:

- plan recognition for each supported stage
- plan rejection for unsupported shapes
- callback composition preserves stage order
- borrow binding is used for `CVar` source/captured vectors
- owned binding is used for non-variable source/captured vectors

## Implementation Phases

### Phase 1: API And Static Safety

- Add `std/parallel_vector.brp`.
- Add `ParallelVector[T, #N]` builtin type plumbing.
- Add `vector.parallel`.
- Add scoped `map`, `map_indexed`, and `zip_map`.
- Add typecheck/infer tests for allowed and rejected operations.
- Keep implementation simple and correct, even if it initially lowers through
  existing single-stage runtime kernels.

### Phase 2: Replace Public Direct Vector Parallel APIs

- Migrate runtime and compiler tests from direct `map_parallel`,
  `map_indexed_parallel`, and `zip_parallel` to scoped `parallel`.
- Remove public direct vector parallel declarations from `std/vector.brp`.
- Add migration diagnostics or should-fail cases for old imports.
- Remove `fold_parallel` from public vector API.
- Keep runtime C functions if scoped lowering still uses them internally.

### Phase 3: Fusion Plan

- Add `Core_parallel_vector_pipeline`.
- Recognize scoped chains after call resolution in `Core_stage.Fusion`.
- Build explicit pass-local plans with `StageMap`, `StageMapIndexed`, and
  `StageZipMap`.
- Reject unsupported plan shapes by leaving them alone only if a correct
  fallback exists. If no fallback exists, make the earlier typechecker reject
  those shapes.

### Phase 4: One-Allocation Lowering

- Lower map-only chains to one `blorp_vmap_parallel`.
- Lower indexed chains to one `blorp_vmap_indexed_parallel`.
- Lower one-`zip_map` chains to one `blorp_vzip_parallel`.
- Compose callbacks in Core before closure conversion.
- Bind source and captured vectors once, borrowing existing variables.
- Add codegen audits proving no intermediate vector runtime calls appear.

### Phase 5: Ownership Hardening

- Verify Perceus sees the composed callback and the single result owner.
- Add leak tests for managed callback results.
- Confirm captured vectors are borrowed across the pipeline and not dropped
  before worker callbacks finish.
- Add invariants or focused tests for illegal `ParallelVector` operations after
  typechecking.

### Phase 6: Optional In-Place Reuse

Only after the one-allocation implementation is stable:

- Detect source uniquely owned and dead after the pipeline.
- Require compatible result storage layout.
- Reuse source storage for result writes.
- Keep value semantics: never overwrite a vector that can be observed later.
- Measure before making this the default.

## Open Questions

- Should `ParallelVector` be prelude-visible, or should callback parameter
  inference make annotations unnecessary?
- Can `map_indexed` expose `..#N` immediately, or do we need an `Int` bridge
  until range-refined callback parameters are supported?
- Should multiple `zip_map` stages be rejected initially or allowed with a
  materializing fallback? Rejection is simpler and keeps the performance
  contract honest.
- Should old direct vector parallel functions produce migration diagnostics
  before removal, or is immediate removal acceptable during cleanup?
- Should thread-count control stay entirely runtime/env-based, or should there
  be a future explicit scheduler policy type?

## Success Criteria

- The public vector parallel API has only `parallel`, `map`, `map_indexed`, and
  `zip_map`.
- Shape-changing operations are unavailable on `ParallelVector`.
- Chained scoped vector pipelines allocate only one output vector.
- Captured vector variables used in multiple stages are borrowed once.
- Generated C for fused chains has one vector parallel runtime boundary.
- Old direct vector parallel APIs are gone from `std/vector.brp`.
- Unit, compiler, runtime, doctest, and codegen-audit tests cover the behavior.
