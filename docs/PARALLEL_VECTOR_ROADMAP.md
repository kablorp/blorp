# Parallel Vector Cleanup Roadmap

Status: implemented through scoped API, legacy API cleanup, Core fusion, runtime
simplification, and benchmark/codegen audit coverage. Remaining work is
limited to optional ownership reuse and repeated performance measurements on
target hardware.

This roadmap tracks the cleanup from direct vector parallel functions toward a
scoped API that matches `List.parallel` while preserving vector-specific shape
advantages.

## Goals

- Give vector parallelism a scoped API, similar to `List.parallel`.
- Keep the public surface small and shape-preserving.
- Allocate at most one output vector for a fused parallel vector pipeline.
- Avoid materializing intermediate vectors between recognized stages.
- Borrow input and captured vectors when they are already variables.
- Preserve fixed-size shape information through the API and lowering.
- Keep illegal operations unrepresentable after typechecking.
- Fit the existing Core IR pipeline instead of adding ad hoc codegen paths.

## Non-Goals

- No `filter`, `filter_map`, `flat_map`, `partition`, `take`, or `drop`.
- No generic vector `fold_parallel`.
- No `reverse`, `rotate`, or `shift` in the scoped API.
- No public `_with` thread-count variants.
- No broad optimization of arbitrary higher-order functions.
- No source-storage reuse in this implementation. In-place reuse is a later
  ownership optimization.

Filtering is intentionally excluded because it destroys the fixed-size
invariant. A filter needs masks, compaction, or runtime-sized output, which is
list behavior rather than vector behavior.

## Target API

`std/vector.brp` owns the gateway and scoped type:

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

There is no scoped `filter`, `filter_map`, `flat_map`, `fold`, `reverse`,
`rotate`, `shift`, `take`, `drop`, or public thread-count override. Those either
change shape, do not have reliable parallel wins, or make the API less aligned
with the fixed-size vector model.

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

## IR Constraints

The source API lowers to a pipeline the compiler can reason about before
allocation:

- `ParallelVector[T, #N]` is a scoped view over the same runtime vector storage
  representation as `T[#N]`.
- A chain of `map`, `map_indexed`, and `zip_map` is shape-preserving; every stage
  has exactly `#N` output elements.
- The fusion pass builds a pass-local explicit plan, similar to
  `Core_collection_pipeline`, then lowers that plan to ordinary Core.
- Captured vectors used by more than one stage are borrowed once and reused in
  the generated loop body.
- Dimension equality is a type fact, not a runtime heuristic. `zip_map` accepts
  only `B[#N]`, so the runtime path does not use `min(len_a, len_b)` as a
  semantic fallback.

The pass runs in `Core_stage.Fusion`, after collection fusion and before tensor
fusion:

```ocaml
|> Core_string_pipeline.fuse_program ~reg
|> Core_collection_pipeline.fuse_program ~reg
|> Core_parallel_vector_pipeline.fuse_program ~reg
|> Core_tensor_fusion.fuse_program ~reg
|> Core_tuple_sroa.rewrite_program ~reg
```

Recognition uses `CKUser (_, Some def_id)` where possible for:

- `std/vector.parallel`
- `std/parallel_vector.map`
- `std/parallel_vector.map_indexed`
- `std/parallel_vector.zip_map`

A small source-name fallback exists only for focused unit tests that construct
Core by hand and bypass normal resolution.

## Implemented Phases

### Phase 1: Scoped API And Type Plumbing

- Added `ParallelVector[T, #N]` in `std/vector.brp`.
- Added `Vector.parallel`.
- Added `std/parallel_vector.brp` with `map`, `map_indexed`, and `zip_map`.
- Registered `ParallelVector` as a managed vector-shaped builtin through type
  layout, result layout, C type mapping, Core tensor shape facts, and UFCS
  method discovery.
- Added inference support for expected return binding through `T[#N]` results.
- Added tests for successful scoped map, indexed map, and zip-map, plus tests
  proving `filter`, `get`, and `for` are unavailable on the scoped view.

### Phase 2: Legacy API Migration

Removed public direct vector parallel APIs from `std/vector.brp`:

- `map_parallel`
- `map_indexed_parallel`
- `fold_parallel`
- `zip_parallel`
- `map_parallel_with`
- `map_indexed_parallel_with`
- `fold_parallel_with`
- `zip_parallel_with`

Runtime, memory, compiler, and benchmark coverage now use:

```blorp
values.parallel(pure func(chunk: ParallelVector[T, #N]):
	chunk.map_indexed(callback)
)
```

Zip pipelines now use:

```blorp
left.parallel(pure func(chunk: ParallelVector[A, #N]):
	chunk.zip_map(right, callback)
)
```

Vector `fold_parallel` coverage was deleted or converted to sequential `fold`
where the behavior was still worth testing. The old vector runtime fold path was
not meaningfully parallel and is no longer public.

### Phase 3: Pipeline Fusion

Added `Core_parallel_vector_pipeline`, which recognizes straight chains of
`map`, `map_indexed`, and `zip_map` inside a scoped `Vector.parallel` callback.

- Map-only plans lower to one `blorp_vmap_parallel` call.
- Plans that need the element index lower to one `blorp_vmap_indexed_parallel`
  call with a composed callback.
- Zip plans that use one same side vector lower to `blorp_vzip_parallel`, which
  passes that side vector explicitly instead of capturing it in the composed
  callback.
- Unsupported shapes are left unfused only when ordinary Core lowering remains
  correct.

### Phase 4: Runtime Simplification

- Removed public legacy codegen mappings for direct vector parallel names.
- Removed unused vector `_with` runtime wrappers.
- Removed the vector fold-parallel runtime path and matching compiler
  specialization/ownership metadata.
- Updated `vzip_parallel` to use the left vector length directly; public
  `zip_map` typing enforces the same `#N` on both inputs.

### Phase 5: Benchmarks And Audit

Added `benchmarks/blorp/vector_parallel.brp`, a standalone diagnostic benchmark
covering:

- single `map`
- `map.map`
- `map_indexed.map`
- `zip_map.map`
- captured vector reused in multiple stages
- managed-result elements

The benchmark emits parseable `BENCH` rows but does not make release-wide
performance claims.

Local sample collected on 2026-05-21 on an arm64 machine with 10 logical CPUs,
using `./blorp run --no-format benchmarks/blorp/vector_parallel.brp -- full`.
Times are total microseconds for the benchmark's configured iteration count.
`allocs/iter` is `total_allocations / iterations`; every sampled row reported
`live_objects=0` and `bytes_allocated=0` after the case.

| Operation | Size | Allocs/Iter | Threads=1 | Threads=4 | Threads=auto |
|-----------|------|-------------|-----------|-----------|--------------|
| `single_map` | 64 | 1 | 29315 | 26926 | 26306 |
| `map_map` | 64 | 1 | 45260 | 44290 | 43397 |
| `map_indexed_map` | 64 | 1 | 38548 | 38116 | 37885 |
| `zip_map_map` | 64 | 1 | 38036 | 37823 | 37660 |
| `captured_vector_reused` | 64 | 1 | 59423 | 57803 | 57746 |
| `managed_result` | 64 | 129 | 50364 | 48952 | 48834 |
| `single_map` | 1000 | 1 | 55622 | 20211 | 20733 |
| `map_map` | 1000 | 1 | 129728 | 37693 | 37868 |
| `map_indexed_map` | 1000 | 1 | 118456 | 38914 | 38308 |
| `zip_map_map` | 1000 | 1 | 119556 | 41175 | 38401 |
| `captured_vector_reused` | 1000 | 1 | 179976 | 60263 | 48799 |
| `managed_result` | 1000 | 2001 | 153713 | 75288 | 177758 |
| `single_map` | 120000 | 1 | 660967 | 192875 | 121800 |
| `map_map` | 120000 | 1 | 1418387 | 402454 | 246443 |
| `map_indexed_map` | 120000 | 1 | 1414035 | 405787 | 258323 |
| `zip_map_map` | 120000 | 1 | 1411073 | 406814 | 252264 |
| `captured_vector_reused` | 120000 | 1 | 2172080 | 623432 | 373930 |
| `managed_result` | 120000 | 240001 | 2134517 | 1186589 | 2724312 |

Observed shape:

- Fused non-managed map, indexed-map, and same-side-vector zip pipelines
  allocate one tracked object per invocation: the result vector.
- Fused same-side-vector zip pipelines pass the side vector as an explicit
  `blorp_vzip_parallel` runtime argument instead of capturing it in a callback
  closure. They do not materialize intermediate vectors.
- Managed-result pipelines are dominated by per-element list allocation, which
  is expected for this benchmark shape.
- Small vectors do not reliably benefit from wider thread pools; large
  non-managed numeric pipelines do.

Generated-C audit shape:

- `vector_parallel_pipeline_fusion.brp` verifies map-only chains lower to
  `blorp_vmap_parallel`.
- Indexed chains lower to `blorp_vmap_indexed_parallel`.
- Same-side-vector zip-map, reused-capture, and managed-result chains lower to
  `blorp_vzip_parallel`.
- The same audit asserts those scoped zip pipelines do not call
  `blorp_vmap_indexed_parallel` at their call sites.

## Remaining Work

- Repeat benchmark runs on target release hardware before making performance
  claims.
- Consider optional source-storage reuse after ownership analysis can prove the
  source is uniquely owned, dead after the pipeline, and layout-compatible with
  the result.
- Consider multiple `zip_map` fusion only if measurements justify the extra
  lowering complexity.

## Success Criteria

- The public vector parallel API has only `parallel`, `map`, `map_indexed`, and
  `zip_map`.
- Shape-changing operations are unavailable on `ParallelVector`.
- Chained scoped vector pipelines allocate only one output vector.
- Captured vector variables used in same-side zip pipelines avoid extra callback
  closure capture by using `blorp_vzip_parallel`.
- Generated C for fused chains has one vector parallel runtime boundary.
- Old direct vector parallel APIs are gone from `std/vector.brp`.
- Unit, compiler, runtime, doctest, benchmark, and codegen-audit coverage exist
  for the behavior.
