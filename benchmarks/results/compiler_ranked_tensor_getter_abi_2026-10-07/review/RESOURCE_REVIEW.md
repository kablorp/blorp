# Independent ranked tensor resource acceptance review

**APPROVE — 0 blockers, 0 should-fix findings, 0 nits.** Read-only review; no native commands, source changes, or raw evidence changes.

The independently retained [RESOURCE_REVIEW_CHECKS.json](RESOURCE_REVIEW_CHECKS.json) recomputes acceptance from all four raw records: three positive normal instruction samples per compiler/workload, their actual minima, paired diagnostic allocations, saved C bytes/hashes, and exact integer ceilings (`candidate * 200 <= baseline * 201`). Cached summaries agree with those calculations.

| Workload | Allocations, baseline → candidate | Minimum instructions, baseline → candidate | Instruction delta |
| --- | --- | --- | --- |
| Self | 245078157 → 245078157 | 228752978176 → 228938404430 | +0.081059602% |
| Small | 1689099 → 1689099 | 1596391077 → 1597176349 | +0.049190453% |

Whole C is byte-identical: self 83,981,861 bytes (`9f304f4b6c1b0911ff95bc9df3cbc3c6346bb6811b6cf69cae742861bd352e0c`), small 40,512 bytes (`8316ceeb6e78c5e7d6431c33d1a22b0b9ff9bb59b2ecd603fbc38b8a5b618abb`).

Rechecked 60 baseline pins, seven construction pins, 28 completion payload pins, all four JSON/C pins, paired O2/toolchain/header authority, frozen inputs, and current full candidate state before documentation integration. The post-dictionary archived baseline and retained stage2 pair establish baseline authority; mutable live baseline freshness is not assumed. Final raw rereads and guard checks protect the proof beyond cached summaries.

The author report accurately records samples/spreads and background PID matches (self 10/36, small 0/0). Acceptance follows repository min-of-runs; no quiet-window, latency, speed, or isolated helper-allocation claim follows. Outside-repository incidental raw metadata remains qualified by construction authority.

Stable release evidence records foreground session 49998 exit 0, nine commands exit 0, finished children, and released owned slot. Scope remains these frozen self/small workloads.

## Exact reviewed pins

- Controller: `a599e6b377739266fcf656ad893ff9c73cc31e7cdb7248261f015191eff270aa`
- Candidate configuration: `ed10faeb10f2d3cad558daff36502a8f89e0f4b7fab42e2732f8adf22197ca53`
- Independent checks JSON: `f1293d74ac4d0343dc8ab5209c51a0032ad003776f1929d2fee49c5a894684c8`
- Completion proof: `df45e885a18a5703863576b431c9ad769dd681e24365b5c7b3c95bc3a1082dba`
- Author report: `/tmp/blorp-ranked-tensor-reader-resource/RESOURCE_REPORT.md`, SHA256 `362e8a1b8bef2af85e4fd6934344d9c599eade903ee1628427a0f644acb28d59`
- Release record: `/tmp/blorp-ranked-tensor-reader-resource/NATIVE_RELEASE.json`, SHA256 `b9d3c7f370d1691f1d1b4ddd5e5dc834d8eef0f7ca356f30093cb6ae874fd7c5`
