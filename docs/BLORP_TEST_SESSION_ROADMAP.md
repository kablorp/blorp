# Blorp-Owned Test Command Roadmap

## Goal

Make `blorp test` a Blorp-owned command with a short, explicit execution path:

1. enumerate and canonicalize candidate source paths once;
2. parse each source once inside an explicitly owned frontend partition;
3. retain that graph while materializing compatible TestSuite and doctest artifacts;
4. discover the host and prepare runtime inputs once;
5. compile compatible tests into direct combined artifacts and execute them serially;
6. aggregate artifact outcomes while preserving original output and stopping
   on infrastructure failure or interruption.

The objective is to remove the OCaml test route and its tooling, not to build a
persistent compiler daemon or a distributed test scheduler.

## Architectural Decision

The command remains serial for now. Session-local reuse belongs in the normal
CLI planning and effect boundaries rather than in a second test-session
framework.

This deliberately excludes:

- selector arguments and selector harnesses;
- parent/child control protocols;
- report spools;
- implicit filesystem-isolation policy;
- persistent compiler processes;
- parallel scheduling.

The command uses direct combined binaries with statically imported targets.
The public default retains measured eight-source and 512 KiB partitions so
unrelated source surfaces do not unexpectedly become one module graph. The
`--maximal-artifacts` option removes those size limits for a corpus already
qualified to coexist. It is rejected when sanitizers are active. Repeated root
module names always establish a boundary.

## Current Architecture

### Discovery

`cli_test_discovery.brp` first expands requested files and directories into a
small canonical-path descriptor list. Parsing and structural TestSuite/doctest
classification happen only when the owning frontend partition is built. Helper-only
files are discarded before graph construction. Discovery does not typecheck or
execute code.

Leak-baseline path recognition is isolated in
`cli_test_leak_baseline.brp`. It is a path policy, not a general test-isolation
model.

### Frontend Graph Ownership

`cli_test_plan.brp` retains only canonical candidate paths and their root module
identities for a `blorp test` invocation. `cli_main.brp` uses bounded partitions
by default and when sanitizers are active. `--maximal-artifacts` explicitly asks
it to retain all uniquely named roots in one ownership partition, starting a new
partition only before a repeated root module identity. Each partition graph contains:

- every discovered source selected by the command mode;
- generated doctest roots for sources that contain doctests.

Generated doctest roots import the already retained original source. Exact
canonical source keys are stored in the partition so materialization does not need
to rediscover, reread, or reparse source files.

Each runnable artifact receives a projection of its partition graph using retained
root identities. The projection preserves resolved module edges and
standard-library surfaces while limiting later compiler work to compatible
targets.

This is invocation-local ownership. No graph survives after the command exits,
so there is no cache invalidation or stale-process protocol.

### TestSuite Harnesses

`cli_generated_test_harness.brp` emits one direct harness for the compatible
TestSuite roots in a frontend partition:

```text
partition TestSuites -> generated main -> run_suite(T0.tests), run_suite(T1.tests), ...
```

The harness aggregates exact `(passed, failed)` results. There is no runtime
selector or run-all dispatch table; all target identities are static generated
imports.

### Doctests

Doctest source is generated and parsed while its frontend partition is built. Its
module edge to the source under test resolves inside the same retained graph.
Every generated doctest module exposes a typed `(passed, failed)` runner; a
direct harness invokes those runners and emits one exact aggregate result.

### Host And Runtime Reuse

`cli_main.brp` establishes these resources once for the whole test invocation:

- one signal broker;
- one host-toolchain discovery result;
- one runtime source configuration;
- one runtime-cache preparation result or embedded-runtime fallback.

`cli_test_effect.brp` passes the immutable runtime input into every serial
artifact execution. `cli_run_effect.brp` exposes the corresponding prepared-run
boundary while preserving the ordinary `run` command behavior.

Frontend partitions remain separate native executables. Direct leak-baseline
programs remain individual artifacts. Required Ubuntu CI supplies two
byte-balanced compiler-source shards in parallel; `scripts/test compiler-blorp`
explicitly selects maximal artifacts so each shard is one frontend partition
and one generated executable.

### Failure And Interruption Semantics

Invocation planning fails before execution for path and environment errors.
Parsing, generated doctest construction, and graph validation fail at the
owning partition boundary before that partition executes. During execution:

- compilation failures retain compiler stdout and stderr;
- child failures retain child stdout and stderr;
- captured child output is bounded by the configured capture limit;
- completed test artifacts continue serially so later suites still report;
- any failed artifact makes the final command status nonzero;
- planning, compilation, output-forwarding, and runtime-preparation failures stop
  the invocation because later results would not be trustworthy;
- a received signal interrupts runtime preparation or the current artifact and
  stops later artifacts;
- the invocation-wide signal broker is always restored on exit.

These semantics must stay aligned with the normal compile/run effect path.

## Incremental Delivery

### Slice 1: Direct Serial Route - Complete

- Route ordinary TestSuite and doctest requests through Blorp.
- Generate a direct single-suite harness.
- Compile and execute each materialized artifact serially.
- Keep unsupported modes on the transitional route until represented
  explicitly.

### Slice 2: Invocation-Local Reuse - Complete

- Retain parsed original and generated roots within owned frontend graphs.
- Project per-artifact graphs from retained identities.
- Discover the host once.
- construct runtime sources once;
- prepare the runtime cache or embedded fallback once;
- share one signal broker across the invocation.

### Slice 3: Remove Superseded Session Machinery - Complete

- Remove selector-driven combined harness planning and lowering.
- Remove selector and mixed-session drivers.
- Remove report-spool adapters.
- Remove compiler-owned process-control transport and its Core operation
  metadata.
- Remove tests that only specified those abandoned mechanisms.

### Slice 4: Close Remaining Behavior Gaps - Complete

- Resolve CLI and environment timeout, sanitizer, and leak-check policy inside
  Blorp.
- Reuse the normal profile, debug, sanitizer, std-directory, and runtime-cache
  compile/run boundaries.
- Execute explicit repeats inside one invocation.
- Support direct leak-baseline programs without treating arbitrary `main`
  programs as tests.
- Emit the structured gate result consumed by `scripts/test`.
- Resolve `tests` through the loaded std-module identity before admitting a
  source to a generated `TestSuite` harness.
- Preserve executable-module doctests, generated-doctest source origins, and
  public global scope.
- Pool timeout and capture budgets by source count and retain cumulative counts
  when a combined artifact exits abnormally.
- Make warmup populate the same shared runtime cache used by test artifacts and
  fail when cache publication is unavailable.

The route remains deliberately serial and read-only. It has no parallel
scheduler, per-test result cache, or implicit test-time formatter, so the CLI
does not expose controls for those nonexistent behaviors.

### Slice 5: Production Cutover - Complete

- `CliRunTest` executes only in `cli_main.brp`.
- Test plans cannot be serialized through `cli_artifact_json.brp`.
- The OCaml bridge has no test command or test option decoder.
- `blorp_ocaml_host` has no test dispatch, harness, warmup, or execution path.
- CLI smoke exercises suites, doctests, leak mode, repeats, environment policy,
  gate summaries, and warmup with a missing OCaml host.
- The current-source stage-two gate requires the same no-host route.

A clean build therefore cannot silently fall back to the OCaml test
implementation. The retired OCaml `Test_runner` harness, transitional compiler
fixture runner, all OCaml test execution wiring, and the Alcotest dependency
have been removed. Historical `compiler/test/test_*.ml` sources remain as a
non-executable archive whose disposition is tracked in
`docs/OCAML_TEST_COVERAGE_LEDGER.tsv`. Public `.brp` fixtures,
compiler-owned Blorp TestSuites, doctests, and CLI integration tests cover the
replacement route. Session benchmark counters are emitted from the Blorp-owned
partition plan and describe its retained source graph and generated artifacts.

### Slice 6: Combined Artifacts - Complete

- Retain compact canonical path descriptors instead of every parsed source for
  the full invocation.
- Parse, classify, and build one frontend graph for each owned source partition.
- Split earlier when two requested roots have the same module identity, so
  same-named suites in different directories remain independently importable.
- Keep the measured bounded policy as the public default and for sanitizer artifacts.
- Expose maximal artifacts as an explicit opt-in for qualified corpora such as
  the compiler-owned TestSuites.
- Compile compatible TestSuite roots into one direct aggregate harness.
- Expose typed doctest runners and compile them into one direct aggregate
  harness per frontend partition.
- Preserve exact case counts through aggregate machine records.

Local macOS measurements on 2026-08-08:

- 37 runtime sources: 61.2 seconds / 3.44 GB before combined artifacts, 15.5
  seconds / 600 MB after;
- 1,053 std doctests: 81 seconds / 5.42 GB before doctest batching, 13 seconds /
  1.18 GB after, excluding unchanged build setup.

## Fast Feedback

Use the smallest relevant case while editing:

```bash
./blorp test --timeout 30 \
  compiler/blorp/tests/test_compiler_cli_test_plan.brp

./blorp check --no-format \
  compiler/blorp/src/stage_12_cli/cli_test_effect.brp
tests/test_cli_stage_two.sh --timeout 90
```

Before merging a route change, run:

```bash
make
scripts/test compiler-blorp compiler-tools runtime cli
tests/test_compiler/codegen_audit/run_codegen_audit.sh ./blorp
```

Use the registered workloads in `scripts/bench-blorp-test-session` for recorded
before/after samples on the same host and compiler fingerprint.

## Test Strategy

### Planner Tests

Cover:

- file and directory discovery;
- canonical aliases and duplicate inputs;
- mixed TestSuite/doctest sources;
- generated doctest imports resolving to the retained original module;
- source deletion after partition construction, proving materialization uses retained data;
- incompatible standard-library or package contexts across roots;
- malformed generated roots and graph failures.

### Harness Tests

Cover:

- parseable generated source;
- exact static import modules and bindings;
- direct aggregate `run_suite` and typed doctest-runner selection;
- exact aggregate case counts;
- absence of selector parsing and dispatch tables.

### Effect Tests

Cover:

- shared prepared runtime input across multiple partition artifacts;
- cache fallback chosen once per invocation;
- bounded stdout/stderr capture;
- compile failure, child failure, timeout, and signal propagation;
- continued execution after ordinary test failures;
- no execution after an infrastructure failure or interruption.

### End-To-End Tests

The stage-two CLI test must exercise a compiler built from current Blorp source,
not only the pinned bootstrap executable. It should include:

- one TestSuite file;
- one doctest file;
- a directory containing both;
- a failing suite with stable exit status;
- timeout and signal cleanup;
- isolated cold- and warm-runtime-cache paths where supported.

Linux CI must retain the process-session timeout tests because process-group and
pipe-drain behavior differs from macOS.

## Invariants

- Source identity is canonical and explicit; no basename or string-prefix
  guessing is allowed for module ownership.
- Roots with incompatible standard-library or package contexts are rejected at
  their partition boundary before that partition executes.
- Invocation planning owns compact immutable paths; each active partition owns its
  immutable parsed sources and graph until partition execution completes.
- Materialization may project or add a direct harness but may not reread an
  original source.
- Host and runtime preparation happen at most once per test invocation.
- An artifact is compiled through the ordinary compiler pipeline.
- Native subprocesses exist only for compiled test execution and required host
  compilation steps.
- Captured native output is bounded by the command's configured limit.
- Unsupported behavior fails or routes explicitly; there is no silent semantic
  downgrade.

## Deferred Performance Work

Profile the direct serial route before adding architecture. The likely next
opportunities are releasing compiler pipeline allocations earlier, retaining
immutable standard-library surfaces across exceptional frontend partitions, runtime object
reuse across invocations, and reducing native linker startup.
Each requires measured evidence and a precise ownership boundary. Parallelism
and persistent daemons remain deferred because they introduce cancellation,
cache invalidation, and stale-state complexity before the simpler route has
been measured.
