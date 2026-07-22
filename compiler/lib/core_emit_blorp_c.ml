(** Blorp-owned C backend boundary for the supported Core subset.

    This module is deliberately narrow: OCaml projects a supported
    Core subset to JSON, then Blorp owns the final tail and C artifact emission
    through explicit bridge actions. Unsupported Core shapes are rejected before
    the bridge call so the subset boundary remains explicit. *)

type unsupported = { path : string; reason : string }

module IntSet = Set.Make (Int)
module StringSet = Set.Make (String)
module StringMap = Map.Make (String)

let ( let* ) result f =
  match result with Ok value -> f value | Error _ as error -> error

let unsupported path reason = Error { path; reason }

let unsupported_to_string error =
  Printf.sprintf "unsupported Blorp C backend Core subset at %s: %s" error.path
    error.reason

let truncate_diagnostic max_len text =
  if String.length text <= max_len then text
  else String.sub text 0 max_len ^ "..."

let rec compact_callee_label (callee : Core.core) =
  let label =
    match callee.desc with
    | Core.CVar variable -> Core.Var.to_string variable
    | Core.CField (receiver, field) ->
        compact_callee_label receiver ^ "." ^ field
    | Core.CCall (_call_kind, inner, _args) ->
        "call(" ^ compact_callee_label inner ^ ")"
    | _ -> Core.pp_to_string callee
  in
  truncate_diagnostic 180 label

let obj fields = Lsp_json.Object fields
let arr values = Lsp_json.Array values
let str value = Lsp_json.String value
let int value = Lsp_json.Int value
let bool value = Lsp_json.Bool value
let null = Lsp_json.Null
let kind tag fields = obj (("kind", str tag) :: fields)
let option_int_json = function Some value -> int value | None -> null
let option_string_json = function Some value -> str value | None -> null
let int_list_json values = arr (List.map int values)
let string_list_json values = arr (List.map str values)

let supported_sized_integer_conversion_builtins =
  StringSet.of_list
    [
      "blorp_to_int8";
      "blorp_to_int16";
      "blorp_to_int32";
      "blorp_to_int128";
      "blorp_to_uint8";
      "blorp_to_uint16";
      "blorp_to_uint32";
      "blorp_to_uint64";
      "blorp_to_uint128";
    ]

(* These calls may cross the pre-DCE boundary in semantic form. The Blorp-owned
   specialize stage dispatches them from concrete Core types before ownership
   analysis and C emission. Numeric tensor fill names are candidates only:
   [blorp_specialization_crosses_boundary] keeps boxed fill layouts on their
   established direct-runtime ABI. Receiver-typed unary tensor math is handled
   by [call_kind_json_for_call], where the argument type is available. Keep
   this set separate from
   [direct_builtin_supported], which cannot preserve that distinction. *)
let blorp_specialization_builtins =
  StringSet.of_list
    [
      "blorp_checked_get";
      "blorp_checked_get_f32";
      "blorp_checked_get_f64";
      "blorp_checked_set";
      "blorp_hash";
      "blorp_length";
      "blorp_matrix_checked_get";
      "blorp_matrix_checked_set";
      "blorp_matrix_new_fill";
      "blorp_tensor3_checked_get";
      "blorp_tensor4_checked_get";
      "blorp_tensor5_checked_get";
      "blorp_to_bool";
      "blorp_to_char";
      "blorp_to_float";
      "blorp_to_float16";
      "blorp_to_float32";
      "blorp_to_int";
      "blorp_vector_len";
      "blorp_vector_new_fill";
      "blorp_vector_set_inplace_f32";
      "blorp_vector_set_inplace_f64";
      "blorp_vector_set_inplace_i64";
    ]

let blorp_specialization_builtin_supported name =
  StringSet.mem name blorp_specialization_builtins

let blorp_numeric_tensor_fill_builtin = function
  | "blorp_vector_new_fill" | "blorp_matrix_new_fill" -> true
  | _ -> false

let blorp_tensor_parts ~reg ty =
  Codegen_types.expand_alias ~reg ty
  |> Codegen_types.normalize_type |> Types.array_parts

let blorp_tensor_element_name ~reg ty =
  match blorp_tensor_parts ~reg ty with
  | Some (elem_ty, _dims) -> (
      match
        Codegen_types.expand_alias ~reg elem_ty |> Codegen_types.normalize_type
      with
      | Ast.TyNamed (name, []) -> Some name
      | _ -> None)
  | None -> None

let blorp_numeric_tensor_fill_result ~reg ty =
  match blorp_tensor_element_name ~reg ty with
  | Some ("Int" | "Float" | "Float32") -> true
  | _ -> false

let blorp_specialization_crosses_boundary ~reg name result_ty =
  if blorp_numeric_tensor_fill_builtin name then
    blorp_numeric_tensor_fill_result ~reg result_ty
  else blorp_specialization_builtin_supported name

let blorp_unary_tensor_math_builtin = function
  | "blorp_vector_norm" | "blorp_vector_sqrt" | "blorp_vector_exp"
  | "blorp_vector_log" ->
      true
  | _ -> false

let blorp_unary_tensor_math_receiver ~reg ty =
  match blorp_tensor_element_name ~reg ty with
  | Some ("Float" | "Float32" | "Float16") -> true
  | _ -> false

let blorp_tensor_reduction_builtin = function
  | "blorp_max" | "blorp_min" -> true
  | _ -> false

let blorp_receiver_specialization_builtin name =
  blorp_unary_tensor_math_builtin name || blorp_tensor_reduction_builtin name

let blorp_tensor_reduction_receiver ~reg ty =
  match blorp_tensor_element_name ~reg ty with
  | Some ("Int" | "Float" | "Float32" | "Float16") -> true
  | _ -> false

let blorp_receiver_specialization_crosses_boundary ~reg name receiver_ty =
  (blorp_unary_tensor_math_builtin name
  && blorp_unary_tensor_math_receiver ~reg receiver_ty)
  || (blorp_tensor_reduction_builtin name
     && blorp_tensor_reduction_receiver ~reg receiver_ty)

let blorp_specialization_builtin_arity = function
  | "blorp_checked_get" | "blorp_checked_get_f32" | "blorp_checked_get_f64" ->
      2
  | "blorp_vector_new_fill" -> 2
  | "blorp_matrix_checked_get" | "blorp_checked_set"
  | "blorp_matrix_new_fill" ->
      3
  | "blorp_tensor3_checked_get" | "blorp_matrix_checked_set" -> 4
  | "blorp_tensor4_checked_get" -> 5
  | "blorp_tensor5_checked_get" -> 6
  | "blorp_vector_set_inplace_f32" | "blorp_vector_set_inplace_f64"
  | "blorp_vector_set_inplace_i64" ->
      3
  | _ -> 1

let supported_math_passthrough_builtins =
  StringSet.of_list
    [
      "acos";
      "acosh";
      "asin";
      "asinh";
      "atan";
      "atan2";
      "atanh";
      "cbrt";
      "ceil";
      "copysign";
      "cos";
      "cosh";
      "exp";
      "exp2";
      "expm1";
      "floor";
      "fma";
      "fmod";
      "hypot";
      "log";
      "log1p";
      "log2";
      "log10";
      "pow";
      "sin";
      "sinh";
      "sqrt";
      "tan";
      "tanh";
      "trunc";
    ]

let supported_string_runtime_builtins =
  StringSet.of_list [ "blorp_string_concat_consume"; "blorp_string_concat_many" ]

let supported_channel_attempt_builtins =
  StringSet.of_list
    [
      "blorp_channel_try_send_attempt";
      "blorp_channel_send_timeout_attempt";
      "blorp_channel_try_recv_attempt";
      "blorp_channel_recv_timeout_attempt";
    ]

let supported_tensor_runtime_builtins =
  StringSet.of_list
    [
      "blorp_assert_shape_nullable";
      "blorp_tensor_add_scaled_f32_cow";
      "blorp_tensor_add_scaled_f64_cow";
      "blorp_tensor_matrix_multiply_float";
      "blorp_tensor_matrix_multiply_float16";
      "blorp_tensor_matrix_multiply_float32";
      "blorp_tensor_matrix_multiply_int";
      "blorp_tensor_matrix_vector_multiply_float";
      "blorp_tensor_matrix_vector_multiply_float16";
      "blorp_tensor_matrix_vector_multiply_float32";
      "blorp_tensor_matrix_vector_multiply_int";
      "blorp_tensor_outer_float";
      "blorp_tensor_outer_float16";
      "blorp_tensor_outer_float32";
      "blorp_tensor_outer_int";
      "blorp_tensor_transpose";
      "blorp_tensor_transposed_matrix_vector_multiply_float";
      "blorp_tensor_transposed_matrix_vector_multiply_float16";
      "blorp_tensor_transposed_matrix_vector_multiply_float32";
      "blorp_tensor_transposed_matrix_vector_multiply_int";
      "blorp_vector_new";
      "blorp_vector_new_f32";
      "blorp_vector_new_f64";
      "blorp_vector_new_i64";
      "blorp_vector_op";
      "blorp_simd_vector_add_f32";
      "blorp_simd_vector_add_f64";
      "blorp_simd_vector_div_f32";
      "blorp_simd_vector_div_f64";
      "blorp_simd_vector_mul_f32";
      "blorp_simd_vector_mul_f64";
      "blorp_simd_vector_sub_f32";
      "blorp_simd_vector_sub_f64";
      "blorp_matrix_map";
      "blorp_matrix_map_indexed";
      "blorp_matrix_zip_map";
      "blorp_mmap_flat_indexed_parallel";
      "blorp_mmap_indexed_parallel";
      "blorp_mmap_parallel";
      "blorp_mzip_indexed_parallel";
      "blorp_mzip_parallel";
      "blorp_vector_add_i64";
      "blorp_vector_cross_float";
      "blorp_vector_div_i64";
      "blorp_vector_map";
      "blorp_vector_mod_i64";
      "blorp_vector_mul_i64";
      "blorp_vector_scalar_add_f32";
      "blorp_vector_scalar_add_f64";
      "blorp_vector_scalar_add_i64";
      "blorp_vector_scalar_div_f32";
      "blorp_vector_scalar_div_f64";
      "blorp_vector_scalar_div_i64";
      "blorp_vector_scalar_mod_i64";
      "blorp_vector_scalar_mul_f32";
      "blorp_vector_scalar_mul_f64";
      "blorp_vector_scalar_mul_i64";
      "blorp_vector_scalar_op_rev_float";
      "blorp_vector_scalar_op_rev_int";
      "blorp_vector_scalar_op_float16";
      "blorp_vector_scalar_op_rev_float16";
      "blorp_vector_scalar_op_rev_float32";
      "blorp_vector_scalar_rev_div_f32";
      "blorp_vector_scalar_rev_div_f64";
      "blorp_vector_scalar_rev_div_i64";
      "blorp_vector_scalar_rev_mod_i64";
      "blorp_vector_scalar_rev_sub_f32";
      "blorp_vector_scalar_rev_sub_f64";
      "blorp_vector_scalar_rev_sub_i64";
      "blorp_vector_scalar_sub_f32";
      "blorp_vector_scalar_sub_f64";
      "blorp_vector_scalar_sub_i64";
      "blorp_vector_sub_i64";
      "blorp_vector_zip";
      "blorp_vmap_parallel";
      "blorp_vmap_indexed_parallel";
      "blorp_vzip_parallel";
    ]

let supported_raw_tensor_fill_builtins =
  StringSet.of_list
    [
      "blorp_matrix_new_fill_f32";
      "blorp_matrix_new_fill_f64";
      "blorp_matrix_new_fill_i64";
      "blorp_matrix_new_fill_packed";
      "blorp_matrix_new_fill";
      "blorp_vector_new_fill";
      "blorp_vector_new_fill_f32";
      "blorp_vector_new_fill_f64";
      "blorp_vector_new_fill_i64";
      "blorp_vector_new_fill_packed";
    ]

let is_ranked_tensor_fill_factory_name = function
  | "blorp_tensor3_new" | "blorp_tensor4_new" | "blorp_tensor5_new" -> true
  | _ -> false

let supported_raw_tensor_access_builtins =
  StringSet.of_list
    [
      "blorp_checked_get";
      "blorp_checked_get_f32";
      "blorp_checked_get_f64";
      "blorp_checked_slice";
      "blorp_checked_set";
      "blorp_matrix_checked_set";
      "blorp_matrix_checked_set_f32";
      "blorp_matrix_checked_set_f64";
      "blorp_matrix_checked_set_i64";
      "blorp_matrix_checked_get";
      "blorp_matrix_checked_get_f32";
      "blorp_matrix_checked_get_f64";
      "blorp_tensor3_checked_get";
      "blorp_tensor4_checked_get";
      "blorp_tensor5_checked_get";
      "blorp_tensor3_checked_get_shape";
      "blorp_tensor4_checked_get_shape";
      "blorp_tensor5_checked_get_shape";
      "blorp_tensor3_checked_get_shape_f64";
      "blorp_tensor4_checked_get_shape_f64";
      "blorp_tensor5_checked_get_shape_f64";
      "blorp_tensor3_checked_get_shape_f32";
      "blorp_tensor4_checked_get_shape_f32";
      "blorp_tensor5_checked_get_shape_f32";
      "blorp_matrix_set_opt_i64";
      "blorp_matrix_set_opt_nullable_i64";
      "blorp_matrix_get_opt";
      "blorp_matrix_get_opt_bool";
      "blorp_matrix_get_opt_char";
      "blorp_matrix_get_opt_f16";
      "blorp_matrix_get_opt_f32";
      "blorp_matrix_get_opt_float";
      "blorp_matrix_get_opt_int";
      "blorp_matrix_get_opt_int16";
      "blorp_matrix_get_opt_int32";
      "blorp_matrix_get_opt_int64";
      "blorp_matrix_get_opt_int8";
      "blorp_matrix_get_opt_uint16";
      "blorp_matrix_get_opt_uint32";
      "blorp_matrix_get_opt_uint64";
      "blorp_matrix_get_opt_uint8";
      "blorp_vector_get_opt_bool";
      "blorp_vector_get_opt_char";
      "blorp_vector_get_opt_f16";
      "blorp_vector_get_opt_f32";
      "blorp_vector_get_opt_float";
      "blorp_vector_get_opt_int";
      "blorp_vector_get_opt_int16";
      "blorp_vector_get_opt_int32";
      "blorp_vector_get_opt_int64";
      "blorp_vector_get_opt_int8";
      "blorp_vector_get_opt_uint16";
      "blorp_vector_get_opt_uint32";
      "blorp_vector_get_opt_uint64";
      "blorp_vector_get_opt_uint8";
      "blorp_vector_get_opt";
      "blorp_vector_eq";
      "blorp_vector_abs";
      "blorp_vector_exp";
      "blorp_vector_exp_float16";
      "blorp_vector_exp_float32";
      "blorp_vector_log";
      "blorp_vector_log_float16";
      "blorp_vector_log_float32";
      "blorp_vector_max_float";
      "blorp_vector_max_float16";
      "blorp_vector_max_float32";
      "blorp_vector_max_int";
      "blorp_vector_min_float";
      "blorp_vector_min_float16";
      "blorp_vector_min_float32";
      "blorp_vector_min_int";
      "blorp_vector_norm";
      "blorp_vector_norm_float16";
      "blorp_vector_norm_float32";
      "blorp_vector_sqrt";
      "blorp_vector_sqrt_float16";
      "blorp_vector_sqrt_float32";
      "blorp_tensor_slice_row";
      "blorp_vector_to_string_bool";
      "blorp_vector_to_string_float";
      "blorp_vector_to_string_float16";
      "blorp_vector_to_string_float32";
      "blorp_vector_to_string_int";
      "blorp_vector_set_cow_f32";
      "blorp_vector_set_cow_i64";
      "blorp_vector_set_cow_nullable";
      "blorp_vector_set_cow_nullable_f32";
      "blorp_vector_set_cow_nullable_i64";
      "blorp_vector_set_inplace_f16";
      "blorp_vector_set_inplace_f32";
      "blorp_vector_set_inplace_f64";
      "blorp_vector_set_inplace_i64";
      "blorp_vector_set_inplace_packed";
    ]

let supported_primitive_runtime_builtins =
  StringSet.of_list
    [
      "blorp_black_box_float";
      "blorp_black_box_int";
      "blorp_base64_decode";
      "blorp_base64_decode_nullable";
      "blorp_base64_encode";
      "blorp_bytes_from_hex";
      "blorp_bytes_from_hex_nullable";
      "blorp_bytes_from_string";
      "blorp_bytes_to_string";
      "blorp_bool_to_string";
      "blorp_channel_new";
      "blorp_channel_recv";
      "blorp_channel_recv_bool";
      "blorp_channel_recv_char";
      "blorp_channel_recv_f32";
      "blorp_channel_recv_float";
      "blorp_channel_recv_int";
      "blorp_channel_recv_int16";
      "blorp_channel_recv_int32";
      "blorp_channel_recv_int64";
      "blorp_channel_recv_int8";
      "blorp_channel_recv_nullable";
      "blorp_channel_recv_timeout";
      "blorp_channel_recv_timeout_bool";
      "blorp_channel_recv_timeout_char";
      "blorp_channel_recv_timeout_f32";
      "blorp_channel_recv_timeout_float";
      "blorp_channel_recv_timeout_int";
      "blorp_channel_recv_timeout_int16";
      "blorp_channel_recv_timeout_int32";
      "blorp_channel_recv_timeout_int64";
      "blorp_channel_recv_timeout_int8";
      "blorp_channel_recv_timeout_nullable";
      "blorp_channel_recv_timeout_uint16";
      "blorp_channel_recv_timeout_uint32";
      "blorp_channel_recv_timeout_uint64";
      "blorp_channel_recv_timeout_uint8";
      "blorp_channel_recv_uint16";
      "blorp_channel_recv_uint32";
      "blorp_channel_recv_uint64";
      "blorp_channel_recv_uint8";
      "blorp_channel_send";
      "blorp_channel_send_timeout";
      "blorp_channel_send_timeout_status";
      "blorp_channel_seal";
      "blorp_channel_try_recv";
      "blorp_channel_try_recv_bool";
      "blorp_channel_try_recv_char";
      "blorp_channel_try_recv_f32";
      "blorp_channel_try_recv_float";
      "blorp_channel_try_recv_int";
      "blorp_channel_try_recv_int16";
      "blorp_channel_try_recv_int32";
      "blorp_channel_try_recv_int64";
      "blorp_channel_try_recv_int8";
      "blorp_channel_try_recv_nullable";
      "blorp_channel_try_recv_uint16";
      "blorp_channel_try_recv_uint32";
      "blorp_channel_try_recv_uint64";
      "blorp_channel_try_recv_uint8";
      "blorp_channel_try_send";
      "blorp_channel_try_send_status";
      "blorp_codepoint_length";
      "blorp_codepoint_reverse";
      "blorp_crypto_random_bytes";
      "blorp_dict_get_nullable";
      "blorp_dict_get_int";
      "blorp_dict_get_int8";
      "blorp_dict_get_int16";
      "blorp_dict_get_int32";
      "blorp_dict_get_int64";
      "blorp_dict_get_uint8";
      "blorp_dict_get_uint16";
      "blorp_dict_get_uint32";
      "blorp_dict_get_uint64";
      "blorp_dict_get_float";
      "blorp_dict_get_f32";
      "blorp_dict_get_f16";
      "blorp_dict_get_bool";
      "blorp_dict_get_char";
      "blorp_dict_new";
      "blorp_dict_new_float";
      "blorp_dict_new_string";
      "blorp_dict_with_capacity";
      "blorp_dict_with_capacity_float";
      "blorp_dict_with_capacity_string";
      "blorp_dict_remove";
      "blorp_dir_close";
      "blorp_directory_path";
      "blorp_decode_utf8";
      "blorp_decode_utf8_nullable";
      "blorp_debug_error";
      "blorp_debug_info";
      "blorp_debug_log_msg";
      "blorp_debug_warn";
      "blorp_encode_utf8";
      "blorp_exec";
      "blorp_exec_output";
      "blorp_append_file";
      "blorp_file_close_appender";
      "blorp_file_close_read_appender";
      "blorp_file_close_read_writer";
      "blorp_file_close_reader";
      "blorp_file_close_writer";
      "blorp_file_create_directories_raw";
      "blorp_file_remove_directory_tree_raw";
      "blorp_file_rename_path_raw";
      "blorp_file_writer_path";
      "blorp_file_write_text_atomic_raw";
      "blorp_file_exists";
      "blorp_file_modified";
      "blorp_file_size";
      "blorp_for_each_chunk";
      "blorp_for_each_line";
      "blorp_fixed_new";
      "blorp_float16_to_string";
      "blorp_float32_to_string";
      "blorp_float_to_string";
      "blorp_filter_parallel";
      "blorp_filter_parallel_with";
      "blorp_format_float";
      "blorp_fixed_add";
      "blorp_fixed_div";
      "blorp_fixed_eq";
      "blorp_fixed_from_int";
      "blorp_fixed_ge";
      "blorp_fixed_gt";
      "blorp_fixed_le";
      "blorp_fixed_lt";
      "blorp_fixed_mul";
      "blorp_fixed_raw";
      "blorp_fixed_sub";
      "blorp_fixed_to_float";
      "blorp_fixed_to_string";
      "blorp_from_char";
      "blorp_from_chars";
      "blorp_get_mem_stats";
      "blorp_get_scheduler_stats";
      "blorp_getcwd";
      "blorp_compiler_runtime_source";
      "blorp_compiler_runtime_decl";
      "blorp_getenv";
      "blorp_getenv_nullable";
      "blorp_crc32";
      "blorp_crc32_bytes";
      "blorp_hash_bytes";
      "blorp_hash_combine";
      "blorp_hash_float";
      "blorp_hash_int";
      "blorp_hash_string";
      "blorp_hmac_sha256";
      "blorp_html_escape";
      "blorp_input";
      "blorp_input_or_empty";
      "blorp_is_unique";
      "blorp_is_directory";
      "blorp_is_finite";
      "blorp_is_inf";
      "blorp_is_nan";
      "blorp_list_to_string_bool";
      "blorp_list_to_string_float";
      "blorp_list_to_string_int";
      "blorp_list_to_string_string";
      "blorp_lower";
      "blorp_max_threads";
      "blorp_matrix_get_nullable";
      "blorp_mkdir";
      "blorp_mkstemp_path";
      "blorp_now_us";
      "blorp_option_div_int";
      "blorp_option_mod_int";
      "blorp_parse_float";
      "blorp_parse_int";
      "blorp_print";
      "blorp_print_error";
      "blorp_print_live_object_summary";
      "blorp_process_run";
      "blorp_process_run_command_raw";
      "blorp_process_run_inherit";
      "blorp_process_shell";
      "blorp_puts";
      "blorp_refcount";
      "blorp_read_all_lines";
      "blorp_read_all";
      "blorp_read_bytes";
      "blorp_read_file";
      "blorp_read_line";
      "blorp_read_line_or_empty";
      "blorp_random_float";
      "blorp_random_int";
      "blorp_regex_find";
      "blorp_regex_find_all";
      "blorp_regex_replace_all";
      "blorp_regex_test";
      "blorp_remove_dir";
      "blorp_remove_file";
      "blorp_rename";
      "blorp_reset_mem_stats";
      "blorp_reset_scheduler_stats";
      "blorp_round";
      "blorp_set_add";
      "blorp_set_new";
      "blorp_set_new_float";
      "blorp_set_new_string";
      "blorp_set_remove";
      "blorp_seed_random";
      "blorp_setenv";
      "blorp_md5";
      "blorp_md5_bytes";
      "blorp_sha1";
      "blorp_sha1_bytes";
      "blorp_sha256";
      "blorp_sha256_bytes";
      "blorp_sha512";
      "blorp_sha512_bytes";
      "blorp_signal_hangup";
      "blorp_signal_interrupt";
      "blorp_signal_on";
      "blorp_signal_received";
      "blorp_signal_raise";
      "blorp_signal_terminate";
      "blorp_signal_user1";
      "blorp_signal_user2";
      "blorp_size_of";
      "blorp_sleep";
      "blorp_string_append";
      "blorp_string_append_int";
      "blorp_string_chars";
      "blorp_string_codepoints";
      "blorp_string_get_opt";
      "blorp_string_lcs";
      "blorp_string_levenshtein";
      "blorp_stream_all";
      "blorp_stream_any";
      "blorp_stream_collect";
      "blorp_stream_count";
      "blorp_stream_drop";
      "blorp_stream_empty";
      "blorp_stream_filter";
      "blorp_stream_filter_map";
      "blorp_stream_filter_map_bool";
      "blorp_stream_filter_map_char";
      "blorp_stream_filter_map_f32";
      "blorp_stream_filter_map_float";
      "blorp_stream_filter_map_int";
      "blorp_stream_filter_map_int16";
      "blorp_stream_filter_map_int32";
      "blorp_stream_filter_map_int64";
      "blorp_stream_filter_map_int8";
      "blorp_stream_filter_map_nullable";
      "blorp_stream_filter_map_uint16";
      "blorp_stream_filter_map_uint32";
      "blorp_stream_filter_map_uint64";
      "blorp_stream_filter_map_uint8";
      "blorp_stream_fold";
      "blorp_stream_for_each";
      "blorp_stream_from_list";
      "blorp_stream_from_range";
      "blorp_stream_enumerate";
      "blorp_stream_find";
      "blorp_stream_find_int";
      "blorp_stream_find_int8";
      "blorp_stream_find_int16";
      "blorp_stream_find_int32";
      "blorp_stream_find_int64";
      "blorp_stream_find_uint8";
      "blorp_stream_find_uint16";
      "blorp_stream_find_uint32";
      "blorp_stream_find_uint64";
      "blorp_stream_find_float";
      "blorp_stream_find_bool";
      "blorp_stream_find_char";
      "blorp_stream_find_f32";
      "blorp_stream_find_f16";
      "blorp_stream_find_nullable";
      "blorp_stream_map";
      "blorp_stream_repeat";
      "blorp_stream_take";
      "blorp_stream_take_while";
      "blorp_stream_unfold";
      "blorp_test_cancel_after_parked";
      "blorp_test_cooperative_checkpoint_probe";
      "blorp_test_current_timer_wait_install_probe";
      "blorp_test_fiber_cancel_before_park_probe";
      "blorp_test_fiber_created_schedule_probe";
      "blorp_test_fiber_lifecycle_ready_to_park_probe";
      "blorp_test_task_join_slot_probe";
      "blorp_test_task_window_pending_cleanup_probe";
      "blorp_test_timeout_arithmetic_probe";
      "blorp_test_timer_waiter_identity_probe";
      "blorp_test_tls_state_probe";
      "blorp_test_wait_ready_to_park_probe";
      "blorp_test_websocket_state_probe";
      "blorp_temporary_directory_open_raw";
      "blorp_temporary_file_open_raw";
      "blorp_string_concat";
      "blorp_string_eq";
      "blorp_vector_get_nullable";
      "blorp_tls_close_session";
      "blorp_tls_native_available_raw";
      "blorp_tcp_close_listener";
      "blorp_tcp_close_stream";
      "blorp_tcp_connections_continue_on_error_raw";
      "blorp_tcp_connections_stop_on_error_raw";
      "blorp_tcp_dns_name_raw";
      "blorp_tcp_dns_name_text_raw";
      "blorp_tcp_ipv4_raw";
      "blorp_tcp_interface_scope_raw";
      "blorp_tcp_interface_scope_text_raw";
      "blorp_tcp_ip_text_raw";
      "blorp_tcp_parse_ip_raw";
      "blorp_tcp_port_raw";
      "blorp_tcp_port_value_raw";
      "blorp_time_format";
      "blorp_time_from_iso";
      "blorp_time_from_parts";
      "blorp_time_now";
      "blorp_time_parse";
      "blorp_time_parse_rfc3339";
      "blorp_time_to_day";
      "blorp_time_to_hour";
      "blorp_time_to_minute";
      "blorp_time_to_month";
      "blorp_time_to_second";
      "blorp_time_to_weekday";
      "blorp_time_to_year";
      "blorp_to_float";
      "blorp_to_string";
      "blorp_temp_dir";
      "blorp_upper";
      "blorp_udp_close_socket";
      "blorp_url_decode";
      "blorp_url_encode";
      "blorp_websocket_close_session";
      "blorp_websocket_native_available_raw";
      "blorp_write_bytes";
      "blorp_write_file";
      "blorp_yield_now";
    ]

let sized_integer_conversion_builtin_supported name =
  StringSet.mem name supported_sized_integer_conversion_builtins

let list_parallel_runtime_builtin_supported name =
  match name with
  | "blorp_filter_parallel" | "blorp_filter_parallel_with"
  | "blorp_map_parallel" | "blorp_map_parallel_with" | "blorp_zip_parallel"
  | "blorp_zip_parallel_with" ->
      true
  | _ -> String.starts_with ~prefix:"blorp_filter_map_parallel" name

type direct_runtime_args_policy =
  | DirectRuntimeArgsAsWritten
  | DirectRuntimeArgsAppendListParallelLayout of {
      semantic_arity : int;
      runtime_arity : int;
      storage_mode : string;
      elem_size : string;
      value_encoding : string;
    }

type direct_runtime_result_policy =
  | DirectRuntimeResultAsWritten
  | DirectRuntimeResultCast of string
  | DirectRuntimeResultStackResultFromBoxed

type direct_runtime_abi = {
  direct_runtime_name : string;
  direct_runtime_args : direct_runtime_args_policy;
  direct_runtime_result : direct_runtime_result_policy;
}

let direct_runtime_args_policy_json = function
  | DirectRuntimeArgsAsWritten -> kind "as_written" []
  | DirectRuntimeArgsAppendListParallelLayout
      { semantic_arity; runtime_arity; storage_mode; elem_size; value_encoding }
    ->
      kind "list_parallel_layout"
        [
          ("semantic_arity", int semantic_arity);
          ("runtime_arity", int runtime_arity);
          ("storage_mode", str storage_mode);
          ("elem_size", str elem_size);
          ("value_encoding", str value_encoding);
        ]

let direct_runtime_result_policy_json = function
  | DirectRuntimeResultAsWritten -> kind "as_written" []
  | DirectRuntimeResultCast c_type -> kind "cast" [ ("c_type", str c_type) ]
  | DirectRuntimeResultStackResultFromBoxed ->
      kind "stack_result_from_boxed" []

let direct_runtime_call_kind_json abi =
  kind "direct_runtime"
    [
      ( "call",
        obj
          [
            ("name", str abi.direct_runtime_name);
            ("args", direct_runtime_args_policy_json abi.direct_runtime_args);
            ( "result",
              direct_runtime_result_policy_json abi.direct_runtime_result );
          ] );
    ]

let list_callback_result_encoding_arg (layout : Core.list_storage_layout) :
    string =
  match layout.Core.lsl_value_layout with
  | Core.ListElementStackStruct _ -> "BLORP_LIST_CALLBACK_BOXED_STRUCT"
  | Core.ListElementPointer | Core.ListElementInlineBits _
  | Core.ListElementBoxedValue | Core.ListElementUnknownValue _ ->
      "BLORP_LIST_CALLBACK_BITS"

let list_parallel_runtime_layout_args ~reg ~result_ty ~loc =
  let layout = Core_layout_type.list_storage_layout_of_type ~reg result_ty loc in
  let storage_mode, elem_size =
    Core_emit_layout.list_runtime_storage_args layout
  in
  (storage_mode, elem_size, list_callback_result_encoding_arg layout)

let list_parallel_runtime_args_policy ~reg ~result_ty ~loc name =
  let make semantic_arity runtime_arity =
    let storage_mode, elem_size, value_encoding =
      list_parallel_runtime_layout_args ~reg ~result_ty ~loc
    in
    DirectRuntimeArgsAppendListParallelLayout
      { semantic_arity; runtime_arity; storage_mode; elem_size; value_encoding }
  in
  match name with
  | "blorp_map_parallel" -> Some (make 3 6)
  | "blorp_zip_parallel" -> Some (make 4 7)
  | "blorp_map_parallel_with" -> Some (make 4 7)
  | "blorp_zip_parallel_with" -> Some (make 5 8)
  | _ when String.starts_with ~prefix:"blorp_filter_map_parallel" name ->
      Some (make 3 6)
  | _ -> None

let list_parallel_runtime_result_cast_supported name =
  list_parallel_runtime_builtin_supported name

let direct_runtime_result_policy ~reg result_ty name =
  if Core_layout_type.is_stack_result_type ~reg result_ty then
    DirectRuntimeResultStackResultFromBoxed
  else if list_parallel_runtime_result_cast_supported name then
    DirectRuntimeResultCast "blorp_List*"
  else
    match name with
    | "blorp_tensor_add_scaled_f64_cow" | "blorp_tensor_add_scaled_f32_cow" ->
        DirectRuntimeResultCast "blorp_Vector*"
    | _ -> DirectRuntimeResultAsWritten

let tensor_parallel_runtime_builtin_supported = function
  | "blorp_matrix_map" | "blorp_matrix_map_indexed" | "blorp_matrix_zip_map"
  | "blorp_mmap_flat_indexed_parallel" | "blorp_mmap_indexed_parallel"
  | "blorp_mmap_parallel" | "blorp_mzip_indexed_parallel"
  | "blorp_mzip_parallel" | "blorp_vmap_parallel"
  | "blorp_vmap_indexed_parallel" | "blorp_vzip_parallel" ->
      true
  | _ -> false

let primitive_runtime_builtin_supported name =
  StringSet.mem name supported_primitive_runtime_builtins

let generated_enum_vector_to_string_builtin_supported name =
  String.starts_with ~prefix:"blorp_vector_to_string_" name

let direct_builtin_supported name =
  sized_integer_conversion_builtin_supported name
  || StringSet.mem name supported_math_passthrough_builtins
  || StringSet.mem name supported_string_runtime_builtins
  || StringSet.mem name supported_tensor_runtime_builtins
  || StringSet.mem name supported_raw_tensor_fill_builtins
  || StringSet.mem name supported_raw_tensor_access_builtins
  || list_parallel_runtime_builtin_supported name
  || generated_enum_vector_to_string_builtin_supported name
  || primitive_runtime_builtin_supported name
  || Option.is_some (Operation_result_metadata.find_fallible_stream_source name)

let direct_runtime_abi ~reg ~loc result_ty name =
  if not (direct_builtin_supported name) then None
  else
    Some
      {
        direct_runtime_name = name;
        direct_runtime_args =
          (match list_parallel_runtime_args_policy ~reg ~result_ty ~loc name with
          | Some policy -> policy
          | None -> DirectRuntimeArgsAsWritten);
        direct_runtime_result =
          direct_runtime_result_policy ~reg result_ty name;
      }

let channel_attempt_builtin_supported name =
  StringSet.mem name supported_channel_attempt_builtins

let channel_attempt_builtin_arity = function
  | "blorp_channel_try_send_attempt" -> Some 2
  | "blorp_channel_send_timeout_attempt" -> Some 3
  | "blorp_channel_try_recv_attempt" -> Some 1
  | "blorp_channel_recv_timeout_attempt" -> Some 2
  | _ -> None

let channel_semantic_builtin_supported = function
  | "blorp_channel_new" | "blorp_channel_send" | "blorp_channel_try_send"
  | "blorp_channel_try_send_status" | "blorp_channel_send_timeout"
  | "blorp_channel_send_timeout_status" ->
      true
  | name -> channel_attempt_builtin_supported name

let release_policy_json ~reg ty =
  str (Core_emit_layout.release_policy_tag ~reg ty)

let trait_method_c_name_for_type path trait_name method_name ty =
  match Codegen_types.type_key_for_impl ty with
  | Some type_name ->
      Ok (Printf.sprintf "%s_%s_%s" trait_name method_name type_name)
  | None ->
      unsupported path
        (Printf.sprintf "trait method %s.%s for type %s" trait_name
           method_name (Types.type_to_string ty))

let custom_hash_container_constructor_json ~reg path loc key_ty =
  let* hash_fn =
    trait_method_c_name_for_type (path ^ ".hash_fn") "Hashable" "hash" key_ty
  in
  let* equals_fn =
    trait_method_c_name_for_type (path ^ ".equals_fn") "Equatable" "equals"
      key_ty
  in
  Ok
    (kind "custom"
       [
         ("hash_fn", str hash_fn);
         ("equals_fn", str equals_fn);
         ( "elem_needs_release",
           bool
             (Core_emit_layout.boxed_storage_needs_release ~reg key_ty loc)
         );
       ])

let union_payload_storage_json storage =
  match storage with
  | Codegen_types.TypedUnionPayloadStorage -> str "typed"
  | Codegen_types.ErasedUnionPayloadStorage -> str "erased"

let union_payload_storage_json_for_type ~reg type_name =
  union_payload_storage_json (Codegen_types.union_payload_storage reg type_name)

let union_field_release_policy_json ~reg payload_storage field_ty loc =
  str
    (Core_emit_layout.union_field_release_policy_tag ~reg payload_storage
       field_ty loc)

let retain_policy_json ~reg ty =
  str (Core_emit_layout.retain_policy_tag ~reg ty)

let result_list values f =
  let rec collect acc index = function
    | [] -> Ok (arr (List.rev acc))
    | value :: rest -> (
        match f index value with
        | Ok json -> collect (json :: acc) (index + 1) rest
        | Error _ as error -> error)
  in
  collect [] 0 values

let source_loc_json (loc : Ast.loc) =
  match loc.loc_file with
  | Some file ->
      kind "known"
        [
          ("file", str file);
          ("line", int loc.line);
          ("column", int loc.column);
          ("end_line", int loc.end_line);
          ("end_column", int loc.end_column);
        ]
  | None -> kind "synthetic" []

let var_json (variable : Core.var) =
  obj
    [
      ("name", str (Core.Var.to_c_name variable));
      ("uniq", int variable.vuniq);
      ("def_id", option_int_json variable.vdef_id);
    ]

let enum_constructor_key type_name constructor_name =
  type_name ^ "\000" ^ constructor_name

let constructor_c_name_for_type ~reg constructor_symbols ty (variable : Core.var) =
  match Core_emit_layout.canonical_type ~reg ty with
  | Ast.TyNamed (type_name, _) ->
      StringMap.find_opt
        (enum_constructor_key type_name variable.vname)
        constructor_symbols
  | _ -> None

let is_option_none_constructor ~reg ty (variable : Core.var) =
  match Core_emit_layout.canonical_type ~reg ty with
  | Ast.TyNamed ("Option", [ _ ]) when String.equal variable.vname "None" ->
      true
  | _ -> false

let is_stack_option_none_constructor ~reg ty variable =
  is_option_none_constructor ~reg ty variable
  && Core_layout_type.is_stack_option_type ~reg ty

let is_singleton_constructor_value ~reg constructor_symbols ty variable =
  if is_option_none_constructor ~reg ty variable then true
  else
    match constructor_c_name_for_type ~reg constructor_symbols ty variable with
    | Some _ -> true
    | None -> false

let retain_policy_json_for_var ~reg constructor_symbols ty variable =
  if is_singleton_constructor_value ~reg constructor_symbols ty variable then str "none"
  else retain_policy_json ~reg ty

let release_policy_json_for_var ~reg constructor_symbols ty variable =
  if is_singleton_constructor_value ~reg constructor_symbols ty variable then str "none"
  else release_policy_json ~reg ty

let nullable_option_constructor_c_name ~reg ty (variable : Core.var) =
  match Core_emit_layout.canonical_type ~reg ty with
  | Ast.TyNamed ("Option", [ _ ])
    when Core_layout_type.is_nullable_managed_option ~reg ty
         && String.equal variable.vname "None" ->
      Some "NULL"
  | _ -> None

let var_json_for_expr ~reg constructor_symbols ty (variable : Core.var) =
  let name =
    if is_stack_option_none_constructor ~reg ty variable then
      Core.Var.to_c_name variable
    else
      match nullable_option_constructor_c_name ~reg ty variable with
      | Some c_name -> c_name
      | None -> (
          match constructor_c_name_for_type ~reg constructor_symbols ty variable with
          | Some c_name -> c_name
          | None -> Core.Var.to_c_name variable)
  in
  obj
    [
      ("name", str name);
      ("uniq", int variable.vuniq);
      ("def_id", option_int_json variable.vdef_id);
    ]

let primitive_type_names =
  StringSet.of_list
    [
      "Int";
      "Int8";
      "Int16";
      "Int32";
      "Int64";
      "Int128";
      "UInt8";
      "UInt16";
      "UInt32";
      "UInt64";
      "UInt128";
      "Float";
      "Float32";
      "Float16";
      "Bool";
      "Char";
      "String";
      "Bytes";
    ]

let primitive_type_name name = StringSet.mem name primitive_type_names

let tensor_static_dim_json value =
  kind "static" [ ("value", int value) ]

let tensor_runtime_dim_json dim_ty =
  kind "runtime" [ ("name", str (Types.type_to_string dim_ty)) ]

let tensor_dim_json dim_ty =
  match Types.Dim.normalize dim_ty with
  | Ast.TyConstInt value -> Ok (tensor_static_dim_json value)
  | Ast.TyVar name when Types.Dim.is_var_name name ->
      Ok (tensor_runtime_dim_json (Ast.TyVar name))
  | Ast.TyNamed (name, []) when Types.Dim.is_var_name name ->
      Ok (tensor_runtime_dim_json (Ast.TyNamed (name, [])))
  | Ast.TyDimOp _ as dim -> Ok (tensor_runtime_dim_json dim)
  | Ast.TyVarDims name -> Ok (tensor_runtime_dim_json (Ast.TyVarDims name))
  | dim -> Ok (tensor_runtime_dim_json dim)

let tensor_dims_json dims =
  result_list dims (fun _index dim -> tensor_dim_json dim)

let rec type_json ~reg enum_names value_record_names heap_record_names union_names path
    (ty : Ast.type_expr) =
  let ty =
    Codegen_types.expand_alias ~reg ty |> Codegen_types.normalize_type
  in
  match Types.array_parts ty with
  | Some (elem_ty, dims) ->
      let* elem_json =
        type_json ~reg enum_names value_record_names heap_record_names union_names
          (path ^ ".info.element_type") elem_ty
      in
      let* dims_json = tensor_dims_json dims in
      Ok
        (kind "tensor"
           [
             ( "info",
               obj [ ("element_type", elem_json); ("dims", dims_json) ] );
           ])
  | None ->
      non_tensor_type_json ~reg enum_names value_record_names heap_record_names
        union_names path ty

and non_tensor_type_json ~reg enum_names value_record_names heap_record_names
    union_names path ty =
  match ty with
  | Ast.TyNamed ("Void", []) -> Ok (kind "void" [])
  | Ast.TyNamed ("Result", [ ok_ty; err_ty ]) ->
      let* ok_json =
        result_payload_type_json ~reg enum_names value_record_names heap_record_names union_names
          (path ^ ".ok_type") ok_ty
      in
      let* err_json =
        result_payload_type_json ~reg enum_names value_record_names heap_record_names union_names
          (path ^ ".err_type") err_ty
      in
      let tag =
        if Core_layout_type.is_stack_result_type ~reg ty then "stack_result"
        else "boxed_result"
      in
      Ok (kind tag [ ("ok_type", ok_json); ("err_type", err_json) ])
  | Ast.TyNamed ("Option", args) ->
      let* arg_values =
        result_list args (fun index arg ->
            type_json ~reg enum_names value_record_names heap_record_names union_names
              (Printf.sprintf "%s.args[%d]" path index)
              arg)
      in
      Ok (kind "named" [ ("name", str "Option"); ("args", arg_values) ])
  | Ast.TyNamed (name, args) when primitive_type_name name ->
      let* arg_values =
        result_list args (fun index arg ->
            type_json ~reg enum_names value_record_names heap_record_names union_names
              (Printf.sprintf "%s.args[%d]" path index)
              arg)
      in
      Ok (kind "named" [ ("name", str name); ("args", arg_values) ])
  | Ast.TyNamed (name, []) when StringSet.mem name enum_names ->
      Ok (kind "enum" [ ("name", str name) ])
  | Ast.TyNamed (name, _ :: _) when StringSet.mem name enum_names ->
      unsupported path ("generic enum type " ^ name)
  | Ast.TyNamed (name, []) when StringSet.mem name value_record_names ->
      Ok (kind "value_record" [ ("name", str name) ])
  | Ast.TyNamed (name, _ :: _) when StringSet.mem name value_record_names ->
      unsupported path ("generic value record type " ^ name)
  | Ast.TyNamed (name, []) when StringSet.mem name heap_record_names ->
      Ok (kind "heap_record" [ ("name", str name) ])
  | Ast.TyNamed (name, _ :: _) when StringSet.mem name heap_record_names ->
      unsupported path ("generic heap record type " ^ name)
  | Ast.TyNamed (name, []) when StringSet.mem name union_names ->
      Ok (kind "union" [ ("name", str name) ])
  | Ast.TyNamed (name, _ :: _) when StringSet.mem name union_names ->
      unsupported path ("generic union type " ^ name)
  | Ast.TyNamed (name, args) ->
      let* arg_values =
        result_list args (fun index arg ->
            type_json ~reg enum_names value_record_names heap_record_names union_names
              (Printf.sprintf "%s.args[%d]" path index)
              arg)
      in
      Ok (kind "named" [ ("name", str name); ("args", arg_values) ])
  | Ast.TyConstInt _ ->
      Ok (kind "named" [ ("name", str "Int"); ("args", arr []) ])
  | Ast.TyTuple items ->
      let* item_values =
        result_list items (fun index item ->
            type_json ~reg enum_names value_record_names heap_record_names union_names
              (Printf.sprintf "%s.items[%d]" path index)
              item)
      in
      Ok (kind "tuple" [ ("items", item_values) ])
  | Ast.TyArray _ -> unsupported path "uncanonicalized tensor type"
  | Ast.TyFunc _ ->
      Ok (kind "named" [ ("name", str "Closure"); ("args", arr []) ])
  | Ast.TyVar name when Types.Dim.is_var_name name ->
      Ok (kind "named" [ ("name", str "Int"); ("args", arr []) ])
  | Ast.TyVar name -> unsupported path ("type variable " ^ name)
  | Ast.TyBoundVar param ->
      unsupported path ("bound type variable " ^ param.param_name)
  | Ast.TySelf -> unsupported path "Self type"
  | Ast.TyVarDims name -> unsupported path ("variadic dimension " ^ name)
  | Ast.TyRange _ -> Ok (kind "range" [])
  | Ast.TyDimOp _ ->
      Ok (kind "named" [ ("name", str "Int"); ("args", arr []) ])
  | Ast.TyMeta id ->
      unsupported path ("unresolved type meta " ^ string_of_int id)

and result_payload_type_json ~reg enum_names value_record_names heap_record_names
    union_names path ty =
  match Codegen_types.expand_alias ~reg ty with
  | Ast.TyVar _ | Ast.TyBoundVar _ ->
      (* Result's C representation is selected by the container layout. An
         unused generic payload slot does not change the control-flow shape;
         bindings that try to use an unresolved payload still fail separately
         when match bindings are serialized. *)
      Ok (kind "void" [])
  | concrete_ty ->
      type_json ~reg enum_names value_record_names heap_record_names union_names
        path concrete_ty

let int64_fits_json_int value =
  let as_int = Int64.to_int value in
  Int64.equal (Int64.of_int as_int) value

let int_literal_json value =
  if int64_fits_json_int value then
    let as_int = Int64.to_int value in
    kind "int" [ ("value", int as_int) ]
  else kind "wide_int" [ ("value", str (Printf.sprintf "%Ld" value)) ]

let literal_json path (literal : Ast.literal) =
  match literal with
  | Ast.LitInt value -> Ok (int_literal_json value)
  | Ast.LitFloat value -> (
      match classify_float value with
      | FP_nan -> Ok (kind "float_nan" [])
      | FP_infinite ->
          if value < 0.0 then Ok (kind "float_neg_infinity" [])
          else Ok (kind "float_infinity" [])
      | FP_normal | FP_subnormal | FP_zero ->
          Ok (kind "float_text" [ ("value", str (Printf.sprintf "%.17g" value)) ]))
  | Ast.LitBool value -> Ok (kind "bool" [ ("value", bool value) ])
  | Ast.LitChar value -> Ok (kind "char" [ ("value", int value) ])
  | Ast.LitString (value, _) -> Ok (kind "string" [ ("value", str value) ])
  | Ast.LitInt128 _ -> unsupported path "Int128 literal"

let literal_match_literal_json path (literal : Ast.literal) =
  match literal with
  | Ast.LitInt _ | Ast.LitFloat _ | Ast.LitBool _ | Ast.LitChar _
  | Ast.LitString _ ->
      literal_json path literal
  | Ast.LitInt128 _ -> unsupported path "Int128 literal match"

let primitive_tuple_field_type = function
  | Ast.TyNamed
      ( ( "Int" | "Int8" | "Int16" | "Int32" | "Int64" | "UInt8" | "UInt16"
        | "UInt32" | "UInt64" | "Float" | "Float32" | "Float16" | "Bool"
        | "Char" ),
        [] ) ->
      true
  | Ast.TyRange _ -> true
  | _ -> false

let managed_pointer_tuple_field_type = function
  | Ast.TyNamed (("String" | "Bytes" | "Fixed" | "Closure"), []) -> true
  | Ast.TyFunc _ -> true
  | Ast.TyNamed ("List", [ _ ]) -> true
  | Ast.TyNamed ("Dict", [ _; _ ]) -> true
  | Ast.TyNamed ("Set", [ _ ]) -> true
  | Ast.TyNamed ("Channel", [ _ ]) -> true
  | Ast.TyTuple _ -> true
  | Ast.TyArray _ -> true
  | _ -> false

let floating_tuple_field_projection_type = function
  | Ast.TyNamed (("Float" | "Float32" | "Float16"), []) -> true
  | _ -> false

let pointer_tuple_field_type value_record_names heap_record_names union_names = function
  | Ast.TyNamed
      ( ("String" | "Bytes" | "Fixed" | "Closure" | "List" | "Dict" | "Set"
        | "Ptr"),
        _ ) ->
      true
  | Ast.TyNamed ("Channel", [ _ ]) -> true
  | Ast.TyNamed (name, []) ->
      StringSet.mem name value_record_names
      || StringSet.mem name heap_record_names
      || StringSet.mem name union_names
  | Ast.TyFunc _ | Ast.TyTuple _ | Ast.TyArray _ -> true
  | _ -> false

let supported_tuple_field_projection_type ~reg value_record_names heap_record_names
    union_names ty =
  let ty = Codegen_types.expand_alias ~reg ty in
  primitive_tuple_field_type ty
  || managed_pointer_tuple_field_type ty
  || Core_layout_type.is_stack_option_type ~reg ty
  || floating_tuple_field_projection_type ty
  || pointer_tuple_field_type value_record_names heap_record_names union_names ty

let tuple_field_index path arity field_name =
  match int_of_string_opt field_name with
  | Some index when index >= 0 && index < arity -> Ok index
  | Some index ->
      unsupported path
        (Printf.sprintf "tuple field index %d out of bounds for arity %d" index
           arity)
  | None -> unsupported path ("non-numeric tuple field " ^ field_name)

let tuple_element_tag path = function
  | Core.BoxPrim -> Ok "prim"
  | Core.BoxPointer -> Ok "pointer"
  | Core.BoxVoid -> Ok "void"
  | Core.BoxFloat -> Ok "float"
  | Core.BoxFloat32 -> Ok "float32"
  | Core.BoxFloat16 -> Ok "float16"
  | Core.BoxInt128 -> unsupported path "Int128 tuple slot"
  | Core.BoxUInt128 -> unsupported path "UInt128 tuple slot"
  | Core.BoxStruct _ -> Ok "struct"

let union_constructor_tag_c_name type_name ctor =
  Printf.sprintf "TAG_%s_%s"
    (Codegen_names.sanitize_c_ident type_name)
    (Codegen_names.sanitize_c_ident ctor)

let rec match_accessor_type ~reg scrut_ty = function
  | Core.AccRoot -> Some (Core_layout_type.canonical_type ~reg scrut_ty)
  | Core.AccTupleField (parent, idx) -> (
      match match_accessor_type ~reg scrut_ty parent with
      | Some parent_ty -> (
          match Core_layout_type.canonical_type ~reg parent_ty with
          | Ast.TyTuple elems -> List.nth_opt elems idx
          | _ -> None)
      | None -> None)
  | Core.AccListElem (parent, _) -> (
      match match_accessor_type ~reg scrut_ty parent with
      | Some parent_ty -> (
          match Core_layout_type.canonical_type ~reg parent_ty with
          | Ast.TyNamed ("List", [ elem ]) -> Some elem
          | _ -> None)
      | None -> None)
  | Core.AccListSpread (parent, _) -> match_accessor_type ~reg scrut_ty parent
  | Core.AccVariantField (parent, ctor, idx) -> (
      match (match_accessor_type ~reg scrut_ty parent, ctor, idx) with
      | Some parent_ty, "Some", 0 -> (
          match Core_layout_type.canonical_type ~reg parent_ty with
          | Ast.TyNamed ("Option", [ payload ]) -> Some payload
          | _ -> None)
      | Some parent_ty, "Ok", 0 -> (
          match Core_layout_type.canonical_type ~reg parent_ty with
          | Ast.TyNamed ("Result", [ ok_ty; _ ]) -> Some ok_ty
          | _ -> None)
      | Some parent_ty, "Err", 0 -> (
          match Core_layout_type.canonical_type ~reg parent_ty with
          | Ast.TyNamed ("Result", [ _; err_ty ]) -> Some err_ty
          | _ -> None)
      | Some parent_ty, ctor, idx -> (
          match Core_layout_type.canonical_type ~reg parent_ty with
          | Ast.TyNamed (type_name, _) -> (
              match Codegen_types.lookup_union_variant reg type_name ctor with
              | Some variant -> List.nth_opt variant.variant_fields idx
              | None -> None)
          | _ -> None)
      | _ -> None)

let match_accessor_parent_type ~reg scrut_ty = function
  | Core.AccVariantField (parent, _, _)
  | Core.AccTupleField (parent, _)
  | Core.AccListElem (parent, _)
  | Core.AccListSpread (parent, _) ->
      match_accessor_type ~reg scrut_ty parent
  | Core.AccRoot -> None

let constructor_match_test_json ~reg enum_names union_names enum_constructors path
    scrut_ty ctor =
  let scrut_ty = Core_emit_layout.canonical_type ~reg scrut_ty in
  match scrut_ty with
  | Ast.TyNamed ("Option", [ _ ])
    when Core_layout_type.is_stack_option_type ~reg scrut_ty -> (
      let* option_type =
        match Core_layout_type.stack_option_c_type ~reg scrut_ty with
        | Some c_type -> Ok c_type
        | None -> unsupported path "stack Option C type unavailable"
      in
      match ctor with
      | "Some" -> Ok (kind "stack_option_some" [ ("option_type", str option_type) ])
      | "None" -> Ok (kind "stack_option_none" [ ("option_type", str option_type) ])
      | _ -> unsupported path ("unknown stack Option constructor " ^ ctor))
  | Ast.TyNamed ("Option", [ _ ])
    when Core_layout_type.is_nullable_managed_option ~reg scrut_ty -> (
      match ctor with
      | "Some" -> Ok (kind "nullable_option_some" [])
      | "None" -> Ok (kind "nullable_option_none" [])
      | _ -> unsupported path ("unknown nullable Option constructor " ^ ctor))
  | Ast.TyNamed ("Option", [ _ ]) -> (
      match ctor with
      | "Some" | "None" ->
          Ok
            (kind "union_tag"
               [
                 ("tag_c_name", str (union_constructor_tag_c_name "Option" ctor));
                 ("union_c_type", str "Option");
               ])
      | _ -> unsupported path ("unknown boxed Option constructor " ^ ctor))
  | Ast.TyNamed ("Result", [ _; _ ])
    when Core_layout_type.is_stack_result_type ~reg scrut_ty -> (
      let* result_type =
        match Core_layout_type.stack_result_c_type ~reg scrut_ty with
        | Some c_type -> Ok c_type
        | None -> unsupported path "stack Result C type unavailable"
      in
      match ctor with
      | "Ok" -> Ok (kind "stack_result_ok" [ ("result_type", str result_type) ])
      | "Err" ->
          Ok (kind "stack_result_err" [ ("result_type", str result_type) ])
      | _ -> unsupported path ("unknown stack Result constructor " ^ ctor))
  | Ast.TyNamed ("Result", [ _; _ ]) -> (
      match ctor with
      | "Ok" -> Ok (kind "boxed_result_ok" [])
      | "Err" -> Ok (kind "boxed_result_err" [])
      | _ -> unsupported path ("unknown boxed Result constructor " ^ ctor))
  | Ast.TyNamed ("Bool", []) -> (
      match ctor with
      | "True" -> Ok (kind "bool_true" [])
      | "False" -> Ok (kind "bool_false" [])
      | _ -> unsupported path ("unknown Bool constructor " ^ ctor))
  | Ast.TyNamed (type_name, []) when StringSet.mem type_name enum_names -> (
      match
        StringMap.find_opt
          (enum_constructor_key type_name ctor)
          enum_constructors
      with
      | Some c_name -> Ok (kind "enum" [ ("c_name", str c_name) ])
      | None -> unsupported path ("unknown enum constructor " ^ ctor))
  | Ast.TyNamed (type_name, []) when StringSet.mem type_name union_names ->
      Ok
        (kind "union_tag"
           [
             ("tag_c_name", str (union_constructor_tag_c_name type_name ctor));
             ("union_c_type", str type_name);
           ])
  | Ast.TyNamed (_type_name, _ :: _) ->
      unsupported path
        (Printf.sprintf "constructor match on generic type %s constructor %s"
           (Types.type_to_string scrut_ty) ctor)
  | _ ->
      unsupported path
        (Printf.sprintf
           "constructor match on non-enum or non-union type %s constructor %s"
           (Types.type_to_string scrut_ty) ctor)

let rec match_accessor_json ~reg ?(enum_names = StringSet.empty)
    ?(value_record_names = StringSet.empty)
    ?(heap_record_names = StringSet.empty) ?(union_names = StringSet.empty)
    scrut_ty path = function
  | Core.AccRoot -> Ok (kind "root" [])
  | Core.AccVariantField (parent_acc, "Some", 0)
    when Option.fold
           ~none:false
           ~some:(Core_layout_type.is_stack_option_type ~reg)
           (match_accessor_parent_type ~reg scrut_ty
              (Core.AccVariantField (parent_acc, "Some", 0))) ->
      let* parent =
        match_accessor_json ~reg ~enum_names ~value_record_names
          ~heap_record_names ~union_names scrut_ty (path ^ ".parent") parent_acc
      in
      Ok (kind "stack_option_payload" [ ("parent", parent) ])
  | Core.AccVariantField (parent_acc, "Some", 0)
    when Option.fold
           ~none:false
           ~some:(Core_layout_type.is_nullable_managed_option ~reg)
           (match_accessor_parent_type ~reg scrut_ty
              (Core.AccVariantField (parent_acc, "Some", 0))) ->
      let* parent =
        match_accessor_json ~reg ~enum_names ~value_record_names
          ~heap_record_names ~union_names scrut_ty (path ^ ".parent") parent_acc
      in
      Ok (kind "nullable_option_payload" [ ("parent", parent) ])
  | Core.AccVariantField (parent_acc, "Ok", 0)
    when Option.fold
           ~none:false
           ~some:(Core_layout_type.is_stack_result_type ~reg)
           (match_accessor_parent_type ~reg scrut_ty
              (Core.AccVariantField (parent_acc, "Ok", 0))) ->
      let* parent =
        match_accessor_json ~reg ~enum_names ~value_record_names
          ~heap_record_names ~union_names scrut_ty (path ^ ".parent") parent_acc
      in
      let* result_type =
        match match_accessor_type ~reg scrut_ty parent_acc with
        | Some ty -> (
            match Core_layout_type.stack_result_c_type ~reg ty with
            | Some c_type -> Ok c_type
            | None -> unsupported path "stack Result payload C type unavailable")
        | None -> unsupported path "stack Result payload parent type unavailable"
      in
      if parent_acc = Core.AccRoot then
        Ok (kind "stack_result_ok_payload" [ ("parent", parent) ])
      else
        Ok
          (kind "boxed_stack_result_ok_payload"
             [ ("parent", parent); ("result_type", str result_type) ])
  | Core.AccVariantField (parent_acc, "Err", 0)
    when Option.fold
           ~none:false
           ~some:(Core_layout_type.is_stack_result_type ~reg)
           (match_accessor_parent_type ~reg scrut_ty
              (Core.AccVariantField (parent_acc, "Err", 0))) ->
      let* parent =
        match_accessor_json ~reg ~enum_names ~value_record_names
          ~heap_record_names ~union_names scrut_ty (path ^ ".parent") parent_acc
      in
      let* result_type =
        match match_accessor_type ~reg scrut_ty parent_acc with
        | Some ty -> (
            match Core_layout_type.stack_result_c_type ~reg ty with
            | Some c_type -> Ok c_type
            | None -> unsupported path "stack Result payload C type unavailable")
        | None -> unsupported path "stack Result payload parent type unavailable"
      in
      if parent_acc = Core.AccRoot then
        Ok (kind "stack_result_err_payload" [ ("parent", parent) ])
      else
        Ok
          (kind "boxed_stack_result_err_payload"
             [ ("parent", parent); ("result_type", str result_type) ])
  | Core.AccVariantField (parent_acc, "Ok", 0)
    when Option.fold ~none:false
           ~some:(fun ty ->
             match Core_layout_type.canonical_type ~reg ty with
             | Ast.TyNamed ("Result", [ _; _ ]) ->
                 not (Core_layout_type.is_stack_result_type ~reg ty)
             | _ -> false)
           (match_accessor_parent_type ~reg scrut_ty
              (Core.AccVariantField (parent_acc, "Ok", 0))) ->
      let* parent =
        match_accessor_json ~reg ~enum_names ~value_record_names
          ~heap_record_names ~union_names scrut_ty (path ^ ".parent") parent_acc
      in
      Ok (kind "boxed_result_ok_payload" [ ("parent", parent) ])
  | Core.AccVariantField (parent_acc, "Err", 0)
    when Option.fold ~none:false
           ~some:(fun ty ->
             match Core_layout_type.canonical_type ~reg ty with
             | Ast.TyNamed ("Result", [ _; _ ]) ->
                 not (Core_layout_type.is_stack_result_type ~reg ty)
             | _ -> false)
           (match_accessor_parent_type ~reg scrut_ty
              (Core.AccVariantField (parent_acc, "Err", 0))) ->
      let* parent =
        match_accessor_json ~reg ~enum_names ~value_record_names
          ~heap_record_names ~union_names scrut_ty (path ^ ".parent") parent_acc
      in
      Ok (kind "boxed_result_err_payload" [ ("parent", parent) ])
  | Core.AccVariantField (parent_acc, ctor, idx) ->
      let* parent =
        match_accessor_json ~reg ~enum_names ~value_record_names
          ~heap_record_names ~union_names scrut_ty (path ^ ".parent") parent_acc
      in
      let* union_info =
        match match_accessor_parent_type ~reg scrut_ty
                (Core.AccVariantField (parent_acc, ctor, idx)) with
        | Some (Ast.TyNamed (type_name, _))
          when Codegen_types.union_uses_typed_payload_storage reg type_name ->
            Ok (type_name, "variant_field")
        | Some (Ast.TyNamed (type_name, _)) ->
            Ok (type_name, "erased_variant_field")
        | _ -> unsupported path "variant field parent type unavailable"
      in
      let union_c_type, tag = union_info in
      Ok
        (kind tag
           [
             ("parent", parent);
             ("union_c_type", str union_c_type);
             ("constructor", str ctor);
             ("field_index", int idx);
           ])
  | Core.AccTupleField (parent_acc, idx) -> (
      let* parent =
        match_accessor_json ~reg ~enum_names ~value_record_names
          ~heap_record_names ~union_names scrut_ty (path ^ ".parent") parent_acc
      in
      match match_accessor_type ~reg scrut_ty (Core.AccTupleField (parent_acc, idx)) with
      | Some field_ty ->
          let* field_type =
            type_json ~reg enum_names value_record_names heap_record_names
              union_names (path ^ ".type") field_ty
          in
          Ok
            (kind "tuple_field"
               [
                 ("parent", parent);
                 ("index", int idx);
                 ("type", field_type);
               ])
      | None -> unsupported path "tuple match binding accessor type")
  | Core.AccListElem (parent_acc, idx) ->
      let* parent =
        match_accessor_json ~reg ~enum_names ~value_record_names
          ~heap_record_names ~union_names scrut_ty (path ^ ".parent") parent_acc
      in
      Ok (kind "list_element" [ ("parent", parent); ("index", int idx) ])
  | Core.AccListSpread (parent_acc, offset) ->
      let* parent =
        match_accessor_json ~reg ~enum_names ~value_record_names
          ~heap_record_names ~union_names scrut_ty (path ^ ".parent") parent_acc
      in
      Ok
        (kind "list_spread" [ ("parent", parent); ("offset", int offset) ])

let match_binding_mode_json _path = function
  | Core.MatchBorrow -> Ok (str "borrow")
  | Core.MatchOwn -> Ok (str "own")

let match_binding_json ~reg enum_names value_record_names heap_record_names union_names
    scrut_ty var_types path (binding : Core.match_binding) =
  let binding_ty =
    match Core_emit_util.find_var_type binding.mb_var.vname var_types with
    | Ast.TyVar "?" -> (
        match binding.mb_accessor with
        | Core.AccRoot -> scrut_ty
        | accessor -> (
            match match_accessor_type ~reg scrut_ty accessor with
            | Some ty -> ty
            | None -> Ast.TyVar "?"))
    | ty -> ty
  in
  match binding_ty with
  | Ast.TyVar "?" -> unsupported (path ^ ".type") "match binding type unavailable"
  | _ ->
      let* typ =
        type_json ~reg enum_names value_record_names heap_record_names union_names
          (path ^ ".type") binding_ty
      in
      let* accessor =
        match_accessor_json ~reg ~enum_names ~value_record_names
          ~heap_record_names ~union_names scrut_ty (path ^ ".accessor")
          binding.mb_accessor
      in
      let* mode = match_binding_mode_json (path ^ ".mode") binding.mb_mode in
      Ok
        (obj
           [
             ("variable", var_json binding.mb_var);
             ("type", typ);
             ("accessor", accessor);
             ("mode", mode);
           ])

let match_bindings_json ~reg enum_names value_record_names heap_record_names union_names
    scrut_ty var_types path bindings =
  result_list bindings (fun index binding ->
      match_binding_json ~reg enum_names value_record_names heap_record_names
        union_names scrut_ty var_types
        (Printf.sprintf "%s[%d]" path index)
        binding)

let param_json ~reg enum_names value_record_names heap_record_names union_names path
    (param : Core.core_param) =
  let* typ =
    type_json ~reg enum_names value_record_names heap_record_names union_names (path ^ ".type")
      param.cp_ty
  in
  Ok
    (obj
       [
         ("name", var_json param.cp_name);
         ("type", typ);
         ("loc", source_loc_json param.cp_loc);
       ])

let closure_param_json ~reg enum_names value_record_names heap_record_names union_names
    path (param_var, param_ty) =
  let* typ =
    type_json ~reg enum_names value_record_names heap_record_names union_names
      (path ^ ".type") param_ty
  in
  Ok
    (obj
       [
         ("name", var_json param_var);
         ("type", typ);
         ("loc", source_loc_json Ast.dummy_loc);
       ])

let closure_params_json ~reg enum_names value_record_names heap_record_names union_names
    path params =
  result_list params (fun index param ->
      closure_param_json ~reg enum_names value_record_names heap_record_names
        union_names
        (Printf.sprintf "%s[%d]" path index)
        param)

let loop_range_direction_json = function
  | Core.RangeMayRunBackward -> str "may_run_backward"
  | Core.RangeForwardOnly -> str "forward_only"

let loop_binder_json ~reg enum_names value_record_names heap_record_names union_names path
    (binder : Core.loop_binder) =
  let* typ =
    type_json ~reg enum_names value_record_names heap_record_names union_names (path ^ ".type")
      binder.loop_ty
  in
  Ok
    (obj
       [
         ("var", var_json binder.loop_var);
         ("type", typ);
         ( "range_direction",
           loop_range_direction_json binder.loop_range_direction );
       ])

let normalized_type ~reg ty =
  Codegen_types.expand_alias ~reg ty |> Codegen_types.normalize_type

let result_payload_types path ~reg ty =
  match normalized_type ~reg ty with
  | Ast.TyNamed ("Result", [ ok_ty; err_ty ]) -> Ok (ok_ty, err_ty)
  | other ->
      unsupported path
        (Printf.sprintf "operation-result call return type %s"
           (Types.type_to_string other))

let result_layout_policy_json = function
  | Operation_result_metadata.DefaultResultLayout -> kind "default" []
  | Operation_result_metadata.BoxedResultOnly hint ->
      kind "boxed_only" [ ("hint", str hint) ]

let constructor_c_name_for_operation_type ~reg path ~builtin_name ~role type_name
    constructor_name =
  match Codegen_types.lookup_union_variant reg type_name constructor_name with
  | Some variant -> (
      match variant.variant_def_id with
      | Some def_id -> Ok (Codegen_names.mangle_by_def_id def_id variant.variant_name)
      | None -> Ok (Codegen_names.sanitize_c_ident variant.variant_name))
  | None ->
      unsupported path
        (Printf.sprintf "missing runtime operation %s constructor `%s.%s` for `%s`"
           role type_name constructor_name builtin_name)

let operation_payload_named_type_name path ~reg ~builtin_name ~payload_kind ty =
  match normalized_type ~reg ty with
  | Ast.TyNamed (name, _) -> Ok name
  | other ->
      unsupported path
        (Printf.sprintf
           "operation-result %s payload for `%s` must bridge into a named type, \
            got %s"
           payload_kind builtin_name (Types.type_to_string other))

let operation_error_type_name path ~reg
    (bridge : Operation_result_metadata.result_bridge) err_ty =
  match normalized_type ~reg err_ty with
  | Ast.TyNamed (name, [])
    when List.mem name bridge.Operation_result_metadata.error.accepted_type_names
    ->
      Ok name
  | Ast.TyNamed (name, []) ->
      unsupported path
        (Printf.sprintf
           "runtime operation `%s` error payload has unsupported type `%s`"
           bridge.builtin_name name)
  | other ->
      unsupported path
        (Printf.sprintf
           "runtime operation `%s` error payload has unsupported type `%s`"
           bridge.builtin_name (Types.type_to_string other))

let runtime_union_arg_json = function
  | Operation_result_metadata.RuntimeOwnedField field ->
      kind "owned_field" [ ("field", str field) ]
  | Operation_result_metadata.RuntimeIntField field ->
      kind "int_field" [ ("field", str field) ]

let runtime_union_args_json args = arr (List.map runtime_union_arg_json args)

let runtime_union_case_json ~reg path ~builtin_name ~type_name
    (case : Operation_result_metadata.runtime_union_case) =
  let* constructor_c_name =
    constructor_c_name_for_operation_type ~reg path ~builtin_name
      ~role:"success" type_name case.constructor_name
  in
  Ok
    (obj
       [
         ("runtime_tag", str case.runtime_tag);
         ("constructor_name", str case.constructor_name);
         ("constructor_c_name", str constructor_c_name);
         ("args", runtime_union_args_json case.args);
       ])

let runtime_union_cases_json ~reg path ~builtin_name ~type_name cases =
  result_list cases (fun index case ->
      runtime_union_case_json ~reg
        (Printf.sprintf "%s[%d]" path index)
        ~builtin_name ~type_name case)

let runtime_success_payload_json ~reg path
    (bridge : Operation_result_metadata.result_bridge) ok_ty
    (payload : Operation_result_metadata.runtime_success_payload) =
  match payload with
  | Operation_result_metadata.RuntimeNoPayload -> Ok (kind "no_payload" [])
  | Operation_result_metadata.RuntimeField field ->
      Ok (kind "field" [ ("field", str field) ])
  | Operation_result_metadata.RuntimeRecordFields fields ->
      Ok (kind "record_fields" [ ("fields", string_list_json fields) ])
  | Operation_result_metadata.RuntimeUnion { runtime_tag_field; cases } ->
      let* type_name =
        operation_payload_named_type_name path ~reg
          ~builtin_name:bridge.builtin_name ~payload_kind:"union-success" ok_ty
      in
      let* cases_json =
        runtime_union_cases_json ~reg (path ^ ".cases")
          ~builtin_name:bridge.builtin_name ~type_name cases
      in
      Ok
        (kind "union"
           [
             ("runtime_tag_field", str runtime_tag_field);
             ("cases", cases_json);
           ])

let operation_success_payload_json ~reg path
    (bridge : Operation_result_metadata.result_bridge) ok_ty =
  let* runtime_payload =
    runtime_success_payload_json ~reg (path ^ ".runtime_payload") bridge ok_ty
      bridge.success.runtime_payload
  in
  Ok
    (obj
       [
         ("runtime_payload", runtime_payload);
         ("release_mask", int bridge.success.release_mask);
       ])

let operation_error_case_json ~reg path ~builtin_name ~err_name
    (case : Operation_result_metadata.error_case) =
  let* constructor_c_name =
    constructor_c_name_for_operation_type ~reg path ~builtin_name ~role:"error"
      err_name case.constructor_name
  in
  Ok
    (obj
       [
         ("runtime_tag", str case.runtime_tag);
         ("constructor_name", str case.constructor_name);
         ("constructor_c_name", str constructor_c_name);
       ])

let operation_error_cases_json ~reg path ~builtin_name ~err_name cases =
  result_list cases (fun index case ->
      operation_error_case_json ~reg
        (Printf.sprintf "%s[%d]" path index)
        ~builtin_name ~err_name case)

let operation_error_mapping_json ~reg path
    (bridge : Operation_result_metadata.result_bridge) err_name =
  let error = bridge.Operation_result_metadata.error in
  let* other_constructor_c_name =
    constructor_c_name_for_operation_type ~reg (path ^ ".other_constructor")
      ~builtin_name:bridge.builtin_name ~role:"error" err_name
      error.other_constructor
  in
  let* cases =
    operation_error_cases_json ~reg (path ^ ".cases")
      ~builtin_name:bridge.builtin_name ~err_name error.cases
  in
  Ok
    (obj
       [
         ("none_tag", str error.none_tag);
         ("detail_field", str error.detail_field);
         ("other_constructor", str error.other_constructor);
         ("other_constructor_c_name", str other_constructor_c_name);
         ("cases", cases);
       ])

let operation_result_bridge_json ~reg path ~result_ty
    (bridge : Operation_result_metadata.result_bridge) =
  let* ok_ty, err_ty = result_payload_types path ~reg result_ty in
  let ok_ty_normalized = normalized_type ~reg ok_ty in
  if
    not
      (Operation_result_metadata.success_payload_accepts_type bridge.success
         ok_ty_normalized)
  then
    unsupported path
      (Printf.sprintf
         "runtime operation `%s` success payload has unsupported type `%s`"
         bridge.builtin_name (Types.type_to_string ok_ty_normalized))
  else
    let stack_result = Core_layout_type.is_stack_result_type ~reg result_ty in
    match (bridge.result_layout_policy, stack_result) with
    | Operation_result_metadata.BoxedResultOnly hint, true -> unsupported path hint
    | Operation_result_metadata.BoxedResultOnly _, false
    | Operation_result_metadata.DefaultResultLayout, _ ->
        let* err_name = operation_error_type_name path ~reg bridge err_ty in
        let* success =
          operation_success_payload_json ~reg (path ^ ".success") bridge ok_ty
        in
        let* error =
          operation_error_mapping_json ~reg (path ^ ".error") bridge err_name
        in
        Ok
          (obj
             [
               ("builtin_name", str bridge.builtin_name);
               ("runtime_c_name", str bridge.runtime_c_name);
               ("runtime_result_c_type", str bridge.runtime_result_c_type);
               ("temp_prefix", str bridge.temp_prefix);
               ( "result_layout_policy",
                 result_layout_policy_json bridge.result_layout_policy );
               ("success", success);
               ("error", error);
             ])

let fallible_stream_payload_accepts_type ~reg
    (payload : Operation_result_metadata.fallible_stream_terminal_payload) ok_ty
    =
  match (payload, normalized_type ~reg ok_ty) with
  | Operation_result_metadata.StreamPayloadList, Ast.TyNamed ("List", _) -> true
  | Operation_result_metadata.StreamPayloadInt, Ast.TyNamed ("Int", []) -> true
  | Operation_result_metadata.StreamPayloadBool, Ast.TyNamed ("Bool", []) -> true
  | Operation_result_metadata.StreamPayloadOption, Ast.TyNamed ("Option", [ _ ])
    ->
      true
  | Operation_result_metadata.StreamPayloadErased, _ -> true
  | _ -> false

let fallible_stream_terminal_payload_json ~reg loc ok_ty
    (payload : Operation_result_metadata.fallible_stream_terminal_payload) =
  match payload with
  | Operation_result_metadata.StreamPayloadList ->
      let layout =
        Core_layout_type.list_storage_layout_of_type ~reg ok_ty loc
      in
      let storage_mode, elem_size =
        Core_emit_layout.list_runtime_storage_args layout
      in
      Ok (kind "list" [ ("storage_mode", str storage_mode); ("elem_size", str elem_size) ])
  | Operation_result_metadata.StreamPayloadErased -> Ok (kind "erased" [])
  | Operation_result_metadata.StreamPayloadInt -> Ok (kind "int" [])
  | Operation_result_metadata.StreamPayloadOption -> Ok (kind "option" [])
  | Operation_result_metadata.StreamPayloadBool -> Ok (kind "bool" [])

let fallible_stream_error_mapping_for_type path ~reg ~builtin_name err_ty =
  match normalized_type ~reg err_ty with
  | Ast.TyNamed (name, [])
    when List.mem name
           Operation_result_metadata.file_error_mapping.accepted_type_names ->
      Ok
        ( "BLORP_FALLIBLE_STREAM_ERROR_DOMAIN_FILE",
          Operation_result_metadata.file_error_mapping,
          name )
  | Ast.TyNamed (name, [])
    when List.mem name
           Operation_result_metadata.udp_error_mapping.accepted_type_names ->
      Ok
        ( "BLORP_FALLIBLE_STREAM_ERROR_DOMAIN_UDP",
          Operation_result_metadata.udp_error_mapping,
          name )
  | Ast.TyNamed (name, [])
    when List.mem name
           Operation_result_metadata.tcp_error_mapping.accepted_type_names ->
      Ok
        ( "BLORP_FALLIBLE_STREAM_ERROR_DOMAIN_TCP",
          Operation_result_metadata.tcp_error_mapping,
          name )
  | Ast.TyNamed (name, [])
    when List.mem name
           Operation_result_metadata.tls_error_mapping.accepted_type_names ->
      Ok
        ( "BLORP_FALLIBLE_STREAM_ERROR_DOMAIN_TLS",
          Operation_result_metadata.tls_error_mapping,
          name )
  | Ast.TyNamed (name, []) ->
      unsupported path
        (Printf.sprintf
           "fallible stream terminal `%s` error payload has unsupported type `%s`"
           builtin_name name)
  | other ->
      unsupported path
        (Printf.sprintf
           "fallible stream terminal `%s` error payload has unsupported type `%s`"
           builtin_name (Types.type_to_string other))

let fallible_stream_error_domain_json ~reg path ~builtin_name err_ty =
  let* domain_tag, mapping, err_name =
    fallible_stream_error_mapping_for_type path ~reg ~builtin_name err_ty
  in
  let* other_constructor_c_name =
    constructor_c_name_for_operation_type ~reg (path ^ ".other_constructor")
      ~builtin_name ~role:"fallible-stream error" err_name
      mapping.Operation_result_metadata.other_constructor
  in
  let* cases =
    operation_error_cases_json ~reg (path ^ ".cases") ~builtin_name ~err_name
      mapping.Operation_result_metadata.cases
  in
  Ok
    (obj
       [
         ("domain_tag", str domain_tag);
         ( "other_constructor",
           str mapping.Operation_result_metadata.other_constructor );
         ("other_constructor_c_name", str other_constructor_c_name);
         ("cases", cases);
       ])

let fallible_stream_terminal_bridge_json ~reg path ~result_ty ~loc
    (terminal : Operation_result_metadata.fallible_stream_terminal) =
  let* ok_ty, err_ty = result_payload_types path ~reg result_ty in
  if not (fallible_stream_payload_accepts_type ~reg terminal.payload ok_ty) then
    unsupported path
      (Printf.sprintf
         "fallible stream terminal `%s` success payload has unsupported type `%s`"
         terminal.builtin_name
         (Types.type_to_string (normalized_type ~reg ok_ty)))
  else
    let* payload =
      fallible_stream_terminal_payload_json ~reg loc ok_ty terminal.payload
    in
    let* error_domain =
      fallible_stream_error_domain_json ~reg (path ^ ".error_domain")
        ~builtin_name:terminal.builtin_name err_ty
    in
    Ok
      (obj
         [
           ("builtin_name", str terminal.builtin_name);
           ("runtime_c_name", str terminal.runtime_c_name);
           ("runtime_result_c_type", str terminal.runtime_result_c_type);
           ("payload", payload);
           ("error_domain", error_domain);
         ])

let is_option_type = function
  | Ast.TyNamed ("Option", [ _ ]) -> true
  | _ -> false

let is_result_type ~reg ty =
  Core_layout_type.is_stack_result_type ~reg ty
  ||
  match Core_emit_layout.canonical_type ~reg ty with
  | Ast.TyNamed ("Result", [ _; _ ]) -> true
  | _ -> false

let generated_stack_option_get_supported ~reg result_ty =
  Option.is_some (Core_layout_type.generated_stack_option_get_abi ~reg result_ty)

let string_ends_with ~suffix value =
  let value_len = String.length value in
  let suffix_len = String.length suffix in
  value_len >= suffix_len
  && String.sub value (value_len - suffix_len) suffix_len = suffix

let list_to_string_callback_name function_names path list_ty =
  match Codegen_types.normalize_type list_ty with
  | Ast.TyNamed ("List", [ elem_ty ]) -> (
      match Codegen_types.type_key_for_impl elem_ty with
      | None ->
          unsupported path
            (Printf.sprintf
               "cannot form Stringable.to_string callback for list element type %s"
               (Types.type_to_string elem_ty))
      | Some elem_key ->
          let source_name =
            Codegen_types.escape_c_ident
              (Printf.sprintf "Stringable_to_string_%s" elem_key)
          in
          if StringSet.mem source_name function_names then Ok source_name
          else
            let suffix = "_" ^ source_name in
            let match_name =
              StringSet.to_seq function_names
              |> Seq.find (fun name -> string_ends_with ~suffix name)
            in
            Ok (Option.value match_name ~default:source_name))
  | other ->
      unsupported path
        (Printf.sprintf "blorp_list_to_string_cb on non-List type %s"
           (Types.type_to_string other))

let foreign_copy_kind_json = function
  | Core.ForeignStringCopy -> str "string"
  | Core.ForeignBytesCopy -> str "bytes"

let foreign_default_arg_policy_json = function
  | Core.ForeignScalarByValue -> kind "scalar_by_value" []
  | Core.ForeignDefensiveCopy copy_kind ->
      kind "defensive_copy"
        [ ("copy_kind", foreign_copy_kind_json copy_kind) ]

let foreign_arg_passing_json = function
  | Core.ForeignDefaultArgs policies ->
      kind "default"
        [ ("policies", arr (List.map foreign_default_arg_policy_json policies)) ]
  | Core.ForeignBorrowArgs -> kind "borrow" []

let tensor_alloc_runtime_builtin ~reg path (expr : Core.core) =
  let layout =
    Core_emit_layout.tensor_storage_layout_of_type_for_reg ~reg expr.ty expr.loc
  in
  if
    Core.tensor_storage_layout_requires_release_or_error ~phase:Core_error.Emit
      ~loc:expr.loc layout
  then
    unsupported path
      "tensor_alloc for releasing tensor element layouts needs the typed Blorp \
       tensor allocation JSON node"
  else
    match layout.tsl_slots with
    | Core.TensorRawScalarStorage Core.TensorInt64Elements ->
        Ok "blorp_vector_new_i64"
    | Core.TensorRawScalarStorage Core.TensorFloat64Elements ->
        Ok "blorp_vector_new_f64"
    | Core.TensorRawScalarStorage Core.TensorFloat32Elements ->
        Ok "blorp_vector_new_f32"
    | Core.TensorWordStorage -> Ok "blorp_vector_new"
    | Core.TensorPackedStorage _ | Core.TensorInlineStructStorage _
    | Core.TensorBoxedStorage ->
      unsupported path
        "tensor_alloc for this tensor layout needs the typed Blorp tensor \
         allocation JSON node"

let tensor_parallel_raw_scalar_kind_json = function
  | Core.TensorFloat64Elements -> str "float64"
  | Core.TensorFloat32Elements -> str "float32"
  | Core.TensorInt64Elements -> str "int64"

let tensor_parallel_layout_json ~reg ~loc ty =
  let layout =
    Core_emit_layout.tensor_storage_layout_of_type_for_reg ~reg ty loc
  in
  match layout.tsl_slots with
  | Core.TensorRawScalarStorage raw_kind ->
      kind "raw_scalar"
        [ ("raw_kind", tensor_parallel_raw_scalar_kind_json raw_kind) ]
  | Core.TensorInlineStructStorage c_ty ->
      kind "inline_struct" [ ("c_type", str c_ty) ]
  | Core.TensorPackedStorage _ | Core.TensorWordStorage | Core.TensorBoxedStorage
    ->
      kind "pointer" []

let consumed_args_for_user_call consumed_params def_id =
  match def_id with
  | Some id -> Option.value ~default:[] (List.assoc_opt id consumed_params)
  | None -> []

let same_var_name (left : Core.var) (right : Core.var) =
  String.equal left.vname right.vname

let expr_is_param_ref (param : Core.core_param) (expr : Core.core) =
  match expr.Core.desc with
  | Core.CVar candidate -> same_var_name candidate param.cp_name
  | _ -> false

let call_consumes_param consumed_params (param : Core.core_param)
    (kind : Core.call_kind) args =
  match kind with
  | Core.CKUser (_name, def_id) ->
      consumed_args_for_user_call consumed_params def_id
      |> List.exists (fun index ->
             match List.nth_opt args index with
             | Some arg -> expr_is_param_ref param arg
             | None -> false)
  | Core.CKUnknown | Core.CKSelectedDirect _ | Core.CKForeign _ | Core.CKBuiltin _
  | Core.CKClosure | Core.CKIntrinsic _ ->
      false

let function_param_is_consumed consumed_params (body : Core.core)
    (param : Core.core_param) =
  Core.exists_tree
    (fun expr ->
      match expr.Core.desc with
      | Core.CDrop (dropped, _ty, _body) -> same_var_name dropped param.cp_name
      | Core.CCall (kind, _callee, args) ->
          call_consumes_param consumed_params param kind args
      | _ -> false)
    body

let consumed_param_indices_for_function consumed_params (func : Core.core_func) =
  match func.cf_body with
  | None -> []
  | Some body ->
      let rec collect index acc = function
        | [] -> List.rev acc
        | param :: rest ->
            let acc =
              if function_param_is_consumed consumed_params body param then
                index :: acc
              else acc
            in
            collect (index + 1) acc rest
      in
      collect 0 [] func.cf_params

let collect_consumed_param_indices_once consumed_params program =
  let rec collect_decl acc (decl : Core.core_decl) =
    match decl.cd_desc with
    | Core.CDFunc func ->
        let consumed = consumed_param_indices_for_function consumed_params func in
        if consumed = [] then acc else (func.cf_def_id, consumed) :: acc
    | Core.CDPrivate inner -> collect_decl acc inner
    | Core.CDVar _ | Core.CDImpl _ | Core.CDTrait _ | Core.CDType _
    | Core.CDRecord _ | Core.CDImport _ | Core.CDTypeAlias _ ->
        acc
  in
  List.fold_left collect_decl [] program

let normalize_consumed_param_indices consumed_params =
  consumed_params
  |> List.map (fun (def_id, indices) ->
         (def_id, List.sort_uniq Int.compare indices))
  |> List.sort (fun (left_id, _) (right_id, _) ->
         Int.compare left_id right_id)

let merge_consumed_param_indices existing discovered =
  let add_entry acc (def_id, indices) =
    let previous = Option.value ~default:[] (List.assoc_opt def_id acc) in
    let merged_indices = previous @ indices |> List.sort_uniq Int.compare in
    (def_id, merged_indices)
    :: List.filter (fun (existing_id, _) -> existing_id <> def_id) acc
  in
  List.fold_left add_entry existing discovered
  |> normalize_consumed_param_indices

let collect_consumed_param_indices program =
  let rec fixed_point remaining consumed_params =
    if remaining <= 0 then consumed_params
    else
      let discovered =
        collect_consumed_param_indices_once consumed_params program
      in
      let next = merge_consumed_param_indices consumed_params discovered in
      if next = consumed_params then consumed_params
      else fixed_point (remaining - 1) next
  in
  fixed_point (List.length program + 1) []

let call_kind_json ~consumed_params ~reg path ~result_ty ~loc
    (call_kind : Core.call_kind) =
  match call_kind with
  | Core.CKUser (name, def_id) ->
      Ok
        (kind "user"
           [
             ("name", str name);
             ("def_id", option_int_json def_id);
             ("consumed_args", int_list_json (consumed_args_for_user_call consumed_params def_id));
           ])
  | Core.CKForeign foreign ->
      Ok
        (kind "foreign"
           [
             ("name", str foreign.fc_c_name);
             ("arg_passing", foreign_arg_passing_json foreign.fc_arg_passing);
           ])
  | Core.CKBuiltin name -> (
      match Operation_result_metadata.find_result_bridge name with
      | Some bridge ->
          let* bridge_json =
            operation_result_bridge_json ~reg (path ^ ".bridge") ~result_ty bridge
          in
          Ok (kind "operation_result" [ ("bridge", bridge_json) ])
      | None -> (
          match Operation_result_metadata.find_fallible_stream_terminal name with
          | Some terminal ->
              let* bridge_json =
                fallible_stream_terminal_bridge_json ~reg (path ^ ".bridge")
                  ~result_ty ~loc terminal
              in
              Ok (kind "fallible_stream_terminal" [ ("bridge", bridge_json) ])
          | None when String.equal name "blorp_dict_get" && is_option_type result_ty
            ->
              Ok (kind "builtin" [ ("name", str name) ])
          | None
            when (String.equal name "blorp_option_some"
                 || String.equal name "blorp_option_none")
                 && is_option_type result_ty ->
              Ok (kind "builtin" [ ("name", str name) ])
          | None
            when (String.equal name "blorp_result_ok"
                 || String.equal name "blorp_result_err")
                 && is_result_type ~reg result_ty ->
              Ok (kind "builtin" [ ("name", str name) ])
          | None
            when (String.equal name "blorp_vector_get_opt"
                 || String.equal name "blorp_matrix_get_opt")
                 && generated_stack_option_get_supported ~reg result_ty ->
              Ok (kind "builtin" [ ("name", str name) ])
          | None when tensor_parallel_runtime_builtin_supported name ->
              Ok
                (kind "tensor_parallel"
                   [
                     ("name", str name);
                     ( "layout",
                       tensor_parallel_layout_json ~reg ~loc result_ty );
                   ])
          | None when channel_semantic_builtin_supported name ->
              Ok (kind "builtin" [ ("name", str name) ])
          | None when blorp_specialization_crosses_boundary ~reg name result_ty ->
              Ok (kind "builtin" [ ("name", str name) ])
          | None -> (
              match direct_runtime_abi ~reg ~loc result_ty name with
              | Some abi -> Ok (direct_runtime_call_kind_json abi)
          | None -> unsupported path ("builtin call " ^ name))
      )
      )
  | Core.CKIntrinsic name -> Ok (kind "intrinsic" [ ("name", str name) ])
  | Core.CKClosure -> Ok (kind "closure" [])
  | Core.CKUnknown -> unsupported path "unresolved call kind"
  | Core.CKSelectedDirect _ -> unsupported path "selected direct call kind"

let call_kind_json_for_call ~function_names ~consumed_params ~reg path ~result_ty
    ~loc ~callee call_kind (args : Core.core list) =
  match (call_kind, args) with
  | Core.CKBuiltin "blorp_list_to_string_cb", [ list_arg ] ->
      let* callback_name =
        list_to_string_callback_name function_names (path ^ ".callback")
          list_arg.ty
      in
      Ok (kind "list_to_string" [ ("callback_name", str callback_name) ])
  | Core.CKBuiltin "blorp_dict_with_capacity_custom", [ _capacity ] -> (
      match Core_emit_layout.canonical_type ~reg result_ty with
      | Ast.TyNamed ("Dict", [ key_ty; _value_ty ]) ->
          let* constructor_json =
            custom_hash_container_constructor_json ~reg
              (path ^ ".constructor") loc key_ty
          in
          Ok (kind "dict_with_capacity" [ ("constructor", constructor_json) ])
      | other ->
          unsupported path
            (Printf.sprintf "blorp_dict_with_capacity_custom on non-Dict type %s"
               (Types.type_to_string other)))
  | Core.CKBuiltin name, [ receiver ]
    when blorp_receiver_specialization_crosses_boundary ~reg name receiver.ty ->
      Ok (kind "builtin" [ ("name", str name) ])
  | Core.CKBuiltin name, [ receiver ]
    when blorp_receiver_specialization_builtin name ->
      unsupported path
        (Printf.sprintf "builtin call %s on unsupported receiver type %s" name
           (Types.type_to_string receiver.ty))
  | Core.CKUnknown, _ ->
      unsupported path
        ("unresolved call kind for callee `" ^ compact_callee_label callee ^ "`")
  | _ -> call_kind_json ~consumed_params ~reg path ~result_ty ~loc call_kind

let binop_tag = function
  | Ast.Add -> Ok "add"
  | Ast.Sub -> Ok "subtract"
  | Ast.Mul -> Ok "multiply"
  | Ast.Div -> Ok "divide"
  | Ast.Eq -> Ok "equal"
  | Ast.Ne -> Ok "not_equal"
  | Ast.Lt -> Ok "less"
  | Ast.Le -> Ok "less_equal"
  | Ast.Gt -> Ok "greater"
  | Ast.Ge -> Ok "greater_equal"
  | Ast.Mod -> Ok "modulo"

let unop_tag = function Ast.Neg -> "negate" | Ast.Not -> "not"
let logop_tag = function Ast.And -> "and" | Ast.Or -> "or"

let rec expr_json ~function_names ~consumed_params ~reg enum_names
    value_record_names heap_record_names union_names enum_constructors path
    (expr : Core.core) =
  let loc = source_loc_json expr.loc in
  let typed fields =
    let* typ =
      type_json ~reg enum_names value_record_names heap_record_names union_names (path ^ ".type")
        expr.ty
    in
    Ok (fields @ [ ("type", typ); ("loc", loc) ])
  in
  let literal_match_fallback_json (match_scrutinee : Core.core) path = function
    | Core.CTLeaf { ct_bindings = []; ct_body } ->
        let* body =
          expr_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
            enum_constructors (path ^ ".body") ct_body
        in
        Ok (kind "body" [ ("body", body) ])
    | Core.CTLeaf { ct_bindings; ct_body } ->
        let* body =
          expr_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
            enum_constructors (path ^ ".body") ct_body
        in
        let var_types = Core_emit_util.collect_var_types ct_body in
        let* bindings =
          match_bindings_json ~reg enum_names value_record_names heap_record_names
            union_names match_scrutinee.ty var_types (path ^ ".bindings")
            ct_bindings
        in
        Ok (kind "bindings" [ ("bindings", bindings); ("body", body) ])
    | Core.CTFail -> Ok (kind "fail" [])
    | Core.CTSwitchTag _ -> unsupported path "nested constructor match fallback"
    | Core.CTSwitchLit _ as subtree ->
        let nested_match = { expr with desc = Core.CMatch (match_scrutinee, subtree) } in
        let* body =
          expr_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names
            union_names enum_constructors path nested_match
        in
        Ok (kind "body" [ ("body", body) ])
    | Core.CTSwitchLen _ as subtree ->
        let nested_match = { expr with desc = Core.CMatch (match_scrutinee, subtree) } in
        let* body =
          expr_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names
            union_names enum_constructors path nested_match
        in
        Ok (kind "body" [ ("body", body) ])
  in
  match expr.desc with
  | Core.CLit literal ->
      let* literal_value = literal_json (path ^ ".literal") literal in
      let* fields = typed [ ("literal", literal_value) ] in
      Ok (kind "literal" fields)
  | Core.CVar variable ->
      let* fields =
        typed
          [
            ( "var",
              var_json_for_expr ~reg enum_constructors expr.ty variable );
          ]
      in
      Ok (kind "var" fields)
  | Core.CVoid ->
      let* fields = typed [] in
      Ok (kind "void" fields)
  | Core.CCooperativeCheckpoint ->
      let* fields = typed [] in
      Ok (kind "cooperative_checkpoint" fields)
  | Core.CCall (Core.CKIntrinsic "list_retain_for", _callee, [ lst; value ]) ->
      let* retain =
        list_retain_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
          enum_constructors (path ^ ".retain") lst value
      in
      let* fields = typed [ ("retain", retain) ] in
      Ok (kind "list_retain" fields)
  | Core.CCall
      (Core.CKIntrinsic ("list_set" as intrinsic_name), _callee, [ lst; index; value ])
  | Core.CCall
      ( Core.CKIntrinsic ("list_set_owned" as intrinsic_name),
        _callee,
        [ lst; index; value ] ) ->
      let layout =
        Core_layout_type.list_storage_layout_of_type ~reg lst.ty lst.loc
      in
      let* set =
        list_set_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
          enum_constructors (path ^ ".set")
          ~transfers_ownership:(String.equal intrinsic_name "list_set_owned")
          layout lst index value
      in
      let* fields = typed [ ("set", set) ] in
      Ok (kind "list_set" fields)
  | Core.CCall
      (Core.CKIntrinsic "list_handoff_set_owned", _callee, [ lst; index; value ])
    ->
      let layout =
        Core_layout_type.list_storage_layout_of_type ~reg lst.ty lst.loc
      in
      let* set =
        list_set_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
          enum_constructors (path ^ ".set") ~transfers_ownership:true layout
          lst index value
      in
      let* fields = typed [ ("set", set) ] in
      Ok (kind "list_handoff_set_owned" fields)
  | Core.CCall (Core.CKIntrinsic "list_swap_slots", _callee, [ lst; i; j ]) ->
      let layout =
        Core_layout_type.list_storage_layout_of_type ~reg lst.ty lst.loc
      in
      let* swap =
        list_swap_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names
          union_names enum_constructors (path ^ ".swap") layout lst i j
      in
      let* fields = typed [ ("swap", swap) ] in
      Ok (kind "list_swap" fields)
  | Core.CCall
      ( Core.CKIntrinsic "list_handoff_set_source_slot",
        _callee,
        [ result; out_index; source; source_index ] ) ->
      let* slot =
        list_handoff_set_source_slot_json ~function_names ~consumed_params ~reg enum_names value_record_names
          heap_record_names union_names enum_constructors (path ^ ".slot")
          result out_index source source_index
      in
      let* fields = typed [ ("slot", slot) ] in
      Ok (kind "list_handoff_set_source_slot" fields)
  | Core.CCall (Core.CKIntrinsic "string_get_byte", _callee, [ source; index ])
    ->
      let read =
        {
          Core.sbr_source = source;
          sbr_index = index;
          sbr_proof = Core.StringReadBoundsProven;
        }
      in
      let* read_json =
        string_byte_read_json ~function_names ~consumed_params ~reg enum_names value_record_names
          heap_record_names union_names enum_constructors (path ^ ".read") read
      in
      let* fields = typed [ ("read", read_json) ] in
      Ok (kind "string_byte_read" fields)
  | Core.CCall
      (Core.CKIntrinsic "string_set_byte", _callee, [ target; index; byte ]) ->
      let write =
        {
          Core.sbw_target = target;
          sbw_index = index;
          sbw_byte = byte;
          sbw_proof = Core.StringWriteBoundsProven;
        }
      in
      let* write_json =
        string_byte_write_json ~function_names ~consumed_params ~reg enum_names value_record_names
          heap_record_names union_names enum_constructors (path ^ ".write")
          write
      in
      let* fields = typed [ ("write", write_json) ] in
      Ok (kind "string_byte_write" fields)
  | Core.CCall
      ( Core.CKIntrinsic "string_copy_bytes",
        _callee,
        [ dst; dst_pos; src; src_pos; len ] ) ->
      let copy =
        {
          Core.sbc_dst = dst;
          sbc_dst_pos = dst_pos;
          sbc_src = src;
          sbc_src_pos = src_pos;
          sbc_len = len;
          sbc_proof = Core.StringCopyBoundsProven;
        }
      in
      let* copy_json =
        string_byte_copy_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names
          union_names enum_constructors (path ^ ".copy") copy
      in
      let* fields = typed [ ("copy", copy_json) ] in
      Ok (kind "string_byte_copy" fields)
  | Core.CCall (Core.CKIntrinsic "string_set_len", _callee, [ target; len ]) ->
      let set_len =
        {
          Core.ssl_target = target;
          ssl_len = len;
          ssl_proof = Core.StringSetLenBoundsProven;
        }
      in
      let* set_len_json =
        string_set_len_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names
          union_names enum_constructors (path ^ ".set_len") set_len
      in
      let* fields = typed [ ("set_len", set_len_json) ] in
      Ok (kind "string_set_len" fields)
  | Core.CCall
      ( (Core.CKBuiltin "blorp_list_new" | Core.CKIntrinsic "list_alloc"),
        _callee,
        [ capacity ] ) ->
      let layout =
        Core_layout_type.list_storage_layout_of_type ~reg expr.ty expr.loc
      in
      let alloc = { Core.la_layout = layout; la_capacity = capacity } in
      let* alloc_json =
        list_alloc_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
          enum_constructors (path ^ ".alloc") expr.loc alloc
      in
      let* fields = typed [ ("alloc", alloc_json) ] in
      Ok (kind "list_alloc" fields)
  | Core.CCall (Core.CKIntrinsic "list_get", _callee, [ lst; index ]) ->
      let get =
        {
          Core.lg_layout =
            Core_layout_type.list_storage_layout_of_type ~reg lst.ty lst.loc;
          lg_list = lst;
          lg_index = index;
          lg_bounds = Core.ListBoundsChecked;
        }
      in
      let* get_json =
        list_get_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
          enum_constructors (path ^ ".get") get
      in
      let* fields = typed [ ("get", get_json) ] in
      Ok (kind "list_get" fields)
  | Core.CCall (Core.CKIntrinsic "list_get_unchecked", _callee, [ lst; index ])
    ->
      let get =
        {
          Core.lg_layout =
            Core_layout_type.list_storage_layout_of_type ~reg lst.ty lst.loc;
          lg_list = lst;
          lg_index = index;
          lg_bounds = Core.ListBoundsProven;
        }
      in
      let* get_json =
        list_get_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
          enum_constructors (path ^ ".get") get
      in
      let* fields = typed [ ("get", get_json) ] in
      Ok (kind "list_get" fields)
  | Core.CCall (Core.CKBuiltin name, _callee, value :: dims)
    when is_ranked_tensor_fill_factory_name name -> (
      let layout =
        Core_emit_layout.tensor_storage_layout_of_type_for_reg ~reg expr.ty
          expr.loc
      in
      match layout.tsl_slots with
      | Core.TensorRawScalarStorage raw_kind ->
          let* fill =
            tensor_raw_fill_json ~function_names ~consumed_params ~reg enum_names value_record_names
              heap_record_names union_names enum_constructors
              (path ^ ".fill") raw_kind value dims
          in
          let* fields = typed [ ("fill", fill) ] in
          Ok (kind "tensor_raw_fill" fields)
      | Core.TensorPackedStorage _ ->
          unsupported path "packed tensor fill factory"
      | Core.TensorWordStorage | Core.TensorInlineStructStorage _
      | Core.TensorBoxedStorage ->
          unsupported path "non-raw tensor fill factory")
  | Core.CCall (Core.CKIntrinsic "tensor_alloc", callee, [ size ]) ->
      let* builtin_name = tensor_alloc_runtime_builtin ~reg path expr in
      let* callee_json =
        expr_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
          enum_constructors (path ^ ".callee") callee
      in
      let* size_json =
        expr_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
          enum_constructors (path ^ ".args[0]") size
      in
      let* fields =
        typed
          [
            ( "call_kind",
              direct_runtime_call_kind_json
                {
                  direct_runtime_name = builtin_name;
                  direct_runtime_args = DirectRuntimeArgsAsWritten;
                  direct_runtime_result = DirectRuntimeResultAsWritten;
                } );
            ("callee", callee_json);
            ("args", arr [ size_json ]);
          ]
      in
      Ok (kind "call" fields)
  | Core.CCall (Core.CKBuiltin "blorp_dict_new_custom", _callee, _args) -> (
      match Core_emit_layout.canonical_type ~reg expr.ty with
      | Ast.TyNamed ("Dict", [ key_ty; _value_ty ]) ->
          let construct =
            {
              Core.dc_constructor = Core.DictCustom key_ty;
              dc_entries = [];
              dc_value_needs_release =
                Core_emit_layout.dict_value_needs_release ~reg expr.ty
                  expr.loc;
            }
          in
          let* construct_json =
            dict_construct_json ~function_names ~consumed_params ~reg enum_names value_record_names
              heap_record_names union_names enum_constructors
              (path ^ ".construct") expr.loc construct
          in
          let* fields = typed [ ("construct", construct_json) ] in
          Ok (kind "dict_construct" fields)
      | other ->
          unsupported path
            (Printf.sprintf "blorp_dict_new_custom on non-Dict type %s"
               (Types.type_to_string other)))
  | Core.CCall (Core.CKBuiltin "blorp_set_new_custom", _callee, _args) -> (
      match Core_emit_layout.canonical_type ~reg expr.ty with
      | Ast.TyNamed ("Set", [ elem_ty ]) ->
          let alloc = { Core.sa_constructor = Core.SetCustom elem_ty } in
          let* alloc_json = set_alloc_json ~reg (path ^ ".alloc") expr.loc alloc in
          let* fields = typed [ ("alloc", alloc_json) ] in
          Ok (kind "set_alloc" fields)
      | other ->
          unsupported path
            (Printf.sprintf "blorp_set_new_custom on non-Set type %s"
               (Types.type_to_string other)))
  | Core.CCall (call_kind, callee, args) ->
      let* call_kind_value =
        call_kind_json_for_call ~function_names ~consumed_params ~reg
          (path ^ ".call_kind") ~result_ty:expr.ty ~loc:expr.loc ~callee
          call_kind
          args
      in
      let* callee_value =
        expr_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
          enum_constructors (path ^ ".callee") callee
      in
      let* args_value =
        result_list args (fun index arg ->
            expr_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
              enum_constructors
              (Printf.sprintf "%s.args[%d]" path index)
              arg)
      in
      let* fields =
        typed
          [
            ("call_kind", call_kind_value);
            ("callee", callee_value);
            ("args", args_value);
          ]
      in
      Ok (kind "call" fields)
  | Core.CBin (op, left, right) -> (
      match binop_tag op with
      | Error reason -> unsupported path reason
      | Ok op_tag ->
          let* left_value =
            expr_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
              enum_constructors (path ^ ".left") left
          in
          let* right_value =
            expr_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
              enum_constructors (path ^ ".right") right
          in
          let* fields =
            typed
              [
                ("op", str op_tag); ("left", left_value); ("right", right_value);
              ]
          in
          Ok (kind "binary" fields))
  | Core.CUn (op, inner) ->
      let* inner_value =
        expr_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
          enum_constructors (path ^ ".expr") inner
      in
      let* fields =
        typed [ ("op", str (unop_tag op)); ("expr", inner_value) ]
      in
      Ok (kind "unary" fields)
  | Core.CLog (op, left, right) ->
      let* left_value =
        expr_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
          enum_constructors (path ^ ".left") left
      in
      let* right_value =
        expr_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
          enum_constructors (path ^ ".right") right
      in
      let* fields =
        typed
          [
            ("op", str (logop_tag op));
            ("left", left_value);
            ("right", right_value);
          ]
      in
      Ok (kind "logical" fields)
  | Core.CAssign (variable, rhs) ->
      let* rhs_value =
        expr_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
          enum_constructors (path ^ ".rhs") rhs
      in
      let* fields = typed [ ("var", var_json variable); ("rhs", rhs_value) ] in
      Ok (kind "assign" fields)
  | Core.CCast (inner, target_ty) ->
      let* inner_value =
        expr_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
          enum_constructors (path ^ ".expr") inner
      in
      let* typ =
        type_json ~reg enum_names value_record_names heap_record_names union_names (path ^ ".type")
          target_ty
      in
      Ok
        (kind "cast"
           [
             ("expr", inner_value);
             ("type", typ);
             ("loc", source_loc_json expr.loc);
           ])
  | Core.CField (inner, field_name) -> (
      match inner.ty with
      | Ast.TyRange _
        when String.equal field_name "start" || String.equal field_name "end" ->
          let* inner_value =
            expr_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
              enum_constructors (path ^ ".expr") inner
          in
          let* fields =
            typed [ ("expr", inner_value); ("field", str field_name) ]
          in
          Ok (kind "field" fields)
      | Ast.TyRange _ -> unsupported path ("unknown range field " ^ field_name)
      | Ast.TyNamed (name, []) when StringSet.mem name value_record_names ->
          let* inner_value =
            expr_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
              enum_constructors (path ^ ".expr") inner
          in
          let* fields =
            typed [ ("expr", inner_value); ("field", str field_name) ]
          in
          Ok (kind "field" fields)
      | Ast.TyNamed (name, []) when StringSet.mem name heap_record_names ->
          let* inner_value =
            expr_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
              enum_constructors (path ^ ".expr") inner
          in
          let* fields =
            typed [ ("expr", inner_value); ("field", str field_name) ]
          in
          Ok (kind "field" fields)
      | Ast.TyNamed ("Module", []) -> (
          match expr.ty with
          | Ast.TyFunc _ ->
              let* inner_value =
                expr_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names
                  union_names enum_constructors (path ^ ".expr") inner
              in
              let* fields =
                typed [ ("expr", inner_value); ("field", str field_name) ]
              in
              Ok (kind "field" fields)
          | _ ->
              let constructor_var = Core.Var.named field_name in
              let* fields =
                typed
                  [
                    ( "var",
                      var_json_for_expr ~reg enum_constructors expr.ty
                        constructor_var );
                  ]
              in
              Ok (kind "var" fields))
	      | Ast.TyTuple items ->
	          let* field_index =
	            tuple_field_index (path ^ ".field") (List.length items) field_name
	          in
	          let* field_ty =
	            match List.nth_opt items field_index with
	            | Some ty -> Ok ty
	            | None -> unsupported path "tuple field index out of bounds"
	          in
	          if
	            not
	              (supported_tuple_field_projection_type ~reg value_record_names
	                 heap_record_names union_names field_ty)
	          then
	            unsupported path
	              (Printf.sprintf
	                 "tuple field type outside Blorp backend subset: %s"
	                 (Types.type_to_string field_ty))
	          else
	            let* inner_value =
	              expr_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
	                enum_constructors (path ^ ".expr") inner
	            in
	            let* fields =
	              typed [ ("expr", inner_value); ("index", int field_index) ]
	            in
	            Ok (kind "tuple_field" fields)
      | _ ->
          unsupported path
            (Printf.sprintf
               "field access on non-record, range, or tuple: %s.%s"
               (Types.type_to_string inner.ty)
               field_name))
  | Core.CLet (binding, body) ->
      let* typ =
        type_json ~reg enum_names value_record_names heap_record_names union_names (path ^ ".type")
          binding.bind_ty
      in
      let* rhs =
        expr_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
          enum_constructors (path ^ ".rhs") binding.bind_rhs
      in
      let* body =
        expr_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
          enum_constructors (path ^ ".body") body
      in
      Ok
        (kind "let"
           [
             ("name", var_json binding.bind_var);
             ("mutable", bool binding.bind_mut);
             ("type", typ);
             ("rhs", rhs);
             ("body", body);
           ])
  | Core.CBorrowLet (binding, body) ->
      let* typ =
        type_json ~reg enum_names value_record_names heap_record_names union_names (path ^ ".type")
          binding.borrow_ty
      in
      let* rhs =
        expr_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
          enum_constructors (path ^ ".rhs") binding.borrow_rhs
      in
      let* body =
        expr_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
          enum_constructors (path ^ ".body") body
      in
      Ok
        (kind "borrow_let"
           [
             ("name", var_json binding.borrow_var);
             ("type", typ);
             ("rhs", rhs);
             ("body", body);
           ])
  | Core.CSeq (first, second) ->
      let* first_value =
        expr_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
          enum_constructors (path ^ ".first") first
      in
      let* second_value =
        expr_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
          enum_constructors (path ^ ".second") second
      in
      Ok (kind "seq" [ ("first", first_value); ("second", second_value) ])
  | Core.CIf (cond, then_expr, else_expr) ->
      let* cond_value =
        expr_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
          enum_constructors (path ^ ".cond") cond
      in
      let* then_value =
        expr_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
          enum_constructors (path ^ ".then") then_expr
      in
      let* else_value =
        expr_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
          enum_constructors (path ^ ".else") else_expr
      in
      let* fields =
        typed
          [ ("cond", cond_value); ("then", then_value); ("else", else_value) ]
      in
      Ok (kind "if" fields)
  | Core.CWhile (cond, body) ->
      let* cond_value =
        expr_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
          enum_constructors (path ^ ".cond") cond
      in
      let* body_value =
        expr_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
          enum_constructors (path ^ ".body") body
      in
      let* fields = typed [ ("cond", cond_value); ("body", body_value) ] in
      Ok (kind "while" fields)
  | Core.CFor (binder, { desc = Core.CRange (lo, hi); _ }, body) ->
      let* binder_value =
        loop_binder_json ~reg enum_names value_record_names heap_record_names union_names
          (path ^ ".binder") binder
      in
      let* start_value =
        expr_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
          enum_constructors (path ^ ".start") lo
      in
      let* end_value =
        expr_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
          enum_constructors (path ^ ".end") hi
      in
      let* body_value =
        expr_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
          enum_constructors (path ^ ".body") body
      in
      let* fields =
        typed
          [
            ("binder", binder_value);
            ("start", start_value);
            ("end", end_value);
            ("body", body_value);
          ]
      in
      Ok (kind "for_range" fields)
  | Core.CFor (binder, iter, body) -> (
      match Codegen_types.normalize_type iter.ty with
      | Ast.TyNamed ("Channel", _) ->
          let* for_channel =
            for_channel_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names
              union_names enum_constructors (path ^ ".for_channel") binder iter
              body
          in
          let* fields = typed [ ("for_channel", for_channel) ] in
          Ok (kind "for_channel" fields)
      | Ast.TyNamed ("List", _) ->
          let layout =
            Core_layout_type.list_storage_layout_of_type ~reg iter.ty iter.loc
          in
          let* for_list =
            for_list_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
              enum_constructors (path ^ ".for_list") binder layout iter body
          in
          let* fields = typed [ ("for_list", for_list) ] in
          Ok (kind "for_list" fields)
      | Ast.TyNamed ("String", _) ->
          let* for_string =
            for_string_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names
              union_names enum_constructors (path ^ ".for_string") binder iter
              body
          in
          let* fields = typed [ ("for_string", for_string) ] in
          Ok (kind "for_string" fields)
      | Ast.TyNamed ("Dict", _) ->
          let* for_dict =
            for_dict_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names
              union_names enum_constructors (path ^ ".for_dict") binder iter body
          in
          let* fields = typed [ ("for_dict", for_dict) ] in
          Ok (kind "for_dict" fields)
      | Ast.TyNamed ("Set", _) ->
          let* for_set =
            for_set_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names
              union_names enum_constructors (path ^ ".for_set") binder iter body
          in
          let* fields = typed [ ("for_set", for_set) ] in
          Ok (kind "for_set" fields)
      | Ast.TyNamed ("Range", []) ->
          let range_field field_name =
            {
              Core.desc = Core.CField (iter, field_name);
              ty = Ast.TyNamed ("Int", []);
              loc = iter.loc;
            }
          in
          let* binder_value =
            loop_binder_json ~reg enum_names value_record_names heap_record_names union_names
              (path ^ ".binder") binder
          in
          let* start_value =
            expr_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
              enum_constructors (path ^ ".start") (range_field "start")
          in
          let* end_value =
            expr_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
              enum_constructors (path ^ ".end") (range_field "end")
          in
          let* body_value =
            expr_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
              enum_constructors (path ^ ".body") body
          in
          let* fields =
            typed
              [
                ("binder", binder_value);
                ("start", start_value);
                ("end", end_value);
                ("body", body_value);
              ]
          in
          Ok (kind "for_range" fields)
      | Ast.TyNamed (name, _) when Type_name_metadata.is_stream_name name ->
          let* for_stream =
            for_stream_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names
              union_names enum_constructors (path ^ ".for_stream") binder iter
              body
          in
          let* fields = typed [ ("for_stream", for_stream) ] in
          Ok (kind "for_stream" fields)
      | Ast.TyNamed (name, [ _resource_ty; _error_ty ])
        when Type_name_metadata.is_resource_source_name name ->
          let* for_resource_source =
            for_resource_source_json ~function_names ~consumed_params ~reg enum_names value_record_names
              heap_record_names union_names enum_constructors
              (path ^ ".for_resource_source") binder iter body
          in
          let* fields =
            typed [ ("for_resource_source", for_resource_source) ]
          in
          Ok (kind "for_resource_source" fields)
      | ty when Core_tensor_type.is_type ~reg ty ->
          let* for_tensor =
            for_tensor_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names
              union_names enum_constructors (path ^ ".for_tensor") binder iter
              body
          in
          let* fields = typed [ ("for_tensor", for_tensor) ] in
          Ok (kind "for_tensor" fields)
      | ty ->
          unsupported path
            (Printf.sprintf "non-range for loop over %s"
               (Types.type_to_string ty)))
  | Core.CRange (lo, hi) -> (
      match expr.ty with
      | Ast.TyRange _ ->
          let* start_value =
            expr_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
              enum_constructors (path ^ ".start") lo
          in
          let* end_value =
            expr_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
              enum_constructors (path ^ ".end") hi
          in
          let* fields = typed [ ("start", start_value); ("end", end_value) ] in
          Ok (kind "range" fields)
      | Ast.TyNamed (name, []) when StringSet.mem name value_record_names ->
          let* start_value =
            expr_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
              enum_constructors (path ^ ".start") lo
          in
          let* end_value =
            expr_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
              enum_constructors (path ^ ".end") hi
          in
          let* fields = typed [ ("start", start_value); ("end", end_value) ] in
          Ok (kind "range" fields)
      | _ -> unsupported path "range expression with non-range type")
  | Core.CMatch (scrutinee, Core.CTLeaf { ct_bindings; ct_body }) ->
      let* scrutinee_value =
        expr_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
          enum_constructors (path ^ ".scrutinee") scrutinee
      in
      let* body_value =
        expr_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
          enum_constructors (path ^ ".match.fallback.body") ct_body
      in
      let var_types = Core_emit_util.collect_var_types ct_body in
      let* bindings_value =
        match_bindings_json ~reg enum_names value_record_names heap_record_names
          union_names scrutinee.ty var_types (path ^ ".match.fallback.bindings")
          ct_bindings
      in
      let* scrutinee_type =
        type_json ~reg enum_names value_record_names heap_record_names union_names
          (path ^ ".match.scrutinee_type") scrutinee.ty
      in
      let* result_type_value =
        type_json ~reg enum_names value_record_names heap_record_names union_names
          (path ^ ".match.type") expr.ty
      in
      let match_value =
        obj
          [
            ("accessor", kind "root" []);
            ("scrutinee_type", scrutinee_type);
            ("cases", arr []);
            ( "fallback",
              kind "bindings"
                [ ("bindings", bindings_value); ("body", body_value) ] );
            ("type", result_type_value);
            ("loc", source_loc_json expr.loc);
          ]
      in
      let release_policy = match_scrutinee_release_policy_json ~reg scrutinee in
      let* fields =
        typed
          [
            ("scrutinee", scrutinee_value);
            ("scrutinee_release_policy", release_policy);
            ("match", match_value);
          ]
      in
      Ok (kind "accessor_literal_match" fields)
  | Core.CMatch (scrutinee, (Core.CTSwitchLit _ as tree))
    when match scrutinee.desc with Core.CVar _ -> false | _ -> true ->
      let tmp_hash = Digest.to_hex (Digest.string path) in
      let tmp_name = "__blorp_match_scrut_" ^ String.sub tmp_hash 0 12 in
      let tmp_var = Core.Var.named tmp_name in
      let tmp_scrutinee =
        { Core.desc = Core.CVar tmp_var; ty = scrutinee.ty; loc = scrutinee.loc }
      in
      let* rhs =
        expr_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
          enum_constructors (path ^ ".scrutinee") scrutinee
      in
      let* scrutinee_type =
        type_json ~reg enum_names value_record_names heap_record_names union_names
          (path ^ ".scrutinee.type") scrutinee.ty
      in
      let nested_match = { expr with desc = Core.CMatch (tmp_scrutinee, tree) } in
      let* body =
        expr_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
          enum_constructors (path ^ ".body") nested_match
      in
      Ok
        (kind "let"
           [
             ("name", var_json tmp_var);
             ("mutable", bool false);
             ("type", scrutinee_type);
             ("rhs", rhs);
             ("body", body);
           ])
  | Core.CMatch
      ( scrutinee,
        Core.CTSwitchLit { ctl_scrut; ctl_cases; ctl_default } )
    ->
      let reusable_match_scrutinee =
        match scrutinee.desc with Core.CVar _ -> true | _ -> false
      in
      let literal_match_case_json (match_scrutinee : Core.core) index
          (literal, subtree) =
        let case_path = Printf.sprintf "%s.cases[%d]" path index in
        let* literal_value =
          literal_match_literal_json (case_path ^ ".literal") literal
        in
        match subtree with
        | Core.CTLeaf { ct_bindings; ct_body } ->
            let* body_value =
              expr_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names
                union_names enum_constructors (case_path ^ ".body") ct_body
            in
            let var_types = Core_emit_util.collect_var_types ct_body in
            let* bindings_value =
              match_bindings_json ~reg enum_names value_record_names
                heap_record_names union_names match_scrutinee.ty var_types
                (case_path ^ ".bindings") ct_bindings
            in
            Ok
              (obj
                 [
                   ("literal", literal_value);
                   ("bindings", bindings_value);
                   ("body", body_value);
                 ])
        | Core.CTFail -> unsupported (case_path ^ ".body") "literal match fail"
        | Core.CTSwitchLit _ when reusable_match_scrutinee ->
            let nested_match = { expr with desc = Core.CMatch (scrutinee, subtree) } in
            let* body_value =
              expr_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names
                union_names enum_constructors (case_path ^ ".body") nested_match
            in
            Ok
              (obj
                 [
                   ("literal", literal_value);
                   ("bindings", arr []);
                   ("body", body_value);
                 ])
        | Core.CTSwitchLit _ ->
            unsupported (case_path ^ ".body") "nested literal match"
        | Core.CTSwitchTag _ ->
            unsupported (case_path ^ ".body") "nested constructor match"
        | Core.CTSwitchLen _ ->
            unsupported (case_path ^ ".body") "nested length match"
      in
      let* scrutinee_value =
        expr_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
          enum_constructors (path ^ ".scrutinee") scrutinee
      in
      let* cases_value =
        result_list ctl_cases (literal_match_case_json scrutinee)
      in
      let* fallback_value =
        literal_match_fallback_json scrutinee (path ^ ".fallback") ctl_default
      in
      (match ctl_scrut with
      | Core.AccRoot ->
          let* fields =
            typed
              [
                ("scrutinee", scrutinee_value);
                ("cases", cases_value);
                ("fallback", fallback_value);
              ]
          in
          Ok (kind "literal_match" fields)
      | accessor ->
          let* accessor_value =
            match_accessor_json ~reg ~enum_names ~value_record_names
              ~heap_record_names ~union_names scrutinee.ty
              (path ^ ".match.accessor") accessor
          in
          let* scrutinee_type =
            match match_accessor_type ~reg scrutinee.ty accessor with
            | Some ty ->
                type_json ~reg enum_names value_record_names heap_record_names
                  union_names (path ^ ".match.scrutinee_type") ty
            | None ->
                unsupported (path ^ ".match.accessor")
                  "literal match accessor type unavailable"
          in
          let* result_type_value =
            type_json ~reg enum_names value_record_names heap_record_names
              union_names (path ^ ".match.type") expr.ty
          in
          let match_value =
            obj
              [
                ("accessor", accessor_value);
                ("scrutinee_type", scrutinee_type);
                ("cases", cases_value);
                ("fallback", fallback_value);
                ("type", result_type_value);
                ("loc", source_loc_json expr.loc);
              ]
          in
          let release_policy = match_scrutinee_release_policy_json ~reg scrutinee in
          let* fields =
            typed
              [
                ("scrutinee", scrutinee_value);
                ("scrutinee_release_policy", release_policy);
                ("match", match_value);
              ]
          in
          Ok (kind "accessor_literal_match" fields))
  | Core.CMatch
      ( scrutinee,
        Core.CTSwitchTag { cts_scrut; cts_cases; cts_default } )
    ->
      let no_release_policy = str "none" in
      let scrutinee_release_policy =
        match_scrutinee_release_policy_json ~reg scrutinee
      in
      let rec constructor_match_switch_json (match_scrutinee : Core.core)
          release_policy path cts_scrut cts_cases cts_default =
        let* scrutinee_value =
          expr_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
            enum_constructors (path ^ ".scrutinee") match_scrutinee
        in
        let* cases_value =
          result_list cts_cases (fun index (ctor, subtree) ->
              constructor_match_case_json match_scrutinee path cts_scrut index ctor
                subtree)
        in
        let* fallback_value =
          constructor_match_fallback_json match_scrutinee (path ^ ".fallback")
            cts_default
        in
        let* fields =
          typed
            [
              ("scrutinee", scrutinee_value);
              ("scrutinee_release_policy", release_policy);
              ("cases", cases_value);
              ("fallback", fallback_value);
            ]
        in
        Ok (kind "constructor_match" fields)
      and constructor_match_fallback_json (match_scrutinee : Core.core) path =
        function
        | None -> Ok (kind "fail" [])
        | Some Core.CTFail -> Ok (kind "fail" [])
        | Some (Core.CTLeaf { ct_bindings = []; ct_body }) ->
            let* body =
              expr_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
                enum_constructors (path ^ ".body") ct_body
            in
            Ok (kind "body" [ ("body", body) ])
        | Some (Core.CTLeaf { ct_bindings; ct_body }) ->
            let* body =
              expr_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names
                union_names enum_constructors (path ^ ".body") ct_body
            in
            let var_types = Core_emit_util.collect_var_types ct_body in
            let* bindings =
              match_bindings_json ~reg enum_names value_record_names
                heap_record_names union_names match_scrutinee.ty var_types
                (path ^ ".bindings") ct_bindings
            in
            Ok (kind "bindings" [ ("bindings", bindings); ("body", body) ])
        | Some (Core.CTSwitchTag { cts_scrut; cts_cases; cts_default }) ->
            let reusable_match_scrutinee =
              match match_scrutinee.desc with Core.CVar _ -> true | _ -> false
            in
            if reusable_match_scrutinee then
              let* body =
                constructor_match_switch_json match_scrutinee no_release_policy
                  path cts_scrut cts_cases cts_default
              in
              Ok (kind "body" [ ("body", body) ])
            else unsupported path "nested constructor match fallback"
        | Some (Core.CTSwitchLit { ctl_scrut; ctl_cases; ctl_default }) ->
            let reusable_match_scrutinee =
              match match_scrutinee.desc with Core.CVar _ -> true | _ -> false
            in
            if reusable_match_scrutinee then
              let* body =
                literal_match_switch_json match_scrutinee path ctl_scrut
                  ctl_cases ctl_default
              in
              Ok (kind "body" [ ("body", body) ])
            else unsupported path "nested literal match fallback"
        | Some (Core.CTSwitchLen _ as subtree) ->
            let nested_match =
              { expr with desc = Core.CMatch (match_scrutinee, subtree) }
            in
            let* body =
              expr_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names
                union_names enum_constructors path nested_match
            in
            Ok (kind "body" [ ("body", body) ])
      and literal_match_switch_json (match_scrutinee : Core.core) path ctl_scrut
          ctl_cases ctl_default =
        let* scrutinee_value =
          expr_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names
            union_names enum_constructors (path ^ ".scrutinee")
            match_scrutinee
        in
        let* cases_value =
          result_list ctl_cases (fun index (literal, subtree) ->
              literal_match_case_json match_scrutinee
                (Printf.sprintf "%s.cases[%d]" path index)
                literal subtree)
        in
        let* fallback_value =
          literal_match_fallback_json match_scrutinee (path ^ ".fallback")
            ctl_default
        in
        match ctl_scrut with
        | Core.AccRoot ->
            let* fields =
              typed
                [
                  ("scrutinee", scrutinee_value);
                  ("cases", cases_value);
                  ("fallback", fallback_value);
                ]
            in
            Ok (kind "literal_match" fields)
        | accessor ->
            let* accessor_value =
              match_accessor_json ~reg ~enum_names ~value_record_names
                ~heap_record_names ~union_names match_scrutinee.ty
                (path ^ ".match.accessor") accessor
            in
            let* scrutinee_type =
              match match_accessor_type ~reg match_scrutinee.ty accessor with
              | Some ty ->
                  type_json ~reg enum_names value_record_names heap_record_names
                    union_names (path ^ ".match.scrutinee_type") ty
              | None ->
                  unsupported (path ^ ".match.accessor")
                    "literal match accessor type unavailable"
            in
            let* result_type_value =
              type_json ~reg enum_names value_record_names heap_record_names
                union_names (path ^ ".match.type") expr.ty
            in
            let match_value =
              obj
                [
                  ("accessor", accessor_value);
                  ("scrutinee_type", scrutinee_type);
                  ("cases", cases_value);
                  ("fallback", fallback_value);
                  ("type", result_type_value);
                  ("loc", source_loc_json expr.loc);
                ]
            in
            let* fields =
              typed
                [
                  ("scrutinee", scrutinee_value);
                  ("scrutinee_release_policy", no_release_policy);
                  ("match", match_value);
                ]
            in
            Ok (kind "accessor_literal_match" fields)
      and literal_match_fallback_json (match_scrutinee : Core.core) path =
        function
        | Core.CTLeaf { ct_bindings = []; ct_body } ->
            let* body =
              expr_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names
                union_names enum_constructors (path ^ ".body") ct_body
            in
            Ok (kind "body" [ ("body", body) ])
        | Core.CTLeaf { ct_bindings; ct_body } ->
            let* body =
              expr_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names
                union_names enum_constructors (path ^ ".body") ct_body
            in
            let var_types = Core_emit_util.collect_var_types ct_body in
            let* bindings =
              match_bindings_json ~reg enum_names value_record_names
                heap_record_names union_names match_scrutinee.ty var_types
                (path ^ ".bindings") ct_bindings
            in
            Ok (kind "bindings" [ ("bindings", bindings); ("body", body) ])
        | Core.CTFail -> Ok (kind "fail" [])
        | Core.CTSwitchLit { ctl_scrut; ctl_cases; ctl_default } ->
            let reusable_match_scrutinee =
              match match_scrutinee.desc with Core.CVar _ -> true | _ -> false
            in
            if reusable_match_scrutinee then
              let* body =
                literal_match_switch_json match_scrutinee path ctl_scrut
                  ctl_cases ctl_default
              in
              Ok (kind "body" [ ("body", body) ])
            else unsupported path "nested literal match fallback"
        | Core.CTSwitchTag _ ->
            unsupported path "nested constructor match fallback"
        | Core.CTSwitchLen _ as subtree ->
            let nested_match =
              { expr with desc = Core.CMatch (match_scrutinee, subtree) }
            in
            let* body =
              expr_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names
                union_names enum_constructors path nested_match
            in
            Ok (kind "body" [ ("body", body) ])
      and literal_match_case_json (match_scrutinee : Core.core) case_path
          literal subtree =
        let* literal_value =
          literal_match_literal_json (case_path ^ ".literal") literal
        in
        match subtree with
        | Core.CTLeaf { ct_bindings; ct_body } ->
            let* body_value =
              expr_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names
                union_names enum_constructors (case_path ^ ".body") ct_body
            in
            let var_types = Core_emit_util.collect_var_types ct_body in
            let* bindings_value =
              match_bindings_json ~reg enum_names value_record_names
                heap_record_names union_names match_scrutinee.ty var_types
                (case_path ^ ".bindings") ct_bindings
            in
            Ok
              (obj
                 [
                   ("literal", literal_value);
                   ("bindings", bindings_value);
                   ("body", body_value);
                 ])
        | Core.CTFail -> unsupported (case_path ^ ".body") "literal match fail"
        | Core.CTSwitchLit { ctl_scrut; ctl_cases; ctl_default } ->
            let reusable_match_scrutinee =
              match match_scrutinee.desc with Core.CVar _ -> true | _ -> false
            in
            if reusable_match_scrutinee then (
              let* body_value =
                literal_match_switch_json match_scrutinee (case_path ^ ".body")
                ctl_scrut ctl_cases ctl_default
              in
              Ok
                (obj
                   [
                     ("literal", literal_value);
                     ("bindings", arr []);
                     ("body", body_value);
                   ]))
            else unsupported (case_path ^ ".body") "nested literal match"
        | Core.CTSwitchTag _ ->
            unsupported (case_path ^ ".body") "nested constructor match"
        | Core.CTSwitchLen _ ->
            unsupported (case_path ^ ".body") "nested length match"
      and constructor_match_case_json (match_scrutinee : Core.core) path
          cts_scrut index ctor subtree =
            let case_path = Printf.sprintf "%s.cases[%d]" path index in
            let* accessor_value =
              match_accessor_json ~reg ~enum_names ~value_record_names
                ~heap_record_names ~union_names match_scrutinee.ty
                (case_path ^ ".accessor") cts_scrut
            in
            let* test_ty =
              match match_accessor_type ~reg match_scrutinee.ty cts_scrut with
              | Some ty -> Ok ty
              | None ->
                  unsupported (case_path ^ ".accessor")
                    "constructor match accessor type unavailable"
            in
            let* constructor_test =
              constructor_match_test_json ~reg enum_names union_names enum_constructors
                (case_path ^ ".test") test_ty ctor
            in
            let* bindings, body_value =
              constructor_match_case_body_json match_scrutinee case_path subtree
            in
            let* bindings_value =
              match bindings with
              | [] -> Ok (arr [])
              | _ ->
                  let body =
                    match subtree with
                    | Core.CTLeaf { ct_body; _ } -> ct_body
                    | _ -> match_scrutinee
                  in
                  let var_types = Core_emit_util.collect_var_types body in
                  match_bindings_json ~reg enum_names value_record_names
                    heap_record_names union_names match_scrutinee.ty var_types
                    (case_path ^ ".bindings") bindings
            in
            Ok
              (obj
                 [
                   ("constructor", str ctor);
                   ("accessor", accessor_value);
                   ("test", constructor_test);
                   ("bindings", bindings_value);
                   ("body", body_value);
                 ])
      and constructor_length_match_branch_json (match_scrutinee : Core.core)
          branch_path subtree =
        let* bindings, body_value =
          constructor_match_case_body_json match_scrutinee branch_path subtree
        in
        let* bindings_value =
          match bindings with
          | [] -> Ok (arr [])
          | _ ->
              let body =
                match subtree with
                | Core.CTLeaf { ct_body; _ } -> ct_body
                | _ -> match_scrutinee
              in
              let var_types = Core_emit_util.collect_var_types body in
              match_bindings_json ~reg enum_names value_record_names
                heap_record_names union_names match_scrutinee.ty var_types
                (branch_path ^ ".bindings") bindings
        in
        Ok
          (obj
             [
               ("bindings", bindings_value);
               ("body", body_value);
             ])
      and constructor_length_match_geq_json (match_scrutinee : Core.core)
          path = function
        | None -> Ok null
        | Some (minimum_length, subtree) ->
            let branch_path = path ^ ".branch" in
            let* branch_value =
              constructor_length_match_branch_json match_scrutinee branch_path
                subtree
            in
            Ok
              (obj
                 [
                   ("minimum_length", int minimum_length);
                   ("branch", branch_value);
                 ])
      and constructor_length_match_fallback_json (match_scrutinee : Core.core)
          path = function
        | None -> Ok null
        | Some subtree ->
            constructor_length_match_branch_json match_scrutinee path subtree
      and constructor_length_match_body_json (match_scrutinee : Core.core)
          case_path ctl_len_scrut ctl_len_cases ctl_len_geq ctl_len_default =
        let* accessor_value =
          match_accessor_json ~reg ~enum_names ~value_record_names
            ~heap_record_names ~union_names match_scrutinee.ty
            (case_path ^ ".body.match.accessor") ctl_len_scrut
        in
        let* cases_value =
          result_list ctl_len_cases (fun index (length, subtree) ->
              let length_case_path =
                Printf.sprintf "%s.body.match.cases[%d]" case_path index
              in
              let* branch_value =
                constructor_length_match_branch_json match_scrutinee
                  (length_case_path ^ ".branch") subtree
              in
              Ok
                (obj
                   [
                     ("length", int length);
                     ("branch", branch_value);
                   ]))
        in
        let* geq_value =
          constructor_length_match_geq_json match_scrutinee
            (case_path ^ ".body.match.geq") ctl_len_geq
        in
        let* fallback_value =
          constructor_length_match_fallback_json match_scrutinee
            (case_path ^ ".body.match.fallback") ctl_len_default
        in
        let* result_type_value =
          type_json ~reg enum_names value_record_names heap_record_names
            union_names (case_path ^ ".body.match.type") expr.ty
        in
        let match_value =
          obj
            [
              ("accessor", accessor_value);
              ("cases", cases_value);
              ("geq", geq_value);
              ("fallback", fallback_value);
              ("type", result_type_value);
              ("loc", source_loc_json expr.loc);
            ]
        in
        Ok (kind "length_match" [ ("match", match_value) ])
      and constructor_match_case_body_json (match_scrutinee : Core.core)
          case_path = function
        | Core.CTLeaf { ct_bindings; ct_body } ->
            let* body_value =
              expr_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
                enum_constructors (case_path ^ ".body.expr") ct_body
            in
            Ok (ct_bindings, kind "expr" [ ("expr", body_value) ])
        | Core.CTSwitchTag { cts_scrut; cts_cases; cts_default } ->
            let reusable_match_scrutinee =
              match match_scrutinee.desc with Core.CVar _ -> true | _ -> false
            in
            if reusable_match_scrutinee then
              let* body_value =
                constructor_match_switch_json match_scrutinee no_release_policy
                  (case_path ^ ".body") cts_scrut cts_cases cts_default
              in
              Ok ([], kind "expr" [ ("expr", body_value) ])
            else unsupported (case_path ^ ".body") "nested constructor match"
        | Core.CTFail -> unsupported (case_path ^ ".body") "constructor match fail case"
        | Core.CTSwitchLit { ctl_scrut; ctl_cases; ctl_default } ->
            let* accessor_value =
              match_accessor_json ~reg ~enum_names ~value_record_names
                ~heap_record_names ~union_names match_scrutinee.ty
                (case_path ^ ".body.match.accessor") ctl_scrut
            in
            let* payload_ty =
              match match_accessor_type ~reg match_scrutinee.ty ctl_scrut with
              | Some ty -> Ok ty
              | None ->
                  unsupported (case_path ^ ".body.match.accessor")
                    "literal match accessor type unavailable"
            in
            let* scrutinee_type_value =
              type_json ~reg enum_names value_record_names heap_record_names
                union_names (case_path ^ ".body.match.scrutinee_type") payload_ty
            in
            let* result_type_value =
              type_json ~reg enum_names value_record_names heap_record_names
                union_names (case_path ^ ".body.match.type") expr.ty
            in
            let* cases_value =
              result_list ctl_cases (fun index (literal, subtree) ->
                  let literal_case_path =
                    Printf.sprintf "%s.body.match.cases[%d]" case_path index
                  in
                  literal_match_case_json match_scrutinee literal_case_path
                    literal subtree)
            in
            let* fallback_value =
              literal_match_fallback_json match_scrutinee
                (case_path ^ ".body.match.fallback") ctl_default
            in
            let match_value =
              obj
                [
                  ("accessor", accessor_value);
                  ("scrutinee_type", scrutinee_type_value);
                  ("cases", cases_value);
                  ("fallback", fallback_value);
                  ("type", result_type_value);
                  ("loc", source_loc_json expr.loc);
                ]
            in
            Ok ([], kind "literal_match" [ ("match", match_value) ])
        | Core.CTSwitchLen
            {
              ctl_len_scrut;
              ctl_len_cases;
              ctl_len_geq;
              ctl_len_default;
            } ->
            let* body_value =
              constructor_length_match_body_json match_scrutinee case_path
                ctl_len_scrut ctl_len_cases ctl_len_geq ctl_len_default
            in
            Ok ([], body_value)
      in
      let constructor_match_body (match_scrutinee : Core.core) release_policy
          body_path =
        constructor_match_switch_json match_scrutinee release_policy body_path
          cts_scrut cts_cases cts_default
      in
      (match scrutinee.desc with
      | Core.CVar _ -> constructor_match_body scrutinee scrutinee_release_policy path
      | _ ->
          let tmp_hash = Digest.to_hex (Digest.string path) in
          let tmp_name =
            "__blorp_match_scrut_" ^ String.sub tmp_hash 0 12
          in
          let tmp_var = Core.Var.named tmp_name in
          let tmp_scrutinee =
            { Core.desc = Core.CVar tmp_var; ty = scrutinee.ty; loc = scrutinee.loc }
          in
          let* rhs =
            expr_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
              enum_constructors (path ^ ".scrutinee") scrutinee
          in
          let* scrutinee_type =
            type_json ~reg enum_names value_record_names heap_record_names union_names
              (path ^ ".scrutinee.type") scrutinee.ty
          in
          let* body =
            constructor_match_body tmp_scrutinee scrutinee_release_policy
              (path ^ ".body")
          in
          Ok
            (kind "let"
               [
                 ("name", var_json tmp_var);
                 ("mutable", bool false);
                 ("type", scrutinee_type);
                 ("rhs", rhs);
                 ("body", body);
               ]))
  | Core.CMatch
      ( scrutinee,
        Core.CTSwitchLen
          { ctl_len_scrut; ctl_len_cases; ctl_len_geq; ctl_len_default } )
    ->
      let rec length_match_branch_json (match_scrutinee : Core.core) branch_path
          subtree =
        let* bindings, body_value =
          length_match_body_json match_scrutinee branch_path subtree
        in
        let* bindings_value =
          match bindings with
          | [] -> Ok (arr [])
          | _ ->
              let body =
                match subtree with
                | Core.CTLeaf { ct_body; _ } -> ct_body
                | _ -> match_scrutinee
              in
              let var_types = Core_emit_util.collect_var_types body in
              match_bindings_json ~reg enum_names value_record_names
                heap_record_names union_names match_scrutinee.ty var_types
                (branch_path ^ ".bindings") bindings
        in
        Ok (obj [ ("bindings", bindings_value); ("body", body_value) ])
      and length_match_case_json match_scrutinee path index
          (length, subtree) =
        let case_path = Printf.sprintf "%s.cases[%d]" path index in
        let* branch_value =
          length_match_branch_json match_scrutinee (case_path ^ ".branch")
            subtree
        in
        Ok
          (obj
             [
               ("length", int length);
               ("branch", branch_value);
             ])
      and length_match_geq_json match_scrutinee path = function
        | None -> Ok null
        | Some (minimum_length, subtree) ->
            let* branch_value =
              length_match_branch_json match_scrutinee (path ^ ".branch")
                subtree
            in
            Ok
              (obj
                 [
                   ("minimum_length", int minimum_length);
                   ("branch", branch_value);
                 ])
      and length_match_fallback_json match_scrutinee path = function
        | None | Some Core.CTFail -> Ok null
        | Some subtree -> length_match_branch_json match_scrutinee path subtree
      and length_match_value_json (match_scrutinee : Core.core) match_path
          len_scrut len_cases len_geq len_default =
        let* accessor_value =
          match_accessor_json ~reg ~enum_names ~value_record_names
            ~heap_record_names ~union_names match_scrutinee.ty
            (match_path ^ ".accessor") len_scrut
        in
        let* cases_value =
          result_list len_cases
            (length_match_case_json match_scrutinee match_path)
        in
        let* geq_value =
          length_match_geq_json match_scrutinee (match_path ^ ".geq") len_geq
        in
        let* fallback_value =
          length_match_fallback_json match_scrutinee
            (match_path ^ ".fallback") len_default
        in
        let* result_type_value =
          type_json ~reg enum_names value_record_names heap_record_names
            union_names (match_path ^ ".type") expr.ty
        in
        Ok
          (obj
             [
               ("accessor", accessor_value);
               ("cases", cases_value);
               ("geq", geq_value);
               ("fallback", fallback_value);
               ("type", result_type_value);
               ("loc", source_loc_json expr.loc);
             ])
      and length_match_body_json (match_scrutinee : Core.core) branch_path =
        function
        | Core.CTLeaf { ct_bindings; ct_body } ->
            let* body_value =
              expr_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names
                union_names enum_constructors (branch_path ^ ".body.expr")
                ct_body
            in
            Ok (ct_bindings, kind "expr" [ ("expr", body_value) ])
        | Core.CTSwitchLen
            {
              ctl_len_scrut;
              ctl_len_cases;
              ctl_len_geq;
              ctl_len_default;
            } ->
            let* match_value =
              length_match_value_json match_scrutinee
                (branch_path ^ ".body.match") ctl_len_scrut ctl_len_cases
                ctl_len_geq ctl_len_default
            in
            Ok ([], kind "length_match" [ ("match", match_value) ])
        | Core.CTFail ->
            unsupported (branch_path ^ ".body") "length match fail case"
        | Core.CTSwitchTag _ as subtree ->
            let nested_match =
              { expr with desc = Core.CMatch (match_scrutinee, subtree) }
            in
            let* body_value =
              expr_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names
                union_names enum_constructors (branch_path ^ ".body.expr")
                nested_match
            in
            Ok ([], kind "expr" [ ("expr", body_value) ])
        | Core.CTSwitchLit _ as subtree ->
            let nested_match =
              { expr with desc = Core.CMatch (match_scrutinee, subtree) }
            in
            let* body_value =
              expr_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names
                union_names enum_constructors (branch_path ^ ".body.expr")
                nested_match
            in
            Ok ([], kind "expr" [ ("expr", body_value) ])
      in
      let* scrutinee_value =
        expr_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
          enum_constructors (path ^ ".scrutinee") scrutinee
      in
      let* match_value =
        length_match_value_json scrutinee (path ^ ".match") ctl_len_scrut
          ctl_len_cases ctl_len_geq ctl_len_default
      in
      let release_policy = match_scrutinee_release_policy_json ~reg scrutinee in
      let* fields =
        typed
          [
            ("scrutinee", scrutinee_value);
            ("scrutinee_release_policy", release_policy);
            ("match", match_value);
          ]
      in
      Ok (kind "length_match" fields)
  | Core.CBreak ->
      let* fields = typed [] in
      Ok (kind "break" fields)
  | Core.CContinue ->
      let* fields = typed [] in
      Ok (kind "continue" fields)
  | Core.CDup (variable, value_ty, body) ->
      let* value_type =
        type_json ~reg enum_names value_record_names heap_record_names union_names
          (path ^ ".value_type") value_ty
      in
      let retain_policy =
        retain_policy_json_for_var ~reg enum_constructors value_ty variable
      in
      let* body_value =
        expr_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
          enum_constructors (path ^ ".body") body
      in
      let* fields =
        typed
          [
            ("var", var_json variable);
            ("value_type", value_type);
            ("retain_policy", retain_policy);
            ("body", body_value);
          ]
      in
      Ok (kind "dup" fields)
  | Core.CDrop (variable, value_ty, body) ->
      let* value_type =
        type_json ~reg enum_names value_record_names heap_record_names union_names
          (path ^ ".value_type") value_ty
      in
      let release_policy =
        release_policy_json_for_var ~reg enum_constructors value_ty variable
      in
      let* body_value =
        expr_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
          enum_constructors (path ^ ".body") body
      in
      let* fields =
        typed
          [
            ("var", var_json variable);
            ("value_type", value_type);
            ("release_policy", release_policy);
            ("body", body_value);
          ]
      in
      Ok (kind "drop" fields)
  | Core.CTailrecLoop
      (Core.TailrecUnmanagedLoop { tul_params; tul_return_ty; tul_body }) ->
      let* params =
        result_list tul_params (fun index param ->
            param_json ~reg enum_names value_record_names heap_record_names union_names
              (Printf.sprintf "%s.params[%d]" path index)
              param)
      in
      let* return_type =
        type_json ~reg enum_names value_record_names heap_record_names union_names
          (path ^ ".return_type") tul_return_ty
      in
      let* body_value =
        expr_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
          enum_constructors (path ^ ".body") tul_body
      in
      Ok
        (kind "tailrec_loop"
           [
             ("params", params);
             ("return_type", return_type);
             ("body", body_value);
             ("loc", loc);
           ])
  | Core.CTailrecLoop
      (Core.TailrecListSpreadLoop
         {
           tls_params;
           tls_return_ty;
           tls_list_index;
           tls_list_param;
           tls_cursor_var;
           tls_body;
         }) ->
      let* params =
        result_list tls_params (fun index param ->
            param_json ~reg enum_names value_record_names heap_record_names union_names
              (Printf.sprintf "%s.loop.params[%d]" path index)
              param)
      in
      let* return_type =
        type_json ~reg enum_names value_record_names heap_record_names union_names
          (path ^ ".loop.return_type") tls_return_ty
      in
      let* list_param =
        param_json ~reg enum_names value_record_names heap_record_names union_names
          (path ^ ".loop.list_param") tls_list_param
      in
      let list_layout =
        Core_layout_type.list_storage_layout_of_type ~reg tls_list_param.cp_ty
          tls_list_param.cp_loc
      in
      let* layout = list_storage_layout_json list_layout in
      let* body_value =
        expr_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
          enum_constructors (path ^ ".loop.body") tls_body
      in
      Ok
        (kind "tailrec_list_spread_loop"
           [
             ( "loop",
               obj
                 [
                   ("params", params);
                   ("return_type", return_type);
                   ("list_index", int tls_list_index);
                   ("list_param", list_param);
                   ("cursor", var_json tls_cursor_var);
                   ("layout", layout);
                   ("body", body_value);
                 ] );
             ("loc", loc);
           ])
  | Core.CTailrecRecur (Core.TailrecRecur { tr_args }) ->
      let* args_value =
        result_list tr_args (fun index arg ->
            expr_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
              enum_constructors
              (Printf.sprintf "%s.args[%d]" path index)
              arg)
      in
      let* fields = typed [ ("args", args_value) ] in
      Ok (kind "tailrec_recur" fields)
  | Core.CTailrecRecur
      (Core.TailrecListSpreadRecur { tr_rebinds; tr_cursor_advance }) ->
	      let* rebinds =
	        result_list tr_rebinds (fun index (param_index, value) ->
	            let* value_json =
	              expr_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names
	                union_names enum_constructors
	                (Printf.sprintf "%s.rebinds[%d].value" path index)
	                value
	            in
            Ok (obj [ ("param_index", int param_index); ("value", value_json) ]))
      in
      let* typ =
        type_json ~reg enum_names value_record_names heap_record_names union_names
          (path ^ ".type") expr.ty
      in
      Ok
        (kind "tailrec_list_spread_recur"
           [
             ("rebinds", rebinds);
             ("cursor_advance", int tr_cursor_advance);
             ("type", typ);
             ("loc", loc);
           ])
  | Core.CTupleConstruct tc ->
      let* elements =
        result_list tc.tc_elems (fun index element ->
            let element_path =
              Printf.sprintf "%s.construct.elements[%d]" path index
            in
            let* element_tag =
              tuple_element_tag (element_path ^ ".kind") element.bsv_box.box_kind
            in
            let* value =
              expr_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
                enum_constructors (element_path ^ ".value")
                element.bsv_box.box_value
            in
            let fields =
              match element.bsv_box.box_kind with
              | Core.BoxVoid -> []
              | Core.BoxStruct c_type -> [ ("value", value); ("c_type", str c_type) ]
              | _ -> [ ("value", value) ]
            in
            Ok (kind element_tag fields))
      in
      let construct =
        obj
          [
            ("elements", elements);
            ("release_mask", int tc.tc_release_mask);
            ("retain_mask", int tc.tc_retain_mask);
          ]
      in
      let* fields = typed [ ("construct", construct) ] in
      Ok (kind "tuple_construct" fields)
  | Core.CTuple items ->
      let* items_value =
        result_list items (fun index item ->
            expr_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
              enum_constructors
              (Printf.sprintf "%s.items[%d]" path index)
              item)
      in
      let* fields = typed [ ("items", items_value) ] in
      Ok (kind "tuple" fields)
  | Core.CRecord fields -> (
      match (Core_emit_layout.canonical_type ~reg expr.ty, fields) with
      | Ast.TyNamed ("Dict", [ key_ty; _value_ty ]), [] ->
          let construct =
            {
              Core.dc_constructor =
                Core_hash_container_layout.dict_constructor_kind ~reg key_ty;
              dc_entries = [];
              dc_value_needs_release =
                Core_emit_layout.dict_value_needs_release ~reg expr.ty
                  expr.loc;
            }
          in
          let* construct_json =
            dict_construct_json ~function_names ~consumed_params ~reg enum_names value_record_names
              heap_record_names union_names enum_constructors
              (path ^ ".construct") expr.loc construct
          in
          let* fields = typed [ ("construct", construct_json) ] in
          Ok (kind "dict_construct" fields)
      | Ast.TyNamed ("Set", [ elem_ty ]), [] ->
          let alloc =
            {
              Core.sa_constructor =
                Core_hash_container_layout.set_constructor_kind ~reg elem_ty;
            }
          in
          let* alloc_json =
            set_alloc_json ~reg (path ^ ".alloc") expr.loc alloc
          in
          let* fields = typed [ ("alloc", alloc_json) ] in
          Ok (kind "set_alloc" fields)
      | Ast.TyNamed ("List", _), [] ->
          let alloc =
            {
              Core.la_layout =
                Core_layout_type.list_storage_layout_of_type ~reg expr.ty
                  expr.loc;
              la_capacity = Core.Build.lit_int ~loc:expr.loc 0;
            }
          in
          let* alloc_json =
            list_alloc_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names
              union_names enum_constructors (path ^ ".alloc") expr.loc alloc
          in
          let* fields = typed [ ("alloc", alloc_json) ] in
          Ok (kind "list_alloc" fields)
      | Ast.TyNamed (type_name, []), _ ->
          let* fields_value =
            result_list fields (fun index (name, value) ->
                let field_path = Printf.sprintf "%s.fields[%d]" path index in
                let* value_json =
                  expr_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
                    enum_constructors (field_path ^ ".value") value
                in
                Ok (obj [ ("name", str name); ("value", value_json) ]))
          in
          let* fields =
            typed [ ("type_name", str type_name); ("fields", fields_value) ]
          in
          Ok (kind "record_construct" fields)
      | _ -> unsupported path "record literal on non-value record")
  | Core.CRecordConstruct rc ->
      if
        (not (StringSet.mem rc.rc_type_name value_record_names))
        && not (StringSet.mem rc.rc_type_name heap_record_names)
      then unsupported path "record construction on unknown record type"
      else if Option.is_some rc.rc_erased_release_mask then
        unsupported path "record construction with erased fields"
      else
        let* fields_value =
          result_list rc.rc_fields (fun index field ->
              let field_path = Printf.sprintf "%s.fields[%d]" path index in
              match field with
              | Core.RecordRawField (name, value) ->
                  let* value_json =
                    expr_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
                      enum_constructors (field_path ^ ".value") value
                  in
                  Ok (obj [ ("name", str name); ("value", value_json) ])
              | Core.RecordErasedField _ ->
                  unsupported field_path "erased record field")
        in
        let* fields =
          typed [ ("type_name", str rc.rc_type_name); ("fields", fields_value) ]
        in
        Ok (kind "record_construct" fields)
  | Core.CList lit ->
      let* construct =
        list_literal_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
          enum_constructors (path ^ ".construct") expr.loc lit
      in
      let* fields = typed [ ("construct", construct) ] in
      Ok (kind "list_construct" fields)
  | Core.CListAlloc alloc ->
      let* alloc_json =
        list_alloc_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
          enum_constructors (path ^ ".alloc") expr.loc alloc
      in
      let* fields = typed [ ("alloc", alloc_json) ] in
      Ok (kind "list_alloc" fields)
  | Core.CListGet get ->
      let* get_json =
        list_get_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
          enum_constructors (path ^ ".get") get
      in
      let* fields = typed [ ("get", get_json) ] in
      Ok (kind "list_get" fields)
  | Core.CListHandoff handoff ->
      let* handoff_json =
        list_handoff_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
          enum_constructors (path ^ ".handoff") expr.loc handoff
      in
      let* fields = typed [ ("handoff", handoff_json) ] in
      Ok (kind "list_handoff" fields)
  | Core.CStringByteRead read ->
      let* read_json =
        string_byte_read_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
          enum_constructors (path ^ ".read") read
      in
      let* fields = typed [ ("read", read_json) ] in
      Ok (kind "string_byte_read" fields)
  | Core.CStringByteWrite write ->
      let* write_json =
        string_byte_write_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
          enum_constructors (path ^ ".write") write
      in
      let* fields = typed [ ("write", write_json) ] in
      Ok (kind "string_byte_write" fields)
  | Core.CStringByteCopy copy ->
      let* copy_json =
        string_byte_copy_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
          enum_constructors (path ^ ".copy") copy
      in
      let* fields = typed [ ("copy", copy_json) ] in
      Ok (kind "string_byte_copy" fields)
  | Core.CStringSetLen set_len ->
      let* set_len_json =
        string_set_len_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
          enum_constructors (path ^ ".set_len") set_len
      in
      let* fields = typed [ ("set_len", set_len_json) ] in
      Ok (kind "string_set_len" fields)
  | Core.CListConstruct lc ->
      let* construct =
        list_construct_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
          enum_constructors (path ^ ".construct") lc
      in
      let* fields = typed [ ("construct", construct) ] in
      Ok (kind "list_construct" fields)
  | Core.CVector items ->
      let* items_json =
        result_list items (fun index item ->
            expr_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
              enum_constructors
              (Printf.sprintf "%s.items[%d]" path index)
              item)
      in
      let* fields = typed [ ("items", items_json) ] in
      Ok (kind "vector" fields)
  | Core.CTensorLiteral literal -> (
      match literal.tl_payload with
      | Core.TensorBoxedElements elements ->
          let elem_needs_release =
            Core.tensor_storage_layout_requires_release_or_error
              ~phase:Core_error.Emit ~loc:expr.loc literal.tl_layout
          in
          let* literal_json =
            tensor_boxed_literal_json ~function_names ~consumed_params ~reg enum_names value_record_names
              heap_record_names union_names enum_constructors
              (path ^ ".literal") literal.tl_shape elements elem_needs_release
          in
          let* fields = typed [ ("literal", literal_json) ] in
          Ok (kind "tensor_boxed_literal" fields)
      | Core.TensorPackedElements (width, elements) ->
          let* literal_json =
            tensor_packed_literal_json ~function_names ~consumed_params ~reg enum_names value_record_names
              heap_record_names union_names enum_constructors
              (path ^ ".literal") literal.tl_shape width elements
          in
          let* fields = typed [ ("literal", literal_json) ] in
          Ok (kind "tensor_packed_literal" fields)
      | Core.TensorRawElements _ | Core.TensorInlineStructElements _ ->
          let* literal_json =
            tensor_literal_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names
              union_names enum_constructors (path ^ ".literal") literal
          in
          let* fields = typed [ ("literal", literal_json) ] in
          Ok (kind "tensor_literal" fields)
      | Core.TensorWordElements _ -> unsupported path "word tensor literal")
  | Core.CDict entries -> (
      match (entries, Core_emit_layout.canonical_type ~reg expr.ty) with
      | [], Ast.TyNamed ("Set", [ elem_ty ]) ->
          let alloc =
            {
              Core.sa_constructor =
                Core_hash_container_layout.set_constructor_kind ~reg elem_ty;
            }
          in
          let* alloc_json =
            set_alloc_json ~reg (path ^ ".alloc") expr.loc alloc
          in
          let* fields = typed [ ("alloc", alloc_json) ] in
          Ok (kind "set_alloc" fields)
      | _ ->
          let* entries_json =
            result_list entries (fun index (key, value) ->
                let entry_path = Printf.sprintf "%s.entries[%d]" path index in
                let* key_json =
                  expr_json ~function_names ~consumed_params ~reg enum_names value_record_names
                    heap_record_names union_names enum_constructors
                    (entry_path ^ ".key") key
                in
                let* value_json =
                  expr_json ~function_names ~consumed_params ~reg enum_names value_record_names
                    heap_record_names union_names enum_constructors
                    (entry_path ^ ".value") value
                in
                Ok (obj [ ("key", key_json); ("value", value_json) ]))
          in
          let* fields = typed [ ("entries", entries_json) ] in
          Ok (kind "dict" fields))
  | Core.CDictConstruct dc ->
      let* construct =
        dict_construct_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
          enum_constructors (path ^ ".construct") expr.loc dc
      in
      let* fields = typed [ ("construct", construct) ] in
      Ok (kind "dict_construct" fields)
  | Core.CSetAlloc alloc ->
      let* alloc_json = set_alloc_json ~reg (path ^ ".alloc") expr.loc alloc in
      let* fields = typed [ ("alloc", alloc_json) ] in
      Ok (kind "set_alloc" fields)
  | Core.CRecordUpdate _ -> unsupported path "record update"
  | Core.CLambda lambda ->
      let* params =
        closure_params_json ~reg enum_names value_record_names heap_record_names
          union_names (path ^ ".params") lambda.lam_params
      in
      let* return_type =
        type_json ~reg enum_names value_record_names heap_record_names union_names
          (path ^ ".return_type") lambda.lam_return_ty
      in
      let* body =
        expr_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
          enum_constructors (path ^ ".body") lambda.lam_body
      in
      let* fields =
        typed
          [
            ("params", params);
            ("return_type", return_type);
            ("body", body);
            ("pure", bool lambda.lam_is_pure);
          ]
      in
      Ok (kind "lambda" fields)
  | Core.CTensorRawRead read ->
      let* read_json =
        tensor_raw_read_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
          enum_constructors (path ^ ".read") read
      in
      let* fields = typed [ ("read", read_json) ] in
      Ok (kind "tensor_raw_read" fields)
  | Core.CTensorRawWrite write ->
      let* write_json =
        tensor_raw_write_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
          enum_constructors (path ^ ".write") write
      in
      let* fields = typed [ ("write", write_json) ] in
      Ok (kind "tensor_raw_write" fields)
  | Core.CTensorRawViewLet (binding, body) ->
      let* binding_json =
        tensor_raw_view_binding_json ~function_names ~consumed_params ~reg enum_names value_record_names
          heap_record_names union_names enum_constructors (path ^ ".binding")
          binding
      in
      let* body_json =
        expr_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
          enum_constructors (path ^ ".body") body
      in
      let* fields = typed [ ("binding", binding_json); ("body", body_json) ] in
      Ok (kind "tensor_raw_view_let" fields)
  | Core.CStringInterp _ -> unsupported path "string interpolation"
  | Core.CResourceScope scope ->
      let* scope_json =
        resource_scope_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
          enum_constructors (path ^ ".scope") scope
      in
      let* fields = typed [ ("scope", scope_json) ] in
      Ok (kind "resource_scope" fields)
  | Core.CResourceCleanupExit cleanup_exit ->
      let* cleanup_exit_json =
        resource_cleanup_exit_json ~function_names ~consumed_params ~reg enum_names value_record_names
          heap_record_names union_names enum_constructors (path ^ ".cleanup_exit")
          cleanup_exit
      in
      let* fields = typed [ ("cleanup_exit", cleanup_exit_json) ] in
      Ok (kind "resource_cleanup_exit" fields)
  | Core.CDebugBlock _ -> unsupported path "debug block"
  | Core.CMatchArms _ -> unsupported path "match arms"
  | Core.CMatch _ -> unsupported path "compiled match"
  | Core.CConcurrent block ->
      let* block_json =
        pre_closure_concurrent_block_json ~function_names ~consumed_params
          ~reg enum_names value_record_names heap_record_names union_names
          enum_constructors
          (path ^ ".pre_closure_concurrent") block
      in
      let* fields = typed [ ("pre_closure_concurrent", block_json) ] in
      Ok (kind "pre_closure_concurrent" fields)
  | Core.CConcurrentlyLoop loop ->
      let* loop_json =
        pre_closure_concurrently_loop_json ~function_names ~consumed_params
          ~reg enum_names value_record_names heap_record_names union_names
          enum_constructors (path ^ ".pre_closure_concurrently_loop") loop
      in
      let* fields = typed [ ("pre_closure_concurrently_loop", loop_json) ] in
      Ok (kind "pre_closure_concurrently_loop" fields)
  | Core.CDetach detach ->
      let* detach_json =
        pre_closure_detach_json ~function_names ~consumed_params ~reg enum_names
          value_record_names heap_record_names union_names enum_constructors
          (path ^ ".pre_closure_detach") detach
      in
      let* fields = typed [ ("pre_closure_detach", detach_json) ] in
      Ok (kind "pre_closure_detach" fields)
  | Core.CSelect select ->
      let* select_json =
        select_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
          enum_constructors (path ^ ".select") select
      in
      let* fields = typed [ ("select", select_json) ] in
      Ok (kind "select" fields)
  | Core.CBox (value, source_ty) ->
      let box = Core_emit_layout.make_box_op ~reg value source_ty in
      let* box_json =
        box_op_json ~function_names ~consumed_params ~reg enum_names
          value_record_names heap_record_names union_names enum_constructors
          (path ^ ".box") box
      in
      let* fields = typed [ ("box", box_json) ] in
      Ok (kind "box" fields)
  | Core.CUnbox (value, target_ty) ->
      let unbox =
        {
          Core.unbox_value = value;
          unbox_target_ty = target_ty;
          unbox_kind =
            Core_layout_type.unbox_kind_of_type ~phase:Core_error.Emit ~reg
              target_ty expr.loc;
        }
      in
      let* unbox_kind, expr_value =
        unbox_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
          enum_constructors path unbox
      in
      let* fields =
        typed [ ("unbox_kind", unbox_kind); ("expr", expr_value) ]
      in
      Ok (kind "unbox" fields)
  | Core.CUnionConstruct uc ->
      let* construct =
        union_construct_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
          enum_constructors (path ^ ".construct") uc
      in
      let* fields = typed [ ("construct", construct) ] in
      Ok (kind "union_construct" fields)
  | Core.CUnionReuseConstruct _ -> unsupported path "union reuse construction"
  | Core.CBoxTyped box ->
      let* box_json =
        box_op_json ~function_names ~consumed_params ~reg enum_names
          value_record_names heap_record_names union_names enum_constructors
          (path ^ ".box") box
      in
      let* fields = typed [ ("box", box_json) ] in
      Ok (kind "box" fields)
  | Core.CUnboxTyped unbox ->
      let* unbox_kind, expr_value =
        unbox_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
          enum_constructors path unbox
      in
      let* fields =
        typed [ ("unbox_kind", unbox_kind); ("expr", expr_value) ]
      in
      Ok (kind "unbox" fields)

and box_kind_json _path = function
  | Core.BoxPrim -> Ok (kind "prim" [])
  | Core.BoxPointer -> Ok (kind "pointer" [])
  | Core.BoxVoid -> Ok (kind "void" [])
  | Core.BoxStruct c_type -> Ok (kind "struct" [ ("c_type", str c_type) ])
  | Core.BoxFloat -> Ok (kind "float" [])
  | Core.BoxFloat32 -> Ok (kind "float32" [])
  | Core.BoxFloat16 -> Ok (kind "float16" [])
  | Core.BoxInt128 -> Ok (kind "int128" [])
  | Core.BoxUInt128 -> Ok (kind "uint128" [])

and box_op_json ~function_names ~consumed_params ~reg enum_names
    value_record_names heap_record_names union_names enum_constructors path
    (box : Core.box_op) =
  let* kind_value = box_kind_json (path ^ ".kind") box.box_kind in
  let* value =
    expr_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names enum_constructors
      (path ^ ".value") box.box_value
  in
  let* source_type =
    type_json ~reg enum_names value_record_names heap_record_names union_names (path ^ ".source_type")
      box.box_source_ty
  in
  Ok
    (obj
       [ ("kind", kind_value); ("value", value); ("source_type", source_type) ])

and unbox_kind_json = function
  | Core.UnboxFloat -> Ok (kind "float" [])
  | Core.UnboxFloat32 -> Ok (kind "float32" [])
  | Core.UnboxFloat16 -> Ok (kind "float16" [])
  | Core.UnboxInt128 -> Ok (kind "int128" [])
  | Core.UnboxUInt128 -> Ok (kind "uint128" [])
  | Core.UnboxPointer -> Ok (kind "pointer" [])
  | Core.UnboxPrim -> Ok (kind "prim" [])
  | Core.UnboxStruct c_type -> Ok (kind "struct" [ ("c_type", str c_type) ])

and boxed_storage_value_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
    enum_constructors path (value : Core.boxed_storage_value) =
  let* kind_value = box_kind_json (path ^ ".kind") value.bsv_box.box_kind in
  let* value_json =
    expr_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names enum_constructors
      (path ^ ".value") value.bsv_box.box_value
  in
  Ok
    (obj
       [
         ("kind", kind_value);
         ("value", value_json);
         ("needs_release", bool value.bsv_needs_release);
         ("transfers_ownership", bool value.bsv_transfers_ownership);
       ])

and boxed_storage_values_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
    enum_constructors path values =
  result_list values (fun index value ->
      boxed_storage_value_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
        enum_constructors
        (Printf.sprintf "%s[%d]" path index)
        value)

and dict_constructor_json ~reg path loc = function
  | Core.DictGeneric -> Ok (kind "generic" [])
  | Core.DictString -> Ok (kind "string" [])
  | Core.DictFloat -> Ok (kind "float" [])
  | Core.DictCustom key_ty ->
      custom_hash_container_constructor_json ~reg path loc key_ty

and set_constructor_json ~reg path loc = function
  | Core.SetGeneric -> Ok (kind "generic" [])
  | Core.SetString -> Ok (kind "string" [])
  | Core.SetFloat -> Ok (kind "float" [])
  | Core.SetCustom elem_ty ->
      custom_hash_container_constructor_json ~reg path loc elem_ty

and dict_entry_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
    enum_constructors path
    ((key, value) : Core.boxed_storage_value * Core.boxed_storage_value) =
  let* key_json =
    boxed_storage_value_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
      enum_constructors (path ^ ".key") key
  in
  let* value_json =
    boxed_storage_value_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
      enum_constructors (path ^ ".value") value
  in
  Ok (obj [ ("key", key_json); ("value", value_json) ])

and dict_entries_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
    enum_constructors path entries =
  result_list entries (fun index entry ->
      dict_entry_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
        enum_constructors
        (Printf.sprintf "%s[%d]" path index)
        entry)

and dict_construct_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
    enum_constructors path loc (construct : Core.dict_construct) =
  let* constructor =
    dict_constructor_json ~reg (path ^ ".constructor") loc construct.dc_constructor
  in
  let* entries =
    dict_entries_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
      enum_constructors (path ^ ".entries") construct.dc_entries
  in
  Ok
    (obj
       [
         ("constructor", constructor);
         ("entries", entries);
         ("value_needs_release", bool construct.dc_value_needs_release);
       ])

and set_alloc_json ~reg path loc (alloc : Core.set_alloc) =
  let* constructor =
    set_constructor_json ~reg (path ^ ".constructor") loc alloc.sa_constructor
  in
  Ok (obj [ ("constructor", constructor) ])

and borrowed_list_iterable (expr : Core.core) =
  match expr.desc with
  | Core.CVar _ -> true
  | Core.CField (inner, _) -> borrowed_list_iterable inner
  | _ -> false

and iterable_release_policy_json ~reg (iter : Core.core) =
  if Core_emit_layout.boxed_expr_transfers_ownership ~reg iter then
    release_policy_json ~reg iter.ty
  else str "none"

and match_scrutinee_needs_release ~reg (scrut : Core.core) =
  match scrut.desc with
  | Core.CVar _ | Core.CField _ -> false
  | Core.CCast (inner, _) | Core.CUnbox (inner, _) ->
      match_scrutinee_needs_release ~reg inner
  | Core.CUnboxTyped unbox ->
      match_scrutinee_needs_release ~reg unbox.unbox_value
  | _
    when not
           (Core_layout_type.source_value_requires_release_or_error
              ~phase:Core_error.Emit ~reg scrut.ty scrut.loc) ->
      false
  | Core.CCall (kind, _, args) -> (
      match
        Core_ownership.contract_for_call_kind kind ~arg_count:(List.length args)
      with
      | Some { result = Core_ownership.ReturnOwned; _ } -> true
      | Some
          {
            result =
              ( Core_ownership.ReturnVoid | Core_ownership.ReturnPrimitive
              | Core_ownership.ReturnBorrowed
              | Core_ownership.ReturnAliasOfArg _ );
            _;
          } ->
          false
      | None -> (
          match kind with
          | Core.CKUnknown | Core.CKSelectedDirect _ -> false
          | Core.CKUser _ | Core.CKForeign _ | Core.CKBuiltin _
          | Core.CKClosure ->
              true
          | Core.CKIntrinsic _ -> false))
  | _ -> true

and match_scrutinee_release_policy_json ~reg scrut =
  if match_scrutinee_needs_release ~reg scrut then
    release_policy_json ~reg scrut.ty
  else str "none"

and require_supported_list_loop_layout _path (layout : Core.list_storage_layout) =
  match layout.lsl_slots with
  | Core.ListPointerStorage -> Ok ()
  | Core.ListInlineStorage _ -> Ok ()
  | Core.ListInlineStructStorage _ -> Ok ()

and for_channel_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
    enum_constructors path binder iter body =
  let* binder_json =
    loop_binder_json ~reg enum_names value_record_names heap_record_names union_names
      (path ^ ".binder") binder
  in
  let* iterable_json =
    expr_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names enum_constructors
      (path ^ ".iterable") iter
  in
  let* body_json =
    expr_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names enum_constructors
      (path ^ ".body") body
  in
  Ok
    (obj
       [
         ("binder", binder_json);
         ("iterable", iterable_json);
         ("body", body_json);
       ])

and for_list_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
    enum_constructors path binder layout iter body =
  let* () = require_supported_list_loop_layout (path ^ ".layout") layout in
  let* binder_json =
    loop_binder_json ~reg enum_names value_record_names heap_record_names union_names
      (path ^ ".binder") binder
  in
  let* layout_json = list_storage_layout_json layout in
  let* iterable_json =
    expr_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names enum_constructors
      (path ^ ".iterable") iter
  in
  let iterable_release_policy = iterable_release_policy_json ~reg iter in
  let* body_json =
    expr_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names enum_constructors
      (path ^ ".body") body
  in
  Ok
    (obj
       [
         ("binder", binder_json);
         ("layout", layout_json);
         ("iterable", iterable_json);
         ("iterable_release_policy", iterable_release_policy);
         ("body", body_json);
       ])

and for_iterable_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names
    union_names enum_constructors path binder iter body =
  let* binder_json =
    loop_binder_json ~reg enum_names value_record_names heap_record_names union_names
      (path ^ ".binder") binder
  in
  let* iterable_json =
    expr_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names enum_constructors
      (path ^ ".iterable") iter
  in
  let iterable_release_policy = iterable_release_policy_json ~reg iter in
  let* body_json =
    expr_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names enum_constructors
      (path ^ ".body") body
  in
  Ok
    (obj
       [
         ("binder", binder_json);
         ("iterable", iterable_json);
         ("iterable_release_policy", iterable_release_policy);
         ("body", body_json);
       ])

and for_string_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names
    union_names enum_constructors path binder iter body =
  for_iterable_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names
    union_names enum_constructors path binder iter body

and for_dict_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
    enum_constructors path binder iter body =
  for_iterable_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names
    union_names enum_constructors path binder iter body

and for_set_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
    enum_constructors path binder iter body =
  for_iterable_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names
    union_names enum_constructors path binder iter body

and for_stream_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
    enum_constructors path binder iter body =
  let* binder_json =
    loop_binder_json ~reg enum_names value_record_names heap_record_names union_names
      (path ^ ".binder") binder
  in
  let* iterable_json =
    expr_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names enum_constructors
      (path ^ ".iterable") iter
  in
  let iterable_release_policy = iterable_release_policy_json ~reg iter in
  let* body_json =
    expr_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names enum_constructors
      (path ^ ".body") body
  in
  Ok
    (obj
       [
         ("binder", binder_json);
         ("iterable", iterable_json);
         ("iterable_release_policy", iterable_release_policy);
         ("body", body_json);
       ])

and for_resource_source_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names
    union_names enum_constructors path binder iter body =
  let* binder_json =
    loop_binder_json ~reg enum_names value_record_names heap_record_names union_names
      (path ^ ".binder") binder
  in
  let* iterable_json =
    expr_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names enum_constructors
      (path ^ ".iterable") iter
  in
  let iterable_release_policy = iterable_release_policy_json ~reg iter in
  let* body_json =
    expr_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names enum_constructors
      (path ^ ".body") body
  in
  Ok
    (obj
       [
         ("binder", binder_json);
         ("iterable", iterable_json);
         ("iterable_release_policy", iterable_release_policy);
         ("body", body_json);
       ])

and pre_closure_detach_json ~function_names ~consumed_params ~reg enum_names
    value_record_names heap_record_names union_names enum_constructors path
    (detach : Core.detach_expr) =
  let* body =
    expr_json ~function_names ~consumed_params ~reg enum_names
      value_record_names heap_record_names union_names enum_constructors
      (path ^ ".body") detach.detach_body
  in
  Ok (obj [ ("body", body) ])

and pre_closure_concurrent_binding_json ~function_names ~consumed_params ~reg
    enum_names value_record_names heap_record_names union_names enum_constructors
    path index
    (binding : Core.conc_binding) =
  let binding_path = Printf.sprintf "%s.bindings[%d]" path index in
  let* binding_type =
    type_json ~reg enum_names value_record_names heap_record_names union_names
      (binding_path ^ ".type") binding.cb_ty
  in
  let* rhs =
    expr_json ~function_names ~consumed_params ~reg enum_names
      value_record_names heap_record_names union_names enum_constructors
      (binding_path ^ ".rhs") binding.cb_rhs
  in
  Ok
    (obj
       [
         ("var", var_json binding.cb_var);
         ("type", binding_type);
         ("rhs", rhs);
       ])

and concurrent_timeout_json ~function_names ~consumed_params ~reg enum_names
    value_record_names heap_record_names union_names enum_constructors path =
  function
  | Some timeout ->
      expr_json ~function_names ~consumed_params ~reg enum_names
        value_record_names heap_record_names union_names enum_constructors path
        timeout
  | None -> Ok null

and pre_closure_concurrent_block_json ~function_names ~consumed_params ~reg
    enum_names value_record_names heap_record_names union_names enum_constructors
    path
    (block : Core.concurrent_block) =
  let* bindings =
    result_list block.conc_bindings
      (pre_closure_concurrent_binding_json ~function_names ~consumed_params
         ~reg enum_names value_record_names heap_record_names union_names
         enum_constructors path)
  in
  let* body =
    expr_json ~function_names ~consumed_params ~reg enum_names
      value_record_names heap_record_names union_names enum_constructors
      (path ^ ".body") block.conc_body
  in
  let* timeout =
    concurrent_timeout_json ~function_names ~consumed_params ~reg enum_names
      value_record_names heap_record_names union_names enum_constructors
      (path ^ ".timeout") block.conc_timeout
  in
  Ok
    (obj
       [
         ("bindings", bindings);
         ("body", body);
         ("timeout", timeout);
         ("max_threads", option_int_json block.conc_max_threads);
       ])

and concurrently_loop_output_json = function
  | Core.ConcurrentlyLoopCollect -> str "collect"
  | Core.ConcurrentlyLoopDiscard -> str "discard"

and concurrently_loop_item_type path (loop : Core.concurrently_loop) =
  match (loop.cf_item_mode, Codegen_types.normalize_type loop.cf_iter.ty) with
  | Core.ConcurrentlyLoopCopyItem, Ast.TyNamed ("List", [ item_ty ]) ->
      Ok item_ty
  | Core.ConcurrentlyLoopCopyItem, ty ->
      unsupported path
        (Printf.sprintf "copy-item concurrently loop requires List[T], got %s"
           (Types.type_to_string ty))
  | Core.ConcurrentlyLoopMoveResourceItem { clmi_resource_ty; _ }, _ ->
      Ok clmi_resource_ty

and concurrently_loop_item_mode_json ~reg enum_names value_record_names
    heap_record_names union_names path = function
  | Core.ConcurrentlyLoopCopyItem -> Ok (kind "copy" [])
  | Core.ConcurrentlyLoopMoveResourceItem { clmi_resource_ty; clmi_error_ty } ->
      let* resource_type =
        type_json ~reg enum_names value_record_names heap_record_names union_names
          (path ^ ".resource_type") clmi_resource_ty
      in
      let* error_type =
        type_json ~reg enum_names value_record_names heap_record_names union_names
          (path ^ ".error_type") clmi_error_ty
      in
      Ok
        (kind "move_resource_item"
           [ ("resource_type", resource_type); ("error_type", error_type) ])

and pre_closure_concurrently_loop_json ~function_names ~consumed_params ~reg
    enum_names value_record_names heap_record_names union_names enum_constructors
    path
    (loop : Core.concurrently_loop) =
  let* item_ty = concurrently_loop_item_type (path ^ ".item_type") loop in
  let* item_type =
    type_json ~reg enum_names value_record_names heap_record_names union_names
      (path ^ ".item_type") item_ty
  in
  let* item_mode =
    concurrently_loop_item_mode_json ~reg enum_names value_record_names
      heap_record_names union_names (path ^ ".item_mode") loop.cf_item_mode
  in
  let* iterable =
    expr_json ~function_names ~consumed_params ~reg enum_names
      value_record_names heap_record_names union_names enum_constructors
      (path ^ ".iterable") loop.cf_iter
  in
  let* body =
    expr_json ~function_names ~consumed_params ~reg enum_names
      value_record_names heap_record_names union_names enum_constructors
      (path ^ ".body") loop.cf_body
  in
  let* timeout =
    concurrent_timeout_json ~function_names ~consumed_params ~reg enum_names
      value_record_names heap_record_names union_names enum_constructors
      (path ^ ".timeout") loop.cf_timeout
  in
  let* limit =
    match loop.cf_width with
    | Core.ConcurrentlyLoopLimit limit ->
        expr_json ~function_names ~consumed_params ~reg enum_names
          value_record_names heap_record_names union_names enum_constructors
          (path ^ ".limit") limit
  in
  Ok
    (obj
       [
         ("var", var_json loop.cf_var);
         ("item_type", item_type);
         ("item_mode", item_mode);
         ("iterable", iterable);
         ("body", body);
         ("timeout", timeout);
         ("limit", limit);
         ("output", concurrently_loop_output_json loop.cf_output);
       ])

and select_recv_arm_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names
    union_names enum_constructors path
    (recv : [ `Recv of Core.var * Ast.type_expr * Core.core ]) =
  match recv with
  | `Recv (binder, elem_ty, channel) ->
      let* elem_type =
        type_json ~reg enum_names value_record_names heap_record_names
          union_names (path ^ ".elem_type") elem_ty
      in
      let* channel_json =
        expr_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
          enum_constructors (path ^ ".channel") channel
      in
      Ok
        (obj
           [
             ("binder", var_json binder);
             ("elem_type", elem_type);
             ("channel", channel_json);
           ])

and select_arm_kind_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names
    union_names enum_constructors path = function
  | Core.SelectRecv { select_bind; select_elem_ty; select_channel } ->
      let* recv =
        select_recv_arm_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names
          union_names enum_constructors (path ^ ".recv")
          (`Recv (select_bind, select_elem_ty, select_channel))
      in
      Ok (kind "recv" [ ("recv", recv) ])
  | Core.SelectSealed channel ->
      let* channel_json =
        expr_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
          enum_constructors (path ^ ".channel") channel
      in
      Ok (kind "sealed" [ ("channel", channel_json) ])
  | Core.SelectAfter timeout ->
      let* timeout_json =
        expr_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
          enum_constructors (path ^ ".timeout") timeout
      in
      Ok (kind "after" [ ("timeout", timeout_json) ])

and select_arm_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
    enum_constructors path index (arm : Core.select_arm) =
  let arm_path = Printf.sprintf "%s.arms[%d]" path index in
  let* kind_json =
    select_arm_kind_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names
      union_names enum_constructors (arm_path ^ ".kind") arm.select_arm_kind
  in
  let* body_json =
    expr_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
      enum_constructors (arm_path ^ ".body") arm.select_arm_body
  in
  Ok
    (obj
       [
         ("kind", kind_json);
         ("body", body_json);
         ("loc", source_loc_json arm.select_arm_loc);
       ])

and select_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
    enum_constructors path (select : Core.select_expr) =
  let* arms =
    result_list select.select_arms
      (select_arm_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names
         union_names enum_constructors path)
  in
  Ok (obj [ ("arms", arms) ])

	and tensor_for_row_slice_json ~reg path (iter : Core.core) =
	  match Core_tensor_type.of_type ~reg iter.ty with
	  | Some { Core_tensor_type.dims = _outer :: inner_dims; _ } -> (
	      let all_literal =
	        List.for_all
	          (function Ast.TyConstInt _ -> true | _ -> false)
	          inner_dims
	      in
	      let* row_size, result_first_dim =
	        match inner_dims with
	        | [ Ast.TyConstInt n ] ->
	            Ok (Printf.sprintf "%dL" n, Printf.sprintf "%dL" n)
	        | [ _ ] ->
	            Ok ("", "")
	        | Ast.TyConstInt first_inner :: rest when all_literal ->
	            let product =
	              List.fold_left
	                (fun acc ty ->
	                  match ty with Ast.TyConstInt n -> acc * n | _ -> acc)
	                first_inner rest
	            in
	            Ok
	              ( Printf.sprintf "%dL" product,
	                Printf.sprintf "%dL" first_inner )
	        | _ :: _ ->
	            unsupported path
	              "cannot peel 3D+ tensor with non-literal inner dimensions"
	        | [] -> unsupported path "1D tensor row-slice loop"
	      in
	      let runtime_derived =
	        match inner_dims with [ Ast.TyConstInt _ ] -> false | [ _ ] -> true | _ -> false
	      in
	      Ok
	        (kind "row_slice"
	           [
	             ("row_size", str row_size);
	             ("result_first_dim", str result_first_dim);
	             ("runtime_derived", bool runtime_derived);
	           ]))
	  | Some _ -> unsupported path "1D tensor row-slice loop"
	  | None -> unsupported path "non-tensor row-slice loop"

and tensor_for_proven_raw_scalar_storage_json ~reg path
    (binder : Core.loop_binder) =
  match binder.loop_source_storage with
  | Core.TensorStorageProven
      { tsp_layout = { Core.tsl_slots = Core.TensorRawScalarStorage raw_kind; _ }; _ }
    -> (
      match Core_layout_type.tensor_raw_scalar_kind_of_type ~reg binder.loop_ty with
      | Some expected_kind when expected_kind = raw_kind ->
          Ok (Some (kind "raw_scalar" [ ("raw_kind", tensor_raw_scalar_kind_json raw_kind) ]))
      | Some _ ->
          unsupported path
            "raw scalar tensor for-loop storage proof does not match element type"
      | None -> Ok None)
  | Core.TensorStorageProven _ | Core.TensorStorageUnknown _ -> Ok None

and tensor_for_element_storage_json ~reg path (binder : Core.loop_binder) =
  let* raw_storage =
    tensor_for_proven_raw_scalar_storage_json ~reg path binder
  in
  match raw_storage with
  | Some storage -> Ok storage
  | None -> (
      match
        Core_layout_type.tensor_runtime_read_helper_of_type ~reg binder.loop_ty
      with
      | Some helper ->
          let* helper_tag =
            tensor_runtime_read_helper_tag (path ^ ".helper") helper.trrh_c_helper
          in
          Ok
            (kind "runtime_read"
               [
                 ( "value_c_type",
                   str (Core_emit_layout.c_type_for_reg ~reg binder.loop_ty) );
                 ("helper", str helper_tag);
               ])
      | None -> (
          match Core_emit_layout.tensor_element_storage_for_reg ~reg binder.loop_ty with
          | Core_layout_type.TensorElementInlineStruct c_type ->
              Ok (kind "inline_struct" [ ("c_type", str c_type) ])
          | Core_layout_type.TensorElementRawScalar _ ->
              unsupported path "raw scalar tensor for-loop"
          | Core_layout_type.TensorElementPackedBits _ ->
              unsupported path "packed tensor for-loop"
          | Core_layout_type.TensorElementBoxed ->
              Ok
                (kind "boxed"
                   [
                     ( "value_c_type",
                       str (Core_emit_layout.c_type_for_reg ~reg binder.loop_ty)
                     );
                   ])))

and tensor_runtime_read_helper_tag path = function
  | "blorp_vector_read_i64" -> Ok "i64"
  | "blorp_vector_read_f64" -> Ok "f64"
  | "blorp_vector_read_f32" -> Ok "f32"
	| "blorp_vector_read_f16" -> Ok "f16"
	| helper -> unsupported path ("unsupported tensor runtime read helper " ^ helper)

	and tensor_for_loop_element_storage_json ~reg path binder (iter : Core.core) =
	  match Core_tensor_type.of_type ~reg iter.ty with
	  | Some { Core_tensor_type.dims = [ _ ]; _ } ->
	      tensor_for_element_storage_json ~reg path binder
	  | Some { Core_tensor_type.dims = _ :: _ :: _; _ } ->
	      tensor_for_row_slice_json ~reg path iter
	  | Some _ -> unsupported path "tensor for-loop without dimensions"
	  | None -> unsupported path "non-tensor for-loop"

	and for_tensor_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names
	    union_names enum_constructors path binder iter body =
	  let* binder_json =
	    loop_binder_json ~reg enum_names value_record_names heap_record_names union_names
	      (path ^ ".binder") binder
	  in
	  let* element_storage_json =
	    tensor_for_loop_element_storage_json ~reg (path ^ ".element_storage") binder iter
	  in
  let* iterable_json =
    expr_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names enum_constructors
      (path ^ ".iterable") iter
  in
  let iterable_release_policy = iterable_release_policy_json ~reg iter in
  let* body_json =
    expr_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names enum_constructors
      (path ^ ".body") body
  in
  Ok
    (obj
       [
         ("binder", binder_json);
         ("element_storage", element_storage_json);
         ("iterable", iterable_json);
         ("iterable_release_policy", iterable_release_policy);
         ("body", body_json);
       ])

and list_storage_layout_json (layout : Core.list_storage_layout) =
  match layout.lsl_slots with
  | Core.ListPointerStorage -> Ok (kind "pointer" [])
  | Core.ListInlineStorage width ->
      Ok
        (kind "inline"
           [ ("width_bytes", int (Core.inline_storage_width_bytes width)) ])
  | Core.ListInlineStructStorage c_type ->
      Ok (kind "inline_struct" [ ("c_type", str c_type) ])

and list_construct_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
    enum_constructors path (lc : Core.list_construct) =
  let* layout = list_storage_layout_json lc.lc_layout in
  let* elements =
    boxed_storage_values_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
      enum_constructors (path ^ ".elements") lc.lc_elems
  in
  Ok
    (obj
       [
         ("layout", layout);
         ("elements", elements);
         ("elem_needs_release", bool lc.lc_elem_needs_release);
       ])

and list_literal_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
    enum_constructors path loc (lit : Core.list_literal) =
  let* layout = list_storage_layout_json lit.ll_layout in
  let elems =
    List.map (Core_emit_layout.boxed_storage_value ~reg) lit.ll_elems
  in
  let* elements =
    boxed_storage_values_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
      enum_constructors (path ^ ".elements") elems
  in
  Ok
    (obj
       [
         ("layout", layout);
         ("elements", elements);
         ( "elem_needs_release",
           bool
             (Core.list_storage_layout_requires_release_or_error
                ~phase:Core_error.Emit ~loc lit.ll_layout) );
       ])

and list_alloc_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
    enum_constructors path loc (alloc : Core.list_alloc) =
  let* layout = list_storage_layout_json alloc.la_layout in
  let* capacity =
    expr_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names enum_constructors
      (path ^ ".capacity") alloc.la_capacity
  in
  Ok
    (obj
       [
         ("layout", layout);
         ("capacity", capacity);
         ( "elem_needs_release",
           bool
             (Core.list_storage_layout_requires_release_or_error
                ~phase:Core_error.Emit ~loc alloc.la_layout) );
       ])

and list_bounds_json = function
  | Core.ListBoundsChecked -> str "checked"
  | Core.ListBoundsProven -> str "proven"

and list_get_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
    enum_constructors path (get : Core.list_get) =
  let* layout = list_storage_layout_json get.lg_layout in
  let* list =
    expr_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names enum_constructors
      (path ^ ".list") get.lg_list
  in
  let* index =
    expr_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names enum_constructors
      (path ^ ".index") get.lg_index
  in
  Ok
    (obj
       [
         ("layout", layout);
         ("list", list);
         ("index", index);
         ("bounds", list_bounds_json get.lg_bounds);
       ])

and tensor_raw_scalar_kind_json = function
  | Core.TensorFloat64Elements -> str "float64"
  | Core.TensorFloat32Elements -> str "float32"
  | Core.TensorInt64Elements -> str "int64"

and tensor_literal_shape_json = function
  | Core.TensorVectorLength length ->
      kind "vector" [ ("length", int length) ]
  | Core.TensorStaticShape dims ->
      kind "static" [ ("dims", arr (List.map int dims)) ]

and tensor_literal_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names
    union_names enum_constructors path (literal : Core.tensor_literal) =
  let element_values elements =
    result_list elements (fun index element ->
        expr_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
          enum_constructors
          (Printf.sprintf "%s.elements[%d]" path index)
          element)
  in
  match literal.tl_payload with
  | Core.TensorRawElements (raw_kind, elements) ->
      let* elements_value = element_values elements in
      Ok
        (obj
           [
             ("shape", tensor_literal_shape_json literal.tl_shape);
             ( "payload",
               kind "raw"
                 [
                   ("raw_kind", tensor_raw_scalar_kind_json raw_kind);
                   ("elements", elements_value);
                 ] );
           ])
  | Core.TensorInlineStructElements (struct_c_type, elements) ->
      let* elements_value = element_values elements in
      Ok
        (obj
           [
             ("shape", tensor_literal_shape_json literal.tl_shape);
             ( "payload",
               kind "inline_struct"
                 [
                   ("struct_c_type", str struct_c_type);
                   ("elements", elements_value);
                 ] );
           ])
  | Core.TensorWordElements _ | Core.TensorPackedElements _
  | Core.TensorBoxedElements _ ->
      unsupported path "unsupported tensor literal payload"

and tensor_boxed_literal_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names
    union_names enum_constructors path shape elements elem_needs_release =
  let* element_values =
    boxed_storage_values_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names
      union_names enum_constructors (path ^ ".elements") elements
  in
  Ok
    (obj
       [
         ("shape", tensor_literal_shape_json shape);
         ("elements", element_values);
         ("elem_needs_release", bool elem_needs_release);
       ])

and tensor_packed_literal_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names
    union_names enum_constructors path shape width elements =
  let* element_values =
    result_list elements (fun index element ->
        expr_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names
          union_names enum_constructors
          (Printf.sprintf "%s.elements[%d]" path index)
          element)
  in
  Ok
    (obj
       [
         ("shape", tensor_literal_shape_json shape);
         ("elem_size", int (Core.inline_storage_width_bytes width));
         ("elements", element_values);
       ])

and tensor_raw_fill_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names
    union_names enum_constructors path raw_kind value dims =
  let* value_json =
    expr_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
      enum_constructors (path ^ ".value") value
  in
  let* dim_values =
    result_list dims (fun index dim ->
        expr_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names
          union_names enum_constructors
          (Printf.sprintf "%s.dims[%d]" path index)
          dim)
  in
  Ok
    (obj
         [
           ("raw_kind", tensor_raw_scalar_kind_json raw_kind);
           ("value", value_json);
           ("dims", dim_values);
         ])

and tensor_raw_read_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
    enum_constructors path (read : Core.tensor_raw_read) =
  let* index =
    expr_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names enum_constructors
      (path ^ ".index") read.trr_index
  in
  Ok
    (obj
       [
         ("view", var_json read.trr_view);
         ("raw_kind", tensor_raw_scalar_kind_json read.trr_kind);
         ("index", index);
       ])

and tensor_raw_write_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
    enum_constructors path (write : Core.tensor_raw_write) =
  let* index =
    expr_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names enum_constructors
      (path ^ ".index") write.trw_index
  in
  let* value =
    expr_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names enum_constructors
      (path ^ ".value") write.trw_value
  in
  Ok
    (obj
       [
         ("view", var_json write.trw_view);
         ("raw_kind", tensor_raw_scalar_kind_json write.trw_kind);
         ("index", index);
         ("value", value);
       ])

and tensor_raw_view_binding_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
    enum_constructors path (binding : Core.tensor_raw_view_binding) =
  let* source =
    expr_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names enum_constructors
      (path ^ ".source") binding.trv_source
  in
  Ok
    (obj
       [
         ("variable", var_json binding.trv_var);
         ("raw_kind", tensor_raw_scalar_kind_json binding.trv_kind);
         ("source", source);
       ])

and list_handoff_mode_json = function
  | Core.BorrowFresh -> str "borrow_fresh"
  | Core.ConsumeReuse -> str "consume_reuse"

and list_handoff_write_order_json = function
  | Core.ForwardCompacting -> str "forward_compacting"

and list_handoff_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
    enum_constructors path loc (handoff : Core.list_handoff) =
  let* layout = list_storage_layout_json handoff.lh_layout in
  let* source =
    expr_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names enum_constructors
      (path ^ ".source") handoff.lh_source
  in
  let* source_type =
    type_json ~reg enum_names value_record_names heap_record_names union_names (path ^ ".source_type")
      handoff.lh_source_ty
  in
  let* result_type =
    type_json ~reg enum_names value_record_names heap_record_names union_names (path ^ ".result_type")
      handoff.lh_result_ty
  in
  let* capacity =
    expr_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names enum_constructors
      (path ^ ".capacity") handoff.lh_capacity
  in
  let* body =
    expr_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names enum_constructors
      (path ^ ".body") handoff.lh_body
  in
  Ok
    (obj
       [
         ("mode", list_handoff_mode_json handoff.lh_mode);
         ("layout", layout);
         ( "elem_needs_release",
           bool
             (Core.list_storage_layout_requires_release_or_error
                ~phase:Core_error.Emit ~loc handoff.lh_layout) );
         ("source", source);
         ("source_var", var_json handoff.lh_source_var);
         ("source_type", source_type);
         ("result_type", result_type);
         ("capacity", capacity);
         ("result_var", var_json handoff.lh_result_var);
         ("len_var", var_json handoff.lh_len_var);
         ("out_var", var_json handoff.lh_out_var);
         ("body", body);
         ("write_order", list_handoff_write_order_json handoff.lh_write_order);
       ])

and list_handoff_set_source_slot_json ~function_names ~consumed_params ~reg enum_names value_record_names
    heap_record_names union_names enum_constructors path result out_index source
    source_index =
  let* result_json =
    expr_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names enum_constructors
      (path ^ ".result") result
  in
  let* out_index_json =
    expr_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names enum_constructors
      (path ^ ".out_index") out_index
  in
  let* source_json =
    expr_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names enum_constructors
      (path ^ ".source") source
  in
  let* source_index_json =
    expr_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names enum_constructors
      (path ^ ".source_index") source_index
  in
  Ok
    (obj
       [
         ("result", result_json);
         ("out_index", out_index_json);
         ("source", source_json);
         ("source_index", source_index_json);
       ])

and string_byte_read_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
    enum_constructors path (read : Core.string_byte_read) =
  match read.sbr_proof with
  | Core.StringReadBoundsProven ->
      let* source =
        expr_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
          enum_constructors (path ^ ".source") read.sbr_source
      in
      let* index =
        expr_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
          enum_constructors (path ^ ".index") read.sbr_index
      in
      Ok (obj [ ("source", source); ("index", index) ])

and string_byte_write_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
    enum_constructors path (write : Core.string_byte_write) =
  match write.sbw_proof with
  | Core.StringWriteBoundsProven ->
      let* target =
        expr_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
          enum_constructors (path ^ ".target") write.sbw_target
      in
      let* index =
        expr_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
          enum_constructors (path ^ ".index") write.sbw_index
      in
      let* byte =
        expr_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
          enum_constructors (path ^ ".byte") write.sbw_byte
      in
      Ok (obj [ ("target", target); ("index", index); ("byte", byte) ])

and string_byte_copy_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
    enum_constructors path (copy : Core.string_byte_copy) =
  match copy.sbc_proof with
  | Core.StringCopyBoundsProven ->
      let* dst =
        expr_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
          enum_constructors (path ^ ".dst") copy.sbc_dst
      in
      let* dst_pos =
        expr_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
          enum_constructors (path ^ ".dst_pos") copy.sbc_dst_pos
      in
      let* src =
        expr_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
          enum_constructors (path ^ ".src") copy.sbc_src
      in
      let* src_pos =
        expr_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
          enum_constructors (path ^ ".src_pos") copy.sbc_src_pos
      in
      let* len =
        expr_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
          enum_constructors (path ^ ".len") copy.sbc_len
      in
      Ok
        (obj
           [
             ("dst", dst);
             ("dst_pos", dst_pos);
             ("src", src);
             ("src_pos", src_pos);
             ("len", len);
           ])

and string_set_len_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
    enum_constructors path (set_len : Core.string_set_len) =
  match set_len.ssl_proof with
  | Core.StringSetLenBoundsProven ->
      let* target =
        expr_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
          enum_constructors (path ^ ".target") set_len.ssl_target
      in
      let* len =
        expr_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
          enum_constructors (path ^ ".len") set_len.ssl_len
      in
      Ok (obj [ ("target", target); ("len", len) ])

and unbox_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names enum_constructors
    path (u : Core.unbox_op) =
  let* kind_value = unbox_kind_json u.unbox_kind in
  let* expr_value =
    expr_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names enum_constructors
      (path ^ ".expr") u.unbox_value
  in
  Ok (kind_value, expr_value)

and list_set_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
    enum_constructors path ~transfers_ownership
    (layout : Core.list_storage_layout) list index value =
  let boxed_value =
    {
      (Core_emit_layout.boxed_storage_value ~reg value) with
      bsv_transfers_ownership = transfers_ownership;
    }
  in
  let* () = require_list_set_layout path layout boxed_value in
  let* layout_json = list_storage_layout_json layout in
  let* list_json =
    expr_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names enum_constructors
      (path ^ ".list") list
  in
  let* index_json =
    expr_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names enum_constructors
      (path ^ ".index") index
  in
  let* value_json =
    boxed_storage_value_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
      enum_constructors (path ^ ".value") boxed_value
  in
  Ok
    (obj
       [
         ("layout", layout_json);
         ("list", list_json);
         ("index", index_json);
         ("value", value_json);
         ( "value_is_stack_result",
           bool (Core_layout_type.is_stack_result_type ~reg value.ty) );
       ])

and list_swap_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
    enum_constructors path (layout : Core.list_storage_layout) list left_index
    right_index =
  let* layout_json = list_storage_layout_json layout in
  let* list_json =
    expr_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
      enum_constructors (path ^ ".list") list
  in
  let* left_index_json =
    expr_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
      enum_constructors (path ^ ".left_index") left_index
  in
  let* right_index_json =
    expr_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
      enum_constructors (path ^ ".right_index") right_index
  in
  Ok
    (obj
       [
         ("layout", layout_json);
         ("list", list_json);
         ("left_index", left_index_json);
         ("right_index", right_index_json);
       ])

and list_retain_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
    enum_constructors path list value =
  (* [list_retain_for] is already an explicit ownership operation. Container
     intrinsics often carry managed pointer slots as [Ptr], so deriving this
     bit only from the source type would erase the required retain. Inline
     values must remain false: boxing one solely for a no-op retain leaks the
     temporary box. *)
  let prepared_value = Core_emit_layout.boxed_storage_value ~reg value in
  let needs_release =
    match prepared_value.bsv_box.box_kind with
    | Core.BoxPointer -> true
    | Core.BoxStruct _ ->
        Core_layout_type.is_stack_result_type ~reg value.ty
    | Core.BoxPrim | Core.BoxVoid | Core.BoxFloat | Core.BoxFloat32
    | Core.BoxFloat16 | Core.BoxInt128 | Core.BoxUInt128 -> false
  in
  let boxed_value =
    {
      prepared_value with
      bsv_needs_release = needs_release;
    }
  in
  let* list_json =
    expr_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names enum_constructors
      (path ^ ".list") list
  in
  let* value_json =
    boxed_storage_value_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
      enum_constructors (path ^ ".value") boxed_value
  in
  Ok (obj [ ("list", list_json); ("value", value_json) ])

and resource_exit_json = function
  | Core.ResourceBreak -> str "break"
  | Core.ResourceContinue -> str "continue"

and resource_scope_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
    enum_constructors path (scope : Core.resource_scope) =
  let* typ =
    type_json ~reg enum_names value_record_names heap_record_names union_names (path ^ ".type")
      scope.rs_ty
  in
  let* acquire =
    expr_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names enum_constructors
      (path ^ ".acquire") scope.rs_acquire
  in
  let* body =
    expr_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names enum_constructors
      (path ^ ".body") scope.rs_body
  in
  let* cleanup =
    expr_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names enum_constructors
      (path ^ ".cleanup") scope.rs_cleanup
  in
  Ok
    (obj
       [
         ("var", var_json scope.rs_var);
         ("type", typ);
         ("acquire", acquire);
         ("body", body);
         ("cleanup", cleanup);
       ])

and resource_cleanup_exit_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
    enum_constructors path (cleanup_exit : Core.resource_cleanup_exit) =
  let* cleanups =
    result_list cleanup_exit.rce_cleanups (fun index cleanup ->
        expr_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
          enum_constructors
          (Printf.sprintf "%s.cleanups[%d]" path index)
          cleanup)
  in
  Ok
    (obj
       [
         ("cleanups", cleanups);
         ("exit", resource_exit_json cleanup_exit.rce_exit);
       ])

and require_inline_struct_list_set_value path c_type
    (value : Core.boxed_storage_value) =
  match value.bsv_box.box_kind with
  | Core.BoxStruct value_c_type when String.equal value_c_type c_type -> Ok ()
  | Core.BoxStruct value_c_type ->
      unsupported path
        (Printf.sprintf
           "inline-struct list set value type %s does not match list storage %s"
           value_c_type c_type)
  | Core.BoxPrim | Core.BoxPointer | Core.BoxVoid | Core.BoxFloat
  | Core.BoxFloat32 | Core.BoxFloat16 | Core.BoxInt128 | Core.BoxUInt128 ->
      unsupported path "non-struct inline-struct list set value"

and require_list_set_layout path (layout : Core.list_storage_layout)
    (value : Core.boxed_storage_value) =
  match layout.lsl_slots with
  | Core.ListInlineStructStorage c_type ->
      require_inline_struct_list_set_value (path ^ ".value") c_type value
  | Core.ListPointerStorage ->
      let* _ = box_kind_json (path ^ ".value.kind") value.bsv_box.box_kind in
      Ok ()
  | Core.ListInlineStorage _ ->
      let* _ = box_kind_json (path ^ ".value.kind") value.bsv_box.box_kind in
      Ok ()

and union_representation_json path (uc : Core.union_construct) =
  match uc.uc_representation with
  | Core.OptionUnion layout -> (
      match Core_layout_type.option_constructor_abi_of_layout layout with
      | Core_layout_type.OptionConstructorStackInline abi ->
          Ok
            (kind "stack_option"
               [
                 ("option_type", str abi.soe_c_type);
                 ("tag", int uc.uc_tag);
	             ("none_value", str abi.soe_none_value);
	           ])
      | Core_layout_type.OptionConstructorNullableManaged ->
          Ok (kind "nullable_option" [])
      | Core_layout_type.OptionConstructorBoxedUnion ->
          Ok (kind "boxed_option" [])
      | Core_layout_type.OptionConstructorUnavailable reason ->
          unsupported path ("unavailable Option constructor ABI: " ^ reason))
  | Core.GenericUnion -> Ok (kind "generic" [])
  | Core.ResultUnion result_layout ->
      let abi =
        Core_layout_type.stack_result_constructor_abi_of_layout result_layout
      in
      Ok
        (kind "stack_result"
           [
             ("result_type", str abi.src_result_c_type);
             ("tag", int uc.uc_tag);
             ("release_mask", int uc.uc_release_mask);
           ])

and union_construct_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
    enum_constructors path (uc : Core.union_construct) =
  let* representation =
    union_representation_json (path ^ ".representation") uc
  in
  let* args_json =
    result_list uc.uc_args (fun index arg ->
        boxed_storage_value_json ~function_names ~consumed_params ~reg enum_names value_record_names heap_record_names union_names
          enum_constructors
          (Printf.sprintf "%s.args[%d]" path index)
          arg)
  in
  let uses_release_mask =
    match uc.uc_representation with
    | Core.OptionUnion layout
      when (match Core_layout_type.option_constructor_abi_of_layout layout with
            | Core_layout_type.OptionConstructorBoxedUnion -> true
            | Core_layout_type.OptionConstructorStackInline _
            | Core_layout_type.OptionConstructorNullableManaged
            | Core_layout_type.OptionConstructorUnavailable _ ->
                false) ->
        uc.uc_args <> []
    | _ -> (
        match
          Codegen_types.lookup_union_variant reg uc.uc_type_name
            uc.uc_constructor_name
        with
    | Some variant ->
        (not (Codegen_types.union_uses_typed_payload_storage reg uc.uc_type_name))
        && List.exists
             (fun field_ty ->
               Core_emit_layout.boxed_storage_needs_release ~reg field_ty
                 variant.variant_loc)
             variant.variant_fields
    | None -> uc.uc_release_mask <> 0)
  in
  Ok
    (obj
       [
         ("type_name", str uc.uc_type_name);
         ("constructor_name", str uc.uc_constructor_name);
         ("constructor_c_name", str uc.uc_c_name);
         ("representation", representation);
         ("payload_storage", union_payload_storage_json_for_type ~reg uc.uc_type_name);
         ("uses_release_mask", bool uses_release_mask);
         ("release_mask", int uc.uc_release_mask);
         ("args", args_json);
       ])

let function_kind_json (func : Core.core_func) =
  match func.cf_kind with
  | Core.CFUser -> Ok (kind "user" [])
  | Core.CFBuiltin -> (
      match Core_resolve.builtin_c_name_for_func func with
      | Some c_name -> Ok (kind "builtin" [ ("c_name", str c_name) ])
      | None -> Ok (kind "unresolved_builtin" []))
  | Core.CFForeign foreign ->
      let link_flag_json (platform, flag) =
        obj
          [
            ("platform", option_string_json platform);
            ("flag", str flag);
          ]
      in
      Ok
        (kind "foreign"
           [
             ("c_name", str foreign.c_name);
             ("includes", arr (List.map str foreign.includes));
             ("link_flags", arr (List.map link_flag_json foreign.link_flags));
             ("arg_passing", foreign_arg_passing_json foreign.arg_passing);
           ])

let collect_foreign_includes (program : Core.core_program) =
  let seen = Hashtbl.create 8 in
  let ordered = ref [] in
  let remember header =
    if not (Hashtbl.mem seen header) then begin
      Hashtbl.add seen header ();
      ordered := header :: !ordered
    end
  in
  let rec visit_decl (decl : Core.core_decl) =
    match decl.cd_desc with
    | Core.CDFunc func -> (
        match func.cf_kind with
        | Core.CFForeign { includes; _ } -> List.iter remember includes
        | Core.CFUser | Core.CFBuiltin -> ())
    | Core.CDPrivate inner -> visit_decl inner
    | _ -> ()
  in
  List.iter visit_decl program;
  List.rev !ordered

let var_is_global global_def_ids global_names (variable : Core.var) =
  match variable.vdef_id with
  | Some def_id when IntSet.mem def_id global_def_ids -> true
  | Some _ | None -> StringSet.mem (Core.Var.to_c_name variable) global_names

let expr_uses_global global_def_ids global_names (expr : Core.core) =
  Core.exists_tree
    (fun node ->
      match node.desc with
      | Core.CVar variable -> var_is_global global_def_ids global_names variable
      | _ -> false)
    expr

let globals_used_by_expr global_def_ids global_names (expr : Core.core) =
  Core.fold_tree
    (fun names node ->
      match node.desc with
      | Core.CVar variable when var_is_global global_def_ids global_names variable
        ->
          StringSet.add (Core.Var.to_c_name variable) names
      | _ -> names)
    StringSet.empty expr

let unsupported_global_reference_reason global_def_ids global_names expr =
  match
    globals_used_by_expr global_def_ids global_names expr |> StringSet.elements
  with
  | [] -> "global variable reference"
  | names ->
      Printf.sprintf "global variable reference (%s)" (String.concat ", " names)

let is_void_type = function Ast.TyNamed ("Void", []) -> true | _ -> false

let is_string_type ty =
  match Codegen_types.normalize_type ty with
  | Ast.TyNamed (("String" | "LiteralString"), []) -> true
  | _ -> false

let string_binary_op_supported = function
  | Ast.Eq | Ast.Ne | Ast.Lt | Ast.Le | Ast.Gt | Ast.Ge -> true
  | Ast.Add | Ast.Sub | Ast.Mul | Ast.Div | Ast.Mod -> false

let require_binary_op path op (left : Core.core) (right : Core.core) =
  if (is_string_type left.ty || is_string_type right.ty)
     && not (string_binary_op_supported op)
  then unsupported path "unsupported string binary operator"
  else Ok ()

let list_layout_for_expr (expr : Core.core) =
  Core_layout_type.list_storage_layout_of_type expr.ty expr.loc

let require_emittable_list_store_layout path (layout : Core.list_storage_layout)
    ~inline_scalar_reason ~allow_inline_scalar =
  match layout.lsl_slots with
  | Core.ListPointerStorage | Core.ListInlineStructStorage _ -> Ok ()
  | Core.ListInlineStorage _ when allow_inline_scalar -> Ok ()
  | Core.ListInlineStorage _ ->
      unsupported (path ^ ".layout") inline_scalar_reason

let require_core_arity path name expected args =
  let actual = List.length args in
  if actual = expected then Ok ()
  else
    unsupported path
      (Printf.sprintf "intrinsic call %s expected %d arg(s), got %d" name
         expected actual)

let require_simple_call_kind path ~result_ty ~callee call_kind args =
  match call_kind with
  | Core.CKUser ("Some", _) when is_option_type result_ty ->
      require_core_arity path "Some" 1 args
  | Core.CKUser ("None", _) when is_option_type result_ty ->
      require_core_arity path "None" 0 args
  | Core.CKUser (("Some" | "None"), _) ->
      unsupported path "unprepared Option constructor call"
  | Core.CKBuiltin "blorp_option_some" when is_option_type result_ty ->
      require_core_arity path "blorp_option_some" 1 args
  | Core.CKBuiltin "blorp_option_none" when is_option_type result_ty ->
      require_core_arity path "blorp_option_none" 0 args
  | Core.CKBuiltin ("blorp_result_ok" | "blorp_result_err" as name) ->
      require_core_arity path name 1 args
  | Core.CKUser _ -> Ok ()
  | Core.CKForeign _ -> Ok ()
  | Core.CKBuiltin name
    when Option.is_some (Operation_result_metadata.find_result_bridge name) ->
      Ok ()
  | Core.CKBuiltin name -> (
      match Operation_result_metadata.find_fallible_stream_terminal name with
      | Some terminal ->
          require_core_arity path name
            (List.length terminal.Operation_result_metadata.arguments)
            args
      | None -> (
          match name with
          | "blorp_dict_get" when is_option_type result_ty ->
              require_core_arity path "blorp_dict_get" 2 args
          | "blorp_vector_get_opt" ->
              require_core_arity path "blorp_vector_get_opt" 2 args
          | "blorp_matrix_get_opt" ->
              require_core_arity path "blorp_matrix_get_opt" 3 args
          | "blorp_dict_with_capacity_custom" ->
              require_core_arity path "blorp_dict_with_capacity_custom" 1 args
          | "blorp_list_to_string_cb" ->
              require_core_arity path "blorp_list_to_string_cb" 1 args
          | _ when channel_attempt_builtin_supported name -> (
              match channel_attempt_builtin_arity name with
              | Some arity -> require_core_arity path name arity args
              | None -> unsupported path ("builtin call " ^ name))
          | _ when blorp_specialization_builtin_supported name ->
              require_core_arity path name
                (blorp_specialization_builtin_arity name)
                args
          | _ when blorp_receiver_specialization_builtin name ->
              (* Structural validation runs without the type registry. The
                 call projector separately proves the receiver type before it
                 preserves one of these semantic names for Blorp. *)
              require_core_arity path name 1 args
          | _ when direct_builtin_supported name -> Ok ()
          | _ -> unsupported path ("builtin call " ^ name)))
  | Core.CKIntrinsic _ -> Ok ()
  | Core.CKClosure -> Ok ()
  | Core.CKUnknown ->
      unsupported path
        ("unresolved call kind for callee `" ^ compact_callee_label callee ^ "`")
  | Core.CKSelectedDirect _ -> unsupported path "selected direct call kind"

let rec require_simple_expr path (expr : Core.core) =
  match expr.desc with
  | Core.CLit (Ast.LitInt _ | Ast.LitBool _ | Ast.LitString _) -> Ok ()
  | Core.CLit literal ->
      literal_json (path ^ ".literal") literal |> Result.map ignore
  | Core.CVar _ | Core.CVoid -> Ok ()
  | Core.CCall (Core.CKIntrinsic "list_retain_for", _callee, [ lst; value ]) ->
      let* () = require_simple_expr (path ^ ".list") lst in
      require_simple_expr (path ^ ".value") value
  | Core.CCall
      ( (Core.CKIntrinsic "list_set" | Core.CKIntrinsic "list_set_owned"),
        _callee,
        [ lst; index; value ] ) ->
      let layout = list_layout_for_expr lst in
      let* () =
        require_emittable_list_store_layout path layout
          ~inline_scalar_reason:"inline scalar list set" ~allow_inline_scalar:true
      in
      let* () = require_simple_expr (path ^ ".list") lst in
      let* () = require_simple_expr (path ^ ".index") index in
      require_simple_expr (path ^ ".value") value
  | Core.CCall
      (Core.CKIntrinsic "list_handoff_set_owned", _callee, [ lst; index; value ])
    ->
      let layout = list_layout_for_expr lst in
      let* () =
        require_emittable_list_store_layout path layout
          ~inline_scalar_reason:"inline scalar list handoff set"
          ~allow_inline_scalar:true
      in
      let* () = require_simple_expr (path ^ ".list") lst in
      let* () = require_simple_expr (path ^ ".index") index in
      require_simple_expr (path ^ ".value") value
  | Core.CCall
      ( Core.CKIntrinsic "list_handoff_set_source_slot",
        _callee,
        [ result; out_index; source; source_index ] ) ->
      let* () = require_simple_expr (path ^ ".result") result in
      let* () = require_simple_expr (path ^ ".out_index") out_index in
      let* () = require_simple_expr (path ^ ".source") source in
      require_simple_expr (path ^ ".source_index") source_index
  | Core.CCall (Core.CKIntrinsic "list_swap_slots", _callee, [ lst; i; j ]) ->
      let* () = require_simple_expr (path ^ ".list") lst in
      let* () = require_simple_expr (path ^ ".left_index") i in
      require_simple_expr (path ^ ".right_index") j
  | Core.CCall
      ( (Core.CKBuiltin "blorp_list_new" | Core.CKIntrinsic "list_alloc"),
        _callee,
        [ capacity ] ) ->
      require_simple_expr (path ^ ".capacity") capacity
  | Core.CCall
      ( (Core.CKIntrinsic "list_get" | Core.CKIntrinsic "list_get_unchecked"),
        _callee,
        [ lst; index ] ) ->
      let* () = require_simple_expr (path ^ ".list") lst in
      require_simple_expr (path ^ ".index") index
  | Core.CCall (Core.CKIntrinsic "string_get_byte", _callee, [ source; index ])
    ->
      require_string_byte_read path
        {
          Core.sbr_source = source;
          sbr_index = index;
          sbr_proof = Core.StringReadBoundsProven;
        }
  | Core.CCall
      (Core.CKIntrinsic "string_set_byte", _callee, [ target; index; byte ]) ->
      require_string_byte_write path
        {
          Core.sbw_target = target;
          sbw_index = index;
          sbw_byte = byte;
          sbw_proof = Core.StringWriteBoundsProven;
        }
  | Core.CCall
      ( Core.CKIntrinsic "string_copy_bytes",
        _callee,
        [ dst; dst_pos; src; src_pos; len ] ) ->
      require_string_byte_copy path
        {
          Core.sbc_dst = dst;
          sbc_dst_pos = dst_pos;
          sbc_src = src;
          sbc_src_pos = src_pos;
          sbc_len = len;
          sbc_proof = Core.StringCopyBoundsProven;
        }
  | Core.CCall (Core.CKIntrinsic "string_set_len", _callee, [ target; len ]) ->
      require_string_set_len path
        {
          Core.ssl_target = target;
          ssl_len = len;
          ssl_proof = Core.StringSetLenBoundsProven;
        }
  | Core.CCall (Core.CKBuiltin name, _callee, value :: dims)
    when is_ranked_tensor_fill_factory_name name ->
      let* () = require_simple_expr (path ^ ".value") value in
      require_simple_args (path ^ ".dims") dims
  | Core.CCall
      ( ( Core.CKBuiltin "blorp_dict_new_custom"
        | Core.CKBuiltin "blorp_set_new_custom" ),
        _callee,
        _args ) ->
      Ok ()
  | Core.CCall (call_kind, callee, args) ->
      let* () =
        require_simple_call_kind (path ^ ".call_kind") ~result_ty:expr.ty
          ~callee call_kind args
      in
      require_simple_args path args
  | Core.CBin (op, left, right) ->
      let* () = require_binary_op path op left right in
      let* () = require_simple_expr (path ^ ".left") left in
      require_simple_expr (path ^ ".right") right
  | Core.CUn (_op, inner) -> require_simple_expr (path ^ ".expr") inner
  | Core.CLog (_op, left, right) ->
      let* () = require_simple_expr (path ^ ".left") left in
      require_simple_expr (path ^ ".right") right
  | Core.CCast (inner, _target_ty) -> require_simple_expr (path ^ ".expr") inner
  | Core.CBox (inner, _source_ty) -> require_simple_expr (path ^ ".value") inner
  | Core.CBoxTyped box -> require_box_op path box
  | Core.CUnbox (inner, _target_ty) ->
      require_simple_expr (path ^ ".expr") inner
  | Core.CUnboxTyped unbox -> require_unbox_op path unbox
  | Core.CDup (_variable, _value_ty, body) ->
      require_simple_expr (path ^ ".body") body
  | Core.CDrop (_variable, _value_ty, body) ->
      require_simple_expr (path ^ ".body") body
  | Core.CField (inner, _field_name) ->
      require_simple_expr (path ^ ".expr") inner
  | Core.CTuple items -> require_tuple_literal path expr.ty items
  | Core.CTupleConstruct tc -> require_tuple_construct path tc
  | Core.CVector items -> require_raw_vector_literal path items
  | Core.CList lit -> require_list_literal path lit
  | Core.CListAlloc alloc -> require_list_alloc path alloc
  | Core.CListGet get -> require_list_get path get
  | Core.CListHandoff handoff -> require_list_handoff_simple path handoff
  | Core.CStringByteRead read -> require_string_byte_read path read
  | Core.CStringByteWrite write -> require_string_byte_write path write
  | Core.CStringByteCopy copy -> require_string_byte_copy path copy
  | Core.CStringSetLen set_len -> require_string_set_len path set_len
  | Core.CTensorLiteral literal -> require_tensor_literal path literal
  | Core.CTensorRawRead read -> require_tensor_raw_read path read
  | Core.CTensorRawWrite write -> require_tensor_raw_write path write
  | Core.CTensorRawViewLet (binding, body) ->
      let* () = require_tensor_raw_view_binding (path ^ ".binding") binding in
      require_simple_expr (path ^ ".body") body
  | Core.CDict entries -> require_raw_dict_literal path entries
  | Core.CDictConstruct construct -> require_dict_construct path construct
  | Core.CSetAlloc alloc -> require_set_alloc path alloc
  | Core.CListConstruct lc -> require_list_construct path lc
  | Core.CRecord fields -> require_record_literal path expr.ty fields
  | Core.CRecordConstruct rc -> require_record_construct path rc
  | Core.CUnionConstruct uc -> require_union_construct path uc
  | Core.CLambda _ -> Ok ()
  | Core.CRange (lo, hi) ->
      let* () = require_simple_expr (path ^ ".start") lo in
      require_simple_expr (path ^ ".end") hi
  | Core.CIf (cond, then_expr, else_expr) ->
      let* () = require_simple_expr (path ^ ".cond") cond in
      let* () = require_simple_expr (path ^ ".then") then_expr in
      require_simple_expr (path ^ ".else") else_expr
  | Core.CAssign _ | Core.CLet _ | Core.CSeq _ | Core.CWhile _
  | Core.CCooperativeCheckpoint | Core.CBreak | Core.CContinue ->
      unsupported path
        (Printf.sprintf "statement-shaped expression: %s"
           (Core.pp_to_string expr))
  | _ ->
      unsupported path
        (Printf.sprintf "unsupported simple expression: %s : %s"
           (Core.pp_to_string expr)
           (Types.type_to_string expr.ty))

and require_simple_args path args =
  let rec check index = function
    | [] -> Ok ()
    | arg :: rest ->
        let* () =
          require_simple_expr (Printf.sprintf "%s.args[%d]" path index) arg
        in
        check (index + 1) rest
  in
  check 0 args

and require_raw_vector_literal path items =
  let rec check index = function
    | [] -> Ok ()
    | item :: rest ->
        let* () =
          require_simple_expr (Printf.sprintf "%s.items[%d]" path index) item
        in
        check (index + 1) rest
  in
  check 0 items

and require_raw_dict_literal path entries =
  let rec check index = function
    | [] -> Ok ()
    | (key, value) :: rest ->
        let entry_path = Printf.sprintf "%s.entries[%d]" path index in
        let* () = require_simple_expr (entry_path ^ ".key") key in
        let* () = require_simple_expr (entry_path ^ ".value") value in
        check (index + 1) rest
  in
  check 0 entries

and require_tensor_literal path (literal : Core.tensor_literal) =
  if not (Core.tensor_literal_layout_matches_payload literal.tl_layout literal.tl_payload)
  then
    unsupported path
      (Printf.sprintf
         "tensor literal layout %s does not match payload %s (emit invariant \
          violated)"
         (Core.tensor_storage_slot_layout_str literal.tl_layout.tsl_slots)
         (Core.tensor_storage_slot_layout_str
            (Core.tensor_literal_payload_slot_layout literal.tl_payload)))
  else
    match literal.tl_payload with
  | Core.TensorRawElements (_raw_kind, elements) ->
      require_simple_args (path ^ ".elements") elements
  | Core.TensorBoxedElements elements ->
      let rec check index = function
        | [] -> Ok ()
        | element :: rest ->
            let* () =
              require_pointer_list_element
                (Printf.sprintf "%s.elements[%d]" path index)
                element
            in
            check (index + 1) rest
      in
      check 0 elements
  | Core.TensorPackedElements (_width, elements) ->
      require_simple_args (path ^ ".elements") elements
  | Core.TensorWordElements _ -> unsupported path "word tensor literal"
  | Core.TensorInlineStructElements (_struct_c_type, elements) ->
      require_simple_args (path ^ ".elements") elements

and require_call_args_body ~reg union_names path args =
  let rec check index = function
    | [] -> Ok ()
    | arg :: rest ->
        let* () =
          require_function_body ~reg union_names
            (Printf.sprintf "%s.args[%d]" path index)
            arg
        in
        check (index + 1) rest
  in
  check 0 args

and require_tuple_element path (element : Core.boxed_storage_value) =
  let* _ = tuple_element_tag (path ^ ".kind") element.bsv_box.box_kind in
  require_simple_expr (path ^ ".value") element.bsv_box.box_value

and require_pointer_list_element path (element : Core.boxed_storage_value) =
  let* _ = box_kind_json (path ^ ".kind") element.bsv_box.box_kind in
  require_simple_expr (path ^ ".value") element.bsv_box.box_value

and require_tuple_construct path (tc : Core.tuple_construct) =
  let rec check index = function
    | [] -> Ok ()
    | element :: rest ->
        let* () =
          require_tuple_element
            (Printf.sprintf "%s.construct.elements[%d]" path index)
            element
        in
        check (index + 1) rest
  in
  check 0 tc.tc_elems

and require_tuple_element_body ~reg union_names path
    (element : Core.boxed_storage_value) =
  let* _ = tuple_element_tag (path ^ ".kind") element.bsv_box.box_kind in
  require_function_body ~reg union_names (path ^ ".value")
    element.bsv_box.box_value

and require_tuple_construct_body ~reg union_names path
    (tc : Core.tuple_construct) =
  let rec check index = function
    | [] -> Ok ()
    | element :: rest ->
        let* () =
          require_tuple_element_body ~reg union_names
            (Printf.sprintf "%s.elements[%d]" path index)
            element
        in
        check (index + 1) rest
  in
  check 0 tc.tc_elems

and require_tuple_literal path _ty items =
  let rec check index = function
    | [] -> Ok ()
    | item :: rest ->
        let* () =
          require_simple_expr
            (Printf.sprintf "%s.items[%d]" path index)
            item
        in
        check (index + 1) rest
  in
  check 0 items

and require_tuple_literal_body ~reg union_names path _ty items =
  let rec check index = function
    | [] -> Ok ()
    | item :: rest ->
        let* () =
          require_function_body ~reg union_names
            (Printf.sprintf "%s.items[%d]" path index)
            item
        in
        check (index + 1) rest
  in
  check 0 items

and require_record_literal path ty fields =
  match ty with
  | Ast.TyNamed _ ->
      let rec check index = function
        | [] -> Ok ()
        | (_name, value) :: rest ->
            let* () =
              require_simple_expr
                (Printf.sprintf "%s.fields[%d].value" path index)
                value
            in
            check (index + 1) rest
      in
      check 0 fields
  | _ -> unsupported path "record literal on non-named type"

and require_record_literal_body ~reg union_names path ty fields =
  match ty with
  | Ast.TyNamed _ ->
      let rec check index = function
        | [] -> Ok ()
        | (_name, value) :: rest ->
            let* () =
              require_function_body ~reg union_names
                (Printf.sprintf "%s.fields[%d].value" path index)
                value
            in
            check (index + 1) rest
      in
      check 0 fields
  | _ -> unsupported path "record literal on non-named type"

and require_record_field_arg path = function
  | Core.RecordRawField (_name, value) ->
      require_simple_expr (path ^ ".value") value
  | Core.RecordErasedField _ -> unsupported path "erased record field"

and require_record_construct path (rc : Core.record_construct) =
  if Option.is_some rc.rc_erased_release_mask then
    unsupported path "record construction with erased fields"
  else
    let rec check index = function
      | [] -> Ok ()
      | field :: rest ->
          let* () =
            require_record_field_arg
              (Printf.sprintf "%s.fields[%d]" path index)
              field
          in
          check (index + 1) rest
    in
    check 0 rc.rc_fields

and require_record_field_arg_body ~reg union_names path = function
  | Core.RecordRawField (_name, value) ->
      require_function_body ~reg union_names (path ^ ".value") value
  | Core.RecordErasedField _ -> unsupported path "erased record field"

and require_record_construct_body ~reg union_names path
    (rc : Core.record_construct) =
  if Option.is_some rc.rc_erased_release_mask then
    unsupported path "record construction with erased fields"
  else
    let rec check index = function
      | [] -> Ok ()
      | field :: rest ->
          let* () =
            require_record_field_arg_body ~reg union_names
              (Printf.sprintf "%s.fields[%d]" path index)
              field
          in
          check (index + 1) rest
    in
    check 0 rc.rc_fields

and inline_struct_list_unmanaged (layout : Core.list_storage_layout) =
  match layout.lsl_policy with
  | Core.StoragePolicyUnmanagedBits -> true
  | Core.StoragePolicyManagedPointer | Core.StoragePolicyOwnedErasedBox
  | Core.StoragePolicyUnknown _ ->
      false

and require_inline_struct_list_element path c_type ~allow_element_release_flag
    (value : Core.boxed_storage_value) =
  if value.bsv_needs_release && not allow_element_release_flag then
    unsupported path "managed inline-struct list element"
  else if value.bsv_transfers_ownership && not allow_element_release_flag then
    unsupported path "owned inline-struct list element transfer"
  else
    match value.bsv_box.box_kind with
    | Core.BoxStruct value_c_type when String.equal value_c_type c_type ->
        require_simple_expr (path ^ ".value") value.bsv_box.box_value
    | Core.BoxStruct value_c_type ->
        unsupported path
          (Printf.sprintf
             "inline-struct list element type %s does not match list storage %s"
             value_c_type c_type)
    | Core.BoxPrim | Core.BoxPointer | Core.BoxVoid | Core.BoxFloat
    | Core.BoxFloat32 | Core.BoxFloat16 | Core.BoxInt128 | Core.BoxUInt128 ->
        unsupported path "non-struct inline-struct list element"

and require_list_construct path (lc : Core.list_construct) =
  match lc.lc_layout.lsl_slots with
  | Core.ListInlineStructStorage c_type ->
      let allow_element_release_flag =
        inline_struct_list_unmanaged lc.lc_layout
      in
      if lc.lc_elem_needs_release then
        unsupported path "managed inline-struct list construction"
      else if not allow_element_release_flag then
        unsupported path
          "inline-struct list construction without unmanaged storage policy"
      else
        let rec check index = function
          | [] -> Ok ()
          | element :: rest ->
              let* () =
                require_inline_struct_list_element
                  (Printf.sprintf "%s.elements[%d]" path index)
                  c_type ~allow_element_release_flag element
              in
              check (index + 1) rest
        in
        check 0 lc.lc_elems
  | Core.ListPointerStorage | Core.ListInlineStorage _ ->
      let rec check index = function
        | [] -> Ok ()
        | element :: rest ->
            let* () =
              require_pointer_list_element
                (Printf.sprintf "%s.elements[%d]" path index)
                element
            in
            check (index + 1) rest
      in
      check 0 lc.lc_elems

and require_pointer_list_element_body ~reg union_names path
    (element : Core.boxed_storage_value) =
  let* _ = box_kind_json (path ^ ".kind") element.bsv_box.box_kind in
  require_function_body ~reg union_names (path ^ ".value")
    element.bsv_box.box_value

and require_list_construct_body ~reg union_names path
    (lc : Core.list_construct) =
  match lc.lc_layout.lsl_slots with
  | Core.ListInlineStructStorage _ -> require_list_construct path lc
  | Core.ListPointerStorage | Core.ListInlineStorage _ ->
      let rec check index = function
        | [] -> Ok ()
        | element :: rest ->
            let* () =
              require_pointer_list_element_body ~reg union_names
                (Printf.sprintf "%s.elements[%d]" path index)
                element
            in
            check (index + 1) rest
      in
      check 0 lc.lc_elems

and require_list_literal_body ~reg union_names path (lit : Core.list_literal) =
  match lit.ll_layout.lsl_slots with
  | Core.ListInlineStructStorage _ -> require_list_literal path lit
  | Core.ListPointerStorage | Core.ListInlineStorage _ ->
      let* _ = list_storage_layout_json lit.ll_layout in
      let elems =
        List.map (Core_emit_layout.boxed_storage_value ~reg) lit.ll_elems
      in
      let rec check index = function
        | [] -> Ok ()
        | element :: rest ->
            let* () =
              require_pointer_list_element_body ~reg union_names
                (Printf.sprintf "%s.elements[%d]" path index)
                element
            in
            check (index + 1) rest
      in
      check 0 elems

and require_dict_constructor _path = function
  | Core.DictGeneric | Core.DictString | Core.DictFloat -> Ok ()
  | Core.DictCustom _ -> Ok ()

and require_set_constructor _path = function
  | Core.SetGeneric | Core.SetString | Core.SetFloat -> Ok ()
  | Core.SetCustom _ -> Ok ()

and require_dict_entry path
    ((key, value) : Core.boxed_storage_value * Core.boxed_storage_value) =
  let* () = require_pointer_list_element (path ^ ".key") key in
  require_pointer_list_element (path ^ ".value") value

and require_dict_construct path (construct : Core.dict_construct) =
  let* () =
    require_dict_constructor (path ^ ".constructor") construct.dc_constructor
  in
  let rec check index = function
    | [] -> Ok ()
    | entry :: rest ->
        let* () =
          require_dict_entry (Printf.sprintf "%s.entries[%d]" path index) entry
        in
        check (index + 1) rest
  in
  check 0 construct.dc_entries

and require_set_alloc path (alloc : Core.set_alloc) =
  require_set_constructor (path ^ ".constructor") alloc.sa_constructor

and require_list_literal path (lit : Core.list_literal) =
  let* _ = list_storage_layout_json lit.ll_layout in
  let rec check index = function
    | [] -> Ok ()
    | elem :: rest ->
        let* () =
          require_simple_expr (Printf.sprintf "%s.elements[%d]" path index) elem
        in
        check (index + 1) rest
  in
  check 0 lit.ll_elems

and require_list_alloc path (alloc : Core.list_alloc) =
  let* _ = list_storage_layout_json alloc.la_layout in
  require_simple_expr (path ^ ".capacity") alloc.la_capacity

and require_list_get path (get : Core.list_get) =
  let* _ = list_storage_layout_json get.lg_layout in
  let* () = require_simple_expr (path ^ ".list") get.lg_list in
  require_simple_expr (path ^ ".index") get.lg_index

and require_list_handoff_simple path (handoff : Core.list_handoff) =
  let* _ = list_storage_layout_json handoff.lh_layout in
  let* () = require_simple_expr (path ^ ".source") handoff.lh_source in
  let* () = require_simple_expr (path ^ ".capacity") handoff.lh_capacity in
  require_simple_expr (path ^ ".body") handoff.lh_body

and require_list_handoff_body ~reg union_names path (handoff : Core.list_handoff)
    =
  let* _ = list_storage_layout_json handoff.lh_layout in
  let* () = require_simple_expr (path ^ ".source") handoff.lh_source in
  let* () = require_simple_expr (path ^ ".capacity") handoff.lh_capacity in
  require_function_body ~reg union_names (path ^ ".body") handoff.lh_body

and require_string_byte_read path (read : Core.string_byte_read) =
  match read.sbr_proof with
  | Core.StringReadBoundsProven ->
      let* () = require_simple_expr (path ^ ".source") read.sbr_source in
      require_simple_expr (path ^ ".index") read.sbr_index

and require_string_byte_write path (write : Core.string_byte_write) =
  match write.sbw_proof with
  | Core.StringWriteBoundsProven ->
      let* () = require_simple_expr (path ^ ".target") write.sbw_target in
      let* () = require_simple_expr (path ^ ".index") write.sbw_index in
      require_simple_expr (path ^ ".byte") write.sbw_byte

and require_string_byte_copy path (copy : Core.string_byte_copy) =
  match copy.sbc_proof with
  | Core.StringCopyBoundsProven ->
      let* () = require_simple_expr (path ^ ".dst") copy.sbc_dst in
      let* () = require_simple_expr (path ^ ".dst_pos") copy.sbc_dst_pos in
      let* () = require_simple_expr (path ^ ".src") copy.sbc_src in
      let* () = require_simple_expr (path ^ ".src_pos") copy.sbc_src_pos in
      require_simple_expr (path ^ ".len") copy.sbc_len

and require_string_set_len path (set_len : Core.string_set_len) =
  match set_len.ssl_proof with
  | Core.StringSetLenBoundsProven ->
      let* () = require_simple_expr (path ^ ".target") set_len.ssl_target in
      require_simple_expr (path ^ ".len") set_len.ssl_len

and require_tensor_raw_read path (read : Core.tensor_raw_read) =
  require_simple_expr (path ^ ".index") read.trr_index

and require_tensor_raw_write path (write : Core.tensor_raw_write) =
  let* () = require_simple_expr (path ^ ".index") write.trw_index in
  require_simple_expr (path ^ ".value") write.trw_value

and require_tensor_raw_view_binding path
    (binding : Core.tensor_raw_view_binding) =
  require_simple_expr (path ^ ".source") binding.trv_source

and require_unbox_op path (unbox : Core.unbox_op) =
  let* _ = unbox_kind_json unbox.unbox_kind in
  require_simple_expr (path ^ ".expr") unbox.unbox_value

and require_unbox_op_body ~reg union_names path (unbox : Core.unbox_op) =
  let* _ = unbox_kind_json unbox.unbox_kind in
  require_function_body ~reg union_names (path ^ ".expr") unbox.unbox_value

and require_box_op path (box : Core.box_op) =
  let* _ = box_kind_json (path ^ ".kind") box.box_kind in
  match box.box_kind with
  | Core.BoxPrim | Core.BoxPointer | Core.BoxVoid | Core.BoxStruct _
  | Core.BoxFloat | Core.BoxFloat32 | Core.BoxFloat16 | Core.BoxInt128
  | Core.BoxUInt128 ->
      require_simple_expr (path ^ ".value") box.box_value

and cleanup_release_call_kind_supported path = function
  | Core.CKUser _ -> Ok ()
  | Core.CKBuiltin name when direct_builtin_supported name -> Ok ()
  | Core.CKBuiltin name -> unsupported path ("builtin call " ^ name)
  | Core.CKForeign _ -> unsupported path "foreign call"
  | Core.CKIntrinsic _ -> unsupported path "intrinsic cleanup call"
  | Core.CKClosure -> unsupported path "closure cleanup call"
  | Core.CKUnknown -> unsupported path "unresolved cleanup call"
  | Core.CKSelectedDirect _ -> unsupported path "selected cleanup call"

and require_resource_cleanup_call path cleanup =
  match cleanup.Core.desc with
  | Core.CCall (call_kind, _callee, [ { desc = Core.CVar variable; _ } ]) ->
      let* () =
        cleanup_release_call_kind_supported (path ^ ".call_kind") call_kind
      in
      Ok variable
  | Core.CCall (_call_kind, _callee, _args) ->
      unsupported path
        "resource cleanup must take exactly one resource argument"
  | _ -> unsupported path "resource cleanup must be a direct finalizer call"

and require_resource_scope ~reg union_names path (scope : Core.resource_scope) =
  let* cleanup_var =
    require_resource_cleanup_call (path ^ ".cleanup") scope.rs_cleanup
  in
  if not (Core.Var.equal cleanup_var scope.rs_var) then
    unsupported (path ^ ".cleanup")
      "resource cleanup argument does not match scoped resource"
  else
    let* () = require_simple_expr (path ^ ".acquire") scope.rs_acquire in
    let* () =
      require_function_body ~reg union_names (path ^ ".body") scope.rs_body
    in
    require_function_body ~reg union_names (path ^ ".cleanup") scope.rs_cleanup

and require_resource_cleanup_exit ~reg union_names path
    (cleanup_exit : Core.resource_cleanup_exit) =
  let rec check index = function
    | [] -> Ok ()
    | cleanup :: rest ->
        let cleanup_path = Printf.sprintf "%s.cleanups[%d]" path index in
        let* _ = require_resource_cleanup_call cleanup_path cleanup in
        let* () = require_function_body ~reg union_names cleanup_path cleanup in
        check (index + 1) rest
  in
  check 0 cleanup_exit.rce_cleanups

and require_concurrent_binding ~reg union_names path index
    (binding : Core.conc_binding) =
  let binding_path = Printf.sprintf "%s.bindings[%d]" path index in
  require_function_body ~reg union_names (binding_path ^ ".rhs") binding.cb_rhs

and require_concurrent_block ~reg union_names path
    (block : Core.concurrent_block) =
  let rec check index = function
    | [] -> Ok ()
    | binding :: rest ->
        let* () =
          require_concurrent_binding ~reg union_names path index binding
        in
        check (index + 1) rest
  in
  let* () = check 0 block.conc_bindings in
  let* () =
    match block.conc_timeout with
    | Some timeout ->
        require_function_body ~reg union_names (path ^ ".timeout") timeout
    | None -> Ok ()
  in
  require_function_body ~reg union_names (path ^ ".body") block.conc_body

and require_concurrently_loop ~reg union_names path
    (loop : Core.concurrently_loop) =
  let* _ = concurrently_loop_item_type (path ^ ".item_type") loop in
  let* () =
    require_function_body ~reg union_names (path ^ ".iterable") loop.cf_iter
  in
  let* () =
    require_function_body ~reg union_names (path ^ ".body") loop.cf_body
  in
  let* () =
    match loop.cf_timeout with
    | Some timeout ->
        require_function_body ~reg union_names (path ^ ".timeout") timeout
    | None -> Ok ()
  in
  match loop.cf_width with
  | Core.ConcurrentlyLoopLimit limit ->
      require_function_body ~reg union_names (path ^ ".limit") limit

and require_select_arm_kind ~reg union_names path = function
  | Core.SelectRecv { select_channel; _ } ->
      require_function_body ~reg union_names (path ^ ".channel") select_channel
  | Core.SelectSealed channel ->
      require_function_body ~reg union_names (path ^ ".channel") channel
  | Core.SelectAfter timeout ->
      require_function_body ~reg union_names (path ^ ".timeout") timeout

and require_select_arm ~reg union_names path index (arm : Core.select_arm) =
  let arm_path = Printf.sprintf "%s.arms[%d]" path index in
  let* () =
    require_select_arm_kind ~reg union_names (arm_path ^ ".kind")
      arm.select_arm_kind
  in
  require_function_body ~reg union_names (arm_path ^ ".body")
    arm.select_arm_body

and require_select ~reg union_names path (select_expr : Core.select_expr) =
  let rec check index = function
    | [] -> Ok ()
    | arm :: rest ->
        let* () = require_select_arm ~reg union_names path index arm in
        check (index + 1) rest
  in
  check 0 select_expr.select_arms

and require_stack_option_arg path (value : Core.boxed_storage_value) =
  (* Stack Option payloads are emitted inline. The boxed-storage release flags
     describe the generic void* representation and are not eligibility
     constraints for this constructor ABI. Void payloads carry their effect as a
     statement and store the runtime's sentinel value. *)
  require_simple_expr (path ^ ".value") value.bsv_box.box_value

and require_stack_option_arg_body ~reg union_names path
    (value : Core.boxed_storage_value) =
  (* Stack Option payloads are emitted inline. The boxed-storage release flags
     describe the generic void* representation and are not eligibility
     constraints for this constructor ABI. Void payloads carry their effect as a
     statement and store the runtime's sentinel value. *)
  require_function_body ~reg union_names (path ^ ".value") value.bsv_box.box_value

and require_union_construct path (uc : Core.union_construct) =
  match uc.uc_representation with
  | Core.OptionUnion layout -> (
      match Core_layout_type.option_constructor_abi_of_layout layout with
      | Core_layout_type.OptionConstructorStackInline _ -> (
          match uc.uc_args with
          | [] -> Ok ()
          | [ arg ] -> require_stack_option_arg (path ^ ".args[0]") arg
          | _ -> unsupported path "stack Option constructor arity above one")
      | Core_layout_type.OptionConstructorNullableManaged ->
          (match uc.uc_args with
	          | [] -> Ok ()
	          | [ arg ] -> require_simple_expr (path ^ ".args[0]") arg.bsv_box.box_value
	          | _ -> unsupported path "nullable managed Option constructor arity above one")
	      | Core_layout_type.OptionConstructorBoxedUnion -> (
	          match uc.uc_args with
	          | [] -> Ok ()
	          | [ arg ] ->
	              let* _ = box_kind_json (path ^ ".args[0].kind") arg.bsv_box.box_kind in
	              require_simple_expr (path ^ ".args[0].value") arg.bsv_box.box_value
	          | _ -> unsupported path "boxed Option constructor arity above one")
	      | Core_layout_type.OptionConstructorUnavailable reason ->
	          unsupported path ("unavailable Option constructor ABI: " ^ reason))
  | Core.GenericUnion ->
      let rec check index (args : Core.boxed_storage_value list) =
        match args with
        | [] -> Ok ()
        | arg :: rest ->
            let arg_path = Printf.sprintf "%s.args[%d]" path index in
            let* _ = box_kind_json (arg_path ^ ".kind") arg.bsv_box.box_kind in
            let* () =
              require_simple_expr (arg_path ^ ".value") arg.bsv_box.box_value
            in
            check (index + 1) rest
      in
      check 0 uc.uc_args
  | Core.ResultUnion _ -> (
      match uc.uc_args with
      | [ arg ] ->
          let* _ = box_kind_json (path ^ ".args[0].kind") arg.bsv_box.box_kind in
          require_simple_expr (path ^ ".args[0].value") arg.bsv_box.box_value
      | _ -> unsupported path "stack Result constructor arity above one")

and require_union_construct_body ~reg union_names path
    (uc : Core.union_construct) =
  match uc.uc_representation with
  | Core.OptionUnion layout -> (
      match Core_layout_type.option_constructor_abi_of_layout layout with
      | Core_layout_type.OptionConstructorNullableManaged -> (
          match uc.uc_args with
          | [] -> Ok ()
          | [ arg ] ->
              require_function_body ~reg union_names (path ^ ".args[0]")
                arg.bsv_box.box_value
          | _ -> unsupported path "nullable managed Option constructor arity above one")
      | Core_layout_type.OptionConstructorStackInline _ -> (
          match uc.uc_args with
          | [] -> Ok ()
          | [ arg ] ->
              require_stack_option_arg_body ~reg union_names
                (path ^ ".args[0]") arg
          | _ -> unsupported path "stack Option constructor arity above one")
	      | Core_layout_type.OptionConstructorBoxedUnion -> (
	          match uc.uc_args with
	          | [] -> Ok ()
	          | [ arg ] ->
	              let* _ = box_kind_json (path ^ ".args[0].kind") arg.bsv_box.box_kind in
	              require_function_body ~reg union_names (path ^ ".args[0].value")
	                arg.bsv_box.box_value
	          | _ -> unsupported path "boxed Option constructor arity above one")
	      | Core_layout_type.OptionConstructorUnavailable _ -> require_union_construct path uc)
  | Core.GenericUnion ->
      let rec check index (args : Core.boxed_storage_value list) =
        match args with
        | [] -> Ok ()
        | arg :: rest ->
            let arg_path = Printf.sprintf "%s.args[%d]" path index in
            let* _ = box_kind_json (arg_path ^ ".kind") arg.bsv_box.box_kind in
            let* () =
              require_function_body ~reg union_names (arg_path ^ ".value")
                arg.bsv_box.box_value
            in
            check (index + 1) rest
      in
      check 0 uc.uc_args
  | Core.ResultUnion _ -> (
      match uc.uc_args with
      | [ arg ] ->
          let* _ = box_kind_json (path ^ ".args[0].kind") arg.bsv_box.box_kind in
          require_function_body ~reg union_names (path ^ ".args[0].value")
            arg.bsv_box.box_value
      | _ -> unsupported path "stack Result constructor arity above one")

and require_function_body ~reg union_names path (expr : Core.core) =
  match expr.desc with
  | Core.CLet (binding, body) ->
      if is_void_type binding.bind_ty then
        let* () =
          require_function_body ~reg union_names (path ^ ".rhs")
            binding.bind_rhs
        in
        require_function_body ~reg union_names (path ^ ".body") body
      else if String.equal (Core.Var.to_c_name binding.bind_var) "_" then
        let* () =
          require_function_body ~reg union_names (path ^ ".rhs")
            binding.bind_rhs
        in
        require_function_body ~reg union_names (path ^ ".body") body
      else
        let* () =
          require_function_body ~reg union_names (path ^ ".rhs")
            binding.bind_rhs
        in
        require_function_body ~reg union_names (path ^ ".body") body
  | Core.CBorrowLet (binding, body) ->
      if is_void_type binding.borrow_ty then
        let* () =
          require_function_body ~reg union_names (path ^ ".rhs")
            binding.borrow_rhs
        in
        require_function_body ~reg union_names (path ^ ".body") body
      else if String.equal (Core.Var.to_c_name binding.borrow_var) "_" then
        let* () =
          require_function_body ~reg union_names (path ^ ".rhs")
            binding.borrow_rhs
        in
        require_function_body ~reg union_names (path ^ ".body") body
      else
        let* () =
          require_function_body ~reg union_names (path ^ ".rhs")
            binding.borrow_rhs
        in
        require_function_body ~reg union_names (path ^ ".body") body
  | Core.CAssign (_variable, rhs) ->
      require_function_body ~reg union_names (path ^ ".rhs") rhs
  | Core.CTailrecLoop
      (Core.TailrecUnmanagedLoop { tul_params = _; tul_return_ty; tul_body }) ->
      require_tailrec_tail ~reg union_names (path ^ ".body") tul_return_ty
        tul_body
  | Core.CTailrecLoop
      (Core.TailrecListSpreadLoop { tls_list_param; tls_return_ty; tls_body; _ })
    ->
      require_tailrec_list_spread_body ~reg union_names (path ^ ".body")
        tls_list_param.cp_ty tls_return_ty tls_body
  | Core.CTailrecRecur _ ->
      unsupported path "tail-recursive recur outside tail-recursive loop"
  | Core.CVector items -> require_raw_vector_literal path items
  | Core.CDict entries -> require_raw_dict_literal path entries
  | Core.CTuple items ->
      require_tuple_literal_body ~reg union_names path expr.ty items
  | Core.CTupleConstruct tc ->
      require_tuple_construct_body ~reg union_names path tc
  | Core.CList lit -> require_list_literal_body ~reg union_names path lit
  | Core.CListHandoff handoff ->
      require_list_handoff_body ~reg union_names path handoff
  | Core.CListConstruct lc ->
      require_list_construct_body ~reg union_names path lc
  | Core.CRecord fields ->
      require_record_literal_body ~reg union_names path expr.ty fields
  | Core.CRecordConstruct rc ->
      require_record_construct_body ~reg union_names path rc
  | Core.CUnionConstruct uc ->
      require_union_construct_body ~reg union_names path uc
  | Core.CDetach detach ->
      require_function_body ~reg union_names (path ^ ".body")
        detach.detach_body
  | Core.CCall (Core.CKIntrinsic "list_retain_for", _, [ _; _ ])
  | Core.CCall
      ( Core.CKIntrinsic "list_handoff_set_source_slot",
        _,
        [ _; _; _; _ ] )
  | Core.CCall (Core.CKIntrinsic "list_swap_slots", _, [ _; _; _ ])
  | Core.CCall
      ( (Core.CKBuiltin "blorp_list_new" | Core.CKIntrinsic "list_alloc"),
        _,
        [ _ ] )
  | Core.CCall
      ( (Core.CKIntrinsic "list_get" | Core.CKIntrinsic "list_get_unchecked"),
        _,
        [ _; _ ] ) ->
      require_simple_expr path expr
  | Core.CCall (Core.CKIntrinsic "string_get_byte", _, [ _; _ ])
  | Core.CCall (Core.CKIntrinsic "string_set_byte", _, [ _; _; _ ])
  | Core.CCall (Core.CKIntrinsic "string_copy_bytes", _, [ _; _; _; _; _ ])
  | Core.CCall (Core.CKIntrinsic "string_set_len", _, [ _; _ ]) ->
      require_simple_expr path expr
  | Core.CCall
      ( (Core.CKIntrinsic "list_set" | Core.CKIntrinsic "list_set_owned"),
        _callee,
        [ lst; index; value ] ) ->
      let layout = list_layout_for_expr lst in
      let* () =
        require_emittable_list_store_layout path layout
          ~inline_scalar_reason:"inline scalar list set" ~allow_inline_scalar:true
      in
      let* () = require_simple_expr (path ^ ".list") lst in
      let* () = require_simple_expr (path ^ ".index") index in
      (match layout.lsl_slots with
      | Core.ListPointerStorage ->
          require_function_body ~reg union_names (path ^ ".value") value
      | Core.ListInlineStructStorage _ | Core.ListInlineStorage _ ->
          require_simple_expr (path ^ ".value") value)
  | Core.CCall
      (Core.CKIntrinsic "list_handoff_set_owned", _callee, [ lst; index; value ])
    ->
      let layout = list_layout_for_expr lst in
      let* () =
        require_emittable_list_store_layout path layout
          ~inline_scalar_reason:"inline scalar list handoff set"
          ~allow_inline_scalar:true
      in
      let* () = require_simple_expr (path ^ ".list") lst in
      let* () = require_simple_expr (path ^ ".index") index in
      (match layout.lsl_slots with
      | Core.ListPointerStorage ->
          require_function_body ~reg union_names (path ^ ".value") value
      | Core.ListInlineStructStorage _ | Core.ListInlineStorage _ ->
          require_simple_expr (path ^ ".value") value)
  | Core.CCall (Core.CKClosure, _callee, _args) ->
      require_simple_expr path expr
  | Core.CCall (Core.CKBuiltin name, _callee, _args)
    when is_ranked_tensor_fill_factory_name name ->
      require_simple_expr path expr
  | Core.CCall (Core.CKBuiltin name as call_kind, callee, args)
    when Option.is_some (Operation_result_metadata.find_result_bridge name) ->
      let* () =
        require_simple_call_kind (path ^ ".call_kind") ~result_ty:expr.ty
          ~callee call_kind args
      in
      require_call_args_body ~reg union_names path args
  | Core.CCall (Core.CKBuiltin name as call_kind, callee, args)
    when Option.is_some
           (Operation_result_metadata.find_fallible_stream_terminal name) ->
      let* () =
        require_simple_call_kind (path ^ ".call_kind") ~result_ty:expr.ty
          ~callee call_kind args
      in
      require_call_args_body ~reg union_names path args
  | Core.CCall
      ( ( Core.CKBuiltin "blorp_dict_new_custom"
        | Core.CKBuiltin "blorp_set_new_custom" ),
        _callee,
        _args ) ->
      require_simple_expr path expr
  | Core.CCall (call_kind, callee, args) ->
      let* () =
        require_simple_call_kind (path ^ ".call_kind") ~result_ty:expr.ty
          ~callee call_kind args
      in
      require_call_args_body ~reg union_names path args
  | Core.CSeq (first, second) ->
      let* () =
        require_function_body ~reg union_names (path ^ ".first") first
      in
      require_function_body ~reg union_names (path ^ ".second") second
  | Core.CIf (cond, then_expr, else_expr) -> (
      match require_simple_expr path expr with
      | Ok () -> Ok ()
      | Error _ ->
          let* () =
            require_condition_expr ~reg union_names (path ^ ".cond") cond
          in
          let* () =
            require_function_body ~reg union_names (path ^ ".then") then_expr
          in
          require_function_body ~reg union_names (path ^ ".else") else_expr)
  | Core.CBin (op, left, right) ->
      let* () = require_binary_op path op left right in
      let* () =
        require_function_body ~reg union_names (path ^ ".left") left
      in
      require_function_body ~reg union_names (path ^ ".right") right
  | Core.CUn (_op, inner) ->
      require_function_body ~reg union_names (path ^ ".expr") inner
  | Core.CLog (_op, left, right) ->
      let* () = require_condition_expr ~reg union_names (path ^ ".left") left in
      require_condition_expr ~reg union_names (path ^ ".right") right
  | Core.CCast (inner, _target_ty) ->
      require_function_body ~reg union_names (path ^ ".expr") inner
  | Core.CUnbox (inner, _target_ty) ->
      require_function_body ~reg union_names (path ^ ".expr") inner
  | Core.CUnboxTyped unbox ->
      require_unbox_op_body ~reg union_names path unbox
  | Core.CField (inner, _field_name) ->
      require_function_body ~reg union_names (path ^ ".expr") inner
  | Core.CWhile (cond, body) ->
      let* () =
        require_condition_expr ~reg union_names (path ^ ".cond") cond
      in
      require_function_body ~reg union_names (path ^ ".body") body
  | Core.CFor (_binder, { desc = Core.CRange (lo, hi); _ }, body) ->
      let* () = require_simple_expr (path ^ ".start") lo in
      let* () = require_simple_expr (path ^ ".end") hi in
      require_function_body ~reg union_names (path ^ ".body") body
  | Core.CFor (binder, iter, body) -> (
      match Codegen_types.normalize_type iter.ty with
      | Ast.TyNamed ("Channel", _) ->
          let* () =
            require_function_body ~reg union_names (path ^ ".iterable") iter
          in
          require_function_body ~reg union_names (path ^ ".body") body
      | Ast.TyNamed ("List", _) ->
          let layout = list_layout_for_expr iter in
          let* () =
            require_supported_list_loop_layout (path ^ ".layout") layout
          in
          let* () =
            require_function_body ~reg union_names (path ^ ".iterable") iter
          in
          require_function_body ~reg union_names (path ^ ".body") body
      | Ast.TyNamed ("String", _) ->
          let* () =
            require_function_body ~reg union_names (path ^ ".iterable") iter
          in
          require_function_body ~reg union_names (path ^ ".body") body
      | Ast.TyNamed ("Dict", _) ->
          let* () =
            require_function_body ~reg union_names (path ^ ".iterable") iter
          in
          require_function_body ~reg union_names (path ^ ".body") body
      | Ast.TyNamed ("Set", _) ->
          let* () =
            require_function_body ~reg union_names (path ^ ".iterable") iter
          in
          require_function_body ~reg union_names (path ^ ".body") body
      | Ast.TyNamed ("Range", []) ->
          let* () = require_simple_expr (path ^ ".iterable") iter in
          require_function_body ~reg union_names (path ^ ".body") body
      | Ast.TyNamed (name, _) when Type_name_metadata.is_stream_name name ->
          let* () =
            require_function_body ~reg union_names (path ^ ".iterable") iter
          in
          require_function_body ~reg union_names (path ^ ".body") body
      | Ast.TyNamed (name, [ _resource_ty; _error_ty ])
        when Type_name_metadata.is_resource_source_name name ->
          let* () =
            require_function_body ~reg union_names (path ^ ".iterable") iter
          in
          require_function_body ~reg union_names (path ^ ".body") body
      | ty when Core_tensor_type.is_type ~reg ty ->
          let* () =
            tensor_for_loop_element_storage_json ~reg
	              (path ^ ".element_storage") binder iter
	            |> Result.map ignore
	          in
	          let* () = require_simple_expr (path ^ ".iterable") iter in
	          require_function_body ~reg union_names (path ^ ".body") body
      | ty ->
          unsupported path
            (Printf.sprintf "non-range for loop over %s"
               (Types.type_to_string ty)))
  | Core.CMatch (scrutinee, Core.CTLeaf { ct_bindings; ct_body }) ->
      let* () = require_function_body ~reg union_names (path ^ ".scrutinee") scrutinee in
      let* () =
        require_match_bindings ~reg (scrutinee.ty)
          (path ^ ".bindings") ct_bindings
      in
      require_function_body ~reg union_names (path ^ ".body") ct_body
  | Core.CMatch
      ( scrutinee,
        Core.CTSwitchLit { ctl_scrut; ctl_cases; ctl_default } )
    ->
      require_literal_match_expr ~reg union_names path scrutinee ctl_scrut
        ctl_cases ctl_default
  | Core.CMatch
      ( scrutinee,
        Core.CTSwitchTag { cts_scrut; cts_cases; cts_default } )
    ->
      require_constructor_match_expr ~reg union_names path scrutinee cts_scrut
        cts_cases cts_default
  | Core.CMatch
      ( scrutinee,
        Core.CTSwitchLen
          { ctl_len_scrut; ctl_len_cases; ctl_len_geq; ctl_len_default } )
    ->
      require_length_match_expr ~reg union_names path scrutinee ctl_len_scrut
        ctl_len_cases ctl_len_geq ctl_len_default
  | Core.CMatch _ -> unsupported path "compiled match"
  | Core.CCooperativeCheckpoint -> Ok ()
  | Core.CBreak | Core.CContinue -> Ok ()
  | Core.CResourceScope scope ->
      require_resource_scope ~reg union_names path scope
  | Core.CResourceCleanupExit cleanup_exit ->
      require_resource_cleanup_exit ~reg union_names path cleanup_exit
  | Core.CConcurrent block ->
      require_concurrent_block ~reg union_names path block
  | Core.CConcurrentlyLoop loop ->
      require_concurrently_loop ~reg union_names path loop
  | Core.CSelect select_expr ->
      require_select ~reg union_names path select_expr
  | Core.CTensorRawViewLet (binding, body) ->
      let* () = require_tensor_raw_view_binding (path ^ ".binding") binding in
      require_function_body ~reg union_names (path ^ ".body") body
  | Core.CDup (_variable, value_ty, body) ->
      let _retain_policy = Core_emit_layout.retain_policy_tag ~reg value_ty in
      require_function_body ~reg union_names (path ^ ".body") body
  | Core.CDrop (_variable, value_ty, body) ->
      let _release_policy = Core_emit_layout.release_policy_tag ~reg value_ty in
      require_function_body ~reg union_names (path ^ ".body") body
  | _ -> require_simple_expr path expr

and require_condition_expr ~reg union_names path (cond : Core.core) =
  match require_simple_expr path cond with
  | Ok () -> Ok ()
  | Error _ -> require_function_body ~reg union_names path cond

and require_tailrec_tail ~reg union_names path return_ty (expr : Core.core) =
  match expr.desc with
  | Core.CTailrecRecur (Core.TailrecRecur { tr_args }) ->
      require_simple_args path tr_args
  | Core.CTailrecRecur (Core.TailrecListSpreadRecur _) ->
      unsupported path "list-spread tail-recursive recur"
  | Core.CLet (binding, body) ->
      if is_void_type binding.bind_ty then
        let* () =
          require_function_body ~reg union_names (path ^ ".rhs")
            binding.bind_rhs
        in
        require_tailrec_tail ~reg union_names (path ^ ".body") return_ty body
      else if String.equal (Core.Var.to_c_name binding.bind_var) "_" then
        let* () =
          require_function_body ~reg union_names (path ^ ".rhs")
            binding.bind_rhs
        in
        require_tailrec_tail ~reg union_names (path ^ ".body") return_ty body
      else
        let* () =
          require_function_body ~reg union_names (path ^ ".rhs")
            binding.bind_rhs
        in
        require_tailrec_tail ~reg union_names (path ^ ".body") return_ty body
  | Core.CBorrowLet (binding, body) ->
      if is_void_type binding.borrow_ty then
        let* () =
          require_function_body ~reg union_names (path ^ ".rhs")
            binding.borrow_rhs
        in
        require_tailrec_tail ~reg union_names (path ^ ".body") return_ty body
      else if String.equal (Core.Var.to_c_name binding.borrow_var) "_" then
        let* () =
          require_function_body ~reg union_names (path ^ ".rhs")
            binding.borrow_rhs
        in
        require_tailrec_tail ~reg union_names (path ^ ".body") return_ty body
      else
        let* () =
          require_function_body ~reg union_names (path ^ ".rhs")
            binding.borrow_rhs
        in
        require_tailrec_tail ~reg union_names (path ^ ".body") return_ty body
  | Core.CSeq (first, second) ->
      let* () =
        require_function_body ~reg union_names (path ^ ".first") first
      in
      require_tailrec_tail ~reg union_names (path ^ ".second") return_ty second
  | Core.CIf (cond, then_expr, else_expr) ->
      let* () = require_simple_expr (path ^ ".cond") cond in
      let* () =
        require_tailrec_tail ~reg union_names (path ^ ".then") return_ty
          then_expr
      in
      require_tailrec_tail ~reg union_names (path ^ ".else") return_ty else_expr
  | Core.CMatch (scrutinee, Core.CTLeaf { ct_bindings; ct_body }) ->
      let* () = require_function_body ~reg union_names (path ^ ".scrutinee") scrutinee in
      let* () =
        require_match_bindings ~reg (scrutinee.ty)
          (path ^ ".bindings") ct_bindings
      in
      require_tailrec_tail ~reg union_names (path ^ ".body") return_ty ct_body
  | Core.CMatch
      ( scrutinee,
        Core.CTSwitchLit { ctl_scrut; ctl_cases; ctl_default } )
    ->
      require_tailrec_literal_match_expr ~reg union_names path return_ty
        scrutinee ctl_scrut ctl_cases ctl_default
  | Core.CMatch
      ( scrutinee,
        Core.CTSwitchTag { cts_scrut; cts_cases; cts_default } )
    ->
      require_constructor_match_expr ~reg union_names path scrutinee cts_scrut
        cts_cases cts_default
  | Core.CMatch
      ( scrutinee,
        Core.CTSwitchLen
          { ctl_len_scrut; ctl_len_cases; ctl_len_geq; ctl_len_default } )
    ->
      require_length_match_expr ~reg union_names path scrutinee ctl_len_scrut
        ctl_len_cases ctl_len_geq ctl_len_default
  | Core.CMatch _ -> unsupported path "compiled match"
  | Core.CTailrecLoop _ -> unsupported path "nested tail-recursive loop"
  | Core.CResourceScope scope ->
      require_resource_scope ~reg union_names path scope
  | Core.CResourceCleanupExit cleanup_exit ->
      require_resource_cleanup_exit ~reg union_names path cleanup_exit
  | Core.CTensorRawViewLet (binding, body) ->
      let* () = require_tensor_raw_view_binding (path ^ ".binding") binding in
      require_tailrec_tail ~reg union_names (path ^ ".body") return_ty body
  | Core.CDup (_variable, value_ty, body) ->
      let _retain_policy = Core_emit_layout.retain_policy_tag ~reg value_ty in
      require_tailrec_tail ~reg union_names (path ^ ".body") return_ty body
  | Core.CDrop (_variable, value_ty, body) ->
      let _release_policy = Core_emit_layout.release_policy_tag ~reg value_ty in
      require_tailrec_tail ~reg union_names (path ^ ".body") return_ty body
	  | _ ->
	      if is_void_type return_ty then
	        require_function_body ~reg union_names path expr
	      else require_simple_expr path expr

	and require_tailrec_list_spread_rebinds path rebinds =
	  let rec check index = function
	    | [] -> Ok ()
	    | (_param_index, value) :: rest ->
	        let value_path = Printf.sprintf "%s[%d].value" path index in
	        let* () = require_simple_expr value_path value in
	        check (index + 1) rest
	  in
	  check 0 rebinds

	and require_tailrec_list_spread_body ~reg union_names path list_ty return_ty
	    (expr : Core.core) =
	  require_tailrec_list_spread_tail ~reg union_names path list_ty return_ty expr

	and require_tailrec_list_spread_tail ~reg union_names path list_ty return_ty
	    (expr : Core.core) =
	  match expr.desc with
	  | Core.CTailrecRecur
	      (Core.TailrecListSpreadRecur { tr_rebinds; tr_cursor_advance = _ }) ->
	      require_tailrec_list_spread_rebinds (path ^ ".rebinds") tr_rebinds
	  | Core.CTailrecRecur (Core.TailrecRecur _) ->
	      unsupported path "unmanaged tail-recursive recur in list-spread loop"
	  | Core.CLet (binding, body) ->
	      let* () =
	        require_function_body ~reg union_names (path ^ ".rhs")
	          binding.bind_rhs
	      in
	      require_tailrec_list_spread_tail ~reg union_names (path ^ ".body")
	        list_ty return_ty body
	  | Core.CBorrowLet (binding, body) ->
	      let* () =
	        require_function_body ~reg union_names (path ^ ".rhs")
	          binding.borrow_rhs
	      in
	      require_tailrec_list_spread_tail ~reg union_names (path ^ ".body")
	        list_ty return_ty body
	  | Core.CSeq (first, second) ->
	      let* () =
	        require_function_body ~reg union_names (path ^ ".first") first
	      in
	      require_tailrec_list_spread_tail ~reg union_names (path ^ ".second")
	        list_ty return_ty second
	  | Core.CIf (cond, then_expr, else_expr) ->
	      let* () = require_simple_expr (path ^ ".cond") cond in
	      let* () =
	        require_tailrec_list_spread_tail ~reg union_names (path ^ ".then")
	          list_ty return_ty then_expr
	      in
	      require_tailrec_list_spread_tail ~reg union_names (path ^ ".else")
	        list_ty return_ty else_expr
	  | Core.CMatch (_scrutinee, tree) ->
	      require_tailrec_list_spread_tree ~reg union_names list_ty return_ty
	        (path ^ ".match") tree
	  | Core.CTailrecLoop _ -> unsupported path "nested tail-recursive loop"
	  | Core.CResourceScope scope ->
	      require_resource_scope ~reg union_names path scope
	  | Core.CResourceCleanupExit cleanup_exit ->
	      require_resource_cleanup_exit ~reg union_names path cleanup_exit
	  | Core.CTensorRawViewLet (binding, body) ->
	      let* () = require_tensor_raw_view_binding (path ^ ".binding") binding in
	      require_tailrec_list_spread_tail ~reg union_names (path ^ ".body")
	        list_ty return_ty body
	  | Core.CDup (_variable, value_ty, body) ->
	      let _retain_policy = Core_emit_layout.retain_policy_tag ~reg value_ty in
	      require_tailrec_list_spread_tail ~reg union_names (path ^ ".body")
	        list_ty return_ty body
	  | Core.CDrop (_variable, value_ty, body) ->
	      let _release_policy = Core_emit_layout.release_policy_tag ~reg value_ty in
	      require_tailrec_list_spread_tail ~reg union_names (path ^ ".body")
	        list_ty return_ty body
	  | _ ->
	      if is_void_type return_ty then
	        require_function_body ~reg union_names path expr
	      else require_simple_expr path expr

	and require_tailrec_list_spread_tree ~reg union_names list_ty return_ty path =
	  function
	  | Core.CTLeaf { ct_bindings; ct_body } ->
	      let* () = require_match_bindings ~reg list_ty (path ^ ".bindings") ct_bindings in
	      require_tailrec_list_spread_tail ~reg union_names (path ^ ".body")
	        list_ty return_ty ct_body
	  | Core.CTFail -> Ok ()
	  | Core.CTSwitchLen
	      { ctl_len_scrut; ctl_len_cases; ctl_len_geq; ctl_len_default } ->
	      let* () =
	        match_accessor_json ~reg list_ty (path ^ ".accessor") ctl_len_scrut
	        |> Result.map ignore
	      in
	      let rec check_cases index = function
	        | [] -> Ok ()
	        | (_length, subtree) :: rest ->
	            let case_path = Printf.sprintf "%s.cases[%d]" path index in
	            let* () =
	              require_tailrec_list_spread_tree ~reg union_names list_ty
	                return_ty case_path subtree
	            in
	            check_cases (index + 1) rest
	      in
	      let* () = check_cases 0 ctl_len_cases in
	      let* () =
	        match ctl_len_geq with
	        | None -> Ok ()
	        | Some (_minimum_length, subtree) ->
	            require_tailrec_list_spread_tree ~reg union_names list_ty return_ty
	              (path ^ ".geq.branch") subtree
	      in
	      (match ctl_len_default with
	      | None -> Ok ()
	      | Some subtree ->
	          require_tailrec_list_spread_tree ~reg union_names list_ty return_ty
	            (path ^ ".fallback") subtree)
	  | Core.CTSwitchLit { ctl_scrut; ctl_cases; ctl_default } ->
	      let* () =
	        match_accessor_json ~reg list_ty (path ^ ".accessor") ctl_scrut
	        |> Result.map ignore
	      in
	      let rec check_cases index = function
	        | [] -> Ok ()
	        | (_literal, subtree) :: rest ->
	            let case_path = Printf.sprintf "%s.cases[%d]" path index in
	            let* () =
	              require_tailrec_list_spread_tree ~reg union_names list_ty
	                return_ty case_path subtree
	            in
	            check_cases (index + 1) rest
	      in
	      let* () = check_cases 0 ctl_cases in
	      require_tailrec_list_spread_tree ~reg union_names list_ty return_ty
	        (path ^ ".fallback") ctl_default
	  | Core.CTSwitchTag { cts_scrut; cts_cases; cts_default } ->
	      let* () =
	        match_accessor_json ~reg list_ty (path ^ ".accessor") cts_scrut
	        |> Result.map ignore
	      in
	      let rec check_cases index = function
	        | [] -> Ok ()
	        | (_ctor, subtree) :: rest ->
	            let case_path = Printf.sprintf "%s.cases[%d]" path index in
	            let* () =
	              require_tailrec_list_spread_tree ~reg union_names list_ty
	                return_ty case_path subtree
	            in
	            check_cases (index + 1) rest
	      in
	      let* () = check_cases 0 cts_cases in
	      (match cts_default with
	      | None -> Ok ()
	      | Some subtree ->
	          require_tailrec_list_spread_tree ~reg union_names list_ty return_ty
	            (path ^ ".fallback") subtree)

	and require_literal_match_expr ~reg union_names path scrutinee ctl_scrut cases
	    fallback =
  let* () = require_function_body ~reg union_names (path ^ ".scrutinee") scrutinee in
  let* () =
    match_accessor_json ~reg scrutinee.ty (path ^ ".accessor") ctl_scrut
    |> Result.map ignore
  in
  let reusable_match_scrutinee = true in
  let* () =
    require_literal_match_cases ~reg union_names ~reusable_match_scrutinee
      ~scrut_ty:(scrutinee.ty) (path ^ ".cases") cases
  in
  require_literal_match_fallback ~reg union_names ~reusable_match_scrutinee
    ~scrut_ty:(scrutinee.ty) (path ^ ".fallback") fallback

and require_tailrec_literal_match_expr ~reg union_names path return_ty scrutinee
    ctl_scrut cases fallback =
  let* () =
    require_function_body ~reg union_names (path ^ ".scrutinee") scrutinee
  in
  let* () =
    match_accessor_json ~reg scrutinee.ty (path ^ ".accessor") ctl_scrut
    |> Result.map ignore
  in
  let reusable_match_scrutinee = true in
  let* () =
    require_tailrec_literal_match_cases ~reg union_names
      ~reusable_match_scrutinee ~scrut_ty:(scrutinee.ty)
      (path ^ ".cases") return_ty cases
  in
  require_tailrec_literal_match_fallback ~reg union_names
    ~reusable_match_scrutinee ~scrut_ty:(scrutinee.ty)
    (path ^ ".fallback") return_ty fallback

and require_literal_match_fallback ~reg union_names ~reusable_match_scrutinee
    ~scrut_ty path = function
  | Core.CTLeaf { ct_bindings = []; ct_body } ->
      require_function_body ~reg union_names (path ^ ".body") ct_body
  | Core.CTLeaf { ct_bindings; ct_body } ->
      let* () =
        require_match_bindings ~reg scrut_ty (path ^ ".bindings") ct_bindings
      in
      require_function_body ~reg union_names (path ^ ".body") ct_body
  | Core.CTFail -> Ok ()
  | Core.CTSwitchTag _ -> unsupported path "nested constructor match fallback"
  | Core.CTSwitchLit { ctl_scrut; ctl_cases; ctl_default }
    when reusable_match_scrutinee ->
      let* () =
        match_accessor_json ~reg scrut_ty (path ^ ".accessor") ctl_scrut
        |> Result.map ignore
      in
      let* () =
        require_literal_match_cases ~reg union_names ~reusable_match_scrutinee
          ~scrut_ty (path ^ ".cases") ctl_cases
      in
      require_literal_match_fallback ~reg union_names ~reusable_match_scrutinee
        ~scrut_ty (path ^ ".fallback") ctl_default
  | Core.CTSwitchLit _ -> unsupported path "nested literal match fallback"
  | Core.CTSwitchLen _ as subtree ->
      require_constructor_match_tree ~reg union_names scrut_ty path subtree

and require_tailrec_literal_match_fallback ~reg union_names
    ~reusable_match_scrutinee ~scrut_ty path return_ty subtree =
  require_tailrec_literal_match_tree ~reg union_names
    ~reusable_match_scrutinee ~scrut_ty path return_ty subtree

and require_literal_match_tree ~reg union_names ~reusable_match_scrutinee
    ~scrut_ty path = function
  | Core.CTLeaf { ct_bindings = []; ct_body } ->
      require_function_body ~reg union_names (path ^ ".body") ct_body
  | Core.CTLeaf { ct_bindings; ct_body } ->
      let* () =
        require_match_bindings ~reg scrut_ty (path ^ ".bindings") ct_bindings
      in
      require_function_body ~reg union_names (path ^ ".body") ct_body
  | Core.CTFail -> unsupported path "literal match fail"
  | Core.CTSwitchLit { ctl_scrut; ctl_cases; ctl_default }
    when reusable_match_scrutinee ->
      let* () =
        match_accessor_json ~reg scrut_ty (path ^ ".accessor") ctl_scrut
        |> Result.map ignore
      in
      let* () =
        require_literal_match_cases ~reg union_names ~reusable_match_scrutinee
          ~scrut_ty (path ^ ".cases") ctl_cases
      in
      require_literal_match_fallback ~reg union_names ~reusable_match_scrutinee
        ~scrut_ty (path ^ ".fallback") ctl_default
  | Core.CTSwitchLit _ -> unsupported path "nested literal match"
  | Core.CTSwitchTag _ -> unsupported path "nested constructor match"
  | Core.CTSwitchLen _ -> unsupported path "nested length match"

and require_tailrec_literal_match_tree ~reg union_names
    ~reusable_match_scrutinee ~scrut_ty path return_ty = function
  | Core.CTLeaf { ct_bindings = []; ct_body } ->
      require_tailrec_tail ~reg union_names (path ^ ".body") return_ty ct_body
  | Core.CTLeaf { ct_bindings; ct_body } ->
      let* () =
        require_match_bindings ~reg scrut_ty (path ^ ".bindings") ct_bindings
      in
      require_tailrec_tail ~reg union_names (path ^ ".body") return_ty ct_body
  | Core.CTFail -> Ok ()
  | Core.CTSwitchLit { ctl_scrut; ctl_cases; ctl_default }
    when reusable_match_scrutinee ->
      let* () =
        match_accessor_json ~reg scrut_ty (path ^ ".accessor") ctl_scrut
        |> Result.map ignore
      in
      let* () =
        require_tailrec_literal_match_cases ~reg union_names
          ~reusable_match_scrutinee ~scrut_ty (path ^ ".cases") return_ty
          ctl_cases
      in
      require_tailrec_literal_match_fallback ~reg union_names
        ~reusable_match_scrutinee ~scrut_ty (path ^ ".fallback") return_ty
        ctl_default
  | Core.CTSwitchLit _ -> unsupported path "nested literal match"
  | Core.CTSwitchTag _ -> unsupported path "nested constructor match"
  | Core.CTSwitchLen _ -> unsupported path "nested length match"

and require_literal_match_cases ~reg union_names ~reusable_match_scrutinee
    ~scrut_ty path cases =
  let rec check index = function
    | [] -> Ok ()
    | (literal, subtree) :: rest ->
        let case_path = Printf.sprintf "%s[%d]" path index in
        let* () =
          literal_match_literal_json (case_path ^ ".literal") literal
          |> Result.map ignore
        in
        let* () =
          require_literal_match_tree ~reg union_names ~reusable_match_scrutinee
            ~scrut_ty (case_path ^ ".body") subtree
        in
        check (index + 1) rest
  in
  check 0 cases

and require_tailrec_literal_match_cases ~reg union_names
    ~reusable_match_scrutinee ~scrut_ty path return_ty cases =
  let rec check index = function
    | [] -> Ok ()
    | (literal, subtree) :: rest ->
        let case_path = Printf.sprintf "%s[%d]" path index in
        let* () =
          literal_match_literal_json (case_path ^ ".literal") literal
          |> Result.map ignore
        in
        let* () =
          require_tailrec_literal_match_tree ~reg union_names
            ~reusable_match_scrutinee ~scrut_ty (case_path ^ ".body")
            return_ty subtree
        in
        check (index + 1) rest
  in
  check 0 cases

and require_constructor_match_expr ~reg union_names path scrutinee cts_scrut
    cases fallback =
  let* () = require_function_body ~reg union_names (path ^ ".scrutinee") scrutinee in
  let* () =
    match_accessor_json ~reg scrutinee.ty (path ^ ".accessor") cts_scrut
    |> Result.map ignore
  in
  let* () =
    require_constructor_match_cases ~reg union_names scrutinee.ty
      (path ^ ".cases") cases
  in
  require_constructor_match_fallback ~reg union_names scrutinee.ty
    (path ^ ".fallback") fallback

and require_length_match_expr ~reg union_names path scrutinee len_scrut
    len_cases len_geq len_default =
  let* () =
    require_function_body ~reg union_names (path ^ ".scrutinee") scrutinee
  in
  let* () =
    match_accessor_json ~reg scrutinee.ty (path ^ ".accessor") len_scrut
    |> Result.map ignore
  in
  let* () =
    require_constructor_length_match_cases ~reg union_names scrutinee.ty
      (path ^ ".cases") len_cases
  in
  let* () =
    match len_geq with
    | None -> Ok ()
    | Some (_minimum_length, subtree) ->
        require_constructor_match_tree ~reg union_names scrutinee.ty
          (path ^ ".geq.branch") subtree
  in
  match len_default with
  | None -> Ok ()
  | Some subtree ->
      require_constructor_match_tree ~reg union_names scrutinee.ty
        (path ^ ".fallback") subtree

and require_constructor_match_fallback ~reg union_names scrut_ty path = function
  | None -> Ok ()
  | Some (Core.CTLeaf { ct_bindings = []; ct_body }) ->
      require_function_body ~reg union_names (path ^ ".body") ct_body
  | Some (Core.CTLeaf { ct_bindings; ct_body }) ->
      let* () =
        require_match_bindings ~reg scrut_ty (path ^ ".bindings") ct_bindings
      in
      require_function_body ~reg union_names (path ^ ".body") ct_body
  | Some Core.CTFail -> Ok ()
  | Some (Core.CTSwitchTag { cts_scrut; cts_cases; cts_default }) ->
      let* () =
        match_accessor_json ~reg scrut_ty (path ^ ".accessor") cts_scrut
        |> Result.map ignore
      in
      let* () =
        require_constructor_match_cases ~reg union_names scrut_ty path cts_cases
      in
      require_constructor_match_fallback ~reg union_names scrut_ty path
        cts_default
  | Some (Core.CTSwitchLit { ctl_scrut; ctl_cases; ctl_default }) ->
      let* () =
        match_accessor_json ~reg scrut_ty (path ^ ".accessor") ctl_scrut
        |> Result.map ignore
      in
      let* () =
        require_literal_match_cases ~reg union_names
          ~reusable_match_scrutinee:true ~scrut_ty (path ^ ".cases")
          ctl_cases
      in
      require_literal_match_fallback ~reg union_names
        ~reusable_match_scrutinee:true ~scrut_ty (path ^ ".fallback")
        ctl_default
  | Some (Core.CTSwitchLen _ as subtree) ->
      require_constructor_match_tree ~reg union_names scrut_ty path subtree

and require_match_binding_accessor ~reg scrut_ty path = function
  | Core.AccRoot -> Ok ()
  | accessor -> match_accessor_json ~reg scrut_ty path accessor |> Result.map ignore

and require_match_binding ~reg scrut_ty path (binding : Core.match_binding) =
  match binding.mb_mode with
  | Core.MatchBorrow ->
      require_match_binding_accessor ~reg scrut_ty (path ^ ".accessor")
        binding.mb_accessor
  | Core.MatchOwn -> (
      match binding.mb_accessor with
      | Core.AccVariantField (Core.AccRoot, _, _) ->
          require_match_binding_accessor ~reg scrut_ty (path ^ ".accessor")
            binding.mb_accessor
      | Core.AccListSpread _ ->
          require_match_binding_accessor ~reg scrut_ty (path ^ ".accessor")
            binding.mb_accessor
      | _ -> unsupported path "unsupported owned match binding accessor")

and require_match_bindings ~reg scrut_ty path bindings =
  let rec check index = function
    | [] -> Ok ()
    | binding :: rest ->
        let binding_path = Printf.sprintf "%s[%d]" path index in
        let* () = require_match_binding ~reg scrut_ty binding_path binding in
        check (index + 1) rest
  in
  check 0 bindings

and require_constructor_match_cases ~reg union_names scrut_ty path cases =
  let rec check index = function
    | [] -> Ok ()
    | (_ctor, subtree) :: rest ->
        let case_path = Printf.sprintf "%s[%d]" path index in
        let* () =
          require_constructor_match_tree ~reg union_names scrut_ty case_path
            subtree
        in
        check (index + 1) rest
  in
  check 0 cases

and require_constructor_length_match_cases ~reg union_names scrut_ty path cases =
  let rec check index = function
    | [] -> Ok ()
    | (_length, subtree) :: rest ->
        let case_path = Printf.sprintf "%s[%d]" path index in
        let* () =
          require_constructor_match_tree ~reg union_names scrut_ty
            (case_path ^ ".branch") subtree
        in
        check (index + 1) rest
  in
  check 0 cases

and require_constructor_match_tree ~reg union_names scrut_ty path = function
  | Core.CTLeaf { ct_bindings; ct_body } ->
      let* () =
        require_match_bindings ~reg scrut_ty (path ^ ".bindings") ct_bindings
      in
      require_function_body ~reg union_names (path ^ ".body") ct_body
  | Core.CTSwitchTag { cts_scrut; cts_cases; cts_default } ->
      let* () =
        match_accessor_json ~reg scrut_ty (path ^ ".accessor") cts_scrut
        |> Result.map ignore
      in
      let* () =
        require_constructor_match_cases ~reg union_names scrut_ty
          (path ^ ".cases") cts_cases
      in
      require_constructor_match_fallback ~reg union_names scrut_ty
        (path ^ ".fallback") cts_default
  | Core.CTFail -> Ok ()
  | Core.CTSwitchLit { ctl_scrut; ctl_cases; ctl_default } ->
      let* () =
        match_accessor_json ~reg scrut_ty (path ^ ".accessor") ctl_scrut
        |> Result.map ignore
      in
      let* () =
        require_literal_match_cases ~reg union_names
          ~reusable_match_scrutinee:true ~scrut_ty (path ^ ".cases")
          ctl_cases
      in
      require_literal_match_fallback ~reg union_names
        ~reusable_match_scrutinee:true ~scrut_ty (path ^ ".fallback")
        ctl_default
  | Core.CTSwitchLen
      { ctl_len_scrut; ctl_len_cases; ctl_len_geq; ctl_len_default } ->
      let* () =
        match_accessor_json ~reg scrut_ty (path ^ ".accessor") ctl_len_scrut
        |> Result.map ignore
      in
      let* () =
        require_constructor_length_match_cases ~reg union_names scrut_ty
          (path ^ ".cases") ctl_len_cases
      in
      let* () =
        match ctl_len_geq with
        | None -> Ok ()
        | Some (_minimum_length, subtree) ->
            require_constructor_match_tree ~reg union_names scrut_ty
              (path ^ ".geq.branch") subtree
      in
      (match ctl_len_default with
      | None -> Ok ()
      | Some subtree ->
          require_constructor_match_tree ~reg union_names scrut_ty
            (path ^ ".fallback") subtree)

let function_json ~function_names ~consumed_params ~reg ~enum_names
    ~value_record_names ~heap_record_names ~union_names ~enum_constructors
    ~global_def_ids ~global_names path loc
    (func : Core.core_func) =
  let* params =
    result_list func.cf_params (fun index param ->
        param_json ~reg enum_names value_record_names heap_record_names union_names
          (Printf.sprintf "%s.params[%d]" path index)
          param)
  in
  let* return_type =
    type_json ~reg enum_names value_record_names heap_record_names union_names (path ^ ".return_type")
      func.cf_return_ty
  in
  let* body =
    match func.cf_body with
    | Some body ->
        if expr_uses_global global_def_ids global_names body then
          unsupported (path ^ ".body")
            (unsupported_global_reference_reason global_def_ids global_names body)
        else
          let* () =
            require_function_body ~reg union_names (path ^ ".body") body
          in
          expr_json ~function_names ~consumed_params ~reg enum_names
            value_record_names heap_record_names union_names enum_constructors
            (path ^ ".body") body
    | None -> Ok null
  in
  let* function_kind =
    function_kind_json func
  in
  Ok
    (kind "function"
       [
         ("name", str func.cf_name);
         ("module", option_string_json func.cf_module);
         ( "type_params",
           string_list_json
             (List.map
                (fun (param : Ast.type_param_decl) -> param.param_name)
                func.cf_type_params) );
         ("params", params);
         ("return_type", return_type);
         ("body", body);
         ("pure", bool func.cf_is_pure);
         ("function_kind", function_kind);
         ("def_id", int func.cf_def_id);
         ("loc", source_loc_json loc);
       ])

let project_global_decl (_global : Core.core_var) = true

let global_json ~function_names ~consumed_params ~reg ~is_private enum_names
    value_record_names heap_record_names union_names enum_constructors path loc
    (global : Core.core_var) =
  let* () = require_function_body ~reg union_names (path ^ ".init") global.cv_init in
  let* typ =
    type_json ~reg enum_names value_record_names heap_record_names union_names (path ^ ".type")
      global.cv_ty
  in
  let* init =
    expr_json ~function_names ~consumed_params ~reg enum_names value_record_names
      heap_record_names union_names enum_constructors (path ^ ".init")
      global.cv_init
  in
  Ok
    (kind "global"
       [
         ("name", var_json global.cv_name);
         ("type", typ);
         ("init", init);
         ("mutable", bool global.cv_is_mutable);
         ("const", bool global.cv_is_const);
         ("private", bool is_private);
         ("def_id", int global.cv_def_id);
         ("loc", source_loc_json loc);
       ])

let constructor_c_name name def_id =
  match def_id with
  | Some id -> Codegen_names.mangle_by_def_id id name
  | None -> Codegen_names.sanitize_c_ident name

let enum_variant_json path (variant : Ast.variant) =
  match variant.variant_fields with
  | _ :: _ -> unsupported path "enum variant payload"
  | [] ->
      Ok
        (obj
           [
             ("name", str variant.variant_name);
             ( "c_name",
               str
                 (constructor_c_name variant.variant_name variant.variant_def_id)
             );
             ("tag", int variant.variant_tag);
             ("def_id", option_int_json variant.variant_def_id);
           ])

let enum_decl_json path loc (type_decl : Ast.type_decl) =
  if type_decl.type_params <> [] then
    unsupported path "generic enum declaration"
  else
    let* variants =
      result_list type_decl.type_variants (fun index variant ->
          enum_variant_json
            (Printf.sprintf "%s.variants[%d]" path index)
            variant)
    in
    Ok
      (kind "enum"
         [
           ("name", str type_decl.type_name);
           ("type_params", string_list_json (Ast.type_param_names type_decl.type_params));
           ("variants", variants);
           ("loc", source_loc_json loc);
         ])

let variant_tag_c_name type_name (variant : Ast.variant) =
  Printf.sprintf "TAG_%s_%s"
    (Codegen_names.sanitize_c_ident type_name)
    (Codegen_names.sanitize_c_ident variant.variant_name)

let erased_generic_union_field_type_json field_ty =
  match field_ty with
  | Ast.TyVar _ | Ast.TyBoundVar _ ->
      Some (kind "named" [ ("name", str "Any"); ("args", arr []) ])
  | _ -> None

let union_variant_json ~reg enum_names value_record_names heap_record_names
    union_names type_name path (variant : Ast.variant) =
  let payload_storage = Codegen_types.union_payload_storage reg type_name in
  match variant.variant_fields with
  | fields ->
      let* field_values =
        result_list fields (fun index field_ty ->
            let field_path = Printf.sprintf "%s.fields[%d]" path index in
            let* typ =
              match (payload_storage, erased_generic_union_field_type_json field_ty) with
              | Codegen_types.ErasedUnionPayloadStorage, Some typ -> Ok typ
              | _ ->
                  type_json ~reg enum_names value_record_names heap_record_names
                    union_names (field_path ^ ".type") field_ty
            in
            Ok
              (obj
                 [
                   ("type", typ);
                   ( "release_policy",
                     union_field_release_policy_json ~reg payload_storage field_ty
                       variant.variant_loc );
                 ]))
      in
      Ok
        (obj
           [
             ("name", str variant.variant_name);
             ( "c_name",
               str
                 (constructor_c_name variant.variant_name variant.variant_def_id)
             );
             ("tag_c_name", str (variant_tag_c_name type_name variant));
             ("tag", int variant.variant_tag);
             ("fields", field_values);
             ("def_id", option_int_json variant.variant_def_id);
           ])

let supported_generic_erased_union_decl (type_decl : Ast.type_decl) =
  (String.equal type_decl.type_name "Option"
  || String.equal type_decl.type_name "Result")
  && type_decl.type_params <> []
  && type_decl.type_variants <> []

let union_decl_json ~reg enum_names value_record_names heap_record_names union_names path loc
    (type_decl : Ast.type_decl) =
  if
    type_decl.type_params <> []
    && not (supported_generic_erased_union_decl type_decl)
  then
    unsupported path "generic union declaration"
  else
    let* variants =
      result_list type_decl.type_variants (fun index variant ->
          union_variant_json ~reg enum_names value_record_names heap_record_names union_names
            type_decl.type_name
            (Printf.sprintf "%s.variants[%d]" path index)
            variant)
    in
    Ok
      (kind "union"
         [
           ("name", str type_decl.type_name);
           ("type_params", string_list_json (Ast.type_param_names type_decl.type_params));
           ( "payload_storage",
             union_payload_storage_json_for_type ~reg type_decl.type_name );
           ("variants", variants);
           ("loc", source_loc_json loc);
         ])

let supported_union_decl (type_decl : Ast.type_decl) =
  (not type_decl.type_is_builtin)
  && (not type_decl.type_is_enum)
  && (type_decl.type_params = [] || supported_generic_erased_union_decl type_decl)
  && type_decl.type_variants <> []

let value_record_field_json ~reg enum_names value_record_names heap_record_names
    union_names path (field : Ast.field_decl) =
  let* typ =
    type_json ~reg enum_names value_record_names heap_record_names union_names (path ^ ".type")
      field.field_type
  in
  Ok (obj [ ("name", str field.field_name); ("type", typ) ])

let value_record_decl_json ~reg enum_names value_record_names heap_record_names union_names path loc
    (record_decl : Ast.record_decl) =
  if record_decl.record_type_params <> [] then
    unsupported path "generic value record declaration"
  else
    let* fields =
      result_list record_decl.record_fields (fun index field ->
          value_record_field_json ~reg enum_names value_record_names heap_record_names union_names
            (Printf.sprintf "%s.fields[%d]" path index)
            field)
    in
    Ok
      (kind "value_record"
         [
           ("name", str record_decl.record_name);
           ( "type_params",
             string_list_json (Ast.type_param_names record_decl.record_type_params) );
           ("fields", fields);
           ("loc", source_loc_json loc);
         ])

let heap_record_field_json ~reg enum_names value_record_names heap_record_names union_names path
    (field : Ast.field_decl) =
  if Core_layout_type.record_field_uses_erased_storage ~reg field.field_type then
    unsupported path "heap record field with erased storage"
  else
    let* typ =
      type_json ~reg enum_names value_record_names heap_record_names union_names
        (path ^ ".type") field.field_type
    in
    Ok
      (obj
         [
           ("name", str field.field_name);
           ("type", typ);
           ("release_policy", release_policy_json ~reg field.field_type);
         ])

let heap_record_decl_json ~reg enum_names value_record_names heap_record_names union_names path loc
    (record_decl : Ast.record_decl) =
  if record_decl.record_type_params <> [] then
    unsupported path "generic heap record declaration"
  else
    let* fields =
      result_list record_decl.record_fields (fun index field ->
          heap_record_field_json ~reg enum_names value_record_names
            heap_record_names union_names
            (Printf.sprintf "%s.fields[%d]" path index)
            field)
    in
    Ok
      (kind "heap_record"
         [
           ("name", str record_decl.record_name);
           ( "type_params",
             string_list_json (Ast.type_param_names record_decl.record_type_params) );
           ("fields", fields);
           ("loc", source_loc_json loc);
         ])

let impl_method_c_name (impl : Core.core_impl) (method_func : Core.core_func) =
  let type_name =
    match Codegen_types.type_key_for_impl impl.ci_for_type with
    | Some name -> name
    | None -> "Unknown"
  in
  Printf.sprintf "%s_%s_%s" impl.ci_trait method_func.cf_name type_name

let impl_method_jsons ~function_names ~consumed_params ~reg ~enum_names
    ~value_record_names ~heap_record_names ~union_names ~enum_constructors
    ~global_def_ids ~global_names path loc
    (impl : Core.core_impl) =
  if Codegen_types.has_type_vars impl.ci_for_type then Ok []
  else
    let rec collect acc index = function
      | [] -> Ok (List.rev acc)
      | (method_func : Core.core_func) :: rest ->
          let method_path = Printf.sprintf "%s.methods[%d]" path index in
          let method_func =
            { method_func with cf_name = impl_method_c_name impl method_func }
          in
          if method_func.cf_body = None || method_func.cf_type_params <> [] then
            collect acc (index + 1) rest
          else
            let* json =
              function_json ~function_names ~consumed_params ~reg ~enum_names
                ~value_record_names ~heap_record_names ~union_names
                ~enum_constructors ~global_def_ids ~global_names method_path loc
                method_func
            in
            collect (json :: acc) (index + 1) rest
    in
    collect [] 0 impl.ci_methods

let rec decl_jsons ~function_names ~consumed_params ~reg ~is_private enum_names
    value_record_names heap_record_names union_names enum_constructors
    global_def_ids global_names index (decl : Core.core_decl) =
  let declaration_label =
    match decl.cd_desc with
    | Core.CDFunc func -> "function " ^ func.cf_name
    | Core.CDVar var -> "variable " ^ Core.Var.to_string var.cv_name
    | Core.CDTrait trait -> "trait " ^ trait.ct_name
    | Core.CDType type_decl -> "type " ^ type_decl.type_name
    | Core.CDRecord record_decl -> "record " ^ record_decl.record_name
    | Core.CDImpl impl -> "impl " ^ impl.ci_trait
    | Core.CDImport import_decl -> "import " ^ import_decl.import_module
    | Core.CDTypeAlias alias_decl -> "type alias " ^ alias_decl.alias_name
    | Core.CDPrivate _ -> "private declaration"
  in
  let path =
    Printf.sprintf "program.decls[%d](%s)" index declaration_label
  in
  match decl.cd_desc with
  | Core.CDFunc func when func.cf_body = None || func.cf_type_params <> [] ->
      Ok []
  | Core.CDType type_decl
    when type_decl.type_params <> []
         && not (supported_generic_erased_union_decl type_decl) ->
      Ok []
  | Core.CDRecord record_decl when record_decl.record_type_params <> [] -> Ok []
  | Core.CDFunc func ->
      let* json =
        function_json ~function_names ~consumed_params ~reg ~enum_names
          ~value_record_names ~heap_record_names ~union_names ~enum_constructors
          ~global_def_ids ~global_names path decl.cd_loc func
      in
      Ok [ json ]
  | Core.CDType type_decl
    when type_decl.type_is_enum && not type_decl.type_is_builtin ->
      let* json = enum_decl_json path decl.cd_loc type_decl in
      Ok [ json ]
  | Core.CDType type_decl when supported_union_decl type_decl ->
      let* json =
        union_decl_json ~reg enum_names value_record_names heap_record_names union_names path
          decl.cd_loc type_decl
      in
      Ok [ json ]
  | Core.CDRecord record_decl
    when record_decl.record_is_value && not record_decl.record_is_builtin ->
      let* json =
        value_record_decl_json ~reg enum_names value_record_names heap_record_names union_names path
          decl.cd_loc record_decl
      in
      Ok [ json ]
  | Core.CDRecord record_decl
    when (not record_decl.record_is_value) && not record_decl.record_is_builtin ->
      let* json =
        heap_record_decl_json ~reg enum_names value_record_names heap_record_names
          union_names path decl.cd_loc record_decl
      in
      Ok [ json ]
  | Core.CDImport _ | Core.CDTrait _ | Core.CDType _ | Core.CDTypeAlias _
  | Core.CDRecord _ ->
      Ok []
  | Core.CDPrivate inner ->
      decl_jsons ~function_names ~consumed_params ~reg ~is_private:true
        enum_names value_record_names heap_record_names union_names
        enum_constructors global_def_ids global_names index inner
  | Core.CDVar global when project_global_decl global ->
      let* json =
        global_json ~function_names ~consumed_params ~reg ~is_private enum_names
          value_record_names heap_record_names union_names enum_constructors path
          decl.cd_loc global
      in
      Ok [ json ]
  | Core.CDVar _ -> Ok []
  | Core.CDImpl impl ->
      impl_method_jsons ~function_names ~consumed_params ~reg ~enum_names
        ~value_record_names ~heap_record_names ~union_names ~enum_constructors
        ~global_def_ids ~global_names path decl.cd_loc impl

let program_json ~reg (program : Core.core_program) =
  let rec collect_enum_names names (decl : Core.core_decl) =
    match decl.cd_desc with
    | Core.CDType type_decl
      when type_decl.type_is_enum && not type_decl.type_is_builtin ->
        StringSet.add type_decl.type_name names
    | Core.CDPrivate inner -> collect_enum_names names inner
    | _ -> names
  in
  let rec collect_value_record_names names (decl : Core.core_decl) =
    match decl.cd_desc with
    | Core.CDRecord record_decl
      when record_decl.record_is_value && not record_decl.record_is_builtin ->
        StringSet.add record_decl.record_name names
    | Core.CDPrivate inner -> collect_value_record_names names inner
    | _ -> names
  in
  let rec collect_heap_record_names names (decl : Core.core_decl) =
    match decl.cd_desc with
    | Core.CDRecord record_decl
      when (not record_decl.record_is_value) && not record_decl.record_is_builtin ->
        StringSet.add record_decl.record_name names
    | Core.CDPrivate inner -> collect_heap_record_names names inner
    | _ -> names
  in
  let rec collect_union_names names (decl : Core.core_decl) =
    match decl.cd_desc with
    | Core.CDType type_decl when supported_union_decl type_decl ->
        StringSet.add type_decl.type_name names
    | Core.CDPrivate inner -> collect_union_names names inner
    | _ -> names
  in
  let add_enum_constructor type_name constructors (variant : Ast.variant) =
    StringMap.add
      (enum_constructor_key type_name variant.variant_name)
      (constructor_c_name variant.variant_name variant.variant_def_id)
      constructors
  in
  let rec collect_enum_constructors constructors (decl : Core.core_decl) =
    match decl.cd_desc with
    | Core.CDType type_decl
      when type_decl.type_is_enum && not type_decl.type_is_builtin ->
        List.fold_left
          (add_enum_constructor type_decl.type_name)
          constructors type_decl.type_variants
    | Core.CDType type_decl when supported_union_decl type_decl ->
        List.fold_left
          (add_enum_constructor type_decl.type_name)
          constructors type_decl.type_variants
    | Core.CDPrivate inner -> collect_enum_constructors constructors inner
    | _ -> constructors
  in
  let rec collect_global_def_ids ids (decl : Core.core_decl) =
    match decl.cd_desc with
    | Core.CDVar global -> IntSet.add global.cv_def_id ids
    | Core.CDPrivate inner -> collect_global_def_ids ids inner
    | _ -> ids
  in
  let rec collect_global_names names (decl : Core.core_decl) =
    match decl.cd_desc with
    | Core.CDVar global ->
        StringSet.add (Core.Var.to_c_name global.cv_name) names
    | Core.CDPrivate inner -> collect_global_names names inner
    | _ -> names
  in
  let rec collect_projected_global_def_ids ids (decl : Core.core_decl) =
    match decl.cd_desc with
    | Core.CDVar global when project_global_decl global ->
        IntSet.add global.cv_def_id ids
    | Core.CDPrivate inner -> collect_projected_global_def_ids ids inner
    | _ -> ids
  in
  let rec collect_projected_global_names names (decl : Core.core_decl) =
    match decl.cd_desc with
    | Core.CDVar global when project_global_decl global ->
        StringSet.add (Core.Var.to_c_name global.cv_name) names
    | Core.CDPrivate inner -> collect_projected_global_names names inner
    | _ -> names
  in
  let rec collect_function_names names (decl : Core.core_decl) =
    match decl.cd_desc with
    | Core.CDFunc func when func.cf_body <> None && func.cf_type_params = [] ->
        StringSet.add func.cf_name names
    | Core.CDImpl impl when not (Codegen_types.has_type_vars impl.ci_for_type)
      ->
        List.fold_left
          (fun names (method_func : Core.core_func) ->
            if method_func.cf_body = None || method_func.cf_type_params <> []
            then names
            else StringSet.add (impl_method_c_name impl method_func) names)
          names impl.ci_methods
    | Core.CDPrivate inner -> collect_function_names names inner
    | _ -> names
  in
  let enum_names = List.fold_left collect_enum_names StringSet.empty program in
  let value_record_names =
    List.fold_left collect_value_record_names StringSet.empty program
  in
  let heap_record_names =
    List.fold_left collect_heap_record_names StringSet.empty program
  in
  let union_names =
    List.fold_left collect_union_names StringSet.empty program
  in
  let enum_constructors =
    List.fold_left collect_enum_constructors StringMap.empty program
  in
  let all_global_def_ids =
    List.fold_left collect_global_def_ids IntSet.empty program
  in
  let all_global_names =
    List.fold_left collect_global_names StringSet.empty program
  in
  let projected_global_def_ids =
    List.fold_left collect_projected_global_def_ids IntSet.empty program
  in
  let projected_global_names =
    List.fold_left collect_projected_global_names StringSet.empty program
  in
  let function_names =
    List.fold_left collect_function_names StringSet.empty program
  in
  let consumed_params = collect_consumed_param_indices program in
  let unsupported_global_def_ids =
    IntSet.diff all_global_def_ids projected_global_def_ids
  in
  let unsupported_global_names =
    StringSet.diff all_global_names projected_global_names
  in
  let rec collect acc index = function
    | [] -> Ok (arr (List.rev acc))
    | decl :: rest -> (
        match
          decl_jsons ~function_names ~consumed_params ~reg ~is_private:false enum_names
            value_record_names heap_record_names union_names enum_constructors
            unsupported_global_def_ids unsupported_global_names index decl
        with
        | Ok jsons -> collect (List.rev_append jsons acc) (index + 1) rest
        | Error _ as error -> error)
  in
  let* decls = collect [] 0 program in
  Ok
    (kind "program"
       [
         ("decls", decls);
         ("foreign_includes", string_list_json (collect_foreign_includes program));
       ])

type config = {
  embed_runtime : bool;
  profile : bool;
  reg : Codegen_types.registry;
}

let config_with_embed ~embed_runtime ?(profile = false) ~reg () =
  { embed_runtime; profile; reg }

let with_embedded_runtime (artifact : Compiler_blorp_bridge.c_artifact) =
  {
    artifact with
    Compiler_blorp_bridge.c_code =
      Runtime.runtime_code ^ "\n" ^ artifact.Compiler_blorp_bridge.c_code;
  }

let emit_core_program_to_artifact (config : config)
    (program : Core.core_program) =
  let* core_json = program_json ~reg:config.reg program in
  let artifact =
    Compiler_blorp_bridge.emit_core_c_artifact_exn
      ~profile:config.profile core_json
  in
  Ok (if config.embed_runtime then with_embedded_runtime artifact else artifact)

let emit_program_string config program =
  match emit_core_program_to_artifact config program with
  | Ok artifact -> Ok artifact.Compiler_blorp_bridge.c_code
  | Error _ as error -> error

let try_emit_program_string config program =
  match emit_program_string config program with
  | Ok _ as ok -> ok
  | Error error -> Error (unsupported_to_string error)

let try_emit_core_program_string = try_emit_program_string
