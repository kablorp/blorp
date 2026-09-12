# Accepted Global Visibility Inputs Step 2e Results — 2026-09-11

- Baseline compiler: `04645992d12542fe73be7b108052608ef2369b8b4b1dfa8ed999e406d7e2cd95`
- Candidate compiler: `1322f83b0e2fcd092392af22e34e73428e4db1b667409e8b93124b2e82d244cb`
- Platform: macOS arm64, `/usr/bin/time -lp`
- Sampling: one retained baseline/candidate pair after benchmark build; no
  repeated wall-time sampling

Command:

```bash
env BLORP_COMPILER_BENCHMARK_SKIP_BUILD=1 /usr/bin/time -lp \
	benchmarks/compiler_typecheck_phase_profile accepted 1 32 4 16 16 memory
```

Both runs produced identical semantic and constructor checksums, output counts,
and accepted catalog counts. Allocations change from `278251` to `278317`
(+0.0237%), releases from `189249` to `189315` (+0.0349%), retained objects are
neutral at `89002`, and allocated bytes improve from `6491112` to `6490056`
(-0.0163%). Instructions improve from `8477386936` to `8462326045` (-0.1777%).
RSS is neutral at `40042496`, peak footprint changes from `33522000` to
`33538408` (+0.0489%), and compiler size changes from `19388496` to `19388768`
bytes (+0.0014%).

The measured window changes from 230,169 to 170,044 microseconds (-26.1221%), and
cycles change from `2709090242` to `2353452184` (-13.1276%). These single short
samples are retained for reproducibility, not used as performance claims. The
direct mechanism counters support the narrower conclusion: value-only authority
input lowers allocated bytes and retired work while allocation calls, peak
footprint, and code size remain within guard thresholds.
