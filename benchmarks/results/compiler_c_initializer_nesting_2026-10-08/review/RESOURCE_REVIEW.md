# Independent final fix review

Verdict: **APPROVE** the actual source/tests/census amendment and this fix's matched resource evidence. Blockers: 0. Should-fix: 0. Nits: 0. Fixpoint and current-main integration remain separate acceptance requirements.

Read-only recomputation verified 96 sealed artifact pins, all four raw records and saved C, builder-reported normal/diagnostic/C/body hashes, 5,862 current tracked files, and the exact 3,952-file frozen `5b4b9467b110` archive plus regenerated standard-library input. All 13 baseline and 11 candidate commands exited zero; final FRESH and resource session32377 consumption/release are recorded. No native command was run for this review.

| Workload | Allocations, baseline → candidate | Minimum retired instructions, baseline → candidate |
| --- | --- | --- |
| self | 284,086,867 → 284,099,387; +0.004407103% | 271,222,687,541 → 270,826,570,677; −0.146048573% |
| small | 1,753,167 → 1,753,167; unchanged | 1,654,609,705 → 1,654,994,443; +0.023252493% |

All four exact integer ceilings `candidate × 100 ≤ baseline × 101` pass. Each side/workload has three normal samples and paired diagnostic allocations with matching O2/Clang21/target/split provenance. The unchanged harness checks each normal sample's C against its diagnostic output. Small C is identical (40,499 bytes, SHA `2033e266…`). Self C intentionally differs (86,893,514 → 86,893,248 bytes); its semantic review and fixpoint are additional requirements. Raw convenience metadata remains `compiler_stage: 1`; retained construction proves the explicit binaries are stage2. Min-of-runs permits background activity; no quiet-host, wall-time or speed claim follows.

Emitter `6a3046…`, suite `3c843c…`, runtime `be1fd1…`, and census `e45c1f…` still match the independent source/C/census reviews. Only six reviewed census keys and five exceeded caps changed; historical scanner metadata and exemptions remain intact. Composite proportional correctness gates passed; overlapping suite counts are not additive coverage. Prior STOPs are preserved. This 1% fix evidence does not accept Mono or earlier-main reader-cut costs.

Proof: [RESOURCE_RECOMPUTATION.json](RESOURCE_RECOMPUTATION.json), SHA `71f83b99e24beb5338b593b406e06ebbf440832de33f0cd0c588cc73fb2a09d2`. Comparison SHA `87204a87a56933b26cf571b7a685a321287e83bd37b2bd9223828751ff9fcf32`; COMPLETE SHA `044d27e14f88b3dc59440c7d9f7695e1f444c1e1568e01ae77dac87e4acbe49c`; release SHA `442f9202fc54895fe661a45f14f59af447d9635687ff4c7474c558a3d91d07a7`.
