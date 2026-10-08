# Vector Option reader: accepted within measured scope

Recommendation: accept the frozen 3-path slice for coordinator integration and
combined validation. No receiver guard is needed on these measurements. No
source changes, commit or integration were performed here. All owned native jobs
have finished and the shared slot is released.

| Workload | Allocation total, base → candidate | Delta | Minimum retired instructions, base → candidate | Delta |
| --- | --- | --- | --- | --- |
| Frozen self | 245,056,112 → 245,056,522 | +0.000167309% | 229,073,908,756 → 228,793,451,928 | -0.122430717% |
| Small | 1,689,044 → 1,689,044 | 0% | 1,597,345,527 → 1,596,550,270 | -0.049786160% |

Both allocations and minimum retired instructions satisfy the exact +0.5%
ceiling. Self's 410 additional allocations occur entirely in
`pass_tensor_specialize_specialize_fused_complete`, which changes from
1,791,491 to 1,791,901 allocations (+0.022886%). Other phase counts are identical;
small's phase counts are all identical. Complete verbatim harness tables are
`comparison-self.txt` and `comparison-small.txt`.

## Samples and output identity

Self baseline instruction samples: 229173938966, 229073908756, 229283639184;
candidate: 228793451928, 228889168143, 228941229966. Min/max spreads relative to
minimum are 0.091555791% and 0.064590152%.

Small baseline samples: 1597850514, 1597345527, 1598293520;
candidate: 1596550270, 1597458070, 1598059829. Spreads are 0.059348024% and
0.094551298%.

Both C outputs are byte-identical: frozen self is 83,979,351 bytes; small is
40,512 bytes. Complete hashes and record paths are in `FINAL_RESOURCE_RESULT.json`.
The three earlier retained/width C oracles also remain identical.

## Provenance, commands and controller repair

Exact base is `7ab679600bcefa2fda3d0a14fe4b432758bad91b`. The reviewed patch
SHA256 remains `3a6d31701c498c106b125e1765a24a60bc5a503db8e6679fe48e9553889548b1`.
Stage1 candidate remains FRESH and SHA256
`d70303de784de23e5c726789451fb953c407d79ac85887f32ad452afee87a9d1`.
Normal/diagnostic stage2 pairs share a compiler body, have runtime modes 0/1,
matching CLI/runtime -O2, Apple clang 21.0.0, aarch64-apple-darwin, and split 8.
Their paths, complete versions, generator and binary hashes are retained in
`results/stage2-pair-provenance.json`. Frozen archive, generated-input, source,
small-workload and pair hashes were checked before and after measurement.

The original reviewed controller (`resources.original-path-check.py`, SHA256
`c20fe03cae9e071ac7d49c998402922a5f6e9d280cc60fbdd0b54f67211410b4`) completed
stage2 setup and both self measurements, then exited 1 on a false path mismatch:
its `/var` reference and the harness's normalized `/private/var` directory name
refer to the same physical frozen input. Raw self records already passed C
identity and budget checks when revalidated with canonical paths.

Coordinator authorized scratch-only canonicalization with `Path.resolve()` and
a small-only continuation. `resources.small-continuation.py` (SHA256
`e387e322e7a14199bff77293ab4bcff08369c76220e131aaf6ff50ce474e5280`) revalidated
retained self evidence and used retained paired binaries for baseline/candidate
small, without rebuild or self-repeat. It exited 0. Original controller, failure
evidence and raw harness JSON remain unchanged. `CONTROLLER_REPAIR.json` records
the correction; `results/resource-commands.json` records exact native argv and
logs for both batches.

Both commands used `native_slot_serial.py` with this worktree and `--wait-seconds
600`; first ran `resources.py`, then `resources.small-continuation.py`. Workload
compiles use `--no-format --no-embed-runtime` and the shared frozen input.

## Independent validation and limitations

Static review approved with zero findings. Frozen base/new-test snapshot fails
exactly two intended regressions; candidate owning suites pass 23 + 18. Independent
selected/owning/Core sanitizer validation passes 2,476, broad compiler gate passes
6,761, and direct C audit passes 232. Strict identity/magic scans and diff checks
pass, with one obsolete reader row retired. Independent test-runner report is
`/tmp/blorp-vector-option-reader-wave3-validation/TEST_RUNNER_REPORT.md`.

Current repository policy (`benchmarks/README.md:1893-1900`,
`docs/WORKER_CHECKLIST.md:139-142`) accepts background activity and uses
minimum-of-runs instructions. Process observation recorded 2/13 background PIDs
for self baseline/candidate and 0/0 for small. These are documented contexts,
not quiet windows. Sample spreads are retained; no wall-time or speed claim is
made. Manual pair selection leaves the harness's incidental compiler_stage field
1; explicit pair provenance and summaries identify actual stage 2 without
editing raw records. Results cover the frozen self and small workloads, not an
unlimited performance guarantee. Combined parent validation remains coordinator
work; this worker has not integrated or committed the slice.
