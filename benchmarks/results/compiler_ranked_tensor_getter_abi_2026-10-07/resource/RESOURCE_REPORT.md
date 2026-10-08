# Ranked tensor ABI reader resource report

**PASS within frozen self/small scope; recommend acceptance.** Both exact +0.5% allocations/minimum-instruction ceilings pass with identical C. Foreground scheduler session 49998 exited 0, released the owned slot, and left no owned native children. No subsequent native commands or source edits followed.

| Workload | Baseline allocations | Candidate allocations | Allocation delta | Baseline minimum instructions | Candidate minimum instructions | Instruction delta | C identity |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| Self | 245,078,157 | 245,078,157 | 0% | 228,752,978,176 | 228,938,404,430 | +0.081059602% | identical |
| Small | 1,689,099 | 1,689,099 | 0% | 1,596,391,077 | 1,597,176,349 | +0.049190453% | identical |

Three normal samples per compiler/workload; paired diagnostics provide allocations. Acceptance uses exact `candidate * 200 <= baseline * 201`, not rounded percentages.

| Workload/compiler | Instruction samples in execution order | (max−min)/min | External PID matches over window |
| --- | --- | ---: | ---: |
| Self baseline | 228836767509; 228752978176; 228767036774 | 0.036628740% | 10 |
| Self candidate | 229295137027; 228938404430; 229287632048 | 0.155820339% | 36 |
| Small baseline | 1597131546; 1596750434; 1596391077 | 0.046383935% | 0 |
| Small candidate | 1598447773; 1597176349; 1598544059 | 0.085632999% | 0 |

Background figures are unique observed PID matches, not concurrent counts. Activity is accepted under benchmarks/README.md:1893–1900 and WORKER_CHECKLIST.md:139–142. No quiet-window, latency or speed claim. Flat allocation totals do not prove the helper allocation-free or isolate twelve-case cost. Per-phase allocation deltas are empty.

Self C: 83,981,861 bytes, SHA256 `9f304f4b6c1b0911ff95bc9df3cbc3c6346bb6811b6cf69cae742861bd352e0c`. Small C: 40,512 bytes, SHA256 `8316ceeb6e78c5e7d6431c33d1a22b0b9ff9bb59b2ecd603fbc38b8a5b618abb`. The maintained harness verifies every normal sample's C against paired diagnostic emission, then requires baseline/candidate identity. Unmodified raw JSON/C/logs/commands remain in [comparison/](comparison/).

## Provenance

Baseline: archived `2ee201fb5cb74e8a7b4f3d068a143d8d71dd2bad` plus accepted dictionary production, reusing its sealed stage2 pair without rebuild. [BASELINE_READY.json](BASELINE_READY.json) SHA256 `3cd26b9a7a8bf551c973c4f02007d464b146fce9d2cfc674ab1ad6debf6a0109`. Live pre-edit bin/source freshness is not required after candidate construction.

| Pair | Normal SHA256 | Diagnostic SHA256 |
| --- | --- | --- |
| Baseline | `0de63d8215e2600a6c4123fc97b554189f066a64a0918b8e0fe6a2db6d361cd2` | `5950a64a26fd267486193e331445e2704f9c02599104b762b908460aa8fd1a62` |
| Candidate | `d596204d536dc0171facaa9b1e3f5b22018f9db709a14aecf4b6f74201ec597c` | `a47cbeed6efafa1567f9ba996c6515256db12048037a41948e10274dc0ddd5c8` |

Both actual stage2 pairs: Apple clang21.0.0, aarch64, CLI/runtime O2, split8, exact `self-2ee201fb5cb7`, modes0/1. Outside-repository raw harness revision/freshness unknown and incidental stage field remain unmodified; sealed construction establishes stage2 authority.

Candidate stage1 FRESH before/after, SHA256 `4ec66620466ba1b0328bdbc5a79f86a9e2a2a092a6c4e4eb21ccc5e15661e547`; emitter `24b9bf114c3db06ba8277bccff6e1559d147ad112adc99a33df6991984bebc31`; three-path patch versus2ee `04767397e49bbe354dc5137e31f93e72c38a539f79078d43e4d9eff857dfda57`. Actual post-dictionary delta retires exactly two suffix rows; dictionary/drafts are preserved.

Frozen exact2ee input inventory `b4791d0dda99868f86e18250c58ad572b53695d848a3e8e95588482a39054db2`; small source `6a67158fb09aac383ec40e77e5c5b1d64fd068b19edf6e2596a6f25060d9cc93`. Full candidate tracked/untracked/generated inputs were pinned and protected.

Independently approved controller `a599e6b377739266fcf656ad893ff9c73cc31e7cdb7248261f015191eff270aa` and configuration `ed10faeb10f2d3cad558daff36502a8f89e0f4b7fab42e2732f8adf22197ca53`. Construction artifacts are pinned immediately against builder-log hashes; original controller and bounded repair remain retained.

Final [COMPARISON_COMPLETE.json](comparison/COMPARISON_COMPLETE.json) SHA256 `df45e885a18a5703863576b431c9ad769dd681e24365b5c7b3c95bc3a1082dba` seals28 payloads. Construction and raw JSON/C pins were guarded subsequently; all four records/saved C reread and budgets recomputed before PASS. Baseline seals rechecked.

## Independent source review

**APPROVE: 0 blockers, 0 should-fix, 0 nits.** One exact twelve-name private ABI admission supplies immutable facts; renderer matches three representations. CoreUnboxKind/struct-unbox authority is unchanged. No runtime ABI/Core schema/ownership changes. [APPLIED_FINAL_REVIEW.md](APPLIED_FINAL_REVIEW.md) SHA256 `736779afdcce1d935a731b0eaa1bffd7c53e0cbb5fc1cce7db3c2edd08577082` retains scope and test evidence.

Seven controls pass before refactor; no bug/TDD claim. Standalone Builtin scalar-renderer coverage and production DirectRuntimeCall/StructUnbox coverage remain qualified separately. Earlier fixture syntax/output-premise corrections are preserved in implementation/validation history. Independent correctness and required hygiene gates passed separately; aggregate counts overlap.

## Completed invocation and release

```sh
python3 /tmp/blorp-identity-wave-7ab679600/native_slot_serial.py \
  --cwd <worktree:reader-cuts> --wait-seconds 600 -- \
  python3 -B /tmp/blorp-ranked-tensor-reader-resource/compare_resources.py --run-comparison
```

[NATIVE_RELEASE.json](NATIVE_RELEASE.json) records session49998 exit0, all nine commands exit0, controller children finished and slot released. This completed invocation must not be rerun over sealed outputs. No wider performance or architecture claim follows.
