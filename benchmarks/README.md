# blorp Benchmarks

Performance benchmarks comparing blorp, Blorp 2, C, Go, OCaml, and Python.

## Quick Start

```bash
# Build both compilers first
make
make -C blorp_2 compiler

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
  blorp_2/<name>.brp      # supported Blorp 2 ports; separate table column
  c/<name>.c
  go/<name>.go
  ocaml/<name>.ml
  python/<name>.py
  args/<name>.txt        # optional shared CLI args
```

Compiler measurement tools live beside these suites: `self_compile_measure`,
`build_stage2_compiler`, `c_emission_bytes`, `normalize_generated_c_symbols`,
and the record-update allocation guards with the `blorp/profiles/` programs
they drive. `results/` holds markdown summaries only
(see [Recording Results](#recording-results)).

The benchmark name is the filename without the extension. A benchmark must have
a blorp source file; C, Go, OCaml, and Python counterparts are optional.
Blorp benchmark sources can import harness helpers from `./support/benchmark`.
Reusable low-level timing and optimizer-barrier primitives live in the standard
`instrumentation` module.

### Blorp 2

The `blorp2` column uses `blorp_2/build/compiler` and the explicit
`blorp_2/standard_library` root. Set `BLORP2_COMPILER` to select another compiler
executable. There is no fallback to the legacy compiler. A missing compiler is
an error when the selected workload has a Blorp 2 port; unsupported rows show
`-`. Listing the workloads needs neither compiler.

The initial ports are `numeric_loop`, `fib`, `binary_trees`, `compiler_ast`,
`list_ops`, and `compiler_emit`. They preserve the existing inputs, iteration
counts and result checksums. Both Blorp compilers' generated C uses the same
native optimization flags and the same whole-main timing wrapper.
The `blorp2/blorp time` note is Blorp 2 elapsed time divided by legacy elapsed
time: a value above 1 means Blorp 2 took longer.

The tree and AST ports use a managed record containing an inline union, matching
the supported recursive-data idiom. Every logical node, including a leaf, has
one managed record root; there is no additional union box. The logical trees,
construction counts and child evaluation order stay the same, but the storage
representation differs. Their Blorp 2 comparisons are marked provisional.

`list_ops` and `compiler_emit` compare the current libraries as well as code
generation. Blorp 2 List updates copy, its filter/reverse/sort helpers use
temporary immutable algorithms, and the fold port uses an explicit summing loop
instead of `fold_left`. Its String emitter has no capacity reservation and uses
fresh concatenations and temporary integer strings. These comparisons are
provisional; see [the audit](AUDIT.md). They do not isolate compiler quality.

## Default Benchmark Suite

These run when the filter is omitted or set to `all`.

| Benchmark | What it tests | Languages |
|-----------|--------------|-----------|
| `numeric_loop` | Collatz sequence (1M numbers), arithmetic loops | blorp, Blorp 2, C, Go, OCaml, Python |
| `fib` | Recursive fib(40), function call overhead | blorp, Blorp 2, C, Go, OCaml, Python |
| `string` | Checksum-based search, replace, substring, case conversion, split, trim, and reverse | blorp, C, Go, OCaml, Python |
| `array_sum` | Explicit integer vector sum (10k iterations, 1000 elements) | blorp, C, Go, OCaml, Python |
| `array_ops` | Integer vector add + scale + sum (10k iterations) | blorp, C, Go, OCaml, Python |
| `dict_ops` | Hash map build/lookup/remove/iterate | blorp, Go, OCaml, Python |
| `list_ops` | List append/sort/filter/fold/reverse/concat | blorp, Blorp 2, Go, OCaml, Python |
| `set_ops` | Hash set build/contains/union/intersect/diff | blorp, Go, OCaml, Python |
| `threaded_cpu_map` | Fixed-width CPU-bound worker partitioning | blorp, C, Go, OCaml, Python |
| `channel_pipeline` | Producer/worker/consumer channel pipeline; Blorp currently uses structured concurrent list processing | blorp, C, Go, OCaml, Python |
| `sleep_fanout` | Many sleeping tasks/threads spawned and joined together | blorp, C, Go, OCaml, Python |
| `options` | `Option` representation and layout costs | blorp |
| `simd` | 16-element numeric tensor add, multiply, sum, and dot kernels | blorp, C |
| `nbody` | Struct-of-arrays N-body planetary simulation; Blorp currently uses list-backed storage | blorp, C, Go, OCaml, Python |
| `binary_trees` | Allocation-heavy binary tree construction/checking | blorp, Blorp 2, C, Go, OCaml, Python |
| `fannkuch` | Permutation-heavy integer workload | blorp, C, Go, OCaml, Python |
| `spectral_norm` | Floating-point matrix/vector kernel with fresh intermediates | blorp, C, Go, OCaml, Python |
| `mandelbrot` | Complex-number style nested numeric loops | blorp, C, Go, OCaml, Python |
| `knucleotide` | String slicing and frequency maps | blorp, Go, OCaml, Python |
| `reverse_complement` | Shared FASTA reverse-complement transforms | blorp, Go, OCaml, Python |
| `compiler_ast` | Recursive AST construction, immutable tree rewrites, and pattern matching | blorp, Blorp 2, Go, OCaml |
| `compiler_symbols` | Persistent symbol tables, nested scope walks, and repeated lookups | blorp, Go, OCaml |
| `compiler_emit` | C-like code emission and generated-text checksumming | blorp, Blorp 2, Go, OCaml |

## Extra Benchmarks

These are listed by `bench.sh --list` and can be run directly, but they are not
included in `bench.sh all`.

| Benchmark | What it tests | Languages |
|-----------|--------------|-----------|
| `paradigms` | Functional dispatch, list destructuring, pattern matching, and coroutine-style control flow | blorp |
| `virtual_threads` | Fiber spawn, join, park, and wake scaling | blorp |
| `control_flow_accumulators` | List accumulators updated in join arms (`in_arms`), across inner-loop entry (`nested`) and in a flat loop (`flat`), with a `none` startup control; arguments are the mode and the append count | blorp, Blorp 2 |
| `helper_accumulators` | Accumulators threaded through a helper parameter: List append (`list_helper`), String append (`string_helper`) and List `set` on a fixed table (`set_helper`), with a `none` startup control; arguments are the mode and the update count | blorp, Blorp 2 |

## Compiler Diagnostics

These opt-in compiler tools compile bounded fixtures through the production
compiler. They are not runtime language comparisons and are deliberately
excluded from `bench.sh all`.

### Record Update Allocations

`compiler_record_update_match_allocations` runs a bounded loop of alternating
self-updates selected by an exhaustive Boolean `match` through the production
compiler and asserts the runtime allocation counters. Reuse is valid only when
every returning literal branch transfers the same mutable owner:

```bash
benchmarks/compiler_record_update_match_allocations
BLORP_RECORD_UPDATE_SKIP_BUILD=1 \
  benchmarks/compiler_record_update_match_allocations
```

`compiler_record_update_nested_match_allocations` exercises the projected
decision tree for nested constructor and literal patterns. Every nested leaf
must transfer the same mutable owner before the compiler can reuse it. The
record includes static `String` literal fields so the probe also checks that
field aliases do not force fresh record allocations or dynamic string storage.

```bash
benchmarks/compiler_record_update_nested_match_allocations
BLORP_RECORD_UPDATE_SKIP_BUILD=1 \
  benchmarks/compiler_record_update_nested_match_allocations
```

The normal invocation asserts the optimized one-allocation baseline. Override
`BLORP_RECORD_UPDATE_EXPECT_ALLOCATIONS` to lock in a new expected count. Set
`BLORP_RECORD_UPDATE_MEASURE_ONLY=1` while intentionally measuring an
optimization that is expected to change the count. Both probes always assert
their release and live-object baselines; use
`BLORP_RECORD_UPDATE_EXPECT_RELEASES` and
`BLORP_RECORD_UPDATE_EXPECT_CURRENT_OBJECTS` only when intentionally changing
those lifecycle counts.

## Self-Compile Measurement Protocol

`benchmarks/self_compile_measure` is the one standard measurement for
compiler-performance work. Every worker, baseline, and acceptance decision
uses it so numbers are comparable across branches, worktrees, and people.

It compiles a **frozen input snapshot** (the compiler's own `blorp/src` and
`standard_library/src` at one recorded revision) with paired compiler
executables. The diagnostic binary supplies allocation checkpoints; the
normal binary supplies instructions, time, and RSS. Their generated C must
match byte for byte. The harness reports:

- allocations per compiler phase, from the runtime's memory checkpoints
  (deterministic; the primary signal while iterating);
- retired instructions per run, from `/usr/bin/time -l` (stable to about
  0.1% on Apple Silicon; the primary acceptance signal);
- per-phase wall time, total wall time, and peak RSS (secondary; host noise);
- the SHA-256 of the generated C (semantics-preserving source refactors must
  produce **identical** C).

```bash
# One-time per checkout: build at the acceptance optimization level.
export BLORP_CLI_C_OPTIMIZATION=-O2
make
scripts/compiler-build-status

# On the untouched parent, record one input revision for both checkouts.
frozen_input_rev=$(git rev-parse HEAD)
# Establish both paired baselines on the untouched parent.
benchmarks/self_compile_measure --stage2 \
  --label baseline --input-rev "$frozen_input_rev" \
  --output /tmp/paired-baseline.json
shasum -a 256 benchmarks/self_compile/small.brp \
  > /tmp/paired-small-baseline.sha256
benchmarks/self_compile_measure --stage2 --program small \
  --label baseline-small --input-rev "$frozen_input_rev" \
  --output /tmp/paired-small-baseline.json

# In the candidate checkout, rebuild at -O2 and confirm FRESH before comparing.
export BLORP_CLI_C_OPTIMIZATION=-O2
make
scripts/compiler-build-status
benchmarks/self_compile_measure --stage2 \
  --label candidate --input-rev "$frozen_input_rev" \
  --baseline /tmp/paired-baseline.json \
  --output /tmp/candidate.json --require-identical
# Small-program guard (must not regress materially).
shasum -a 256 -c /tmp/paired-small-baseline.sha256 && \
  benchmarks/self_compile_measure --stage2 --program small \
  --label candidate-small --input-rev "$frozen_input_rev" \
  --baseline /tmp/paired-small-baseline.json \
  --output /tmp/candidate-small.json --require-identical

# Run a multi-process gate.
scripts/compiler-check --changed
```

Rules:

1. The `--input-rev` must equal the baseline's `input_rev`. The harness
   freezes that revision under `$TMPDIR/blorp-perf-input/<sha>` once and
   reuses it; workers never compile their own changed sources as the input.
2. The compiler under test must be `FRESH` per `scripts/compiler-build-status`;
   the harness refuses a stale executable.
3. Compare like with like: a `-O0` build (the `make` default) against the
   `-O0` baseline while iterating; the coordinator's acceptance run uses the
   `-O2` build against the `-O2` baseline. For an `-O2` build export
   `BLORP_CLI_C_OPTIMIZATION=-O2` for `make`, `scripts/compiler-build-status`,
   and the harness alike, since the build identity includes that level. The
   JSON records the level as `c_optimization`. Report which one you used.
4. Measurements are single-process and their primary metrics tolerate
   concurrency; run commands directly. Do not spawn many compiled test
   binaries in parallel yourself (`scripts/compiler-check`, `scripts/test`
   can overwhelm macOS `syspolicyd`). Measurement noise from concurrent work
   is accepted; use the harness's min-of-runs, never wall time, as evidence.
5. Report the comparison table verbatim: allocations per phase, total
   allocations, minimum retired instructions, and the IDENTICAL/DIFFERENT
   output line. Wall time and per-phase `phases_ms` are host-clock noise, not
   acceptance evidence; the table omits them by default (they are still
   recorded in the JSON) and only prints them with `--show-wall`.
6. Every measurement records a toolchain fingerprint (`cc_version`, the full
   `<compiler> --version` output, and the `compiled_by` / `optimization` /
   `commit` fields parsed from it). `compare()` prints a `toolchain mismatch:`
   line for each of `cc_version`, `compiled_by`, or `optimization` that
   differs and exits nonzero unless `--allow-toolchain-mismatch` is passed —
   an Xcode clang update or a bootstrap-pin change moves instruction counts on
   byte-identical C, so a baseline and candidate built with different
   toolchains are not comparable by default. A `commit` difference alone is
   expected and informational only. If the compiler under test is
   bootstrap-built (`compiled_by` starts with `dev-`) and the worktree
   touches `blorp/src/compiler/stage_10_backend/` or
   `blorp/src/lib/runtime/native/`, the harness also prints a loud warning
   that the measurement cannot observe those changes and points at
   `benchmarks/build_stage2_compiler` (see the stage-2 rule below).
7. `--input-rev` freezes the self-compile source, but `--program small` reads
   `benchmarks/self_compile/small.brp` from each checkout. Before comparing
   small-program results, require that file to have the same SHA-256 in the
   baseline and candidate checkouts, as verified in the example above. A
   changed small program is a different workload even if `--input-rev` matches.

Baseline JSON is raw data: keep it under the ignored `build/` directory and
commit only a markdown summary of the comparison. A baseline recorded without
a toolchain fingerprint has no `toolchain` key; comparing against one prints a
warning ("baseline predates fingerprint recording") instead of a hard refusal,
so read its instruction-count deltas with that in mind.

For intentional code-generation changes, omit `--require-identical` when
comparing baseline with candidate; use generated-C review, behavioral and
ownership gates, and the stage-2/stage-3 fixpoint oracle instead. The normal
and diagnostic binaries must still emit identical C within each measured
pair. Record changes in C size alongside instructions and allocations.

### The Stage-2 Rule

`bin/blorp` is linked by the pinned bootstrap compiler, so a change to the
backend or the runtime in this worktree never shows up in what `bin/blorp`
itself runs. Any task that touches codegen or the runtime must instead
measure a **stage-2 compiler**: `blorp/src/main.brp` compiled by `bin/blorp`
and linked with the Makefile's own "Compiling Blorp CLI" recipe, so it
carries this checkout's codegen and runtime.

```bash
# Build both modes directly from one generated C and body object.
benchmarks/build_stage2_compiler --diagnostic-output bin/blorp-stage2-diagnostic \
  bin/blorp-stage2

# Or let the harness build and measure it in one step.
benchmarks/self_compile_measure --stage2 \
  --label candidate --input-rev <input_rev> \
  --baseline /tmp/paired-stage2-baseline.json \
  --output /tmp/candidate.json --require-identical
```

`--stage2` builds both `bin/blorp-stage2` and
`bin/blorp-stage2-diagnostic` via `benchmarks/build_stage2_compiler`, records
their hashes and the `bin/blorp` hash that generated their shared C, and
measures them as a pair. External binaries require both `--compiler` and
`--diagnostic-compiler`. The comparison
table prints `output bytes` next to the instructions-retired row, since the
compiler's own generated-C size is a tracked metric for codegen work. Both
scripts respect `BLORP_CLI_C_OPTIMIZATION` the same way `make` does; export it
before building, checking freshness, and measuring so all three agree on the
optimization level.

## Timing Model

`bench.sh` first compiles all compiled-language binaries for the selected
benchmark set into a temporary directory. Timed execution remains
benchmark-major, so the comparison table still runs `fib` across
blorp/blorp2/C/Go/OCaml/Python before moving to the next benchmark.
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

For `fib`, `numeric_loop`, `array_sum`, `array_ops`, `dict_ops`, `list_ops`, and
`set_ops`, `compiler_ast`, and `compiler_emit`, the sample runner checks exact stdout on every warmup and timed run
before accepting its `BENCH` marker. Their expected outputs are recorded in
`benchmarks/bench_run.py`. `binary_trees` also checks every result, allowing only
the existing spaces-versus-tabs formatting difference. Its contract uses the
shared depth-15 argument. Other rows do not yet have an output contract in the
sample runner.

`BENCH_ALLOC_STATS=1` builds separate diagnostic binaries for blorp and Blorp 2.
Timed samples always use normal binaries with memory diagnostics disabled.
Allocation runs use each runtime's leak-check mode and fail the benchmark on
diagnostic errors. The counts are labeled separately: legacy managed-object
counts and Blorp 2 allocator-call counts have different accounting boundaries.
The reported `bytes` field is live bytes at exit, not total bytes allocated.

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
BLORP2_COMPILER=/path/compiler  bash benchmarks/bench.sh fib # Select Blorp 2 compiler
BENCH_THREADS=4                 bash benchmarks/bench.sh   # Worker/task width for concurrency rows
BLORP_THREADS=4                 bash benchmarks/bench.sh   # Blorp runtime thread width for concurrency rows
GOMAXPROCS=4                    bash benchmarks/bench.sh   # Go runtime parallelism for concurrency rows
BENCH_RUNS=5                    bash benchmarks/bench.sh   # Timed runs per language (default: 1)
BENCH_WARMUPS=1                 bash benchmarks/bench.sh   # Untimed warmup runs (default: 0)
BENCH_ALLOC_STATS=1             bash benchmarks/bench.sh   # Separate allocation runs for both Blorp runtimes
BENCH_VERBOSE=1                 bash benchmarks/bench.sh   # Print build logs on failures
```

Python variants of concurrency benchmarks intentionally use `PYTHON_CONCURRENCY`
instead of `PYTHON`. That interpreter must be Python 3.14 or newer, built with
free threading enabled, and the harness runs it with `-X gil=0` before checking
that the GIL is disabled.

## Adding a New Benchmark

1. Add `benchmarks/blorp/<name>.brp`.
2. Optionally add `benchmarks/blorp_2/<name>.brp`, `benchmarks/c/<name>.c`, `benchmarks/go/<name>.go`,
   `benchmarks/ocaml/<name>.ml`, and `benchmarks/python/<name>.py`.
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

## Recording Results

A measurement lands as one markdown file, `benchmarks/results/<topic>_<date>.md`,
that stands on its own: host, source and binary revisions, flags, input hash,
commands, run order, sample count, headline numbers with spread, output
identity and caveats. Raw samples, logs, manifests, copied C and per-run
directories stay under the ignored `build/` directory; `.gitignore` admits only
markdown into `benchmarks/results/`. Link each report from the plan, README,
cost ceiling or source comment it supports, and delete the report when that
decision is superseded.
