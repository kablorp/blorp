# Test-runner report: global initializer nesting fix

Verdict: **APPROVE the bounded fix validation**. All accepted correctness/cost/fixpoint components passed, with no failures in the final accepted components. Final fix+Mono integration still requires the full host/Linux landing gates; the original combined Linux compiler corpus has not been rerun here. No native jobs remain.

The fixed source was frozen at HEAD `5b4b9467b11061ea1d77c76045ceb5f61f074398`, emitter `6a3046d175525881ab34939d3f7e1e548ec2f2aedff8ac594a4bedec43b83e76`, Core suite `3c843c0edc419c84ded6939d6e5d6d157f623c13185e9be7a0bd9b3498e36b7b`, and runtime suite `be1fd1ee444da274550b8d0999229cec98530446c3a6665ee5fe208e8ed4673f`. Ordinary Mac O2 Make produced installed issuer `ff8508a3399a9cf03c15ed3148922ccd62b715c952ebb4e4bd6e9662798c4438`; actual FRESH checks passed before/after the accepted batches. Final source, tests, paying/generated inputs, issuer, logical index, original two architecture drafts, and retained cost products stayed pinned. Expected ignored native construction/cache outputs were separately recorded.

| Correctness component | Passed | Failed |
| --- | ---: | ---: |
| Eight targeted Core controls after fix | 8 | 0 |
| Six owning backend suites (includes all 404 CoreEmit controls) | 442 | 0 |
| Core sanitizer | 2634 | 0 |
| Generated-C audit, one worker | 238 | 0 |
| Leak gate | 1254 | 0 |
| Serial compiler-blorp | 7289 | 0 |
| Census scanner pure unit tests | 32 | 0 |

These counts overlap and are not a unique total. Three ordinary new runtime controls passed; they protect order/COW/alias behavior. Separate default Linux Clang18 ASan/UBSan and leak runs provide the shutdown/ownership checks below. Actual plain strict magic passed with 502 allowlisted findings and 0 stale; census3528, hygiene, diff-check and final FRESH passed.

The shortest typed fail-before loop was 7 PASS / 1 intended functional FAIL. All eight controls pass after the fix. They retain the duplicate temporary, source-binding, branch, free-reference, capture-reference, mismatched temporary spelling and raw-box negative admission behavior.

The supported public300 fixture uses three prior immutable managed globals plus a mutable list of 300 alternating references. Baseline default Clang18 compilation failed at `<stdin>:1012:23` with `bracket nesting level exceeded maximum of 256`. The candidate ordinary, sanitizer and leak executions each exited0 with `global managed list preserved`. Candidate public C is `687fa9dfddfc157ddf3f7516f9abcc5e65a4b759689bbea5f38538b09d56ab25`; the actual final host Core is unchanged from baseline. Raw lexical initializer brace depth fell from302 to3, and actual default Clang acceptance is the decisive compiler oracle. Core JSON omits origin-kind payloads; no origin was inferred from printed names/labels.

Linux used the immutable Ubuntu24.04/Clang18.1.3 image `sha256:b88ff4627daebb6e897a5e6691e25764868a836d23bc03459eecfb62ce183ae2`, ordinary real-Clang O2 Make/FRESH, then the reviewed capture wrapper only for artifact execution. Actual sanitizer compile receipts include `-fsanitize=address,undefined`, `-fno-omit-frame-pointer`, and `-g`; no sanitizer diagnostics occurred. Zero-leak assertions parse the actual reports: public307 allocations/307 releases/0 leaked/0 bytes; runtime3/3/0/0. The runtime suite reporting epoch alone is not a count of all global allocations. Flags/default parser depth were unchanged; public artifact C compilation remained O0. C/headers/argv/driver/issuer and owned-container closure receipts are retained. This was a focused public proof, not a full Linux gate.

Matched cost used ordinary O2 stage2 normal/diagnostic pairs, three normal instruction samples and paired diagnostic allocations, the same independently sealed frozen5b self/small input, small/harness bytes and matching toolchain. Raw `compiler_stage=1` is convenience-flag metadata; ordinary construction plus actual versions establish stage2. The declared fix ceiling is `candidate*100 <= baseline*101` for both allocations and minimum instructions, applied without overrides.

| Workload | Allocations | Minimum retired instructions | Exact 1% ceilings |
| --- | --- | --- | --- |
| self | 284086867 → 284099387 (+0.004407%) | 271222687541 → 270826570677 (-0.146049%) | PASS |
| small | 1753167 → 1753167 (+0.000000%) | 1654609705 → 1654994443 (+0.023252%) | PASS |

All normal samples match their own diagnostic output by the unchanged harness. Small C is byte-identical across baseline/candidate. Self C intentionally changes for the emitter fix: baseline `c3575273aa87563f153291d94d60a7bfc46d1a62b73a9eef31bce53c01f831e5`, candidate `e43a2a118e4a98b2ec5046a05553d81dab6a1781143678b87a1c422f3eba00ef`. Independent self-C review (`self-c-review/SELF_C_REVIEW.md`, SHA `7f6566c09b49a62bd7e8932746ad60f16e4057f2a5ff875d81d8042f92fb553c`) approved the exact 38 DropTemp alias changes with unchanged C outside the initializer and preserved 1113 local declarations / 1672 ordered ownership-list-cleanup lines. The min-of-three protocol permits background work; no quiet-host or speed claim is made. All raw samples remain retained. Independent resource recomputation approved the four raw records, 96 retained artifact pins and exact 1% ceilings (`review/RESOURCE_REVIEW.md`, SHA `cc3d72dec2b551771ea1515094c794c63d1f287f145ee901532cc9deb9fcf6e3`).

Equivalent retained-stage2→stage3 fixpoint passed. The approved ordinary builder used current candidate sources and the retained normal stage2, built stage3, then generated C using stage3. Both whole C outputs are84,974,862B with SHA `bc7a127b8ae89668ccf099b3f716e30a75b80f60ba6e92e840f87a8d6d2d17b9`, also matching the original candidate construction C. `scripts/compiler-fixpoint` itself was not executed; frozen5b measurement C was not used as a fixpoint input. Stage3 binary is `1a2a316e3d202122c2058bf5cbc63223406401582f82c293815618015f11a2b7`; the retained candidate pair remains normal `2ecd961e81d24c587e07f3a997b13e33e2d1123bd6842d3881a3306480bde475` / diagnostic `9cec666e9b200269fa8b5d5cf88ac73b5375a382da59df325cb78062c2d37641`. It can serve as the common-fix baseline for a separately authorized matched Mono comparison if paying authority remains identical.

| Preserved STOP | Actual cause / resolution |
| --- | --- |
| First cost attempt | Native compile exited-15; sender remains unknown. Independent source guard also caught a tests-only edit. No pair/samples accepted; new baseline-attempt2 completed with final tests frozen. |
| First proportional gate attempt | My runner used absent `scripts/check-compiler-identities` after all compiled checks passed. Original STOP/logs preserved. |
| Remaining-only census attempt | Mandatory current census found six candidate exact sites/five caps; exact clean5b passed. No bypass. |
| Fixture/setup controls | Reserved identifier, unsupported global call/CTFE forms, literal fast-path negative control and test assertion grouping are retained as setup/control history, not new compiler regressions. |

Root applied only independently reviewed census metadata `31888873263c6806341467d4779c53da2342a39419c199ece629c20bc9e6bbaf` → `e45c1fcfbf83fd4aa4e0e37173124874b28bcace48c7b589e750551a5e9d35dc`. Six exact C-emission boundary sites/five exceeded caps were admitted; scanner, classifications, existing874 keys, other budgets/boundaries and historical source_revision remained unchanged. Separate actual census/unit/hygiene/diff/FRESH completion passed. The composite verdict links passing compiled logs and both unchanged STOPs; it does not rewrite earlier failures.

Every owned foreground session was consumed and all children waited; Linux owned container was removed. Release receipts show slot free after public82106, initial28407, remaining72633, reconciled48071, cost32377 and fixpoint16786. All baseline/candidate products, raw records, logs, C/objects/versions/native-link copies were rehashed at their closing boundary. No source/test/scanner/baseline/document/index edit or commit by this test-runner.

Evidence is in `focused-core-eight-v2/`, `candidate-short/`, `public-linux-candidate/candidate-attempt1/`, `baseline-attempt2/`, `candidate-cost/`, `fix-gates/`, `fix-gates-completion/`, `fix-gates-reconciled/`, and `fixpoint/` under this scratch root. Exact commands, environment, exits and full logs are retained, not reconstructed. Full landing acceptance, the original combined default Linux compiler corpus and the Mono-only0.5% comparison remain separate pending work.

Closing authority:

- `baseline-attempt2/BASELINE_COMPLETE.json` SHA `55687abf162e8b2c03efe7b53bc394e8c8dcfb96e0a1d7b82ff0c84f0da4ae8a`.
- `candidate-cost/CANDIDATE_COMPLETE.json` SHA `044d27e14f88b3dc59440c7d9f7695e1f444c1e1568e01ae77dac87e4acbe49c`.
- `fix-gates-reconciled/FINAL_RESULT.json` SHA `f89b07325b5c7c5ead1676a127393c8fbb09eda94c0ad45d66e6de5107ce2191`.
- `fixpoint/FINAL_RESULT.json` SHA `043a4a087359e35f8b9fd5efb82dc31e958193c22d28e517ec98a18637d5359f`.
- `fixpoint/NATIVE_RELEASE.json` SHA `bbc7fdc15d4721cb86b25038edae04a0be02d35935e2b140af5ce776ae712c76`.
