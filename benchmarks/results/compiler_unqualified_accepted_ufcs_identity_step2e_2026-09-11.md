# Unqualified Accepted UFCS Identity Step 2e Results — 2026-09-11

- Baseline compiler: `d147addc15619c8b8764e447b3446ae5298452e8c89e7883a950770ed6723665`
- Candidate compiler: `8f696a68f6e60bf88758f9cd7c66a4dc933cda42fdf85ba04ef18fdf23ef296b`
- Baseline source revision: `1c71dd25`
- Platform: macOS arm64, `/usr/bin/time -lp`
- Sampling: one retained baseline/candidate pair per screen; no repeated wall
  time sampling

## Focused allocation screen

A temporary in-process probe reset `MemStats`, then called the unchanged
`test_typecheck_source_selects_pure_imported_ufcs_overload` bridge regression
64 times. This exercises unqualified accepted selection and purity-flexible
retry. Both runs reported `valid=True`.

| Metric | Baseline | Candidate | Change |
| --- | ---: | ---: | ---: |
| Allocations | 2,721,280 | 2,721,920 | +0.0235% |
| Releases | 2,721,280 | 2,721,920 | +0.0235% |
| Retained objects | 0 | 0 | neutral |
| Retained bytes | 0 | 0 | neutral |

The first exact implementation added 3,264 allocations/releases, or 51 per
fixture. Short-circuiting lower-precedence visibility tiers and constructing
the combined argument-type list once reduced the final delta to 640, or 10 per
fixture. The scratch probe was removed after measurement.

## Changed-path native screen

```bash
/usr/bin/time -lp bin/blorp test \
  --profile-mode exact \
  --profile-module blorp/src/compiler/stage_06_typecheck/type_system/accepted_callable_authority \
  --profile-module blorp/src/compiler/stage_06_typecheck/infer \
  blorp/test/compiler/stage_06_typecheck/test_typecheck_bridge.brp
```

Both runs passed all 117 tests.

| Metric | Baseline | Candidate | Change |
| --- | ---: | ---: | ---: |
| Retired instructions | 174,070,899,229 | 174,062,255,128 | -0.0050% |
| Cycles | 45,115,285,495 | 45,358,483,974 | +0.5391% |
| Maximum RSS | 796,049,408 | 765,788,160 | -3.8014% |
| Peak footprint | 589,398,808 | 588,694,296 | -0.1195% |

Observed wall time moved from 15.42 to 14.51 seconds. This is one noisy
compile-plus-test pair and is not a latency claim.

## Build-level resource screen

```bash
env BLORP_COMPILER_BENCHMARK_SKIP_BUILD=1 /usr/bin/time -lp \
  benchmarks/compiler_typecheck_phase_profile bodies 1 32 4 16 16 memory
```

Both runs produced semantic checksum `2057305071532051463`, constructor
checksum `-2142865109331864226`, 34 primary outputs, and zero secondary outputs.
This fixture does not execute unqualified UFCS; it is a broad build regression
guard only.

| Metric | Baseline | Candidate | Change |
| --- | ---: | ---: | ---: |
| Allocations | 17,232 | 17,232 | neutral |
| Releases | 12,924 | 12,924 | neutral |
| Retained objects | 4,308 | 4,308 | neutral |
| Allocated bytes | 350,408 | 350,408 | neutral |
| Retired instructions | 6,275,205,190 | 6,275,862,592 | +0.0105% |
| Cycles | 1,720,979,924 | 1,735,485,407 | +0.8429% |
| Maximum RSS | 24,936,448 | 25,001,984 | +0.2628% |
| Peak footprint | 17,645,880 | 17,695,056 | +0.2787% |
| Compiler bytes | 19,424,512 | 19,425,808 | +0.0067% |

Candidate setup and measured-window times were 432,584 and 17,727
microseconds. Baseline observations were 435,233 and 17,943 microseconds.
Those one-shot times are retained without a latency claim.
