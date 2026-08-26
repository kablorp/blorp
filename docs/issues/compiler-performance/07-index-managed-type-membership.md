# Index Managed-Type Membership

**Status:** Ready for a narrow representation change

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

Primary file: `compiler/src/stage_09_core/type_policy.brp`.

`managed_type_names(program)` starts with builtin managed names and appends
every heap record and union name if not already present.

`is_managed_type(managed_names, typ)` recursively classifies `Option`, result,
named, record, union, function, tuple, tensor, and scalar types. For a general
named type it checks:

1. `managed_names.contains(name)`;
2. one-shot stream type-name metadata; and
3. resource-source type-name metadata.

There is another public `is_managed_type` wrapper in
`compiler/src/stage_09_core/perceus.brp`; preserve its API or migrate it
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
rg -n 'is_managed_type|managed_type_names' compiler/tests
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

