# Accepted Global Exact Module Slots Step 2e Results — 2026-09-11

- Baseline compiler: `1322f83b0e2fcd092392af22e34e73428e4db1b667409e8b93124b2e82d244cb`
- Candidate compiler: `5b94cf7fe4fcdd25620a8fd06ae69102db633d90843d053f7155d8ec4f88cbc7`
- Platform: macOS arm64, `/usr/bin/time -lp`
- Sampling: retained Issue 77 baseline plus one candidate run; no repeated
  wall-time sampling

Command:

```bash
env BLORP_COMPILER_BENCHMARK_SKIP_BUILD=1 /usr/bin/time -lp \
	benchmarks/compiler_typecheck_phase_profile accepted 1 32 4 16 16 memory
```

Both runs produced identical semantic and constructor checksums, output counts,
and accepted catalog counts. Allocations move from `278317` to `278349`
(+0.0115%), releases move from `189315` to `189347` (+0.0169%), retained objects
remain `89002`, and allocated bytes remain `6490056`. Maximum RSS moves from
`40042496` to `40075264` (+0.0818%), peak footprint improves from `33538408` to
`33489232` (-0.1466%), and compiler size moves from `19388768` to `19405296`
bytes (+0.0852%).

Instructions improve from `8462326045` to `8459585105` (-0.0324%). The measured
window moves from 170,044 to 151,832 microseconds (-10.7090%) while cycles move
from `2353452184` to `2341500832` (-0.5078%). The short wall and cycle samples
are retained for reproducibility, not used as claims. Retained objects and
allocated bytes are neutral, peak footprint improves, and every guard movement
remains within 0.15%.
