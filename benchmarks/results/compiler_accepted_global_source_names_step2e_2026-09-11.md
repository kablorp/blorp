# Accepted Global Source Names Step 2e Results — 2026-09-11

- Baseline compiler: `ff66777cc7f04f70b1f2c20ef93529b29680fad3b12623c9cebde7fb05501637`
- Candidate compiler: `7eed0e5f173dbe4392eb50557cc0cc4499548e2802b411a1135abc5b7a8c3d52`
- Platform: macOS, `/usr/bin/time -lp`
- Sampling: one retained baseline/candidate pair after benchmark build; no
  repeated wall-time sampling

Command:

```bash
env BLORP_COMPILER_BENCHMARK_SKIP_BUILD=1 /usr/bin/time -lp \
	benchmarks/compiler_typecheck_phase_profile bound 1 32 4 16 16 memory
```

Both runs produced identical semantic and constructor checksums, output counts,
and work counters. Allocations (`102839`), releases (`101691`), retained objects
(`1148`), and allocated bytes (`94672`) are exactly neutral. Instructions move
from `6638858766` to `6655756895` (+0.2545%), cycles from `1867496451` to
`1868698446` (+0.0644%), RSS from `24379392` to `24444928` (+0.2688%), and peak
footprint from `18202960` to `18252112` (+0.2700%). Compiler size is unchanged at
`19387424` bytes.

The measured window changes from 32,930 to 34,115 microseconds (+3.5985%). This
single short elapsed sample is retained for reproducibility, not as evidence of
a regression. The packet removes one retained string-keyed semantic index with
neutral deterministic memory counters and effectively flat native work.
