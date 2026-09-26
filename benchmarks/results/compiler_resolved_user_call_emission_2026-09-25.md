# Resolved user-call emission

Date: 2026-09-25 (America/Los_Angeles). Baseline is
`2d51ff0d6a06860c9b4a87b4ecb232e78bcd3f19`; candidate is the uncommitted
`codex/resolved-user-call-ids` worktree based on that revision. This is a
backend-only optimization, not an ID-only Core representation migration.

## Boundary and census

Core `def_id` is module-local: resolution still needs the qualified source name
to distinguish colliding IDs. The artifact-wide ID-keyed C emission plan is
validated by `prepare_c_emission_symbols`. After that boundary, `emit.brp`
now looks up the projected spelling by ID at each resolved user-call consumer
instead of reconstructing a `UserCall` carrying a projected String. The
unprojected test authority keeps its source-name fallback; unresolved and
collision validation stay in C symbol projection. No second Core tree or
whole-program declaration table was added.

The frozen self-compile census used a FRESH base compiler and:

```bash
bin/blorp compile --dump-core-after=lower,resolve,perceus,final --dump-core-file=/tmp/blorp-resolved-call-census-2d51ff0d.core.txt --stop-after=final --no-format blorp/src/main.brp
```

Counts are `UserCall` nodes with `Some(def_id)` / `None`, followed by serialized
source-name bytes in the dump (not measured live heap bytes):

| Boundary | `Some` | `None` | Name bytes |
| --- | ---: | ---: | ---: |
| lower | 0 | 0 | 0 |
| resolve | 99,184 | 0 | 6,091,801 |
| perceus | 94,903 | 0 | 5,694,040 |
| final | 65,105 | 0 | 5,385,014 |

The dump was 1,445,658,665 bytes (SHA-256
`a65ae4be2572058f5fbff20736e0fbf6db04cc939eb7`) and was deleted after
retaining the command, counts, and hash. It is not a retained artifact.

## Matched measurement

Baseline worktree:
`/Users/keithphilpott/.codex/worktrees/resolved-call-baseline/blorp`.
Candidate worktree:
`/Users/keithphilpott/.codex/worktrees/resolved-call-identity/blorp`.
Both used Apple clang 21.0.0 (`clang-2100.3.34.2`), bootstrap
`dev-048a5864cd98`, CLI and runtime `-O2`, and a self-built stage-2 compiler
(`compiled_by: self-2d51ff0d6a06`). In each worktree:

```bash
BLORP_CLI_C_OPTIMIZATION=-O2 make
BLORP_CLI_C_OPTIMIZATION=-O2 scripts/compiler-build-status
BLORP_CLI_C_OPTIMIZATION=-O2 benchmarks/build_stage2_compiler bin/blorp-stage2
```

Both build-status checks reported `FRESH`. Stage-2 binary SHA-256 was
`51370d79cfe9f74cad03790aa6868d0327b3a915ecdffe9c0e39ff3611b473fd`
for baseline and
`93f16440d2dc015395febd71d9f7afa9c4570b78da4d1dbb351c3746bd8e8f25`
for candidate. The C used to build these *different compiler binaries* was
78,266,351 bytes / SHA-256
`3ce3ae9ea84ecbec6f4400b1edffedecaa74e7e64e95bd03a0dc323080e14b21`
for baseline and 78,268,664 bytes / SHA-256
`6a5af5cdd9e1fddbb469e1c9b5eaa1ebd7d0037e457c49fea7bda061bc26ef0c`
for candidate.

The input was frozen with:

```bash
benchmarks/self_compile_measure freeze --rev 2d51ff0d6a06860c9b4a87b4ecb232e78bcd3f19
```

Frozen input path:
`/var/folders/m7/zszgqft538nfx_qr1kmc7dlc0000gn/T/blorp-perf-input/2d51ff0d6a06860c9b4a87b4ecb232e78bcd3f19`.
The final clean sequence alternated baseline/candidate/baseline/candidate,
with a foreign compiled-process preflight between runs. From each matching
worktree, the commands were:

```bash
BLORP_CLI_C_OPTIMIZATION=-O2 benchmarks/self_compile_measure --compiler bin/blorp-stage2 --skip-build-check --label resolved-call-base-clean-a --input-rev 2d51ff0d6a06860c9b4a87b4ecb232e78bcd3f19 --samples 1 --output /tmp/resolved-call-base-clean-a.json
BLORP_CLI_C_OPTIMIZATION=-O2 benchmarks/self_compile_measure --compiler bin/blorp-stage2 --skip-build-check --label resolved-call-candidate-clean-a --input-rev 2d51ff0d6a06860c9b4a87b4ecb232e78bcd3f19 --samples 1 --baseline /tmp/resolved-call-base-clean-a.json --output /tmp/resolved-call-candidate-clean-a.json --require-identical
BLORP_CLI_C_OPTIMIZATION=-O2 benchmarks/self_compile_measure --compiler bin/blorp-stage2 --skip-build-check --label resolved-call-base-clean-b --input-rev 2d51ff0d6a06860c9b4a87b4ecb232e78bcd3f19 --samples 1 --output /tmp/resolved-call-base-clean-b.json
BLORP_CLI_C_OPTIMIZATION=-O2 benchmarks/self_compile_measure --compiler bin/blorp-stage2 --skip-build-check --label resolved-call-candidate-clean-b --input-rev 2d51ff0d6a06860c9b4a87b4ecb232e78bcd3f19 --samples 1 --baseline /tmp/resolved-call-base-clean-b.json --output /tmp/resolved-call-candidate-clean-b.json --require-identical
```

| Clean run | Retired instructions | Peak RSS bytes |
| --- | ---: | ---: |
| baseline A | 164,608,832,391 | 2,127,855,616 |
| candidate A | 164,543,243,474 | 2,133,016,576 |
| baseline B | 164,708,324,129 | 2,129,313,792 |
| candidate B | 164,636,262,182 | 2,133,229,568 |

Both paired instruction deltas are approximately -0.04%, within the 0.2%
noise threshold; no speedup is claimed. Candidate peak RSS was about 5 MB
higher in both pairs. Deterministic allocation and retained-state values were
identical across the clean samples within each build:

| Metric | Baseline | Candidate | Change |
| --- | ---: | ---: | ---: |
| Total allocations | 211,869,407 | 211,674,847 | -194,560 (-0.092%) |
| `backend_emission_complete` allocations | 19,404,515 | 19,209,955 | -194,560 (-1.003%) |
| `pass_resolve_backend_match_fused_complete` allocations | 3,127,689 | 3,127,689 | 0 |
| `pass_ownership_contracts_complete` allocations | 7,262,625 | 7,262,625 | 0 |
| `pass_prepare_complete` allocations | 808,501 | 808,501 | 0 |
| `cleanup_plan_complete` allocations | 1,068,122 | 1,068,122 | 0 |
| `cancellation_plan_complete` allocations | 9,186,847 | 9,186,847 | 0 |
| Retained `current_objects` | 21,309,847 | 21,309,847 | 0 |
| Retained allocator bytes in use | 1,901,701,712 | 1,901,701,712 | 0 |

All frozen-input generated C was byte-identical: 83,571,359 bytes, SHA-256
`def0412c02c063515325f420bf765de79c1bf12240f6a39fde6363254865a106`.
Generated C was also inspected at projected `brp_2G` declaration, definition,
and calls. The four raw JSON paths above are `/tmp` artifacts and may expire.
Earlier groups at `/tmp/resolved-call-base-stage2-O2.json`,
`/tmp/resolved-call-base-clean-stage2-O2.json`, and
`/tmp/resolved-call-candidate-stage2-O2.json` overlapped unrelated stage-2
build or compiler-sanitize activity. They are excluded from instruction and
RSS conclusions; only their diagnostic allocation/C-identity evidence was
used.

## Validation and verdict

Focused `test_c_symbol_projection.brp` and `test_core_emit.brp`: 381 passed,
0 failed (39 and 342 respectively). The changed-source selector passed 373
tests in four suites and one generated-C audit:

```bash
BLORP_CLI_C_OPTIMIZATION=-O2 scripts/compiler-check --changed --base 2d51ff0d6a06860c9b4a87b4ecb232e78bcd3f19
```

The direct codegen audit passed 221/221; `scripts/compiler-check
--validate-manifest` reported 345 production modules, 253 suites, and 10
checks. The broad gate was:

```bash
scripts/test --no-build --log-dir /tmp/blorp-resolved-call-final compiler-blorp
```

It exited 0 with `BLORP_GATE_RESULT gate=test status=PASS passed=5115
failed=0 tests=5115`; log:
`/tmp/blorp-resolved-call-final/compiler-blorp.log`. Build status was FRESH
`2d51ff0d6a06-dirty`, CLI/runtime `-O2`, Apple clang 21. Independent
test-runner verdict: PASS. Source-review verdict: ACCEPT, no correctness
findings. `git diff --check` passed.

Recommendation: accept this bounded backend cut. It meets byte-identical
output, flat retired instructions, non-regressing total allocations, and a
1.003% backend-emission allocation reduction. Do not infer that module-local
`def_id` can replace source names throughout Core; that requires a separately
proven globally unique callable identity.

Fetched `origin/main` has advanced to
`d84db06c2b9432dd5354f0bdccac59ea4fb78fed`, through `79dae118` (impl
method gathering) and `d84db06c` (resolved variadic dimension builder).
`git diff --name-only 2d51ff0d..origin/main` found no overlap with the
candidate's `emit.brp` or `test_core_emit.brp`. A clean integration/rebase
step is still required before landing; this candidate was measured and tested
on `2d51ff0d`, not retested on `d84db06c`.
