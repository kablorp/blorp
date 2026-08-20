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

### Blorp Test Session

`scripts/bench-blorp-test-session` characterizes the production `blorp test`
route and compares test-session implementations with alternating paired runs.
It records exact executable and explicitly named companion-input hashes,
revision and worktree content, effective-environment and cache fingerprints,
raw output hashes, structured gate/manifests, current timing records, session
counters, elapsed time, and sampled peak aggregate RSS across the descendant
process session. With `BLORP_TEST_TIMINGS=1`, the current production route
reports discovered runnable files, their unique retained source identities and
bytes, declared suites, aggregate suite harnesses, combined suite files and
native executions, and individually executed source files.
The deterministic effective artifact plan is reported once per invocation from
the first repeat. `--repeat` deliberately rebuilds and executes the same
batches so compilation, side effects, leak
checks, and timeouts are exercised again. The `planned_*` names deliberately
do not claim that compilation or execution completed; compile failures and
individual doctest expansion remain runtime observations. The retained-source
names likewise do not claim total discovery I/O because rejected candidates
are not represented by the retained runnable source records.

Every successful route run must execute at least one test and emit exactly one
versioned `session_totals` record containing the required structural and plan
counters. Optional counters report per-route coverage and receive medians only
when present in every retained measurement. Route elapsed time stops when the
route process is reaped; post-exit descendant verification is recorded
separately so benchmark bookkeeping does not inflate tiny-suite latency.

Timeout supervision runs independently of RSS sampling. Cleanup preflights an
absolute `ps` executable before launching a route, tracks sampled process birth
identities as well as PIDs, and revalidates post-reap process groups before
signalling them. A platform without the required process metadata is rejected
before measurement rather than producing unverifiable cleanup evidence.

Run a local single-route smoke measurement with an isolated warm runtime cache:

```bash
scripts/bench-blorp-test-session \
  --baseline ./blorp \
  --baseline-label current \
  --pairs 1 \
  --warmup-pairs 1 \
  --cache-state isolated-warm \
  --allow-dirty \
  -- test --timeout 30 \
    tests/test_blorp/types/test_bool.brp
```

Compare two route executables with identical test arguments:

```bash
scripts/bench-blorp-test-session \
  --baseline /path/to/baseline/blorp \
  --candidate /path/to/candidate/blorp \
  --workload compiler-suite \
  --pairs 10 \
  --warmup-pairs 1 \
  --cache-state isolated-warm \
  --input compiler/blorp/tests \
  --artifact-dir /tmp/blorp-test-session-evidence \
  --output benchmarks/results/blorp_test_session.json \
  -- test --timeout 180 compiler/blorp/tests/
```

Comparison mode alternates route order and requires matching characterized
output for every pair. Runs with at least ten and at most thirty measured pairs
report deterministic 95% bootstrap intervals for paired elapsed-time and
sampled-RSS changes; smoke runs report paired samples without inferential
intervals.

`benchmarks/blorp_test_session_policy.json` keeps comparison and
characterization workloads in one registry with an explicit `kind`.
`tiny-suite` gates the upper bound of the paired elapsed-time 95% interval;
`compiler-suite` gates the upper bound of the paired aggregate-RSS 95%
interval. Both reject an upper bound above a 10% regression or an interval
wider than 10 percentage points. A registered comparison must use the
policy's exact command, isolated-warm cache state, and one warmup, with 10-30
measured pairs in even-numbered alternating blocks and at least 10,000
bootstrap samples. The driver records and rechecks the policy hash so the
policy cannot change during a run. When a registered comparison exceeds
either bound, the driver retains the JSON result and exits nonzero.

The registry also includes characterization workloads for the remaining
session shapes: many tiny compatible suites, shared-import fan-out,
mixed shared/process/filesystem isolation, the full compiler suite, a runtime
value-types subset, a standard-library dictionary directory, doctests,
sanitizer, leak checking, and one oversized suite alongside a small suite. The
runtime subset is explicit because the full directory deliberately contains
trait-registration collision fixtures that cannot share one combined harness.
These entries fix the command, cache state, warmup and measured run counts,
supervisor timeout, and source inputs to fingerprint. They take the same
exclusive contention lease as comparison evidence, but deliberately have no
regression assessment or publication ceiling.

Result schema 2 replaces the duplicated `benchmark_policy` object with a
compact `registered_workload` object and removes `publication_ready`,
`publication_blockers`, `statistical_policy`, and derived `evidence_level`
fields. Consumers should use the registration's policy hash and optional
comparison assessment alongside the direct measurement and parity fields.

Run the dedicated shared-import fan-out characterization with its registered
settings:

```bash
scripts/bench-blorp-test-session \
  --baseline ./blorp \
  --baseline-label current \
  --workload shared-import-fanout \
  --pairs 3 \
  --warmup-pairs 1 \
  --timeout 180 \
  --cache-state isolated-warm \
  --input benchmarks/fixtures/blorp_test_session/shared_import_fanout \
  --output benchmarks/results/blorp_test_session_shared_import_fanout.json \
  -- test --timeout 60 \
    benchmarks/fixtures/blorp_test_session/shared_import_fanout/suite_01.brp \
    benchmarks/fixtures/blorp_test_session/shared_import_fanout/suite_02.brp \
    benchmarks/fixtures/blorp_test_session/shared_import_fanout/suite_03.brp \
    benchmarks/fixtures/blorp_test_session/shared_import_fanout/suite_04.brp \
    benchmarks/fixtures/blorp_test_session/shared_import_fanout/suite_05.brp \
    benchmarks/fixtures/blorp_test_session/shared_import_fanout/suite_06.brp \
    benchmarks/fixtures/blorp_test_session/shared_import_fanout/suite_07.brp \
    benchmarks/fixtures/blorp_test_session/shared_import_fanout/suite_08.brp
```

Characterization refuses altered settings or fingerprint inputs. Registered
characterization is baseline-only so its three-run sample cannot be mistaken
for balanced candidate evidence. Use the unregistered paired mode for
exploratory comparisons until an even-sample policy and workload-specific
thresholds are committed. Use `--allow-dirty` only for local smoke
measurements; retained baseline evidence must come from a clean revision.

Registered runs acquire the canonical per-user host compiler contention lease
exclusively and fail immediately while an official build/test gate holds its
shared lease. Its predictable `/tmp` namespace and lock file are owner-checked,
symlink-rejecting, and tightened to `0700`/`0600`. Registered runs reject the
test-only lock-base override. The lease is advisory: other users, unrelated
compiler invocations, and general machine load do not participate, so evidence
still requires an otherwise idle machine.

`isolated-cold` gives every route/run a fresh `BLORP_RUNTIME_CACHE` and is the
comparison default. `isolated-warm` gives each route a separate cache reused by
its warmup and measured runs and therefore requires at least one warmup pair.
Test command arguments do not control runtime cache state. Use `--input` for
shared source trees and `--baseline-input`/`--candidate-input` for
route-specific binaries, runtime libraries, or other explicit inputs; all are
hashed before and after the run. `--artifact-dir`
retains raw streams and per-run JSON even when validation fails. It must name a
new directory outside the measured worktree. Dirty worktree measurements
require `--allow-dirty` and are marked in the result; do not use them for
published speedup claims.

The benchmark driver's phase-local feedback loop is:

```bash
PYTHONDONTWRITEBYTECODE=1 \
  python3 -m unittest tests/test_blorp_test_session_benchmark.py
```

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
records, a source-interleaved internal heap record, compact explicit-enum
fields in an internal heap record, preserved enum and Boolean fields in
foreign-reachable heap records, and a value struct reachable from a foreign
signature. The runner appends a temporary layout reporter to the generated C;
it does not modify production sources or artifacts. Use it as the fast
feedback loop for representation work tracked in
`docs/COMPILER_PRIORITIES.md`.

`compiler_enum_field_layout` reproduces the Slice 8 source inventory and the
generated compiler-C structural comparison. Inventory mode is read-only and
does not compile C:

```bash
benchmarks/compiler_enum_field_layout --inventory
```

The default mode requires a current
`compiler/_build/blorp-cli/blorp_cli_main.c`. It compiles that exact artifact
and a temporary baseline that widens only its emitted one-byte explicit-enum
fields, then reports every target field and record:

```bash
benchmarks/compiler_enum_field_layout
```

### Record Update Allocations

`compiler_record_update_allocations` runs a bounded, uniquely owned heap-record
update loop through the production compiler and reports runtime allocation
counters:

```bash
benchmarks/compiler_record_update_allocations
BLORP_RECORD_UPDATE_SKIP_BUILD=1 \
  benchmarks/compiler_record_update_allocations
```

The normal invocation asserts the optimized one-allocation baseline. Override
`BLORP_RECORD_UPDATE_EXPECT_ALLOCATIONS` to lock in a new expected count. Set
`BLORP_RECORD_UPDATE_MEASURE_ONLY=1` while intentionally measuring an
optimization that is expected to change the count. Both probes always assert
their release and live-object baselines; use
`BLORP_RECORD_UPDATE_EXPECT_RELEASES` and
`BLORP_RECORD_UPDATE_EXPECT_CURRENT_OBJECTS` only when intentionally changing
those lifecycle counts.

`compiler_record_update_temporary_reuse_allocations` measures a nested update in
the same loop. The source form historically required one fallback allocation
per iteration after reusing the dead outer temporary: `100001` allocations and
`100000` releases for 100,000 iterations. Nested mutable self-updates now stage
their field values and reuse the original record once, so the probe asserts one
initial allocation, no loop releases, and one live result.

```bash
benchmarks/compiler_record_update_temporary_reuse_allocations
BLORP_RECORD_UPDATE_SKIP_BUILD=1 \
  benchmarks/compiler_record_update_temporary_reuse_allocations
```

`compiler_record_update_branch_allocations` measures alternating mutable
self-updates selected by an `if` expression. The source form historically
retained the old owner in both branches, causing `100001` allocations and
`100000` releases for 100,000 iterations. When every branch updates from the
same owner, the ownership preparation pass now transfers that owner within each
branch, so the probe asserts one initial allocation and no loop releases.

```bash
benchmarks/compiler_record_update_branch_allocations
BLORP_RECORD_UPDATE_SKIP_BUILD=1 \
  benchmarks/compiler_record_update_branch_allocations
```

`compiler_record_update_match_allocations` measures the same alternating
self-updates selected by an exhaustive Boolean `match`. Reuse is valid only
when every returning literal branch transfers the same mutable owner.

```bash
benchmarks/compiler_record_update_match_allocations
BLORP_RECORD_UPDATE_SKIP_BUILD=1 \
  benchmarks/compiler_record_update_match_allocations
```

`compiler_record_update_nested_match_allocations` exercises the projected
decision tree for nested constructor and literal patterns. Every nested leaf
must transfer the same mutable owner before the compiler can reuse it. The
record includes managed `String` fields so the probe also checks that retained
field aliases do not force fresh record allocations.

```bash
benchmarks/compiler_record_update_nested_match_allocations
BLORP_RECORD_UPDATE_SKIP_BUILD=1 \
  benchmarks/compiler_record_update_nested_match_allocations
```

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
The 2026-07-27 baseline and bottleneck analysis are recorded in
`results/compiler_frontend_profile_2026-07-27.md`, with raw elapsed samples in
the adjacent `.tsv` file.

The runner builds and directly uses the workspace production
compiler CLI artifact at `compiler/_build/blorp-cli/blorp`, invokes its public
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

### Isolated typechecking phases

`compiler_typecheck_phase_profile` measures one pure constructor from the
migrated Phase 1-3 typechecking architecture. It validates and retains the
complete phase chain once, then resets function-profile counters and repeats
only the requested stage. Fixture construction and result reporting are outside
the function-profile window.

```bash
benchmarks/compiler_typecheck_phase_profile indexed
benchmarks/compiler_typecheck_phase_profile importable 20 8 32 64 4
benchmarks/compiler_typecheck_phase_profile skeleton 20 8 32 64 4
benchmarks/compiler_typecheck_phase_profile headers 20 8 32 64 4
```

Available stages are `indexed`, `importable`, `bound`, `skeleton`, `aliases`,
`parameters`, `headers`, and `accepted`. Each run prints deterministic output
counts and a structural checksum in addition to setup and measured wall-clock
times. The checksum covers phase-owned identities and principal output shape;
it is a benchmark equivalence guard, not a complete serialization of retained
parsed AST. Focused phase tests remain the semantic authority.
`window_elapsed_microseconds` includes the begin/end transition so timing calls
remain outside the function-profile window. Use the same fixture dimensions
and iteration count for before/after comparisons.

### Known-Type Membership Profile

`compiler_known_type_index_profile` isolates prescan registration and repeated
ordinary/resource membership queries:

```bash
benchmarks/compiler_known_type_index_profile
benchmarks/compiler_known_type_index_profile 5 50 2048 2048
```

The positional controls are registration iterations, lookup iterations, names
per kind, and queries per kind. Duplicate registration is included and the
workload verifies that every resource type is also a known type while ordinary
types never acquire resource capability. The runner is optimized rather than
function-instrumented and skips rebuilding the compiler by default. Source
changes still invalidate its cached executable.

Use `alias` mode to isolate full alias expansion without parsing or graph-wide
typechecking work:

```bash
BLORP_TYPECHECK_PROFILE_SKIP_BUILD=1 \
  benchmarks/compiler_typecheck_profile 20 16 64 128 alias
```

In this mode the positional controls are iterations, alias-chain depth,
structural target depth, and resolutions per iteration. The
`ALIAS_RESOLUTION_PROFILE_BENCH` summary reports logical alias expansions and
result nodes. Pair those values with the profile call counts for
`env_resolve_alias_seen`, `apply_subst`, and
`compiler_env_copy_type` to distinguish required traversal from defensive
reconstruction. The fixture is deterministic and validates every resolved type
against the structural target.

Use `alias-register` mode to isolate the persistent-environment boundary that
stores transparent alias targets:

```bash
BLORP_TYPECHECK_PROFILE_SKIP_BUILD=1 \
  benchmarks/compiler_typecheck_profile 256 16 64 1 alias-register
```

The positional controls are iterations, aliases per fresh environment, and
structural target depth; the fourth numeric argument is ignored but retained so
the workload selector remains the fifth argument. Target construction is
excluded from elapsed time. The timed workload includes registration plus one
validating lookup and structural comparison per environment. The summary
reports logical registrations and the recursive copy nodes attributable to
baseline registration. Subtract candidate from baseline
`compiler_env_copy_type` calls to isolate those registration copies; the
remaining calls belong to validation.

### Import Graph Profile

`compiler_import_graph_profile` is the fast control for import-environment
work. Unlike `compiler_typecheck_profile`, it constructs real resolved import
edges. The default graph has 30 modules, 32 functions per module, and a fan-out
of 20, producing 420 resolved imports and 13,440 imported-function registration
opportunities per iteration:

```bash
benchmarks/compiler_import_graph_profile
benchmarks/compiler_import_graph_profile 3 30 32 20 fallback
```

The positional controls are iterations, module count, functions per module,
import fan-out, and parsed-program mode. The benchmark validates artifact,
declaration, resolved-import, and import-binding counts on every iteration and
prints `workload_valid=True` only when the complete graph matches those
invariants without type errors. Every generated module calls every imported
callable through its qualified module alias, so dropping or mis-registering an
imported signature fails the workload rather than appearing as a speedup.
Request construction is reported separately from measured graph typechecking.

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
counts from its generated shape. Those are not observed materialization
counters yet; Phase 6 adds those before this benchmark can prove that widening
a module does not materialize irrelevant bodies.

The optimized cached executable is the per-edit feedback loop. Compiler-source
changes require one cold rebuild; repeated samples then execute the cached
binary directly. Set `BLORP_COMPILER_BENCHMARK_SKIP_BUILD=1` after the artifact
exists to skip even the workspace build check. Use
`BLORP_CTFE_TYPECHECK_PROFILE_FUNCTIONS=1` only to attribute work inside
`prepare_ctfe_dependencies`, imported declaration registration, and body
materialization. Instrumented elapsed time is not comparable with the default
optimized result.

The baseline, prescan result, and profile interpretation are recorded in
`results/compiler_ctfe_typecheck_profile_2026-08-10.md`. Keep the narrow
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
`baseline_import_binding_comparison_pressure` describe the work performed by
the list-scanning implementation at the benchmark's introduction. They are not
required costs: elapsed and inclusive function time should fall when Phase 2
replaces those scans with graph-owned indexes, even when the number of semantic
lookup calls remains fixed. Use
`BLORP_MODULE_BINDING_PROFILE_FUNCTIONS=1` when exact function call counts are
needed; plain mode remains the fast comparison loop.

The compiler benchmark wrappers use `compiler_blorp_benchmark_runner` for
compiler selection, content-addressed artifacts, and native C flags.
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

### Typecheck Name Lookup Profile

`compiler_typecheck_name_lookup_profile` isolates the typecheck state's
top-level and imported-name indexes. It builds the state outside the timed
lookup region and validates hit and miss results on every iteration:

```bash
benchmarks/compiler_typecheck_name_lookup_profile
benchmarks/compiler_typecheck_name_lookup_profile 500 512 512
```

The positional controls are the starting iteration count, registered names of
each kind, and queries of each kind per iteration. The executable doubles the
iteration count until a calibration sample reaches 50 ms or the one-million
iteration cap, then reports the minimum, median, and maximum of five timed
samples. Setup and calibration time remain outside those samples.
`nanoseconds_per_lookup` normalizes comparisons when calibration selects
different iteration counts. The wrapper skips
rebuilding the full compiler because the workload imports the edited typecheck
source directly. Set
`BLORP_COMPILER_BENCHMARK_SKIP_BUILD=0` when the compiler executable itself
must be refreshed. Cached runs use an optimized uninstrumented executable; set
`BLORP_NAME_LOOKUP_PROFILE_FUNCTIONS=1` only when exact function rows are needed.

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

`compiler_type_ownership` is the fast preset for ownership work. It combines
bounded resource scans and `Self` resolution, performs two warmups and six
measured runs, and accepts trailing overrides:

```bash
benchmarks/compiler_type_ownership
benchmarks/compiler_type_ownership --runs 9 --self-resolution-depth 96
benchmarks/compiler_type_ownership \
  --bridge /tmp/candidate/compiler_typecheck_worker \
  --baseline-bridge /tmp/baseline/compiler_typecheck_worker
```

The runner uses `BLORP_TYPECHECK_BENCHMARK_WORKER` when it names an existing
worker. `--bridge PATH` overrides it. Otherwise, the runner builds a disposable
worker from `compiler/blorp/benchmarks/compiler_typecheck_worker.brp` with the
current `./blorp`. Worker construction is excluded from the reported time.
Results include SHA-256 digests of the worker and request so saved before/after
measurements remain auditable.

The benchmark CI workflow runs the smallest fixture without an override before
the standard suite. That smoke compiles and links the real worker, executes it,
and validates its streamed response on each benchmark platform.

`compiler_type_instantiation` is the fast preset for generic type
instantiation work. Its signatures combine unchanged, partially changed, and
fully changed recursive transforms in the same request:

```bash
benchmarks/compiler_type_instantiation
benchmarks/compiler_type_instantiation \
  --bridge /tmp/candidate/compiler_typecheck_worker \
  --baseline-bridge /tmp/baseline/compiler_typecheck_worker
```

### Captured Typecheck Replay

`compiler_typecheck_replay` runs one previously captured production
`typecheck_graph` request against an isolated benchmark worker. The former
OCaml-host capture hook was retired when production typechecking moved into the
public Blorp compiler. A replacement must be a structured compiler dump mode;
until that exists, the runner can replay existing local captures but cannot
create a new authoritative capture. Keep captures local because they contain
source text and local paths. First typecheck only the target while retaining its
full prepared graph context, then typecheck the complete selected module graph:

```bash
capture=/path/to/existing-typecheck-graph-request.json
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

This is the fast feedback loop for graph-retention work. With a prepared worker
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
per-object metadata table; `bytes_allocated` is the platform allocator's
process-wide in-use estimate. It still adds atomic traffic to every managed
allocation, so use either mode for attribution rather than headline timing
comparisons. Cumulative allocator-stat counts include worker startup; compare
checkpoints or module/phase deltas rather than interpreting them as an isolated
epoch.

For compile-execution memory profiles, set
`BLORP_COMPILER_MEMORY_PROFILE=1`. The compiler writes schema-1
`BLORP_COMPILER_MEMORY_CHECKPOINT` rows to stderr at `frontend_start`,
`frontend_complete` (or `frontend_stopped`/`frontend_failed`), `backend_complete`,
`artifact_write_start`, and `artifact_write_complete`. Each row includes a
monotonic timestamp, managed allocation/release/current-object counters,
allocator bytes, current RSS, and process peak RSS. Unsupported platform
measurements are `-1`; do not infer missing values. Compare checkpoint deltas
and global peak RSS together because allocator retention can keep RSS above the
managed live-object count. Command planning and source loading happen before
`frontend_start`, so these rows intentionally measure execution of an already
constructed compile plan rather than process startup or the entire CLI command.

On macOS, regular RSS sampling invokes `ps` every 20 ms and observes only the
helper leader process. This is appropriate for the current single-process
typecheck worker, but it perturbs elapsed time and would omit any future child
processes. Use the global peak as the memory comparison and treat per-phase
samples and macOS elapsed time as diagnostic.

### Captured Backend Replay

`compiler_backend_memory` replays one production `emit_core_c` request against
an isolated benchmark-owned backend worker. Capture mode writes the request and
deliberately stops before starting the worker:

```bash
capture=$(mktemp "${TMPDIR:-/tmp}/blorp-emit-core.XXXXXX.json")
BLORP_COMPILER_CAPTURE_EMIT_CORE_REQUEST="$capture" \
  ./blorp test --timeout 30 \
  compiler/blorp/tests/test_compiler_infer.brp
```

The capture command exits nonzero after reporting the saved path. Its test
timeout does not govern compilation; safety comes from capture mode stopping
before worker execution. Capture still runs the compiler frontend and middle
once and materializes the serialized request. Keep captured requests local:
they contain the lowered program and source paths, can be large, and should not
be committed.

Replay a bounded request with:

```bash
benchmarks/compiler_backend_memory "$capture" --timeout 60
benchmarks/compiler_backend_memory "$capture" --timeout 60 --json
benchmarks/compiler_backend_memory "$capture" --timeout 60 --vmmap
```

For source-location representation work, generate a deterministic bounded
request containing 10,200 known Core locations instead of capturing a full
compiler build:

```bash
request=$(mktemp "${TMPDIR:-/tmp}/blorp-core-source-loc.XXXXXX.json")
./blorp run --no-format \
  compiler/blorp/benchmarks/compiler_core_source_loc_request.brp >"$request"
benchmarks/compiler_backend_memory "$request" --timeout 60
```

The fixture emits the same backend bridge envelope as a production capture and
keeps function count, tree shape, and generated C stable across layout changes.

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
and moderately sized function bodies, sends it through the production
`run_perceus` bridge action, validates the resulting Core, and reports request
and artifact hashes, elapsed time, and peak memory. Each function reads 32
globals by default so the fixture measures both reference discovery and the
width of the global table:

```bash
benchmarks/compiler_perceus_memory
benchmarks/compiler_perceus_memory --globals 24
benchmarks/compiler_perceus_memory --globals 384
benchmarks/compiler_perceus_memory --global-reads-per-function 0
```

The function count, body shape, and referenced-global count stay fixed when
varying `--globals`, isolating the cost of irrelevant globals beyond the
referenced set. Set `--global-reads-per-function 0` to measure bodies with no
global references. The runner uses `BLORP_BACKEND_BENCHMARK_WORKER` when it
names a prepared worker; otherwise it builds the benchmark-owned worker before
starting measurement. Worker construction is excluded from the reported time.

On macOS, all compiler memory diagnostics accept `--vmmap` to sample physical
footprint, `MALLOC_SMALL`, and allocation count when `vmmap` exposes those
fields:

```bash
benchmarks/compiler_typecheck_memory --vmmap
benchmarks/compiler_backend_memory captured-request.json --vmmap
benchmarks/compiler_perceus_memory --vmmap
```

The default action hashes the Core artifact produced by the isolated worker
route through Perceus. This excludes reuse and C emission, but includes worker
startup, Core JSON decoding/encoding, and the ownership-preparation stages
immediately before Perceus. Use `--end-to-end` to retain the older integration
measurement through generated C.

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
request and worker hashes, and a stable artifact hash. Durable baseline results
belong under `benchmarks/results/`.

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
