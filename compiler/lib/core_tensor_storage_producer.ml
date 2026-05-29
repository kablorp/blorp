(** Tensor producer storage contracts.

    This module is the explicit late-Core boundary that describes which opaque
    tensor/vector runtime builtins produce storage whose runtime representation
    is known by the compiler.

    Calls still arrive here as [CKBuiltin] C names. That string boundary is
    transitional and intentionally isolated here so [Core_codegen_prepare] can
    consume a typed contract instead of carrying ad hoc name lists. *)

type source_arg = SourceArg0 | SourceArg1 | SourceArg2
type storage_rule = KnownResultLayout | PreservesArgLayout of source_arg

type producer =
  | KnownResultProducer of string
  | PreservesArgProducer of string * source_arg

let source_arg_index = function
  | SourceArg0 -> 0
  | SourceArg1 -> 1
  | SourceArg2 -> 2

let fold_storage_rule ~known_result ~preserves_arg = function
  | KnownResultLayout -> known_result ()
  | PreservesArgLayout source_arg -> preserves_arg (source_arg_index source_arg)

let storage_rule = function
  | KnownResultProducer _ -> KnownResultLayout
  | PreservesArgProducer (_, source_arg) -> PreservesArgLayout source_arg

let producer_debug_name = function
  | KnownResultProducer name | PreservesArgProducer (name, _) -> name

let name_is_in names name = List.exists (String.equal name) names

let known_result_builtin_names =
  [
    "blorp_vector_new_i64";
    "blorp_vector_new_f64";
    "blorp_vector_new_f32";
    "blorp_vector_new_packed";
    "blorp_vector_new_sized";
    "blorp_vector_new_fill_i64";
    "blorp_vector_new_fill_f64";
    "blorp_vector_new_fill_f32";
    "blorp_vector_new_fill_packed";
    "blorp_vector_new_fill_sized";
    "blorp_matrix_new_fill_i64";
    "blorp_matrix_new_fill_f64";
    "blorp_matrix_new_fill_f32";
    "blorp_matrix_new_fill_packed";
    "blorp_matrix_new_fill_sized";
    "blorp_tensor_new_i64";
    "blorp_tensor_new_f64";
    "blorp_tensor_new_f32";
    "blorp_tensor_new_packed";
    "blorp_tensor_new_sized";
    "blorp_tensor3_new";
    "blorp_tensor4_new";
    "blorp_tensor5_new";
    "blorp_vector_add_i64";
    "blorp_vector_sub_i64";
    "blorp_vector_mul_i64";
    "blorp_vector_div_i64";
    "blorp_vector_mod_i64";
    "blorp_vector_add_int";
    "blorp_simd_vector_add_f64";
    "blorp_simd_vector_sub_f64";
    "blorp_simd_vector_mul_f64";
    "blorp_simd_vector_div_f64";
    "blorp_simd_vector_add_f32";
    "blorp_simd_vector_sub_f32";
    "blorp_simd_vector_mul_f32";
    "blorp_simd_vector_div_f32";
    "blorp_vector_scalar_add_i64";
    "blorp_vector_scalar_sub_i64";
    "blorp_vector_scalar_mul_i64";
    "blorp_vector_scalar_div_i64";
    "blorp_vector_scalar_mod_i64";
    "blorp_vector_scalar_rev_sub_i64";
    "blorp_vector_scalar_rev_div_i64";
    "blorp_vector_scalar_rev_mod_i64";
    "blorp_vector_scalar_add_f64";
    "blorp_vector_scalar_sub_f64";
    "blorp_vector_scalar_mul_f64";
    "blorp_vector_scalar_div_f64";
    "blorp_vector_scalar_rev_sub_f64";
    "blorp_vector_scalar_rev_div_f64";
    "blorp_vector_scalar_add_f32";
    "blorp_vector_scalar_sub_f32";
    "blorp_vector_scalar_mul_f32";
    "blorp_vector_scalar_div_f32";
    "blorp_vector_scalar_rev_sub_f32";
    "blorp_vector_scalar_rev_div_f32";
    "blorp_vector_exp_float32";
    "blorp_vector_log_float32";
    "blorp_vector_sqrt_float32";
    "blorp_vector_cross_float";
    "blorp_tensor_matrix_multiply_int";
    "blorp_tensor_matrix_multiply_float";
    "blorp_tensor_matrix_multiply_float32";
    "blorp_tensor_matrix_vector_multiply_int";
    "blorp_tensor_matrix_vector_multiply_float";
    "blorp_tensor_matrix_vector_multiply_float32";
    "blorp_tensor_transposed_matrix_vector_multiply_int";
    "blorp_tensor_transposed_matrix_vector_multiply_float";
    "blorp_tensor_transposed_matrix_vector_multiply_float32";
    "blorp_tensor_outer_int";
    "blorp_tensor_outer_float";
    "blorp_tensor_outer_float32";
    "blorp_matrix_map";
    "blorp_matrix_map_indexed";
    "blorp_matrix_zip_map";
  ]

let source_arg0_builtin_names =
  [
    "blorp_assert_shape_nullable";
    "blorp_assert_shape";
    "blorp_tensor_slice_row";
    "blorp_vector_add_float";
    "blorp_vector_exp";
    "blorp_vector_log";
    "blorp_vector_abs";
    "blorp_vector_sqrt";
  ]

let source_arg1_builtin_names =
  [
    "blorp_vector_scalar_op_int";
    "blorp_vector_scalar_op_float";
    "blorp_vector_scalar_op_rev_int";
    "blorp_vector_scalar_op_rev_float";
    "blorp_vector_scalar_op_int_cow";
    "blorp_vector_scalar_op_float_cow";
  ]

let source_arg2_builtin_names = [ "blorp_vector_op"; "blorp_vector_op_cow" ]

let preserved_source_arg name =
  if name_is_in source_arg0_builtin_names name then Some SourceArg0
  else if name_is_in source_arg1_builtin_names name then Some SourceArg1
  else if name_is_in source_arg2_builtin_names name then Some SourceArg2
  else None

let producer_of_builtin_name name =
  if name_is_in known_result_builtin_names name then
    Some (KnownResultProducer name)
  else
    Option.map
      (fun source_arg -> PreservesArgProducer (name, source_arg))
      (preserved_source_arg name)

let of_call_kind = function
  | Core.CKBuiltin name -> producer_of_builtin_name name
  | Core.CKUnknown | Core.CKSelectedDirect _ | Core.CKUser _ | Core.CKForeign _
  | Core.CKIntrinsic _ | Core.CKClosure ->
      None
