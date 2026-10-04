# Diagnostic regressions held back from the fixture gate

Status: open.

These 168 should_fail fixtures are still rejected, but the current diagnostic
is less helpful than the one the fixture pins: a help line, suggestion or name
was lost, or the wording is misleading. AGENTS.md rules 6 and 7 ask every
compile error to teach the fix, so the fixtures stay unmarked (not run by
`run_blorp_check_fixtures.py`) until the message is restored. Most of them
still guard a real rule (index proofs, purity, exhaustiveness), so restoring a
class puts those rules back under the gate.

Fixtures live under
`blorp/test/compiler/stage_06_typecheck/fixtures/typecheck/should_fail/`
("typecheck") and
`blorp/test/compiler/stage_06_typecheck/infer_fixtures/infer/should_fail/`
("infer"). Each class gives one pinned/current pair.

The 13 missing-module and nine empty-list inference fixtures were restored and
marked for `RUN-BLORP-CHECK`; they are no longer in this inventory.

## Classes

### Subscript proof error says only literals are accepted (13)

Pinned: `Subscript index must be a compile-time constant or a loop variable
proven in-bounds (e.g., for i in 0..length(v): v[i]). Use get() for
runtime-checked access`. Current: `Subscript index must be a compile-time
integer literal. Use get() for runtime-checked access`, which is wrong for
range-proved loop variables and drops the alternative.

typecheck: `flattened_row_major_index_off_by_one`, `mutable_var_narrowing_unsound`,
`narrowing_and_chain_incomplete`, `narrowing_length_missing_lower`,
`narrowing_modulo_negative_lhs`, `narrowing_mutable_if_length`,
`narrowing_mutable_var`, `narrowing_or_chain`; infer:
`dim_branch_bound_offset_subscript`, `int_as_range_type`,
`range_conditional_incomplete`, `subscript_assign_unproven`,
`subscript_runtime_index`.

### Method call with no matching function reported as a field access (11)

Pinned: `No function 'get' available for type ParallelList[Int]`. Current:
`Cannot access field on type ParallelList[Int]. Field access is supported on
record fields. Use tuple[index] for tuple elements`, then `Cannot call
non-function type: Void`.

typecheck: `visibility_ufcs_private`, `file_resource_reader_rw_write`,
`file_resource_writer_rw_read`; infer: `method_not_found`,
`ufcs_type_import_wrong_type`, `channel_close_removed`,
`parallel_list_get_unavailable`, `parallel_list_set_unavailable`,
`parallel_matrix_get_unavailable`, `parallel_vector_filter_unavailable`,
`parallel_vector_get_unavailable`.

### Tensor arithmetic mismatch blamed on non-numeric element types (9)

Pinned: `Cannot apply + to Float[#3] and Float[#4]`. Current: `Tensor
arithmetic requires concrete numeric element types, got Float[#3] and
Float[#4]`, although both element types are numeric and the shapes differ.

typecheck: `tensor_diff_ndim_add`, `tensor_dim_mismatch_add`,
`tensor_elem_type_mismatch`, `tensor_scalar_broadcast_wrong_type`; infer:
`tensor_broadcast_type_mismatch`, `tensor_elementwise_dim_mismatch`,
`tensor_elementwise_dim_param_mismatch`, `tensor_elementwise_type_mismatch`,
`variadic_elementwise_unsound`.

### Purity error lost its fix suggestion or reason (9)

Pinned: `Pure function 'apply' has impure callback parameter 'f'. Use 'pure
(Int) -> Int' for the parameter type` (or a note such as `'print' is impure
because it performs I/O` with a help line). Current: the first sentence only.

typecheck: `purity_eta_expansion_bypass`, `purity_hof_exemption_bypass`,
`purity_impure_callback_alias_param`, `purity_impure_callback_chain`,
`purity_impure_callback_param`, `purity_impure_callback_to_pure_func`,
`purity_impure_lambda_to_pure_func`, `purity_builtin_reason`,
`structured_purity_note`.

### Import suggestions lost (7)

Pinned: `'None' is a constructor of 'Option' — import it with the type:
Option(None)`, `help: 'sort' requires an import: import: list: sort`, or an
`as` alias suggestion for an ambiguous import. Current: `'None' is not exported
by module 'option'`, ``Unbound value `sort` ``, or the bare ambiguity.

typecheck: `module_ambiguous_import`, `bare_constructor_import`,
`bare_constructor_import_non_prelude`; infer: `undefined_suggest_import`,
`qualified_call_no_alias`, `duplicate_import_names`,
`resolution_bare_constructor_import`.

### Constructor or enum variant of another type reported as unknown (7)

Pinned: `Constructor Some (from option) belongs to type Option (from option),
not Color`. Current: ``Unknown constructor pattern `Some` ``; for an enum variant
in a typed tensor literal, ``Unbound value `A` ``.

typecheck: `constructor_wrong_type_qualified`,
`match_cross_union_constructor_on_bool`, `match_or_pattern_cross_union`,
`match_wrong_union_constructor`; infer: `match_cross_type_constructor`,
`packed_enum_tensor_mixed_enums`, `packed_enum_tensor_set_wrong_enum`.

### Purity error names the wrong callee (6)

Pinned: `Pure function 'bad' cannot call impure function 'impure_double'`.
Current: `... cannot call impure function 'map'` (the higher-order function)
or `'<closure>'` (instead of the variable or field name).

typecheck: `hof_impure_in_pure`, `impure_in_pure_map`, `pure_impure_callback`,
`pure_hof_mixed_callbacks`, `purity_impure_via_variable`,
`purity_record_field_impure_call`.

### Opaque-type guidance lost (6)

Pinned: `Cannot access field on opaque type heap.Heap[Int]. Use the public
constructor and accessor functions for this type`, or the help `Use a public
constructor or accessor from the module that defines the opaque type.`
Current: the generic field-access message, or the error without its help.

typecheck: `std_cache_opaque_rejects_field_access`,
`std_heap_opaque_rejects_field_access`,
`std_sorted_map_opaque_rejects_field_access`,
`std_units_duration_opaque_rejects_field_access`,
`opaque_type_from_outside_module`, `opaque_type_into_outside_module`.

### Did-you-mean, migration and immutability help lost (11)

Pinned: `help: Did you mean 'print'?`; `help: blorp doesn't use 'let'. Write
'name: Type = value' or 'var name = value'`; `help: Declare with 'var' to make
it mutable: var x = ...`. Current: no help line.

typecheck: `import_typo_suggest`, `mutate_for_variable`, `mutate_parameter`;
infer: `did_you_mean_identifier`, `structured_help_hint`, `lowercase_type_name`,
`let_keyword`, `return_keyword`, `range_function`, `immutable_assign_hint`,
`structured_immutable_help`.

### Other lost help lines (15)

Pinned explanations now missing: the `@tail_recursive` reason, the trait
method collision remedy, `Add 'T: Orderable' to the function signature`,
`Convert with to_float(x) or to_int(y)`, the Option unwrapping help, the `+`
operand note, the wildcard help for non-exhaustive matches, the top-level
initializer help, the `items.concurrent(...)` help, `Use 'var' and reassignment
instead of re-declaring`, and the generic range literal explanation.

typecheck: `tailrec_in_loop_body`, `tailrec_not_tail`, `tailrec_not_tail_in_let`,
`trait_method_name_collision`, `structured_exhaustive_note`,
`top_level_mutable_initializer_call`, `concurrently_loop_value_position`,
`concurrent_block_redeclare_outer_binding`, `generic_range_nonzero_literal`;
infer: `unbounded_compare`, `int_plus_float_hint`, `option_plus_int`,
`structured_binop_note`, `shadow_for_loop_var`, `shadow_tuple_destruct`.

### Lost names (54)

Pinned names now missing: or-pattern variable lists (`'r' vs 'h, w'`), the loop
offset expression (`i - 1`), the escaping binding (`: source`), the callee of a
qualified call (`in call to 'read_chunk'`), the trait and parameter of an
untyped trait method parameter, the operator trait (`does not implement
Addable`), the arm of a mismatched match case (`(arm 2, pattern False)`), and
the parameter name in an argument mismatch: pinned `argument 1 ('x') expected
Int, got String`, current `argument 1 expected Int, got String at <path>:L:C`
(`arg_mismatch_with_param_name` exists to pin the name). Where a generic call
now reports `Generic type parameter T inferred as Int and String`, the argument
and its name are both gone.

typecheck: `match_or_pattern_different_vars`, `loop_offset_negative`,
`loop_offset_oob`, `tcp_connections_source_cannot_escape_with`,
`tcp_public_api_rejects_raw_int`, `trait_method_untyped_param`,
`operator_trait_bound_qualified`, `match_body_type_mismatch`,
`cross_param_dim_mismatch`, `enumerate_list`, `enumerate_outside_loop`,
`impure_lambda_to_pure_param`, `impure_to_pure_parameter`,
`matrix_from_row_major_vector_dim_mismatch`,
`matrix_set_diagonal_requires_square_matrix`,
`matrix_trace_requires_square_matrix`, `matrix_zip_map_dim_mismatch`,
`numeric_float32_where_float`, `numeric_int8_where_int`,
`purity_alias_impure_callback_blocks_lambda_inference`,
`purity_lambda_inference_rejects_returned_impure_closure`,
`tensor_float32_for_float_tensor`; infer: `or_pattern_binding_mismatch`,
`arg_mismatch_with_param_name`, `match_inconsistent_types`,
`arg_mismatch_with_func_name`, `dim_arithmetic_no_solution`,
`dim_canonical_reject`, `dim_nonexact_div`, `dim_quadratic_stuck`,
`dim_solve_negative`, `dim_solving_reject`, `forge_range_func_arg`,
`function_arg_count_mismatch`, `function_multi_param_variance`,
`function_param_variance`, `generic_function_arg_mismatch`,
`generic_type_mismatch`, `lambda_return_mismatch`, `lambda_tuple_type_mismatch`,
`list_constructor_wrong_arg`, `list_type_mismatch`, `literal_string_cli_arg`,
`literal_string_injection`, `multi_char_type_mismatch`,
`nested_list_type_mismatch`, `numeric_param_type_mismatch`,
`packed_enum_tensor_param_mismatch`, `tensor_dim_mismatch`,
`tensor_elem_mismatch`, `type_param_conflict_provenance`,
`variadic_dims_elem_mismatch`, `variadic_dims_narrowing`, `wrong_arg_type`.

### Misleading wording (20)

- A module or type from another file is named by its working-directory-relative
  path (`'secret_helper' is private in module
  'blorp/test/compiler/stage_06_typecheck/fixtures/typecheck/helpers/visibility_mod'`,
  `` declared as `TokenB` but initializer has type
  `blorp/test/.../helpers/type_identity_a.Token` ``) instead of the import path
  the user wrote (`'../helpers/visibility_mod'`), so the message depends on
  where `blorp` was run (typecheck `import_same_local_type_names_distinct`,
  `visibility_import_private_aliased`, `visibility_import_private_func`,
  `visibility_import_private_record`, `visibility_import_private_var`,
  `visibility_private_impl_trait_dispatch`,
  `visibility_private_trait_methods_leak`, `visibility_qualified_private_func`).
- A qualified call to an existing private function reports ``Module alias `S`
  for module `string` has no function `raw_last_index_of` ``, as if it did not
  exist, where the pin said it is not exported (typecheck
  `visibility_qualified_private_func`, `visibility_qualified_private_std`,
  `pkg_dns_raw_resolve_ffi_private`).
- `x: Option = None` reports ``Binding `x` declared as `Option` but initializer
  has type `Option[?m0]` ``, leaking an inference variable instead of saying
  `Option` needs a type argument (infer `option_untyped`).
- `Float[String]` reports `Type 'Float' expects 0 argument(s), got 1` instead of
  saying a dimension must be `#N`, `#3` or `#Ds...`
  (typecheck `tensor_string_dim_in_sig`, infer `tensor_dim_not_dimension_type`).
- `#Ds...` in a record field reports `Unknown type parameter '#Ds'` (infer
  `vardims_in_record_field`).
- An impure global initializer reports `compile-time constant evaluation does
  not support impure function calls yet`; GRAMMAR says such calls must be pure,
  not that support is pending (typecheck `compile_time_impure_initializer`).
- A resource-returning body with no return type gets
  `help: add '-> Result[FileReader, fs.IOError]'`, a signature that is itself
  rejected (typecheck `file_resource_inferred_return_carrier`).
- Passing `open_read` or a lambda returning an acquisition reports `scoped
  resource value cannot be passed` (typecheck `file_resource_function_call_arg`,
  `file_resource_lambda_return_call_arg`).
- A foreign include path with a newline or quote is printed raw, so the
  diagnostic splits across lines (typecheck `foreign_bad_include_newline`,
  `foreign_bad_include_quote`).

## Acceptance

For each class, the diagnostic regains the pinned information (the exact
pinned text need not return; update the fixture's EXPECT lines to the new text
when it is at least as helpful), the class's fixtures pass
`run_blorp_check_fixtures.py`, carry `-- RUN-BLORP-CHECK`, and
`expected_blorp_check_fixture_count` in `scripts/test` is raised to match.
