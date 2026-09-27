# Retained Core continuation pilot

## Frozen provenance (recorded before source edits)

- Source and self input: `99b4eedf9682f7539e745cdb3afea2bc237801af`; this worktree began clean and detached at that commit.
- Branch: `codex/retained-core-continuation` in `/Users/keithphilpott/.codex/worktrees/c196/blorp`.
- Fixed source-check compiler: `/tmp/blorp-retained-base-99b4eedf`, SHA-256 `693d19021211d57070de6db20747480dba73e821988d8b5749e31dc394a04913`.
- Fixed compiler version: `blorp 0.0.1`, commit `99b4eedf9682`, clean, built by `dev-35040738956f`, CLI/runtime `-O2`, split 8, Apple clang `21.0.0 (clang-2100.3.34.2)`.
- Local `bin/blorp` initially absent (`compiler-build-status: UNKNOWN`); no measurements from it before a candidate build.
- All compiled operations use `/tmp/blorp-memory-pilot-run-20260927.py` for an `fcntl` lock. The shared pristine stage-2 baseline is assigned to another worker.

## Hypothesis and stop rule

The successful late-Core result publishes `PreparedCompileExecution`, keeping its pre-late `CoreCompilation.program` alive through backend emission. Carrying only configuration, target path, optional typed summary and allocation-report selection should release that old root before emission without changing output. First check generated C for the actual release; reject if enclosing owners still retain the program and fixing them requires broad ownership changes. Allocation count must not increase, and any reproducible retired-instruction increase rejects the candidate even if RSS falls.

## Candidate and ownership proof

The uncommitted candidate narrows `LateCoreCompileExecution` to configuration,
typed summary, report selection, prepared Core, and observations. The emission
result carries only target path, typed summary, emission, and observations.
The timed path returns a compact ready variant from a helper that closes the
preparation scope before backend emission. The final refinement removes the
intermediate `TimedBackendArtifactCompileTail` record and returns the final
timed execution directly. Stopped, failed, report, and run-artifact paths
remain separate.

Generated candidate C: `blorp/build/_build/blorp-cli/blorp_cli_main.c`,
SHA-256 `2488af899609d9beae554ae5c5736aa8323c5b9a616efeca3ba68c6f24b64789`.
It releases `prepared` around line 222417, then `early_preparation` and the
runtime projection match owner before returning. The outer wrapper calls the
backend from `LateCompilePlanReady` around line 222472, after those releases.
There is no `TimedBackendArtifactCompileTail` constructor in final C. The
outer `TimedCompilePlanPreparation` contains the pre-lowering request, not
the pre-late `CoreCompilation.program`. This proves the intended old-Core
owner is absent at backend entry; it does not imply all earlier IR is gone.

## Focused behavior

- Fixed stage-1 source check passed for `compilation.brp`,
  `compile_plan_execute.brp`, and `test_cli_late_core.brp`, with explicit
  `--std-dir standard_library/src`.
- `bin/blorp test --timeout 180 blorp/test/compiler/pipeline/test_cli_late_core.brp`:
  13/13 passed after the final refinement. The fixture covers backend and
  artifact failures, timed labels, stops, and Core invariants.
- `benchmarks/fixtures/retained_core_continuation.brp` compiled through the
  fixed stage-1 and initial candidate to byte-identical C, SHA-256
  `96723b49996d42f892e8c5275310b6c32abe824c6aaeca49e73bb88bbd580b45`.
  Both `run ... -- alpha` invocations printed `late core continuation` and
  exited 0. The final self compile also emitted byte-identical C.

## Same-input, same-toolchain self compile

All valid rows used frozen revision `99b4eedf9682f7539e745cdb3afea2bc237801af`
with `--input-rev` and no explicit `--input-dir`; the harness therefore used
the identical textual `/var/folders/...` input path. The compilers were
stage 2, CLI/runtime `-O2`, Apple clang 21.0.0. Baseline binary SHA-256:
`bdd95f2e174aa695026a9abdb4ffe971e8f3eddc3f81eb500e67a2a790253405`.
Final candidate binary `/tmp/blorp-retained-core-stage2-refined-o2`, SHA-256
`50e958b86e80004d6c9b9bb7e6b1451777ef5fc6ff43cf3367c32cc6c9919a06`.
The harness mislabels externally supplied stage-2 binaries as stage 1; these
are stage-2 binaries by build provenance and `compiled_by: self-99b4eedf9682`.

| Metric | Baseline | Final candidate | Result |
| --- | ---: | ---: | --- |
| Generated self C | 78,715,797 bytes | 78,715,797 bytes | Byte identical, SHA-256 `0d3b3e7f58ca02c7ff66ad25993a1d605e2801cffa22f02e3cfc42c1d743468f` |
| Total allocations | 190,932,006 | 190,932,007 | **+1; explicitly accepted tradeoff** |
| Live objects at backend completion | 20,603,746 | 13,421,734 | -7,182,012 |
| Allocator-zone bytes at backend completion | 1,867,659,376 | 1,854,913,136 | -12,746,240; pool-inclusive |
| Process peak RSS | 2,031,517,696 | 2,017,951,744 | -13,565,952 |
| Retired instructions, three samples | 143,580,242,270 / 143,544,872,583 / 143,588,273,107 | 143,614,421,412 / 143,735,550,489 / 143,677,547,747 | Upward in this bounded sample; non-regression unproved |

At `late_core_complete`, both have 20,603,724 live objects and 175,114,357
total allocations. The new ready carrier is allocated before backend, whereas
the old prepared-tail result was allocated later. Removing the backend-tail
intermediate did **not** remove the one total allocation; its exact cause
remains unresolved. The checkpoint allocator bytes and process peak come
from separate harness runs and must not be treated as one timeline.

Raw valid JSON is also retained in
`benchmarks/results/retained_core_continuation_baseline_2026-09-27.json`
and `benchmarks/results/retained_core_continuation_candidate_2026-09-27.json`.
The full generated C stays at `/tmp/blorp-retained-self-base-99b4eedf.c`
and `/tmp/blorp-retained-core-self-refined.c`; the latter has SHA-256
`0d3b3e7f58ca02c7ff66ad25993a1d605e2801cffa22f02e3cfc42c1d743468f`.
Intermediate valid JSON is `/tmp/blorp-retained-core-self-candidate-corrected.json`.
The final JSON SHA-256 is
`58486652619201f8c0a17862daf01cb229b88d3074f08bfe6dd57ed5056551d3`.

Two preliminary results were excluded. The first stage-2 candidate was
accidentally linked at CLI `-O0` because the optimization variable was not
exported to `build_stage2_compiler`; it was never compared. The first O2
measurement passed an explicit `--input-dir`, which the harness canonicalized
to `/private/var/folders/...` while the baseline used `/var/folders/...`.
Generated C then differed first in source-identity names at line 7810, and
its extra discovery/mono work is not candidate evidence. That invalid run is
preserved in `/tmp/blorp-retained-core-self-candidate.json` and `.c`.

## Decision

The user explicitly accepted this retained-memory improvement despite the
one-allocation increase and inconclusive retired-instruction comparison.
This is an exception to the original no-regression criterion, not evidence
that it passed. The mechanism demonstrably frees the obsolete graph before
emission and lowers live objects and peak memory. The remaining one
allocation is unexplained; three instruction samples per side show a small
upward delta, and no alternating confirmation was run. The measured baseline
is `99b4eedf9682f7539e745cdb3afea2bc237801af`; local main later advanced
to `770d6f8e7` in unrelated work. These counters do not predict the combined
main result.

## Review and validation

All validation ran in `/Users/keithphilpott/.codex/worktrees/c196/blorp`,
serialized by `/tmp/blorp-memory-pilot-run-20260927.py`. The independent
test-runner reported 66/66 initial focused checks, then
`scripts/compiler-check --changed --base 99b4eedf` passed 184/184: two changed
production sources, three selected suites, and serial CLI smoke. It also
passed `scripts/test --no-build --serial --log-dir
/tmp/blorp-retained-test-runner-sanitize compiler-core-sanitize` at
2,177/2,177; full sanitizer log:
`/tmp/blorp-retained-test-runner-sanitize/compiler-core-sanitize.log`.
Compiler-check's success log directory under `logs/` was cleaned by the
script; its verdict is retained in the test-runner transcript. The gate's
plain `make` changed the checkout binary to CLI `-O0`, runtime `-O2`; current
`compiler-build-status` is FRESH and `bin/blorp` SHA-256 is
`0432b241dbf2ca6201cdaf40e6c2aae9f050042a5b89bd7d39e219b48d1120f9`.
The separate measured stage-2 binary remained `-O2/-O2`.

After the selected gate, two existing failure-path tests were tightened to
pass nonempty prior phase timings and assert exact order, prefix duration,
and a lower bound on outer elapsed time. The changed source typechecked, and
the owning late-Core suite passed 13/13 again. The independent reviewer
approved both the implementation and final test-only edit with no findings
(P0/P1/P2: 0/0/0). `git diff --check` passed.
