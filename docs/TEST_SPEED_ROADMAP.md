# Test Speed Roadmap

This roadmap captures the current test-speed diagnosis and the intended path to
make normal test runs faster by doing less duplicate work. The goal is not to
hide failures behind caches or looser gates. The goal is to keep the normal loop
focused, move expensive broad sweeps to explicit deep/premerge gates, and remove
test harness structure that repeatedly crosses process, compiler, and bridge
boundaries without adding proportional signal.

## Current Diagnosis

The chief culprit is the compiler gate.

Recent measurements on this branch showed:

- Runtime/std tests are no longer the dominant issue. They are still substantial,
  but most remaining subprocess use there directly tests process, system, IO, or
  runtime behavior.
- CLI smoke is mostly command-surface integration. It should stay small and
  should not own broad formatter/std corpus sweeps.
- Compiler surface tests without codegen audit took about 216 seconds wall time
  and about 1793 seconds of user CPU. That makes the compiler gate highly
  CPU-bound even before the full generated-C audit is added.
- Full codegen audit adds one Blorp compile plus one host C compiler invocation
  per audit file. At the time of measurement, that was 193 Blorp compiles and
  193 `cc` invocations.
- `compiler/blorp/tests` are important for expanding Blorp's compiler footprint,
  but they are expensive because they do substantial bridge/rendering/compiler
  work.
- Bridge helper preparation still costs roughly 16-21 seconds per `scripts/test`
  run when it recompiles helper binaries instead of reusing the existing
  content-addressed helper cache.
- Running all gates concurrently can oversubscribe the machine because several
  gates also parallelize internally.

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

## Roadmap

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

The compiler runner still shells out for formatter and purify cases because the
public CLI is the available interface.

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
exercise the Blorp-owned compiler surface through bridge/rendering paths.

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
`__compiler-bridge-prepare` path should use it instead of recompiling helper
binaries into a fresh startup directory on every `scripts/test` invocation.

Expected impact: roughly 16-21 seconds saved on warm test runs.

Correctness guardrail: helper reuse must be keyed by helper source, compiler
binary, relevant std/compiler sources, compile flags, and platform facts that
affect the helper binary.

### 7. Reduce Full-Run Oversubscription

The full gate currently runs multiple top-level gates in parallel, and some of
those gates also run internal workers.

Improve by:

- Capping per-gate worker counts when multiple gates run together.
- Avoiding concurrent execution of the heaviest CPU-bound gates.
- Reporting both gate wall time and aggregate user CPU so oversubscription is
  visible.

Expected impact: better full-run wall time and fewer flaky timeout failures under
load.

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
5. `tests/test_compiler/run_compiler_tests.sh` is now a thin wrapper around
   `blorp __compiler-tests`; the old duplicate shell runner and legacy env
   escape are removed.
6. The compiler runner now terminates active worker processes on SIGTERM/SIGINT,
   and `scripts/test` failure excerpts include infrastructure errors such as
   `Error:` lines instead of printing an empty failure block.

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

## Recommended Next Slice

Continue with the next low-risk cleanup:

1. Measure `scripts/test compiler` and `scripts/test compiler-deep` separately.
2. Decide whether the default compiler gate needs a tiny named generated-C smoke
   subset, or whether the existing runtime/compiler checks already cover enough
   generated-C behavior for local confidence.
3. Profile the remaining parser/infer/typecheck fixture runner and identify
   whether the hot path is repeated module loading, type environment setup, or
   expensive fixture-specific work.
4. Keep only focused formatter fixtures and a small CLI smoke in the default
   path.

## Success Metrics

- Normal `scripts/test compiler` avoids full codegen audit, bridge-helper
  preparation, std preflight, format/purify tool fixtures, and broad
  compiler-owned Blorp sweeps.
- Default full `scripts/test` wall time drops without increasing flakiness.
- Deep/premerge still runs the expensive coverage explicitly.
- Test summaries make it obvious which expensive coverage did or did not run.
- Runtime/std tests do not contain broad nested compiler tests.
- CLI smoke remains focused on public command behavior instead of corpus sweeps.
