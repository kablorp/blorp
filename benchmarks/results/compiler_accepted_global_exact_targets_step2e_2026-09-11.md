# Accepted Global Exact Targets Step 2e Results — 2026-09-11

- Baseline commit: `8368b469fef61a470dec10870d7930465a8251d8`
- Baseline compiler: `f120025641e0fced41106089af2b815aa3d32a45617cc2830f0871fe117d8a2b`
- Candidate compiler: `04645992d12542fe73be7b108052608ef2369b8b4b1dfa8ed999e406d7e2cd95`
- Platform: macOS arm64, `/usr/bin/time -lp`
- Sampling: one retained baseline/candidate pair after benchmark build; no
  repeated wall-time sampling

Command:

```bash
env BLORP_COMPILER_BENCHMARK_SKIP_BUILD=1 /usr/bin/time -lp \
	benchmarks/compiler_typecheck_phase_profile accepted 1 32 4 16 16 memory
```

Both runs produced identical semantic and constructor checksums, output counts,
and deterministic work counters. Allocations (`278251`), releases (`189249`),
retained objects (`89002`), and allocated bytes (`6491112`) are exactly neutral.
Instructions change from `8457676214` to `8464941684` (+0.0859%). RSS improves
from `40058880` to `40042496` (-0.0409%), peak footprint from `33571152` to
`33505592` (-0.1953%), and compiler size changes from `19388336` to `19388496`
bytes (+0.0008%).

The measured window changes from 164,020 to 195,393 microseconds (+19.1275%), and
cycles change from `2369252427` to `2708106964` (+14.3022%). These single short
samples are retained for reproducibility, not as latency claims; both are
visibly host-sensitive. The packet removes the imported
module-path/original-name reconstruction with neutral managed-memory counters,
a small peak-footprint improvement, and an instruction guard well inside the 1%
investigation threshold in the directly affected accepted-graph stage.
