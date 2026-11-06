# blorp Benchmarks

Performance benchmarks comparing the legacy compiler, Blorp, C, Go, OCaml, and Python.

## Quick Start

```bash
# Build the Blorp compiler first. The legacy column needs no build: it uses a
# pinned legacy release that the first run downloads and verifies.
make -C blorp compiler

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
  legacy/support/benchmark.brp  # shared helper module for the legacy programs
  legacy/<name>.brp     # programs for the pinned legacy compiler
  blorp/<name>.brp      # supported Blorp ports; separate table column
  c/<name>.c
  go/<name>.go
  ocaml/<name>.ml
  python/<name>.py
  args/<name>.txt        # optional shared CLI args
```

`results/` holds markdown summaries only (see [Recording Results](#recording-results)).

The benchmark name is the filename without the extension. A benchmark must have
a legacy source file; Blorp, C, Go, OCaml, and Python counterparts are optional.
Legacy benchmark sources can import harness helpers from `./support/benchmark`.

### The legacy column

The `legacy` column is the legacy compiler, pinned to a published release built
from the last legacy sources (`ee9e001c6de8`). `bench.sh` does not build it. It
downloads the release that `benchmarks/legacy-compiler.env` names (repository,
tag and one SHA-256 per target) into `$XDG_CACHE_HOME/blorp/legacy` (default
`~/.cache/blorp/legacy`), verifies the digest before first use, and compiles
each benchmark from a temporary directory so the release's embedded standard
library is used, never a checkout's. Only a run that builds a benchmark
downloads it; `--list` and `--help` never do. The release provides macOS arm64,
Linux x64 and Linux arm64. The standard `instrumentation` module that the
timing helpers use comes from that release's embedded library.

### The blorp column

The `blorp` column uses `blorp/build/compiler` and the explicit
`blorp/standard_library` root. Set `BLORP_COMPILER` to select another compiler
executable. The column never falls back to the legacy compiler. A missing compiler is
an error when the selected workload has a Blorp port; unsupported rows show
`-`. Listing the workloads needs neither compiler.

The initial ports are `numeric_loop`, `fib`, `binary_trees`, `compiler_ast`,
`list_ops`, `compiler_emit`, and `dict_ops` (over the `dict` module, iterating
`D.values` because a Dict has no `for` loop yet). They preserve the existing
inputs, iteration counts and result checksums. Both Blorp compilers' generated C
uses the same native optimization flags and the same whole-main timing wrapper.
The `blorp/legacy time` note is Blorp elapsed time divided by legacy elapsed
time: a value above 1 means Blorp took longer. The `blorp/legacy
instructions` note, shown with `BENCH_RESOURCE_STATS=1`, is the same ratio for
retired instructions.

The ports exist because Blorp does not yet compile the legacy sources: as of
2026-10-31 each one stops at its first infix arithmetic operator, compound
assignment or tensor dimension. The
[2026-10-31 comparison](results/blorp2-runtime-benchmarks-2026-10-31.md)
lists each first diagnostic and measures the ports against the legacy
compiler.

The tree and AST ports use a managed record containing an inline union, matching
the supported recursive-data idiom. Every logical node, including a leaf, has
one managed record root; there is no additional union box. The logical trees,
construction counts and child evaluation order stay the same, but the storage
representation differs. Their Blorp comparisons are marked provisional.

`list_ops` and `compiler_emit` compare the current libraries as well as code
generation. Blorp List updates copy, its filter/reverse/sort helpers use
temporary immutable algorithms, and the fold port uses an explicit summing loop
instead of `fold_left`. Its String emitter has no capacity reservation and uses
fresh concatenations and temporary integer strings. These comparisons are
provisional; see [the audit](https://github.com/kablorp/blorp/blob/ee9e001c6de8911ee486fd992419bef5bc628e8b/benchmarks/AUDIT.md). They do not isolate compiler quality.

## Default Benchmark Suite

These run when the filter is omitted or set to `all`.

| Benchmark | What it tests | Languages |
|-----------|--------------|-----------|
| `numeric_loop` | Collatz sequence (1M numbers), arithmetic loops | legacy, blorp, C, Go, OCaml, Python |
| `fib` | Recursive fib(40), function call overhead | legacy, blorp, C, Go, OCaml, Python |
| `string` | Checksum-based search, replace, substring, case conversion, split, trim, and reverse | legacy, C, Go, OCaml, Python |
| `array_sum` | Explicit integer vector sum (10k iterations, 1000 elements) | legacy, C, Go, OCaml, Python |
| `array_ops` | Integer vector add + scale + sum (10k iterations) | legacy, C, Go, OCaml, Python |
| `dict_ops` | Hash map build/lookup/remove/iterate | legacy, blorp, Go, OCaml, Python |
| `list_ops` | List append/sort/filter/fold/reverse/concat | legacy, blorp, Go, OCaml, Python |
| `set_ops` | Hash set build/contains/union/intersect/diff | legacy, Go, OCaml, Python |
| `threaded_cpu_map` | Fixed-width CPU-bound worker partitioning | legacy, C, Go, OCaml, Python |
| `channel_pipeline` | Producer/worker/consumer channel pipeline; Blorp currently uses structured concurrent list processing | legacy, C, Go, OCaml, Python |
| `sleep_fanout` | Many sleeping tasks/threads spawned and joined together | legacy, C, Go, OCaml, Python |
| `options` | `Option` representation and layout costs | legacy |
| `simd` | 16-element numeric tensor add, multiply, sum, and dot kernels | legacy, C |
| `nbody` | Struct-of-arrays N-body planetary simulation; Blorp currently uses list-backed storage | legacy, C, Go, OCaml, Python |
| `binary_trees` | Allocation-heavy binary tree construction/checking | legacy, blorp, C, Go, OCaml, Python |
| `fannkuch` | Permutation-heavy integer workload | legacy, C, Go, OCaml, Python |
| `spectral_norm` | Floating-point matrix/vector kernel with fresh intermediates | legacy, C, Go, OCaml, Python |
| `mandelbrot` | Complex-number style nested numeric loops | legacy, C, Go, OCaml, Python |
| `knucleotide` | String slicing and frequency maps | legacy, Go, OCaml, Python |
| `reverse_complement` | Shared FASTA reverse-complement transforms | legacy, Go, OCaml, Python |
| `compiler_ast` | Recursive AST construction, immutable tree rewrites, and pattern matching | legacy, blorp, Go, OCaml |
| `compiler_symbols` | Persistent symbol tables, nested scope walks, and repeated lookups | legacy, Go, OCaml |
| `compiler_emit` | C-like code emission and generated-text checksumming | legacy, blorp, Go, OCaml |

## Extra Benchmarks

These are listed by `bench.sh --list` and can be run directly, but they are not
included in `bench.sh all`.

| Benchmark | What it tests | Languages |
|-----------|--------------|-----------|
| `paradigms` | Functional dispatch, list destructuring, pattern matching, and coroutine-style control flow | legacy |
| `virtual_threads` | Fiber spawn, join, park, and wake scaling | legacy |
| `control_flow_accumulators` | List accumulators updated in join arms (`in_arms`), across inner-loop entry (`nested`) and in a flat loop (`flat`), with a `none` startup control; arguments are the mode and the append count | legacy, blorp |
| `helper_accumulators` | Accumulators threaded through a helper parameter: List append (`list_helper`), String append (`string_helper`) and List `set` on a fixed table (`set_helper`), with a `none` startup control; arguments are the mode and the update count | legacy, blorp |

## Timing Model

`bench.sh` first compiles all compiled-language binaries for the selected
benchmark set into a temporary directory. Timed execution remains
benchmark-major, so the comparison table still runs `fib` across
legacy/blorp/C/Go/OCaml/Python before moving to the next benchmark.
Blorp-generated C and the C comparison programs are compiled and linked at
`-O2`; this is a benchmark setting, not a substitute for output validation.

The harness does not time benchmarks from the outside. It runs a
language-specific instrumented entry point, and that entry point prints a
machine-readable line to stderr:

```text
BENCH name=fib lang=legacy seconds=0.123456789
```

The harness parses those `BENCH` lines. By default each benchmark runs once;
when `BENCH_RUNS` is greater than 1, the harness reports the best timed run.
This excludes shell overhead, process launch time, and dynamic-loader startup
from the measured result.

For `fib`, `numeric_loop`, `array_sum`, `array_ops`, `dict_ops`, `list_ops`, and
`set_ops`, `compiler_ast`, and `compiler_emit`, the sample runner checks exact stdout on every warmup and timed run
before accepting its `BENCH` marker. Their expected outputs are recorded in
`benchmarks/bench_run.py`. `binary_trees` also checks every result, allowing only
the existing spaces-versus-tabs formatting difference. Its contract uses the
shared depth-15 argument. Other rows do not yet have an output contract in the
sample runner.

`BENCH_ALLOC_STATS=1` builds separate diagnostic binaries for legacy and Blorp.
Timed samples always use normal binaries with memory diagnostics disabled.
Allocation runs use each runtime's leak-check mode and fail the benchmark on
diagnostic errors. The counts are labeled separately: legacy managed-object
counts and Blorp allocator-call counts have different accounting boundaries.
The reported `bytes` field is live bytes at exit, not total bytes allocated.

`BENCH_RESOURCE_STATS=1` runs every timed sample under macOS `/usr/bin/time -l`
and appends each language's minimum retired instructions and maximum peak
resident set size to the row, with a `blorp/legacy instructions` ratio when both
Blorp lanes ran. These counters cover the whole process, including startup, so
a millisecond workload is dominated by process launch. Warmups run without the
timer. Other platforms' `time` commands do not report retired instructions, so
`bench.sh` refuses to start there rather than omit them.

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
OCAMLOPT=ocamlopt               bash benchmarks/bench.sh   # Use specific OCaml native compiler
CC=gcc                          bash benchmarks/bench.sh   # Use specific C compiler
BLORP_COMPILER=/path/compiler   bash benchmarks/bench.sh fib # Select the Blorp compiler
XDG_CACHE_HOME=/path/cache      bash benchmarks/bench.sh   # Where the pinned legacy compiler is cached
BENCH_THREADS=4                 bash benchmarks/bench.sh   # Worker/task width for concurrency rows
BLORP_THREADS=4                 bash benchmarks/bench.sh   # Blorp runtime thread width for concurrency rows
GOMAXPROCS=4                    bash benchmarks/bench.sh   # Go runtime parallelism for concurrency rows
BENCH_RUNS=5                    bash benchmarks/bench.sh   # Timed runs per language (default: 1)
BENCH_WARMUPS=1                 bash benchmarks/bench.sh   # Untimed warmup runs (default: 0)
BENCH_ALLOC_STATS=1             bash benchmarks/bench.sh   # Separate allocation runs for both Blorp runtimes
BENCH_RESOURCE_STATS=1          bash benchmarks/bench.sh   # Retired instructions and peak RSS (macOS)
BENCH_VERBOSE=1                 bash benchmarks/bench.sh   # Print build logs on failures
```

Python variants of concurrency benchmarks intentionally use `PYTHON_CONCURRENCY`
instead of `PYTHON`. That interpreter must be Python 3.14 or newer, built with
free threading enabled, and the harness runs it with `-X gil=0` before checking
that the GIL is disabled.

## Adding a New Benchmark

1. Add `benchmarks/legacy/<name>.brp`.
2. Optionally add `benchmarks/blorp/<name>.brp`, `benchmarks/c/<name>.c`, `benchmarks/go/<name>.go`,
   `benchmarks/ocaml/<name>.ml`, and `benchmarks/python/<name>.py`.
3. If every language should receive the same CLI args, add
   `benchmarks/args/<name>.txt`.
4. Import `./support/benchmark` from legacy benchmark sources when you need the
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

## Recording Results

A measurement lands as one markdown file, `benchmarks/results/<topic>_<date>.md`,
that stands on its own: host, source and binary revisions, flags, input hash,
commands, run order, sample count, headline numbers with spread, output
identity and caveats. Raw samples, logs, manifests, copied C and per-run
directories stay under the ignored `build/` directory; `.gitignore` admits only
markdown into `benchmarks/results/`. Link each report from the plan, README,
cost ceiling or source comment it supports, and delete the report when that
decision is superseded.
