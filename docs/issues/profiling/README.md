# Profiling Workstream

**Status:** Count/selective modes, dense function IDs, and fiber-correct exact
timing are implemented. The [Developer Guide](../../DEVELOPMENT.md#function-profiling-and-flame-graphs)
owns their current use. This page lists only the remaining capabilities.

| Question | Intended first measurement |
| --- | --- |
| Which code consumes CPU? | Optimized native statistical sampling, with a logical symbol map. |
| How often is a function called? | Count-only probes over selected exact function identities. |
| How does active time divide between callers and callees? | Narrow exact inclusive/self timing. |
| Where are fibers blocked, allocating, or cancelled? | A later bounded event recorder when aggregate profiles cannot answer. |

## Remaining Sequence

1. [Local aggregation and structured output](04-local-aggregation-and-output.md):
   remove hot shared atomic updates and publish one versioned snapshot.
2. [Native sampling and symbol maps](05-native-sampling-and-symbol-maps.md):
   make low-observer-effect optimized sampling the normal CPU-ranking path.
   This can advance independently of local exact-counter aggregation.
3. [Unified profile command](06-unified-profile-command.md): distinguish
   profiling the compiler from profiling a produced program and retain a
   reproducible result bundle. Remove the temporary `--profile` alias at
   this cutover; do not keep an indefinite compatibility spelling.

A bounded event recorder remains a *later direction*, not an executable
handoff. Reconsider it only after the ordinary workflow and data model land
and a concrete blocking, allocation, or cancellation question cannot be
answered by samples and aggregate counters. Do not build it to solve a
count-only or sampling problem.

## Shared Contract

- Profiling is observational: aside from elapsed time and scheduling effects,
  it cannot change output, diagnostics, exit status, ownership, or cleanup.
- Runtime/C symbol strings and display names are metadata. Compiler-issued
  exact identity is the key; ID assignment and output order are deterministic.
- Every dropped sample, event, frame, or output record is counted and reported.
  No limit can silently produce a plausible but incomplete profile.
- Reports label their clock. Scheduled-active, process/thread CPU, and wall
  time are different measures. Inclusive values overlap; self values or
  partitioning samples are needed for percentages. Blocking wall latency is
  not CPU self time.
- Profile-window transitions define calls crossing the boundary. Fiber
  suspension, cancellation, and nonlocal unwinding must not leak stale frames.
  Signal handlers request reporting or termination; they do not symbolize,
  allocate, lock, or serialize.
- Normal builds carry no profiling runtime overhead or metadata unless an
  explicit profile/symbol-map option requests it.

For each remaining issue, use a small direct harness while changing the
mechanism, then one representative compiler-sized artifact. Compare semantic
output, completeness counters, compiler overhead, allocation, retired
instructions, and paired latency. Save raw samples and exact binary/source
provenance under `benchmarks/results/`; do not paste logs into these handoffs.
