# Accepted Trait-Method Visibility Rows — Step 2e

**Date:** 2026-09-12

**Baseline:** clean `1161c4f6`

**Candidate:** Issue 92 working tree

## Result

Accepted bare trait-method visibility now retains compact, sorted
`SourceNameId + TraitMethodId` rows. The accepted authority no longer owns a
`Dict[String, TraitMethodId]`, and selectively imported methods are resolved to
their exact semantic identity once, at accepted visibility construction.

One baseline/candidate pair was taken for each screen. This is a regression
guard, not a wall-time study.

## Accepted-Authority Screen

The `accepted` workload constructs the accepted authorities directly. Both
runs produced semantic checksum `-6362768653699369705`, constructor checksum
`-2142865109331864226`, 1,257 primary outputs, 65 secondary outputs, 136
accepted constructor rows, 353 accepted field rows, 129 constructor lookup
requests, and zero graph-wide constructor projections.

| Metric | Baseline | Candidate | Change |
| --- | ---: | ---: | ---: |
| Allocations | 264,613 | 265,009 | +0.1497% |
| Releases | 182,652 | 183,048 | +0.2168% |
| Retained objects | 81,961 | 81,961 | neutral |
| Allocated bytes | 6,017,008 | 6,017,008 | neutral |
| Retired instructions | 8,248,591,941 | 8,275,409,206 | +0.3251% |
| Cycles | 2,266,910,937 | 2,295,486,495 | +1.2606% |
| Maximum RSS | 37,634,048 | 37,666,816 | +0.0871% |
| Peak footprint | 30,998,840 | 31,015,224 | +0.0529% |
| Setup microseconds | 387,656 | 420,268 | +8.4126% |
| Window microseconds | 137,888 | 145,529 | +5.5415% |

The representation change is neutral for retained objects and allocated bytes.
The 396 extra transient allocations are released before the retained snapshot;
they amount to six allocation/release pairs per accepted authority construction.
Instructions, cycles, RSS, and peak footprint remain below the packet's 2%
investigation threshold.

The one-shot setup and window readings are not used as latency claims. The
candidate process was visibly descheduled while its large exact-profile report
was waiting for the calling tool to drain output; its external wall time is
therefore intentionally omitted. A future latency claim should use a quiet
counter-only mode or redirect the verbose profile outside the measured process.

## Checked-Bodies Regression Screen

The retained checked-bodies workload provides a second, broad guard. Both runs
produced semantic checksum `2057305071532051463`, constructor checksum
`-2142865109331864226`, 34 primary outputs, zero secondary outputs, 129
constructor lookup requests, and zero graph-wide constructor projections.

| Metric | Baseline | Candidate | Change |
| --- | ---: | ---: | ---: |
| Allocations | 17,244 | 17,244 | neutral |
| Releases | 12,936 | 12,936 | neutral |
| Retained objects | 4,308 | 4,308 | neutral |
| Allocated bytes | 350,408 | 350,408 | neutral |
| Retired instructions | 6,263,132,170 | 6,266,868,348 | +0.0597% |
| Cycles | 1,751,473,154 | 1,752,921,520 | +0.0827% |
| Maximum RSS | 24,887,296 | 24,936,448 | +0.1975% |
| Peak footprint | 17,629,520 | 17,629,520 | neutral |
| Setup microseconds | 422,890 | 422,231 | -0.1558% |
| Window microseconds | 16,215 | 16,388 | +1.0669% |
| Wall seconds | 16.04 | 16.29 | observation only |

The broad guard is exactly neutral for allocation and retained-memory counters.
Instructions, cycles, RSS, peak footprint, and setup remain within 0.20%; the
one-shot measured window remains within 1.1%.

## Compiler Size

| Metric | Baseline | Candidate | Change |
| --- | ---: | ---: | ---: |
| Executable bytes | 19,513,568 | 19,514,016 | +0.0023% |

Compiler size grows by 448 bytes. Generated program C is unchanged because this
packet changes Stage 06 authority representation and lookup only.

## Commands

```bash
make -j1
/usr/bin/time -lp benchmarks/compiler_typecheck_phase_profile \
  accepted 1 32 4 16 16 memory
/usr/bin/time -lp benchmarks/compiler_typecheck_phase_profile \
  bodies 1 32 4 16 16 memory
stat -f %z bin/blorp
```

The baseline and candidate were freshly built from the same bootstrap pin. No
repeated timing pairs were taken.
