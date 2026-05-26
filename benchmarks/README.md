# blorp Benchmarks

Performance benchmarks comparing blorp against C, Go, and Python.

## Quick Start

```bash
# Build ./blorp first
make

# Run the default benchmark suite
bash benchmarks/bench.sh

# Run a single benchmark
bash benchmarks/bench.sh fib

# List available benchmarks
bash benchmarks/bench.sh --list
```

## Layout

Benchmarks are organized by language so each language can have its own timing
and build setup:

```text
benchmarks/
  blorp/support/benchmark.brp  # shared helper module for Blorp benchmarks
  blorp/<name>.brp
  c/<name>.c
  go/<name>.go
  python/<name>.py
  args/<name>.txt        # optional shared CLI args
```

The benchmark name is the filename without the extension. A benchmark must have
a blorp source file; C, Go, and Python counterparts are optional.
Blorp benchmark sources can import harness helpers from `./support/benchmark`.
Reusable low-level timing and optimizer-barrier primitives live in the standard
`instrumentation` module.

## Default Benchmark Suite

These run when the filter is omitted or set to `all`.

| Benchmark | What it tests | Languages |
|-----------|--------------|-----------|
| `numeric_loop` | Collatz sequence (1M numbers), arithmetic loops | blorp, C, Go, Python |
| `fib` | Recursive fib(40), function call overhead | blorp, C, Go, Python |
| `string` | Checksum-based search, replace, substring, case conversion, split, trim, and reverse | blorp, C, Go, Python |
| `array_sum` | Explicit integer vector sum (10k iterations, 1000 elements) | blorp, C, Go, Python |
| `array_ops` | Integer vector add + scale + sum (10k iterations) | blorp, C, Go, Python |
| `dict_ops` | Hash map build/lookup/remove/iterate | blorp, Go, Python |
| `list_ops` | List append/sort/filter/fold/reverse/concat | blorp, Go, Python |
| `set_ops` | Hash set build/contains/union/intersect/diff | blorp, Go, Python |
| `threaded_cpu_map` | Fixed-width CPU-bound worker partitioning | blorp, C, Go, Python |
| `channel_pipeline` | Bounded producer/worker/consumer channel pipeline | blorp, C, Go, Python |
| `sleep_fanout` | Many sleeping tasks/threads spawned and joined together | blorp, C, Go, Python |
| `options` | `Option` representation and layout costs | blorp |
| `simd` | SIMD vector operations with checksum output | blorp, C |
| `nbody` | Struct-of-arrays N-body planetary simulation | blorp, C, Go, Python |
| `binary_trees` | Allocation-heavy binary tree construction/checking | blorp, C, Go, Python |
| `fannkuch` | Permutation-heavy integer workload | blorp, C, Go, Python |
| `spectral_norm` | Floating-point matrix/vector kernel with fresh intermediates | blorp, C, Go, Python |
| `mandelbrot` | Complex-number style nested numeric loops | blorp, C, Go, Python |
| `knucleotide` | String slicing and frequency maps | blorp, Go, Python |
| `reverse_complement` | Shared FASTA reverse-complement transforms | blorp, Go, Python |

## Extra Benchmarks

These are listed by `bench.sh --list` and can be run directly, but they are not
included in `bench.sh all`.

| Benchmark | What it tests | Languages |
|-----------|--------------|-----------|
| `numeric_vector` | Numeric tensor/vector operations and subscript variants | blorp |
| `paradigms` | Functional dispatch, list destructuring, pattern matching, and coroutine-style control flow | blorp |
| `particle_gravity` | Particle-sim-derived parallel indexed gravity kernel | blorp |
| `virtual_threads` | Fiber spawn, join, park, and wake scaling | blorp |

## Standalone Diagnostic Benchmarks

`benchmarks/blorp/list_parallel.brp` isolates `List.parallel` behavior. It does
not use `bench.sh` because it emits one parseable row per operation, size,
thread setting, and selectivity case:

```bash
BLORP_THREADS=4 ./blorp run --no-format benchmarks/blorp/list_parallel.brp -- smoke
BLORP_THREADS=4 ./blorp run --no-format benchmarks/blorp/list_parallel.brp -- full
```

Leave `BLORP_THREADS` unset to measure the runtime default. The `smoke` mode
uses small sizes for harness checks; `full` includes 120k and 1M element cases.

`benchmarks/blorp/vector_parallel.brp` isolates scoped `Vector.parallel`
pipelines. It covers single `map`, `map.map`, `map_indexed.map`,
`zip_map.map`, repeated use of a captured same-shape vector, and managed-result
elements. Each `BENCH` row includes elapsed time, allocation counters, live
objects, bytes still allocated, and a checksum:

```bash
BLORP_THREADS=4 ./blorp run --no-format benchmarks/blorp/vector_parallel.brp -- smoke
BLORP_THREADS=4 ./blorp run --no-format benchmarks/blorp/vector_parallel.brp -- full
```

## Timing Model

`bench.sh` first compiles all compiled-language binaries for the selected
benchmark set into a temporary directory. Timed execution remains
benchmark-major, so the comparison table still runs `fib` across blorp/C/Go/Python
before moving to the next benchmark.

The harness does not time benchmarks from the outside. It runs a
language-specific instrumented entry point, and that entry point prints a
machine-readable line to stderr:

```text
BENCH name=fib lang=blorp seconds=0.123456789
```

The harness parses those `BENCH` lines. By default each benchmark runs once;
when `BENCH_RUNS` is greater than 1, the harness reports the best timed run.
This excludes shell overhead, process launch time, and dynamic-loader startup
from the measured result.

The current runners instrument the full benchmark `main` body. That means
benchmark-specific setup and output are included unless the source factors them
out before entering `main`. If a benchmark needs narrower hot-section timing,
prefer moving setup outside the measured function inside that language's source
or runner rather than reintroducing shell timing.

## Environment Variables

```bash
PYTHON=python3.11               bash benchmarks/bench.sh   # Use specific Python
PYTHON_CONCURRENCY=python3.14t  bash benchmarks/bench.sh   # Free-threaded Python for concurrency rows
GO=go1.22                       bash benchmarks/bench.sh   # Use specific Go
CC=gcc                          bash benchmarks/bench.sh   # Use specific C compiler
BENCH_THREADS=4                 bash benchmarks/bench.sh   # Worker/task width for concurrency rows
BLORP_THREADS=4                 bash benchmarks/bench.sh   # Blorp runtime thread width for concurrency rows
GOMAXPROCS=4                    bash benchmarks/bench.sh   # Go runtime parallelism for concurrency rows
BENCH_RUNS=5                    bash benchmarks/bench.sh   # Timed runs per language (default: 1)
BENCH_WARMUPS=1                 bash benchmarks/bench.sh   # Untimed warmup runs (default: 0)
BENCH_VERBOSE=1                 bash benchmarks/bench.sh   # Print build logs on failures
```

Python variants of concurrency benchmarks intentionally use `PYTHON_CONCURRENCY`
instead of `PYTHON`. That interpreter must be Python 3.14 or newer, built with
free threading enabled, and the harness runs it with `-X gil=0` before checking
that the GIL is disabled.

## Adding a New Benchmark

1. Add `benchmarks/blorp/<name>.brp`.
2. Optionally add `benchmarks/c/<name>.c`, `benchmarks/go/<name>.go`, and
   `benchmarks/python/<name>.py`.
3. If every language should receive the same CLI args, add
   `benchmarks/args/<name>.txt`.
4. Import `./support/benchmark` from Blorp benchmark sources when you need the
   shared timing/checksum helpers.
5. Add `<name>` to `ALL_BENCHMARKS` in `benchmarks/bench.sh`, or to
   `EXTRA_BENCHMARKS` if it should be runnable and listed but excluded from
   the default `all` suite.
6. Add concurrency benchmarks to `CONCURRENCY_BENCHMARKS` when their Python
   implementation requires the free-threaded interpreter path.
7. Run `BENCH_RUNS=1 BENCH_WARMUPS=0 bash benchmarks/bench.sh <name>` to verify
   the source builds and reports a `BENCH` line.

## Performance Notes

blorp compiles to C with ARC memory management. Common overhead sources are:

1. **Reference counting** — heap objects carry ARC bookkeeping.
2. **Bounds checking** — collection accesses are bounds-checked unless proven.
3. **Copy-on-write** — mutation operations check uniqueness at runtime.
4. **String construction** — immutable string operations need fusion, COW, or
   builder-like paths to avoid repeated copying.
