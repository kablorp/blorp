# Flatten Variable-Dimension List Resolution

**Status:** Proposed

**Current state:** `resolve_var_dims_type_list` appends ordinary types but uses
`result.concat(concrete_dims)` when one variable-dimension type expands to
several dimensions. It ran 331,640 times in the retained self-compile.
**Next action:** Add a fixture that varies input count and expansion width,
then replace repeated concat with one ownership-local accumulation strategy.
**Read first:** `blorp/src/compiler/stage_06_typecheck/infer.brp`, the variable-
dimension inference fixtures under `blorp/test/compiler/stage_06_typecheck/`,
and the [call-count screen](../../../benchmarks/results/compiler_complexity_call_counts_2026-09-14.md).
**Fast loop:** `bin/blorp check --no-format blorp/test/compiler/stage_06_typecheck/infer_fixtures/infer/should_pass/dim_monomorphize.brp` and a proposed `compiler_var_dims_resolution_profile` benchmark.
**Decision:** Preserve list order and unresolved-variable behavior; do not
change dimension solving or substitution ownership.

## Objective

Build resolved variable-dimension lists in work proportional to input plus
output size rather than repeatedly copying the accumulated prefix.

## Why and proposed shape

The current branch copies the existing result and every concrete dimension:

```blorp
for typ in types:
	match typ:
		SemanticVarDimsType(name):
			match find_var_dims_subst(subst, name):
				Some(concrete_dims):
					result = result.concat(concrete_dims)
		_:
			result = result.append(resolve_var_dims_type(subst, typ))
```

The narrow candidate is to append `concrete_dims` elements into the same
uniquely owned local result, or precompute the final length and fill once if
that has a supported, safe list-construction boundary. Do not add a general
builder abstraction unless a second measured owner needs it.

## Fast measurement

The proposed fixture should independently vary input type count, substitutions,
dimensions per substitution, and recursive type depth. Report input visits,
substitution lookups, concrete dimensions copied, accumulated-prefix elements
copied, allocations/releases, and an exact resolved-type checksum.

Start with widths `1, 4, 16, 64` and hold total output constant in a second
series so concat count can be separated from necessary output work.

## Invariants and tests

- Expanded dimensions remain at the original type's position.
- Multiple expansions preserve their internal order.
- Missing substitutions retain the original variable-dimension type.
- Recursive named, array, tuple, function, and result types remain unchanged.
- Empty concrete-dimension lists behave exactly as today.

Add focused mixed ordinary/expanded/missing cases before implementation.

## Acceptance and rejection

Accept if accumulated-prefix copying becomes zero or constant, output checksums
match, and the wide fixture improves allocations or retired instructions by at
least 10% without a material width-one regression. Run the focused inference
fixture, `scripts/compiler-check --stage typecheck`, and self-compile output
identity.

Reject a solution that changes substitution semantics, adds unsafe list writes,
or merely moves the same concatenations into a helper.
