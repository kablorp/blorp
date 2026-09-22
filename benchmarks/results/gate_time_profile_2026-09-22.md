# Gate time profile (2026-09-22)

Measurement only — nothing below was implemented. Numbers come from one
`--serial` run of seven gates under the global measurement lock, each once,
with `BLORP_TEST_TIMINGS=1` (`scripts/test --timings`) and `--log-dir` capturing
full per-artifact output.

## Ranked gate speedups (phase-time evidence)

1. **compiler-core-sanitize: raise/verify host-C split usage.** `host_c` is
   47.8% of this gate's wall (27.7s of 58s) for a single 59-source suite
   artifact built at the standard 8-translation-unit split. ASan/UBSan
   instrumentation makes each TU compile heavier, so this is the gate where
   more or better-balanced splitting has the largest, most direct ceiling of
   any gate measured (up to ~48% of wall if `host_c` were free).
2. **runtime: execution dominates (47.7% of wall).** The single 446-source
   combined suite spends 27.7s of its 58s wall actually running tests, more
   than pipeline (8.2%) and host_c (23.9%) combined. Any execution-time win
   (test selection/caching so an unchanged suite doesn't re-run, or shrinking
   the interpreter/runtime overhead in the generated harness loop) has a
   ceiling near 48% here — the largest execution-side opportunity of the four
   gates that have phase data.
3. **leak: batch 41 single-source "program" artifacts into the existing suite
   path.** The leak gate is 42 artifacts: one 76-source combined suite and 41
   individual leak-baseline programs, each its own link+run (~0.5-0.7s wall
   apiece, split roughly 35% pipeline / 30% host_c / 35% execution — mostly
   fixed per-process overhead: 8-way clang spin-up and runtime discovery for
   a single tiny file). Batching them the way the 76-source suite already
   batches its members would remove most of this fixed cost. Ceiling: the 41
   program artifacts account for roughly 42.8s of the 56.2s summed-phase time
   in this gate (~72% of accounted-for time, ~4.7s of it in per-artifact
   frontend_graph/host_c/execution overhead that a single combined artifact
   would pay once instead of 41 times).
4. **compiler-blorp: the known static_string_literal_pool quadratic.** Pipeline
   (33.9%) and host_c (33.5%) are almost tied here. The 2026-09-16 note that
   `add_static_string_literal`'s Dict-copy-per-insert cost ~6% of the compiler
   corpus's compile time still applies to the `pipeline` share of this gate
   (82.4s), i.e. roughly 5s of this gate's 243s wall — real but the smallest
   ceiling on this list, and already well understood/cheap to fix.
5. **compiler-tools / cli / lsp: no phase breakdown exists to target.** These
   three gates never call through the `bin/blorp test` artifact-batching path
   (see "gap found" below), so there is no `pipeline`/`host_c`/`execution`
   split to act on from this data; any change here should start by adding
   the same `BLORP_TEST_TIMING` instrumentation those code paths already have
   elsewhere, or by using the launch-count data below.
6. **Separate the build lock from the test-binary launch lock.** Not a phase
   inside any gate, but real: this run queued behind four other
   `self_compile_measure lock --` holders and did not start until ~9 minutes
   after being launched (see "Machine state" below). A lock that only
   serializes binary *launches* (the actual syspolicyd/parallel-execution
   hazard) rather than the whole build+test invocation would shrink that
   queuing, though it does not show up in any gate's own wall time.

## Ranked ways to launch fewer distinct binaries

Requested by the coordinator mid-task; see "Distinct executables and launches"
below for the counts these rest on. Not implemented.

1. **Collapse leak's 41 individual program artifacts into combined suites.**
   Removes ~40 of leak's 42 links and ~40 of its 42 launches — the single
   biggest count reduction available, and it reuses a code path leak already
   exercises (the 76-source suite in the same gate).
2. **One runner binary per gate that loads fixtures as data (compiler-tools).**
   compiler-tools launches the *existing* `bin/blorp` binary 113 times (once
   per format/purify/lint fixture) plus 2 Python-unittest processes. None of
   these are new links, but a single dispatch-by-argv (or in-process loop)
   runner would remove on the order of 110+ fork/exec round trips per run.
3. **Content-hash cache for cli's ~43 compiling fixtures.** Of cli's ~117
   direct CLI launches, roughly 43 (by PASS-description keyword match, see
   caveat below) compile a small fixture program from scratch every run even
   though the fixture source and compiler stamp are unchanged between runs.
   Skipping the relink when the hash matches removes up to ~43 fresh links
   per run (these are the ones that matter most for syspolicyd, since each is
   a genuinely new code hash, unlike the reused `bin/blorp` launches above).
4. **Batch small artifacts into fewer host-C compiles (general).** Same
   mechanism as #1, generalized: anywhere a gate produces many single- or
   few-source artifacts instead of one combined one, each artifact currently
   pays its own 8-way clang split fixed cost. leak is the clear case here;
   cli's compiling fixtures are smaller individual wins of the same shape.

## How this was measured

Worktree: `/Users/keithphilpott/CLionProjects/blorp-gate-profile` (branch
`perf/gate-profile`, `origin/main` at `a246909f95b5`, clean).

Build stamp (`bin/blorp --version`):

```
blorp 0.0.1
commit: a246909f95b5
target: aarch64-apple-darwin
channel: local
dirty: false
compiled_by: dev-ec74c01d3679
optimization: cli=-O2 runtime=-O2
split: 8
cc: Apple clang version 21.0.0 (clang-2100.3.34.2)
```

Commands, exactly as run:

```bash
cd /Users/keithphilpott/CLionProjects/blorp-gate-profile
BLORP_CLI_C_OPTIMIZATION=-O2 make          # build the -O2 gate compiler once
mkdir -p /tmp/gate-profile-logs
benchmarks/self_compile_measure lock -- \
  scripts/test --serial --release-compiler --timings --log-dir /tmp/gate-profile-logs \
  compiler-blorp compiler-tools runtime leak compiler-core-sanitize lsp cli
```

`--release-compiler` re-asserted `-O2` inside `scripts/test`'s own `make
install` step (a no-op relink against the already-`-O2` binary). `--serial`
runs the seven gates one at a time, matching the "never run compiled test
binaries in parallel" rule. `--log-dir` copies each gate's full captured
stdout+stderr (including every `BLORP_TEST_ARTIFACT_*` and
`BLORP_TEST_TIMING` line) to its own file; the phase sums, artifact counts,
and top-5 tables below come from parsing those files directly.

**Gap found while doing this:** `scripts/test --timings`' own printed
"Generated TestSuite phase totals" summary only ever showed data for the
`compiler-blorp` gate. Reading the script, `print_blorp_test_timing_summary`
is called from `run_compiler_blorp` and `run_compiler_blorp_sanitize` but not
from `run_runtime`, `run_leak`, `run_compiler_core_sanitize`, or the other
serial-mode gate functions — even though their underlying `bin/blorp test`
invocations emit the same `BLORP_TEST_TIMING` lines (confirmed present in the
`--log-dir` files for all of them). This is a real gap in the tool's own
reporting, not a measurement problem; it's why every number below was parsed
from the raw log files rather than the script's own summary. Not fixed here
(measurement-only task).

### Machine state

Darwin 25.6.0, arm64, 10 logical CPUs. This machine was heavily loaded with
other agents' worktrees for the entire measurement window: at the time this
run's lock request was issued, `ps` showed one gate actively running
(`bin/blorp test --sanitize`) plus four other queued
`self_compile_measure lock --` invocations from three other worktrees
(`blorp-pool-cap`, and others running `compiler-blorp`/`compiler-tools` and
`runtime`/`leak`/`compiler-core-sanitize`/`compiler-blorp-sanitize` batches).
This run's own lock acquisition queued for roughly 9 minutes (launched
~12:06, first gate output appeared ~12:15) before it got exclusive access;
once inside the lock, no other gate ran concurrently with it. Wall times below
are this machine's numbers under that queuing model, not a quiet-machine
baseline — treat single-run wall time as directional, per the standing
`self_compile_measure` guidance that wall time is host-clock noise.

## Per-gate table

Wall times from the gate summary this run printed:

```
Compiler-Blorp PASS       5033       0    5033    4m03s
Compiler-Tools PASS        115       0     115      17s
Runtime       PASS       4492       0    4492      58s
Leak-check    PASS        963       0     963      59s
Compiler-Core-ASan PASS       2079       0    2079      58s
LSP           PASS         36       0      36    2m46s
CLI           PASS        117       0     117      52s
Total         PASS      12835       0   12835   10m56s
```

| Gate | Wall | Phase sum (fg+pipe+hostc+exec) | Artifacts | Host-C TUs / artifact | Parallelism | Blorp compile / clang / exec / overhead (of wall) |
|---|---|---|---|---|---|---|
| compiler-blorp | 243s | 217.28s (0.29+82.37+81.32+53.31) | 1 (252 sources, combined suite) | 8 (`DEFAULT_TEST_C_TRANSLATION_UNITS`, `blorp/src/lib/cli_args.brp:301`) | 8 concurrent clang (min(8 TUs, 10 cores)) | 33.9% / 33.5% / 21.9% / 10.6% |
| compiler-tools | 17s | n/a — no `bin/blorp test` path used | 0 test-harness artifacts; 113 direct `bin/blorp format\|purify\|lint` launches of the existing binary + 2 Python-unittest processes | n/a | 1 (serial loop over fixtures) | n/a / n/a / n/a / 100% (all harness/CLI-launch overhead) |
| runtime | 58s | 46.36s (0.07+4.78+13.85+27.66) | 1 (446 sources, combined suite) | 8 | 8 | 8.2% / 23.9% / 47.7% / 20.1% |
| leak | 59s | 56.17s (0.51+19.33+16.63+19.70) | 42 (41×1-source "program" + 1×76-source suite) | 8 per artifact | 8 per artifact; artifacts themselves run one at a time | 32.8% / 28.2% / 33.4% / 4.8%* |
| compiler-core-sanitize | 58s | 56.56s (0.03+21.39+27.70+7.45) | 1 (59 sources, combined suite, ASan+UBSan) | 8 | 8 | 36.9% / 47.8% / 12.8% / 2.5% |
| lsp | 166s | n/a — no `bin/blorp test` path used | 0 test-harness artifacts; 6 Python fixture processes (mostly long-lived LSP server sessions over stdio) | n/a | 1 (serial) | n/a / n/a / n/a / 100% |
| cli | 52s | n/a — no `bin/blorp test` path used | 0 test-harness artifacts; ~117 direct `bin/blorp` CLI launches (~43 compile a fixture program) | n/a (ordinary single-file `bin/blorp compile`, not the test split path) | 1 (serial) | n/a / n/a / n/a / 100% |

\* leak's overhead also includes `blorp/test/runtime/test_leak_report.sh`,
which does not itself launch `bin/blorp` (its `$BLORP` variable is set but
unused in the script as written).

Sum check: 243+17+58+59+58+166+52 = 653s ≈ the run's reported
"gate-sum 10m53s" (653s) plus 2s of build/setup = 10m56s total, consistent.

### Top five artifacts by phase

compiler-blorp, runtime, and compiler-core-sanitize each ran exactly **one**
artifact, so "top five" is just that one artifact in every phase (already in
the table above). leak is the only gate with enough artifacts for a real
ranking:

**leak — top 5 by `pipeline`:**
1. combined suite (76 sources) — 13337 ms
2. `leak_check_baselines/tcp_concurrent_source_cancelled_stream.brp` — 195 ms
3. `leak_check_baselines/json_object_key_cleanup.brp` — 179 ms
4. `leak_check_baselines/nested_worker_group_cancel_channel.brp` — 178 ms
5. `leak_check_baselines/stack_result_tuple_borrowed_value.brp` — 164 ms

**leak — top 5 by `host_c`:**
1. combined suite (76 sources) — 5997 ms
2. `leak_check_baselines/udp_datagram_stream_cancelled_recv.brp` — 291 ms
3. `leak_check_baselines/udp_datagram_stream_cancelled_predicate.brp` — 287 ms
4. `leak_check_baselines/sleep_cancelled_string.brp` — 285 ms
5. `leak_check_baselines/stack_result_tuple_borrowed_value.brp` — 284 ms

**leak — top 5 by `execution`:**
1. combined suite (76 sources) — 9674 ms
2. `leak_check_baselines/udp_datagram_stream_cancelled_predicate.brp` — 321 ms
3. `leak_check_baselines/string_literal_lifecycle.brp` — 317 ms
4. `leak_check_baselines/udp_cancelled_recv_string.brp` — 316 ms
5. `leak_check_baselines/tcp_cancelled_accept_string.brp` — 315 ms

**leak — top 5 by `frontend_graph`:**
1. combined suite (76 sources) — 63 ms
2. `leak_check_baselines/channel_failed_send_string.brp` — 16 ms
3. `leak_check_baselines/tcp_cancelled_accept_string.brp` — 16 ms
4. `leak_check_baselines/concurrent_cancelled_fixed_join_string.brp` — 15 ms
5. `leak_check_baselines/stream_cancelled_owned_callback_string.brp` — 15 ms

## Distinct executables and launches

Per the coordinator's request: how many *new* host binaries each gate links
(a fresh code hash, the thing syspolicyd assesses on first launch) versus how
many times binaries get launched in total. Counts for compiler-blorp,
runtime, leak, and compiler-core-sanitize are exact, read directly from the
`BLORP_TEST_ARTIFACT_START`/`END` rows (one link + one launch per artifact,
confirmed against `blorp/src/lib/host_c.brp`'s `split_link_command`, which
issues exactly one link per artifact regardless of TU count). Counts for
compiler-tools, cli, and lsp are **estimates** from static log/source
inspection, not from instrumented launches (`ps`/`fs_usage` sampling was not
run — flagged below rather than guessed further).

| Gate | New binaries linked | Launches of new binaries | Launches of the pre-existing `bin/blorp` CLI | Notes |
|---|---|---|---|---|
| compiler-blorp | 1 | 1 | 0 (invoked via the `bin/blorp test` driver process itself) | exact |
| runtime | 1 | 1 | 0 | exact |
| compiler-core-sanitize | 1 (ASan/UBSan build — a distinct code hash from the plain compiler-blorp artifact) | 1 | 0 | exact |
| leak | 42 (41 program + 1 suite) | 42 | 0 | exact; this is the gate `test_leak_report.sh` also runs against, but that script does not itself launch `bin/blorp` |
| compiler-tools | 0 | 0 | 113 (one `bin/blorp format\|purify\|lint` per fixture, confirmed in `blorp/test/tool/test_compiler_tool_fixtures.py:run_fixture`) | exact link count (0), exact launch count (113) |
| cli | ~43 (fixtures whose PASS description contains "compile"/"build"/"link", out of 117 total fixtures) | ~43 | ~117 (one CLI invocation per fixture; the ~43 compiling fixtures also launch their own produced binary once each) | **estimate** — keyword match on `PASS:` descriptions in the captured log, not per-fixture instrumentation; total launches ≈160 |
| lsp | not measured | not measured | ~1 long-lived server session in `test_lsp_fixture_process.py` (single `subprocess.Popen`); `test_lsp_stdio_transport.py` has 9 `Popen`/`run` call sites across its two invocations (plain + `BLORP_LSP_STDIO_SANITIZE=1`); `test_lsp_native_runtime.py` has 2; `test_lsp_native_baseline.py` and `test_lsp_native_measurements.py` import no `subprocess` at all (they appear to drive the LSP logic in-process rather than by launching `bin/blorp`) | **estimate from static code inspection only** — call-site counts, not observed launch counts; a short `fs_usage -w` or `ps` sample during this gate would be needed for real numbers |

The one clear, confirmed case of "a suite rebuilds even though nothing
changed between runs" is structural rather than a caching gap: every gate run
recompiles its artifact(s) from scratch every time (there is no artifact
cache keyed on source+compiler-stamp hash anywhere in `blorp/src/lib/host_c.brp`
or `blorp/src/test/program_session_runner.brp`), so re-running the same gate
twice in a row with no source changes relinks every artifact both times. This
is the gap the "content-hash cache" item in both ranked lists targets.

## Follow-up: is compiler-blorp's host_c slow from imbalance or contention? (part 2)

Requested by the coordinator, measurement only. Method: reran
`compiler-blorp` + `compiler-core-sanitize` under the same global lock
(`benchmarks/self_compile_measure lock -- scripts/test --serial
--release-compiler --timings --log-dir ... compiler-blorp
compiler-core-sanitize`), with a 0.5 s-interval `ps -axwwo
pid,etime,pcpu,command` sampler running for the whole duration, filtered to
clang processes. Full command lines (including `-cc1`) were captured, so this
reads `-O` level and the actual per-translation-unit source file directly off
the process table instead of inferring it.

**`blorp/src/test/program_session_runner.brp` / `blorp/src/lib/host_c.brp`:**
`run_host_c_translation_units` compiles every unit **concurrently** —
`prepared.units.concurrent(prepared.units.length(), ...)` launches all 8 at
once, bounded only by the runtime's worker pool (sized to host cores, 10
here). This is confirmed directly in the ps samples: all 8
`unit_0.c`..`unit_7.c` compiles for one artifact share one temp directory and
start at the *same* timestamp. Every one of them compiles at **`-O0`**
(visible in the captured `-cc1 ... -O0 ...` command line) — the gating
default; `--release-compiler` only changes how `bin/blorp` itself is built,
not the generated test artifacts (matches the code read from
`scripts/test`/`cli_args.brp` in the main report above).

**compiler-blorp: real imbalance, not just contention.** This rerun's
`host_c` phase measured 86.187s (vs. 81.315s in the first run — consistent).
Isolating our own 8 unit processes (pid range 69286-69303, one shared temp
dir) by first-seen/last-seen timestamp:

| unit | observed duration |
|---|---|
| unit_0 | **84.59s** |
| unit_1 | 11.54s |
| unit_2 | 12.18s |
| unit_3 | 12.18s |
| unit_4 | 12.18s |
| unit_5 | 12.18s |
| unit_6 | 12.18s |
| unit_7 | 12.18s |

All 8 started at the identical timestamp (1790106877.72). Units 1-7 are
tightly balanced (11.5-12.2s) and finish in ~12s; **unit_0 alone runs 84.59s,
about 7x longer than any other unit**, and its wall-clock end
(1790106962.31) accounts for essentially the entire measured `host_c` phase
(86.19s). This directly answers the question: the compiler-blorp gate's
81-86s host_c is **one oversized translation unit dominating a well-launched
8-way concurrent compile**, not a failure to parallelize and not (primarily)
machine contention. If unit_0 were split evenly with the rest (or the
splitter balanced by clang cost rather than whatever it currently balances
by), host_c should land close to the coordinator's ~15s guess — units 1-7
already demonstrate that ceiling. This is a bigger, better-targeted lever
than the generic "split count" framing in the original ranked list above;
see the revised ranking below.

Contention is real but secondary here: the sampler incidentally caught
unrelated `clang -cc1 ... -fdebug-compilation-dir=.../blorp-leak-batch
.../unit_0.c` processes from a *different* worktree/agent overlapping our
window (1790106961-967), proving other agents were compiling on this same
10-core machine at the same time without going through our lock (they must
not be using `self_compile_measure lock --`, or are holding/queuing a
separate lock instance around a different command). That inflates wall time
generally but does not explain the 7x unit_0-vs-others gap, which shows up
identically in the concurrency-launch timestamps regardless of contention.

**compiler-core-sanitize: balanced, no dominant unit.** Same method, pids
73850-73865, all launched at 1790107043.23 (also `-O0`, confirmed
`-fsanitize` in the command line):

| unit | observed duration |
|---|---|
| unit_0 | 23.20s |
| unit_1 | 20.43s |
| unit_2 | 19.23-19.83s |
| unit_3 | 19.83s |
| unit_4 | 19.83s |
| unit_5 | 20.43s |
| unit_6 | 19.83s |
| unit_7 | 20.43s |

Spread is only ~20% (19.2-23.2s), and the measured `host_c` phase (24.1s this
run, 27.7s in the first run) tracks the slowest unit plus modest launch/link
overhead — this is what 8-way concurrency working as intended looks like.
The sanitizer gate's `host_c` share is dominated by ASan/UBSan
instrumentation cost spread evenly across units, not by an imbalance to fix.

### Revised ranking note

Given this, **the single highest-value, most concrete fix in either ranked
list is rebalancing (or further splitting) whatever produces `unit_0` for the
compiler-blorp suite artifact** — it alone is responsible for essentially all
of that gate's 81-86s `host_c` time (33-35% of the gate's wall). This
supersedes item 1 in the original "ranked gate speedups" list above as the
better-evidenced target; compiler-core-sanitize's `host_c` share, while
still the largest fraction of its own gate, is already well-parallelized and
has a smaller realistic ceiling (its 8 units are within 20% of each other, so
there is no single dominant unit to fix — only the fixed per-unit ASan/UBSan
cost, which is a different, harder problem than rebalancing a split).

## Follow-up: where the lsp gate's 166s goes

Requested by the coordinator, measurement only. `run_lsp_gate_commands` in
`scripts/test` runs six independent Python processes in sequence (see
`blorp/test/lsp/*`); none of them go through the `bin/blorp test` artifact
path, which is why this gate has no `BLORP_TEST_TIMING` rows. From the
captured log (`/tmp/gate-profile-logs/lsp.log`, this run), in order:

| script | tests | time | share of 166s |
|---|---|---|---|
| `test_lsp_fixture_process.py` | 1 | 0.216s | 0.1% |
| `test_lsp_native_baseline.py` | 18 | **152.262s** | **91.7%** |
| `test_lsp_native_measurements.py` | 1 | 9.510s | 5.7% |
| `test_lsp_native_runtime.py` | 4 | 0.551s | 0.3% |
| `test_lsp_stdio_transport.py` | 6 | 0.992s | 0.6% |
| `test_lsp_stdio_transport.py` (`BLORP_LSP_STDIO_SANITIZE=1`) | 6 | 1.818s | 1.1% |

Sum (165.35s) matches the gate's 166s wall; there is no unaccounted harness
overhead worth calling out separately here, unlike the other gates.

`test_lsp_native_baseline.py` alone is 36 process launches' worth of the
gate's total: it has no `setUp`, so each of its 18 `test_*` methods
independently constructs its own `RUNNER.LspClient(str(BLORP), workspace)`,
i.e. launches a fresh `bin/blorp` LSP-server subprocess (the existing binary,
not a new link — LSP has no host-C compile step; there is no `host_c`/
`pipeline` phase because diagnostics only need frontend-graph + typecheck,
never C emission) against its own small temporary workspace, drives it over
the LSP protocol, then shuts it down. That is 18 separate server launches for
this file alone (plus 1 in `test_lsp_fixture_process.py`, plus one long-lived
session per `test_lsp_stdio_transport.py` run, etc. — a precise system-wide
launch count would need the same `ps`/`fs_usage` instrumentation flagged as
unmeasured in the main report's launch-count table).

To get **time per fixture** (unittest's default runner only prints dots, no
per-test timing), the 18 `test_*` methods in `NativeLspBaselineTests` were
each re-run individually via `unittest.TestSuite([TestCase(name)])` timed
with `time.perf_counter()`, same process/module, same machine, immediately
after the real gate run (all 18 passed; total 147.43s vs. the gate's
152.262s — the ~5s gap is ordinary run-to-run variance on this loaded
machine, not a methodology difference).

**Top five fixtures by time:**

| fixture | time |
|---|---|
| `test_rapid_edits_publish_only_the_newest_analysis` | 22.901s |
| `test_open_document_runs_native_compiler_analysis` | 18.891s |
| `test_standard_library_and_package_imports_resolve` | 16.526s |
| `test_shutdown_and_exit_do_not_wait_for_active_analysis` | 15.353s |
| `test_writer_failure_overrides_clean_lifecycle_exit` | 13.647s |

Full per-test breakdown (18 tests, sorted by appearance, `cum` = cumulative):

```
   0.02s cum    0.021s  OK  test_clean_eof_before_initialize_is_successful_shutdown
  11.02s cum   10.998s  OK  test_close_clears_open_document_diagnostics
  12.05s cum    1.029s  OK  test_definition_from_call_returns_declaration_location
  13.02s cum    0.974s  OK  test_definitions_traverse_selective_imports_to_unopened_provider
  15.51s cum    2.489s  OK  test_document_effects_complete_before_the_next_client_event
  16.69s cum    1.181s  OK  test_document_highlights_use_exact_symbol_ranges
  17.81s cum    1.122s  OK  test_document_symbols_return_compiler_owned_declarations
  25.65s cum    7.834s  OK  test_exit_is_not_blocked_by_a_client_that_stops_reading
  26.61s cum    0.957s  OK  test_hover_returns_compiler_owned_typed_signature
  35.69s cum    9.082s  OK  test_implicit_tuple_implementation_typechecks
  45.77s cum   10.078s  OK  test_missing_import_publishes_exact_import_path_diagnostic
  64.66s cum   18.891s  OK  test_open_document_runs_native_compiler_analysis
  77.00s cum   12.343s  OK  test_public_command_uses_native_lifecycle_server
  99.90s cum   22.901s  OK  test_rapid_edits_publish_only_the_newest_analysis
 101.91s cum    2.004s  OK  test_references_return_null_for_incomplete_snapshot
 117.26s cum   15.353s  OK  test_shutdown_and_exit_do_not_wait_for_active_analysis
 133.79s cum   16.526s  OK  test_standard_library_and_package_imports_resolve
 147.43s cum   13.647s  OK  test_writer_failure_overrides_clean_lifecycle_exit
```

There is no fixed per-test floor (times range from 0.02s to 22.9s) — this
rules out "every launch pays the same ~7-8s startup tax" as the explanation.
The costly tests are the ones whose names describe real interaction load
(rapid edits triggering repeated re-analysis, opening a document and running
full native compiler analysis, resolving standard-library and package
imports, a shutdown that must wait out in-flight analysis, a lifecycle
writer-failure path) — the time is concentrated in a handful of
fixtures doing genuinely more LSP/analysis work per test, not spread evenly
across all 18. `test_lsp_native_measurements.py`'s own
`LSP_BASELINE initialize_ms=7275.9 diagnostics_ms=2205.8` line (measured
against a real 318-file/11MB workspace, unlike `native_baseline`'s small
per-test workspaces) shows that a *full workspace* initialize+diagnostics
cycle costs ~9.5s on its own — consistent with, but not identical to, what
drives the costlier `native_baseline` fixtures.

