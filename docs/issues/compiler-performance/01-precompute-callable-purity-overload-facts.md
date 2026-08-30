# Precompute Callable Purity-Overload Facts In Core Flattening

**Status:** Implemented 2026-08-26

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

- `blorp/src/compiler/stage_08_core_lower/flatten.brp`
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

Build immutable facts once for each input program state, then use those facts
throughout the relevant flatten subpass. Builtin-overload materialization needs
raw declaration facts; naming and target selection need facts from the
materialized declaration list.

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
The raw materialization index needs these facts per source name:

```blorp
private record CallableNameFacts {
	has_pure_implementation: Bool,
	has_impure_implementation: Bool,
	has_unresolved_builtin: Bool
}
```

The final materialized-program index additionally stores explicit target
selection for the ordinary and pure emitted names. A target is represented as
`none`, one `def_id`, or `ambiguous`; it is never encoded by concatenating a
name and purity string. Store the facts in a `Dict[String, CallableNameFacts]`.

Use bounded passes instead of nested scans:

1. build raw facts and materialize builtin overloads;
2. build materialized facts;
3. record the selected ordinary/pure target IDs; and
4. construct source-to-target rewrites in original declaration order.

Do not use one string key that ambiguously combines name and purity. Do not
replace the existing source-name-plus-`def_id` rewrite identity boundary in
this issue.

The implementation may be split into two bounded steps:

1. Replace `is_paired_purity_overload` and builtin-presence scans with the
   precomputed facts table.
2. Replace remaining per-call candidate scans with target selections stored in
   the materialized facts table.

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
4. Add `CallableNameFacts`, raw-fact construction, and a materialized callable
   rewrite plan with explicit target-selection state.
5. Thread raw facts through builtin materialization and final facts through
   callable naming/target selection.
6. Replace purity-pair, unresolved-builtin, and target-candidate scans with
   dictionary lookup.
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
./blorp test --timeout 180 blorp/test/compiler/stage_08_core_lower/test_core_flatten.brp
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

## Implementation Results

The implementation keeps the index pass-local and uses the source name only as
the dictionary key. Purity and selected-target identity remain explicit fields
of `CallableNameFacts`; no composite string key encodes those concepts.

Builtin-overload materialization first builds raw name facts so a bodyless user
declaration can be materialized when a same-name unresolved builtin exists. A
second, independent plan is then built from the materialized functions:

1. collect implementation and purity facts by source name;
2. select at most one target for the ordinary and pure emitted names; and
3. construct source callable rewrites in declaration order.

The final plan is immutable. Its three complete function-list visits are
reported by the maintained benchmark result. Duplicate implementations for one
emitted target become `AmbiguousCallableTarget` and fail with a typed
`CoreFlattenError`; a cross-name collision in a generated target name fails
the same way. No inconsistent Core is emitted. The existing
source-name-plus-`def_id` rewrite list is intentionally retained, because
replacing that identity boundary is outside this issue.

### Focused Profile

The following exact profiler rows use the maintained 128-callable fixture,
five iterations, and four selected calls per callable. They are directly
comparable runs from this checkout before and after the change.

| Measurement | Before | After |
| --- | ---: | ---: |
| `prefix_module_names_with_aliases` | 1132.694 ms | 58.191 ms |
| `collect_callable_rewrites` | 1097.465 ms | 10.944 ms |
| `callable_target_name` calls | 85,120 | 1,280 |
| `is_paired_purity_overload` calls | 85,120 | removed |
| `List.any[CoreFunction]` calls | 172,160 | removed from callable planning |
| Workload checksum | 8329755092875520672 | 8329755092875520672 |

The profiled prefix pass improved by about 19x. The focused uninstrumented
five-sample 128-callable windows were 12.961, 13.303, 13.358, 13.813, and
16.604 ms, for a 13.358 ms median. The maintained scaling workload remained
near-linear:

| Callables | Prefix window | Callable-plan visits |
| ---: | ---: | ---: |
| 16 | 0.998 ms | 96 |
| 32 | 2.120 ms | 192 |
| 64 | 5.503 ms | 384 |
| 128 | 14.642 ms | 768 |

Each row preserved the expected alias count, rewritten-call count, and
checksum. The visit count is exactly three passes over the top-level function
list.

### Validation

- `./blorp test --timeout 180 blorp/test/compiler/stage_08_core_lower/test_core_flatten.brp`
  passed 22 tests, including the bounded-plan metric plus same-name and
  generated-name collision regressions.
- `scripts/compiler-check --stage core-lower` passed 7 sources, 4 focused
  suites, and the Core sanitizer gate in 904.35 seconds after the final
  collision-error propagation change.
- `./blorp check --no-format blorp/src/compiler/stage_12_cli/main.brp` completed in
  145.62 seconds with a 963.8 MB peak memory footprint on the implementation
  machine before the final collision hardening; the same self-check also
  passed after that hardening.

The whole-compiler number is an integration measurement, not a stable
before/after speed claim: the historical profile in this issue was collected
from a different compiler revision and machine state. The focused fixture is
the authoritative measurement for this change.
