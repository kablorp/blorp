# Selective Definition Target Step 2c Results — 2026-09-11

## Revisions And Host

- Baseline: `e5fb245d` (`Normalize qualified module alias targets`)
- Candidate: uncommitted Step 2c worktree
- Baseline compiler SHA-256:
  `1189fc882280ee1cade3fc7a71427c12fa9787a29c16d25b7278160cb9ff200b`
- Candidate compiler SHA-256:
  `12b90ac5a29efeb9b22d0a3c2f3f411f2b23a9a536d32702c5d96a0aea5c1184`
- Platform: macOS, `/usr/bin/time -lp`
- Sampling: one retained baseline/candidate pair per workload; no wall-time
  claim

## Workloads

The importable-phase profile isolates `ImportableModuleGraph` construction for
32 dependency modules plus the target. Its deterministic managed-memory window
is the primary resource signal for the sparse exported-target index.

Two retained source fixtures exercise the production compiler over the same
32-function dependency:

- `main.brp` imports all 32 functions selectively;
- `qualified_main.brp` imports the module without selective symbols.

This distinguishes the paid selective-index path from the shared-empty
qualified path. The production checks include compiler startup and the broader
front end, so their native counters are regression guards rather than precise
attribution to the new index.

## Commands

```bash
BLORP_BENCHMARK_CACHE_DIR=/tmp/blorp_step2c_cache_baseline \
	/tmp/blorp_step2c_baseline/tree/benchmarks/compiler_typecheck_phase_profile \
	importable 1 32 4 16 16 memory

BLORP_BENCHMARK_CACHE_DIR=/tmp/blorp_step2c_cache_candidate \
	benchmarks/compiler_typecheck_phase_profile importable 1 32 4 16 16 memory

/usr/bin/time -lp <baseline-or-candidate-blorp> check --no-format \
	blorp/benchmark/compiler/selective_import_graph_fixture/main.brp

/usr/bin/time -lp <baseline-or-candidate-blorp> check --no-format \
	blorp/benchmark/compiler/selective_import_graph_fixture/qualified_main.brp

stat -f '%z %N' <baseline-blorp> bin/blorp
shasum -a 256 <baseline-blorp> bin/blorp
```

The benchmark caches are outside the measured window. One-shot elapsed time is
recorded only for the isolated window and is not acceptance evidence.

## Final Raw Counters

| Workload | Metric | Baseline | Candidate | Change |
| --- | --- | ---: | ---: | ---: |
| importable | semantic checksum | 3225153837847304234 | 3225153837847304234 | exact |
| importable | constructor checksum | 4522423758094903886 | 4522423758094903886 | exact |
| importable | allocations | 7,571 | 7,574 | +0.0396% |
| importable | releases | 2,666 | 2,669 | +0.1125% |
| importable | retained objects | 4,905 | 4,905 | 0 |
| importable | allocated bytes | 350,008 | 351,064 | +0.3017% |
| importable | window microseconds | 1,773 | 1,844 | +4.0045% |
| selective | instructions retired | 2,982,777,919 | 2,991,086,966 | +0.2786% |
| selective | cycles | 750,098,727 | 755,759,311 | +0.7546% |
| selective | maximum RSS | 31,195,136 | 31,326,208 | +0.4202% |
| selective | peak footprint | 25,182,592 | 25,166,160 | -0.0653% |
| qualified | instructions retired | 2,980,259,190 | 2,986,354,435 | +0.2045% |
| qualified | cycles | 744,464,465 | 765,998,030 | +2.8925% |
| qualified | maximum RSS | 31,145,984 | 31,358,976 | +0.6839% |
| qualified | peak footprint | 25,100,624 | 25,215,336 | +0.4570% |
| compiler | executable bytes | 19,264,128 | 19,300,176 | +0.1871% |

## Design Feedback From The Measurement Loop

The first correct implementation eagerly indexed every public export in every
accepted module. Against the same isolated phase it produced 14,049
allocations (+85.6%), 6,998 retained objects (+42.7%), and 487,128 allocated
bytes (+39.2%). That representation was rejected before broad validation.

Filtering the index to graph-wide requested selective spellings removed most
of that work. The next measurement still showed exactly 33 extra retained
objects: one empty map for each module slot in a qualified-only graph. Returning
the shared `EXPORTED_DEFINITION_TARGETS_EMPTY` value for an empty request set
removed those objects. The final retained-object count is identical to Step 2b
and the remaining deterministic deltas are at or below 0.31%.

## Interpretation

The semantic and constructor checksums are exact. Retired instructions, RSS,
and peak footprint vary between -0.07% and +0.69%, below the 1% investigation
guard. The full compiler grew 36,048 bytes (+0.19%). No stable resource guard
regressed materially.

Qualified cycles moved from -1.40% to +2.89% in same-binary screens while its
retired-instruction count remained below +0.21%. The sign change makes this
one-shot cycle counter unsuitable for acceptance; it is reported rather than
discarded or interpreted as either a regression or improvement.

The 71-microsecond isolated elapsed increase is a single short sample and is
not a clean latency measurement. It is retained for transparency, not used to
claim a speedup or regression. The useful result is architectural plus
mechanistic: ordinary graph bindings no longer retain path/name join keys, the
new target index is sparse, and its deterministic retained-memory cost is
neutral.
