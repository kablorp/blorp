# Precompute Callable Purity-Overload Facts In Core Flattening

**Status:** Ready for implementation

## Issue Summary

Remove the verified superlinear scan in Core lowering where callable target
resolution repeatedly scans every top-level function to rediscover whether a
source name has both pure and impure implementations.

This is the highest-confidence optimization in the self-compilation profile.
It has a focused scaling harness and a direct algorithmic explanation. The
implementation should precompute callable naming facts once, then perform
constant-time or near-constant-time target lookup during rewriting.

## Profile Evidence

The 2026-08-25 profile compiled the 290-module compiler in 180.545 seconds with
704.1 million allocations and 2.218 GB peak RSS. External sampling attributed
14,869 samples, 9.891% of all samples and about 18.02 seconds, to
`flatten.is_paired_purity_overload` and the library/runtime work beneath it.

Related inclusive paths were about 10.5% each for `callable_target_name` and
`callable_target_def_id`. This is overlapping evidence, not additive cost.

The focused harness holds calls per callable at four:

| Callables | Prefix pass per iteration |
| ---: | ---: |
| 16 | 1.758 ms |
| 32 | 6.856 ms |
| 64 | 30.571 ms |
| 128 | 180.333 ms |

An 8x input increase produced roughly 103x runtime. At 128 callables over five
iterations the exact profiler recorded:

- 1,280 `callable_target_def_id` calls;
- 85,120 `callable_target_name` calls;
- 85,120 `is_paired_purity_overload` calls; and
- 172,160 `List.any[CoreFunction]` calls.

This is direct evidence of repeated full-list scans inside another candidate
scan, not a speculative hotspot.

## Current Code And Cause

Primary implementation:

- `compiler/src/stage_08_core_lower/flatten.brp`
- `is_paired_purity_overload`
- `callable_target_name`
- `callable_target_def_id`
- `has_callable_implementation_named`
- `has_unresolved_builtin_named`

`is_paired_purity_overload(functions, name)` performs one `functions.any` scan
for a pure implementation and another for an impure implementation. Call target
selection invokes that helper repeatedly while already iterating candidate
functions. The same immutable facts are rediscovered for the same name many
times.

The current behavior is subtle. A source `builtin("std/...")` declaration can
be bodyless but still count as an implementation. Bodyless user declarations
can be paired with unresolved builtin declarations. Pure and impure overloads
must retain distinct callable IDs and exact selected signatures.

## Goals

Build the facts required for callable naming and target selection once per
program or module, then use those facts throughout the flatten pass.

The completed pass must have no `functions.any` scan nested under per-call or
per-candidate target lookup.

## Non-Goals

- Do not change source overload or purity semantics.
- Do not infer callable identity from spelling when an existing `def_id` or
  nominal callable identity is available.
- Do not combine this issue with the broader identity migration.
- Do not rename generated Core functions.
- Do not change builtin materialization policy.
- Do not add a process-global cache.

## Proposed Design

Introduce a private pass-local index constructed from `top_level_functions`.
The minimum useful value per source name contains:

```blorp
private struct CallableNameFacts {
	has_pure_implementation: Bool,
	has_impure_implementation: Bool,
	has_unresolved_builtin: Bool
}
```

Store it in a `Dict[String, CallableNameFacts]`. Update one entry while walking
the function list once. If target resolution still scans candidates by name,
also build one of these indexes in the same walk:

```blorp
Dict[Int, CoreFunction]                  -- preferred when def_id is authoritative
Dict[String, List[CoreFunction]]         -- needed only for name-overload operations
```

Do not use one string key that ambiguously combines name and purity. Use a
small explicit key/value representation or separate fields.

The implementation may be split into two bounded steps:

1. Replace `is_paired_purity_overload` and builtin-presence scans with the
   precomputed facts table.
2. Replace remaining per-call candidate scans with the direct callable target
   table where existing identity permits it.

Step 1 must show the exact `List.any` calls disappearing. Step 2 should only be
undertaken in this issue if it does not require changing public Core identity
types.

## Mechanical Implementation Sequence

1. Read the complete callable planning section in `flatten.brp`, including
   builtin materialization and module alias prefixing.
2. Run the current focused tests and benchmark; save output outside the repo.
3. Add a test-only counter or benchmark assertion showing that building a
   callable plan visits each function a bounded number of times. Prefer a
   public benchmark result field over production debug logging.
4. Add `CallableNameFacts` and a single-pass index constructor.
5. Thread the index through the private flatten helpers that currently receive
   the whole function list solely for repeated queries.
6. Replace purity-pair and unresolved-builtin scans with dictionary lookup.
7. Re-run the focused benchmark at 16, 32, 64, and 128 callables.
8. Inspect all remaining `functions.any` and full-function loops in the
   callable target path. Document any scan that remains and why.
9. Run the focused compiler suite, owning stage checks, and whole-compiler
   comparison.

## Invariants And Pitfalls

- `UnresolvedBuiltinFunction` with no body still counts as an implementation.
- A forward declaration with no implementation must not be treated as one.
- Pure and impure overloads with the same source name must remain distinct.
- Duplicate names across modules must not share a table unless the key includes
  the module identity already represented at this phase.
- Selection by `def_id` must fail closed on collisions; do not silently choose
  the first candidate.
- Preserve deterministic output regardless of dictionary iteration order. Use
  indexes for lookup, not declaration emission ordering.
- A precomputed index must be pass-local and immutable after construction so
  stale entries cannot survive program rewriting.

## Fast Feedback Loop

Use the existing harness:

```bash
benchmarks/compiler_core_flatten_profile prefix 5 16 4
benchmarks/compiler_core_flatten_profile prefix 5 32 4
benchmarks/compiler_core_flatten_profile prefix 5 64 4
benchmarks/compiler_core_flatten_profile prefix 5 128 4
```

The arguments are mode, iterations, callables, and calls per callable. The
profiling workspace contained this harness and fixture:

- `benchmarks/compiler_core_flatten_profile`
- `compiler/benchmarks/compiler_core_flatten_profile.brp`
- `compiler/benchmarks/compiler_core_flatten_profile_fixture.brp`

At profile time these harness files were uncommitted while production compiler
source matched `main`. Verify they exist in the implementation checkout. If
they are absent, recreate this narrow harness from the workload controls and
expected output fields described above before editing `flatten.brp`.

Every result must report the same valid workload and checksum before and after.
Compare medians from at least five runs. Record exact function counts when the
selective profiler is available.

## Functional Tests

Start with:

```bash
./blorp test --timeout 180 compiler/tests/test_compiler_core_flatten.brp
scripts/compiler-check --stage core-lower
```

Add or retain cases for:

- one ordinary source function;
- pure-only and impure-only functions;
- a paired pure/impure source name;
- bodyless forward declarations;
- source builtin plus bodyless overload materialization;
- duplicate names in distinct modules;
- repeated call sites selecting distinct callable IDs; and
- malformed/colliding IDs failing deterministically.

## Acceptance Criteria

- The 128-callable workload no longer calls
  `is_paired_purity_overload` once per candidate; ideally the helper is removed.
- Construction performs a bounded number of full function-list passes.
- The focused scaling curve is approximately linear or near-linear over
  16/32/64/128 callables. Explain any remaining superlinear component.
- The 128-callable median materially improves without regressing 16 callables.
- Workload checksum and all focused semantic tests are unchanged.
- Generated Core names and selected `def_id` values are byte-for-byte stable.
- The issue report includes before/after calls, time, allocations if available,
  and whole-compiler phase measurements.
