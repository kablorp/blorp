# Accepted Trait Policy Identity — Step 2e

**Date:** 2026-09-11

**Baseline:** clean `main` at `f891949b`

**Candidate:** Issue 90 working tree

## Result

Accepted elementwise, self-bound, and resource-argument policy consumers now
query exact `TraitId` values. The former accepted-call ID-to-name helper is
deleted. Each query also verifies that the issuing `DefinitionTable` shares
allocation provenance with the accepted authority before interpreting the
compact ID. Exact table and topology paths avoid source-name round trips;
string projection remains explicit for compiler-Env compatibility fallback,
graphless or unresolved dispatch, and the failed self-bound diagnostic.

## Checked-Bodies Regression Screen

One baseline/candidate pair was taken. Both runs produced semantic checksum
`2057305071532051463`, constructor checksum `-2142865109331864226`, 34 primary
outputs, zero secondary outputs, 129 constructor lookup requests, and zero
graph-wide constructor projections.

| Metric | Main baseline | Candidate | Change |
| --- | ---: | ---: | ---: |
| Allocations | 17,244 | 17,244 | neutral |
| Releases | 12,936 | 12,936 | neutral |
| Retained objects | 4,308 | 4,308 | neutral |
| Allocated bytes | 350,408 | 350,408 | neutral |
| Retired instructions | 6,271,463,729 | 6,273,064,011 | +0.0255% |
| Cycles | 1,739,863,660 | 1,738,509,208 | -0.0778% |
| Maximum RSS | 25,067,520 | 25,018,368 | -0.1961% |
| Peak footprint | 17,744,184 | 17,695,032 | -0.2770% |
| Setup microseconds | 420,399 | 419,915 | -0.1151% |
| Window microseconds | 16,235 | 16,101 | -0.8254% |
| Wall seconds | 15.69 | 15.68 | observation only |

Allocations and retained memory are the primary representation guards. Retired
instructions, RSS, peak footprint, and compiler size remain well below the 1%
investigation threshold. One-shot time and cycles are observations only.

## Compiler Size

| Metric | Main baseline | Candidate | Change |
| --- | ---: | ---: | ---: |
| Executable bytes | 19,477,648 | 19,477,968 | +0.0016% |

## Commands

```bash
make -j1
/usr/bin/time -lp benchmarks/compiler_typecheck_phase_profile \
  bodies 1 32 4 16 16 memory
stat -f %z bin/blorp
```

The baseline and candidate were freshly built in their respective worktrees.
No repeated wall-time pairs were taken.
