# Combined three reader cuts: resource acceptance

PASS within the frozen self/small allocation and minimum retired-instruction scope. Both whole C outputs are identical and both metrics meet the unchanged exact +0.5% ceiling (`candidate * 200 <= baseline * 201`). The approved candidate-only batch exited 0, all owned native processes finished, and the shared slot is released. No source/test/docs edits or commits were made by this worker.

| Workload | Allocations, baseline → combined | Delta | Minimum retired instructions, baseline → combined | Delta |
| --- | --- | --- | --- | --- |
| Frozen self | 245,056,112 → 245,056,522 | +410 (+0.000167309%) | 229,157,014,450 → 228,946,800,997 | −0.091733370% |
| Small | 1,689,044 → 1,689,044 | 0% | 1,596,202,656 → 1,597,845,135 | +0.102899152% |

Self's extra 410 allocations occur only in `pass_tensor_specialize_specialize_fused_complete` (1,791,491 → 1,791,901). All other self phase allocation deltas and all small deltas are identical. Complete verbatim harness output, including every table row and RSS observations, is retained in [comparison-self.txt](comparison-self.txt) and [comparison-small.txt](comparison-small.txt). RSS and wall time are not acceptance metrics here.

## Samples and output identity

Self baseline instruction samples: 229395679419, 229157014450, 229166683493; combined: 228999382296, 228946800997, 229016715548. Min/max spreads relative to minimum: 0.104149100% baseline, 0.030537466% combined.

Small baseline samples: 1596202656, 1597768721, 1598054054; combined: 1597845135, 1598104733, 1598314526. Spreads: 0.115987653% baseline, 0.029376501% combined.

Every workload uses three normal instruction samples plus paired diagnostic allocation accounting. Frozen self C is 83,979,351 bytes, SHA256 `4c4a5cc547c51e405a0c0aa1a707f812966c694496d5ca17e1eb1b8c9fc733e1`; small is 40,512 bytes, SHA256 `8316ceeb6e78c5e7d6431c33d1a22b0b9ff9bb59b2ecd603fbc38b8a5b618abb`. Saved C hashes match raw records; the standard harness enforces whole-output identity with `--require-identical`. Large C files remain at their original scratch paths recorded in [FINAL_RESOURCE_RESULT.json](FINAL_RESOURCE_RESULT.json); this modest evidence packet retains their hashes instead of duplicating them.

## Provenance and acceptance boundary

All three reviewed cuts are included: semantic-variable equality uses existing kind, backend projection reuses exact filter-map admission, and vector Option specialization uses existing explicit type/layout facts. Exact HEAD/base is `7ab679600bcefa2fda3d0a14fe4b432758bad91b`. The ordered four-production/three-test/allowlist patch SHA is `c99980103f311052f7e1ed5e46afbf199b6e92c79a2e9e8619d82793086afaee`; unrelated document changes are excluded. [expected.json](expected.json) and [expected-boundary.patch](expected-boundary.patch) retain that boundary.

The pinned FRESH combined stage1 generator is SHA `522ffdece99511889d86c9de6741ddac847efd6aa49f5a7e77c252e8e26f9d9a`. This batch built one custom stage2 pair from it without rebuilding stage1:

- Combined normal: `bin/blorp-reader-cuts-stage2`, SHA `13c7587335fe971a01d2857963451e44b528ba9ac107084494ce60e4bfba65bf`.
- Combined diagnostic: `bin/blorp-reader-cuts-stage2-diagnostic`, SHA `d051465980b7bb33c9196a347f29702577d25d59c9438a192dd981a8fa3089af`.
- Retained baseline normal/diagnostic: SHA `789ea481aa37eb676449d1fb65ea7f5492f4d5835d05e0335477faac1acba859` / `5df0efcfb1ec8bff9948b19e22c273d3361bace65128e0de4450ea8309d96b29`.

Normal and diagnostic headers match Apple clang 21.0.0 (clang-2100.3.34.2), aarch64-apple-darwin, split 8, CLI/runtime O2 and `self-7ab679600bce`; memory modes are 0/1. Existing accepted first-pair parent binaries were preserved and their hashes rechecked.

Only VALID wave3 baseline JSON/C were reused; no baseline measurements were repeated and no earlier rejected records supplied metrics. All baseline JSON/C pins were checked before and after. Frozen input was compared byte for byte with all 3,871 exact-base archive files; only `.complete` and generated embedded std are additional files. Inventory SHA is `b88e9ec44101451a2478293c1e74142ce198cd05f6a651ce7a349f94c6f2b41f`; generated std SHA `23aa2bba68c427a73d86e407e5d113899c4dcb06ee6f7678dad54718d8075464`. Both small files equal SHA `6a67158fb09aac383ec40e77e5c5b1d64fd068b19edf6e2596a6f25060d9cc93`. Physical paths use `Path.resolve()` on both sides; raw JSON is unchanged. Source/patch/generator/input/pair hashes were checked throughout, and final generator freshness was asserted FRESH. See [post-run-proof.json](post-run-proof.json).

## Exact execution

The approved controller SHA is `d3b2556ac7bcb4a332e8d9c7c5afade1639df39c8c95f6ea1954c7ccbabf52d0`; expectation file SHA is `1bfa394e945b523400680b449e2f21c8b49ac010ec75a9e88eef882571fe3f96`. Independent review approved with zero findings before root GO.

```sh
python3 /tmp/blorp-identity-wave-7ab679600/native_slot_serial.py --cwd <worktree:reader-cuts> --wait-seconds 600 -- python3 /tmp/blorp-identity-wave-combined-resource/resources.py
```

The exact candidate-only measurement commands were:

```sh
benchmarks/self_compile_measure --program self --input-dir $TMPDIR_CANONICAL/blorp-perf-input/7ab679600bcefa2fda3d0a14fe4b432758bad91b --samples 3 --compiler <worktree:reader-cuts>/bin/blorp-reader-cuts-stage2 --diagnostic-compiler <worktree:reader-cuts>/bin/blorp-reader-cuts-stage2-diagnostic --label combined-reader-cuts-candidate-self --output /tmp/blorp-identity-wave-combined-resource/results/resource-candidate-self.json --keep-output /tmp/blorp-identity-wave-combined-resource/results/resource-candidate-self.c --baseline /tmp/blorp-identity-wave-wave3-resource/resource-baseline-self.json --require-identical
benchmarks/self_compile_measure --program small --input-dir $TMPDIR_CANONICAL/blorp-perf-input/7ab679600bcefa2fda3d0a14fe4b432758bad91b --samples 3 --compiler <worktree:reader-cuts>/bin/blorp-reader-cuts-stage2 --diagnostic-compiler <worktree:reader-cuts>/bin/blorp-reader-cuts-stage2-diagnostic --label combined-reader-cuts-candidate-small --output /tmp/blorp-identity-wave-combined-resource/results/resource-candidate-small.json --keep-output /tmp/blorp-identity-wave-combined-resource/results/resource-candidate-small.c --baseline /tmp/blorp-identity-wave-wave3-resource/resource-baseline-small.json --require-identical
```

All setup/version/freshness commands, timestamps, exit codes and observed background process details are retained in [resource-commands.json](resource-commands.json); the wrapper command/exit is in [scheduler-command.json](scheduler-command.json). No retry occurred.

## Limits and interpretation

Current repository policy uses minimum-of-runs instructions and permits background activity. Observed matching external PIDs were 8 during combined self and 0 during small; reused baseline windows had background activity as disclosed in their original packet. These are not quiet-window measurements and imply no wall-time or speedup claim. Raw explicit-pair harness metadata says `compiler_stage: 1`; construction/version/hash provenance and summaries establish actual stage2 without rewriting the raw records. This is a resource acceptance for these workloads, not an unlimited performance guarantee. Correctness gates were handled separately by the coordinator's independent runner and were not rerun here.
