# Index Managed-Type Membership

**Status:** Implemented locally; acceptance recommended

## Issue Summary

Replace repeated linear membership tests over `List[String]` in Core ownership
policy with a set-like managed-type index. Keep recursive type classification
semantics unchanged and defer memoization until the membership change is
measured independently.

## Profile Evidence

The compiler self-compilation baseline took 180.545 seconds, performed 704.1
million allocations, and reached 2.218 GB peak RSS. External sampling attributed
3,511 samples, 2.335% and about 4.25 seconds, to
`type_policy.is_managed_type` and the library/runtime work below it.

`is_managed_type` is called broadly by Perceus, specialization, collection
layout, and ownership-related Core passes. Each `NamedType` query currently
executes `managed_names.contains(name)`, a linear string-equality scan.
`managed_type_names` also suppresses duplicate declaration names with linear
`contains` calls while building the list.

## Current Code

Primary file: `blorp/src/compiler/stage_09_core/type_policy.brp`.

`managed_type_names(program)` starts with builtin managed names and appends
every heap record and union name if not already present.

`is_managed_type(managed_names, typ)` recursively classifies `Option`, result,
named, record, union, function, tuple, tensor, and scalar types. For a general
named type it checks:

1. `managed_names.contains(name)`;
2. one-shot stream type-name metadata; and
3. resource-source type-name metadata.

There is another public `is_managed_type` wrapper in
`blorp/src/compiler/stage_09_core/perceus.brp`; preserve its API or migrate it
coherently.

## Goals

1. Make ordinary managed-name membership expected O(1).
2. Build the membership index once per relevant Core program/policy context.
3. Preserve recursive classification and special type-name policy exactly.
4. Thread the index without copying it into every expression or AST node.
5. Demonstrate scaling improvement as managed declaration count grows.

## Non-Goals

- Do not change which types are managed.
- Do not modify Perceus retain/release policy.
- Do not cache by formatted type string.
- Do not add process-global mutable state.
- Do not combine this issue with recursive `CoreType` memoization.
- Do not change source language record/struct allocation semantics.

## Proposed Design

Use `Set[String]` if its implementation provides true indexed membership and
does not simply wrap a list. Otherwise use `Dict[String, Bool]` or a dedicated
opaque `ManagedTypeIndex` around the repository's indexed set representation.

```blorp
opaque type ManagedTypeIndex = Set[String]

pure func managed_type_index(program: CoreProgram) -> ManagedTypeIndex:
	...

pure func is_managed_type(index: ManagedTypeIndex, typ: CoreType) -> Bool:
	...
```

The opaque wrapper is appropriate only if it prevents unrelated strings from
being passed accidentally and existing APIs support it without conversion
churn. Do not add wrapper ceremony that creates more allocations than it saves.

If an ordered list is required for deterministic diagnostics or serialization,
retain it as a separate projection. Membership queries must use the index.

## Mechanical Implementation Sequence

1. Inventory all `managed_type_names` and `is_managed_type` callers and classify
   whether they require ordering or only membership.
2. Inspect `std/set.brp` and generated behavior to verify indexed complexity.
3. Add a benchmark that builds N managed declarations and performs M repeated
   queries across named, nested result, option, tuple, and scalar types.
4. Add semantic table tests comparing old list policy and new index policy.
5. Introduce `ManagedTypeIndex` or a direct set/dict representation.
6. Build it once at each pass boundary, then thread the same value through
   recursive calls.
7. Migrate callers mechanically. Do not reconstruct a set from a list at every
   function boundary.
8. Remove or narrow `managed_type_names` only after ordered consumers are
   accounted for.
9. Measure before considering type-result memoization.

## Invariants And Pitfalls

- Nested `Option[Option[T]]` is managed under the current policy.
- Stack and boxed results have special recursive behavior.
- `TypeParameterType` and `SelfType` remain unmanaged at this phase.
- Functions, tuples, tensors, heap records, unions, and boxed results remain
  managed.
- Enums, value records, ranges, and void remain unmanaged.
- One-shot stream and resource-source names remain recognized even if absent
  from the declaration index.
- Duplicate declaration names must not change semantics.
- A set's nondeterministic iteration order must never affect output.
- Avoid rebuilding the index in every Perceus function.

## Fast Feedback Loop

Add a focused benchmark with:

```text
managed names: 32, 128, 512, 2,048
queries per name: 1, 8, 64
hit/miss ratio: 0%, 50%, 100%
type nesting depth: 1, 4, 16
```

Report index build time separately from query time, successful classifications,
checksum, allocations, and elapsed microseconds. Compare the crossover point;
small programs must not pay an excessive index-construction penalty.

## Functional Tests

Locate and run the current owner suites before adding a new file:

```bash
rg -n 'is_managed_type|managed_type_names' blorp/test/compiler
scripts/compiler-check --stage core
scripts/test compiler-core-sanitize
scripts/test leak
```

Add a table-driven suite for every `CoreType` variant and the special
Option/Result/stream/resource-source cases. Retain ownership/leak regressions
for managed collections and user-defined unions/heap records.

## Acceptance Criteria

- Hot membership queries no longer call `List[String].contains`.
- The managed-name index is built once per pass/program, not once per query.
- Classification results match the pre-change table for every Core type case.
- Query scaling is approximately independent of managed-name count after index
  construction.
- Index build overhead is reported and small-input behavior does not materially
  regress.
- Core sanitizer, ownership, and leak tests pass.

## Implementation Results

Candidate measured on August 26, 2026 with:

```bash
./blorp run --no-format compiler/benchmarks/compiler_managed_type_index_profile.brp -- <managed_count> <queries_per_name> <hit_ratio_percent> <nesting_depth>
```

The clean matrix covered managed counts `32`, `128`, `512`, and `2048`;
queries per managed name `1`, `8`, and `64`; hit ratios `0`, `50`, and
`100`; and nesting depths `1`, `4`, and `16`. All 108 rows reported
`workload_valid=True`, and the legacy-list and indexed paths had matching
successful-classification counts and checksums in every row.

Build timing is measured separately from query timing. The legacy build path is
a benchmark-local copy of the old list-backed duplicate suppression logic; the
indexed path calls production `managed_type_index(program)`.

| Managed names | Legacy build us | Indexed build us | Legacy build memory | Indexed build memory |
| --- | ---: | ---: | --- | --- |
| 32 | 12-54 | 5-52 | 2 alloc / 1 release / 1 retained / 624 B | 1 alloc / 0 release / 1 retained / 96 B |
| 128 | 96-275 | 15-66 | 4 alloc / 3 release / 1 retained / 2352 B | 1 alloc / 0 release / 1 retained / 96 B |
| 512 | 1211-2745 | 58-105 | 5 alloc / 4 release / 1 retained / 4656 B | 1 alloc / 0 release / 1 retained / 96 B |
| 2048 | 17037-20991 | 260-311 | 7 alloc / 6 release / 1 retained / 18480 B | 1 alloc / 0 release / 1 retained / 96 B |

Query windows allocated no tracked objects in either implementation in every
row: `total_allocations=0`, `total_releases=0`, `retained_objects=0`, and
`allocated_bytes=0`.

| Managed names | Queries/name | Legacy query us range | Indexed query us range | Speedup range |
| --- | ---: | ---: | ---: | ---: |
| 32 | 1 | 82-705 | 19-160 | 2.9x-5.6x |
| 32 | 8 | 894-5657 | 221-894 | 3.1x-6.3x |
| 32 | 64 | 6051-20927 | 1294-3028 | 4.2x-6.9x |
| 128 | 1 | 830-6980 | 109-460 | 7.0x-15.2x |
| 128 | 8 | 5162-25255 | 334-1654 | 5.9x-15.3x |
| 128 | 64 | 27914-184274 | 2411-11838 | 7.8x-15.6x |
| 512 | 1 | 6464-38858 | 176-750 | 26.8x-51.8x |
| 512 | 8 | 46022-300142 | 1183-5688 | 25.5x-52.8x |
| 512 | 64 | 361628-2479664 | 9743-49233 | 25.7x-50.4x |
| 2048 | 1 | 84788-635496 | 591-2989 | 88.0x-212.6x |
| 2048 | 8 | 665144-4849692 | 5056-25542 | 86.3x-189.9x |
| 2048 | 64 | 5350855-37808730 | 39286-211751 | 91.5x-178.5x |

Representative worst-case rows:

| Managed names | Queries/name | Hit ratio | Depth | Legacy query us | Indexed query us |
| --- | ---: | ---: | ---: | ---: | ---: |
| 128 | 64 | 0 | 16 | 184274 | 11838 |
| 512 | 64 | 0 | 16 | 2479664 | 49233 |
| 2048 | 64 | 0 | 16 | 37808730 | 211751 |

Notes and caveats:

- `managed_type_names(program)` had no production caller after the migration and
  was removed instead of preserved as a public projection.
- The benchmark retains local legacy list-builder and list-classifier helpers
  only as measurement and semantic oracles.
- This issue deliberately does not add recursive `CoreType` classification
  memoization.
- The timing matrix was a single clean serialized run, not a statistical
  benchmark suite with repeated samples.
