# Compiler C Symbol Projection Phase Profile

Date: 2026-08-23

This profile isolates `project_core_program_callables` from every earlier
compiler phase and from C emission. Synthetic finalized `CoreProgram` fixture
construction, one warmup run, and exact output observation are outside the
function-profile window. The measured function only projects already-built
programs and retains the final projected values.

The original hash baseline checked projected definition and call counts, its
fixed 13-byte symbol width, and an order-sensitive checksum over every byte of
every projected definition and direct-call name. The compact-ID follow-up
checks each name against the callable's base-62 definition-ID projection and
computes the expected variable-width byte count from those IDs.

## Provenance

| Input | Value |
| --- | --- |
| Git revision | `013191013400814cf689e2743282b079a9c33963` |
| Benchmark compiler SHA-256 | `590955d9d31cd9872c7c830fdb3ed8eefce6b08ca4a9dcd7b0a2af0f57518bf6` |
| Benchmark source SHA-256 | `afbc1c4cd687883c433526052b6ab55dc366ec39f700739dfee951ef540729e7` |
| Wrapper SHA-256 | `41b280d40a7740dff5878f6fb7f47cf52226d3b87b01d7ed3c3f3dd7c1c4549f` |
| Profile executable SHA-256 | `5df83162c5cea29d2532bb52ed04a6b2a0790a1b5535ecda30d4a6c4ac61e49b` |
| Host | Darwin 25.5.0, arm64, Apple M4 |
| C compiler | Apple clang 21.0.0 |
| Instrumentation | Blorp `--profile`, C `-O0` |

Absolute times apply only to this instrumented comparison series. They are not
release-build latency estimates.

## Compact-ID Follow-Up

The follow-up replaces late hashing with `brp_` plus the artifact-local
definition ID encoded in base 62. The delimiter keeps compact identifiers out
of the ordinary C word namespace. Five fresh process samples used the same
candidate-heavy workload as the hash baseline:

| Function / metric | Hash median | Compact-ID median | Change |
| --- | ---: | ---: | ---: |
| `project_core_program_callables` | 45.127 ms | 16.256 ms | -64.0% |
| `build_callable_symbol_plan` | 34.137 ms | 4.890 ms | -85.7% |
| `check_definition_id_uniqueness` | n/a | 0.896 ms | required new check |
| `project_expr` | 8.135 ms | 7.983 ms | -1.9% |
| `validate_program_projection` | 3.522 ms | 3.371 ms | -4.3% |
| Profile window | 45.662 ms | 16.797 ms | -63.2% |
| Projected identifier bytes | 3,328 | 1,475 | -55.7% |

The validation delta is sensitive to instrumented-code layout and is outweighed
by the removed planning work; validation source and call counts are unchanged.

One 4,096-callable iteration fell from 74.087 ms to 26.585 ms (-64.1%),
while projected identifier bytes fell from 53,248 to 24,768 (-53.5%). The
compact-ID raw samples are retained in
`compiler_c_symbol_projection_profile_compact_ids_2026-08-23.tsv`.

The paired production-route fixture produced a smaller but correctly bounded
whole-compile result over five alternating samples:

| Metric | Hash baseline | Compact IDs | Change |
| --- | ---: | ---: | ---: |
| Compile to C median | 0.999800 s | 0.996931 s | -0.3% |
| Generated C | 15,586 bytes | 14,921 bytes | -4.3% |
| Projected callable identifiers | 390 bytes | 180 bytes | -53.8% |
| `-O0` object | 10,512 bytes | 10,304 bytes | -2.0% |
| `-O2` object | 5,920 bytes | 5,904 bytes | -0.3% |

The fixture checksum remained 243 for both compilers. This confirms the large
thin-phase speedup without claiming a stable whole-compiler latency change on
a small production artifact.

## Candidate-Heavy Attribution

Five process samples of ten iterations over one artifact containing 256
functions with 96-byte source names and one direct call per function produced
these medians:

| Function | Inclusive time | Calls | Share of projection |
| --- | ---: | ---: | ---: |
| `project_core_program_callables` | 45.127 ms | 10 | 100.0% |
| `build_callable_symbol_plan` | 34.137 ms | 10 | 75.6% |
| `fnv1a_update` | 26.095 ms | 2,570 | 57.8% |
| `project_expr` | 8.135 ms | 5,120 | 18.0% |
| `validate_program_projection` | 3.522 ms | 10 | 7.8% |
| `encode_callable_hash` | 2.120 ms | 2,560 | 4.7% |
| `validate_projected_symbol_pairs` | 1.509 ms | 10 | 3.3% |
| `program_symbol_inventory` | 0.297 ms | 10 | 0.7% |

Inclusive rows overlap and must not be summed. Hashing is the largest cost for
this shallow, candidate-heavy workload. Inspection of generated C explains
why: `fnv1a_update` calls `blorp_bytes_from_string`, installs ARC cleanup,
performs a bounds-checked byte read returning `Option`, converts integer widths,
and executes a cooperative checkpoint for every byte. The FNV xor and multiply
are not themselves problematic.

The implementation does avoid obvious repeated hash work: the schema seed is
computed once per plan and each candidate name is hashed once. The inefficiency
is in the Blorp-level per-byte implementation, not a quadratic hash algorithm.

## Body Density

Varying direct-call carriers while holding candidate count and name length
constant separates plan cost from body traversal:

| Calls per function | Window | Projection | Symbol plan | Hash | Expression projection | Validation |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 45.659 ms | 45.128 ms | 34.101 ms | 26.116 ms | 8.240 ms | 3.501 ms |
| 4 | 62.654 ms | 61.292 ms | 34.160 ms | 26.133 ms | 25.867 ms | 11.130 ms |
| 16 | 136.596 ms | 131.671 ms | 34.213 ms | 26.145 ms | 97.304 ms | 47.363 ms |

Hash cost stays flat because the callable inventory is unchanged. On dense
bodies, expression projection and the separate validation traversal overtake
hashing. A production-shaped Core replay is therefore required before treating
hashing as the dominant contributor to a whole compiler build.

## Scaling

Ten batched call iterations with 96-byte names and one call per function scale
linearly:

| Callables | Window |
| ---: | ---: |
| 128 | 22.941 ms |
| 256 | 45.840 ms |
| 512 | 92.106 ms |
| 1,024 | 184.707 ms |

One 4,096-callable iteration took 74.089 ms. The projection function accounted
for 74.087 ms, the symbol plan for 55.498 ms, hashing for 41.901 ms, expression
projection for 13.426 ms, and validation for 5.912 ms. There is no evidence of
quadratic behavior in this measured range.

At 256 callables and ten iterations, source-name length controls hash cost:

| Requested source-name length | Window | Hash |
| ---: | ---: | ---: |
| 32 bytes | 27.544 ms | 8.877 ms |
| 96 bytes | 45.993 ms | 26.197 ms |
| 384 bytes | 127.828 ms | 105.156 ms |

This is the expected linear relationship with hashed bytes, amplified by the
avoidable work performed for each byte.

## Batching

Five process samples of 256 functions, ten iterations, 96-byte names, and one
call per function produced these medians:

| Layout | Artifacts | Window | Projection subtree |
| --- | ---: | ---: | ---: |
| Batched | 1 | 45.662 ms | 45.127 ms |
| Fragmented | 256 | 62.752 ms | 61.817 ms |

Production emission invokes projection once on the complete final Core
artifact. It therefore already receives the batched behavior. Batching saves
about 27.2% against artificially projecting 256 one-function artifacts; adding
another module-level batching layer would not help this phase.

## Conclusion

The projection algorithm remains linear and artifact-batched. Encoding the
already-global definition ID removes all source-name-length sensitivity and
eliminates the largest candidate-heavy cost without introducing another
identity table. The required final-Core invariant rejects definition IDs owned
by distinct declarations, the production planner independently validates
callable IDs, and ABI-visible name conflicts are resolved with a deterministic
underscore suffix.

The remaining profile is dominated by expression projection and the separate
validation traversal. Any next optimization should capture and replay a
representative production final-Core artifact before combining those walks;
the paired result shows that even a 64.0% thin-phase improvement moves total
compile-to-C latency only slightly on this fixture.

## Reproduction

```bash
BLORP_COMPILER_BENCHMARK_SKIP_BUILD=1 \
  benchmarks/compiler_c_symbol_projection_profile calls 10 256 96 1

BLORP_COMPILER_BENCHMARK_SKIP_BUILD=1 \
  benchmarks/compiler_c_symbol_projection_profile calls 10 256 96 16

BLORP_COMPILER_BENCHMARK_SKIP_BUILD=1 \
  benchmarks/compiler_c_symbol_projection_profile fragmented 10 256 96 1

BLORP_COMPILER_BENCHMARK_SKIP_BUILD=1 \
  benchmarks/compiler_c_symbol_projection_profile calls 1 4096 96 1
```
