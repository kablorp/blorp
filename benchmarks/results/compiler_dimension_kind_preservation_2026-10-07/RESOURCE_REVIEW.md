# Independent dimension-kind resource review

**APPROVE — 0 blockers, 0 should-fix findings, 0 nits.** Acceptance covers the frozen self/small resource comparison; final correctness gates remain separate. Read-only review, with no native commands or repository edits.

Recomputed both ceilings from all four raw records: three positive integer normal samples per side/workload, actual minima, and paired diagnostic allocation checkpoints. Every metric passes exact `candidate * 200 <= baseline * 201`; retained comparison summaries agree.

| Workload | Allocations, baseline → candidate | Minimum instructions, baseline → candidate | Instruction delta |
| --- | --- | --- | --- |
| Self | 244863442 → 244863442 | 228763175100 → 228947991780 | +0.080789524% |
| Small | 1689096 → 1689096 | 1598495230 → 1599798388 | +0.081524047% |

Whole saved C is byte-identical and agrees with raw-record hashes/sizes: self 83,843,873 bytes, SHA256 `e203bf534162e77443563c1ff7037a7cef3c245d7f1d51ba4456c8e7ca5aef5e`; small 40,512 bytes, SHA256 `8316ceeb6e78c5e7d6431c33d1a22b0b9ff9bb59b2ecd603fbc38b8a5b618abb`.

Verified all 25 protected payload hashes, four candidate construction pins, both pairs against builder-reported binary hashes, version/command-log hashes, and raw compiler paths/hashes. Actual stage2 headers match: Apple clang21, aarch64, CLI/runtime O2, split8, `self-8fe717e28d46`, modes0/1. Incidental raw `compiler_stage=1` remains unmodified and qualified by explicit retained-pair construction authority.

All 3,873 frozen input paths/bytes and canonical directories agree; small input hash agrees. Frozen bytes were independently checked against exact8fe archive plus regenerated embedded std **after baseline**, then guarded during candidate phases. This timing is retained. Current source inventory differs only in reviewed dim_solver; source `9e152a0c…` and tests `746b60…` remain exact.

| Workload | Baseline normal samples | Candidate normal samples | Baseline/candidate spread, (max−min)/min |
| --- | --- | --- | --- |
| Self | 228763175100; 228995929897; 228795121500 | 229223389486; 228947991780; 229199355917 | 0.101744871% / 0.120288326% |
| Small | 1603432205; 1598495230; 1606118177 | 1599798388; 1600307122; 1607333846 | 0.476882687% / 0.471025478% |

Repository min-of-runs governs acceptance. Background activity is not excluded; there is no quiet-window, latency, speed or isolated-helper-allocation claim. Coordinator reports resource session58160 exited0 and released its slot; correctness validation subsequently uses the scheduler. This reviewer owns no native jobs.

## Exact proof pins

- Comparison: `3e56e4927802e082e37f04a88a72286d9620316ea836824963ed50adfc26b752`
- Candidate controller: `70e3d8e4092fcc0b388d1522b13f621c162a1adfeddfb21529b5f1edc2c49887`
- Baseline controller: `e2bd2662d10ea8ea46a7df3f420f3e1f4a89a8e523696c433aa5f2516b5577f3`
- Candidate pair: `0084f957e01125ba7ccac3ed0fed497c613343981bbf51e3085603aff2d82629`
- Baseline pair: `846f956faf09d9965057de9fe1f807f56cf1eb2a1aaf2266701d0346a68ceada`
- Baseline protected manifest: `8749c6efecefc3853bdd78a67edbb87b53d6b4633973159a84f26032e34575da`
- Frozen input seal: `be53dce39aa5e458fc2af70f39b076445f9dbdd043bb61c1b9a8f9577f002274`
- Raw baseline/candidate self: `cac0eddc888dab3549be4e37c71ca26a2cbc4b1fd9dad889300663a52c386f7e` / `942bbcf0909cbe2ea6f01059a013e4bda4daf7ebdd4544c807f7410f971b7258`
- Raw baseline/candidate small: `c6dae13ba2bf42a15fa786951477d7f4c29487ee31f7fce9c73e4ec25d861b90` / `604ae986612565c54f33588fa115b548fab474fe67b7477ad401798929042089`
