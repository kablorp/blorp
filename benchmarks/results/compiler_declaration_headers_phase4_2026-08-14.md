# Phase 4 Declaration Header Profile

Date: 2026-08-14

## Contract

`benchmarks/compiler_typecheck_phase_profile` constructs and validates the
complete Phase 1-4 fixture before opening its function-profile window. Each
stage then rebuilds exactly one pure product from its immediate accepted
predecessor. Observation happens after the window and traverses the resulting
product into a deterministic checksum.

The Phase 4 fixture extends the mixed type-header source only for this isolated
harness. Each of eight dependency modules contributes one trait with one
required method and one exact implementation. The complete measured inventory
contains:

- 8 trait topology headers and 8 method slots;
- 521 ordinary callable headers and 16 annotated globals;
- 8 implementation headers and 8 implementation methods; and
- 1,144 declaration skeletons plus 9 importable modules in the accepted
  facade.

The deterministic profile test runs every Phase 1-4 stage twice and requires
non-empty products and identical observations. The broader mixed type-header
benchmark source is unchanged.

## Environment

The working source was based on revision `5136ba6d9eb3` and contained the
uncommitted Phase 4 implementation under measurement.

```text
Darwin 25.5.0 arm64
Apple clang 21.0.0
Blorp 0.0.1 local compiler
```

The runner compiled the benchmark with function instrumentation and `-O0`.
Times below characterize inclusive constructor work and should not be treated
as optimized end-to-end compiler timings.

## Commands

```bash
BLORP_COMPILER_BENCHMARK_SKIP_BUILD=1 \
  benchmarks/compiler_typecheck_phase_profile topology 10 8 32 64 4
BLORP_COMPILER_BENCHMARK_SKIP_BUILD=1 \
  benchmarks/compiler_typecheck_phase_profile callables 10 8 32 64 4
BLORP_COMPILER_BENCHMARK_SKIP_BUILD=1 \
  benchmarks/compiler_typecheck_phase_profile implementations 10 8 32 64 4
BLORP_COMPILER_BENCHMARK_SKIP_BUILD=1 \
  benchmarks/compiler_typecheck_phase_profile accepted 100 8 32 64 4
```

## Closure Baseline

| Stage | Builds | Window us | Per build us | Primary | Secondary |
| --- | ---: | ---: | ---: | ---: | ---: |
| Trait topology | 10 | 10,936 | 1,094 | 8 | 8 |
| Callable headers | 10 | 1,382,146 | 138,215 | 521 | 16 |
| Implementation headers | 10 | 36,044 | 3,604 | 8 | 8 |
| Accepted facade | 100 | 213 | 2.1 | 1,144 | 9 |

Checksums were respectively `-6495045407886840906`,
`-9172927260034877371`, `-8966752484004013016`, and
`-5062659951511599294`.

Callable construction is the material Phase 4 cost on this fixture. Across ten
builds, its inclusive profile reported:

| Function | Inclusive ms | Calls |
| --- | ---: | ---: |
| `compiler_callable_header_graph_build` | 1,379.702 | 10 |
| `append_callable_header` | 1,366.389 | 5,210 |
| `resolve_callable_signature` | 755.152 | 5,210 |
| `compiler_resolve_callable_type_shape` | 688.217 | 20,020 |
| `effective_callable_type_parameters` | 423.981 | 5,210 |
| `compiler_type_header_graph_has_unqualified_type_name` | 145.444 | 15,380 |

Inclusive rows overlap and must not be added. The unqualified-name probes are a
reasonable future leaf investigation, but Phase 4 does not add a cache or a
second semantic index without a representative optimized before/after result.

## Retained Optimization

Phase 4's retained optimization remains the exact definition-ID topology
index. Its dedicated representative benchmark records a 24.5% improvement over
the preceding short-name bucket and a 61.6% improvement over the recursive
cycle builder. See
`compiler_trait_topology_phase4a_2026-08-14.md` for seven-run medians, the
4,096-trait depth regression, and rejected index designs.

### Follow-up: Two-pass skeleton construction

An optimized native profile found declaration skeleton construction scaling
quadratically. The previous aggregate build state retained its ordered list and
name dictionary across each record update, so generated C copied the whole
dictionary on every accepted skeleton.

Skeleton construction now has two explicit passes. The first produces ordered
candidate-or-error items. The second validates those items and owns the output
list, name index, and diagnostics as independent local values. Generated C now
consumes the dictionary directly into `Dict.set` without retaining it first.

The exact optimized measurement command was:

```bash
BLORP_COMPILER_BENCHMARK_SKIP_BUILD=1 \
  benchmarks/compiler_blorp_benchmark_runner \
  compiler-typecheck-phase-profile \
  compiler/benchmarks/compiler_typecheck_phase_profile.brp \
  plain skeleton 100 8 32 64 4
```

Across seven runs, median time for 100 builds fell from 883,197 us to 55,781
us, or from 8.832 ms to 0.558 ms per build. That is a 15.8x speedup and a 93.7%
reduction in the isolated skeleton window. The fixture checksum and 1,144-item
inventory were unchanged. Post-fix scaling was also close to linear: increasing
the inventory from 760 to 2,680 skeletons increased per-build time from 0.414
ms to 1.090 ms.

### Follow-up: Prepared callable resolution context

Callable signature construction previously rebuilt the same type-resolution
context for every parameter type, return type, and dimension-constraint side.
Each call revalidated parameter ownership, converted the parameter IDs,
extracted the declaration and bound graphs, and repeated the owner-module
lookup.

The type-header graph now exposes an opaque callable resolution context whose
constructor performs those checks once. Callable-header construction prepares
one context after resolving the callable's type parameters and reuses it for
the complete signature. The opaque boundary prevents callers from constructing
a context with an unchecked owner, module, or parameter set.

Using the same optimized runner and the `callables 100 8 32 64 4` fixture, seven
fresh runs were interleaved with a detached `main` worktree to control for host
load. Median time for 100 builds fell from 313,655 us to 281,248 us, or from
3.137 ms to 2.812 ms per build. That is a 10.3% improvement in the isolated
callable-header window. The 521-callable inventory and checksum
`-57112854785136987` were unchanged.

## Result

The Phase 4 constructors now have separate, non-empty, deterministic profile
windows. Setup, parsing, predecessor construction, and product observation are
outside those windows. The retained topology, skeleton, and callable-context
optimizations all preserve the fixture contracts and have isolated optimized
before/after measurements.
