# First self-hosted Blorp 2 native e2e slice

Base: `40a58a45b2f2e6498ec93d5ecf7af8fa281254bd`. Independent functional gates, oracle checks and matched cost observations pass.
This is scoped test qualification, not a bootstrap release. Raw evidence: `build/self-hosted-e2e/` (ignored).

## Boundary

One explicitly imported impure operation, `process.run_to_files`, runs an
executable with literal argv and exclusively creates stdout/stderr captures.
It reuses the runtime signature and ordinary Result/ownership paths. The public
module is outside prelude/compiler imports, so the existing pinned B2 seed can
build the updated compiler without a release or pin rotation. Make supplies
absolute compiler/CC/work-directory paths to an ordinary Blorp main constructing
actual TestSuites. Language fixtures retain their own mains and emitted C.

The user approved direct-child termination/reaping with best-effort group
signals. A reduced macOS probe establishes that group SIGKILL returns EPERM for
an exited unreaped leader even though direct-PID SIGKILL succeeds; [Apple's XNU `killpg1`](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/kern/kern_sig.c)
filters zombies before determining whether any signalable member was
found. Treating all group errors as fatal rejects ordinary successful commands.
The narrower guarantee avoids group inspection or a supervision framework;
direct-child signal/wait and descriptor cleanup errors remain blocking.
Detached daemons/background writers and descendant supervision are excluded.

## Functional evidence

- `bash blorp/test/test_build/test_blorp2_bootstrap.sh`: 35 routing checks passed,
  including compile/link/native failure propagation, explicit configuration,
  missing compiler and legacy-host tripwires. Log: `root-routing-current.log`.
- `make -C blorp_2 test-components`: 35 suites / 202 checks passed, with strict
  balanced reports. Log: `components-current.log`. This includes 12 granular
  process checks across parse/check/specialize/lower/own/verify/emit and two
  strict-report parser checks.
- Cold-cache `make -C blorp_2 test-compiler`: existing
  `blorp2-seed-a9b1939155aa` downloaded and digest-verified in the task cache;
  no `bin/blorp` exists. Log: `candidate-A-cold-build.log`.
- `make -C blorp_2 test-e2e`: 26 process-runtime checks and four native e2e
  checks passed. Driver compilation: 6,868,727 balanced allocations; driver
  execution: 1,590 balanced allocations; zero leaks/bytes. Log: `e2e-current03.log`.
  The driver, runtime probe and fixture executables use ASan/UBSan with recovery
  disabled; accepted fixtures run separate normal/strict-memory executables
  linked from the same unchanged C.

| Native witness | Required result |
| --- | --- |
| return zero | exit 0; empty stdout/stderr; strict 0/0 |
| return 23 | exit 23; empty stdout/stderr; strict 0/0 |
| text output | exit 0; `Hello, World!` plus LF; empty normal stderr; strict 1/1 |
| rejected compilation | exit 1; exact missing-main diagnostic/help/span; existing output unchanged |

Runtime checks cover literal argv, EOF stdin, normal/nonzero/127 exits, signals,
ready-child timeout, validation before file creation, exclusive/aliased/existing
captures, symlink/FIFO rejection, exec failure, closed stdio and unsupported
SIGCHLD. Independent waitpid/ECHILD probes check direct reaping after exit,
signal, waiting timeout and acknowledged pre-exec timeout. The last probe uses
one test-local execve shim around unchanged production fragments; group attempts
are source-reviewed, without syscall counters or descendant guarantees.

Early red/failure evidence remains recorded: the old e2e target was explicitly
DEFERRED, the parent rejected the unknown builtin, the first native call exposed
the macOS zombie-group error, and first driver compilation caught nested `?=`
and old Unicode-escape spelling. Those harness errors were fixed in source;
no compiler feature or generated-C rewrite was introduced.

## Final qualification and cost accounting

Independent `scripts/blorp2-fixpoint --prove` passed with 1,242 frozen
source/library/test/build inputs: all 590 maintained fixtures have identical exit/stdout/stderr/emitted-C
presence and bytes under A/B; 202 component checks and 26 runtime/four native
checks pass under actual self-built B. Seed/A/B/C source C is byte-identical,
SHA256 `f5871fce8fcaa69fc6b5c51c979686bab13b1f8cfd83a3587bc564fbaa34c6e0`.
Logs and input hashes: `test-review/final/fixpoint.log`,
`test-review/final/SOURCE_FREEZE.json`, and `blorp_2/build/fixpoint/`.

Same-C sanitized B passed complete-source strict accounting: 30,362,647
allocations/releases, zero leaked/bytes, identical C and no sanitizer diagnostics.
Flags: `-O0 -DBLORP_MEMORY_DIAGNOSTICS=1 -fsanitize=address,undefined
-fno-sanitize-recover=all -lm -lpthread`; results: `test-review/final/SANITIZED_RESULT.json`.
The independent build-route rerun passed all 35 checks.

The retained actual-B driver passed a pristine 30-case control, six exact argv
rejections (status 2), a forced-False callback (named FAIL/status 1), and a real
copied return-zero fixture changed to return 1 (named FAIL/status 1). Restoring
the copied bytes restores all 30 passes. Repository sources were unchanged;
source mains and emitted C were never replaced or rewritten. Results:
`test-review/final/oracles/VERDICT.json` and its raw command/output artifacts.

GNU GCC 16.2.0 also passed all 26 runtime/four native cases with unchanged
sanitizer/strict flags and balanced driver accounting (1,590/1,590). This
qualifies native probes/fixtures on macOS ARM64 with an Apple-Clang-built B and
driver; it does not claim GNU bootstrap or remote Linux/GCC/ARM CI execution.
Evidence: `test-review/final/gnu-gcc/`.

Matched costs passed the plan’s 3% investigation/10% stop criteria. The observer uses one warmup and three alternating
normal samples per version/workload, then one deterministic strict diagnostic
run. Both actual self-built B pairs use Apple Clang `-O0`, diagnostics 0/1 and
`-lm -lpthread`. Both receive identical frozen final compiler/library bytes,
cwd, argv and physical output path. It requires positive instruction/RSS
counters, exact balanced diagnostic reports, source/binary guards and identical
C across modes and versions. `benchmarks/self_compile_measure` expects the
legacy CLI/profiler protocol, so the B2-only observation script and complete
spec remain under `test-review/final/cost/`, without adding a test framework.
Minimum normal retired instructions qualify costs; elapsed time is observational.

| Matched input | Parent allocations | Candidate allocations | Parent min instructions | Candidate min instructions |
| --- | ---: | ---: | ---: | ---: |
| Return zero | 116,474 | 116,474 | 1,450,488,070 | 1,450,335,683 |
| Frozen final compiler source | 30,362,694 | 30,362,694 | 1,094,458,389,261 | 1,094,447,348,608 |

Allocations are unchanged. Instruction differences are -0.0105% and -0.0010%,
respectively, within measurement noise; no speedup is claimed. C is identical
across modes/versions for each input. Whole-source maximum normal RSS was
316,801,024 → 314,310,656 bytes; diagnostic RSS was 323,321,856 → 324,747,264
(+0.44%). No allocation/instruction/RSS increase reaches the 3% investigation
threshold.

The process input is candidate-only: 125,387 allocations, 1,466,532,383 minimum
normal instructions, C SHA256
`c40e75cbdec8e605e8423fbc6c4f3cf9c506688816f3ff61f968a8b612288780`.
The parent cannot compile that operation; there is no parent comparison or
fallback. Raw specs, guards, argv, streams, timers, samples and output C remain
in `test-review/final/cost/`; `summary.json` contains all observations.
 Parent A/B normal/diagnostic pairs
are retained with provenance in `PARENT_LINEAGE.json`; parent A-to-B strict
self-compilation used 30,246,256 balanced allocations and emitted C SHA256
`d17ffd5c3398100acef3694137cbec5c2e7c1e333f1101016978b8944cd57976`.
These historical owned-input counts are not substituted for the matched final
source measurement. New process input has candidate-only measurements because
the parent lacks this operation. Normal retired instructions and diagnostic
allocations are measured separately using paired actual self-built compilers.

## Size audit

| Area | Added | Deleted | Net |
| --- | ---: | ---: | ---: |
| Compiler wiring | 53 | 10 | +43 |
| Native-runtime Blorp carrier | 444 | 0 | +444 |
| Target library | 9 | 0 | +9 |
| Build/CI | 59 | 20 | +39 |
| Blorp e2e driver | 227 | 0 | +227 |
| Other tests | 955 | 8 | +947 |

Compiler/library growth is +496; including build/CI it is +535. Crossing the
500-line investigation point was reviewed explicitly: the native payload has
429 physical C lines (425 nonblank), comprising the feature prelude, private
FD/capture/clock/error helpers, child setup, and one launch/wait/cleanup body.
Prebuilt argv, the exec errno handshake, overflow-safe deadline and cleanup
errors account for the readable code beyond the original 220–330 C-line
estimate. No alternate process path, controller, registry or general process
handle was added. Physical lines, rather than nonblank lines, govern the size
audit; the result remains below the 750-line stop threshold. Documentation is
reported separately in `test-review/final/LINE_COUNTS.json` and does not replace
production or necessary test growth.

The first four cases and runtime checks do not qualify the remaining deferred
native/grammar/tooling/unit cases or their resource budgets. No bootstrap asset
is published or pin rotated by this change. Existing producer-C, parity, digest
and publication locks remain intact; publishing a changed producer requires
reviewing its exact C identity through the release workflow.
