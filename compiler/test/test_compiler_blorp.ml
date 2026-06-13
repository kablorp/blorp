module Ast = Blorp.Ast
module Core = Blorp.Core

let test_loc =
  { Ast.line = 1; column = 1; end_line = 1; end_column = 1; loc_file = None }

let ty_int = Ast.TyNamed ("Int", [])
let ty_bool = Ast.TyNamed ("Bool", [])
let ty_float = Ast.TyNamed ("Float", [])
let ty_string = Ast.TyNamed ("String", [])
let ty_list_int = Ast.TyNamed ("List", [ ty_int ])
let ty_tensor_float = Ast.TyNamed ("Tensor", [ ty_float ])
let ty_float_vector = Ast.TyArray (ty_float, [ Ast.TyConstInt 3 ])
let ty_string_vector = Ast.TyArray (ty_string, [ Ast.TyConstInt 3 ])
let core desc ty : Core.core = { desc; ty; loc = test_loc }
let cvar name ty = core (Core.CVar (Core.Var.named name)) ty
let cint value = core (Core.CLit (Ast.LitInt (Int64.of_int value))) ty_int

let compiler_blorp_rel file =
  Filename.concat (Filename.concat "compiler" "blorp") file

let compiler_lib_rel file =
  Filename.concat (Filename.concat "compiler" "lib") file

let compiler_tool_tests_dir_rel = compiler_blorp_rel "tests"
let core_emit_intrinsic_rel = compiler_lib_rel "core_emit_intrinsic.ml"

let core_emit_list_intrinsic_rel =
  compiler_lib_rel "core_emit_list_intrinsic.ml"

let core_emit_rel = compiler_lib_rel "core_emit.ml"

let core_emit_blorp_prepared_string_rel =
  compiler_lib_rel "core_emit_blorp_prepared_string.ml"

type renderer_spec = {
  name : string;
  tool_rel : string;
  artifact_prefix : string;
  manifest_rel : string;
  embedded_tsv : string;
}

let intrinsic_renderer =
  {
    name = "intrinsic";
    tool_rel = compiler_blorp_rel "codegen_intrinsic_renderer.brp";
    artifact_prefix = "codegen-intrinsic-renderer";
    manifest_rel = compiler_lib_rel "core_emit_blorp_intrinsic_templates.tsv";
    embedded_tsv = Blorp.Core_emit_blorp_intrinsic_templates.tsv;
  }

let prepared_string_renderer =
  {
    name = "prepared string";
    tool_rel = compiler_blorp_rel "codegen_prepared_string_renderer.brp";
    artifact_prefix = "codegen-prepared-string-renderer";
    manifest_rel =
      compiler_lib_rel "core_emit_blorp_prepared_string_templates.tsv";
    embedded_tsv = Blorp.Core_emit_blorp_prepared_string_templates.tsv;
  }

let prepared_list_renderer =
  {
    name = "prepared list";
    tool_rel = compiler_blorp_rel "codegen_prepared_list_renderer.brp";
    artifact_prefix = "codegen-prepared-list-renderer";
    manifest_rel =
      compiler_lib_rel "core_emit_blorp_prepared_list_templates.tsv";
    embedded_tsv = Blorp.Core_emit_blorp_prepared_list_templates.tsv;
  }

let prepared_tensor_renderer =
  {
    name = "prepared tensor";
    tool_rel = compiler_blorp_rel "codegen_prepared_tensor_renderer.brp";
    artifact_prefix = "codegen-prepared-tensor-renderer";
    manifest_rel =
      compiler_lib_rel "core_emit_blorp_prepared_tensor_templates.tsv";
    embedded_tsv = Blorp.Core_emit_blorp_prepared_tensor_templates.tsv;
  }

let find_project_file rel =
  let rec search dir depth =
    let candidate = Filename.concat dir rel in
    if Sys.file_exists candidate then candidate
    else if depth = 0 then
      Alcotest.failf "Cannot locate %s from CWD=%s" rel (Sys.getcwd ())
    else
      let parent = Filename.dirname dir in
      if parent = dir then
        Alcotest.failf "Cannot locate %s from CWD=%s" rel (Sys.getcwd ())
      else search parent (depth - 1)
  in
  search (Sys.getcwd ()) 12

let read_file path =
  let ic = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in ic)
    (fun () -> really_input_string ic (in_channel_length ic))

let cc_args include_dirs link_flags =
  [ "-O0"; "-fwrapv"; "-w" ]
  @ List.concat_map (fun dir -> [ "-I"; dir ]) include_dirs
  @ [ "-lm"; "-lpthread" ]
  @ List.concat_map
      (fun flag -> String.split_on_char ' ' (String.trim flag))
      link_flags

let compile_blorp_tool ~tool_rel ~artifact_prefix =
  let compiler_tool_path = find_project_file tool_rel in
  let source = read_file compiler_tool_path in
  match
    Blorp.Pipeline.compile ~embed_runtime:true ~filename:compiler_tool_path
      ~source ()
  with
  | Error errors ->
      Alcotest.fail
        (Blorp.Diagnostics.format_errors ~file:compiler_tool_path errors)
  | Ok (Blorp.Pipeline.Stopped_at _) ->
      Alcotest.fail "compiler-blorp tool compilation stopped unexpectedly"
  | Ok (Blorp.Pipeline.Compiled { c_code; include_dirs; link_flags; _ }) ->
      let bin_file =
        Blorp.Test_runner.run_artifact_path ~kind:"compiler-blorp"
          ~prefix:artifact_prefix ~suffix:".bin"
      in
      let cc_result, cc_output =
        Blorp.Test_runner.compile_c_from_stdin c_code bin_file
          (cc_args include_dirs link_flags)
      in
      if cc_result <> 0 then
        Alcotest.fail
          ("failed to compile compiler-blorp tool C output\n"
         ^ String.trim cc_output)
      else bin_file

let compile_renderer renderer =
  compile_blorp_tool ~tool_rel:renderer.tool_rel
    ~artifact_prefix:renderer.artifact_prefix

let run_tool bin args =
  Blorp.Test_runner.run_process_capture_timeout ~timeout:(Some 10) bin args

let assert_tool_success bin label args expected =
  let code, output = run_tool bin args in
  Alcotest.(check int) (label ^ " exit code") 0 code;
  Alcotest.(check string) (label ^ " output") expected (String.trim output)

let assert_source_contains source label fragment =
  Alcotest.(check bool) label true (Blorp.Modules.contains source fragment)

let assert_source_not_contains source label fragment =
  Alcotest.(check bool) label false (Blorp.Modules.contains source fragment)

let test_template_substitution_supports_multi_digit_placeholders () =
  let manifest =
    Blorp.Core_emit_blorp_template.create ~label:"test template"
      "multi\t11\t@10@:@0@:@9@\n"
  in
  let args =
    [
      "arg0";
      "arg1";
      "arg2";
      "arg3";
      "arg4";
      "arg5";
      "arg6";
      "arg7";
      "arg8";
      "arg9";
      "arg10";
    ]
  in
  let rendered =
    Blorp.Core_emit_blorp_template.render_exn manifest "multi" args
  in
  Alcotest.(check string)
    "multi-digit placeholder output" "arg10:arg0:arg9" rendered

let test_codegen_intrinsic_renderer_compiles_and_runs_smoke () =
  Blorp.Test_runner.with_run_artifacts (fun () ->
      let bin = compile_renderer intrinsic_renderer in
      assert_tool_success bin "zero-arg intrinsic"
        [ "intrinsic"; "math_nan" ]
        "(0.0/0.0)";
      assert_tool_success bin "one-arg intrinsic"
        [ "intrinsic"; "math_sqrt"; "__x" ]
        "sqrt(__x)";
      assert_tool_success bin "two-arg intrinsic"
        [ "intrinsic"; "math_pow"; "__base"; "__exp" ]
        "pow(__base, __exp)";
      assert_tool_success bin "three-arg intrinsic"
        [ "intrinsic"; "math_fma"; "a"; "b"; "c" ]
        "fma(a, b, c)")

let test_renderer_manifest_matches_checked_in_templates renderer =
  Blorp.Test_runner.with_run_artifacts (fun () ->
      let bin = compile_renderer renderer in
      let code, output = run_tool bin [ "manifest" ] in
      Alcotest.(check int) (renderer.name ^ " manifest exit code") 0 code;
      let manifest_path = find_project_file renderer.manifest_rel in
      let manifest = read_file manifest_path in
      Alcotest.(check string)
        ("generated " ^ renderer.name
       ^ " manifest matches checked-in template manifest")
        (String.trim manifest) (String.trim output);
      Alcotest.(check string)
        ("embedded " ^ renderer.name
       ^ " template module matches checked-in manifest")
        (String.trim manifest)
        (String.trim renderer.embedded_tsv))

let test_core_emit_delegates_initial_slice_to_blorp_manifest () =
  let core_emit_intrinsic_path = find_project_file core_emit_intrinsic_rel in
  let source = read_file core_emit_intrinsic_path in
  assert_source_contains source "production emitter calls Blorp manifest bridge"
    "Core_emit_blorp_intrinsic.emit";
  List.iter
    (fun fragment ->
      assert_source_not_contains source
        ("production emitter removed old OCaml arm: " ^ fragment)
        fragment)
    [
      "| \"bit_and\"";
      "| \"bit_or\"";
      "| \"bit_xor\"";
      "| \"bit_not\"";
      "| \"shift_left\"";
      "| \"shift_right\"";
      "| \"elem_release_fn\"";
      "| \"list_get\"";
      "| \"list_len\"";
      "| \"list_capacity\"";
      "| \"list_set_len\"";
      "| \"list_reverse_owned\"";
      "| \"list_release_elem\"";
      "| \"list_set_elem_release\"";
      "| \"string_get_byte\"";
      "| \"string_len\"";
      "| \"string_alloc\"";
      "| \"string_set_byte\"";
      "| \"string_ensure_unique\"";
      "| \"string_ensure_capacity\"";
      "| \"bytes_get\"";
      "| \"bytes_len\"";
      "| \"bytes_set\"";
      "| \"bytes_alloc\"";
      "| \"bytes_set_len\"";
      "| \"bytes_cow\"";
      "| \"dict_len\"";
      "| \"set_len\"";
      "| \"set_capacity\"";
      "| \"set_mask\"";
      "| \"set_bucket\"";
      "| \"set_first\"";
      "| \"set_last\"";
      "| \"set_entry_key\"";
      "| \"set_entry_next\"";
      "| \"set_entry_prev_order\"";
      "| \"set_entry_next_order\"";
      "| \"set_set_len\"";
      "| \"set_set_bucket\"";
      "| \"set_set_first\"";
      "| \"set_set_last\"";
      "| \"set_entry_set_next\"";
      "| \"set_entry_set_prev_order\"";
      "| \"set_entry_set_next_order\"";
      "| \"set_hash\"";
      "| \"set_eq\"";
      "| \"set_hash_immediate\"";
      "| \"set_eq_immediate\"";
      "| \"set_retain_key_for\"";
      "| \"set_alloc\"";
      "| \"set_alloc_entry\"";
      "| \"set_free_entry\"";
      "| \"set_cow\"";
      "| \"set_reuse_alloc\"";
      "| \"set_resize\"";
      "| \"set_reserve_for_len\"";
      "| \"dict_capacity\"";
      "| \"dict_mask\"";
      "| \"dict_grow_at\"";
      "| \"dict_key_at\"";
      "| \"dict_value_at\"";
      "| \"dict_meta_get\"";
      "| \"dict_order_get\"";
      "| \"dict_order_len\"";
      "| \"dict_order_index_get\"";
      "| \"dict_key_release_fn\"";
      "| \"dict_value_release_fn\"";
      "| \"dict_set_len\"";
      "| \"dict_set_key_at\"";
      "| \"dict_set_value_at\"";
      "| \"dict_meta_set\"";
      "| \"dict_order_set\"";
      "| \"dict_set_order_len\"";
      "| \"dict_order_index_set\"";
      "| \"dict_hash\"";
      "| \"dict_eq\"";
      "| \"dict_hash_immediate\"";
      "| \"dict_eq_immediate\"";
      "| \"dict_retain_key_for\"";
      "| \"dict_retain_value_for\"";
      "| \"dict_release_value_for\"";
      "| \"dict_alloc\"";
      "| \"dict_cow\"";
      "| \"dict_reuse_alloc\"";
      "| \"dict_resize\"";
      "| \"slice_source\"";
      "| \"slice_start\"";
      "| \"slice_len\"";
      "| \"slice_alloc\"";
      "| \"tensor_is_unique\"";
      "| \"tensor_len\"";
      "| \"tensor_capacity\"";
      "| \"tensor_get_i64_word_unchecked\"";
      "| \"tensor_get_i64_raw_unchecked\"";
      "| \"tensor_get_f64\"";
      "| \"tensor_get_f32\"";
      "| \"tensor_get_f16\"";
      "| \"tensor_set_f64\"";
      "| \"tensor_set_f32\"";
      "| \"tensor_set_f16\"";
      "| \"tensor_get_i64\"";
      "| \"tensor_set_i64\"";
      "| \"fixed_alloc\"";
      "| \"fixed_value\"";
      "| \"fixed_scale\"";
      "| \"fixed_precision\"";
      "| \"fixed_pow10\"";
      "String.sub name 5";
      "math_sqrt";
    ]

let test_core_emit_delegates_prepared_string_slice_to_blorp_manifest () =
  let core_emit_path = find_project_file core_emit_rel in
  let core_emit_intrinsic_path = find_project_file core_emit_intrinsic_rel in
  let core_emit_blorp_prepared_string_path =
    find_project_file core_emit_blorp_prepared_string_rel
  in
  let core_emit_source = read_file core_emit_path in
  let core_emit_intrinsic_source = read_file core_emit_intrinsic_path in
  let prepared_string_source = read_file core_emit_blorp_prepared_string_path in
  let source =
    core_emit_source ^ "\n" ^ core_emit_intrinsic_source ^ "\n"
    ^ prepared_string_source
  in
  let old_body_source = core_emit_source ^ "\n" ^ core_emit_intrinsic_source in
  assert_source_contains source
    "production emitter delegates string find-byte intrinsic"
    "Core_emit_blorp_prepared_string.emit_find_byte_from";
  assert_source_contains source
    "production emitter calls Blorp prepared string bridge"
    "Core_emit_blorp_prepared_string.emit_byte_read";
  assert_source_contains source "production emitter delegates string byte copy"
    "Core_emit_blorp_prepared_string.emit_byte_copy";
  assert_source_contains source "raw string byte-copy fallback delegates"
    "Core_emit_blorp_prepared_string.emit_byte_copy_intrinsic";
  assert_source_contains source "raw string set-len fallback delegates"
    "Core_emit_blorp_prepared_string.emit_set_len_intrinsic";
  List.iter
    (fun fragment ->
      assert_source_not_contains old_body_source
        ("production emitter removed old prepared string body: " ^ fragment)
        fragment)
    [
      "emit ctx \"(long)(unsigned char)((blorp_String*)\"";
      "emit ctx \"(((blorp_String*)\"";
      "let dst_tmp = Printf.sprintf \"__string_copy_dst_%d\" id";
      "emit ctx \"({ blorp_String* __sl = (blorp_String*)\"";
    ]

let test_core_emit_delegates_prepared_list_slice_to_blorp_manifest () =
  let core_emit_path = find_project_file core_emit_rel in
  let core_emit_list_intrinsic_path =
    find_project_file core_emit_list_intrinsic_rel
  in
  let core_emit_intrinsic_path = find_project_file core_emit_intrinsic_rel in
  let source =
    read_file core_emit_path ^ "\n"
    ^ read_file core_emit_list_intrinsic_path
    ^ "\n"
    ^ read_file core_emit_intrinsic_path
  in
  assert_source_contains source
    "production emitter calls Blorp prepared list bridge"
    "Core_emit_blorp_prepared_list.emit_get";
  assert_source_contains source
    "production emitter delegates inline struct list loads"
    "Core_emit_blorp_prepared_list.emit_inline_struct_dynamic_load";
  assert_source_contains source "production emitter delegates inline bit loads"
    "Core_emit_blorp_prepared_list.emit_inline_bits_load";
  assert_source_contains source "production emitter delegates inline bit stores"
    "Core_emit_blorp_prepared_list.emit_inline_bits_store";
  assert_source_contains source
    "production emitter delegates pointer set-raw stores"
    "Core_emit_blorp_prepared_list.emit_pointer_set_raw_store";
  assert_source_contains source
    "production emitter delegates pointer handoff-owned stores"
    "Core_emit_blorp_prepared_list.emit_pointer_handoff_set_owned_store";
  assert_source_contains source
    "production emitter delegates inline struct set-raw stores"
    "Core_emit_blorp_prepared_list.emit_inline_struct_set_raw_store";
  assert_source_contains source
    "production emitter delegates inline struct handoff-owned stores"
    "Core_emit_blorp_prepared_list.emit_inline_struct_handoff_set_owned_store";
  assert_source_contains source "production emitter delegates pointer swaps"
    "Core_emit_blorp_prepared_list.emit_pointer_swap";
  assert_source_contains source "production emitter delegates inline bit swaps"
    "Core_emit_blorp_prepared_list.emit_inline_bits_swap";
  assert_source_contains source
    "production emitter delegates inline struct swaps"
    "Core_emit_blorp_prepared_list.emit_inline_struct_swap";
  assert_source_contains source
    "production emitter delegates list handoff source slots"
    "Core_emit_blorp_prepared_list.emit_handoff_set_source_slot";
  assert_source_contains source "production emitter delegates list copy spans"
    "Core_emit_blorp_prepared_list.emit_copy_span_uninit";
  assert_source_contains source "production emitter delegates list COW checks"
    "Core_emit_blorp_prepared_list.emit_ensure_unique";
  assert_source_contains source
    "production emitter delegates list capacity checks"
    "Core_emit_blorp_prepared_list.emit_ensure_capacity";
  assert_source_contains source "production emitter delegates list reuse alloc"
    "Core_emit_blorp_prepared_list.emit_reuse_alloc";
  assert_source_contains source "production emitter delegates list retain-for"
    "Core_emit_blorp_prepared_list.emit_retain_for";
  assert_source_contains source "production emitter delegates list allocation"
    "Core_emit_blorp_prepared_list.emit_alloc_call";
  assert_source_contains source
    "production emitter delegates release-wrapped list allocation"
    "Core_emit_blorp_prepared_list.render_alloc_with_release";
  assert_source_contains source
    "production emitter delegates list construct inline struct stores"
    "Core_emit_blorp_prepared_list.emit_construct_inline_struct_set";
  assert_source_contains source
    "production emitter delegates list construct appends"
    "Core_emit_blorp_prepared_list.emit_construct_append";
  assert_source_contains source
    "production emitter rejects unprepared tuple literals"
    "unprepared CTuple reached emission";
  assert_source_contains source
    "production emitter rejects unprepared list literals"
    "unprepared CList reached emission";
  List.iter
    (fun fragment ->
      assert_source_not_contains source
        ("production emitter removed old prepared list body: " ^ fragment)
        fragment)
    [
      "emit ctx \"blorp_list_get((blorp_List*)\"";
      "({ uintptr_t %s = 0; memcpy(&%s, (char*)%s->data";
      "uintptr_t %s = 0; memcpy(&%s, (char*)%s->data + %s * %d, %d);";
      "uintptr_t %s = (uintptr_t)";
      "memcpy((char*)%s->data + %s * %d, &%s, %d); })";
      "let emit_boxed_struct_temp";
      "blorp_list_set_raw_copy(%s, %s, &%s);";
      "let emit_pointer_swap_slots";
      "void* %s = blorp_list_get(%s, %s); blorp_list_set_raw(%s, %s,";
      "unsigned char %s[%s];";
      "char* %s = (char*)%s->data; uintptr_t %s = 0; memcpy(&%s, %s + %s";
      "char*)((blorp_List*)%s)->data +";
      "if (%s->storage_mode == BLORP_LIST_STORAGE_INLINE && %s->elem_size ==";
      "void* %s = blorp_list_get(%s, %s); if (!%s)";
      "emit ctx \"blorp_list_handoff_set_source_slot((blorp_List*)\"";
      "emit ctx \"blorp_list_copy_span_uninit((blorp_List*)\"";
      "let list_tmp = Printf.sprintf \"__list_unique_%d\"";
      "let list_tmp = Printf.sprintf \"__list_cap_%d\"";
      "emit ctx \"blorp_list_new(\"";
      "emit ctx \"blorp_list_new_inline(\"";
      "emit ctx \"blorp_list_retain_for((blorp_List*)\"";
      "tuple_field_needs_retain ctx el";
      "boxed_expr_transfers_ownership ctx el";
      "let append_fn";
      "__lst_elem_%d";
    ]

let test_core_emit_delegates_prepared_tensor_slice_to_blorp_manifest () =
  let core_emit_path = find_project_file core_emit_rel in
  let core_emit_intrinsic_path = find_project_file core_emit_intrinsic_rel in
  let source = read_file core_emit_path in
  let intrinsic_source = read_file core_emit_intrinsic_path in
  assert_source_contains source
    "production emitter calls Blorp prepared tensor bridge"
    "Core_emit_blorp_prepared_tensor.emit_raw_view_decl";
  assert_source_contains source "production emitter delegates tensor raw read"
    "Core_emit_blorp_prepared_tensor.emit_raw_read";
  assert_source_contains source "production emitter delegates tensor raw write"
    "Core_emit_blorp_prepared_tensor.emit_raw_write_stmt";
  assert_source_contains intrinsic_source
    "production emitter delegates tensor word storage checks"
    "Core_emit_blorp_prepared_tensor.emit_word_storage_check";
  assert_source_contains intrinsic_source
    "production emitter delegates tensor f64 storage checks"
    "Core_emit_blorp_prepared_tensor.emit_f64_storage_check";
  assert_source_contains intrinsic_source
    "production emitter delegates tensor inline struct unchecked gets"
    "Core_emit_blorp_prepared_tensor.emit_inline_struct_get_unchecked";
  assert_source_contains intrinsic_source
    "production emitter delegates tensor pointer unchecked gets"
    "Core_emit_blorp_prepared_tensor.emit_data_pointer_get_unchecked";
  assert_source_contains intrinsic_source
    "production emitter delegates tensor f64 raw unchecked gets"
    "Core_emit_blorp_prepared_tensor.emit_f64_raw_get_unchecked";
  assert_source_contains intrinsic_source
    "production emitter delegates tensor f32 raw unchecked gets"
    "Core_emit_blorp_prepared_tensor.emit_f32_raw_get_unchecked";
  assert_source_contains intrinsic_source
    "production emitter delegates tensor allocation"
    "Core_emit_blorp_prepared_tensor.emit_alloc";
  assert_source_contains source
    "production emitter delegates tensor fill allocation"
    "Core_emit_blorp_prepared_tensor.emit_fill_alloc_call";
  assert_source_contains source
    "production emitter delegates tensor literal allocation"
    "Core_emit_blorp_prepared_tensor.render_literal_alloc_call";
  assert_source_contains source
    "production emitter delegates tensor literal f64 writes"
    "Core_emit_blorp_prepared_tensor.emit_literal_f64_write";
  assert_source_contains source
    "production emitter delegates tensor literal inline struct writes"
    "Core_emit_blorp_prepared_tensor.emit_literal_inline_struct_write";
  assert_source_contains source
    "production emitter delegates tensor literal boxed writes"
    "Core_emit_blorp_prepared_tensor.emit_literal_boxed_write";
  assert_source_contains source
    "production emitter rejects unprepared vector literals"
    "unprepared CVector reached emission";
  List.iter
    (fun fragment ->
      assert_source_not_contains source
        ("production emitter removed old prepared tensor body: " ^ fragment)
        fragment)
    [
      "Core_layout_type.tensor_raw_scalar_abi b.trv_kind).tras_pointer_c_type";
      "emit ctx (escape_c_ident (Var.to_c_name r.trr_view));";
      "emit ctx (escape_c_ident (Var.to_c_name w.trw_view));";
      "and emit_tensor_fill_alloc_call";
      "emit ctx \"blorp_tensor_new_i64(\"";
      "emit ctx \"blorp_tensor_new_f64(\"";
      "emit ctx \"blorp_tensor_new_f32(\"";
      "emit ctx \"blorp_tensor_new_packed(\"";
      "let vector_ctor, tensor_ctor";
      "let packed_width_arg";
      "TensorStaticShape (_ :: _) -> (";
      "blorp_vector_write_f64(%s, %d";
      "%s->data[%d] = (void*)(intptr_t)(";
      "blorp_packed_set(%s, %d, (long)(";
      "__ten_elem_%d";
      "let is_float32_literal";
      "let tensor_dims";
      "collect_leaves";
    ];
  List.iter
    (fun fragment ->
      assert_source_not_contains intrinsic_source
        ("production intrinsic emitter removed old tensor body: " ^ fragment)
        fragment)
    [
      "let vec_tmp = Printf.sprintf \"__tensor_layout_%d\"";
      "let vec_tmp = Printf.sprintf \"__tgu_vec_%d\"";
      "emit ctx \"((blorp_Vector*)\"";
      "; double %s; memcpy(&%s, (char*)%s->data + %s * sizeof(double)";
      "; float %s; memcpy(&%s, (char*)%s->data + %s * sizeof(float)";
      "let emit_tensor_alloc_ctor";
      "let emit_tensor_alloc";
      "emit ctx \"blorp_vector_new_i64(\"";
      "blorp_vector_init_elem_release(%s";
    ]

let emit_bridge render =
  let ctx = Blorp.Core_emit_context.create () in
  render ctx;
  Buffer.contents ctx.output

let test_prepared_string_bridge_emits_expected_c () =
  let read =
    {
      Core.sbr_source = cvar "s" ty_string;
      sbr_index = cint 2;
      sbr_proof = Core.StringReadBoundsProven;
    }
  in
  let copy =
    {
      Core.sbc_dst = cvar "dst" ty_string;
      sbc_dst_pos = cint 0;
      sbc_src = cvar "src" ty_string;
      sbc_src_pos = cint 1;
      sbc_len = cint 3;
      sbc_proof = Core.StringCopyBoundsProven;
    }
  in
  let read_c =
    emit_bridge (fun ctx ->
        Blorp.Core_emit_blorp_prepared_string.emit_byte_read
          ~emit_expr:Blorp.Core_emit.emit_expr ctx read)
  in
  let copy_c =
    emit_bridge (fun ctx ->
        Blorp.Core_emit_blorp_prepared_string.emit_byte_copy
          ~emit_expr:Blorp.Core_emit.emit_expr ctx copy)
  in
  Alcotest.(check string)
    "string byte read bridge output"
    "(long)(unsigned char)((blorp_String*)s)->data[2L]" read_c;
  Alcotest.(check string)
    "string byte copy bridge output"
    "({ blorp_String* __string_copy_dst_0 = (blorp_String*)dst; long \
     __string_copy_dst_pos_0 = 0L; blorp_String* __string_copy_src_0 = \
     (blorp_String*)src; long __string_copy_src_pos_0 = 1L; long \
     __string_copy_len_0 = 3L; if (__string_copy_len_0 > 0) { \
     memcpy(__string_copy_dst_0->data + __string_copy_dst_pos_0, \
     __string_copy_src_0->data + __string_copy_src_pos_0, \
     (size_t)__string_copy_len_0); } (void)0; })"
    copy_c

let test_prepared_list_bridge_emits_expected_c () =
  let small_ty = Ast.TyNamed ("Small", []) in
  let ty_list_small = Ast.TyNamed ("List", [ small_ty ]) in
  let get =
    {
      Core.lg_list = cvar "xs" ty_list_int;
      lg_index = cint 1;
      lg_layout = Core.list_inline_storage Core.InlineBytes8;
      lg_bounds = Core.ListBoundsChecked;
    }
  in
  let rendered =
    emit_bridge (fun ctx ->
        Blorp.Core_emit_blorp_prepared_list.emit_get
          ~emit_expr:Blorp.Core_emit.emit_expr ctx get)
  in
  let inline_struct_load =
    emit_bridge (fun ctx ->
        Blorp.Core_emit_blorp_prepared_list.emit_inline_struct_dynamic_load ctx
          ~list_tmp:"__list" ~idx_tmp:"__idx" ~out_tmp:"__out"
          ~struct_ty:"Small" ~bounds:Core.ListBoundsChecked)
  in
  let inline_bits_load =
    emit_bridge (fun ctx ->
        Blorp.Core_emit_blorp_prepared_list.emit_inline_bits_load ctx
          ~list_tmp:"__list" ~idx_tmp:"__idx" ~bits_tmp:"__bits"
          ~width:Core.InlineBytes8)
  in
  let inline_bits_store =
    emit_bridge (fun ctx ->
        Blorp.Core_emit_blorp_prepared_list.emit_inline_bits_store
          ~emit_expr:Blorp.Core_emit.emit_expr
          ~emit_boxed:Blorp.Core_emit.emit_boxed ctx (cvar "xs" ty_list_int)
          (cint 1) (cint 42) Core.InlineBytes8)
  in
  let inline_struct_store =
    emit_bridge (fun ctx ->
        Blorp.Core_emit_blorp_prepared_list.emit_inline_struct_set_raw_store
          ~emit_expr:Blorp.Core_emit.emit_expr ctx (cvar "xs" ty_list_small)
          (cint 1) (cvar "next" small_ty) ~struct_ty:"Small")
  in
  let pointer_swap =
    emit_bridge (fun ctx ->
        Blorp.Core_emit_blorp_prepared_list.emit_pointer_swap
          ~emit_expr:Blorp.Core_emit.emit_expr ctx (cvar "xs" ty_list_int)
          (cint 1) (cint 2))
  in
  let inline_bits_swap =
    emit_bridge (fun ctx ->
        Blorp.Core_emit_blorp_prepared_list.emit_inline_bits_swap
          ~emit_expr:Blorp.Core_emit.emit_expr ctx (cvar "xs" ty_list_int)
          (cint 1) (cint 2) Core.InlineBytes8)
  in
  let inline_struct_swap =
    emit_bridge (fun ctx ->
        Blorp.Core_emit_blorp_prepared_list.emit_inline_struct_swap
          ~emit_expr:Blorp.Core_emit.emit_expr ctx (cvar "xs" ty_list_small)
          (cint 1) (cint 2))
  in
  let pointer_alloc =
    Blorp.Core_emit_blorp_prepared_list.render_alloc_call
      (Core.list_pointer_storage ())
      "4L"
  in
  let inline_alloc =
    Blorp.Core_emit_blorp_prepared_list.render_alloc_call
      (Core.list_inline_storage Core.InlineBytes8)
      "4L"
  in
  let inline_struct_alloc =
    Blorp.Core_emit_blorp_prepared_list.render_alloc_call
      (Core.list_inline_struct_storage "Small")
      "4L"
  in
  let release_alloc =
    Blorp.Core_emit_blorp_prepared_list.render_alloc_with_release
      ~alloc_expr:"blorp_list_new(4L)" ~result_tmp:"__lst"
  in
  let construct_release =
    emit_bridge (fun ctx ->
        Blorp.Core_emit_blorp_prepared_list.emit_construct_init_elem_release ctx
          ~list_tmp:"__lst")
  in
  let construct_inline_struct =
    emit_bridge (fun ctx ->
        Blorp.Core_emit_blorp_prepared_list.emit_construct_inline_struct_set
          ~emit_expr:Blorp.Core_emit.emit_expr ctx ~list_tmp:"__lst" ~index:2
          ~struct_ty:"Small" (cvar "next" small_ty))
  in
  let construct_set_len =
    emit_bridge (fun ctx ->
        Blorp.Core_emit_blorp_prepared_list.emit_construct_set_len ctx
          ~list_tmp:"__lst" ~len:3)
  in
  let boxed_int =
    Blorp.Core_codegen_prepare.boxed_storage_value
      ~reg:(Blorp.Codegen_types.create_registry ())
      (cint 7)
  in
  let construct_append =
    emit_bridge (fun ctx ->
        Blorp.Core_emit_blorp_prepared_list.emit_construct_append
          ~emit_boxed:Blorp.Core_emit.emit_boxed_storage ctx ~list_tmp:"__lst"
          ~owned:false boxed_int)
  in
  let construct_append_owned =
    emit_bridge (fun ctx ->
        Blorp.Core_emit_blorp_prepared_list.emit_construct_append
          ~emit_boxed:Blorp.Core_emit.emit_boxed_storage ctx ~list_tmp:"__lst"
          ~owned:true boxed_int)
  in
  Alcotest.(check string)
    "inline list get bridge output"
    "({ blorp_List* __lg_list_0 = (blorp_List*)xs; long __lg_idx_0 = 1L; \
     (__builtin_expect(!__lg_list_0 || __lg_idx_0 < 0 || __lg_idx_0 >= \
     __lg_list_0->len, 0) ? NULL : ({ uintptr_t __lg_bits_0 = 0; \
     memcpy(&__lg_bits_0, (char*)__lg_list_0->data + __lg_idx_0 * 8, 8); \
     (void*)__lg_bits_0; })); })"
    rendered;
  Alcotest.(check string)
    "inline bits load bridge output"
    "uintptr_t __bits = 0; memcpy(&__bits, (char*)__list->data + __idx * 8, 8);"
    inline_bits_load;
  Alcotest.(check string)
    "inline bits store bridge output"
    "({ blorp_List* __list_store_0 = (blorp_List*)xs; long __list_store_idx_0 \
     = 1L; uintptr_t __list_store_bits_0 = (uintptr_t)(void*)(long)(42L); \
     memcpy((char*)__list_store_0->data + __list_store_idx_0 * 8, \
     &__list_store_bits_0, 8); })"
    inline_bits_store;
  Alcotest.(check string)
    "inline struct store bridge output"
    "({ blorp_List* __list_store_0 = (blorp_List*)xs; long __list_store_idx_1 \
     = 1L; Small __list_elem_2 = next; if (__list_store_0 && \
     __list_store_0->storage_mode == BLORP_LIST_STORAGE_INLINE && \
     __list_store_0->elem_size == (int16_t)sizeof(Small)) { \
     blorp_list_set_raw_copy(__list_store_0, __list_store_idx_1, \
     &__list_elem_2); } else { blorp_list_set_raw((blorp_List*)__list_store_0, \
     __list_store_idx_1, (void*)blorp_box_struct(&__list_elem_2, \
     sizeof(Small))); } })"
    inline_struct_store;
  Alcotest.(check string)
    "pointer swap bridge output"
    "({ blorp_List* __list_swap_0 = (blorp_List*)xs; long __list_swap_i_1 = \
     1L; long __list_swap_j_2 = 2L; if (__builtin_expect(__list_swap_0 && \
     __list_swap_i_1 != __list_swap_j_2, 1)) { void* __list_swap_tmp_3 = \
     blorp_list_get(__list_swap_0, __list_swap_i_1); \
     blorp_list_set_raw(__list_swap_0, __list_swap_i_1, \
     blorp_list_get(__list_swap_0, __list_swap_j_2)); \
     blorp_list_set_raw(__list_swap_0, __list_swap_j_2, __list_swap_tmp_3); } \
     })"
    pointer_swap;
  Alcotest.(check string)
    "inline bits swap bridge output"
    "({ blorp_List* __list_swap_0 = (blorp_List*)xs; long __list_swap_i_1 = \
     1L; long __list_swap_j_2 = 2L; if (__builtin_expect(__list_swap_0 && \
     __list_swap_i_1 != __list_swap_j_2, 1)) { char* __list_swap_base_3 = \
     (char*)__list_swap_0->data; uintptr_t __list_swap_bits_4 = 0; \
     memcpy(&__list_swap_bits_4, __list_swap_base_3 + __list_swap_i_1 * 8, 8); \
     memcpy(__list_swap_base_3 + __list_swap_i_1 * 8, __list_swap_base_3 + \
     __list_swap_j_2 * 8, 8); memcpy(__list_swap_base_3 + __list_swap_j_2 * 8, \
     &__list_swap_bits_4, 8); } })"
    inline_bits_swap;
  Alcotest.(check string)
    "inline struct swap bridge output"
    "({ blorp_List* __list_swap_0 = (blorp_List*)xs; long __list_swap_i_1 = \
     1L; long __list_swap_j_2 = 2L; if (__builtin_expect(__list_swap_0 && \
     __list_swap_i_1 != __list_swap_j_2, 1)) { if (__list_swap_0->storage_mode \
     == BLORP_LIST_STORAGE_INLINE) { char* __list_swap_base_3 = \
     (char*)__list_swap_0->data; size_t __list_swap_size_4 = \
     (size_t)__list_swap_0->elem_size; void* __list_swap_a_5 = \
     __list_swap_base_3 + __list_swap_i_1 * __list_swap_size_4; void* \
     __list_swap_b_6 = __list_swap_base_3 + __list_swap_j_2 * \
     __list_swap_size_4; unsigned char \
     __list_swap_bytes_7[__list_swap_size_4]; memcpy(__list_swap_bytes_7, \
     __list_swap_a_5, __list_swap_size_4); memcpy(__list_swap_a_5, \
     __list_swap_b_6, __list_swap_size_4); memcpy(__list_swap_b_6, \
     __list_swap_bytes_7, __list_swap_size_4); } else { void* \
     __list_swap_tmp_8 = blorp_list_get(__list_swap_0, __list_swap_i_1); \
     blorp_list_set_raw(__list_swap_0, __list_swap_i_1, \
     blorp_list_get(__list_swap_0, __list_swap_j_2)); \
     blorp_list_set_raw(__list_swap_0, __list_swap_j_2, __list_swap_tmp_8); } \
     } })"
    inline_struct_swap;
  Alcotest.(check string)
    "inline struct load bridge output"
    "if (__builtin_expect(!__list || __idx < 0 || __idx >= __list->len, 0)) { \
     memset(&__out, 0, sizeof(Small)); } else if (__list->storage_mode == \
     BLORP_LIST_STORAGE_INLINE && __list->elem_size == (int16_t)sizeof(Small)) \
     { memcpy(&__out, (char*)__list->data + __idx * sizeof(Small), \
     sizeof(Small)); } else { void* __lg_raw_0 = blorp_list_get(__list, \
     __idx); if (!__lg_raw_0) { memset(&__out, 0, sizeof(Small)); } else { \
     __out = blorp_unbox_struct(__lg_raw_0, Small); } }"
    inline_struct_load;
  Alcotest.(check string)
    "list pointer alloc bridge output" "blorp_list_new(4L)" pointer_alloc;
  Alcotest.(check string)
    "list inline alloc bridge output" "blorp_list_new_inline(4L, 8)"
    inline_alloc;
  Alcotest.(check string)
    "list inline struct alloc bridge output"
    "blorp_list_new_inline(4L, sizeof(Small))" inline_struct_alloc;
  Alcotest.(check string)
    "list release alloc bridge output"
    "({ blorp_List* __lst = blorp_list_new(4L); \
     blorp_list_init_elem_release(__lst, blorp_elem_release_fn); __lst; })"
    release_alloc;
  Alcotest.(check string)
    "list construct release bridge output"
    "blorp_list_init_elem_release(__lst, blorp_elem_release_fn);"
    construct_release;
  Alcotest.(check string)
    "list construct inline struct bridge output"
    "{ Small __lst_elem_0 = next; blorp_list_set_raw_copy(__lst, 2, \
     &__lst_elem_0); }"
    construct_inline_struct;
  Alcotest.(check string)
    "list construct set len bridge output" "__lst->len = 3;" construct_set_len;
  Alcotest.(check string)
    "list construct append bridge output"
    "__lst = blorp_list_append(__lst, ({ long __box_0 = 7L; \
     (void*)(long)(__box_0); }));"
    construct_append;
  Alcotest.(check string)
    "list construct append owned bridge output"
    "__lst = blorp_list_append_owned(__lst, ({ long __box_0 = 7L; \
     (void*)(long)(__box_0); }));"
    construct_append_owned

let test_prepared_tensor_bridge_emits_expected_c () =
  let ty_small = Ast.TyNamed ("Small", []) in
  let raw_view =
    {
      Core.trv_var = Core.Var.named "__raw";
      trv_kind = Core.TensorFloat64Elements;
      trv_source = cvar "values" ty_tensor_float;
    }
  in
  let raw_write =
    {
      Core.trw_view = Core.Var.named "__raw";
      trw_kind = Core.TensorFloat64Elements;
      trw_index = cint 1;
      trw_value = core (Core.CLit (Ast.LitFloat 2.5)) ty_float;
    }
  in
  let view_c =
    emit_bridge (fun ctx ->
        Blorp.Core_emit_blorp_prepared_tensor.emit_raw_view_decl
          ~emit_expr:Blorp.Core_emit.emit_expr ctx raw_view)
  in
  let write_c =
    emit_bridge (fun ctx ->
        Blorp.Core_emit_blorp_prepared_tensor.emit_raw_write_stmt
          ~emit_expr:Blorp.Core_emit.emit_expr ctx raw_write)
  in
  let storage_c =
    emit_bridge (fun ctx ->
        Blorp.Core_emit_blorp_prepared_tensor.emit_word_storage_check
          ~emit_expr:Blorp.Core_emit.emit_expr ctx
          (cvar "values" ty_tensor_float))
  in
  let f64_storage_c =
    emit_bridge (fun ctx ->
        Blorp.Core_emit_blorp_prepared_tensor.emit_f64_storage_check
          ~emit_expr:Blorp.Core_emit.emit_expr ctx
          (cvar "values" ty_tensor_float))
  in
  let f32_storage_c =
    emit_bridge (fun ctx ->
        Blorp.Core_emit_blorp_prepared_tensor.emit_f32_storage_check
          ~emit_expr:Blorp.Core_emit.emit_expr ctx
          (cvar "values" ty_tensor_float))
  in
  let i64_storage_c =
    emit_bridge (fun ctx ->
        Blorp.Core_emit_blorp_prepared_tensor.emit_i64_storage_check
          ~emit_expr:Blorp.Core_emit.emit_expr ctx
          (cvar "values" ty_tensor_float))
  in
  let pointer_get_c =
    emit_bridge (fun ctx ->
        Blorp.Core_emit_blorp_prepared_tensor.emit_data_pointer_get_unchecked
          ~emit_expr:Blorp.Core_emit.emit_expr ctx
          (cvar "values" ty_tensor_float)
          (cint 1))
  in
  let inline_struct_get_c =
    emit_bridge (fun ctx ->
        Blorp.Core_emit_blorp_prepared_tensor.emit_inline_struct_get_unchecked
          ~emit_expr:Blorp.Core_emit.emit_expr ctx
          (cvar "values" ty_tensor_float)
          (cint 1) ~struct_ty:"Small")
  in
  let f64_raw_get_c =
    emit_bridge (fun ctx ->
        Blorp.Core_emit_blorp_prepared_tensor.emit_f64_raw_get_unchecked
          ~emit_expr:Blorp.Core_emit.emit_expr ctx
          (cvar "values" ty_tensor_float)
          (cint 1))
  in
  let f32_raw_get_c =
    emit_bridge (fun ctx ->
        Blorp.Core_emit_blorp_prepared_tensor.emit_f32_raw_get_unchecked
          ~emit_expr:Blorp.Core_emit.emit_expr ctx
          (cvar "values" ty_tensor_float)
          (cint 1))
  in
  let f64_alloc_c =
    emit_bridge (fun ctx ->
        Blorp.Core_emit_blorp_prepared_tensor.emit_alloc
          ~emit_expr:Blorp.Core_emit.emit_expr ctx
          (cvar "result" ty_float_vector)
          (cint 3))
  in
  let string_alloc_c =
    emit_bridge (fun ctx ->
        Blorp.Core_emit_blorp_prepared_tensor.emit_alloc
          ~emit_expr:Blorp.Core_emit.emit_expr ctx
          (cvar "result" ty_string_vector)
          (cint 3))
  in
  let fill_f64_alloc_c =
    Blorp.Core_emit_blorp_prepared_tensor.render_fill_alloc_call
      (Core.tensor_raw_scalar_storage ~elem_ty:ty_float
         Core.TensorFloat64Elements)
      ~first_dim:"rows" ~total_dim:"total" test_loc
  in
  let fill_packed_alloc_c =
    Blorp.Core_emit_blorp_prepared_tensor.render_fill_alloc_call
      (Core.tensor_packed_storage ~elem_ty:ty_bool Core.InlineBytes1)
      ~first_dim:"rows" ~total_dim:"total" test_loc
  in
  let literal_f64_alloc_c =
    Blorp.Core_emit_blorp_prepared_tensor.render_literal_alloc_call
      (Core.tensor_raw_scalar_storage ~elem_ty:ty_float
         Core.TensorFloat64Elements)
      (Core.TensorStaticShape [ 2; 3 ])
  in
  let literal_packed_vector_alloc_c =
    Blorp.Core_emit_blorp_prepared_tensor.render_literal_alloc_call
      (Core.tensor_packed_storage ~elem_ty:ty_bool Core.InlineBytes1)
      (Core.TensorVectorLength 5)
  in
  let literal_inline_struct_alloc_c =
    Blorp.Core_emit_blorp_prepared_tensor.render_literal_alloc_call
      (Core.tensor_inline_struct_storage ~elem_ty:ty_small "Small")
      (Core.TensorStaticShape [ 2; 4 ])
  in
  let literal_init_release_c =
    emit_bridge (fun ctx ->
        Blorp.Core_emit_blorp_prepared_tensor.emit_literal_init_elem_release ctx
          ~tensor_tmp:"vec")
  in
  let literal_f64_write_c =
    emit_bridge (fun ctx ->
        Blorp.Core_emit_blorp_prepared_tensor.emit_literal_f64_write
          ~emit_expr:Blorp.Core_emit.emit_expr ctx ~tensor_tmp:"vec" ~index:2
          (core (Core.CLit (Ast.LitFloat 2.5)) ty_float))
  in
  let literal_i64_write_c =
    emit_bridge (fun ctx ->
        Blorp.Core_emit_blorp_prepared_tensor.emit_literal_i64_write
          ~emit_expr:Blorp.Core_emit.emit_expr ctx ~tensor_tmp:"vec" ~index:1
          (cint 42))
  in
  let literal_word_write_c =
    emit_bridge (fun ctx ->
        Blorp.Core_emit_blorp_prepared_tensor.emit_literal_word_write
          ~emit_expr:Blorp.Core_emit.emit_expr ctx ~tensor_tmp:"vec" ~index:0
          (cint 7))
  in
  let literal_packed_write_c =
    emit_bridge (fun ctx ->
        Blorp.Core_emit_blorp_prepared_tensor.emit_literal_packed_write
          ~emit_expr:Blorp.Core_emit.emit_expr ctx ~tensor_tmp:"vec" ~index:3
          (cint 1))
  in
  let literal_inline_struct_write_c =
    emit_bridge (fun ctx ->
        Blorp.Core_emit_blorp_prepared_tensor.emit_literal_inline_struct_write
          ~emit_expr:Blorp.Core_emit.emit_expr ctx ~tensor_tmp:"vec" ~index:4
          ~struct_ty:"Small" (cvar "point" ty_small))
  in
  let literal_boxed_write_c =
    emit_bridge (fun ctx ->
        Blorp.Core_emit_blorp_prepared_tensor.emit_literal_boxed_write_rendered
          ctx ~tensor_tmp:"vec" ~index:5 ~value_arg:"boxed")
  in
  let literal_boxed_retain_c =
    emit_bridge (fun ctx ->
        Blorp.Core_emit_blorp_prepared_tensor.emit_literal_boxed_retain ctx
          "boxed")
  in
  Alcotest.(check string)
    "tensor raw view bridge output"
    "double* __raw = (double*)((blorp_Vector*)values)->data" view_c;
  Alcotest.(check string)
    "tensor raw write bridge output" "__raw[1L] = 2.5;" write_c;
  Alcotest.(check string)
    "tensor word storage bridge output"
    "({ blorp_Vector* __tensor_layout_0 = (blorp_Vector*)values; \
     __tensor_layout_0 && __tensor_layout_0->storage_mode == \
     BLORP_VECTOR_STORAGE_POINTER && __tensor_layout_0->elem_size == \
     (int16_t)sizeof(void*) && __tensor_layout_0->elem_release == NULL; })"
    storage_c;
  Alcotest.(check string)
    "tensor f64 storage bridge output"
    "({ blorp_Vector* __tensor_layout_0 = (blorp_Vector*)values; \
     __tensor_layout_0 && __tensor_layout_0->storage_mode == \
     BLORP_VECTOR_STORAGE_F64 && __tensor_layout_0->elem_size == \
     (int16_t)sizeof(double); })"
    f64_storage_c;
  Alcotest.(check string)
    "tensor f32 storage bridge output"
    "({ blorp_Vector* __tensor_layout_0 = (blorp_Vector*)values; \
     __tensor_layout_0 && __tensor_layout_0->storage_mode == \
     BLORP_VECTOR_STORAGE_F32 && __tensor_layout_0->elem_size == \
     (int16_t)sizeof(float); })"
    f32_storage_c;
  Alcotest.(check string)
    "tensor i64 storage bridge output"
    "({ blorp_Vector* __tensor_layout_0 = (blorp_Vector*)values; \
     __tensor_layout_0 && __tensor_layout_0->storage_mode == \
     BLORP_VECTOR_STORAGE_I64 && __tensor_layout_0->elem_size == \
     (int16_t)sizeof(long); })"
    i64_storage_c;
  Alcotest.(check string)
    "tensor pointer get bridge output" "((blorp_Vector*)values)->data[1L]"
    pointer_get_c;
  Alcotest.(check string)
    "tensor inline struct get bridge output"
    "({ blorp_Vector* __tgu_vec_0 = (blorp_Vector*)values; long __tgu_idx_1 = \
     1L; Small __tgu_out_2; if (__builtin_expect(__tgu_vec_0->storage_mode == \
     BLORP_VECTOR_STORAGE_INLINE && __tgu_vec_0->elem_size == sizeof(Small), \
     1)) { memcpy(&__tgu_out_2, (char*)__tgu_vec_0->data + __tgu_idx_1 * \
     sizeof(Small), sizeof(Small)); } else { void* __tgu_raw_3 = \
     __tgu_vec_0->data[__tgu_idx_1]; __tgu_out_2 = \
     blorp_unbox_struct(__tgu_raw_3, Small); } __tgu_out_2; })"
    inline_struct_get_c;
  Alcotest.(check string)
    "tensor f64 raw get bridge output"
    "({ blorp_Vector* __tensor_raw_vec_0 = (blorp_Vector*)values; long \
     __tensor_raw_idx_1 = 1L; double __tensor_raw_2; memcpy(&__tensor_raw_2, \
     (char*)__tensor_raw_vec_0->data + __tensor_raw_idx_1 * sizeof(double), \
     sizeof(double)); __tensor_raw_2; })"
    f64_raw_get_c;
  Alcotest.(check string)
    "tensor f32 raw get bridge output"
    "({ blorp_Vector* __tensor_raw_vec_0 = (blorp_Vector*)values; long \
     __tensor_raw_idx_1 = 1L; float __tensor_raw_2; memcpy(&__tensor_raw_2, \
     (char*)__tensor_raw_vec_0->data + __tensor_raw_idx_1 * sizeof(float), \
     sizeof(float)); __tensor_raw_2; })"
    f32_raw_get_c;
  Alcotest.(check string)
    "tensor f64 alloc bridge output" "blorp_vector_new_f64(3L)" f64_alloc_c;
  Alcotest.(check string)
    "tensor string alloc bridge output"
    "({ blorp_Vector* __tensor_alloc_0 = blorp_vector_new(3L); \
     blorp_vector_init_elem_release(__tensor_alloc_0, blorp_elem_release_fn); \
     __tensor_alloc_0; })"
    string_alloc_c;
  Alcotest.(check string)
    "tensor fill f64 alloc bridge output" "blorp_tensor_new_f64(rows, total)"
    fill_f64_alloc_c;
  Alcotest.(check string)
    "tensor fill packed alloc bridge output"
    "blorp_tensor_new_packed(rows, total, 1)" fill_packed_alloc_c;
  Alcotest.(check string)
    "tensor literal f64 alloc bridge output" "blorp_tensor_new_f64(2, 6)"
    literal_f64_alloc_c;
  Alcotest.(check string)
    "tensor literal packed vector alloc bridge output"
    "blorp_vector_new_packed(5, 1)" literal_packed_vector_alloc_c;
  Alcotest.(check string)
    "tensor literal inline struct alloc bridge output"
    "blorp_tensor_new_sized(2, 8, sizeof(Small))" literal_inline_struct_alloc_c;
  Alcotest.(check string)
    "tensor literal init release bridge output"
    "blorp_vector_init_elem_release(vec, blorp_elem_release_fn);"
    literal_init_release_c;
  Alcotest.(check string)
    "tensor literal f64 write bridge output"
    "blorp_vector_write_f64(vec, 2, 2.5);" literal_f64_write_c;
  Alcotest.(check string)
    "tensor literal i64 write bridge output" "((long*)vec->data)[1] = 42L;"
    literal_i64_write_c;
  Alcotest.(check string)
    "tensor literal word write bridge output"
    "vec->data[0] = (void*)(intptr_t)(7L);" literal_word_write_c;
  Alcotest.(check string)
    "tensor literal packed write bridge output"
    "blorp_packed_set(vec, 3, (long)(1L));" literal_packed_write_c;
  Alcotest.(check string)
    "tensor literal inline struct write bridge output"
    "{ Small __ten_elem_0 = point; memcpy((char*)vec->data + 4 * \
     sizeof(Small), &__ten_elem_0, sizeof(Small)); }"
    literal_inline_struct_write_c;
  Alcotest.(check string)
    "tensor literal boxed write bridge output" "vec->data[5] = boxed;"
    literal_boxed_write_c;
  Alcotest.(check string)
    "tensor literal boxed retain bridge output"
    "if (boxed) blorp_retain(boxed);" literal_boxed_retain_c

let test_compiler_blorp_test_suites () =
  let suite_path = find_project_file compiler_tool_tests_dir_rel in
  let test_files = Blorp.Test_runner.collect_test_files [ suite_path ] in
  Alcotest.(check bool)
    "discovers compiler/blorp TestSuite files" true (test_files <> []);
  let exit_code =
    Blorp.Test_runner.run_tests ~mode:Blorp.Test_runner.SuiteOnly
      ~timeout:(Some 30) ~jobs:1 ~cache:false suite_path
  in
  Alcotest.(check int) "compiler/blorp TestSuite exit code" 0 exit_code

let suite =
  [
    ( "core_emit_blorp_template",
      [
        Alcotest.test_case "substitutes multi-digit placeholders" `Quick
          test_template_substitution_supports_multi_digit_placeholders;
      ] );
    ( "codegen_intrinsic_renderer",
      [
        Alcotest.test_case "compiles and runs smoke" `Slow
          test_codegen_intrinsic_renderer_compiles_and_runs_smoke;
        Alcotest.test_case "manifest matches checked-in templates" `Slow
          (fun () ->
            test_renderer_manifest_matches_checked_in_templates
              intrinsic_renderer);
        Alcotest.test_case "production emitter delegates initial slice" `Quick
          test_core_emit_delegates_initial_slice_to_blorp_manifest;
        Alcotest.test_case "compiler/blorp TestSuites pass" `Slow
          test_compiler_blorp_test_suites;
      ] );
    ( "codegen_prepared_string_renderer",
      [
        Alcotest.test_case "manifest matches checked-in templates" `Slow
          (fun () ->
            test_renderer_manifest_matches_checked_in_templates
              prepared_string_renderer);
        Alcotest.test_case "production emitter delegates prepared string slice"
          `Quick
          test_core_emit_delegates_prepared_string_slice_to_blorp_manifest;
        Alcotest.test_case "prepared string bridge emits expected C" `Quick
          test_prepared_string_bridge_emits_expected_c;
      ] );
    ( "codegen_prepared_list_renderer",
      [
        Alcotest.test_case "manifest matches checked-in templates" `Slow
          (fun () ->
            test_renderer_manifest_matches_checked_in_templates
              prepared_list_renderer);
        Alcotest.test_case "production emitter delegates prepared list slice"
          `Quick test_core_emit_delegates_prepared_list_slice_to_blorp_manifest;
        Alcotest.test_case "prepared list bridge emits expected C" `Quick
          test_prepared_list_bridge_emits_expected_c;
      ] );
    ( "codegen_prepared_tensor_renderer",
      [
        Alcotest.test_case "manifest matches checked-in templates" `Slow
          (fun () ->
            test_renderer_manifest_matches_checked_in_templates
              prepared_tensor_renderer);
        Alcotest.test_case "production emitter delegates prepared tensor slice"
          `Quick
          test_core_emit_delegates_prepared_tensor_slice_to_blorp_manifest;
        Alcotest.test_case "prepared tensor bridge emits expected C" `Quick
          test_prepared_tensor_bridge_emits_expected_c;
      ] );
  ]
