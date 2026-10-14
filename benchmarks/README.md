# blorp Benchmarks

Performance benchmarks comparing blorp against C, Go, OCaml, and Python.

## Quick Start

```bash
# Build bin/blorp first
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

Compiler measurement tools live beside these suites: the `compiler_*` and
`self_compile*` runners, `build_stage2_compiler`, `c_emission_bytes`,
`normalize_generated_c_symbols`, the record-update allocation guards, and the
`blorp/profiles/` programs they drive. `results/` holds markdown summaries only
(see [Recording Results](#recording-results)).

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

### Compiler Record Layout

`compiler_record_layout` compiles a bounded fixture through the production
backend and reports generated-C `sizeof` and `_Alignof` values at both `-O0`
and `-O2`. The heap rows also report the allocation bytes selected by the
runtime's small-object pool:

```bash
benchmarks/compiler_record_layout
```

The fixture covers consecutive Boolean fields in a value struct, interleaved
Boolean and machine-word fields, three- and nine-field Boolean runs in heap
records, a source-interleaved internal heap record, compact scalar-union
fields in an internal heap record, preserved scalar wire-tag and Boolean fields in
foreign-reachable heap records, and a value struct reachable from a foreign
signature. The runner appends a temporary layout reporter to the generated C;
it does not modify production sources or artifacts. Use it as the fast
feedback loop for record representation changes.

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

### Frontend and Typecheck Function Profile

`compiler_typecheck_profile` runs a bounded synthetic graph through
`typecheck_graph` in-process with function profiling enabled:

```bash
benchmarks/compiler_typecheck_profile
benchmarks/compiler_typecheck_profile 2 2 64 128
benchmarks/compiler_typecheck_profile 2 2 64 128 fallback
benchmarks/compiler_typecheck_profile 1 8 32 64 mixed 4
```

The positional controls are iterations, module count, nested type depth, and
typed probes per module. An optional fifth argument selects the parsed-program
mode: `retained` is the default, while `fallback` exercises the text-parsing
boundary. The default `1 1 64 128 retained` workload is intended for fast local
typechecker comparisons.

The `mixed` mode changes the third and fourth controls to type shapes per
module and qualified probes per module. Its optional sixth argument is import
fan-out. It constructs recursive records, nested transparent aliases, opaque
aliases, unions, private declarations, and qualified cross-module references,
then validates exact artifact, declaration, import, category, private-wrapper,
and checksum counts. The focused type-header graph suite remains authoritative
for public-projection visibility. Use `1 8 32 64 mixed 4` for representative
accepted-header projection measurements; keep `retained` as the
containment-heavy control.

For frontend-through-typecheck work on the compiler, use the function-heavy
fixture in fallback mode and keep the retained run as a typecheck-only control:

```bash
BLORP_TYPECHECK_PROFILE_SKIP_BUILD=1 \
  benchmarks/compiler_typecheck_profile 5 1 16 256 fallback
BLORP_TYPECHECK_PROFILE_SKIP_BUILD=1 \
  benchmarks/compiler_typecheck_profile 5 1 16 256 retained
```

This shape is closer to the self-hosted inference module's function-to-type
declaration ratio while remaining a roughly two-second cached feedback loop.
Use at least three alternating fallback/retained samples and compare medians.

The runner builds and directly uses the workspace production
compiler CLI artifact at `blorp/build/_build/blorp-cli/blorp`, invokes its public
`compile --profile` path, and exercises the contiguous Blorp Core pipeline.
It caches the profiled executable by compiler, benchmark, standard-library,
runner, helper, platform, and C-toolchain content.
The first run for a new key performs the full instrumented build; subsequent
runs execute the cached binary directly. Benchmark stdout contains one
`TYPECHECK_PROFILE_BENCH` summary, including `workload_valid=True` only when
every iteration produced the expected artifact and declaration counts.
Function and `FLAME:` profile rows are written to stderr. Function times are
inclusive and overlap along nested call chains, so compare the same rows and
call counts across revisions rather than adding row percentages or treating
them as disjoint wall time. Request construction is excluded from
`elapsed_microseconds` but remains visible in the process-wide function profile;
use the `compiler_typecheck_benchmark_with_request` subtree when comparing the
typecheck workload itself.

### Paired Production-Pass Comparison

`compiler_pass_compare` is a small shared comparison driver for production-pass
benchmark experiments. It accepts two already executable benchmark commands or
binaries, runs a warmup, alternates baseline/candidate order, fails on child
errors or mismatched semantic fields, rejects dirty source roots unless
`--allow-dirty-source` is explicit, and writes raw paired samples plus binary,
fixture, platform, and optional source-worktree provenance. The driver does not
compile benchmark programs and does not copy sources between worktrees; if a
pilot needs a benchmark source that is absent from the baseline checkout, make
that temporary copy explicitly and verify before/after hashes outside the
timed comparison. Use `--fixture-source` for benchmark sources that must be
byte-identical under both source roots; use `--fixture` only for shared
external input files that are not source-root relative.

```bash
benchmarks/compiler_pass_compare \
  --label <label> \
  --baseline-bin /path/to/base/benchmarks/<benchmark> \
  --candidate-bin /path/to/candidate/benchmarks/<benchmark> \
  --baseline-source-root /path/to/base \
  --candidate-source-root /path/to/candidate \
  --fixture-source blorp/benchmark/compiler/<benchmark>.brp \
  --prefix <SUMMARY_ROW_PREFIX> \
  --time-field <elapsed_field> \
  --checksum-field <checksum_field> \
  --stable-field <field_that_must_match> \
  --pairs 7 \
  --warmup-pairs 1 \
  --results /tmp/<label>-pairs.json \
  -- <benchmark arguments>
```

The driver refuses a speed claim if a checksum or stable field diverges
between the paired runs; keep the raw pairs file local and commit only a
markdown summary.

### Core module flattening profile

`compiler_core_flatten_profile` isolates the callable-heavy module-flattening
work performed immediately after typed AST to Core lowering. By default the
synthetic fixture pairs one implementation with one forward declaration for
each logical callable, so every logical callable produces a real alias and
every call must be rewritten to the retained implementation.

```bash
benchmarks/compiler_core_flatten_profile prefix 10 128 4
benchmarks/compiler_core_flatten_profile aliases 10 128 4
benchmarks/compiler_core_flatten_profile prefix 10 128 4 fwd-first 8
benchmarks/compiler_core_flatten_profile prefix 10 128 4 impl-first 8
```

The positional controls are stage, iterations, logical callable count, calls
per implementation, declaration order (`impl-first` or `fwd-first`, default
`impl-first`), and forward declarations per logical callable (default `1`).
`prefix` measures `prefix_module_names_with_aliases`, including rewrite-plan
construction, declaration and expression renaming, type rewriting, and
deduplication. `aliases` measures `rewrite_program_callable_aliases` against a
prebuilt target program. Fixture construction, warmup, output traversal, and
checksum validation remain outside the profile window.

Declaration order and forward-declaration count isolate
`flatten.deduplicate_functions` cost shapes. `impl-first` places each
implementation before its duplicate forward declarations, so every duplicate
is already admitted and a pre-index algorithm's full-declaration rescan never
runs. `fwd-first` places every duplicate before its implementation, forcing a
pre-index algorithm to rescan all declarations once per duplicate before it
ever reaches the implementation -- the quadratic worst case. Raising forward
declarations per callable widens the duplicate ratio under either order.

Stdout contains one `CORE_FLATTEN_PROFILE` row with structural counters,
elapsed profile-window time, managed allocation/release deltas
(`new_allocations`/`new_releases`, from `memory.get_mem_stats()` snapshots
taken immediately inside the profile window), and `workload_valid=True` only
when all declarations and calls have the expected rewritten identities. Raw
function and `FLAME:` rows are written to stderr; grep them for
`function_decl_has_implementation_named` or the current pre-index build
function to see full-declaration-rescan call counts directly. Function times
are inclusive, so compare identical rows and call counts across sizes or
revisions; do not add row percentages. The first invocation compiles and
caches an instrumented benchmark binary. Set
`BLORP_COMPILER_BENCHMARK_SKIP_BUILD=1` when the workspace compiler is already
current.

### Import Graph Profile

`compiler_import_graph_profile` is the fast control for import-environment
work. Unlike `compiler_typecheck_profile`, it constructs real resolved import
edges. The default graph has 30 modules, 32 functions per module, and a fan-out
of 20, producing 420 resolved imports and 13,440 imported-function registration
opportunities per iteration:

```bash
benchmarks/compiler_import_graph_profile
benchmarks/compiler_import_graph_profile 3 30 32 20 fallback
benchmarks/compiler_import_graph_profile 3 30 32 20 retained direct
```

The positional controls are iterations, module count, functions per module,
import fan-out, parsed-program mode, and optional `direct` frontend mode. The
default measures descriptive replay. Direct mode builds a real
`FrontendGraph` and enters typechecking through the compiler's graph-owned
table boundary. The benchmark validates artifact, declaration,
resolved-import, and import-binding counts on every iteration and prints
`workload_valid=True` only when the complete graph matches those invariants
without type errors. Every generated module calls every imported callable
through its qualified module alias, so dropping or mis-registering an imported
signature fails the workload rather than appearing as a speedup. Request
construction is reported separately; elapsed and allocator counters cover the
selected graph construction/typechecking mode.

This runner is deliberately uninstrumented and optimized by default. A cached
invocation takes roughly two seconds on the development machine. Compiler-source
changes invalidate the executable and require compiling the benchmark again;
that cold build remains material and must not be included in benchmark samples.
Use `BLORP_IMPORT_GRAPH_PROFILE_FUNCTIONS=1` only when exact function call counts
are needed. Function instrumentation is too expensive and intrusive for the
per-edit timing loop.

### CTFE Dependency Typecheck Profile

`compiler_ctfe_typecheck_profile` measures the production path that prepares
typed imported programs for compile-time evaluation. Its dependency graph is a
linear chain. Every module contains the same number of pure functions, but the
target global reaches only function zero through that chain. Increasing graph
depth therefore measures repeated imported-module setup, while increasing
module width exposes eager materialization of CTFE-irrelevant function bodies:

```bash
benchmarks/compiler_ctfe_typecheck_profile
benchmarks/compiler_ctfe_typecheck_profile 3 24 128 retained
benchmarks/compiler_ctfe_typecheck_profile 3 64 1 retained
benchmarks/compiler_ctfe_typecheck_profile 3 24 32 fallback
```

The positional controls are iterations, dependency modules, functions per
module, and parsed-program mode. Request construction and parsing are reported
as `setup_microseconds` and excluded from `elapsed_microseconds`. Every timed
iteration validates artifact, declaration, import, diagnostic, CTFE execution,
and rewritten-global results; `workload_valid=True` is required for a usable
sample. The fixture also records the expected reachable and irrelevant body
counts from its generated shape; these are not observed materialization
counters.

The optimized cached executable is the per-edit feedback loop. Compiler-source
changes require one cold rebuild; repeated samples then execute the cached
binary directly. Set `BLORP_COMPILER_BENCHMARK_SKIP_BUILD=1` after the artifact
exists to skip even the workspace build check. Use
`BLORP_CTFE_TYPECHECK_PROFILE_FUNCTIONS=1` only to attribute work inside
`prepare_ctfe_dependencies`, imported declaration registration, and body
materialization. Instrumented elapsed time is not comparable with the default
optimized result.

Keep the narrow
`64 1` depth control beside a wide run when evaluating a change: optimizing
only dependency-order list mechanics should not be mistaken for reducing
semantic registration or body checking.

### Module Binding Profile

`compiler_module_binding_profile` isolates graph-aware source import binding
from declaration registration and body inference. Setup parses 64 module
surfaces with 16 exports each. The measured loop registers 64 combined
qualified/selective imports through the same production function used by the
typechecker:

```bash
benchmarks/compiler_module_binding_profile
benchmarks/compiler_module_binding_profile 100 64 16
```

The positional controls are iterations, module count, and exports per module.
Even-numbered imports use exact canonical paths; odd-numbered imports use an
alternate source module name. Every import selects the final exported symbol
and also binds an explicit module alias. The result validates aliases,
selective names, total bindings, and diagnostics. Counts and diagnostics are
checked on every iteration; exact source-order and indexed lookups are checked
on the final state after elapsed timing stops.

`baseline_alternate_candidate_pressure`,
`baseline_surface_symbol_comparison_pressure`, and
`baseline_import_binding_comparison_pressure` model the work of a
list-scanning implementation. They are not required costs: elapsed and
inclusive function time can fall with graph-owned indexes even when the number
of semantic lookup calls stays fixed. Use
`BLORP_MODULE_BINDING_PROFILE_FUNCTIONS=1` when exact function call counts are
needed; plain mode remains the fast comparison loop.

The compiler benchmark wrappers use `compiler_blorp_benchmark_runner` for
compiler selection, content-addressed artifacts, and native C flags.
The runner enables memory diagnostics in benchmark executables so fixtures
that report allocation counts receive active counters. Its script hash is
part of the cache key, so this flag change rebuilds cached executables.
`BLORP_COMPILER_BENCHMARK_COMPILER` and
`BLORP_COMPILER_BENCHMARK_SKIP_BUILD=1` are the generic controls; the older
`BLORP_TYPECHECK_PROFILE_*` names remain supported for the existing profile.

Set `BLORP_COMPILER_BENCHMARK_WORKSPACE_ROOT` when the benchmark source and its
imported compiler modules come from another checkout. The runner uses that one
root for the default compiler, source hashing, compiler headers,
native include paths, `blorp.toml`, and the benchmark working directory. This
prevents a cross-checkout run from compiling generated C against headers from a
different compiler-source graph.

The runner executes from the selected workspace root and clears `BLORP_STD`,
so one cache key describes one effective compiler graph.
`BLORP_TYPECHECK_PROFILE_COMPILER` may override the compiler CLI. Set
`BLORP_TYPECHECK_PROFILE_SKIP_BUILD=1` after building that executable separately
when repeated source-level measurements should avoid the workspace build check.

### Typecheck Type-Shape Scanning

`compiler_typecheck_memory` generates nested record types and probe functions
with explicitly typed local bindings. It sends them through a benchmark-only
`typecheck_graph` transport backed by the production Blorp typechecker and
validates every streamed typed artifact:

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
benchmarks/compiler_typecheck_memory --type-depth 1 --probes-per-module 1 \
  --type-instantiation-depth 32 --type-instantiation-probes-per-module 32
benchmarks/compiler_typecheck_memory --type-depth 1 --probes-per-module 1 \
  --union-variants-per-module 256
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

Self-resolution probes generate a trait and implementation whose method
parameters contain deeply nested `Self` types. The implementation targets a
local generic record with an equally deep concrete type argument, so both the
traversed signature and substituted `concrete_type` scale with the requested
depth. They exercise the production `resolve_self` path during
implementation validation:

```bash
benchmarks/compiler_typecheck_memory --type-depth 1 --probes-per-module 1 \
  --self-resolution-depth 64 --self-resolution-probes-per-module 128
```

Type-instantiation probes generate generic function signatures with a deeply
unchanged concrete tuple, a partially changed tuple, and a nested generic type
whose complete ancestor path changes. They exercise all three paths through
`type_instantiate_type_params`.

Union-header probes add one accepted union declaration per module with the
requested number of constructors, alternating empty and `Int` payloads. Keep
the other dimensions at their minimums when using this mode so the request
isolates type-header installation and constructor registration.

Use `--warmup-runs N --runs N` for low-noise comparisons. The bridge and request
are prepared once, every warmup and measured response is validated, and the
summary reports minimum, median, and maximum elapsed time plus median and
maximum peak RSS.

Pass two prepared helpers to compare a candidate and baseline in one invocation:

```bash
benchmarks/compiler_typecheck_memory \
  --bridge /tmp/candidate/compiler_typecheck_worker \
  --baseline-bridge /tmp/baseline/compiler_typecheck_worker \
  --warmup-runs 2 --runs 10
```

Comparison mode alternates bridge order on every round, requires byte-identical
responses, requires even warmup and measured run counts, preserves every sample
and its execution order, and reports median paired latency and peak-RSS
percentage changes. Negative changes mean the candidate used less time or
memory than the baseline.

The runner uses `BLORP_TYPECHECK_BENCHMARK_WORKER` when it names an existing
worker. `--bridge PATH` overrides it. Otherwise, the runner builds a disposable
worker from `blorp/benchmark/compiler/compiler_typecheck_worker.brp` with the
current `bin/blorp`. Worker construction is excluded from the reported time.
Results include SHA-256 digests of the worker and request so saved before/after
measurements remain auditable.

The benchmark CI workflow runs the smallest fixture without an override before
the standard suite. That smoke compiles and links the real worker, executes it,
and validates its streamed response on each benchmark platform.

### Captured Typecheck Replay

`compiler_typecheck_replay` runs one captured production `typecheck_graph`
request against an isolated benchmark worker. Capture exactly one CLI check
root with the explicit diagnostic flag; this constructs the normal source graph
and stops before typechecking. Keep captures local because they contain source
text and local paths. The disposable typecheck worker is compiled with memory diagnostics;
`--memstats` and `--allocator-stats` reject an external worker whose counters
report inactive. First typecheck only the target while retaining its full
prepared graph context, then typecheck the complete selected module graph:

```bash
capture=$(mktemp "${TMPDIR:-/tmp}/blorp-typecheck-graph.XXXXXX.json")
bin/blorp check --no-format --capture-typecheck-request "$capture" \
  blorp/src/main.brp
benchmarks/compiler_typecheck_replay "$capture" \
  --target-only --timeout 60 --memory-limit 4G --json
benchmarks/compiler_typecheck_replay "$capture" \
  --timeout 60 --memory-limit 4G --json
```

`--module PATH` selects one original module target plus the request target and
can be repeated to form a narrow module set. `--first N` selects a prefix. The
`--retention-slice` preset specifically requires an existing
`main` capture and selects the known CTFE trigger plus its six
retained dependencies:

```bash
cli_capture=/path/to/existing-compiler-cli-typecheck-request.json
benchmarks/compiler_typecheck_replay "$cli_capture" \
  --retention-slice --timeout 60 --memory-limit 4G
```

This is the representative feedback loop for graph-retention work. The current
compiler CLI capture contains 337 dependency modules and takes about 80 seconds
for a target-only replay on the development machine; it replaces the unsafe
full-artifact graph with one bounded artifact, but is not yet a short inner-loop
benchmark. The runner enables a low-overhead structural inventory by default. It
reports parsed graph size, retained CTFE
program declarations and typed-expression nodes, artifact nodes, and modules
that exist simultaneously as retained CTFE and emitted typed programs. These
are logical structure counts, not allocator-byte estimates.
Artifact inventory distinguishes a second typed representation
(`duplicates_retained_ctfe=1`) from direct reuse of the retained CTFE program
(`reuses_retained_ctfe=1`). Reuse is permitted only when the dependency
typechecks in the artifact import environment and the graph target is not
reachable through its explicit import closure.
Use `--no-inventory` for an otherwise identical RSS/timing control run.

The result also records request, replay, and worker hashes; artifact order and
count; response size and hash; elapsed time; peak RSS; and sampled peak RSS by
phase and module. Phases shorter than the sampling interval can be absent
rather than receiving an inferred value. Helper preparation is excluded from
the measurement, while stdout and stderr remain file-backed. Without `--bridge`
or `BLORP_TYPECHECK_BENCHMARK_WORKER`, the runner builds the same disposable
benchmark worker used by `compiler_typecheck_memory`.

Timestamped helper markers additionally populate `checkpoint_elapsed_microseconds`,
`module_checkpoint_elapsed_microseconds`, `phase_marker_counts`, and
`module_phase_marker_counts`. Each same-module interval is attributed to the
checkpoint that ends it and is also retained as
`elapsed_since_previous_checkpoint_microseconds` in the timeline. Intervals
between one module's final checkpoint and the next module's start are excluded.
Older helpers without timestamps remain replayable; their checkpoint timing
maps are empty rather than inferred from process sampling.

The memory limit uses an address-space limit on Linux and a sampled RSS
watchdog on macOS. Linux allocation-limit failures are not distinguishable from
unrelated helper failures by exit status alone, so a nonzero exit under that
limit is reported as indeterminate and should be rerun without the limit.
`--memstats` resets before measured work and adds exact, metadata-tracked epoch
counters to phase markers. It is intentionally perturbative. `--allocator-stats`
instead keeps cumulative lightweight managed counters without constructing the
per-object metadata table; the phase markers carry `bytes_allocated` (managed
bytes) and `allocator_bytes_in_use` (the platform allocator's process-wide
in-use estimate, which is what this mode reports as available). It still adds atomic traffic to every managed
allocation, so use either mode for attribution rather than headline timing
comparisons. Cumulative allocator-stat counts include worker startup; compare
checkpoints or module/phase deltas rather than interpreting them as an isolated
epoch.

For compile-execution memory profiles, set
`BLORP_MEMORY_STATS=1`. The compiler writes schema-1
`BLORP_COMPILER_MEMORY_CHECKPOINT` rows to stderr at
`source_discovery_start`, then at the completed compiler phase checkpoints:
`source_discovery_complete`, `typed_frontend_start`,
`typed_frontend_complete`, `core_lowering_input_ready`,
`core_lowering_complete`, `early_core_complete`,
`runtime_projection_complete`, `late_core_complete`,
`backend_emission_complete`, and `artifact_construction_complete`. Also emitted, between the last late-Core pass's own `pass_<name>_complete`
row and `late_core_complete`: `cleanup_plan_complete` and
`cancellation_plan_complete`, for the per-type cleanup plan and the
per-function/global cancellation plan that
`prepared_core_program_with_checkpoints` (`stage_09_core/pipeline.brp`) builds
after the last late-Core pass, so their allocations attribute to a named row
instead of the coarser `late_core_complete` phase total. If a
compilation fails or stops, the final checkpoint uses the active phase label
with `_failed` or `_stopped`, such as `typed_frontend_failed` or
`late_core_stopped`. If final artifact publication fails after compiler
artifact construction succeeds, `artifact_publication_failed` is emitted after
`artifact_construction_complete`; publication time is still outside compiler
phase timing and is not an artifact-construction phase failure. Each row includes a
monotonic timestamp, managed allocation/release/current-object counters,
allocator bytes, current RSS, and process peak RSS. Unsupported platform
measurements are `-1`; do not infer missing values. Compare checkpoint deltas
and global peak RSS together because allocator retention can keep RSS above the
managed live-object count. Source discovery — reading, lexing, and parsing the root module and
everything it imports, plus module-graph construction — runs between
`source_discovery_start` and `source_discovery_complete`, before the compile
plan exists. Command planning happens before `source_discovery_start`, and
final artifact file publication happens after `artifact_construction_complete`,
so these rows intentionally measure source discovery and execution of an
already constructed compile plan rather than process startup or the entire CLI
command.

`core_lowering_input_ready` is the ownership boundary between the rich
frontend result and the opaque input accepted by Core. It is emitted after
command policy and Core input projection, when the broad source/typecheck graph
is no longer reachable, and before Core allocation begins. Compare it with
`typed_frontend_complete` to measure the release itself and with
`core_lowering_complete` to measure its effect on the Core high-water mark.

On macOS, regular RSS sampling invokes `ps` every 20 ms and observes only the
helper leader process. This is appropriate for the current single-process
typecheck worker, but it perturbs elapsed time and would omit any future child
processes. Use the global peak as the memory comparison and treat per-phase
samples and macOS elapsed time as diagnostic.

### C Symbol Projection

`compiler_c_symbol_projection` compiles a bounded multi-module fixture through
the production backend, validates its exact runtime checksum, and measures the
generated-C and host-C effects of internal callable naming:

```bash
benchmarks/compiler_c_symbol_projection --samples 1
benchmarks/compiler_c_symbol_projection --samples 3 --skip-build --json
benchmarks/compiler_c_symbol_projection \
  --compiler bin/blorp --compiler-root . \
  --baseline-compiler /path/to/baseline/blorp \
  --baseline-compiler-root /path/to/baseline \
  --samples 3 --skip-build --json
```

The result includes compiler and fixture hashes, generated-C bytes and lines,
top-level callable identifier counts and lengths, compile-to-C time/RSS,
`-O0` and `-O2` host-C time/RSS, and object sizes. Use `--compiler` with
`--compiler-root` to measure another checkout while retaining the same fixture
bytes. Pass the paired `--baseline-compiler` and `--baseline-compiler-root`
arguments for timing comparisons; paired mode alternates execution order for
each sample. The one-sample form is the fast artifact-census loop.

### Captured Backend Replay

`compiler_backend_memory` replays one schema-1 `emit_core_c` request against an
isolated benchmark-owned backend worker. The compiler does not currently expose
a production backend-request capture option; do not rely on the historical
`BLORP_COMPILER_CAPTURE_EMIT_CORE_REQUEST` recipe. Use a checked-in
deterministic request generator, or an existing private capture whose
provenance and request hash are recorded. Keep private captures local: they can
contain source paths, can be large, and should not be committed.

For source-location representation work, generate a deterministic bounded
request containing 10,200 known Core locations instead of capturing a full
compiler build:

```bash
request=$(mktemp "${TMPDIR:-/tmp}/blorp-core-source-loc.XXXXXX.json")
bin/blorp run --no-format \
  blorp/benchmark/compiler/compiler_core_source_loc_request.brp >"$request"
benchmarks/compiler_backend_memory "$request" --timeout 60
```

The fixture emits the same backend bridge envelope as a production capture and
keeps function count, tree shape, and generated C stable across layout changes.

For callable-symbol emission work, generate the bounded 256-function,
16-calls-per-function request used by the callable-symbol projection profile program:

```bash
request=$(mktemp "${TMPDIR:-/tmp}/blorp-c-symbol-projection.XXXXXX.json")
bin/blorp run --no-format \
  blorp/benchmark/compiler/compiler_c_symbol_projection_request.brp >"$request"
benchmarks/compiler_backend_memory "$request" --timeout 60 --json
```

The generator fixes logical names at 96 bytes and emits a schema-1
`emit_core_c` envelope. Its request hash and the backend response hash must
match across alternating baseline/candidate runs; three pairs are the default
for this focused comparison.

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
responses stay file-backed until the worker has exited.

### Perceus Global Scanning

`compiler_perceus_memory` generates a bounded Core program with managed globals
and moderately sized function bodies, validates the resulting Core, and reports
request and artifact hashes, elapsed time, peak memory, a static ownership-node
census, and deterministic work counters. The default inner window is named
`ownership-preparation plus Perceus` because it includes consume specialization,
static literals, record-update lowering, dictionary ownership preparation,
product field evaluation, and Perceus. Synthetic function origins come from
the compiled worker's `function_origin_fixture` supplier during setup; paired
workers must agree on that metadata. Select
`--measurement-window perceus-direct` to perform those prerequisites before the
window and measure only `insert_drops_program`:

```bash
benchmarks/compiler_perceus_memory
benchmarks/compiler_perceus_memory --globals 24
benchmarks/compiler_perceus_memory --globals 384
benchmarks/compiler_perceus_memory --global-reads-per-function 0
benchmarks/compiler_perceus_memory --measurement-window perceus-direct
```

The closed `aggregate_change_matrix` fixture retains ten neutral and eleven
ownership-sensitive roots per function, plus two neutral call arguments.
Product construction, lowered record update and record reuse now evaluate
fields into ordinary bindings before Perceus. The output oracle follows the
exact field binder to its RHS, preserving each sensitive/neutral pair; the
insertion counters require fifteen reused and eight rebuilt aggregate roots
per function because those three sensitive operands are rewritten in their
binding RHS instead.

The function count, body shape, and referenced-global count stay fixed when
varying `--globals`, isolating the cost of irrelevant globals beyond the
referenced set. Set `--global-reads-per-function 0` to measure bodies with no
global references. The runner uses `BLORP_BACKEND_BENCHMARK_WORKER` when it
names a prepared worker; otherwise it builds the benchmark-owned worker before
starting measurement. Worker construction is excluded from the reported time.
The independently instrumented worker uses
`BLORP_BACKEND_COUNTER_BENCHMARK_WORKER`; the timing-worker override is never
silently reused for counters.

On macOS, all compiler memory diagnostics accept `--vmmap` to sample physical
footprint, `MALLOC_SMALL`, and allocation count when `vmmap` exposes those
fields:

```bash
benchmarks/compiler_typecheck_memory --vmmap
benchmarks/compiler_backend_memory captured-request.json --vmmap
benchmarks/compiler_perceus_memory --vmmap
```

The result contains both process elapsed time and `window_elapsed_microseconds`.
Only the latter isolates the named compiler window; process elapsed time still
includes worker startup and Core JSON decoding/encoding. Window allocation and
release counts are captured by the ordinary timing worker. Static `DupExpr` and
`DropExpr` counts are grouped by policy in `ownership_census`.
An untimed inspection request also reports expression and ownership-event
censuses, plus artifact hashes, for ownership-ready, post-Perceus, post-reuse,
and prepared Core.

For end-to-end emission, `generated_c_ownership_census` also reports cleanup
frame declarations, cleanup-scope guards, and cleanup push/pop/duplicate calls.
These metrics provide a deterministic generated-C census; compare their values together with
`generated_c_bytes`, elapsed time, and peak memory rather than counting source
text with ad hoc shell patterns.

Logical counters come from a separately compiled `--debug --profile` worker.
Normal builds erase all marker calls through `debug:` blocks. The runner executes
the counter worker twice, requires identical counter maps, and rejects any Core
artifact mismatch between counter and timing workers. Use `--no-work-counters`
for a timing-only run, or `--counter-bridge` when comparing an explicitly built
instrumented worker. Never use the debug/profile worker's elapsed time for a
speed claim.

The body catalog keeps each ownership optimization on an independently
selectable workload:

```bash
benchmarks/compiler_perceus_memory --body-shape linear
benchmarks/compiler_perceus_memory --body-shape borrowed_call_protection
benchmarks/compiler_perceus_memory --body-shape aggregate_escape
benchmarks/compiler_perceus_memory --body-shape borrowed_return
benchmarks/compiler_perceus_memory --body-shape nested_user_call --user-call-edges 8
benchmarks/compiler_perceus_memory --body-shape mutually_recursive_calls --user-call-edges 8
```

The borrowed-call fixture holds one real consuming field projection constant as
owner count grows. The aggregate fixture places twelve field projections in
explicit record-transfer slots per function. Both use fixed 128-node bodies and
ordinary name-only heap-record parameters. The borrowed-result fixture uses a
fixed 256-node body with a balanced 32-terminal result tree; one traversable
padding subtree remains outside result position. None adds real alias work as
the owner-count axis grows. Use `--end-to-end` to run
ownership preparation, Perceus, and the complete post-Perceus tail before
measuring backend emission. That result includes separate retain, release,
ARC-only release, cleanup-push, and cleanup-pop counts from the generated
program C artifact.

For the standard four-point global/reference matrix, build one worker and run
seven warmed samples per point:

```bash
benchmarks/compiler_perceus_memory --global-matrix --samples 7 --json
```

The parameter matrix keeps two uncalled worker functions at 128 body leaves,
replaces literals with one exact read per varied parameter, and runs primitive
`Int` and managed borrowed `String` controls at each 1/8/32 point through the
same worker:

```bash
benchmarks/compiler_perceus_memory --parameter-matrix --samples 7 --json
```

This matrix holds expression-node count fixed. The primitive control measures
parameter metadata and Core JSON growth without managed ownership
normalization. Primitive and managed samples alternate at each count and the
result reports paired ratios. Use paired candidate/baseline workers for
compiler-change claims rather than treating absolute times as Perceus-only
subphase timings.

The contract matrix varies borrowed owners, exact function-body node count,
and user-call edges one axis at a time. Padding literals keep the other two
structural axes fixed, including the owner-count points. The edge axis uses 33
mutually recursive functions so each function can call 1, 8, or 32 distinct
callees; repeated sites to the same callee do not masquerade as graph edges:

```bash
benchmarks/compiler_perceus_memory --contract-matrix --samples 7 --json
```

The aggregate matrix keeps two uncalled worker functions at exactly 128 nodes,
varies 1, 8, and 32 borrowed owners, and holds twelve real aggregate escapes per
function fixed. It rejects owner-scaled traversal, alias fallback, origin-set,
or rewrite work and requires at least a 75% traversal reduction at 32 owners in
paired compiler-worker mode:

```bash
benchmarks/compiler_perceus_memory \
  --aggregate-matrix \
  --measurement-window perceus-direct \
  --samples 7 --json
```

The result matrix keeps two uncalled worker functions at exactly 256 nodes,
varies 1, 8, and 32 borrowed owners, and holds 32 real result terminals per
function fixed. It forces the direct-Perceus window, requires explicit
immediate-parent timing and counter workers, checks exact Core identity, and
enforces the result traversal, timing, allocation, and one-owner regression
gates:

```bash
benchmarks/compiler_perceus_memory \
  --result-matrix \
  --bridge /path/to/candidate-worker \
  --counter-bridge /path/to/candidate-counter-worker \
  --baseline-bridge /path/to/immediate-parent-worker \
  --baseline-counter-bridge /path/to/immediate-parent-counter-worker \
  --samples 7 --json
```

The referenced-global matrix keeps 384 declared globals, two uncalled
256-node functions, and 32 ownership-boundary sites per function. It cycles
those fixed sites through 1, 8, and 32 exact managed global identities, so
only the referenced-owner cardinality changes. The matrix requires explicit
immediate-parent timing and counter workers, forces direct Perceus, checks
exact post-Perceus Core identity, and enforces visit, timing, allocation,
fallback, rewrite-count, and one-global regression gates:

```bash
benchmarks/compiler_perceus_memory \
  --referenced-global-matrix \
  --bridge /path/to/candidate-worker \
  --counter-bridge /path/to/candidate-counter-worker \
  --baseline-bridge /path/to/immediate-parent-worker \
  --baseline-counter-bridge /path/to/immediate-parent-counter-worker \
  --samples 7 --json
```

The direct matrix leaves workers uncalled to isolate Perceus. Validate rooted
generated C separately with `--body-shape referenced_global_boundary`,
`--end-to-end`, and each 1/8/32 reference count.

The lambda-owner baseline matrix keeps two uncalled outer functions and two
256-node outer lambda bodies fixed while varying 1, 8, and 32 managed lambda
parameters. Each outer lambda contains twelve consuming calls, twelve
transferring record fields, twelve result terminals, and one fixed nested
lambda region. This preparation matrix deliberately excludes captures and
globals: their current name-mode overlap would make source-kind timing
comparisons ambiguous:

```bash
benchmarks/compiler_perceus_memory \
  --lambda-owner-matrix \
  --measurement-window perceus-direct \
  --samples 7 --json
```

For performance decisions, compare explicit workers in alternating order:

```bash
benchmarks/compiler_perceus_memory \
  --baseline-bridge /path/to/baseline-worker \
  --bridge /path/to/candidate-worker \
  --samples 7 --json
```

Paired mode rejects differing artifacts and reports both the ratio of medians
and the median paired candidate/baseline ratio. Worker processes have a
60-second default timeout; override it with `--timeout`.

The result reports median elapsed time, median absolute deviation, peak RSS,
request and worker hashes, and a stable artifact hash. Record a durable result as one
markdown summary under `benchmarks/results/`; keep the raw samples under the
ignored `build/` directory.

`vmmap` sampling perturbs elapsed time, so use regular runs for timing and
sampled runs for allocator detail. Requests, responses, emitted C, and
measurement files live in a temporary directory and are removed after each
run.

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

For `fib`, `numeric_loop`, `array_sum`, `array_ops`, `dict_ops`, `list_ops`, and
`set_ops`, the sample runner checks exact stdout on every warmup and timed run
before accepting its `BENCH` marker. Their expected outputs are recorded in
`benchmarks/bench_run.py`. Other rows do not yet have an output contract in the
sample runner.

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

## Recording Results

A measurement lands as one markdown file, `benchmarks/results/<topic>_<date>.md`,
that stands on its own: host, source and binary revisions, flags, input hash,
commands, run order, sample count, headline numbers with spread, output
identity and caveats. Raw samples, logs, manifests, copied C and per-run
directories stay under the ignored `build/` directory; `.gitignore` admits only
markdown into `benchmarks/results/`. Link each report from the plan, README,
cost ceiling or source comment it supports, and delete the report when that
decision is superseded.
