# Index Monomorphization Type-Parameter Membership

**Status:** Measured, production change rejected

**Current state:** `types_contain_parameter` recursively walks Core types and
`type_contains_parameter` scans `type_params: List[String]` at every parameter
leaf. `types_contain_parameter` ran 107,722 times in the retained self-compile.
**Next action:** Keep the retained `compiler_mono_parameter_profile` probe for
future membership experiments; do not add a production membership index without
a caller-owned boundary that amortizes index construction.
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

## 2026-09-15 Measurement

Added the retained probe in
`blorp/benchmark/compiler/compiler_mono_parameter_profile.brp` and the focused
test
`blorp/test/compiler/stage_09_core/test_core_mono_parameter_profile_benchmark.brp`.
The probe counts top-level queries, Core type nodes, parameter leaves, list
name comparisons, indexed membership probes, index build work, and Boolean
result checksums across named types, functions, stack/boxed results, tensor
dimensions, tuples, `SelfType`, and terminal variants.

Focused wide no-hit workload:

```bash
bin/blorp run --release --no-format \
  blorp/benchmark/compiler/compiler_mono_parameter_profile.brp -- 32 128 8 -1
```

Observed deterministic work for that shape:

| Metric | Linear | Indexed model |
| --- | ---: | ---: |
| Top-level queries | 1,152 | 1,152 |
| Type nodes visited | 10,624 | 10,624 |
| Parameter leaves | 1,408 | 1,408 |
| Name comparisons / membership probes | 45,056 | 1,408 |
| Index build names | 0 | 32 |

The Boolean checksums matched across the linear model, indexed model, and
current production implementation. One- and two-parameter runs stayed on the
linear public behavior and retained the baseline allocation counts.

Production indexing experiments were rejected. Building a `Set[String]` in the
public single-type query rebuilt the index once per query and increased the
wide no-hit allocation count from 7,888 to 10,192 in the focused probe. An
adaptive wrapper that kept 0-2 parameters linear still added allocation through
the wrapper representation, and a later attempt had to special-case nested
single-type recursion to recover the baseline. A candidate self-compile did
not provide a speedup signal (`real 158.42s` candidate versus `110.51s`
baseline executable on the local macOS run, with output identity confounded by
the rebuild changing generated build-info inputs).

Decision: reject the production membership index for now. The retained probe
is useful evidence that a caller-owned index could help only if an existing
wide list/substitution boundary can build it once and reuse it across many
recursive leaves without affecting the public single-type path.
