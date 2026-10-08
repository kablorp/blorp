# Ranked tensor ABI reader: final independent correctness validation

**PASS.** The final frozen reader cut was validated read-only in `<worktree:reader-cuts>`. Session 15139 exited 0; the shared serial native slot is released and no owned children remain. Resource acceptance was not run by this batch.

| Gate | Actual result |
| --- | --- |
| O2 make and build status before/after gates | PASS; FRESH, CLI/runtime `-O2` |
| Changed plan (`--base 2ee201fb5cb74e8a7b4f3d068a143d8d71dd2bad`) | Exactly 2 production sources, 5 suites, Core sanitizer and generated-C audit |
| Selected compiler check | 2913 passed, 0 failed (tool-reported aggregate) |
| Serial `compiler-blorp` | 6782 passed, 0 failed |
| Contextual tensor specialization | 36 passed, 0 failed |
| Checked get/set runtime | 14 passed, 0 failed |
| Tensor multi-index runtime | 5 passed, 0 failed |
| Frozen source oracle compile/run | PASS; run exit 0 |
| Whole emitted-C oracle identity | PASS; 39,058 bytes, byte-identical to retained baseline |
| Actual magic-spelling enforcement (`--strict`, without `--report`) | PASS; 502 allowlisted findings, 0 new, 0 stale |
| Identity census (`--check --json`) | PASS; 3446 rows |
| `git diff --check` | PASS |

The selected check ran the codegen audit once with `BLORP_CODEGEN_AUDIT_JOBS=1`; no separate duplicate audit was run. `compiler-check` removes its successful child logs, so 2913 is its retained authoritative aggregate, rather than a claimed per-component breakdown. Gate counts overlap and are not summed into a unique-test total. The Core sanitizer selection includes the accepted, uncommitted dictionary source cut inherited by this tree.

No failures occurred in this final batch. Earlier syntax and output-assertion mistakes in added baseline controls remain documented in the original baseline/retry packets; they were tests-only corrections, not production fixes. The corrected baseline and preparation qualification passed before final reader deletion.

Authority: HEAD `2ee201fb5cb74e8a7b4f3d068a143d8d71dd2bad` plus the accepted dictionary cut and reviewed ranked cut; the checkout is intentionally dirty. Final compiler SHA256 is `4ec66620466ba1b0328bdbc5a79f86a9e2a2a092a6c4e4eb21ccc5e15661e547`. The actual reviewed ranked 3-path HEAD boundary patch is `04767397e49bbe354dc5137e31f93e72c38a539f79078d43e4d9eff857dfda57`; its raw allowlist diff includes the inherited dictionary row plus the two ranked rows.

Final source fingerprints: production patch `a665ac224d871d0645e10ee2b532361ebc2bbee8362bb77a64327b9323961e91`, compiler/test/allowlist patch `d7a8f5796f9707131d2c50cf0f4a6934f16ab921331b277db1e2b209ed323952`, full tracked patch `c9ded83a6c445b184aef19f2b30c90dfaf12cf9451e6b3337f255453e199cf57`. Source, tests, allowlist, docs and frozen scratch inputs remained unchanged. All 14 record-validation packets report `source_changed_during_run=false`; post-make source/generated/bin guards held. The allowed generated-input delta during initial make was actually empty.

Oracle input SHA256 `8c9aca635816a35891825e6f784f99c3ea6153a74b991bddb21742b11524e57f`; retained baseline and final C SHA256 `6d6faf6b39697b83663601ccb585c959b67728f2395436886dc4a1f2c0bd8ac7`. The baseline was the same post-dictionary source compiler, before ranked preparation/deletion. The fixture covers ranks 3/4/5, Float/Float32/Float16/Int/String/fixed-record payloads, negative wrap and scalar OOB zero. Baseline C readback identifies typed-width runtime calls, erased/scalar unboxing, and guarded inline fixed-record reads; final whole-C identity preserves those paths. Standalone prepared-emitter controls are distinguished from full production-pipeline projection; this report does not claim production reachability for every manually constructed Builtin path.

Exact commands, environment, timestamps and outputs are in [commands.json](commands.json), [qualification-results.json](qualification-results.json), the per-command validation packets, [selected-plan.json](selected-plan.json), [post-make-frozen-provenance.json](post-make-frozen-provenance.json) and [RELEASE_PROOF.json](RELEASE_PROOF.json). [PRESERVATION_MANIFEST.json](PRESERVATION_MANIFEST.json) pins this report and the complete final scratch packet. No source/test/doc/baseline/allowlist edits, commits or resource measurements were performed by the test-runner.
