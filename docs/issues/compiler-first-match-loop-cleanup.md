# Replace Manual First-Match Loops With `List.find`

## Status

Ready for implementation.

## Issue Summary

Replace the 14 private compiler search helpers listed below with direct
`List.find` expressions. Four helpers have one consumer and should be inlined
and deleted. Ten helpers have multiple consumers and should retain their names
but replace their imperative loop bodies with `find`.

This is a mechanical source cleanup. Do not change lookup keys, lookup order,
fallback behavior, collection representation, or surrounding callers.

## Context

The compiler contains repeated first-match searches written as mutable loops:

```blorp
var result: Option[Entry] = None

for entry in entries:
	if predicate(entry):
		result = Some(entry)
		break

result
```

Blorp already provides a pure, short-circuiting `List.find` builtin with the
same first-match contract:

```blorp
entries.find(func(entry): predicate(entry))
```

A scan on 2026-08-24 found 40 loops with the general accumulator shape. Only 14
return the matched list element unchanged. Those 14 form this issue because
their replacement introduces no intermediate collection, no projection, and no
additional managed value.

The other 26 loops return a field or computed value from the matched element.
They are explicitly deferred because replacing them with `find(...).map(...)`
may introduce an intermediate `Option[Entry]` and additional ARC traffic. They
should not be included without a `find_map` design or measurements.

## Relationship To Other Cleanup Issues

This issue follows the completed private-wrapper and single-use straight-line
function cleanups. Revalidate names and callers because those cleanups may have
deleted or moved a listed helper.

## Goal

- Replace 14 mutable search loops with `List.find`.
- Delete the four helpers identified as single-consumer helpers.
- Preserve first-match and source-order behavior exactly.
- Reduce mutable local state and hand-written loop boilerplate.

## Non-Goals

Do not:

- replace projection searches with `find(...).map(...)`;
- add `find_map` to the standard library;
- convert failure accumulators or validation loops;
- replace searches with dictionaries or indexes;
- reorder source collections;
- deduplicate or sort collections;
- change equality or identity predicates;
- rename lookup functions or parameters;
- change caller control flow; or
- perform adjacent cleanup.

## Fixed Transformation A: Retain The Helper

For rows marked `REWRITE BODY`, replace only the mutable loop body.

Before:

```blorp
private pure func find_entry(entries: List[Entry], key: Key) -> Option[Entry]:
	var result: Option[Entry] = None

	for entry in entries:
		if entry.key == key:
			result = Some(entry)
			break

	result
```

After:

```blorp
private pure func find_entry(entries: List[Entry], key: Key) -> Option[Entry]:
	entries.find(func(entry): entry.key == key)
```

Do not edit any caller for `REWRITE BODY` rows.

## Fixed Transformation B: Inline And Delete

For rows marked `INLINE + DELETE`, replace the sole direct call with the listed
`find` expression after substituting actual arguments, then delete the private
helper.

Before:

```blorp
match find_entry(entries, key):
	Some(entry): use(entry)
	None: fallback
```

After:

```blorp
match entries.find(func(entry): entry.key == key):
	Some(entry): use(entry)
	None: fallback
```

Do not otherwise rewrite the surrounding `match`, `map`, or `get_or` call.

## Mandatory Precondition Check

Before editing each function:

```bash
rg -n '\bFUNCTION_NAME\b' blorp/src/compiler blorp/test/compiler
```

For `INLINE + DELETE`, require exactly one declaration and one consumer. For
`REWRITE BODY`, require the listed declaration and only direct-call consumers.
If a function is recursive, passed as a value, or has changed away from the
documented loop shape, record `SKIPPED: inventory drift` and do not improvise.

## Candidate Inventory And Exact Replacements

Paths are relative to `blorp/src/compiler/`. Definition and caller lines are
navigation hints from the 2026-08-24 scan.

### Types

| File | Function | Action | Definition | Current callers | Replacement body |
|---|---|---|---:|---|---|
| `stage_06_typecheck/type_system/context.brp` | `find_type_home_entry` | REWRITE BODY | 232 | 267, 280 | `context.type_homes.find(func(entry): entry.type_name == type_name)` |
| `stage_06_typecheck/type_system/context.brp` | `find_meta_binding_entry` | INLINE + DELETE | 383 | 398 | `context.meta_bindings.find(func(entry): entry.meta_id == meta_id)` |
| `stage_06_typecheck/type_system/env.brp` | `find_overload_set` | REWRITE BODY | 3074 | 3086, 3096, 3586, 3650, 3674, 3722 | `sets.find(func(set): set.name == name)` |

### Typechecking

| File | Function | Action | Definition | Current callers | Replacement body |
|---|---|---|---:|---|---|
| `stage_06_typecheck/decl.brp` | `find_trait_method` | INLINE + DELETE | 4723 | 4916 | `methods.find(func(method): method.name == name)` |
| `stage_06_typecheck/headers/type_header_graph.brp` | `type_parameter_by_name` | REWRITE BODY | 859 | 1102, 1222, 1233 | `parameters.find(func(parameter): resolution_parameter_name(parameter) == name)` |
| `stage_06_typecheck/infer.brp` | `find_module_constructor` | REWRITE BODY | 8363 | 6635, 8444, 8516, 8568, 8794, 16435 | `env_get_constructors(env, name).find(func(ctor): typecheck_state_type_home_matches(context.state, ctor.parent_type, module_path))` |
| `stage_06_typecheck/modules/module_binding.brp` | `find_surface_symbol` | REWRITE BODY | 734 | 982, 1007, 1031 | `symbols.find(func(symbol): symbol.name == name)` |
| `stage_06_typecheck/state.brp` | `find_type_home_entry` | REWRITE BODY | 699 | 717, 721 | `state.type_homes.find(func(home): home.type_name == type_name)` |

### Core Lowering And Core

| File | Function | Action | Definition | Current callers | Replacement body |
|---|---|---|---:|---|---|
| `stage_08_core_lower/flatten.brp` | `find_callable_rewrite` | REWRITE BODY | 459 | 522, 539, 554, 1590 | `rewrites.find(func(rewrite): rewrite.source_name == source_name and rewrite.def_id == def_id)` |
| `stage_09_core/backend_projection.brp` | `find_function_name` | REWRITE BODY | 140 | 381, 392, 393 | Preserve `suffix`, then return `names.find(func(name): name == expected or name.ends_with(suffix))` |
| `stage_09_core/mono_data.brp` | `find_template` | REWRITE BODY | 195 | 321, 708, 876 | `templates.find(func(template): template_name(template) == name)` |
| `stage_09_core/mono_data.brp` | `find_transparent_alias` | INLINE + DELETE | 209 | 300 | `aliases.find(func(alias_decl): alias_decl.name == name and not alias_decl.is_opaque)` |
| `stage_09_core/prepare.brp` | `find_union_variant_by_reference` | REWRITE BODY | 413 | 436, 452, 3571 | `union_decl.variants.find(func(variant): union_variant_matches_reference(variant, constructor_name, def_id))` |
| `stage_09_core/synth_context.brp` | `find_type_alias` | INLINE + DELETE | 85 | 125 | `context.type_aliases.find(func(alias_decl): alias_decl.name == name)` |

## Mechanical Execution Order

### Batch 1: Types

Edit only:

1. `stage_06_typecheck/type_system/context.brp`
2. `stage_06_typecheck/type_system/env.brp`

Then run:

```bash
./blorp format blorp/src/compiler/stage_06_typecheck/type_system/context.brp \
  blorp/src/compiler/stage_06_typecheck/type_system/env.brp
scripts/compiler-check --stage types
```

### Batch 2: Typechecking

Edit only:

1. `stage_06_typecheck/decl.brp`
2. `stage_06_typecheck/headers/type_header_graph.brp`
3. `stage_06_typecheck/infer.brp`
4. `stage_06_typecheck/modules/module_binding.brp`
5. `stage_06_typecheck/state.brp`

Then run:

```bash
./blorp format \
  blorp/src/compiler/stage_06_typecheck/decl.brp \
  blorp/src/compiler/stage_06_typecheck/headers/type_header_graph.brp \
  blorp/src/compiler/stage_06_typecheck/infer.brp \
  blorp/src/compiler/stage_06_typecheck/modules/module_binding.brp \
  blorp/src/compiler/stage_06_typecheck/state.brp
scripts/compiler-check --stage typecheck
```

### Batch 3: Core Lowering And Core

Edit only:

1. `stage_08_core_lower/flatten.brp`
2. `stage_09_core/backend_projection.brp`
3. `stage_09_core/mono_data.brp`
4. `stage_09_core/prepare.brp`
5. `stage_09_core/synth_context.brp`

Then run:

```bash
./blorp format \
  blorp/src/compiler/stage_08_core_lower/flatten.brp \
  blorp/src/compiler/stage_09_core/backend_projection.brp \
  blorp/src/compiler/stage_09_core/mono_data.brp \
  blorp/src/compiler/stage_09_core/prepare.brp \
  blorp/src/compiler/stage_09_core/synth_context.brp
scripts/compiler-check --stage core-lower
scripts/compiler-check --stage core
```

## Deferred Projection Searches

Do not edit these 26 structurally similar functions in this issue:

- `unify_subst_list_lookup`
- `dim_lookup_meta`
- `impl_subst_lookup`
- `find_subscript_proof_for_var`
- `find_range_proof_for_var`
- `find_module_alias`
- `definition_module_find_func_callable_id`
- `definition_module_find_source_definition_id`
- `definition_index_rep_find_func_callable_id`
- `definition_index_rep_find_source_definition_id`
- `graph_local_trait_default_methods`
- `graph_imported_trait_default_methods`
- `constructor_for_variant`
- `layout_substitution_find`
- `semantic_type_substitution_find`
- `find_var_dims_subst`
- `resource_capability_memo_lookup`
- `ctfe_eval_dict_get`
- `rewritten_global_name`
- `raw_tensor_view_kind`
- `lookup_substitution`
- `request_source_name_for_concrete_name`
- `replacement_def_id`
- `std_call_kind`
- `semantic_constructor_case`
- `tuple_return_reference`

Their loop returns a projection rather than the matched element. A future issue
must decide whether to add `List.find_map` or prove that `find(...).map(...)`
does not add material ARC or allocation overhead.

## Final Verification

After all batches:

```bash
scripts/compiler-check --changed
make
scripts/test compiler-blorp
make quality
git diff --check
```

Inspect the final diff. It may contain only:

- replacement of the 10 `REWRITE BODY` loop bodies with the listed `find`
  expressions;
- substitution and deletion of the four `INLINE + DELETE` helpers; and
- formatting caused by those exact edits.

## Acceptance Criteria

- All 14 candidates are completed or marked `SKIPPED: inventory drift`.
- The four `INLINE + DELETE` symbols have no remaining references.
- The 10 retained helpers contain no mutable result accumulator or explicit
  search loop.
- Every replacement preserves the exact predicate and source list order.
- No `find(...).map(...)`, `filter`, new list allocation, or new index appears.
- None of the 26 deferred projection searches changes.
- Types, typechecking, Core lowering, and Core focused checks pass.
- `scripts/compiler-check --changed`, `make`, `scripts/test compiler-blorp`,
  `make quality`, and `git diff --check` pass.

## Expected Impact

This issue removes four private functions and simplifies ten others. The
primary benefit is deleting mutable search boilerplate in favor of the standard
first-match primitive. Because the replacement directly returns the matched
element, it should not allocate an intermediate list or add an `Option.map`
step. Do not claim a performance improvement without measurement.
