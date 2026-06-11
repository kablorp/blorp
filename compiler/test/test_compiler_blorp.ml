module Ast = Blorp.Ast
module Core = Blorp.Core

let test_loc =
  { Ast.line = 1; column = 1; end_line = 1; end_column = 1; loc_file = None }

let ty_int = Ast.TyNamed ("Int", [])
let ty_float = Ast.TyNamed ("Float", [])
let ty_string = Ast.TyNamed ("String", [])
let ty_list_int = Ast.TyNamed ("List", [ ty_int ])
let ty_tensor_float = Ast.TyNamed ("Tensor", [ ty_float ])
let core desc ty : Core.core = { desc; ty; loc = test_loc }
let cvar name ty = core (Core.CVar (Core.Var.named name)) ty
let cint value = core (Core.CLit (Ast.LitInt (Int64.of_int value))) ty_int

let compiler_blorp_rel file =
  Filename.concat (Filename.concat "compiler" "blorp") file

let compiler_lib_rel file =
  Filename.concat (Filename.concat "compiler" "lib") file

let compiler_tool_tests_dir_rel = compiler_blorp_rel "tests"
let core_emit_intrinsic_rel = compiler_lib_rel "core_emit_intrinsic.ml"
let core_emit_rel = compiler_lib_rel "core_emit.ml"

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
  let source = read_file core_emit_path in
  assert_source_contains source
    "production emitter calls Blorp prepared string bridge"
    "Core_emit_blorp_prepared_string.emit_byte_read";
  assert_source_contains source "production emitter delegates string byte copy"
    "Core_emit_blorp_prepared_string.emit_byte_copy";
  List.iter
    (fun fragment ->
      assert_source_not_contains source
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
  let source = read_file core_emit_path in
  assert_source_contains source
    "production emitter calls Blorp prepared list bridge"
    "Core_emit_blorp_prepared_list.emit_get";
  assert_source_contains source
    "production emitter delegates inline struct list loads"
    "Core_emit_blorp_prepared_list.emit_inline_struct_dynamic_load";
  assert_source_contains source "production emitter delegates inline bit loads"
    "Core_emit_blorp_prepared_list.emit_inline_bits_load";
  List.iter
    (fun fragment ->
      assert_source_not_contains source
        ("production emitter removed old prepared list body: " ^ fragment)
        fragment)
    [
      "emit ctx \"blorp_list_get((blorp_List*)\"";
      "({ uintptr_t %s = 0; memcpy(&%s, (char*)%s->data";
      "uintptr_t %s = 0; memcpy(&%s, (char*)%s->data + %s * %d, %d);";
      "char*)((blorp_List*)%s)->data +";
      "if (%s->storage_mode == BLORP_LIST_STORAGE_INLINE && %s->elem_size ==";
      "void* %s = blorp_list_get(%s, %s); if (!%s)";
    ]

let test_core_emit_delegates_prepared_tensor_slice_to_blorp_manifest () =
  let core_emit_path = find_project_file core_emit_rel in
  let source = read_file core_emit_path in
  assert_source_contains source
    "production emitter calls Blorp prepared tensor bridge"
    "Core_emit_blorp_prepared_tensor.emit_raw_view_decl";
  assert_source_contains source "production emitter delegates tensor raw read"
    "Core_emit_blorp_prepared_tensor.emit_raw_read";
  assert_source_contains source "production emitter delegates tensor raw write"
    "Core_emit_blorp_prepared_tensor.emit_raw_write_stmt";
  List.iter
    (fun fragment ->
      assert_source_not_contains source
        ("production emitter removed old prepared tensor body: " ^ fragment)
        fragment)
    [
      "Core_layout_type.tensor_raw_scalar_abi b.trv_kind).tras_pointer_c_type";
      "emit ctx (escape_c_ident (Var.to_c_name r.trr_view));";
      "emit ctx (escape_c_ident (Var.to_c_name w.trw_view));";
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
  Alcotest.(check string)
    "inline list get bridge output"
    "({ blorp_List* __lg_list_0 = (blorp_List*)xs; long __lg_idx_1 = 1L; \
     (__builtin_expect(!__lg_list_0 || __lg_idx_1 < 0 || __lg_idx_1 >= \
     __lg_list_0->len, 0) ? NULL : ({ uintptr_t __lg_bits_2 = 0; \
     memcpy(&__lg_bits_2, (char*)__lg_list_0->data + __lg_idx_1 * 8, 8); \
     (void*)__lg_bits_2; })); })"
    rendered;
  Alcotest.(check string)
    "inline bits load bridge output"
    "uintptr_t __bits = 0; memcpy(&__bits, (char*)__list->data + __idx * 8, 8);"
    inline_bits_load;
  Alcotest.(check string)
    "inline struct load bridge output"
    "if (__builtin_expect(!__list || __idx < 0 || __idx >= __list->len, 0)) { \
     memset(&__out, 0, sizeof(Small)); } else if (__list->storage_mode == \
     BLORP_LIST_STORAGE_INLINE && __list->elem_size == (int16_t)sizeof(Small)) \
     { memcpy(&__out, (char*)__list->data + __idx * sizeof(Small), \
     sizeof(Small)); } else { void* __lg_raw_0 = blorp_list_get(__list, \
     __idx); if (!__lg_raw_0) { memset(&__out, 0, sizeof(Small)); } else { \
     __out = blorp_unbox_struct(__lg_raw_0, Small); } }"
    inline_struct_load

let test_prepared_tensor_bridge_emits_expected_c () =
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
  Alcotest.(check string)
    "tensor raw view bridge output"
    "double* __raw = (double*)((blorp_Vector*)values)->data" view_c;
  Alcotest.(check string)
    "tensor raw write bridge output" "__raw[1L] = 2.5;" write_c

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
