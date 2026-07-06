# Test Speed Roadmap

Status checked against code on 2026-07-06.

This roadmap captures the current test-speed diagnosis and the intended path to
make normal test runs faster by doing less duplicate work. The goal is not to
hide failures behind caches or looser gates. The goal is to keep the normal loop
focused, move expensive broad sweeps to explicit deep/premerge gates, and remove
test harness structure that repeatedly crosses process, compiler, and bridge
boundaries without adding proportional signal.

## Current Diagnosis

The default local gate is slow for two related reasons: it does too much broad
integration work by default, and running every top-level gate at once
oversubscribes the machine.

Recent measurements on this branch showed:

- A warm default `scripts/test` run took 9m15s wall time. Individual gate times
  were much worse under contention: compiler-unit 8m55s, runtime 6m59s,
  compiler 6m16s, CLI 4m19s.
- The same gates are materially faster in isolation. Runtime alone took 2m07s
  gate time. Compiler alone took 4m17s gate time. Compiler-unit alone took about
  4m18s.
- The compiler fixture gate is highly CPU-bound: the isolated compiler gate used
  about 2034 seconds of user CPU for 4m17s of wall time. Running it beside
  runtime and compiler-unit slows the other gates substantially.
- Compiler-unit used to be one serial Alcotest executable containing both
  phase-local unit tests and broader internal integration tests. It is not the
  only problem, but it became the longest tail when run under full-gate
  contention.
- Before the CLI split, CLI smoke was broader than command-surface smoke: it
  covered package fetch/vendor flows, compile/run/test, formatter tooling, REPL,
  and LSP.
- Bridge helper preparation still costs roughly 16-21 seconds per `scripts/test`
  run when helper binaries are prepared into a fresh startup directory.

## Principles

- Prefer doing fewer things over adding opaque caches.
- Keep fast local checks semantically meaningful, not merely shallow.
- Keep expensive coverage available, but make it explicit when it is broad,
  redundant, or premerge-oriented.
- Do not weaken failure checks just to reduce wall time.
- Avoid hidden duplicate sweeps, especially when one gate silently retests a
  corpus already owned by another gate.
- When a test shells out, it should be because the process boundary is the
  behavior under test or because no in-process interface exists yet.

## Target Test Shape

`scripts/test` should become the normal fast confidence gate:

- Compiler unit tests that are genuinely unit-level.
- Parser, infer, and typecheck compiler tests through in-process runners.
- Runtime/std tests, with slow process-heavy tests kept narrow and intentional.
- CLI smoke for public command behavior.
- A small, representative codegen audit subset.
- A small, representative formatter/purify CLI surface check.

Deep or premerge gates should own broad sweeps:

- Full codegen audit.
- Full formatter corpus validation if it remains useful.
- Broad package lifecycle integration.
- Any large generated-C warning sweep.
- Expensive `compiler/blorp/tests` subsets that are not needed in every local
  iteration.

## Active Roadmap

### 1. Split Fast and Deep Compiler Gates

Add explicit gate names instead of making `compiler` mean every compiler-related
thing.

Proposed shape:

- `scripts/test compiler` runs parser, infer, and typecheck surface fixtures.
- `scripts/test compiler-deep` runs full codegen audit, formatter/purify tool
  fixtures, and broad compiler-owned integration sweeps.
- `scripts/test premerge` or the existing premerge script runs both fast and deep
  gates.

Expected impact: minutes saved on local runs, because full codegen audit is one
of the largest sources of subprocess and C compiler work.

Correctness guardrail: every test removed from the default compiler gate must
move to a named deep/premerge gate unless it is obsolete or duplicate.

### 2. Remove Hidden Formatter Duplication

Formatter coverage should have one clear owner.

Keep:

- Focused `format/should_pass`, `format/should_fail`, and `format/should_error`
  fixtures.
- A small CLI smoke proving `blorp format` formats a representative file and
  `--check` accepts it.
- Formatter tool command parsing tests if the standalone tool remains supported.

Avoid:

- Running formatter roundtrip over every parser fixture.
- Running full std formatting from CLI smoke.
- Running full formatter-source formatting from CLI smoke.
- Running corpus-level formatter checks in both compiler and CLI gates.

Expected impact: fewer `blorp format` subprocesses and a clearer ownership model.

Follow-up quality issue: `format/should_fail/wrapped_string_literals.brp`
exposed a formatter idempotence bug where the first format wraps strings and the
second format inserts blank lines. Fix that as a formatter behavior change, not
as part of test harness cleanup.

### 3. Move Formatter and Purify Tests In Process or Batch Them

Formatter and purify tool fixtures live in `compiler-deep`, not the default
compiler gate. They still shell out because the public CLI is the available
interface.

Preferred long-term shape:

- Expose formatter check/format entry points to the compiler test runner without
  launching `./blorp` per file.
- Expose purify dry-run/rewrite entry points similarly, or add a batch command
  that handles many files in one compiler process.
- Keep only a few CLI-level formatter/purify checks in `tests/test_cli.sh`.

Expected impact: reduces hundreds of small compiler subprocesses while retaining
the same fixture coverage.

### 4. Make Codegen Audit Two-Tiered

Full codegen audit is valuable, but expensive.

Fast default:

- Select a representative subset covering the warning classes and codegen areas
  most likely to regress.
- Keep the subset explicit and named, not random.

Deep/premerge:

- Run the full codegen audit corpus.
- Keep the full generated-C warning sweep here.

Expected impact: large local speedup. Full codegen audit remains available before
merge and release.

### 5. Batch Compiler Blorp Bridge Work

`compiler/blorp/tests` are architecturally important, but expensive because they
exercise the Blorp-owned compiler surface through parser, CLI frontier,
bridge/rendering, and Core-tail paths.

Improve by:

- Batching related bridge requests inside a single helper process.
- Reusing long-lived helper processes within a test run where safe.
- Avoiding repeated startup and renderer initialization inside tight assertion
  loops.
- Keeping the bridge protocol explicit and deterministic.

Expected impact: reduces CPU and process overhead without deleting Blorp-owned
compiler coverage.

### 6. Reuse Prepared Bridge Helpers

The bridge helper content-addressed cache already exists. The explicit
`__compiler-bridge-prepare` path now uses it instead of recompiling helper
binaries into a fresh startup directory on every `scripts/test` invocation.
Preparation still copies verified helpers into the run-local directory so the
test harness can set explicit prepared-helper paths and fail loudly if those
paths are lost.

Expected impact: roughly 16-21 seconds saved on warm test runs.

Correctness guardrail: helper reuse must be keyed by helper source, compiler
binary, relevant std/compiler sources, compile flags, and platform facts that
affect the helper binary.

### 7. Reduce Full-Run Oversubscription

The full gate used to run every selected top-level gate in parallel, while some
of those gates also ran internal workers. That was simple in the shell but
expensive in practice: runtime and compiler-unit became several times slower
when competing with the CPU-heavy compiler fixture runner.

The current approach is deliberately simpler than a scheduler:

- Run selected gates in fixed waves: `compiler-unit`, `compiler-unit-deep`,
  `compiler`, `compiler-deep`, `runtime`, then `leak + doctest + cli`.
- Keep each gate responsible for its own internal strategy.
- Do not infer CPU needs from names, timings, or machine load.

Expected impact: more predictable full-run behavior and fewer timeout flakes
under load. This may trade some best-case wall time for clarity until the
default gate is slimmed down further.

### 8. Keep Runtime Process Tests Narrow

Runtime/std tests currently have a small number of subprocess call sites. Most
are justified because they test process, system, signal, or IO behavior.

Keep them narrow:

- Process API tests should cover behavior directly, not compiler behavior.
- IO tests that need stdin/stdout should use one generated program where possible.
- Avoid nested `./blorp` calls in runtime tests unless the CLI/process boundary is
  genuinely the behavior under test.

Expected impact: keeps runtime tests from regrowing the previous nested compiler
property-test problem.

## Completed Slice

The first high-leverage split is implemented:

1. `scripts/test compiler` runs fast parser, infer, and typecheck surface
   fixtures without bridge-helper preparation or the broad std typecheck
   preflight.
2. `scripts/test compiler-deep` runs the full generated-C audit, formatter and
   purify tool fixtures, and compiler-owned Blorp TestSuites explicitly.
3. `scripts/premerge-gate` includes both gates, so premerge coverage still pays
   for the full audit, format/purify coverage, and compiler-owned Blorp
   coverage.
4. The runner docs and command references expose the distinction.
5. `tests/test_compiler/run_compiler_tests.sh` is now a thin wrapper around a
   test-only Dune executable; the shipped `blorp` CLI no longer exposes
   compiler fixture plumbing.
6. The compiler runner now terminates active worker processes on SIGTERM/SIGINT,
   and `scripts/test` failure excerpts include infrastructure errors such as
   `Error:` lines instead of printing an empty failure block.
7. Multi-gate `scripts/test` now uses fixed waves instead of launching every
   selected gate at once. The reason is predictability: the heavyweight gates
   already perform internal parallel work, so the top-level harness should avoid
   making contention worse instead of becoming a second scheduler.
8. `scripts/test cli` is now smoke-only, while `scripts/test cli-deep` preserves
   the full package lifecycle and formatter-tool integration coverage for
   premerge. The reason is ownership clarity: checking public command contracts
   is a different job from exercising package cache/vendor workflows and
   compiling the self-hosted formatter tool.
9. `__compiler-bridge-prepare` now resolves renderer/parser helpers through the
   shared content-addressed cache before copying them into the run-local startup
   directory. The cache key now also includes `std/` sources, because helper
   generated C can depend on shipped std code as well as compiler-owned Blorp
   sources. A warm `scripts/test cli` run after this change reported `bridge
   prepare 0s`, down from a 19s cold prepare after the cache-key change.
10. `scripts/test compiler-unit` now runs only phase-local, unit-shaped
    Alcotest suites. Session, LSP, package, pipeline, test-runner, compiler
    fixture-runner, and compiler bridge suites moved to the explicit
    `compiler-unit-deep` gate. The reason is not deletion of coverage; it is
    ownership clarity. These tests cross process, session, module graph,
    runtime execution, or bridge boundaries and belong in an internal
    integration gate that premerge still runs.
11. `scripts/test --timings` now enables opt-in per-case timing for
    `compiler-unit` and `compiler-unit-deep`. The runner prints the slowest
    cases and writes stable `BLORP_COMPILER_UNIT_TIMING` records into logs, so
    future speed work can be based on measured slow cases instead of moving
    suites by intuition.
12. Package-cache tests now build valid `.blorpkg` fixtures directly from
    package entries instead of first running full source-package validation and
    then asking `Package_cache.fetch` to validate the unpacked cache contents
    again. The cache behavior is still covered by `Package_cache.fetch`; the
    removed work was duplicate setup.
13. Several compiler-unit inventory tests now share source walks/parses inside
    the test executable. This keeps the broad architecture assertions intact
    while avoiding repeated fixture work in `TypeBoundaryHygiene`,
    `BuiltinConsistency`, and `OperationResultMetadata`.
14. The std inventory in `BuiltinConsistency` now uses the existing parser
    bridge batch API, so it parses all std sources in one request instead of one
    bridge call per file. The `TypeBoundaryHygiene` source-scan helper now
    compares tokens in place instead of allocating a fresh substring at every
    candidate offset.
15. Compiler surface typecheck fixtures now reuse one worker-local frontend
    session per runner worker. Each case resets all semantic compilation state
    before typechecking, but preserves the validated parse cache, so std and
    imported module parse artifacts can be reused without leaking impls, UFCS
    methods, module caches, package config, std override state, inference metas,
    or fresh ids across independent fixtures.

This removes the largest redundant default-local sweep without deleting the
coverage.

Latest measurement after moving formatter/purify tool fixtures out of the
default compiler gate:

- `BLORP_TEST_LOCK_HELD=1 scripts/test compiler --serial`
- 1,483 passed, 0 failed
- 3m35s compiler gate time
- 4m39s wall time, including 1m04s std preflight
- 0s bridge-helper preparation

Follow-up after dropping std preflight from compiler-only runs:

- `BLORP_TEST_LOCK_HELD=1 scripts/test compiler --serial`
- 1,483 passed, 0 failed
- 3m05s compiler gate time
- 3m06s wall time
- 0s bridge-helper preparation
- 0s std preflight

Deep compiler gate measurement:

- `BLORP_TEST_LOCK_HELD=1 scripts/test compiler-deep --serial`
- 981 passed, 0 failed
- 3m45s compiler-deep gate time
- 4m03s wall time, including 16s bridge-helper preparation and 1s cached std
  preflight

Post-wrapper-simplification verification:

- `BLORP_TEST_LOCK_HELD=1 scripts/test compiler --serial`
- 1,483 passed, 0 failed
- 3m35s wall time
- 0s bridge-helper preparation
- 0s std preflight

Compiler-unit split verification:

- `scripts/test compiler-unit --timings --log-dir scratch/test-unit-timings-default-20260706-final`
- 1,847 passed, 0 failed
- 1m55s compiler-unit gate time
- 0s bridge-helper preparation
- 0s std preflight
- Current slowest cases are inventory-style assertions over std/builtins/type
  boundaries. They should stay measured before any further cleanup, because they
  are validating broad compiler invariants rather than ordinary local helpers.

Compiler-unit verification after shared inventory fixtures:

- `scripts/test compiler-unit --timings --log-dir scratch/test-unit-timings-inventory-cache-20260706`
- 1,847 passed, 0 failed
- 1m55s compiler-unit gate time
- `OperationResultMetadata.std_operation_result_builtins_are_public_direct`
  dropped out of the slow-case list after caching parsed std declarations. The
  remaining top cases still perform one broad std parse or one broad compiler
  source scan, so the total wall time did not materially move.

Targeted inventory follow-up:

- `BuiltinConsistency.prelude_entries :: public ABI types have std anchors`
  dropped from about 2.2s to about 1.47s after switching the std inventory to
  the parser bridge batch API.
- `TypeBoundaryHygiene.boundaries :: late layout fallbacks stay inventoried`
  dropped from about 1.7s to about 0.48s after removing allocation-heavy
  substring checks from the source-scan helper.

Compiler-unit verification after batched std inventory and faster source scans:

- `scripts/test compiler-unit --timings --log-dir scratch/test-unit-timings-batch-and-token-20260706-final`
- 1,847 passed, 0 failed
- 1m54s compiler-unit gate time
- `TypeBoundaryHygiene` dropped out of the top slow-case list. The broad std
  inventory still appears around 2.2s in the full run, likely because it still
  performs one real parse of every std source file.

Compiler fixture batching probe:

- A worker-local parser-batch cache for compiler surface fixtures passed all
  1,483 tests, but measured `real 253.94s`, `user 1979.01s`, `sys 74.57s`.
- A parent-level parser-batch cache also passed all 1,483 tests, but measured
  `real 276.93s`, `user 2172.11s`, `sys 79.51s`.
- Both are worse than the prior `scripts/test compiler` checkpoint around
  3m05s wall time. Parser batching alone is therefore not the right lever for
  this runner: it reduces bridge request count but loses too much parallelism
  and leaves typecheck/module work dominant.
- Do not reintroduce fixture parser batching unless it is paired with a larger
  in-process batch typecheck/module-loading design and measured against the
  full compiler surface gate.

Compiler fixture reusable typecheck-session verification:

- `scripts/test compiler --log-dir scratch/test-compiler-reusable-typecheck-20260706`
- 1,483 passed, 0 failed
- 1m15s compiler gate time
- 1m16s wall time
- 0s bridge-helper preparation
- 0s std preflight
- Direct runner measurement for the same surface corpus:
  `real 74.38s`, `user 570.31s`, `sys 22.13s`.
- This is the batching boundary that paid off. Parser-only batching reduced
  bridge calls but regressed wall time; reusing the typecheck session preserves
  parallel workers while avoiding repeated parse/module setup inside each
  worker.

Compiler-unit deep verification:

- `scripts/test compiler-unit-deep --log-dir scratch/test-unit-split-deep-20260706`
- 309 passed, 0 failed
- 4m21s compiler-unit-deep gate time
- 0s bridge-helper preparation
- 0s std preflight

Compiler-unit deep timing after direct package-cache artifacts:

- `scripts/test compiler-unit-deep --timings --log-dir scratch/test-unit-deep-timings-package-cache-after-20260706`
- 309 passed, 0 failed
- 1m57s compiler-unit-deep gate time
- The previous package-cache slow cluster moved from roughly 2.0-2.4s per case
  to roughly 1.2-1.6s per case.
- The current slowest cases are LSP/module/package source-policy integration
  coverage and one combined TestSuite harness regression. Those remain explicit
  deep coverage until there is a narrower in-process assertion that preserves
  the behavior being tested.

Compiler-unit deep verification after reusable typecheck-session coverage:

- `scripts/test compiler-unit-deep --log-dir scratch/test-unit-deep-reusable-session-20260706`
- 312 passed, 0 failed
- 1m48s compiler-unit-deep gate time

## Recommended Next Slice

Continue with the next low-risk cleanup:

1. Keep formatter/purify fixtures in `compiler-deep` until there is an
   in-process or batched interface that reduces work instead of hiding it.
2. Use `scripts/test compiler-unit-deep --timings --log-dir scratch/...` before
   changing any remaining deep cases. Prefer narrowing duplicated fixture setup
   over replacing end-to-end assertions with constants or mocks.
3. If batching remains the next focus, target another real duplicate-work
   boundary with an explicit reset contract. The successful compiler fixture
   slice worked because the preserved state was named narrowly: parse cache
   only. Avoid broad caches that cannot state what they preserve and clear.
4. Consider a small explicit fast subset for codegen audit if local default
   runs still need more reduction after the compiler-unit split.

## Success Metrics

- Normal `scripts/test compiler` avoids full codegen audit, bridge-helper
  preparation, std preflight, format/purify tool fixtures, and broad
  compiler-owned Blorp sweeps.
- Default full `scripts/test` avoids pathological gate contention without adding
  adaptive scheduling logic.
- Deep/premerge still runs the expensive coverage explicitly.
- Test summaries make it obvious which expensive coverage did or did not run.
- Runtime/std tests do not contain broad nested compiler tests.
- CLI smoke remains focused on public command behavior instead of corpus sweeps.
