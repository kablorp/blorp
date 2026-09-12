# Accepted Callable Exact Visibility Inputs Step 2e Results — 2026-09-11

- Baseline compiler: `8c819a2befbb767e26c0f7ccaad9d7ea08edd3fdc74222a15f7dac0729adb517`
- Candidate compiler: `b468709b8a82bd789afb1287a39be8e43cb2943f5a712ec12d8267741663d692`
- Platform: macOS arm64, `/usr/bin/time -lp`
- Sampling: one retained Issue 81 sample plus one final candidate run; no
  repeated wall-time sampling

Command:

```bash
env BLORP_COMPILER_BENCHMARK_SKIP_BUILD=1 /usr/bin/time -lp \
	benchmarks/compiler_typecheck_phase_profile accepted 1 32 4 16 16 memory
```

Both runs produced semantic checksum `-6362768653699369705`, constructor
checksum `-2142865109331864226`, 1,257 primary outputs, 65 secondary outputs,
136 accepted constructor rows, and 353 accepted field rows.

Allocations improve from `279265` to `265849` (-4.8040%), releases improve from
`190297` to `183921` (-3.3506%), retained objects improve from `88968` to
`81928` (-7.9130%), and allocated bytes improve from `6485968` to `6015952`
(-7.2467%). Instructions improve from `8547658201` to `8271714950` (-3.2283%).
Maximum RSS improves from `40042496` to `37666816` (-5.9329%), peak footprint
improves from `33505616` to `31097168` (-7.1882%), and compiler size moves from
`19406448` to `19423872` (+0.0898%).

One-shot cycles improve from `2343688140` to `2322681745` (-0.8963%). Setup and
measured-window time are retained but are not used as latency claims.

## Prototype Progression

A two-list sparse-row prototype removed strings but duplicated visible and UFCS
rows. It retained 96,042 objects (+7.95%) and allocated 7,016,272 bytes (+8.18%)
versus the Issue 81 baseline, so it was rejected.

A combined sparse-row prototype stored visible and UFCS indices in one record
per name. It retained 96,009 objects (+7.91%) and allocated 7,236,416 bytes
(+11.57%), so it was also rejected.

The retained candidate stores no derived per-name candidate relation. It keeps
the exact owner module, active selective bindings, and ordered direct modules,
then reuses the canonical table's searchable name ranges. The benchmark uses a
direct-import fanout of 16, so the measured improvements include the on-demand
UFCS module probes rather than hiding them behind a zero-import fixture.
