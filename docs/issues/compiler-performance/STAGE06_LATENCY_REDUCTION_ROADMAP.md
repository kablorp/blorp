# Stage 06 Latency Reduction Roadmap

**Status:** Two measurement-gated issues remain

**Scope:** Compiler latency through Stage 06, including CTFE requested while
producing typechecked artifacts. Backend and C compiler latency are excluded.

## Current Position

The original profile found that Stage 06 and its CTFE dependency dominated the
frontend self-check. Completed changes established exact constructor identity,
made dependency-global CTFE evaluation graph-owned, and replaced linear
type-home scans with one indexed authority. Graph-owned CTFE evaluation reduced
dependency evaluations by 84.95%, binding applications by 83.73%, whole-check
retired instructions by 13.29%, and median wall time by 7.06% on its recorded
baseline.

Those measurements explain the current architecture; they are not promises for
current `main`. Raw historical results belong in `benchmarks/results/` and Git
history. Refresh the baseline before admitting another implementation.

## Remaining Sequence

1. [Canonicalize accepted semantic-type projection](66-canonicalize-accepted-semantic-type-projection.md).
   Proceed only if a refreshed accepted-graph profile still shows material
   duplicate projection work and the cache key can use exact semantic identity.
2. [Index remaining CTFE environment lookup](67-index-remaining-ctfe-environment-lookup.md).
   Recount after the earlier changes. Reject the representation change unless
   residual binding scans meet that issue's admission threshold.

The issues are serial for honest performance attribution, not because their
representations must be coupled.

## Invariants

Every accepted change must preserve:

- exact module, definition, type, constructor, and callable identity;
- accepted and recoverable graph behavior;
- source-order diagnostics and spans;
- visibility and shadowing precedence;
- CTFE evaluation and rejection behavior;
- byte-identical successful compiler output unless a regression test names an
  intentional correction; and
- graph/session lifetime boundaries without retaining mutable inference state.

Do not infer identity from names, paths, generated C symbols, or source shape.
Do not retain the replaced list or scan as a second authority.

## Measurement And Fast Feedback

Start with deterministic work counters for the repeated operation being
removed: requests, unique keys, candidates visited, hits/misses, allocations,
and a semantic checksum. Prefer these, retired instructions, and peak RSS over
small wall-clock movements.

Use the narrow benchmark named by the issue, then type-check the directly
affected owner. The maintained broader probes are:

```bash
bin/blorp run --release \
  blorp/benchmark/compiler/compiler_typecheck_phase_profile.brp -- \
  headers 20 8 32 64 4 memory

bin/blorp run --release \
  blorp/benchmark/compiler/compiler_typecheck_phase_profile.brp -- \
  accepted 10 8 32 64 4 memory

bin/blorp run --release \
  blorp/benchmark/compiler/compiler_ctfe_typecheck_profile.brp -- \
  5 24 32 retained
```

Finish with the production-shaped check:

```bash
<compiler> check --no-format blorp/src/main.brp
```

Compare baseline and candidate compilers built with the same bootstrap and
optimization level. Use alternating runs and report medians, but require a
deterministic work reduction rather than accepting timing noise.

## Merge Gate

Each issue must be independently revertible and must:

- begin with a failing behavior or deterministic-work assertion;
- leave one authority for the migrated fact;
- delete temporary switches, counters, and fallback implementations;
- pass focused tests and `scripts/compiler-check --changed`;
- pass `scripts/compiler-check --stage typecheck` for Stage 06 changes;
- pass relevant CTFE and leak gates for Stage 07 changes; and
- record before/after evidence in `benchmarks/results/` or the commit.

If an issue misses its admission or acceptance threshold, remove the candidate
implementation and retain only useful tests or profiling support.

## Completion

This roadmap is complete when each remaining issue is either implemented with
measured benefit or explicitly rejected after a current production profile.
Reprofile after every accepted change; do not assume the original hotspot order
remains valid.
