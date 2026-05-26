module N = Codegen_names
(** Builtin Function Registry for blorp Code Generator

    Centralized mapping from (module_path, func_name) to C runtime function names.
    This is the single source of truth for all builtin mappings.
*)

(* ============================================================================
   Naming convention helpers
   ============================================================================ *)

(** Generate ((mod_path, name), "blorp_" ^ name) entries *)
let blorp_prefixed mod_path names =
  List.map (fun name -> ((mod_path, name), "blorp_" ^ name)) names

(** Generate (("", name), name) entries for C passthrough functions *)
let c_passthrough names = List.map (fun name -> (("", name), name)) names

(** Generate ((mod_path, name), prefix ^ name) entries *)
let prefixed_group mod_path prefix names =
  List.map (fun name -> ((mod_path, name), prefix ^ name)) names

(* ============================================================================
   Module groups

   The following module builtin registries were deleted 2026-04-24 in the
   declarative-prelude migration. The corresponding functions now have
   [builtin("blorp_*")] bodies in their stdlib source files (std/io.brp,
   std/system.brp, std/hash.brp, std/debug.brp, std/random.brp, std/crypto_random.brp,
   std/process.brp, std/memory.brp, std/time.brp, std/string.brp).
   Dispatch flows through [Core_resolve]'s user_funcs path (prefixed names like
   [std_io__print]), not through this registry.
   ============================================================================ *)

(* Math C passthrough -- function name = C name *)
let math_passthrough =
  c_passthrough
    [
      "sqrt";
      "sin";
      "cos";
      "tan";
      "floor";
      "ceil";
      "pow";
      "asin";
      "acos";
      "atan";
      "atan2";
      "sinh";
      "cosh";
      "tanh";
      "asinh";
      "acosh";
      "atanh";
      "exp";
      "exp2";
      "log";
      "log2";
      "log10";
      "log1p";
      "expm1";
      "cbrt";
      "hypot";
      "trunc";
      "fmod";
      "copysign";
      "fma";
    ]

(** Scalar math functions that have element-wise tensor backends in the
    runtime ([blorp_vector_sqrt], [blorp_vector_abs], etc.). This is the
    single source of truth consulted by:
    - [infer.ml] arg-compatibility check (allows Tensor arg for scalar param)
    - [infer.ml] return-type lift (Tensor in → Tensor out)
    - [core_specialize.ml] CKBuiltin rewrite (scalar call → vector call)
    Keep in sync with the runtime — only add names that have a
    corresponding [blorp_vector_NAME] function in [runtime.c]. *)
let elementwise_tensor_functions = [ "sqrt"; "abs"; "exp"; "log" ]

let float_class_builtins = blorp_prefixed "" [ "is_nan"; "is_inf"; "is_finite" ]

let float_const_builtins =
  blorp_prefixed "" [ "infinity"; "neg_infinity"; "nan_value" ]

let parallel_list_builtins = []
let parallel_vector_builtins = []
let raylib_module_paths = [ "./raylib"; "../games/raylib"; "./games/raylib" ]

let raylib_builtin_names =
  [
    "init_window";
    "close_window";
    "window_should_close";
    "set_target_fps";
    "get_fps";
    "begin_drawing";
    "end_drawing";
    "clear_background";
    "draw_rectangle";
    "draw_rectangle_rec";
    "draw_rectangle_rounded";
    "draw_circle";
    "draw_line";
    "draw_line_thick";
    "draw_text";
    "set_config_flags";
    "is_key_pressed";
    "is_key_down";
    "get_mouse_x";
    "get_mouse_y";
    "is_mouse_button_pressed";
    "is_mouse_button_down";
    "get_frame_time";
    "get_time";
    "init_audio";
    "close_audio";
    "play_click";
    "set_click_kit";
    "get_num_click_kits";
  ]

let raylib_builtins =
  List.concat_map
    (fun mod_path ->
      prefixed_group mod_path "blorp_raylib_" raylib_builtin_names)
    raylib_module_paths

(* sort and sort_by are now blorp source (merge sort). *)

let matrix_builtins =
  [
    ((N.mod_matrix, "multiply"), "blorp_tensor_matrix_multiply");
    ((N.mod_matrix, "transpose"), "blorp_tensor_transpose");
    ((N.mod_matrix, "multiply_vector"), "blorp_tensor_matrix_vector_multiply");
    ( (N.mod_matrix, "multiply_transposed_vector"),
      "blorp_tensor_transposed_matrix_vector_multiply" );
    ((N.mod_matrix, "outer"), "blorp_tensor_outer");
    ((N.mod_matrix, "get"), "blorp_matrix_get_opt");
    ((N.mod_matrix, "set_cell"), "blorp_matrix_checked_set");
    ((N.mod_matrix, "matrix_checked_get"), "blorp_matrix_checked_get");
    ((N.mod_matrix, "matrix_checked_set"), "blorp_matrix_checked_set");
  ]

(* Matrix kernels resolve through the module-aware builtin table to placeholder
   C names. [Core_specialize] then rewrites those placeholders to the
   element-typed runtime entry and appends static dimensions. Keep them
   module-scoped here so matrix-specific names never resolve as bare builtins. *)

(* String builtins with matching prelude aliases *)
let string_prelude_builtins =
  [
    (* substring, starts_with, ends_with, contains, raw_index_of, count,
     is_numeric, is_ascii, is_blank, is_lower, is_upper → IR in
     core_intrinsics.ml *)
    (* trim, repeat, take/drop_left/right, pad, center, trim_chars, raw_last_index_of → IR *)
    (* upper/lower stay runtime-backed for Unicode expansion and
       context-sensitive case mappings. *)
    ((N.mod_string, "upper"), "blorp_upper");
    ((N.mod_string, "lower"), "blorp_lower");
    ((N.mod_string, "from_char"), "blorp_from_char");
    ((N.mod_string, "from_chars"), "blorp_from_chars");
    ((N.mod_string, "url_encode"), "blorp_url_encode");
    ((N.mod_string, "url_decode"), "blorp_url_decode");
    ((N.mod_string, "html_escape"), "blorp_html_escape");
    ((N.mod_string, "codepoint_length"), "blorp_codepoint_length");
    ((N.mod_string, "codepoints"), "blorp_string_codepoints");
    ((N.mod_string, "codepoint_reverse"), "blorp_codepoint_reverse");
  ]

(* String builtins without prelude aliases. Structural length resolves through
   Core_intrinsic_registry.ir_backed_std_functions, not CKBuiltin. *)
let string_internal_builtins =
  [
    ((N.mod_string, "get"), "blorp_string_get_opt");
    (* drop_left, take_left, trim_left, trim_right, reverse → IR *)
    ((N.mod_string, "base64_encode"), "blorp_base64_encode");
    ((N.mod_string, "base64_decode"), "blorp_base64_decode");
  ]

(* Regex builtins -- prelude names differ *)
let regex_builtins =
  [
    ((N.mod_regex, "test_regex"), "blorp_regex_test");
    ((N.mod_regex, "find"), "blorp_regex_find");
    ((N.mod_regex, "replace_all"), "blorp_regex_replace_all");
    ((N.mod_regex, "find_all"), "blorp_regex_find_all");
  ]

(* Regex removed from prelude — require: import: regex: ... *)

(* combine, intersect, difference, is_subset, map, filter, fold → IR intrinsics
   contains, to_list, length → IR intrinsics *)
let set_builtins =
  [ ((N.mod_set, "set"), "blorp_set_new") ]
  @ prefixed_group N.mod_set "blorp_set_" [ "add"; "remove" ]

let stream_builtins =
  [
    ((N.mod_stream, "from_list"), "blorp_stream_from_list");
    ((N.mod_stream, "from_range"), "blorp_stream_from_range");
    ((N.mod_stream, "repeat"), "blorp_stream_repeat");
    ((N.mod_stream, "unfold"), "blorp_stream_unfold");
    ((N.mod_stream, "empty"), "blorp_stream_empty");
    ((N.mod_stream, "from_lines"), "blorp_stream_from_lines");
    ((N.mod_stream, "map"), "blorp_stream_map");
    ((N.mod_stream, "filter"), "blorp_stream_filter");
    ((N.mod_stream, "filter_map"), "blorp_stream_filter_map");
    ((N.mod_stream, "take"), "blorp_stream_take");
    ((N.mod_stream, "drop"), "blorp_stream_drop");
    ((N.mod_stream, "take_while"), "blorp_stream_take_while");
    ((N.mod_stream, "enumerate"), "blorp_stream_enumerate");
    ((N.mod_stream, "collect"), "blorp_stream_collect");
    ((N.mod_stream, "fold"), "blorp_stream_fold");
    ((N.mod_stream, "count"), "blorp_stream_count");
    ((N.mod_stream, "for_each"), "blorp_stream_for_each");
    ((N.mod_stream, "find"), "blorp_stream_find");
    ((N.mod_stream, "any"), "blorp_stream_any");
    ((N.mod_stream, "all"), "blorp_stream_all");
  ]

(* ============================================================================
   Full builtin mapping
   ============================================================================ *)

(** Mapping from (module_path, func_name) to C runtime function name.
    Module path is "" for Prelude builtins, or "std/module" for module-qualified. *)
let builtin_c_mapping =
  parallel_list_builtins @ parallel_vector_builtins @ math_passthrough
  @ float_class_builtins @ float_const_builtins @ raylib_builtins
  (* Prelude-only builtins (no module counterpart or irregular naming) *)
  @ [
      (("", "to_string"), "blorp_to_string");
      (* [hash] dispatches by argument type in [Core_specialize.specialize_hash];
     this entry maps the source-level [hash(x)] call to the
     polymorphic [blorp_hash] sentinel that the specialize pass
     pattern-matches on. See [specialize_hash] for the per-type
     runtime function each concrete type routes to. *)
      (("", "hash"), "blorp_hash");
      (* [hash_combine(seed, value)] — binary hash mixer used by user
     Hashable impls to combine per-field hashes. Direct mapping to
     the runtime's SplitMix-based combiner; no specialize dispatch
     needed because the signature is (Int, Int) → Int regardless
     of use site. *)
      (("", "hash_combine"), "blorp_hash_combine");
      (("", "to_int"), "blorp_to_int");
      (("", "to_float"), "blorp_to_float");
      (("", "to_bool"), "blorp_to_bool");
      (("", "to_char"), "blorp_to_char");
      (("", "from_char"), "blorp_from_char");
      (("", "from_chars"), "blorp_from_chars");
      (("", "to_int8"), "blorp_to_int8");
      (("", "to_int16"), "blorp_to_int16");
      (("", "to_int32"), "blorp_to_int32");
      (("", "to_int128"), "blorp_to_int128");
      (("", "to_uint8"), "blorp_to_uint8");
      (("", "to_uint16"), "blorp_to_uint16");
      (("", "to_uint32"), "blorp_to_uint32");
      (("", "to_uint64"), "blorp_to_uint64");
      (("", "to_uint128"), "blorp_to_uint128");
      (("", "to_float32"), "blorp_to_float32");
      (("", "to_float16"), "blorp_to_float16");
      (("", "min"), "blorp_min");
      (("", "max"), "blorp_max");
      (* now_us, string_length removed from prelude *)
      (("", "length"), "blorp_length");
      (("", "round"), "blorp_round");
      (* format_float migrated to std/float.brp (2026-04-24).
     bool_to_string removed: 0 call sites across std/tests/examples (2026-04-23). *)
      (("", "checked_div"), "blorp_option_div_int");
      (("", "checked_mod"), "blorp_option_mod_int");
      (("", "assert_shape"), "blorp_assert_shape");
      (("", "checked_get"), "blorp_checked_get");
      (("", "tensor_peel"), "blorp_tensor_peel");
      (("", "checked_set"), "blorp_checked_set");
      (("", "checked_slice"), "blorp_checked_slice");
      (("", "matrix_checked_get"), "blorp_matrix_checked_get");
      (("", "matrix_checked_set"), "blorp_matrix_checked_set");
      (("", "tensor3_checked_get"), "blorp_tensor3_checked_get");
      (("", "tensor3_checked_set"), "blorp_tensor3_checked_set");
      (("", "tensor4_checked_get"), "blorp_tensor4_checked_get");
      (("", "tensor4_checked_set"), "blorp_tensor4_checked_set");
      (("", "tensor5_checked_get"), "blorp_tensor5_checked_get");
      (("", "tensor5_checked_set"), "blorp_tensor5_checked_set");
      ((N.mod_tensor, "checked_get"), "blorp_checked_get");
      ((N.mod_tensor, "tensor_peel"), "blorp_tensor_peel");
      ((N.mod_tensor, "checked_set"), "blorp_checked_set");
      ((N.mod_tensor, "checked_slice"), "blorp_checked_slice");
      ((N.mod_tensor, "matrix_checked_get"), "blorp_matrix_checked_get");
      ((N.mod_tensor, "matrix_checked_set"), "blorp_matrix_checked_set");
      ((N.mod_tensor, "tensor3_checked_get"), "blorp_tensor3_checked_get");
      ((N.mod_tensor, "tensor3_checked_set"), "blorp_tensor3_checked_set");
      ((N.mod_tensor, "tensor4_checked_get"), "blorp_tensor4_checked_get");
      ((N.mod_tensor, "tensor4_checked_set"), "blorp_tensor4_checked_set");
      ((N.mod_tensor, "tensor5_checked_get"), "blorp_tensor5_checked_get");
      ((N.mod_tensor, "tensor5_checked_set"), "blorp_tensor5_checked_set");
      ((N.mod_list, "list"), "blorp_list_new");
      (("", "vector"), "blorp_vector_new_fill");
      (("", "matrix"), "blorp_matrix_new_fill");
      (("", "tensor3"), "blorp_tensor3_new");
      (("", "tensor4"), "blorp_tensor4_new");
      (("", "tensor5"), "blorp_tensor5_new");
      ((N.mod_tensor, "vector"), "blorp_vector_new_fill");
      ((N.mod_tensor, "matrix"), "blorp_matrix_new_fill");
      ((N.mod_tensor, "tensor3"), "blorp_tensor3_new");
      ((N.mod_tensor, "tensor4"), "blorp_tensor4_new");
      ((N.mod_tensor, "tensor5"), "blorp_tensor5_new");
    ]
  (* Tensor/Vector builtins -- prelude names differ *)
  @ [
      ((N.mod_tensor, "length"), "blorp_vector_len");
      ((N.mod_tensor, "get"), "blorp_vector_get_opt");
      ((N.mod_tensor, "set_index"), "blorp_vector_set_cow");
      ((N.mod_vector, "clear"), "blorp_vector_clear");
      ((N.mod_vector, "zip"), "blorp_vector_zip");
      ((N.mod_vector, "max"), "blorp_vector_max_int");
      ((N.mod_vector, "min"), "blorp_vector_min_int");
      ((N.mod_vector, "norm"), "blorp_vector_norm");
      ((N.mod_vector, "cross"), "blorp_vector_cross_float");
      ((N.mod_vector, "exp"), "blorp_vector_exp");
      ((N.mod_vector, "log"), "blorp_vector_log");
      ((N.mod_vector, "sqrt"), "blorp_vector_sqrt");
      ((N.mod_vector, "map"), "blorp_vector_map");
    ]
  (* Matrix builtins — matrix/vector and outer-multiply kernels dispatch through
     [Core_specialize]'s tensor-kernel specialization. *)
  @ matrix_builtins
  (* String builtins *)
  @ string_prelude_builtins
  @ string_internal_builtins
  (* [equals] is an [Equatable] trait method — registered here as a sentinel
     builtin ([blorp_eq_dispatch]) so [Core_resolve] tags call sites with
     [CKBuiltin "blorp_eq_dispatch"]. [Core_specialize] then rewrites
     each call to the correct per-type C function based on arg types. *)
  @ [ (("", "equals"), "blorp_eq_dispatch") ]
  (* Regex builtins *)
  @ regex_builtins
  (* Dict builtins -- contains, get_or, keys, values, entries, length → IR intrinsics *)
  @ [
      ((N.mod_dict, "dict"), "blorp_dict_new");
      ((N.mod_dict, "with_capacity"), "blorp_dict_with_capacity");
      ((N.mod_dict, "get"), "blorp_dict_get");
      ((N.mod_dict, "remove"), "blorp_dict_remove");
    ]
  (* Set builtins -- no prelude aliases *)
  @ set_builtins
  (* Stream builtins *)
  @ stream_builtins
  (* Bytes builtins — new, get, set_index, slice, append, length, fill,
     blit, index_of → IR in core_intrinsics.ml *)
  @ [
      ((N.mod_string, "to_bytes"), "blorp_bytes_from_string");
      ((N.mod_bytes, "to_string"), "blorp_bytes_to_string");
    ]
  (* Bytes: endian ops → blorp source using bitwise ops. from_hex stays builtin *)
  @ prefixed_group N.mod_bytes "blorp_bytes_" [ "from_hex" ]
  @ blorp_prefixed N.mod_bytes [ "encode_utf8"; "decode_utf8" ]
  (* TCP builtins -- no prelude aliases *)
  @ prefixed_group N.mod_tcp "blorp_tcp_"
      [ "listen"; "accept"; "connect"; "read"; "write"; "set_reuse_addr" ]
  @
  (* StringSlice builtins — all moved to IR intrinsics *)
  (* Concurrency builtins *)
  [
    (("", "sleep"), "blorp_sleep");
    (("", "yield_now"), "blorp_yield_now");
    (("", "max_threads"), "blorp_max_threads");
    (("", "channel"), "blorp_channel_new");
    (("", "send"), "blorp_channel_send");
    (("", "recv"), "blorp_channel_recv");
    (("", "try_send"), "blorp_channel_try_send");
    (("", "try_recv"), "blorp_channel_try_recv");
    (("", "recv_timeout"), "blorp_channel_recv_timeout");
    (("", "send_timeout"), "blorp_channel_send_timeout");
    (("", "seal"), "blorp_channel_seal");
    (("", "close"), "blorp_channel_close");
  ]

(** Look up a builtin's C name given its module and function name.
    Returns None if not a registered builtin. Module paths must match an
    explicit registry entry; call sites should canonicalize or register aliases
    instead of relying on basename guesses. *)
let lookup =
  let tbl =
    lazy
      (let h = Hashtbl.create (List.length builtin_c_mapping) in
       List.iter (fun (k, v) -> Hashtbl.replace h k v) builtin_c_mapping;
       h)
  in
  fun module_path func_name ->
    let h = Lazy.force tbl in
    Hashtbl.find_opt h (module_path, func_name)

(** Look up a builtin from the compiler-generated prefixed source name
    ([std_stream__from_list], [std_dict__get], ...).

    This is intentionally derived from [builtin_c_mapping] rather than
    guessing from arbitrary prefixes. It exists for the resolver boundary where
    imported [CVar] children may already have been rewritten to their canonical
    module-qualified source name before the surrounding [CCall] is tagged. *)
let lookup_prefixed =
  let tbl =
    lazy
      (let h = Hashtbl.create (List.length builtin_c_mapping) in
       List.iter
         (fun ((module_path, func_name), c_name) ->
           if module_path <> "" then
             let prefixed =
               Codegen_names.sanitize_module_name module_path ^ "__" ^ func_name
             in
             Hashtbl.replace h prefixed c_name)
         builtin_c_mapping;
       h)
  in
  fun prefixed_name ->
    let h = Lazy.force tbl in
    Hashtbl.find_opt h prefixed_name
