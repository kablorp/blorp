# Qualified Accepted UFCS Identity Step 2e Results — 2026-09-11

- Baseline compiler: `64ea7d421dece6d2020435b62b40414d69da94035562046e2013aa87b4cf6315`
- Candidate compiler: `d147addc15619c8b8764e447b3446ae5298452e8c89e7883a950770ed6723665`
- Baseline source revision: `69b98d3e`
- Platform: macOS arm64, `/usr/bin/time -lp`
- Sampling: one retained baseline/candidate pair per screen; no repeated
  wall-time sampling

## Focused allocation screen

A temporary in-process probe reset `MemStats`, then called the existing
`test_typecheck_source_qualified_import_selects_ufcs_receiver` regression 64
times. Both runs reported `valid=True`.

| Metric | Baseline | Candidate | Change |
| --- | ---: | ---: | ---: |
| Allocations | 1,940,672 | 1,940,736 | +0.0033% |
| Releases | 1,940,672 | 1,940,736 | +0.0033% |
| Retained objects | 0 | 0 | neutral |
| Retained bytes | 0 | 0 | neutral |

The exact binding carrier therefore costs one transient allocation and release
per qualified call. Rejected scalar-ID, opaque-slot, and fused-selection
prototypes cost six, four, and three allocations per call respectively. The
probe was removed after measurement; its construction pattern and target test
are documented in Issue 85.

## Changed-path native screen

Command:

```bash
/usr/bin/time -lp bin/blorp test \
  --profile-mode exact \
  --profile-module blorp/src/compiler/stage_06_typecheck/type_system/accepted_callable_authority \
  --profile-module blorp/src/compiler/stage_06_typecheck/infer \
  blorp/test/compiler/stage_06_typecheck/test_typecheck_bridge.brp
```

Both runs passed all 117 tests. The candidate profile observed seven qualified
lookups, seven exact accepted selections, and six accepted call-inference
entries. The baseline profile observed seven qualified lookups through the old
compatibility result.

| Metric | Baseline | Candidate | Change |
| --- | ---: | ---: | ---: |
| Retired instructions | 173,625,860,858 | 173,797,104,031 | +0.0986% |
| Cycles | 47,002,836,620 | 46,332,934,846 | -1.4252% |
| Maximum RSS | 763,379,712 | 761,823,232 | -0.2039% |
| Peak footprint | 586,924,824 | 586,908,416 | -0.0028% |

Observed wall time moved from `17.27` to `16.47` seconds, user time from `16.28`
to `15.77`, and system time from `0.43` to `0.28`. These are one-shot,
compile-plus-test observations and are not latency claims.

## Build-level resource screen

Command:

```bash
env BLORP_COMPILER_BENCHMARK_SKIP_BUILD=1 /usr/bin/time -lp \
  benchmarks/compiler_typecheck_phase_profile bodies 1 32 4 16 16 memory
```

Both runs produced semantic checksum `2057305071532051463`, constructor
checksum `-2142865109331864226`, 34 primary outputs, and zero secondary outputs.
This fixture does not execute qualified UFCS. It is included only to guard
whole-build allocation, memory, instruction, and size regressions.

| Metric | Baseline | Candidate | Change |
| --- | ---: | ---: | ---: |
| Allocations | 17,232 | 17,232 | 0.0000% |
| Releases | 12,924 | 12,924 | 0.0000% |
| Retained objects | 4,308 | 4,308 | 0.0000% |
| Allocated bytes | 350,408 | 350,408 | 0.0000% |
| Retired instructions | 6,274,672,205 | 6,261,557,009 | -0.2090% |
| Cycles | 1,785,861,678 | 1,742,025,887 | -2.4546% |
| Maximum RSS | 24,821,760 | 24,920,064 | +0.3960% |
| Peak footprint | 17,596,728 | 17,629,496 | +0.1862% |
| Compiler bytes | 19,424,368 | 19,424,512 | +0.0007% |

Candidate setup and measured-window times were `489620` and `20096`
microseconds. The comparable baseline observations were `431841` and `18384`;
these one-shot values are noisy and are not performance claims.
