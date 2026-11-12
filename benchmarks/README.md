# blorp Benchmarks

Performance benchmarks comparing Blorp with C, Go, OCaml, and Python.

## Quick Start

```bash
# Build the Blorp compiler first.
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
  blorp/<name>.brp      # the benchmark programs; one table column
  c/<name>.c            # comparison programs, optional per benchmark
  go/<name>.go
  ocaml/<name>.ml
  python/<name>.py
  args/<name>.txt        # optional shared CLI args
```

`results/` holds markdown summaries only (see [Recording Results](#recording-results)).

The benchmark name is the filename without the extension. A benchmark must have
a Blorp source file; C, Go, OCaml, and Python counterparts are optional. A
program without a Blorp source compares nothing to Blorp and does not belong here.

### The blorp column

The `blorp` column uses `blorp/build/blorp` and the explicit
`blorp/standard_library` root. A recipe that compiles `blorp/src/main.brp` with
another compiler must first run `make -C blorp build/generated/embedded_library.brp`
(`make -C blorp compiler` does), because the compiler's source imports that
generated module. Set `BLORP_COMPILER` to select another compiler
executable. A missing compiler is an error for any run that builds a benchmark;
languages without a counterpart show `-`. Listing the workloads needs no
compiler.

The ports are `numeric_loop`, `fib`, `binary_trees`, `compiler_ast`,
`list_ops`, `compiler_emit`, and `dict_ops` (over the `dict` module, iterating
`D.values` because a Dict has no `for` loop yet). They share inputs, iteration
counts and result checksums with the C, Go, OCaml and Python counterparts. The
two accumulator probes under Extra Benchmarks are Blorp-only: they compare no
other language. The `vs C`, `vs Go`,
`vs OCaml` and `vs Py` notes are that language's elapsed time divided by Blorp's,
so a value above 1.0x means Blorp was faster.

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
provisional. They do not isolate compiler quality.

## Default Benchmark Suite

These run when the filter is omitted or set to `all`.

| Benchmark | What it tests | Languages |
|-----------|--------------|-----------|
| `numeric_loop` | Collatz sequence (1M numbers), arithmetic loops | blorp, C, Go, OCaml, Python |
| `fib` | Recursive fib(40), function call overhead | blorp, C, Go, OCaml, Python |
| `dict_ops` | Hash map build/lookup/remove/iterate | blorp, Go, OCaml, Python |
| `list_ops` | List append/sort/filter/fold/reverse/concat | blorp, Go, OCaml, Python |
| `binary_trees` | Allocation-heavy binary tree construction/checking | blorp, C, Go, OCaml, Python |
| `compiler_ast` | Recursive AST construction, immutable tree rewrites, and pattern matching | blorp, Go, OCaml |
| `compiler_emit` | C-like code emission and generated-text checksumming | blorp, Go, OCaml |

## Extra Benchmarks

These are listed by `bench.sh --list` and can be run directly, but they are not
included in `bench.sh all`.

| Benchmark | What it tests | Languages |
|-----------|--------------|-----------|
| `control_flow_accumulators` | List accumulators updated in join arms (`in_arms`), across inner-loop entry (`nested`) and in a flat loop (`flat`), with a `none` startup control; arguments are the mode and the append count | blorp |
| `helper_accumulators` | Accumulators threaded through a helper parameter: List append (`list_helper`), String append (`string_helper`) and List `set` on a fixed table (`set_helper`), with a `none` startup control; arguments are the mode and the update count | blorp |

## Timing Model

`bench.sh` first compiles all compiled-language binaries for the selected
benchmark set into a temporary directory. Timed execution remains
benchmark-major, so the comparison table still runs `fib` across
blorp/C/Go/OCaml/Python before moving to the next benchmark.
Blorp-generated C and the C comparison programs are compiled and linked at
`-O2`; this is a benchmark setting, not a substitute for output validation.

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

For `fib`, `numeric_loop`, `dict_ops`, `list_ops`, `compiler_ast`, and
`compiler_emit`, the sample runner checks exact stdout on every warmup and timed run
before accepting its `BENCH` marker. Their expected outputs are recorded in
`benchmarks/bench_run.py`. `binary_trees` also checks every result, allowing only
the existing spaces-versus-tabs formatting difference. Its contract uses the
shared depth-15 argument. Other rows do not yet have an output contract in the
sample runner.

`BENCH_ALLOC_STATS=1` builds a separate diagnostic binary for Blorp.
Timed samples always use normal binaries with memory diagnostics disabled.
Allocation runs use the runtime's strict leak-check mode and fail the benchmark
on diagnostic errors. The counts are Blorp allocator calls. The reported `bytes` field is live bytes at exit, not total bytes allocated.

`BENCH_RESOURCE_STATS=1` runs every timed sample under macOS `/usr/bin/time -l`
and appends each language's minimum retired instructions and maximum peak
resident set size to the row. These counters cover the whole process, including startup, so
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
GO=go1.22                       bash benchmarks/bench.sh   # Use specific Go
OCAMLOPT=ocamlopt               bash benchmarks/bench.sh   # Use specific OCaml native compiler
CC=gcc                          bash benchmarks/bench.sh   # Use specific C compiler
BLORP_COMPILER=/path/compiler   bash benchmarks/bench.sh fib # Select the Blorp compiler
BENCH_RUNS=5                    bash benchmarks/bench.sh   # Timed runs per language (default: 1)
BENCH_WARMUPS=1                 bash benchmarks/bench.sh   # Untimed warmup runs (default: 0)
BENCH_ALLOC_STATS=1             bash benchmarks/bench.sh   # Separate allocation runs for Blorp
BENCH_RESOURCE_STATS=1          bash benchmarks/bench.sh   # Retired instructions and peak RSS (macOS)
BENCH_VERBOSE=1                 bash benchmarks/bench.sh   # Print build logs on failures
```

## Adding a New Benchmark

1. Add `benchmarks/blorp/<name>.brp`.
2. Optionally add `benchmarks/c/<name>.c`, `benchmarks/go/<name>.go`,
   `benchmarks/ocaml/<name>.ml`, and `benchmarks/python/<name>.py`.
3. If every language should receive the same CLI args, add
   `benchmarks/args/<name>.txt`.
4. Add `<name>` to `ALL_BENCHMARKS` in `benchmarks/bench.sh`, or to
   `EXTRA_BENCHMARKS` if it should be runnable and listed but excluded from
   the default `all` suite.
5. Run `BENCH_RUNS=1 BENCH_WARMUPS=0 bash benchmarks/bench.sh <name>` to verify
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
