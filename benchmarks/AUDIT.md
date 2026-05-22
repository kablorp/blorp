# Benchmark Audit

Last audited: 2026-05-08.

This file tracks whether each public benchmark compares the same work across
language implementations. A benchmark is apples-to-apples only when variants use
the same input, same core algorithm, same work count, and no external native
library advantage unless that is the explicit subject of the benchmark.

`benchmarks/bench.sh` uses language-specific source wrapping to time the full
benchmark `main` body inside the spawned process. It suppresses speedup notes
for rows marked **Not comparable** or **Blocked**.

| Benchmark | Variants | Status | Audit Notes / Required Fixes |
|-----------|----------|--------|-------------------------------|
| `numeric_loop` | blorp, C, Go, Python | Comparable | Same Collatz loop over `1..999999` and same checksum. Harness wrapper times the full benchmark `main` body. |
| `fib` | blorp, C, Go, Python | Comparable | Same naive recursive `fib(40)` workload. Harness wrapper times the full benchmark `main` body. |
| `string` | blorp, C, Go, Python | Comparable | Same input string, operation labels, iteration counts, and checksum outputs. The row covers count, contains, same/growing/shrinking replace, substring, split, case conversion, reverse, and trim. Materializing operations allocate fresh outputs across variants; Go substring/trim clones are intentional to avoid view-only work. |
| `array_sum` | blorp, C, Go, Python | Comparable | Same fixed-size integer data, explicit summing loop, iteration count, and checksum output. Python no longer uses NumPy, and the iteration count is scaled to keep the pure-language row practical. |
| `array_ops` | blorp, C, Go, Python | Comparable | Same fixed-size integer inputs, add/scale/sum operation sequence, fresh intermediate allocation contract, iteration count, and checksum output. Python no longer uses NumPy; Go now allocates fresh combined/scaled buffers instead of reusing one result buffer. |
| `dict_ops` | blorp, Go, Python | Comparable | Same build, hit lookup, miss lookup, remove, and iteration workloads. No C variant. Harness wrapper times the full benchmark `main` body. |
| `list_ops` | blorp, Go, Python | Comparable | Same append, stable sort, filter, fold, reverse, and concat workloads. Go uses `slices.SortStableFunc`, matching Blorp's stable list sort and Python's stable `sorted`. The sort checksum consumes sorted values, not only the result length. No C variant. |
| `set_ops` | blorp, Go, Python | Comparable | Same build, contains-hit, contains-miss, union, intersection, and difference workloads. Union/intersection/difference now consume constructed result sizes in all variants, and exact output checks match. |
| `options` | blorp | Blorp-only | Representation benchmark for Blorp option layouts; no cross-language claim. |
| `simd` | blorp, C | Comparable | Same operation families, element counts, iteration counts, fresh elementwise-result allocation contract, and checksum outputs. The row now prints deterministic checksums while the harness owns timing. |
| `nbody` | blorp, C, Go, Python | Comparable | Same five-body data, struct-of-arrays layout, offset-momentum step, energy calculation, advance loop, iteration count, and fixed-precision output. Focused output checks match exactly. |
| `binary_trees` | blorp, C, Go, Python | Comparable | Same binary-tree depths, iteration formula, path-derived leaf payloads, and check values. Leaves now carry payloads in all variants, so Blorp no longer uses a nullary-constructor singleton for every leaf; each implementation allocates one tree object per internal node and per leaf at source level. |
| `fannkuch` | blorp, C, Go, Python | Comparable | Same `n` from `bench_args.txt`, checksum, and max-flips result. Implementations use different local permutation mechanics but compute the same canonical result. |
| `spectral_norm` | blorp, C, Go, Python | Comparable | Same matrix formula, power-method iteration count, input size, fresh matrix-vector result allocation contract, and fixed-precision output. Focused output checks match exactly. |
| `mandelbrot` | blorp, C, Go, Python | Comparable | Same grid size, escape threshold, and max-iteration count. The harness discards stdout, but the timed `main` body still generates and writes the ASCII output. |
| `knucleotide` | blorp, Go, Python | Comparable | Same repeated sample DNA, target sequence length, frequency frames, fragment list, and output for a focused `n=100000` check. No C variant. |
| `reverse_complement` | blorp, Go, Python | Comparable | Same fixed three-sequence FASTA input, repeat factor, complement table, line width, headers, total-nucleotide checksum, and output. No C variant. |

## Auxiliary Benchmarks

| Benchmark | Status | Notes |
|-----------|--------|-------|
| `numeric_vector` | Blorp-only | Listed by `bench.sh --list` via `EXTRA_BENCHMARKS` and excluded from the default `all` suite; useful for Blorp numeric/tensor exploration. |
| `paradigms` | Blorp-only | Listed by `bench.sh --list` via `EXTRA_BENCHMARKS` and excluded from the default `all` suite; current focus is intra-Blorp paradigm comparison. |
| `vector_parallel` | Blorp-only | Standalone diagnostic benchmark for scoped `Vector.parallel` pipeline shapes. It emits one parseable row per operation with runtime, allocation counters, live objects, retained bytes, and checksum. It is intentionally excluded from `bench.sh` because it compares intra-Blorp pipeline variants rather than languages. |

## Audit Rules

- If a benchmark is marked **Not comparable** or **Blocked**, `bench.sh` should
  not print language speedup notes for it.
- If a benchmark is marked **Provisional**, speedups are allowed, but conclusions
  must mention the listed caveat.
- New cross-language benchmarks should start in this file before being added to
  `ALL_BENCHMARKS`.
