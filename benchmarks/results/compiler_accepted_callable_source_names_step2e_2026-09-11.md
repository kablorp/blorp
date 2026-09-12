# Accepted Callable Source Names Step 2e Results — 2026-09-11

- Baseline compiler: `aed081ddad97985df9dacb833f925f9584476a3e81481f4cefc62848fecb8bfb`
- Candidate compiler: `65385032de5511a8492273ce9b0ab66d1eb78f396d4a9924ac1377ab27abcde7`
- Platform: macOS arm64, `/usr/bin/time -lp`
- Sampling: one retained Issue 79 sample plus one candidate run; no repeated
  wall-time sampling

Command:

```bash
env BLORP_COMPILER_BENCHMARK_SKIP_BUILD=1 /usr/bin/time -lp \
	benchmarks/compiler_typecheck_phase_profile accepted 1 32 4 16 16 memory
```

Allocations remain `278382`, releases remain `189380`, retained objects remain
`89002`, and allocated bytes remain `6490056`. Retired instructions move from
`8460316056` to `8467018989` (+0.0792%). Maximum RSS improves from `40206336`
to `40108032` (-0.2445%), peak footprint improves from `33620280` to
`33554744` (-0.1950%), and compiler size moves from `19406144` to `19406176`
(+0.0002%).

One-shot cycles move from `2322167528` to `2344974502` (+0.9821%). No
deterministic work or memory signal corroborates that movement, so it is
retained as noise rather than used as a latency claim.

The candidate makes the accepted visibility row ID-based while retaining the
old string-keyed authority as a compatibility consumer. The accepted-stage
fixture is a whole-stage guard; focused declaration tests cover selective
aliases and exact overload targets directly.

## Rejected Broader Representations

Two prototypes attempted to layer list relations over the existing callable
table. A parallel-flat-array form measured 286,032 allocations and 197,059
releases; a grouped-slot form measured 293,183 allocations and 204,214
releases. Those are respectively +2.75%/+4.05% and +5.32%/+7.83% against the
Issue 79 baseline. Both were fully reverted.

The results show that a compact list relation must be constructed at the
accepted-callable producing boundary and replace the old dictionary. Building
the old table and then converting or duplicating it is not an acceptable
migration strategy.
