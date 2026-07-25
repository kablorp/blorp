# blorp Benchmarks

Performance benchmarks comparing blorp against C, Go, OCaml, and Python.

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
  ocaml/<name>.ml
  python/<name>.py
  args/<name>.txt        # optional shared CLI args
```

The benchmark name is the filename without the extension. A benchmark must have
a blorp source file; C, Go, OCaml, and Python counterparts are optional.
Blorp benchmark sources can import harness helpers from `./support/benchmark`.
Reusable low-level timing and optimizer-barrier primitives live in the standard
`instrumentation` module.

## Default Benchmark Suite

These run when the filter is omitted or set to `all`.

| Benchmark | What it tests | Languages |
|-----------|--------------|-----------|
| `numeric_loop` | Collatz sequence (1M numbers), arithmetic loops | blorp, C, Go, OCaml, Python |
| `fib` | Recursive fib(40), function call overhead | blorp, C, Go, OCaml, Python |
| `string` | Checksum-based search, replace, substring, case conversion, split, trim, and reverse | blorp, C, Go, OCaml, Python |
| `array_sum` | Explicit integer vector sum (10k iterations, 1000 elements) | blorp, C, Go, OCaml, Python |
| `array_ops` | Integer vector add + scale + sum (10k iterations) | blorp, C, Go, OCaml, Python |
| `dict_ops` | Hash map build/lookup/remove/iterate | blorp, Go, OCaml, Python |
| `list_ops` | List append/sort/filter/fold/reverse/concat | blorp, Go, OCaml, Python |
| `set_ops` | Hash set build/contains/union/intersect/diff | blorp, Go, OCaml, Python |
| `threaded_cpu_map` | Fixed-width CPU-bound worker partitioning | blorp, C, Go, OCaml, Python |
| `channel_pipeline` | Producer/worker/consumer channel pipeline; Blorp currently uses structured concurrent list processing | blorp, C, Go, OCaml, Python |
| `sleep_fanout` | Many sleeping tasks/threads spawned and joined together | blorp, C, Go, OCaml, Python |
| `options` | `Option` representation and layout costs | blorp |
| `simd` | 16-element numeric tensor add, multiply, sum, and dot kernels | blorp, C |
| `nbody` | Struct-of-arrays N-body planetary simulation; Blorp currently uses list-backed storage | blorp, C, Go, OCaml, Python |
| `binary_trees` | Allocation-heavy binary tree construction/checking | blorp, C, Go, OCaml, Python |
| `fannkuch` | Permutation-heavy integer workload | blorp, C, Go, OCaml, Python |
| `spectral_norm` | Floating-point matrix/vector kernel with fresh intermediates | blorp, C, Go, OCaml, Python |
| `mandelbrot` | Complex-number style nested numeric loops | blorp, C, Go, OCaml, Python |
| `knucleotide` | String slicing and frequency maps | blorp, Go, OCaml, Python |
| `reverse_complement` | Shared FASTA reverse-complement transforms | blorp, Go, OCaml, Python |
| `compiler_ast` | Recursive AST construction, immutable tree rewrites, and pattern matching | blorp, Go, OCaml |
| `compiler_symbols` | Persistent symbol tables, nested scope walks, and repeated lookups | blorp, Go, OCaml |
| `compiler_emit` | C-like code emission and generated-text checksumming | blorp, Go, OCaml |

## Extra Benchmarks

These are listed by `bench.sh --list` and can be run directly, but they are not
included in `bench.sh all`.

| Benchmark | What it tests | Languages |
|-----------|--------------|-----------|
| `paradigms` | Functional dispatch, list destructuring, pattern matching, and coroutine-style control flow | blorp |
| `virtual_threads` | Fiber spawn, join, park, and wake scaling | blorp |

## Compiler Memory Diagnostics

These opt-in compiler benchmarks exercise production bridge actions with
bounded synthetic fixtures. They are not runtime language comparisons and are
deliberately excluded from `bench.sh all`.

### Typecheck Type-Shape Scanning

`compiler_typecheck_memory` generates nested record types and probe functions
with explicitly typed local bindings. It sends them through the production
`typecheck_graph` action and validates every streamed typed artifact:

```bash
benchmarks/compiler_typecheck_memory
benchmarks/compiler_typecheck_memory --type-depth 96 --probes-per-module 192
benchmarks/compiler_typecheck_memory --type-depth 384 --probes-per-module 192
benchmarks/compiler_typecheck_memory --modules 4 --type-depth 48 --probes-per-module 48
benchmarks/compiler_typecheck_memory --type-depth 1 --probes-per-module 1 \
  --primitive-probes-per-module 512
benchmarks/compiler_typecheck_memory --type-depth 1 --probes-per-module 1 \
  --primitive-storage-probes-per-module 512
benchmarks/compiler_typecheck_memory --type-depth 1 --probes-per-module 1 \
  --resource-scan-depth 64 --resource-scan-probes-per-module 128
```

Aggregate probes sample record types evenly across the full declared chain,
including its deepest type. Keep `--probes-per-module` fixed when comparing
depth commands so the same number of bindings covers each requested chain.
Deeper fixtures necessarily declare more record types, so this comparison also
includes their parse, environment, and artifact costs; use matching one-probe
runs as setup controls when attributing the incremental cost. Keep depth and
probe count fixed when varying `--modules` to measure graph width. The default
`192/192` fixture is intended for a roughly one-second local feedback loop on a
development machine.

Primitive probes use distinct scalar range types. Keep `--type-depth` and
`--probes-per-module` at 1 when comparing the final command so the retained
shape-memo cost of leaf bindings is isolated from nested aggregate scanning.
Primitive storage probes place distinct scalar range types in tuple literals.
Keep the other fixture dimensions at 1 or 0 when using the storage command so
the retained shape-memo cost of leaf-element storage checks remains visible.

Resource scan probes place a deeply nested tuple type in function signatures.
Keep the other fixture dimensions at 1 or 0 when using the final command so
recursive declaration resource-shape scanning is isolated.

The runner uses `BLORP_COMPILER_TYPECHECK_BRIDGE_BIN` when it names a prepared
helper. `--bridge PATH` overrides it. Otherwise, the runner prepares a cached
helper through `./blorp __compiler-bridge-prepare` before starting measurement.
Bridge preparation is excluded from the reported time. Results include SHA-256
digests of the bridge and request so saved before/after measurements remain
auditable.

### Captured Typecheck Replay

`compiler_typecheck_replay` runs one exact production `typecheck_graph` request
against an isolated helper. Capture mode writes the request immediately before
the OCaml host would start that helper, then deliberately stops:

```bash
cd compiler && dune build bin/blorp_ocaml_host.exe
cd ..

capture=$(mktemp "${TMPDIR:-/tmp}/blorp-typecheck.XXXXXX.json")
output=$(mktemp "${TMPDIR:-/tmp}/blorp-typecheck.XXXXXX.c")
BLORP_COMPILER_CAPTURE_TYPECHECK_GRAPH_REQUEST="$capture" \
  compiler/_build/default/bin/blorp_ocaml_host.exe \
  __compiler-host-compile-wrapper \
  -o "$output" \
  compiler/blorp/src/stage_06_typecheck/compiler_infer.brp
```

The capture command is expected to exit nonzero, and it must not create the
requested output. Keep captures local: they contain source text and local
paths. First typecheck only the target while retaining its full prepared graph
context, then typecheck the complete selected module graph:

```bash
benchmarks/compiler_typecheck_replay "$capture" \
  --target-only --timeout 60 --memory-limit 4G --json
benchmarks/compiler_typecheck_replay "$capture" \
  --timeout 60 --memory-limit 4G --json
```

`--module PATH` selects one original module target plus the request target and
can be repeated to form a narrow module set. `--first N` selects a prefix.
The `--retention-slice` preset specifically requires a `compiler_cli_main`
capture:

```bash
cli_capture=$(mktemp "${TMPDIR:-/tmp}/blorp-cli-typecheck.XXXXXX.json")
BLORP_COMPILER_CAPTURE_TYPECHECK_GRAPH_REQUEST="$cli_capture" \
  compiler/_build/default/bin/blorp_ocaml_host.exe \
  __compiler-host-compile-wrapper \
  -o "$output" \
  compiler/blorp/src/stage_12_cli/compiler_cli_main.brp

benchmarks/compiler_typecheck_replay "$cli_capture" \
  --retention-slice --timeout 60 --memory-limit 4G
```

As with the generic capture, the host command is expected to stop nonzero
before creating `"$output"`. The preset selects the known CTFE trigger plus its
six retained dependencies.

This is the fast feedback loop for graph-retention work. With a prepared helper
it completes in roughly 20 seconds on the development machine, instead of
running the unsafe 145-artifact graph. The runner enables a low-overhead
structural inventory by default. It reports parsed graph size, retained CTFE
program declarations and typed-expression nodes, artifact nodes, and modules
that exist simultaneously as retained CTFE and emitted typed programs. These
are logical structure counts, not allocator-byte estimates.
Artifact inventory distinguishes a second typed representation
(`duplicates_retained_ctfe=1`) from direct reuse of the retained CTFE program
(`reuses_retained_ctfe=1`). Reuse is permitted only when the dependency
typechecks in the artifact import environment and the graph target is not
reachable through its explicit import closure.
Use `--no-inventory` for an otherwise identical RSS/timing control run.

The result also records request, replay, and helper hashes; artifact order and
count; response size and hash; elapsed time; peak RSS; and sampled peak RSS by
phase and module. Phases shorter than the sampling interval can be absent
rather than receiving an inferred value. Helper preparation is excluded from
the measurement, while stdout and stderr remain file-backed.

The memory limit uses an address-space limit on Linux and a sampled RSS
watchdog on macOS. Linux allocation-limit failures are not distinguishable from
unrelated helper failures by exit status alone, so a nonzero exit under that
limit is reported as indeterminate and should be rerun without the limit.
`--memstats` adds runtime allocation counters to phase markers, but it
substantially increases time and memory use. Use it only for diagnosis, never
for headline before/after RSS or timing comparisons.

On macOS, regular RSS sampling invokes `ps` every 20 ms and observes only the
helper leader process. This is appropriate for the current single-process
typecheck helper, but it perturbs elapsed time and would omit any future child
processes. Use the global peak as the memory comparison and treat per-phase
samples and macOS elapsed time as diagnostic.

### Captured Backend Replay

`compiler_backend_memory` replays one production `emit_core_c` request against
an isolated renderer helper. Capture mode writes the request and deliberately
stops before resolving or starting the renderer:

```bash
capture=$(mktemp "${TMPDIR:-/tmp}/blorp-emit-core.XXXXXX.json")
BLORP_COMPILER_CAPTURE_EMIT_CORE_REQUEST="$capture" \
  ./blorp test --no-cache --timeout 30 \
  compiler/blorp/tests/test_compiler_infer.brp
```

The capture command exits nonzero after reporting the saved path. Its test
timeout does not govern compilation; safety comes from capture mode stopping
before renderer execution. Capture still runs the compiler frontend and middle
once and materializes the serialized request. Keep captured requests local:
they contain the lowered program and source paths, can be large, and should not
be committed.

Replay a bounded request with:

```bash
benchmarks/compiler_backend_memory "$capture" --timeout 60
benchmarks/compiler_backend_memory "$capture" --timeout 60 --json
benchmarks/compiler_backend_memory "$capture" --timeout 60 --vmmap
```

Requests larger than 16 MiB are refused by default. Use
`--allow-large-request` only when the replay process is already inside an
external memory limit, such as a Linux container or cgroup. The acknowledgement
is not itself a memory limit.

The result records request and helper SHA-256 digests, request/response sizes,
elapsed time, peak RSS, process status, and generated-C size. `--vmmap` adds
sampled macOS physical-footprint and allocator metrics. In `--vmmap` mode,
`peak_rss_bytes` is omitted because the sampler would contaminate the child RSS
value; use sampled `physical_footprint_bytes` instead. Full request validation
runs in a short-lived process and releases its JSON heap before bridge
preparation or replay. Bridge preparation is excluded from measurement, and
responses stay file-backed until the renderer has exited.

### Perceus Global Scanning

`compiler_perceus_memory` generates a bounded Core program with managed globals
that are irrelevant to moderately sized function bodies, sends it through the
production `emit_core_c` bridge action, validates the emitted C, and reports
request size, elapsed time, and peak memory:

```bash
benchmarks/compiler_perceus_memory
benchmarks/compiler_perceus_memory --globals 24
benchmarks/compiler_perceus_memory --globals 384
```

The function count and body shape stay fixed when comparing those last two
commands, isolating the cost of irrelevant globals. The runner uses
`BLORP_COMPILER_RENDERER_BRIDGE_BIN` when it names a prepared helper; otherwise
it prepares a cached helper through `./blorp __compiler-bridge-prepare` before
starting measurement. Bridge preparation is excluded from the reported time.

On macOS, all compiler memory diagnostics accept `--vmmap` to sample physical
footprint, `MALLOC_SMALL`, and allocation count when `vmmap` exposes those
fields:

```bash
benchmarks/compiler_typecheck_memory --vmmap
benchmarks/compiler_backend_memory captured-request.json --vmmap
benchmarks/compiler_perceus_memory --vmmap
```

`vmmap` sampling perturbs elapsed time, so use regular runs for timing and
sampled runs for allocator detail. Requests, responses, emitted C, and
measurement files live in a temporary directory and are removed after each
run.

## Timing Model

`bench.sh` first compiles all compiled-language binaries for the selected
benchmark set into a temporary directory. Timed execution remains
benchmark-major, so the comparison table still runs `fib` across
blorp/C/Go/OCaml/Python before moving to the next benchmark.

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
OCAMLOPT=ocamlopt               bash benchmarks/bench.sh   # Use specific OCaml native compiler
CC=gcc                          bash benchmarks/bench.sh   # Use specific C compiler
BENCH_THREADS=4                 bash benchmarks/bench.sh   # Worker/task width for concurrency rows
BLORP_THREADS=4                 bash benchmarks/bench.sh   # Blorp runtime thread width for concurrency rows
GOMAXPROCS=4                    bash benchmarks/bench.sh   # Go runtime parallelism for concurrency rows
BENCH_RUNS=5                    bash benchmarks/bench.sh   # Timed runs per language (default: 1)
BENCH_WARMUPS=1                 bash benchmarks/bench.sh   # Untimed warmup runs (default: 0)
BENCH_ALLOC_STATS=1             bash benchmarks/bench.sh   # Add Blorp allocation/release counts
BENCH_VERBOSE=1                 bash benchmarks/bench.sh   # Print build logs on failures
```

Python variants of concurrency benchmarks intentionally use `PYTHON_CONCURRENCY`
instead of `PYTHON`. That interpreter must be Python 3.14 or newer, built with
free threading enabled, and the harness runs it with `-X gil=0` before checking
that the GIL is disabled.

## Adding a New Benchmark

1. Add `benchmarks/blorp/<name>.brp`.
2. Optionally add `benchmarks/c/<name>.c`, `benchmarks/go/<name>.go`,
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
