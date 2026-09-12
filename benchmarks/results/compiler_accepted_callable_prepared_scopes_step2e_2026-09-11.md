# Accepted Callable Prepared Scopes Step 2e Results — 2026-09-11

- Baseline compiler: `b468709b8a82bd789afb1287a39be8e43cb2943f5a712ec12d8267741663d692`
- Candidate compiler: `56b8320e420c5674e74b2686fedaec12f5a711dc8d58b6cf0dcdbe4d9777d618`
- Platform: macOS arm64, `/usr/bin/time -lp`
- Sampling: one retained Issue 82 sample plus one final candidate run; no
  repeated wall-time sampling

Command:

```bash
env BLORP_COMPILER_BENCHMARK_SKIP_BUILD=1 /usr/bin/time -lp \
	benchmarks/compiler_typecheck_phase_profile accepted 1 32 4 16 16 memory
```

Both runs produced semantic checksum `-6362768653699369705`, constructor
checksum `-2142865109331864226`, 1,257 primary outputs, 65 secondary outputs,
136 accepted constructor rows, and 353 accepted field rows.

Allocations remain `265849`, releases remain `183921`, retained objects remain
`81928`, and allocated bytes remain `6015952`. Instructions improve from
`8271714950` to `8265037225` (-0.0807%). Maximum RSS improves from `37666816` to
`37617664` (-0.1305%), peak footprint improves from `31097168` to `31031632`
(-0.2107%), and compiler size moves from `19423872` to `19423920` (+0.0002%).

One-shot cycles improve from `2322681745` to `2293604863` (-1.2519%). Setup and
measured-window time are retained but are not used as latency claims.

The result confirms that replacing scope-to-path-to-ID round trips with
validated prepared-scope inputs does not introduce new retained state or
allocation work. The small native and footprint improvements are consistent
with removing path projection and reverse lookup, but only the deterministic
memory neutrality is treated as a mechanism-level claim.
