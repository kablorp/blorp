# Accepted Trait-Definition Visibility Rows — Step 2e

**Baseline:** clean `cb716ccf` (Issue 92)

**Candidate:** Issue 93 working tree, same bootstrap pin

One parent/candidate pair used the accepted-authority fixture. Both produced
semantic checksum `-6362768653699369705`, constructor checksum
`-2142865109331864226`, 1,257 primary outputs, 65 secondary outputs, 136
constructor rows, 353 field rows, 129 constructor requests, and zero graph-wide
constructor projections. The fixture constructs accepted authority across 33
module slots but does not isolate the trait-visibility subroutine; this is a
whole-stage regression screen. The declaration regression directly covers
selective trait aliases and local/qualified-only source visibility.

| Metric | Parent | Candidate | Change |
| --- | ---: | ---: | ---: |
| Allocations | 265,009 | 265,539 | +0.2000% |
| Releases | 183,048 | 183,544 | +0.2710% |
| Retained objects | 81,961 | 81,995 | +0.0415% |
| Allocated bytes | 6,017,008 | 6,017,136 | +0.0021% |
| Retired instructions | 8,274,246,858 | 8,277,601,239 | +0.0405% |
| Cycles | 2,281,456,598 | 2,266,557,245 | -0.6531% |
| Maximum RSS | 37,666,816 | 37,601,280 | -0.1740% |
| Peak footprint | 31,048,016 | 30,982,480 | -0.2111% |
| Setup microseconds | 419,336 | 418,823 | -0.1223% |
| Window microseconds | 140,274 | 139,646 | -0.4477% |
| Executable bytes | 19,514,016 | 19,530,640 | +0.0852% |
| Wall seconds | 16.42 | 16.18 | observation only |

No metric breaches the 2% investigation threshold. Managed retention grows by
34 objects and 128 bytes; this is not described as a memory improvement. A
later trait-heavy fixture would better distinguish the compact row's retained
cost from the deleted string dictionary. The one-shot timing and cycle values
are observations, not a latency improvement claim.

```bash
make -j1
set -o pipefail
/usr/bin/time -lp benchmarks/compiler_typecheck_phase_profile \
  accepted 1 32 4 16 16 memory 2>&1 |
  rg '^TYPECHECK_PHASE_PROFILE |^real |^user |^sys |maximum resident set size|instructions retired|cycles elapsed|peak memory footprint'
stat -f %z bin/blorp
```

The `rg` filter continuously drains verbose exact-profile output, avoiding
the blocked output pipe encountered in the Issue 92 measurement. No repeated
timing pairs were taken.
