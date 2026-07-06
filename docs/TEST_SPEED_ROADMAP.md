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
- Compiler-unit is a single serial Alcotest executable. It is not the only
  problem, but it becomes the longest tail when run under full-gate contention.
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
`__compiler-bridge-prepare` path should use it instead of recompiling helper
binaries into a fresh startup directory on every `scripts/test` invocation.

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

- Run selected gates in fixed waves: `compiler-unit`, `compiler`,
  `compiler-deep`, `runtime`, then `leak + doctest + cli`.
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

1. Decide whether all compiler-unit suites belong in the default local gate, or
   whether pipeline/session/package/LSP-style internal integration coverage
   should move to an explicit internal-deep gate.
2. Reuse prepared bridge helpers instead of preparing fresh helper binaries per
   `scripts/test` invocation.
3. Keep formatter/purify fixtures in `compiler-deep` until there is an
   in-process or batched interface that reduces work instead of hiding it.

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
