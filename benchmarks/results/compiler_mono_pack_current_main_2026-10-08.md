# Mono pack kind and global initializer nesting on current main

Terminal dimension-pack substitution now follows its typed `TensorVariadicDim` variant. Managed global initializers with an admitted constructor/ownership spine emit bounded C nesting while preserving ownership order. Ordinary functions and unsupported initializer forms retain lexical scopes. No parameter carrier, public syntax or compiler-stage rewrite is introduced.

The integration base `98983aa8f512116239a202e66ad7b5cc556c4fec` retains the local benchmark-vocabulary correction above main `5b4b9467b11061ea1d77c76045ceb5f61f074398`. The initializer fix is `c0b7ba1f899a8373255065409e1e7fbff18479f6`; emitter SHA `6a3046d175525881ab34939d3f7e1e548ec2f2aedff8ac594a4bedec43b83e76`. The exact Mono delta is `bdaf1453b8c9a732e7869c0109cf1d51117fbb50`: 46 paths plus 35 byte-preserved historical landing files. Main's 15 unrelated staged files and the original architecture drafts are preserved.

The measured 81-path freeze has tree `7d1dc21214cd05c7b5870102b93ea673a616073f`, diff SHA `1f9a76259d263821f83bd60259081661415aaeb18fbd482708da00f5ba438ab0` and HEAD `c0b7ba1f899a8373255065409e1e7fbff18479f6`. The remaining-gate freeze adds exactly 17 reviewed nonpaying metadata paths: tree `5520411c62e5e04900cc1b3d0c8c90beefba26ca`, diff SHA `da7198a772f2c71dba7d230c0200355de38016052e2d466c647a1ec6f1fc379e`. Compiler and test bytes are unchanged across that bridge. These are validated source freezes, not future commit or remote claims.

## Scope and behavior

The terminal pack's name remains a substitution key; `#_` and the two existing ordinary/value-parameter spelling readers remain. The emitter admits a collision-free spine once per eligible dynamic global initializer, using canonical generated names, lexical/free-reference checks and selected C-type authority. Only immutable typed DropTemp RHSs in admitted initializers use sequential bindings.

The valid 300-element managed-list repro failed at default Clang 18 nesting depth before the initializer fix. Its standalone evidence retains unchanged Core, ordered ownership operations, sanitizer and shutdown-leak checks. Current Linux validation also passes the combined 281 compiler TestSuites that exposed the original nesting failure.

## Matched resource comparison

The common baseline is the retained compiler pair built from 5b with the reviewed initializer fix. Both sides compile the same frozen 5b self input and pinned small program. Reuse authority matches 529 paying sources, 10 headers and 178 auxiliary build/bootstrap/runtime/stdlib/harness/small inputs, except the intended Mono source delta. Authority SHA `5fa5217bd63d3661ebfa2fdb7384a609bebe5f9fb280eb8e3ced3a89b358676d`. The retained 989 benchmark-tag correction is outside paying inputs.

Baseline normal SHA `2ecd961e81d24c587e07f3a997b13e33e2d1123bd6842d3881a3306480bde475`; diagnostic SHA `9cec666e9b200269fa8b5d5cf88ac73b5375a382da59df325cb78062c2d37641`. Candidate normal SHA `8aba4d672a57d48fd49781d95f75d9f22f127fc8b17e8343e47c2794d62c3a92`; diagnostic SHA `960ac531b93fd7538a049262211e5941290d1c4738c350ba0adafc088d6215a3`.

The exact metadata transition is `5b4b9467b110-dirty` / `self-5b4b9467b110` to `c0b7ba1f899a-dirty` / `self-c0b7ba1f899a`, including those version lines. Both pairs use Apple clang 21.0.0 (clang-2100.3.34.2), aarch64-apple-darwin, CLI/runtime O2, split 8 and linked diagnostic modes 0/1. Construction proves actual stage 2; raw `compiler_stage: 1` is convenience metadata.

| Workload | Allocations, baseline → candidate | Allocation delta | Minimum instructions delta | Whole C |
| --- | --- | --- | --- | --- |
| Frozen 5b self | 284,099,387 → 284,099,388 | +1 | +0.040057115% | Identical, 86,893,248 bytes |
| Pinned small | 1,753,167 → 1,753,168 | +1 | −0.077706001% | Identical, 40,499 bytes |

Each side uses three positive normal instruction samples and paired diagnostic allocations. All four exact `candidate × 200 ≤ baseline × 201` ceilings pass. The initializer fix's separate 1% budget does not replace this 0.5% Mono ceiling. Raw instruction spreads are self 163,258,240 → 241,967,220 and small 939,250 → 1,062,290. The min-of-runs protocol permits background activity; no quiet-host, wall-time or speed claim is made.

The [comparison](compiler_mono_pack_current_main_2026-10-08/cost/comparison.json) and four measurement records retain exact values and samples. Accepted original comparison SHA `0fb399a9693edd2e942af90873daf7a10ecf1c60d7c65379ec094c65d0717b86`; full cost FINAL SHA `c6bc39a425391acfce344903a5a45816d6c1a863c9a01b63fbaad08e4034ab00`. Batch 13709 was reaped and released, with raw JSON/C, pair, workload and source guards passing.

## Current composite validation

| Boundary | Actual result |
| --- | --- |
| Owning Mono | 39 passed, 0 failed in guarded cost batch |
| Host Core ASan | 2642 passed, 0 failed |
| Host benchmark tooling | 206 passed, 0 failed |
| Host full test aggregate | 19662 passed, 0 failed |
| Host generated-C audit / runtime UBSan | 238 / 5581 passed, 0 failed |
| Canonical security/drift, metadata hygiene/artifact checks | PASS; census 3528, magic 502 and 0 stale |
| Required Linux/amd64 full CI test aggregate | 19662 passed, 0 failed |
| Linux generated-C audit / smoke / examples / security / drift | 238 passed, 0 failed; all remaining steps PASS |
| Final FRESH and source/index/draft/cost guards | PASS; nine remaining commands exited 0; all children reaped and slot released |

Linux components are compiler 7297, tools 260, new compiler 1064, parity 3673, standard library 1, runtime 4831, leak 1254, doctest 1057, LSP 36 and CLI-deep 189, all zero failures. Compiler coverage includes 281 TestSuites / 6434 cases plus 863 production fixtures. Counts overlap host and sanitizer coverage and are not summed as unique tests.

Host premerge used `--no-docker` with `BLORP_TEST_TIMEOUT=60` and compiler timeout 360. Its ten completed components passed, but batch 58994 **failed security** on 35 machine-local-path citations in 15 ancestor reports; their original bytes equalled clean 5b. Docker and final drift had not run. This STOP, its raw log and release remain unchanged. The reviewed path projection qualifies historical publication bytes while preserving measurement values and hashes.

Remaining batch 57957 completed unchanged canonical security/drift, metadata checks and required full Docker CI. This is component/composite acceptance, **not** a relabelled original full-host PASS. Composite original FINAL SHA `3aaebefeb4172cdb146a758060ed3569e5f51910fccf5e8002e643b238a38d53`; post-gate authority SHA `36e11f44abcae1f888562a580e8da656c8e9fab610fa844bde04bda4b611bdef`.

Docker used SSH `blorp-gate`, immutable Linux/amd64 image `b88ff4627daebb6e897a5e6691e25764868a836d23bc03459eecfb62ce183ae2`, snapshot `0d74f0a13dfa2cdcf366b7f53ee344e9e46f5969` with guarded tree 552041 and parent c0b7. The issuer reports dirty false, compiled by `dev-0e1598ed616e`, Ubuntu clang 18.1.3, CLI/runtime O2, split 8 and memory mode 0. Construction jobs were 2; actual gate split was 8. Printed general/runtime/leak/compiler budgets are 30/60/60/360. Docker intentionally used `--no-sanitize`; host ASan/UBSan and standalone Linux fix sanitizer/leak evidence are separate. No nesting-depth override was requested.

The exact owned remote container was absent after exit; session 57957 was consumed, reaped and the shared slot released. Current FRESH issuer SHA `94fe3cf1bb5c0d5b93ff8af6f79ee3de059450082e63a0141a630af1a4a9d478` is unchanged. Source/resource/closure reviews approved with zero findings; [actual closure review](compiler_mono_pack_current_main_2026-10-08/review/ACTUAL_COMPOSITE_CLOSURE_REVIEW.md) records acceptance. Publication bytes receive a separate final delivery review.

## Evidence and historical qualification

The [original Mono packet](compiler_mono_pack_kind_2026-10-08.md) retains 5e measurements; the [old landing packet](compiler_mono_pack_landing_2026-10-08.md) retains 87 gates. Both are historical; preserved STOPs are not recast as PASS, and neither is latest-main acceptance. The [initializer fix report](compiler_c_initializer_nesting_2026-10-08.md) retains the 5b Linux diagnosis and standalone acceptance, including its historical equivalent fixpoint. No new combined fixpoint is claimed.

The [current packet README](compiler_mono_pack_current_main_2026-10-08/README.md) provides actual published routes. Raw receipts keep their original nested relative references, which describe the private/historical layout. Path projection and lossless gzip preserve numeric metrics, timestamps and source/C/binary hashes. Original nested seal hashes retain original-byte authority; the [publication manifest](compiler_mono_pack_current_main_2026-10-08/PUBLICATION_MANIFEST.json) separately records projected/decoded and stored hashes. Large C, binaries and full inventories remain private with listed original identities. The derived authority receipt identifies its selected fields and original parent hashes explicitly.
