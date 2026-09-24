# Managed union payload S2b probe — parked

## Decision

S2b does not meet the roadmap's predeclared **at least 2% retired-instruction
improvement** gate. Three alternating O2 samples show a median reduction of
0.1052%; deterministic allocations fall by 0.0301%. Park the S2b production
change. This report records a negative experiment; it is not an acceptance
claim or a request to expand the whitelist. No broad gates, merge, or push were
performed for S2b.

## Scope and reach

S2b extends S2a's accepted constructor-storage facts to accepted non-generic
heap-record and tagged-union fields, including transparent aliases by terminal
accepted-header identity. Opaque aliases, unresolved or wrong-identity types,
and pre-monomorphization generic unions remain erased. RecvAttempt and the
all-fields eligibility rule remain unchanged.

Same-base census artifacts: `/tmp/blorp-s2b-s2a-census.md` and
`/tmp/blorp-s2b-s2b-census.md`, with 539-row TSVs beside them. They were made
before final test-expectation-only edits; production sources match the measured
candidate. Census compilers were FRESH with `cli=-O0 runtime=-O2` (the same
flags on both sides), split 8. This census is reach evidence only, not the O2
performance measurement, and stale blocker attribution is intentionally not
used.

| Census count | S2a | S2b | Delta |
| --- | ---: | ---: | ---: |
| Typed Core union declarations (of 539) | 151 | 357 | +206 |
| Erased Core union declarations | 388 | 182 | -206 |
| Typed post-DCE accessors | 847 | 7,773 | +6,926 |
| Erased post-DCE accessors | 41,933 | 35,007 | -6,926 |
| `blorp_box_struct` sites | 264 | 262 | -2 |
| Census self-compile C bytes | 145,714,004 | 145,299,010 | -414,994 |

The census Core snapshots are 1,101,485,733 bytes (S2a,
`327473b57236e3c5214a28f3fac07c12149c5a81894565a0862ece0d40b78876`) and
1,101,429,704 bytes (S2b,
`e0fa7e748f5c1247ed8414eec99af4d74f14cb8125f7ee72586dbc0b1360029`).
Self-compile C hashes are `c1d798330d46dd6a4732c019c715afeaacb426daabd43104b2ae7dcf1174c943`
and `db0c46e89bf31b818dc1c3f54273bf7ce9f8ed9778c07632c53fb8d5540e5c17`,
respectively. These counts show substantial Core accessor reach, but only two
fewer static struct-box sites; they do not establish the roadmap performance
gate.

## O2 stage-2 provenance

Both sources were at HEAD `a1fb8e6a2143d2c2047043a260642d8a8e519ef4`.
S2a was clean; S2b was dirty only from the scoped S2b source and test changes.
Both stage-1 CLIs were FRESH, `cli=-O2 runtime=-O2`, split 8, Apple clang
21.0.0 (`clang-2100.3.34.2`). The stage-2 builder script SHA-256 is identical
in both worktrees: `2e81b163a0c4c52ab43a63d1977b4a6d84b423911a58f038fff25d0809eb0c19`.

| Artifact | S2a | S2b |
| --- | --- | --- |
| Stage-1 `bin/blorp` SHA-256 | `1e6169e213a64e4ce752115566f66a47fe316a3d60a590f027fb06532dc65789` | `f5813db0af88347229316abbc74e4f3fc51d758dd19d5f770f1367aaf1720cb7` |
| Stage-2 generated C bytes | 97,112,745 | 96,791,325 |
| Stage-2 generated C SHA-256 | `c9f948ebdc03ef4856732b468aa38d5d62aafb50642caff76a88a070f36d24ea` | `7fb652d8c6c6d584a8c93c555290c4aaba864ab7cc4533cf3ab25a5b9f7e39eb` |
| Stage-2 binary SHA-256 | `8d4cc5e6ce6f20e0ba52e4dbb3be7154ff65db52be5124a576860f3bb967b7ad` | `8f9c784b33555c6c5d086a1de71bc72b1a931fe2661e27b2b491866c0454c960` |
| `--version` identity | `compiled_by=self-a1fb8e6a`, O2/O2 | `compiled_by=self-a1fb8e6a`, O2/O2, dirty |

Frozen input: revision `d5fe8d9d8288165e6dbe55868c11e060d62b6db4`, directory
`/var/folders/m7/zszgqft538nfx_qr1kmc7dlc0000gn/T/blorp-perf-input/d5fe8d9d8288165e6dbe55868c11e060d62b6db4`.
Each measurement used `program=self`, one sample, and `BLORP_CLI_C_OPTIMIZATION=-O2`.
Stage-2 build logs are `/tmp/blorp-s2b-s2a-stage2-build-O2-lease4.log` and
`/tmp/blorp-s2b-s2b-stage2-build-O2-lease4.log`.

## Measurements

The authorized measurement-only fallback used the prebuilt, hash-verified
stage-2 compilers. Each row was a separate invocation of
`benchmarks/self_compile_measure measure --compiler bin/blorp-stage2
--skip-build-check --input-dir <frozen-input> --program self --samples 1`;
S2a and S2b were alternated in three pairs. Pair 1 kept generated C; all raw
JSON and console logs were retained. Every run exited 0 and emitted stable
within-compiler output hashes.

| Pair | Side | Retired instructions | Total allocations | Generated C bytes | Generated C SHA-256 |
| ---: | --- | ---: | ---: | ---: | --- |
| 1 | S2a | 182,529,553,212 | 232,587,200 | 149,367,008 | `7b55ac381f28b55b78ba3b994f9af1bd1b884bb0e7ff13274dd717696e9fd635` |
| 1 | S2b | 182,219,445,807 | 232,517,156 | 148,945,254 | `9b900837907fa04b03537c3d70f23711d1794b6b6489e90ca4868d5799075329` |
| 2 | S2a | 182,347,813,088 | 232,587,200 | 149,367,008 | same as pair 1 S2a |
| 2 | S2b | 182,204,938,472 | 232,517,156 | 148,945,254 | same as pair 1 S2b |
| 3 | S2a | 182,396,815,527 | 232,587,200 | 149,367,008 | same as pair 1 S2a |
| 3 | S2b | 182,143,526,799 | 232,517,156 | 148,945,254 | same as pair 1 S2b |

S2a instruction min/median: 182,347,813,088 / 182,396,815,527.
S2b instruction min/median: 182,143,526,799 / 182,204,938,472. The median
reduction is 191,877,055 instructions (0.1052%); paired reductions are
310,107,405, 142,874,616, and 253,288,728. Deterministic total allocations
fall by 70,044 (0.0301%); generated C falls by 421,754 bytes (0.2824%).

Changed allocation checkpoint rows (candidate minus parent):

| Checkpoint | Allocation delta |
| --- | ---: |
| `typed_frontend_complete` | +5,998 |
| `core_lowering_complete` | +5,890 |
| `pass_mono_complete` | -3,396 |
| `pass_consume_specialize_complete` | +3 |
| `pass_prepare_complete` | -7,601 |
| `cleanup_plan_complete` | -2 |
| `backend_emission_complete` | -70,936 |
| **Total** | **-70,044** |

Raw JSON/log paths use
`/tmp/blorp-s2b-{s2a,s2b}-pair{1,2,3}-lease4.{json,log}`; retained pair-1 C
is `/tmp/blorp-s2b-s2a-pair1-lease4.c` and
`/tmp/blorp-s2b-s2b-pair1-lease4.c`.

## Validation and measurement caveats

Focused correctness evidence before parking:

| Gate | Result | Evidence |
| --- | --- | --- |
| `test_core_lower.brp` | 150/150 | focused command completed successfully; no separate log retained |
| Full generated-C audit, serial `--jobs 1` | 226/226 | `/tmp/blorp-s2b-codegen-audit-lease3.log` |
| Managed nominal transfer-out runtime | normal 1/1; leak 1/1 (3 allocations, 3 releases, 0 leaked); ASan+UBSan 1/1 | `/tmp/blorp-s2b-managed-nominal-{normal,leak,sanitize}-lease3.log` |

An initial generated-C audit had 222/226 pass because four fixture
expectations still described the old erased C; the typed constructor, field,
destructor, and static-immortal-global C was reviewed, the expectations were
updated without changing production eligibility, and the full audit then passed
226/226. A canonical combined `self_compile_measure --stage2 --samples 3`
baseline attempt was stopped before a valid sample when an unrelated direct
stage-2 job appeared. `/tmp/blorp-s2b-s2a-stage2-O2-lease3.log` is retained but
contains no accepted measurement artifact. The earlier `self_compile_measure
lock` helper was found to be a no-op; final builds and samples were run while
holding `scripts/with-compiler-contention-lease --mode exclusive` on
`/private/tmp/blorp-compiler-contention-501/blorp-compiler-evidence-v1.lock`.
Official shared-gate contenders waited behind that lease. Process scans before
each measurement showed no direct compiler/build job beyond the persistent
`clangd`; uncoordinated direct work cannot be prevented by the advisory lease,
so this remains a host-coordination caveat. No wall-time or RSS claim is made.

Because `--stage2` was omitted for the fallback samples, raw JSON correctly
records `compiler_stage=1`, `compiler_build_status=skipped`, and
`stage2_built_by_bin_blorp_sha256=null`. This label is not a claim that the
measured compiler was stage 1: the explicit binary path, stage-2 build recipe,
`--version` output, and hashes above establish stage-2 identity. Raw JSON was
not edited. Census blockers are deliberately not treated as fresh attribution.

## Recommendation

Park S2b in this experimental worktree. The implementation has focused
ownership/codegen coverage and materially broadens typed Core accessor reach,
but the measured instruction improvement is far below the roadmap's 2% gate;
the tiny static-box reduction does not justify accepting this performance
change as successful. Do not merge or push. Any later reconsideration needs a
new, separately reviewed hypothesis and fresh measurement against the then-
current integrated base.
