# Batch Closure Function Indexing

**Status:** Implemented 2026-08-26

## Issue Summary

Build closure-conversion function indexes with local collection accumulators
and construct `FunctionIndexes` once, instead of returning a new three-dictionary
record for every function and implementation method.

The indexes are still required. This issue changes how they are constructed,
not closure resolution semantics.

## Profile Evidence

The compiler self-compilation baseline took 180.545 seconds with 704.1 million
allocations and 2.218 GB peak RSS. External compiler-parent attribution found:

| Function | Samples | Share |
| --- | ---: | ---: |
| `closure.index_functions` | 2,692 | 1.791% |
| `closure.index_function` | 2,643 | 1.758% |
| Combined | 5,335 | 3.549% |

The combined attribution is about 6.46 seconds of the 182.203-second sampled
run. The two rows are exclusive compiler-parent buckets and can be combined;
do not add their inclusive subtrees again.

## Implementation Results

The implemented candidate builds `by_id`, `collisions_by_id`, and `by_name`
with local accumulators and constructs `FunctionIndexes` once at the end of
`index_functions`. `FunctionIndexes` is private; tests and benchmarks observe
the compact `ClosureFunctionIndexDiagnosticSnapshot` built through the exact
production indexing path.

Benchmark harness caveat: the median table below uses
`measurement_mode=construction_counts`. Fixture construction, query-list
construction, and full ordering checksum validation ran outside the reset and
timing window. The measured loop calls the production diagnostic snapshot with
empty lookup queries, so it includes index construction plus compact count
materialization, and excludes per-entry diagnostic lookup/checksum lists. The
same harness and snapshot path were used for the temporary legacy fold and the
accumulator candidate.

One discarded exploratory run passed each workload as one shell argument under
`zsh`, causing the runner to fall back to default controls. The accepted data
below excludes that run and uses three valid alternating runs per
implementation, with medians reported.

| Workload | Legacy us | Accumulator us | Speedup | Time reduction | Legacy allocations | Accumulator allocations | Allocation reduction |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 256 unique | 10,907 | 1,373 | 7.94x | 87.41% | 10,360 | 2,680 | 74.13% |
| 1,024 unique | 160,710 | 4,640 | 34.64x | 97.11% | 41,080 | 10,360 | 74.78% |
| 4,096 unique | 2,694,191 | 19,693 | 136.81x | 99.27% | 163,960 | 41,080 | 74.95% |
| 1,024 duplicate name/16 | 160,409 | 5,050 | 31.76x | 96.85% | 41,710 | 10,990 | 73.65% |
| 1,024 duplicate ID/64 | 163,778 | 4,982 | 32.87x | 96.96% | 41,530 | 10,810 | 73.97% |
| 1,152 mixed implementation methods and duplicates | 201,963 | 5,599 | 36.07x | 97.23% | 47,420 | 12,860 | 72.88% |

All measured rows reported matching deterministic checksums, expected map
counts, expected collision counts, `workload_valid=True`, `retained_objects=0`,
and `allocated_bytes=0`.

Final focused validation after formatting:

- `scripts/compiler-check --validate`: valid manifest with 293 production
  modules, 208 suites, and 7 checks.
- `./blorp format --check blorp/src/compiler/stage_09_core/closure.brp
  blorp/benchmark/compiler/compiler_closure_function_index_profile.brp
  blorp/benchmark/compiler/compiler_closure_function_index_profile_fixture.brp
  blorp/test/compiler/stage_09_core/test_closure_function_index_benchmark.brp
  blorp/test/compiler/stage_09_core/test_core_closure_function_index.brp`: all five
  files ok.
- `git diff --check`: passed.
- `./blorp test --timeout 180
  blorp/test/compiler/stage_09_core/test_core_closure_function_index.brp
  blorp/test/compiler/stage_09_core/test_closure_function_index_benchmark.brp`: closure
  index diagnostics 3/3 passed; benchmark assertions 2/2 passed.

Broad Core and sanitizer gates were intentionally not run in this worker after
the accepted benchmark result; integrated Core checks run after merge.

## Original Representation

Primary file: `blorp/src/compiler/stage_09_core/closure.brp`.

```blorp
record FunctionIndexes {
	by_id: Dict[Int, CoreFunction],
	collisions_by_id: Dict[Int, List[CoreFunction]],
	by_name: Dict[String, List[CoreFunction]]
}
```

`index_functions` walks top-level `FunctionDecl` values and every `ImplDecl`
method. For each function, `index_function`:

- reads and conditionally sets `by_id`;
- reads, appends, and sets a collision list;
- reads, appends, and sets a same-name list; and
- returns a new `FunctionIndexes` record.

`initial_state` immediately destructures these three fields into
`ClosureState`; the intermediate record is only a construction product.

## Problem Statement

The current fold replaces an aggregate record and multiple persistent
collections for every declaration. Even with COW, aliases created by record
updates and old accumulator values can force copies/releases. Indexing is an
initialization phase where one final immutable result is sufficient.

## Goals

1. Build the three index components with minimal intermediate aggregate values.
2. Preserve duplicate ID and same-name ordering exactly.
3. Include top-level functions and implementation methods.
4. Demonstrate reduced allocations and time as declaration count grows.

## Non-Goals

- Do not remove collision detection.
- Do not change closure conversion, capture rules, or hoisting.
- Do not renumber function IDs.
- Do not choose a function arbitrarily when IDs collide.
- Do not change name mangling.
- Do not add global mutable indexes.

## Proposed Design

Replace record-at-a-time folding with one builder function containing three
local collection variables:

```blorp
private pure func index_functions(program: CoreProgram) -> FunctionIndexes:
	var by_id: Dict[Int, CoreFunction] = {}
	var collisions_by_id: Dict[Int, List[CoreFunction]] = {}
	var by_name: Dict[String, List[CoreFunction]] = {}

	-- Visit each function and update these components.
	...

	{
		by_id = by_id,
		collisions_by_id = collisions_by_id,
		by_name = by_name
	}
```

Because helper abstraction can accidentally recreate the same record churn,
either inline the small update block in the two declaration cases or make a
helper return a tuple of updated component dictionaries. Measure generated
allocation behavior; source-level local reassignment alone does not prove COW
consumption.

An optional second approach builds `by_id` and `by_name` first and derives
`collisions_by_id` from grouped duplicate IDs. Use it only if it preserves the
exact first-seen function and collision-list order with less work.

## Mechanical Implementation Sequence

1. Add focused tests that expose ordering and collisions rather than only
   successful lookups.
2. Add a benchmark generating N top-level functions, M implementation methods,
   configurable duplicate names, and configurable duplicate IDs.
3. Capture baseline time, allocations, and checksums for all three indexes.
4. Refactor `index_functions` to local component accumulators.
5. Remove `index_function` if it no longer expresses a useful boundary.
6. Compare exact index contents and ordering against the legacy constructor in
   a test fixture during development.
7. Run closure, identity, function-reference, sanitizer, and leak checks.

## Invariants And Pitfalls

- `by_id` retains the first function observed for an ID.
- On the second occurrence, the collision list starts with the original
  function followed by duplicates in declaration order.
- `by_name` lists functions in declaration/traversal order.
- Implementation methods participate exactly where they do today.
- Function declarations and implementation methods with the same ID must be
  treated as collisions.
- Dictionary iteration order must not affect emitted declarations or selected
  functions.
- Generated functions present before closure conversion must be indexed.
- Avoid holding two complete copies of the indexes during final construction.

## Fast Feedback Loop

Add a benchmark under `blorp/benchmark/compiler/` with controls:

```text
iterations
top_level_functions
impl_blocks
methods_per_impl
duplicate_name_interval
duplicate_id_interval
```

Suggested runs:

```text
256, 1,024, 4,096 unique functions
1,024 functions with every 16th name duplicated
1,024 functions with every 64th ID duplicated
```

Report counts for all maps, total collision entries, deterministic checksum,
allocations/releases, and elapsed microseconds.

## Functional Tests

Run:

```bash
./blorp test --timeout 180 blorp/test/compiler/stage_09_core/test_core_closure.brp
./blorp test --timeout 180 blorp/test/compiler/pipeline/test_core_closure_identity.brp
./blorp test --timeout 180 blorp/test/compiler/pipeline/test_core_function_refs.brp
scripts/compiler-check --stage core
scripts/test compiler-core-sanitize
```

Add tests for unique IDs, duplicate IDs, duplicate names, implementation
methods, source/generated functions, and deterministic lookup behavior.

## Acceptance Criteria

- `FunctionIndexes` is constructed once after collection components are ready.
- The per-function path no longer replaces a full `FunctionIndexes` record.
- Focused index contents and ordering are identical.
- Allocation count and elapsed time improve materially at 1,024 and 4,096
  functions without regressing small inputs.
- Duplicate-ID behavior remains fail closed in downstream closure lookup.
- Closure, identity, sanitizer, and leak suites pass.
