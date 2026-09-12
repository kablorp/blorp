# Accepted Unresolved Trait Identity — Step 2e

**Date:** 2026-09-12

**Baseline:** clean `ef2aa260`

**Candidate:** Issue 91 working tree

## Result

Graph-backed unresolved accepted trait calls retain exact `TraitId` values.
The string-backed unresolved variant remains only for graphless compatibility.
Trait-method import rows also preserve their explicit kind beside exact
overlapping definition targets, while bare trait-method visibility excludes
qualified-only traits and receiver-directed UFCS retains exact selection.

## Checked-Bodies Regression Screen

One baseline/candidate pair was taken. Both runs produced semantic checksum
`2057305071532051463`, constructor checksum `-2142865109331864226`, 34 primary
outputs, zero secondary outputs, 129 constructor lookup requests, and zero
graph-wide constructor projections.

| Metric | Baseline | Candidate | Change |
| --- | ---: | ---: | ---: |
| Allocations | 17,244 | 17,244 | neutral |
| Releases | 12,936 | 12,936 | neutral |
| Retained objects | 4,308 | 4,308 | neutral |
| Allocated bytes | 350,408 | 350,408 | neutral |
| Retired instructions | 6,270,071,242 | 6,263,595,593 | -0.1033% |
| Cycles | 1,742,440,983 | 1,731,901,763 | -0.6049% |
| Maximum RSS | 25,067,520 | 24,854,528 | -0.8497% |
| Peak footprint | 17,760,592 | 17,580,344 | -1.0149% |
| Setup microseconds | 420,578 | 419,332 | -0.2963% |
| Window microseconds | 16,098 | 16,038 | -0.3727% |
| Wall seconds | 16.02 | 15.75 | observation only |

Allocations, releases, retained objects, and allocated bytes are exactly
neutral. Retired instructions, cycles, RSS, peak footprint, setup, and the
measured window improve. Wall time is a one-shot observation rather than a
latency claim.

The retained workload does not execute the newly added receiver-directed UFCS
fallback. Its correctness is covered by the bridge regression and by checking
the production compiler source. The measurement is a whole-typecheck guard
against representation and authority-construction regressions.

## Compiler Size

| Metric | Baseline | Candidate | Change |
| --- | ---: | ---: | ---: |
| Executable bytes | 19,477,968 | 19,513,680 | +0.1833% |

Compiler growth remains below the 1% investigation threshold. Generated
program C is unchanged by this typed-call identity and visibility packet.

## Commands

```bash
make -j1
/usr/bin/time -lp benchmarks/compiler_typecheck_phase_profile \
  bodies 1 32 4 16 16 memory
stat -f %z bin/blorp
```

The baseline and candidate were freshly built in separate worktrees. No
repeated wall-time pairs were taken.
