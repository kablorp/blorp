# Accepted Callable Compact Ranges Step 2e Results — 2026-09-11

- Baseline compiler: `65385032de5511a8492273ce9b0ab66d1eb78f396d4a9924ac1377ab27abcde7`
- Candidate compiler: `8c819a2befbb767e26c0f7ccaad9d7ea08edd3fdc74222a15f7dac0729adb517`
- Platform: macOS arm64, `/usr/bin/time -lp`
- Sampling: one retained Issue 80 sample plus one final candidate run; no
  repeated wall-time sampling

Command:

```bash
env BLORP_COMPILER_BENCHMARK_SKIP_BUILD=1 /usr/bin/time -lp \
	benchmarks/compiler_typecheck_phase_profile accepted 1 32 4 16 16 memory
```

Both runs produced semantic checksum `-6362768653699369705`, constructor
checksum `-2142865109331864226`, 1,257 primary outputs, 65 secondary outputs,
136 accepted constructor rows, and 353 accepted field rows.

Allocations move from `278382` to `279265` (+0.3172%) and releases from `189380`
to `190297` (+0.4842%). Retained objects improve from `89002` to `88968`
(-0.0382%), and allocated bytes improve from `6490056` to `6485968` (-0.0630%).
Instructions move from `8467018989` to `8547658201` (+0.9524%). Maximum RSS
improves from `40108032` to `40042496` (-0.1634%), peak footprint improves from
`33554744` to `33505616` (-0.1464%), and compiler size moves from `19406176` to
`19406448` (+0.0014%).

One-shot cycles improve from `2344974502` to `2343688140` (-0.0549%). Setup and
measured-window time are retained but are not used as latency claims.

## Prototype Progression

The first direct range prototype removed 6,867 allocations but rebuilt
compatibility dictionary values one callable at a time. That reduced retired
instructions but increased allocated bytes by 3.16% and peak footprint by
1.12%, so it was rejected.

The next prototype retained only module ranges and scanned every callable in a
module for each qualified query. Its counters were favorable, but independent
review rejected its `O(n * q)` scaling. A per-name range list restored
logarithmic lookup, but raised allocations 0.32%, releases 0.49%, and allocated
bytes 0.32%, so it was also rejected.

The retained form stable-groups equal numeric `SourceNameId` values at the
producer. Authority construction builds one complete overload list and performs
one dictionary update per source name. Qualified lookup lower-bound searches
the canonical slots directly and scans only matching overloads. This preserves
`O(log n + k)` lookup without a parallel name-range allocation.

Earlier Issue 80 prototypes constructed list relations after the old string
index and were also rejected. The retained candidate builds the compact
relation directly and entirely removes the old table.
