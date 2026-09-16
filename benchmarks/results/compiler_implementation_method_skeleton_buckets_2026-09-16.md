# Implementation-Method Skeleton Buckets

Issue 129. `implementation_methods` used to rescan every callable skeleton in
the module (types, traits, unrelated free functions, and all other
implementations' methods included) once per implementation, via a fresh call
to `declaration_skeleton_graph_callable_skeletons` per implementation. This
change builds one `ImplId`-keyed bucket map from a single catalog pass in
`implementation_header_graph_build`, then passes only the matching bucket to
`implementation_methods`.

## Decision

Accept. The wide multi-implementation workload reduced retired instructions by
72.90% and elapsed time by 76.65%, far exceeding the issue's 15% floor. The
one-implementation control changed retired instructions by +0.05% (5,000
iterations) and -0.04% (50,000 iterations), well inside the 3% guardrail.
Ordered header/method checksums matched exactly at every scale tested, method
source order and explicit/default distinction were preserved, and no
dictionary clone traffic appeared (allocations fell in the wide case and only
grew by ~9 per iteration, from one-time bucket construction, in the control).

## Candidate Description

`implementation_header_graph_build` now calls
`declaration_skeleton_graph_callable_skeletons` exactly once and folds the
result into `implementation_method_skeleton_buckets`, a
`Dict[Int, List[CallableDeclarationSkeletonInfo]]` keyed by
`impl_id_definition_id`. Each bucket collects the `ImplementationMethodCallableSource`
and `DefaultImplementationMethodCallableSource` skeletons whose owner maps to
that key, appended in catalog order (the same accretion idiom as
`method_skeleton_buckets` in `trait_headers.brp`). Per implementation,
`implementation_method_skeletons_for_owner` looks up the bucket by
`impl_id_definition_id(owner)` and re-checks exact identity with
`impl_ids_equal`, mirroring `method_skeletons_for_owner`'s defense against an
Int key that is not provably injective across all encodings. `implementation_methods`
now receives that pre-filtered bucket directly and no longer re-derives or
rescans the callable skeleton list itself; it only removed the per-skeleton
`impl_ids_equal(owner, implementation_id)` guard that the bucket already
guarantees. The bucket map is a local variable inside
`implementation_header_graph_build` and is never stored on
`ImplementationHeaderGraph` or any other public product — it does not escape
graph construction. Trait lookup (`find_default_trait_method`), signature
resolution, and accepted-authority behavior are untouched.

## Files Changed

- `blorp/src/compiler/stage_06_typecheck/headers/implementation_headers.brp` —
  production change: `ImplementationMethodSkeletonBuckets` type alias,
  `implementation_method_skeleton_owner`, `implementation_method_skeleton_buckets`,
  `implementation_method_skeleton_matches_owner`,
  `implementation_method_skeletons_for_owner`; `implementation_methods` takes
  a `candidate_skeletons` bucket parameter instead of rescanning; construction
  and lookup wired into `implementation_header_graph_build`.
- `blorp/test/compiler/stage_06_typecheck/test_implementation_headers.brp` —
  two new regression tests (see below).
- `blorp/benchmark/compiler/compiler_implementation_method_skeleton_bucket_profile_fixture.brp`
  and `compiler_implementation_method_skeleton_bucket_profile.brp` — new
  synthetic-source benchmark harness varying implementation count, methods per
  implementation, default methods per implementation, and unrelated callables.
- `benchmarks/compiler_implementation_method_skeleton_bucket_profile` — shell
  wrapper over `compiler_blorp_benchmark_runner`, matching the existing
  `compiler_implementation_method_parameter_profile` convention.
- `blorp/test/compiler/stage_06_typecheck/test_implementation_method_skeleton_bucket_profile_benchmark.brp`
  — small in-suite tests exercising the fixture at unit scale.
- `blorp/test/compiler/compiler_test_ownership.json` — registered the new
  benchmark suite and added it to `implementation_headers.brp`'s owning
  suites.

## Tests Added

In `test_implementation_headers.brp`:

- `bucket methods by exact implementation identity` — two implementations
  under one trait, interleaved with three unrelated free functions
  (`unrelated_before`/`unrelated_between`/`unrelated_after`) and a default
  trait method neither implementation overrides. Asserts each header's
  explicit methods are exactly its own, in source order (`["measure", "extra"]`
  vs `["measure"]`), the default method (`doubled`) is attributed to both
  independently, and no method leaks across implementations or picks up an
  unrelated free function.
- `preserve error order across implementations` — two implementations each
  with a method-level type parameter that shadows the implementation's own
  type parameter. Confirms both implementations independently produce their
  own `ImplementationMethodShadowsImplementationTypeParameter` and consequent
  `ImplementationMissingRequiredMethod` errors (4 errors total, not
  cross-attributed or deduplicated), in stable source order (first
  implementation's shadow-error span line precedes the second's).

In `test_implementation_method_skeleton_bucket_profile_benchmark.brp`: fixture
correctness at unit scale (multi-implementation method/header counts, a
single-implementation control, and rejection of a non-positive implementation
count).

## Fast Loop And Gates

```
bin/blorp test --timeout 180 blorp/test/compiler/stage_06_typecheck/test_implementation_headers.brp
```
`All 9 tests passed` (7 pre-existing + 2 new), on both the pre-change and
post-change build.

```
bin/blorp test --timeout 180 blorp/test/compiler/stage_06_typecheck/test_implementation_method_skeleton_bucket_profile_benchmark.brp
bin/blorp test --timeout 180 blorp/test/compiler/stage_06_typecheck/test_implementation_method_parameter_profile_benchmark.brp
```
`All 3 tests passed` / `All 2 tests passed`.

`scripts/compiler-check --stage typecheck`, `scripts/compiler-check --changed`,
and `scripts/test compiler-blorp` all currently fail on this branch, but the
failure is **pre-existing and unrelated to this change**: the whole-program
compile step reports purity/type errors in unrelated benchmark fixtures
(`compiler_source_name_catalog_profile_fixture.brp`,
`compiler_type_header_mixed_profile_fixture.brp`, and a `FreshMetaStep`/
`Context` record-update mismatch). Verified by `git stash` back to the clean
base commit `cab823d4bb025218b9d6c7759ea38f7e9cf582b3` (no local changes) and
re-running the identical gates — they fail with the exact same error list.
Flagged separately for a dedicated fix; not addressed here per "one change per
change." The narrower `Production Blorp Check Fixtures` component of
`scripts/test compiler-blorp` (57 fixtures) passed 57/57.

## Benchmark Data

Harness: `benchmarks/compiler_implementation_method_skeleton_bucket_profile
plain <iterations> <implementations> <methods-per-implementation>
<default-methods-per-implementation> <unrelated-callables>`. It builds a
synthetic module with one trait, N implementations of distinct record types
(each with 1 required + M extra explicit methods, plus D unoverridden default
methods), and U unrelated top-level functions, then repeatedly calls production
`implementation_header_graph_build` inside a timed/instrumented window.
5 alternating samples per side unless noted; medians reported. Instructions
retired came from `/usr/bin/time -lp` around the cached, `-O2`-compiled
benchmark binary.

### Wide multi-implementation workload

`256 implementations, 4 extra methods, 1 default method, 512 unrelated
callables, 20 iterations`:

| Metric | Baseline median | Candidate median | Change |
| --- | ---: | ---: | ---: |
| Retired instructions | 23,663,759,823 | 6,409,759,810 | **-72.90%** |
| Elapsed (measured window) | 1,352,505 us | 315,822 us | -76.65% |
| Allocations | 14,740,660 | 4,285,840 | -70.93% |
| Ordered header checksum | 5533996403277553843 | 5533996403277553843 | identical |

### Larger scale confirmation (single sample per side)

`512 implementations, 4 extra methods, 1 default method, 512 unrelated
callables, 10 iterations`:

| Metric | Baseline | Candidate | Change |
| --- | ---: | ---: | ---: |
| Retired instructions | 42,732,593,843 | 10,804,227,206 | -74.71% |
| Allocations | 25,231,460 | 6,901,980 | -72.65% |
| Ordered header checksum | 3477848553613546558 | 3477848553613546558 | identical |

### One-implementation control

`1 implementation, 4 extra methods, 1 default method, 512 unrelated
callables`:

| Iterations | Metric | Baseline median | Candidate median | Change |
| ---: | --- | ---: | ---: | ---: |
| 5,000 | Retired instructions | 6,185,605,377 | 6,188,677,276 | +0.05% |
| 5,000 | Allocations | 4,205,000 | 4,250,000 | +1.07% |
| 50,000 (4 samples) | Retired instructions | 60,935,806,956 | 60,910,814,840 | -0.04% |
| 50,000 | Allocations | 42,050,000 | 42,500,000 | +1.07% |

Elapsed micros were noisy at this small workload size (sub-millisecond total
measured work per sample) and are not reported as the deciding signal; retired
instructions and allocations, which are deterministic per iteration here, both
stay far inside the 3% guardrail. The fixed +9 allocations/iteration in the
control is the one-time bucket-dict insert plus filtered-bucket lookup for a
single implementation, not clone traffic — the wide case's allocation count
falls sharply, ruling out systematic dictionary copying.

All runs reported `workload_valid=True` and matching `warmup_checksum` /
`ordered_header_checksum` between the single-iteration warmup and the
multi-iteration measured window, on both baseline and candidate.

## Provenance

- Base revision (working tree before this change): `cab823d4bb025218b9d6c7759ea38f7e9cf582b3`.
- Platform: Darwin 25.6.0 arm64, Apple M4.
- Baseline `implementation_headers.brp` SHA-256:
  `03102e4d5eddd35e16b37d22d3c7697ffd6a2f45e12b013d4aa38afd7b18212b`.
- Candidate `implementation_headers.brp` SHA-256:
  `31c76273e479df8d367e822299b679b7a0053951954151c9b283220f2314f394`.
- Baseline `bin/blorp` SHA-256:
  `499bc3467d3a4fe64f5a845b572aaa6d3612a56a6896f23f2ce0b713b251ed19`.
- Candidate `bin/blorp` SHA-256:
  `38d7a4d27db22d695b7da6230700f5bbd4ae8df7230bbedda30c9f14b6c4daa7`.
- Baseline benchmark executable SHA-256:
  `a4e66aa3288dfe6f91c0299fe2c05205774a059ddd5e755247fd07e88ee6d035`.
- Candidate benchmark executable SHA-256:
  `e3fcfd9d6d4d5283d6d2d6debb8136a7d018476d601f54e1b235bf24ffed7f9a`.
- Benchmark driver (`compiler_implementation_method_skeleton_bucket_profile.brp`)
  SHA-256: `aef109ccae5ee7ef69b64ac62da875557d81f6fbc9bb2204e067cad5b91888c2`.
- Benchmark fixture
  (`compiler_implementation_method_skeleton_bucket_profile_fixture.brp`)
  SHA-256: `6375788ca981d23d4c29b77f36c383793cce89ed59be4713f9943d305871ba2d`.

## Reproduction

```bash
make
benchmarks/compiler_implementation_method_skeleton_bucket_profile plain 20 256 4 1 512
benchmarks/compiler_implementation_method_skeleton_bucket_profile plain 5000 1 4 1 512
benchmarks/compiler_implementation_method_skeleton_bucket_profile plain 10 512 4 1 512
```

For instruction counts, locate the cached binary under
`~/.cache/blorp/benchmarks/compiler-implementation-method-skeleton-bucket-profile/<hash>/`
(printed indirectly by the wrapper; `BLORP_COMPILER_BENCHMARK_SKIP_BUILD=1`
avoids rebuilding once cached) and run it directly under
`/usr/bin/time -lp <binary> <iterations> <implementations> <methods> <defaults> <unrelated>`,
alternating baseline/candidate order across samples.
