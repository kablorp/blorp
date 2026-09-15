# Core Layout Alias-Cycle Membership Probe

## Summary

Issue 98's proposed path-local keyed alias-cycle membership companion was rejected.
The indexed representation reduces modeled membership work to one lookup per
request, but it increases allocations and does not produce an accepted elapsed
win on the retained shallow and wide/deep probes.

## Provenance

- Repository revision: `9ecb72e934c42f730fe15b5f3f05ee62a76db5f6`
- `bin/blorp`: `FRESH`
- Benchmark compiler SHA-256:
  `6f51f2188c9ecbca1c4cda7a7f0a063621a1ece5374669efda8bf48713460bc3`
- Benchmark fixture SHA-256:
  `b9057eb58ba1dbc51cbc51bda5f5b234cef4197f03ae8ba6b6c7c7fdf23cf82c`
- Benchmark main SHA-256:
  `3997764cb3239a983c2928b40e41d33decfe01cabebfa9f0396cc56662a46634`
- Benchmark runner SHA-256:
  `0ea11061cbd53fe0f3db16ba6c591e04a9c9a8f325c27cf5c70c18a8a75b97cc`
- Raw samples:
  `/tmp/blorp-core-layout-alias-cycle-formatted-20260914224722.log`
- Raw sample SHA-256:
  `db59112f6b327d558f51965e5bf302ddef149d86755f74549584f19dfe7650c3`

Retired-instruction counters were not collected on this macOS host. The closest
direct counters are deterministic membership requests, modeled name
comparisons/lookups, recursive resolutions, allocations/releases, and elapsed
microseconds from the benchmark's measured window.

## Command

```bash
BLORP_COMPILER_BENCHMARK_SKIP_BUILD=1 \
  benchmarks/compiler_core_layout_alias_cycle_profile \
  plain list 200 256 3 2 reuse

BLORP_COMPILER_BENCHMARK_SKIP_BUILD=1 \
  benchmarks/compiler_core_layout_alias_cycle_profile \
  plain indexed 200 256 3 2 reuse

BLORP_COMPILER_BENCHMARK_SKIP_BUILD=1 \
  benchmarks/compiler_core_layout_alias_cycle_profile \
  plain list 50 256 24 4 reuse

BLORP_COMPILER_BENCHMARK_SKIP_BUILD=1 \
  benchmarks/compiler_core_layout_alias_cycle_profile \
  plain indexed 50 256 24 4 reuse

BLORP_COMPILER_BENCHMARK_SKIP_BUILD=1 \
  benchmarks/compiler_core_layout_alias_cycle_profile \
  plain list 50 128 24 4 distinct

BLORP_COMPILER_BENCHMARK_SKIP_BUILD=1 \
  benchmarks/compiler_core_layout_alias_cycle_profile \
  plain indexed 50 128 24 4 distinct
```

Each row below is the median of five samples. Fixture setup is outside the
measured window. Checksums were identical between list and indexed strategies
for every shape.

| Shape | Strategy | Requests | Names Compared / Lookups | Recursive Resolutions | Median Allocations | Median Releases | Median Elapsed µs | Checksum |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| shallow | list | 563,200 | 768,000 | 614,400 | 7,424,002 | 7,424,001 | 1,102,710 | 746,905,600 |
| shallow | indexed | 563,200 | 563,200 | 614,400 | 7,936,002 | 7,936,001 | 1,430,042 | 746,905,600 |
| deep reused | list | 1,587,200 | 18,892,800 | 1,600,000 | 19,955,202 | 19,955,201 | 3,438,299 | 3,196,627,366,400 |
| deep reused | indexed | 1,587,200 | 1,587,200 | 1,600,000 | 20,851,202 | 20,851,201 | 3,390,601 | 3,196,627,366,400 |
| deep distinct | list | 793,600 | 9,446,400 | 800,000 | 9,977,602 | 9,977,601 | 1,769,550 | 1,598,313,683,200 |
| deep distinct | indexed | 793,600 | 793,600 | 800,000 | 10,425,602 | 10,425,601 | 2,659,023 | 1,598,313,683,200 |

## Decision

Reject the production alias-cycle membership index. It meets the modeled
comparison target but fails the acceptance gate: allocations increase by roughly
4.5-6.9%, shallow elapsed regresses by roughly 29.7%, deep distinct elapsed
regresses by roughly 50.3%, and the tiny deep-reused elapsed gain is too small
and too noisy to offset the allocation regression. The existing ordered path
list remains the better representation for the measured Core layout resolver
workload.
