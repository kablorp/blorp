# Qualified Accepted Trait-Call Identity — Step 2e

**Date:** 2026-09-11

**Baseline:** reviewed Issue 88 working tree

**Candidate:** working tree for Issue 89

## Result

Qualified graph-backed accepted trait calls now retain the exact
`TraitId + CallableId` selected target. Accepted authority returns one opaque
value with mandatory trait ID and bound identity projections; inference uses an
explicit union to keep graphless Env compatibility separate.

Issue 88 was intentionally uncommitted when this packet began. The focused
semantic assertion returns early against its old string-backed target, so that
run has a different cleanup path and is not reported as a retention comparison.
The unchanged checked-bodies workload below is the like-for-like regression
pair. The deterministic candidate leak counters need no repeated timing runs.

## Direct Qualified-Call Candidate Leak Screen

A temporary probe invoked the inherited in-memory qualified-call fixture once
after resetting `MemStats`, then was removed:

| Metric | Candidate |
| --- | ---: |
| Allocations | 30,981 |
| Releases | 30,981 |
| Retained objects | 0 |
| Retained bytes | 0 |

The equal allocation/release counts and zero retained footprint establish that
the candidate's opaque selection and exact target leave no call-owned objects.
No causal before/after claim is made from the non-equivalent semantic assertion.

## Checked-Bodies Regression Screen

Both screens produced semantic checksum `2057305071532051463`, constructor
checksum `-2142865109331864226`, 34 primary outputs, and zero secondary outputs.

| Metric | Issue 88 | Candidate | Change |
| --- | ---: | ---: | ---: |
| Allocations | 17,244 | 17,244 | neutral |
| Releases | 12,936 | 12,936 | neutral |
| Retained objects | 4,308 | 4,308 | neutral |
| Allocated bytes | 350,408 | 350,408 | neutral |
| Retired instructions | 6,281,338,017 | 6,281,407,552 | +0.0011% |
| Cycles | 1,732,046,543 | 1,824,142,079 | observation only |
| Maximum RSS | 25,149,440 | 24,920,064 | -0.9121% |
| Peak footprint | 17,760,568 | 17,580,344 | -1.0147% |
| Setup microseconds | 405,097 | 447,531 | observation only |
| Window microseconds | 16,360 | 17,064 | observation only |
| Wall seconds | 16.06 | 17.19 | observation only |

An earlier candidate screen measured 1,721,103,204 cycles. The final screen's
1,824,142,079 cycles with nearly identical instructions makes the one-shot cycle
spread explicitly noisy rather than evidence of a regression.

## Compiler Size

| Metric | Issue 88 | Candidate | Change |
| --- | ---: | ---: | ---: |
| Executable bytes | 19,443,168 | 19,443,888 | +0.0037% |

## Commands

```bash
bin/blorp run \
  blorp/test/compiler/stage_06_typecheck/qualified_trait_call_identity_probe.brp

/usr/bin/time -lp benchmarks/compiler_typecheck_phase_profile \
  bodies 1 32 4 16 16 memory
```

The temporary probe was removed. One-shot wall/setup/window values are retained
as observations and are not latency claims.
