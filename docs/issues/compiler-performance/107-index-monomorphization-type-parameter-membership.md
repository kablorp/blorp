# Index Monomorphization Type-Parameter Membership

**Status:** Proposed, measurement-gated

**Current state:** `types_contain_parameter` recursively walks Core types and
`type_contains_parameter` scans `type_params: List[String]` at every parameter
leaf. `types_contain_parameter` ran 107,722 times in the retained self-compile.
**Next action:** Count type nodes, parameter leaves, and string comparisons per
top-level query before adding a membership index.
**Read first:** `blorp/src/compiler/stage_09_core/mono.brp`,
`blorp/test/compiler/stage_09_core/test_core_mono.brp`, and the
[call-count screen](../../../benchmarks/results/compiler_complexity_call_counts_2026-09-14.md).
**Fast loop:** `bin/blorp test blorp/test/compiler/stage_09_core/test_core_mono.brp`.
Add a nested-type/parameter-width `compiler_mono_parameter_profile` probe
before changing the representation.
**Decision:** Keep the public `core_type_contains_parameter` contract; do not
mix this with substitution or specialization changes.

## Objective

Reduce repeated type-parameter name scans during recursive Core-type queries
while preserving every variant's short-circuit result.

## Why

```blorp
for typ in types:
	if type_contains_parameter(type_params, typ):
		return True

match typ:
	TypeParameterType(name):
		type_params.contains(name)
	NamedType(_, args):
		types_contain_parameter(type_params, args)
```

The worst case is type-node count times parameter count. Early exit and small
parameter lists can make the list optimal, so measure before replacing it.

## Bounded experiment

Vary type-tree depth/branching, parameter count, hit position, no-hit cases,
tensor dimensions, function types, and result/tuple nesting. Report top-level
queries, type nodes visited, membership queries, names compared, index build
work, allocations/releases, and a Boolean result checksum.

If admitted, build one private membership view at the top-level boundary and
pass it through recursive helpers. Preserve the original list only where order
is required elsewhere. Do not rebuild a set at each recursive call.

## Invariants and tests

- Early-return truth values match for every Core type variant.
- `SelfType`, tensor dimensions, results, tuples, and function returns retain
  current handling.
- Name equality and monomorphization identity are unchanged.
- Empty and single-parameter cases stay allocation-light.

## Acceptance and rejection

Accept if realistic no-hit/wide cases reduce comparisons substantially and
improve focused instructions or allocations by at least 10%, while one- and
two-parameter cases stay within 2%. Run the mono suite,
`scripts/compiler-check --changed`, Core invariants, and a compiler self-compile.

Reject if index construction is repeated recursively, if it changes public
type representations, or if production parameter widths are too small to
recover its cost.
