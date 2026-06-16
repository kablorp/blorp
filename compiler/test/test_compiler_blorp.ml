module Ast = Blorp.Ast
module Core = Blorp.Core

let test_loc =
  { Ast.line = 1; column = 1; end_line = 1; end_column = 1; loc_file = None }

let ty_int = Ast.TyNamed ("Int", [])
let ty_bool = Ast.TyNamed ("Bool", [])
let ty_float = Ast.TyNamed ("Float", [])
let ty_string = Ast.TyNamed ("String", [])
let ty_void = Ast.TyNamed ("Void", [])
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
let core_emit_rel = compiler_lib_rel "core_emit.ml"
let core_emit_blorp_backend_rel = compiler_lib_rel "core_emit_blorp_backend.ml"

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

let prepared_dict_renderer =
  {
    name = "prepared dict";
    tool_rel = compiler_blorp_rel "codegen_prepared_dict_renderer.brp";
    artifact_prefix = "codegen-prepared-dict-renderer";
    manifest_rel =
      compiler_lib_rel "core_emit_blorp_prepared_dict_templates.tsv";
    embedded_tsv = Blorp.Core_emit_blorp_prepared_dict_templates.tsv;
  }

let prepared_set_renderer =
  {
    name = "prepared set";
    tool_rel = compiler_blorp_rel "codegen_prepared_set_renderer.brp";
    artifact_prefix = "codegen-prepared-set-renderer";
    manifest_rel = compiler_lib_rel "core_emit_blorp_prepared_set_templates.tsv";
    embedded_tsv = Blorp.Core_emit_blorp_prepared_set_templates.tsv;
  }

let prepared_tuple_renderer =
  {
    name = "prepared tuple";
    tool_rel = compiler_blorp_rel "codegen_prepared_tuple_renderer.brp";
    artifact_prefix = "codegen-prepared-tuple-renderer";
    manifest_rel =
      compiler_lib_rel "core_emit_blorp_prepared_tuple_templates.tsv";
    embedded_tsv = Blorp.Core_emit_blorp_prepared_tuple_templates.tsv;
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

let assert_source_not_contains source label fragment =
  Alcotest.(check bool) label false (Blorp.Modules.contains source fragment)

let assert_source_contains source label fragment =
  Alcotest.(check bool) label true (Blorp.Modules.contains source fragment)

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

let blorp_prepared_backend_modules =
  [
    "Core_emit_blorp_prepared_string.";
    "Core_emit_blorp_prepared_list.";
    "Core_emit_blorp_prepared_tensor.";
    "Core_emit_blorp_prepared_dict.";
    "Core_emit_blorp_prepared_set.";
    "Core_emit_blorp_prepared_tuple.";
  ]

let assert_source_omits_fragments source label fragments =
  List.iter
    (fun fragment ->
      assert_source_not_contains source (label ^ ": " ^ fragment) fragment)
    fragments

let assert_source_contains_fragments source label fragments =
  List.iter
    (fun fragment ->
      assert_source_contains source (label ^ ": " ^ fragment) fragment)
    fragments

let test_core_emit_routes_first_slice_through_blorp_backend_boundary () =
  let core_emit_path = find_project_file core_emit_rel in
  let core_emit_intrinsic_path = find_project_file core_emit_intrinsic_rel in
  let core_emit_util_path =
    find_project_file (compiler_lib_rel "core_emit_util.ml")
  in
  let backend_path = find_project_file core_emit_blorp_backend_rel in
  let core_emit_source = read_file core_emit_path in
  let core_emit_intrinsic_source = read_file core_emit_intrinsic_path in
  let util_source = read_file core_emit_util_path in
  let backend_source = read_file backend_path in
  assert_source_omits_fragments core_emit_source
    "core emitter routes prepared Blorp emission through backend"
    blorp_prepared_backend_modules;
  assert_source_omits_fragments core_emit_intrinsic_source
    "intrinsic emitter routes prepared Blorp emission through backend"
    blorp_prepared_backend_modules;
  assert_source_omits_fragments util_source
    "shared emit utilities route prepared Blorp emission through backend"
    blorp_prepared_backend_modules;
  assert_source_contains_fragments backend_source
    "Blorp backend owns prepared module boundary" blorp_prepared_backend_modules

let emit_bridge render =
  let ctx = Blorp.Core_emit_context.create () in
  render ctx;
  Buffer.contents ctx.output

let render_bridge render =
  let ctx = Blorp.Core_emit_context.create () in
  render ctx

let test_blorp_backend_boundary_emits_expected_c () =
  let reg = Blorp.Codegen_types.create_registry () in
  let boxed_int =
    Blorp.Core_codegen_prepare.boxed_storage_value ~reg (cint 7)
  in
  let ty_small = Ast.TyNamed ("Small", []) in
  let ty_tuple_int = Ast.TyTuple [ ty_int ] in
  let ty_list_small = Ast.TyNamed ("List", [ ty_small ]) in
  let ty_list_string = Ast.TyNamed ("List", [ ty_string ]) in
  let ty_dict = Ast.TyNamed ("Dict", [ ty_string; ty_int ]) in
  let ty_set = Ast.TyNamed ("Set", [ ty_int ]) in
  let emitters =
    {
      Blorp.Core_emit_blorp_backend.emit_expr = Blorp.Core_emit.emit_expr;
      emit_stmt = Blorp.Core_emit.emit_stmt;
      emit_boxed_core = Blorp.Core_emit.emit_boxed;
      emit_boxed_storage = Blorp.Core_emit.emit_boxed_storage;
      type_to_c = (fun ctx ty -> Blorp.Codegen_types.type_to_c ~reg:ctx.reg ty);
    }
  in
  let string_read =
    {
      Core.sbr_source = cvar "s" ty_string;
      sbr_index = cint 2;
      sbr_proof = Core.StringReadBoundsProven;
    }
  in
  let string_write =
    {
      Core.sbw_target = cvar "s" ty_string;
      sbw_index = cint 1;
      sbw_byte = cint 65;
      sbw_proof = Core.StringWriteBoundsProven;
    }
  in
  let string_copy =
    {
      Core.sbc_dst = cvar "dst" ty_string;
      sbc_dst_pos = cint 0;
      sbc_src = cvar "src" ty_string;
      sbc_src_pos = cint 1;
      sbc_len = cint 3;
      sbc_proof = Core.StringCopyBoundsProven;
    }
  in
  let string_set_len =
    {
      Core.ssl_target = cvar "s" ty_string;
      ssl_len = cint 4;
      ssl_proof = Core.StringSetLenBoundsProven;
    }
  in
  let list_get =
    {
      Core.lg_list = cvar "xs" ty_list_int;
      lg_index = cint 1;
      lg_layout = Core.list_inline_storage Core.InlineBytes8;
      lg_bounds = Core.ListBoundsChecked;
    }
  in
  let list_inline_struct_get =
    {
      Core.lg_list = cvar "xs" ty_list_small;
      lg_index = cint 1;
      lg_layout = Core.list_inline_struct_storage "Small";
      lg_bounds = Core.ListBoundsChecked;
    }
  in
  let tensor_raw_view =
    {
      Core.trv_var = Core.Var.named "__raw";
      trv_kind = Core.TensorFloat64Elements;
      trv_source = cvar "values" ty_tensor_float;
    }
  in
  let tensor_raw_read =
    {
      Core.trr_view = Core.Var.named "__raw";
      trr_kind = Core.TensorFloat64Elements;
      trr_index = cint 1;
    }
  in
  let tensor_raw_write =
    {
      Core.trw_view = Core.Var.named "__raw";
      trw_kind = Core.TensorFloat64Elements;
      trw_index = cint 1;
      trw_value = core (Core.CLit (Ast.LitFloat 2.5)) ty_float;
    }
  in
  let list_result = cvar "result" ty_list_int in
  let tuple_construct_c =
    emit_bridge (fun ctx ->
        Blorp.Core_emit_blorp_backend.emit emitters ctx
          (Blorp.Core_emit_blorp_backend.TupleConstruct
             {
               Core.tc_elems = [ boxed_int ];
               tc_release_mask = 0;
               tc_retain_mask = 0;
             }))
  in
  let tuple_field_c =
    emit_bridge (fun ctx ->
        Blorp.Core_emit_blorp_backend.emit emitters ctx
          (Blorp.Core_emit_blorp_backend.TupleFieldAccess
             {
               obj = cvar "tuple" ty_tuple_int;
               field = "0";
               render_read = (fun element -> Printf.sprintf "(long)%s" element);
             }))
  in
  let dict_pair_c =
    emit_bridge (fun ctx ->
        Blorp.Core_emit_blorp_backend.emit emitters ctx
          (Blorp.Core_emit_blorp_backend.DictIterPairBinding
             { entry = "entry"; dict = "__dict_iter_0"; slot = "__dslot_0" }))
  in
  let dict_iter_source_c =
    emit_bridge (fun ctx ->
        Blorp.Core_emit_blorp_backend.emit emitters ctx
          (Blorp.Core_emit_blorp_backend.DictIterSourceBinding
             { dict = "__dict_iter_0"; source = cvar "items" ty_dict }))
  in
  let dict_iter_loop_c =
    emit_bridge (fun ctx ->
        Blorp.Core_emit_blorp_backend.emit emitters ctx
          (Blorp.Core_emit_blorp_backend.DictIterLoopOpen
             { index = "__di_0"; dict = "__dict_iter_0" }))
  in
  let dict_iter_slot_c =
    emit_bridge (fun ctx ->
        Blorp.Core_emit_blorp_backend.emit emitters ctx
          (Blorp.Core_emit_blorp_backend.DictIterSlotBinding
             { slot = "__dslot_0"; dict = "__dict_iter_0"; index = "__di_0" }))
  in
  let dict_iter_guard_c =
    emit_bridge (fun ctx ->
        Blorp.Core_emit_blorp_backend.emit emitters ctx
          (Blorp.Core_emit_blorp_backend.DictIterDeletedSlotGuard
             { slot = "__dslot_0" }))
  in
  let dict_iter_key_c =
    emit_bridge (fun ctx ->
        Blorp.Core_emit_blorp_backend.emit emitters ctx
          (Blorp.Core_emit_blorp_backend.DictIterKeyBinding
             {
               key_c_type = "long";
               binding = "key";
               dict = "__dict_iter_0";
               slot = "__dslot_0";
             }))
  in
  let set_iter_source_c =
    emit_bridge (fun ctx ->
        Blorp.Core_emit_blorp_backend.emit emitters ctx
          (Blorp.Core_emit_blorp_backend.SetIterSourceBinding
             { set = "__set_iter_0"; source = cvar "items" ty_set }))
  in
  let set_iter_retain_c =
    emit_bridge (fun ctx ->
        Blorp.Core_emit_blorp_backend.emit emitters ctx
          (Blorp.Core_emit_blorp_backend.SetIterRetain { set = "__set_iter_0" }))
  in
  let set_iter_loop_c =
    emit_bridge (fun ctx ->
        Blorp.Core_emit_blorp_backend.emit emitters ctx
          (Blorp.Core_emit_blorp_backend.SetIterLoopOpen
             { entry = "__set_entry_0"; set = "__set_iter_0" }))
  in
  let set_iter_key_c =
    Blorp.Core_emit_blorp_backend.render_set_iter_entry_key
      ~entry:"__set_entry_0"
  in
  let set_iter_release_c =
    emit_bridge (fun ctx ->
        Blorp.Core_emit_blorp_backend.emit emitters ctx
          (Blorp.Core_emit_blorp_backend.SetIterRelease { set = "__set_iter_0" }))
  in
  let tuple_element_c =
    Blorp.Core_emit_blorp_backend.render_tuple_field_element_at
      ~tuple_tmp:"__tup_0" ~index:0
  in
  let string_find_c =
    emit_bridge (fun ctx ->
        Blorp.Core_emit_blorp_backend.emit emitters ctx
          (Blorp.Core_emit_blorp_backend.StringFindByteFrom
             { source = cvar "s" ty_string; byte = cint 97; start = cint 2 }))
  in
  let string_read_c =
    emit_bridge (fun ctx ->
        Blorp.Core_emit_blorp_backend.emit emitters ctx
          (Blorp.Core_emit_blorp_backend.StringByteRead string_read))
  in
  let string_write_c =
    emit_bridge (fun ctx ->
        Blorp.Core_emit_blorp_backend.emit emitters ctx
          (Blorp.Core_emit_blorp_backend.StringByteWrite string_write))
  in
  let string_copy_c =
    emit_bridge (fun ctx ->
        Blorp.Core_emit_blorp_backend.emit emitters ctx
          (Blorp.Core_emit_blorp_backend.StringByteCopy string_copy))
  in
  let string_set_len_c =
    emit_bridge (fun ctx ->
        Blorp.Core_emit_blorp_backend.emit emitters ctx
          (Blorp.Core_emit_blorp_backend.StringSetLen string_set_len))
  in
  let list_get_c =
    emit_bridge (fun ctx ->
        Blorp.Core_emit_blorp_backend.emit emitters ctx
          (Blorp.Core_emit_blorp_backend.ListGet list_get))
  in
  let list_construct_c =
    emit_bridge (fun ctx ->
        Blorp.Core_emit_blorp_backend.emit emitters ctx
          (Blorp.Core_emit_blorp_backend.ListConstruct
             {
               Core.lc_layout = Core.list_pointer_storage ();
               lc_elems = [ boxed_int ];
               lc_elem_needs_release = false;
             }))
  in
  let list_handoff_c =
    emit_bridge (fun ctx ->
        Blorp.Core_emit_blorp_backend.emit emitters ctx
          (Blorp.Core_emit_blorp_backend.ListHandoff
             {
               result = core Core.CVoid ty_list_int;
               handoff =
                 {
                   Core.lh_mode = Core.BorrowFresh;
                   lh_layout =
                     Core.list_pointer_storage
                       ~policy:Core.StoragePolicyUnmanagedBits ();
                   lh_source = cvar "xs" ty_list_int;
                   lh_source_var = Core.Var.named "source";
                   lh_source_ty = ty_list_int;
                   lh_result_ty = ty_list_int;
                   lh_capacity = cint 3;
                   lh_result_var = Core.Var.named "result";
                   lh_len_var = Core.Var.named "len";
                   lh_out_var = Core.Var.named "out";
                   lh_body = core Core.CVoid ty_void;
                   lh_write_order = Core.ForwardCompacting;
                 };
             }))
  in
  let tensor_raw_view_c =
    emit_bridge (fun ctx ->
        Blorp.Core_emit_blorp_backend.emit emitters ctx
          (Blorp.Core_emit_blorp_backend.TensorRawViewDecl tensor_raw_view))
  in
  let tensor_literal_c =
    emit_bridge (fun ctx ->
        Blorp.Core_emit_blorp_backend.emit emitters ctx
          (Blorp.Core_emit_blorp_backend.TensorLiteral
             {
               loc = test_loc;
               literal =
                 {
                   Core.tl_shape = Core.TensorVectorLength 1;
                   tl_layout =
                     Core.tensor_raw_scalar_storage ~elem_ty:ty_float
                       Core.TensorFloat64Elements;
                   tl_payload =
                     Core.TensorRawElements
                       ( Core.TensorFloat64Elements,
                         [ core (Core.CLit (Ast.LitFloat 2.5)) ty_float ] );
                 };
             }))
  in
  let tensor_direct_fill_c =
    emit_bridge (fun ctx ->
        Blorp.Core_emit_blorp_backend.emit emitters ctx
          (Blorp.Core_emit_blorp_backend.TensorDirectFillFactory
             {
               loc = test_loc;
               layout =
                 Core.tensor_raw_scalar_storage ~elem_ty:ty_float
                   Core.TensorFloat64Elements;
               value = core (Core.CLit (Ast.LitFloat 2.5)) ty_float;
               dims = [ cint 2; cint 3 ];
             }))
  in
  let tensor_inline_struct_fill_c =
    emit_bridge (fun ctx ->
        Blorp.Core_emit_blorp_backend.emit emitters ctx
          (Blorp.Core_emit_blorp_backend.TensorFillInlineStruct
             {
               function_name = "blorp_vector_new_fill";
               value = cvar "point" ty_small;
               dims = [ cint 2 ];
               struct_ty = "Small";
             }))
  in
  let tensor_boxed_fill_c =
    emit_bridge (fun ctx ->
        Blorp.Core_emit_blorp_backend.emit emitters ctx
          (Blorp.Core_emit_blorp_backend.TensorFillBoxed
             {
               function_name = "blorp_vector_new_fill";
               value = cvar "value" ty_string;
               dims = [ cint 2 ];
               fill_value_policy = Blorp.Core_emit_blorp_backend.KeepFillValue;
             }))
  in
  let tensor_raw_read_c =
    emit_bridge (fun ctx ->
        Blorp.Core_emit_blorp_backend.emit emitters ctx
          (Blorp.Core_emit_blorp_backend.TensorRawRead tensor_raw_read))
  in
  let tensor_raw_write_expr_c =
    emit_bridge (fun ctx ->
        Blorp.Core_emit_blorp_backend.emit emitters ctx
          (Blorp.Core_emit_blorp_backend.TensorRawWriteExpr tensor_raw_write))
  in
  let tensor_raw_write_stmt_c =
    emit_bridge (fun ctx ->
        Blorp.Core_emit_blorp_backend.emit emitters ctx
          (Blorp.Core_emit_blorp_backend.TensorRawWriteStmt tensor_raw_write))
  in
  let list_store_c =
    emit_bridge (fun ctx ->
        Blorp.Core_emit_blorp_backend.emit emitters ctx
          (Blorp.Core_emit_blorp_backend.ListStore
             {
               runtime = Blorp.Core_emit_blorp_backend.ListSetRawStore;
               list = cvar "xs" ty_list_int;
               index = cint 1;
               value = cint 42;
             }))
  in
  let list_reuse_c =
    emit_bridge (fun ctx ->
        Blorp.Core_emit_blorp_backend.emit emitters ctx
          (Blorp.Core_emit_blorp_backend.ListReuseAllocForResult
             {
               result = list_result;
               list = cvar "xs" ty_list_int;
               capacity = cint 4;
             }))
  in
  let list_alloc_for_layout_c =
    emit_bridge (fun ctx ->
        Blorp.Core_emit_blorp_backend.emit emitters ctx
          (Blorp.Core_emit_blorp_backend.ListAllocForLayout
             {
               layout = Core.list_inline_storage Core.InlineBytes8;
               loc = test_loc;
               capacity = cint 4;
             }))
  in
  let list_alloc_for_type_c =
    emit_bridge (fun ctx ->
        Blorp.Core_emit_blorp_backend.emit emitters ctx
          (Blorp.Core_emit_blorp_backend.ListAllocForType
             { ty = ty_list_string; loc = test_loc; capacity = cint 4 }))
  in
  let empty_list_alloc_for_type_c =
    emit_bridge (fun ctx ->
        Blorp.Core_emit_blorp_backend.emit emitters ctx
          (Blorp.Core_emit_blorp_backend.ListAllocForTypeCapacityArg
             { ty = ty_list_string; loc = test_loc; capacity_arg = "0" }))
  in
  let list_inline_struct_load_c =
    emit_bridge (fun ctx ->
        Blorp.Core_emit_blorp_backend.emit emitters ctx
          (Blorp.Core_emit_blorp_backend.ListInlineStructDynamicLoad
             {
               list_tmp = "__list";
               idx_tmp = "__idx";
               out_tmp = "__out";
               struct_ty = "Small";
               bounds = Core.ListBoundsChecked;
             }))
  in
  let list_inline_struct_unbox_c =
    emit_bridge (fun ctx ->
        Blorp.Core_emit_blorp_backend.emit emitters ctx
          (Blorp.Core_emit_blorp_backend.ListInlineStructUnboxGet
             { get = list_inline_struct_get; struct_ty = "Small" }))
  in
  let list_inline_bits_load_c =
    emit_bridge (fun ctx ->
        Blorp.Core_emit_blorp_backend.emit emitters ctx
          (Blorp.Core_emit_blorp_backend.ListInlineBitsLoad
             {
               list_tmp = "__list";
               idx_tmp = "__idx";
               bits_tmp = "__bits";
               width = Core.InlineBytes8;
             }))
  in
  let tensor_word_storage_c =
    emit_bridge (fun ctx ->
        Blorp.Core_emit_blorp_backend.emit emitters ctx
          (Blorp.Core_emit_blorp_backend.TensorStorageCheck
             {
               check = Blorp.Core_emit_blorp_backend.TensorWordStorageCheck;
               tensor = cvar "values" ty_tensor_float;
             }))
  in
  let tensor_raw_get_c =
    emit_bridge (fun ctx ->
        Blorp.Core_emit_blorp_backend.emit emitters ctx
          (Blorp.Core_emit_blorp_backend.TensorF64RawGetUnchecked
             { tensor = cvar "values" ty_tensor_float; index = cint 1 }))
  in
  let tensor_inline_struct_get_c =
    emit_bridge (fun ctx ->
        Blorp.Core_emit_blorp_backend.emit emitters ctx
          (Blorp.Core_emit_blorp_backend.TensorInlineStructGetUnchecked
             {
               tensor = cvar "values" ty_tensor_float;
               index = cint 1;
               struct_ty = "Small";
             }))
  in
  let tensor_inline_struct_element_decl_c =
    emit_bridge (fun ctx ->
        Blorp.Core_emit_blorp_backend.emit emitters ctx
          (Blorp.Core_emit_blorp_backend.TensorInlineStructElementDecl
             {
               var_c = "item";
               tensor_c = "values";
               index_c = "idx";
               struct_ty = "Small";
             }))
  in
  let dict_ctor_c =
    Blorp.Core_emit_blorp_backend.render_dict_constructor
      Blorp.Core_emit_blorp_backend.DictCtorString
  in
  let custom_ctor_c =
    Blorp.Core_emit_blorp_backend.render_custom_constructor
      "blorp_set_new_custom" ~hash_fn:"hash_key" ~equals_fn:"equals_key"
      ~key_release:Blorp.Core_emit_blorp_backend.ElemReleaseFn
  in
  let set_generic_c =
    emit_bridge (fun ctx ->
        Blorp.Core_emit_blorp_backend.emit emitters ctx
          (Blorp.Core_emit_blorp_backend.SetAlloc
             Blorp.Core_emit_blorp_backend.SetCtorGeneric))
  in
  let set_string_c =
    emit_bridge (fun ctx ->
        Blorp.Core_emit_blorp_backend.emit emitters ctx
          (Blorp.Core_emit_blorp_backend.SetAlloc
             Blorp.Core_emit_blorp_backend.SetCtorString))
  in
  let set_float_c =
    emit_bridge (fun ctx ->
        Blorp.Core_emit_blorp_backend.emit emitters ctx
          (Blorp.Core_emit_blorp_backend.SetAlloc
             Blorp.Core_emit_blorp_backend.SetCtorFloat))
  in
  let set_custom_c =
    emit_bridge (fun ctx ->
        Blorp.Core_emit_blorp_backend.emit emitters ctx
          (Blorp.Core_emit_blorp_backend.SetAlloc
             (Blorp.Core_emit_blorp_backend.SetCtorCustom
                {
                  hash_fn = "hash_key";
                  equals_fn = "equals_key";
                  elem_release = Blorp.Core_emit_blorp_backend.NoElemRelease;
                })))
  in
  let list_storage_mode_c, list_elem_size_c =
    Blorp.Core_emit_blorp_backend.list_runtime_storage_args
      (Core.list_inline_storage Core.InlineBytes8)
  in
  let list_release_arg_c =
    Blorp.Core_emit_blorp_backend.list_elem_release_arg ~loc:test_loc
      (Core.list_pointer_storage ~policy:Core.StoragePolicyManagedPointer ())
  in
  let tensor_storage_mode_c, tensor_elem_size_c =
    Blorp.Core_emit_blorp_backend.tensor_runtime_storage_args
      (Core.tensor_raw_scalar_storage ~elem_ty:ty_float
         Core.TensorFloat64Elements)
  in
  let tensor_callback_encoding_c =
    Blorp.Core_emit_blorp_backend.tensor_callback_result_encoding_arg
      (Core.tensor_raw_scalar_storage ~elem_ty:ty_float
         Core.TensorFloat64Elements)
  in
  let dict_capacity_ctor_c =
    let ctx = Blorp.Core_emit_context.create () in
    Blorp.Core_emit_blorp_backend.render_dict_capacity_constructor emitters ctx
      (Blorp.Core_emit_blorp_backend.DictWithCapacityFloat (cint 8))
  in
  let dict_construct_result_c =
    emit_bridge (fun ctx ->
        Blorp.Core_emit_blorp_backend.emit emitters ctx
          (Blorp.Core_emit_blorp_backend.DictConstructResult
             {
               ctor_arg = "blorp_dict_new_string()";
               value_needs_release = false;
             }))
  in
  let dict_construct_storage_c =
    emit_bridge (fun ctx ->
        Blorp.Core_emit_blorp_backend.emit emitters ctx
          (Blorp.Core_emit_blorp_backend.DictConstructStorage
             {
               ctor_arg = "blorp_dict_new()";
               value_needs_release = false;
               force_wrapper = false;
               entries = [ (boxed_int, boxed_int) ];
             }))
  in
  let dict_construct_core_c =
    emit_bridge (fun ctx ->
        Blorp.Core_emit_blorp_backend.emit emitters ctx
          (Blorp.Core_emit_blorp_backend.DictConstructCore
             {
               ctor_arg = "blorp_dict_new()";
               value_needs_release = false;
               force_wrapper = true;
               entries = [ (cint 1, cint 2) ];
             }))
  in
  Alcotest.(check string)
    "backend tuple construct output"
    "blorp_tuple_new(1, ({ long __box_0 = 7L; (void*)(long)(__box_0); }))"
    tuple_construct_c;
  Alcotest.(check string)
    "backend tuple field output"
    "({ void* __tup_0 = (void*)tuple; (long)((blorp_Tuple*)__tup_0)->elem[0]; \
     })"
    tuple_field_c;
  Alcotest.(check string)
    "backend dict pair binding output"
    "blorp_Tuple* entry = blorp_tuple_new(2, __dict_iter_0->keys[__dslot_0], \
     __dict_iter_0->values[__dslot_0]);\n"
    dict_pair_c;
  Alcotest.(check string)
    "backend dict iter source output"
    "blorp_Dict* __dict_iter_0 = (blorp_Dict*)items;\n" dict_iter_source_c;
  Alcotest.(check string)
    "backend dict iter loop output"
    "for (long __di_0 = 0; __di_0 < __dict_iter_0->order_len; __di_0++) {\n"
    dict_iter_loop_c;
  Alcotest.(check string)
    "backend dict iter slot output"
    "long __dslot_0 = __dict_iter_0->order[__di_0];\n" dict_iter_slot_c;
  Alcotest.(check string)
    "backend dict iter deleted-slot guard output"
    "if (__dslot_0 < 0) continue;\n" dict_iter_guard_c;
  Alcotest.(check string)
    "backend dict iter key output"
    "long key = (long)__dict_iter_0->keys[__dslot_0];\n" dict_iter_key_c;
  Alcotest.(check string)
    "backend set iter source output"
    "blorp_Set* __set_iter_0 = (blorp_Set*)items;\n" set_iter_source_c;
  Alcotest.(check string)
    "backend set iter retain output" "blorp_retain(__set_iter_0);\n"
    set_iter_retain_c;
  Alcotest.(check string)
    "backend set iter loop output"
    "for (blorp_SetEntry* __set_entry_0 = __set_iter_0->first; __set_entry_0 \
     != NULL; __set_entry_0 = __set_entry_0->next_order) {\n"
    set_iter_loop_c;
  Alcotest.(check string)
    "backend set iter key output" "__set_entry_0->key" set_iter_key_c;
  Alcotest.(check string)
    "backend set iter release output" "blorp_release(__set_iter_0);\n"
    set_iter_release_c;
  Alcotest.(check string)
    "backend tuple element render output" "((blorp_Tuple*)__tup_0)->elem[0]"
    tuple_element_c;
  Alcotest.(check string)
    "backend string find output"
    "({ blorp_String* __string_find_src_0 = (blorp_String*)s; long \
     __string_find_byte_0 = 97L; long __string_find_start_0 = 2L; \
     blorp_string_find_byte_from(__string_find_src_0, __string_find_byte_0, \
     __string_find_start_0); })"
    string_find_c;
  Alcotest.(check string)
    "backend string byte read output"
    "(long)(unsigned char)((blorp_String*)s)->data[2L]" string_read_c;
  Alcotest.(check string)
    "backend string byte write output"
    "(((blorp_String*)s)->data[1L] = (char)65L)" string_write_c;
  Alcotest.(check string)
    "backend string byte copy output"
    "({ blorp_String* __string_copy_dst_0 = (blorp_String*)dst; long \
     __string_copy_dst_pos_0 = 0L; blorp_String* __string_copy_src_0 = \
     (blorp_String*)src; long __string_copy_src_pos_0 = 1L; long \
     __string_copy_len_0 = 3L; if (__string_copy_len_0 > 0) { \
     memcpy(__string_copy_dst_0->data + __string_copy_dst_pos_0, \
     __string_copy_src_0->data + __string_copy_src_pos_0, \
     (size_t)__string_copy_len_0); } (void)0; })"
    string_copy_c;
  Alcotest.(check string)
    "backend string set-len output"
    "({ blorp_String* __sl = (blorp_String*)s; long __sn = 4L; __sl->len = \
     __sn; __sl->data[__sn] = '\\0'; (void)0; })"
    string_set_len_c;
  Alcotest.(check string)
    "backend inline list get output"
    "({ blorp_List* __lg_list_0 = (blorp_List*)xs; long __lg_idx_0 = 1L; \
     (__builtin_expect(!__lg_list_0 || __lg_idx_0 < 0 || __lg_idx_0 >= \
     __lg_list_0->len, 0) ? NULL : ({ uintptr_t __lg_bits_0 = 0; \
     memcpy(&__lg_bits_0, (char*)__lg_list_0->data + __lg_idx_0 * 8, 8); \
     (void*)__lg_bits_0; })); })"
    list_get_c;
  Alcotest.(check string)
    "backend list construct output"
    "({ blorp_List* __lst_0 = blorp_list_new(1); __lst_0 = \
     blorp_list_append(__lst_0, ({ long __box_1 = 7L; (void*)(long)(__box_1); \
     })); __lst_0; })"
    list_construct_c;
  Alcotest.(check string)
    "backend list handoff output"
    "({ blorp_List* source = xs; long __lh_cap_0 = 3L; long len = source ? \
     ((blorp_List*)source)->len : 0L; void (*__lh_release_0)(void*) = NULL; \
     blorp_List* result = \
     (blorp_List*)blorp_list_handoff_begin_borrow(__lh_cap_0, __lh_release_0, \
     BLORP_LIST_STORAGE_POINTER, sizeof(void*)); long out = 0L; \
     blorp_list_handoff_finish((blorp_List*)result, out, len, false, NULL); \
     result; })"
    list_handoff_c;
  Alcotest.(check string)
    "backend tensor raw view output"
    "double* __raw = (double*)((blorp_Vector*)values)->data" tensor_raw_view_c;
  Alcotest.(check string)
    "backend tensor literal output"
    "({ blorp_Vector* __ten_0 = blorp_vector_new_f64(1); \
     blorp_vector_write_f64(__ten_0, 0, 2.5); __ten_0; })"
    tensor_literal_c;
  Alcotest.(check string)
    "backend tensor direct fill output"
    "({ long __tensor_fill_dim_0_0 = 2L; long __tensor_fill_dim_0_1 = 3L; long \
     __tensor_fill_total_0 = (__tensor_fill_dim_0_0 * __tensor_fill_dim_0_1); \
     double __tensor_fill_value_0 = 2.5; blorp_Vector* __tensor_fill_vec_0 = \
     blorp_tensor_new_f64(__tensor_fill_dim_0_0, __tensor_fill_total_0); \
     double* __tensor_fill_raw_0 = (double*)__tensor_fill_vec_0->data; for \
     (long __tensor_fill_i_0 = 0; __tensor_fill_i_0 < \
     __tensor_fill_vec_0->capacity; __tensor_fill_i_0++) \
     __tensor_fill_raw_0[__tensor_fill_i_0] = __tensor_fill_value_0; \
     __tensor_fill_vec_0; })"
    tensor_direct_fill_c;
  Alcotest.(check string)
    "backend tensor inline-struct fill output"
    "({ Small __fill_0 = point; blorp_vector_new_fill_sized(&__fill_0, 2L, \
     sizeof(Small)); })"
    tensor_inline_struct_fill_c;
  Alcotest.(check string)
    "backend tensor boxed fill output"
    "({ void* __fill_0 = value; blorp_Vector* __vec_0 = \
     blorp_vector_new_fill(__fill_0, 2L); \
     blorp_vector_set_elem_release(__vec_0, blorp_elem_release_fn); __vec_0; \
     })"
    tensor_boxed_fill_c;
  Alcotest.(check string)
    "backend tensor raw read output" "__raw[1L]" tensor_raw_read_c;
  Alcotest.(check string)
    "backend tensor raw write expr output" "({ __raw[1L] = 2.5; (void)0; })"
    tensor_raw_write_expr_c;
  Alcotest.(check string)
    "backend tensor raw write stmt output" "__raw[1L] = 2.5;"
    tensor_raw_write_stmt_c;
  Alcotest.(check string)
    "backend inline list store output"
    "({ blorp_List* __list_store_0 = (blorp_List*)xs; long __list_store_idx_0 \
     = 1L; uintptr_t __list_store_bits_0 = (uintptr_t)(void*)(long)(42L); \
     memcpy((char*)__list_store_0->data + __list_store_idx_0 * 8, \
     &__list_store_bits_0, 8); })"
    list_store_c;
  Alcotest.(check string)
    "backend list reuse alloc output" "blorp_list_reuse_alloc(xs, 4L)"
    list_reuse_c;
  Alcotest.(check string)
    "backend list alloc-for-layout output" "blorp_list_new_inline(4L, 8)"
    list_alloc_for_layout_c;
  Alcotest.(check string)
    "backend list alloc-for-type output"
    "({ blorp_List* __lst_0 = blorp_list_new(4L); \
     blorp_list_init_elem_release(__lst_0, blorp_elem_release_fn); __lst_0; })"
    list_alloc_for_type_c;
  Alcotest.(check string)
    "backend empty list alloc-for-type output"
    "({ blorp_List* __lst_0 = blorp_list_new(0); \
     blorp_list_init_elem_release(__lst_0, blorp_elem_release_fn); __lst_0; })"
    empty_list_alloc_for_type_c;
  Alcotest.(check string)
    "backend inline struct load output"
    "if (__builtin_expect(!__list || __idx < 0 || __idx >= __list->len, 0)) { \
     memset(&__out, 0, sizeof(Small)); } else if (__list->storage_mode == \
     BLORP_LIST_STORAGE_INLINE && __list->elem_size == (int16_t)sizeof(Small)) \
     { memcpy(&__out, (char*)__list->data + __idx * sizeof(Small), \
     sizeof(Small)); } else { void* __lg_raw_0 = blorp_list_get(__list, \
     __idx); if (!__lg_raw_0) { memset(&__out, 0, sizeof(Small)); } else { \
     __out = blorp_unbox_struct(__lg_raw_0, Small); } }"
    list_inline_struct_load_c;
  Alcotest.(check string)
    "backend inline struct unbox get output"
    "({ blorp_List* __lg_list_0 = (blorp_List*)xs; long __lg_idx_0 = 1L; Small \
     __lg_out_0; if (__builtin_expect(!__lg_list_0 || __lg_idx_0 < 0 || \
     __lg_idx_0 >= __lg_list_0->len, 0)) { memset(&__lg_out_0, 0, \
     sizeof(Small)); } else if (__lg_list_0->storage_mode == \
     BLORP_LIST_STORAGE_INLINE && __lg_list_0->elem_size == \
     (int16_t)sizeof(Small)) { memcpy(&__lg_out_0, (char*)__lg_list_0->data + \
     __lg_idx_0 * sizeof(Small), sizeof(Small)); } else { void* __lg_raw_1 = \
     blorp_list_get(__lg_list_0, __lg_idx_0); if (!__lg_raw_1) { \
     memset(&__lg_out_0, 0, sizeof(Small)); } else { __lg_out_0 = \
     blorp_unbox_struct(__lg_raw_1, Small); } } __lg_out_0; })"
    list_inline_struct_unbox_c;
  Alcotest.(check string)
    "backend inline bits load output"
    "uintptr_t __bits = 0; memcpy(&__bits, (char*)__list->data + __idx * 8, 8);"
    list_inline_bits_load_c;
  Alcotest.(check string)
    "backend tensor word storage output"
    "({ blorp_Vector* __tensor_layout_0 = (blorp_Vector*)values; \
     __tensor_layout_0 && __tensor_layout_0->storage_mode == \
     BLORP_VECTOR_STORAGE_POINTER && __tensor_layout_0->elem_size == \
     (int16_t)sizeof(void*) && __tensor_layout_0->elem_release == NULL; })"
    tensor_word_storage_c;
  Alcotest.(check string)
    "backend tensor f64 raw get output"
    "({ blorp_Vector* __tensor_raw_vec_0 = (blorp_Vector*)values; long \
     __tensor_raw_idx_0 = 1L; double __tensor_raw_0; memcpy(&__tensor_raw_0, \
     (char*)__tensor_raw_vec_0->data + __tensor_raw_idx_0 * sizeof(double), \
     sizeof(double)); __tensor_raw_0; })"
    tensor_raw_get_c;
  Alcotest.(check string)
    "backend tensor inline struct get output"
    "({ blorp_Vector* __tgu_vec_0 = (blorp_Vector*)values; long __tgu_idx_0 = \
     1L; Small __tgu_out_0; if (__builtin_expect(__tgu_vec_0->storage_mode == \
     BLORP_VECTOR_STORAGE_INLINE && __tgu_vec_0->elem_size == sizeof(Small), \
     1)) { memcpy(&__tgu_out_0, (char*)__tgu_vec_0->data + __tgu_idx_0 * \
     sizeof(Small), sizeof(Small)); } else { void* __tgu_raw_0 = \
     __tgu_vec_0->data[__tgu_idx_0]; __tgu_out_0 = \
     blorp_unbox_struct(__tgu_raw_0, Small); } __tgu_out_0; })"
    tensor_inline_struct_get_c;
  Alcotest.(check string)
    "backend tensor inline struct element decl output"
    "Small item = ({ blorp_Vector* __tgu_vec_0 = (blorp_Vector*)values; long \
     __tgu_idx_0 = idx; Small __tgu_out_0; if \
     (__builtin_expect(__tgu_vec_0->storage_mode == \
     BLORP_VECTOR_STORAGE_INLINE && __tgu_vec_0->elem_size == sizeof(Small), \
     1)) { memcpy(&__tgu_out_0, (char*)__tgu_vec_0->data + __tgu_idx_0 * \
     sizeof(Small), sizeof(Small)); } else { void* __tgu_raw_0 = \
     __tgu_vec_0->data[__tgu_idx_0]; __tgu_out_0 = \
     blorp_unbox_struct(__tgu_raw_0, Small); } __tgu_out_0; });\n"
    tensor_inline_struct_element_decl_c;
  Alcotest.(check string)
    "backend dict ctor output" "blorp_dict_new_string()" dict_ctor_c;
  Alcotest.(check string)
    "backend custom ctor output"
    "blorp_set_new_custom((unsigned long (*)(void*))hash_key, (bool (*)(void*, \
     void*))equals_key, blorp_elem_release_fn)"
    custom_ctor_c;
  Alcotest.(check string)
    "backend set generic ctor output" "blorp_set_new()" set_generic_c;
  Alcotest.(check string)
    "backend set string ctor output" "blorp_set_new_string()" set_string_c;
  Alcotest.(check string)
    "backend set float ctor output" "blorp_set_new_float()" set_float_c;
  Alcotest.(check string)
    "backend set custom ctor output"
    "blorp_set_new_custom((unsigned long (*)(void*))hash_key, (bool (*)(void*, \
     void*))equals_key, NULL)"
    set_custom_c;
  Alcotest.(check string)
    "backend list storage mode output" "BLORP_LIST_STORAGE_INLINE"
    list_storage_mode_c;
  Alcotest.(check string) "backend list elem size output" "8" list_elem_size_c;
  Alcotest.(check string)
    "backend list release arg output" "blorp_elem_release_fn" list_release_arg_c;
  Alcotest.(check string)
    "backend tensor storage mode output" "BLORP_VECTOR_STORAGE_F64"
    tensor_storage_mode_c;
  Alcotest.(check string)
    "backend tensor elem size output" "sizeof(double)" tensor_elem_size_c;
  Alcotest.(check string)
    "backend tensor callback encoding output"
    "BLORP_VECTOR_CALLBACK_BOXED_FLOAT" tensor_callback_encoding_c;
  Alcotest.(check string)
    "backend dict capacity ctor output" "blorp_dict_with_capacity_float(8L)"
    dict_capacity_ctor_c;
  Alcotest.(check string)
    "backend dict construct-result output" "blorp_dict_new_string()"
    dict_construct_result_c;
  Alcotest.(check string)
    "backend dict storage construct output"
    "({ blorp_Dict* __dict_0 = blorp_dict_new(); __dict_0 = \
     blorp_dict_insert(__dict_0, ({ long __box_1 = 7L; (void*)(long)(__box_1); \
     }), ({ long __box_2 = 7L; (void*)(long)(__box_2); })); __dict_0; })"
    dict_construct_storage_c;
  Alcotest.(check string)
    "backend dict core construct output"
    "({ blorp_Dict* __dict_0 = blorp_dict_new(); __dict_0 = \
     blorp_dict_insert(__dict_0, (void*)(long)(1L), (void*)(long)(2L)); \
     __dict_0; })"
    dict_construct_core_c

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
  let ty_list_string = Ast.TyNamed ("List", [ ty_string ]) in
  let get =
    {
      Core.lg_list = cvar "xs" ty_list_int;
      lg_index = cint 1;
      lg_layout = Core.list_inline_storage Core.InlineBytes8;
      lg_bounds = Core.ListBoundsChecked;
    }
  in
  let inline_struct_get =
    {
      Core.lg_list = cvar "xs" ty_list_small;
      lg_index = cint 1;
      lg_layout = Core.list_inline_struct_storage "Small";
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
  let inline_struct_unbox_get =
    emit_bridge (fun ctx ->
        Blorp.Core_emit_blorp_prepared_list.emit_inline_struct_unbox_get
          ~emit_expr:Blorp.Core_emit.emit_expr ctx inline_struct_get
          ~struct_ty:"Small")
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
        Blorp.Core_emit_blorp_prepared_list.emit_inline_struct_store_template
          ~emit_expr:Blorp.Core_emit.emit_expr ctx
          ~template:Blorp.Core_emit_blorp_prepared_list.SetRawStoreTemplate
          (cvar "xs" ty_list_small) (cint 1) (cvar "next" small_ty)
          ~struct_ty:"Small")
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
  let pointer_storage_mode, pointer_elem_size =
    Blorp.Core_emit_blorp_prepared_list.runtime_storage_args
      (Core.list_pointer_storage ())
  in
  let inline_storage_mode, inline_elem_size =
    Blorp.Core_emit_blorp_prepared_list.runtime_storage_args
      (Core.list_inline_storage Core.InlineBytes8)
  in
  let inline_struct_storage_mode, inline_struct_elem_size =
    Blorp.Core_emit_blorp_prepared_list.runtime_storage_args
      (Core.list_inline_struct_storage "Small")
  in
  let unmanaged_release_arg =
    Blorp.Core_emit_blorp_prepared_list.elem_release_arg ~loc:test_loc
      (Core.list_inline_storage Core.InlineBytes8)
  in
  let managed_release_arg =
    Blorp.Core_emit_blorp_prepared_list.elem_release_arg ~loc:test_loc
      (Core.list_pointer_storage ~policy:Core.StoragePolicyManagedPointer ())
  in
  let release_alloc =
    Blorp.Core_emit_blorp_prepared_list.render_alloc_with_release
      ~alloc_expr:"blorp_list_new(4L)" ~result_tmp:"__lst"
  in
  let alloc_for_layout_c =
    emit_bridge (fun ctx ->
        Blorp.Core_emit_blorp_prepared_list.emit_alloc_for_layout
          ~emit_expr:Blorp.Core_emit.emit_expr ctx
          (Core.list_inline_storage Core.InlineBytes8)
          ~loc:test_loc (cint 4))
  in
  let alloc_for_type_with_release_c =
    emit_bridge (fun ctx ->
        Blorp.Core_emit_blorp_prepared_list.emit_alloc_for_type
          ~emit_expr:Blorp.Core_emit.emit_expr ctx ty_list_string ~loc:test_loc
          (cint 4))
  in
  let empty_alloc_for_type_with_release_c =
    emit_bridge (fun ctx ->
        Blorp.Core_emit_blorp_prepared_list.emit_alloc_for_type_capacity_arg ctx
          ty_list_string ~loc:test_loc "0")
  in
  let reuse_alloc_c =
    emit_bridge (fun ctx ->
        Blorp.Core_emit_blorp_prepared_list.emit_reuse_alloc_for_result
          ~emit_expr:Blorp.Core_emit.emit_expr ctx
          (cvar "result" ty_list_int)
          (cvar "xs" ty_list_int) (cint 4))
  in
  let reuse_alloc_with_release_c =
    emit_bridge (fun ctx ->
        Blorp.Core_emit_blorp_prepared_list.emit_reuse_alloc_for_result
          ~emit_expr:Blorp.Core_emit.emit_expr ctx
          (cvar "result" ty_list_string)
          (cvar "strings" ty_list_string)
          (cint 4))
  in
  let retain_reg = Blorp.Codegen_types.create_registry () in
  let boxed_int_for_retain =
    Blorp.Core_codegen_prepare.boxed_storage_value ~reg:retain_reg (cint 7)
  in
  let boxed_string_for_retain =
    Blorp.Core_codegen_prepare.boxed_storage_value ~reg:retain_reg
      (cvar "value" ty_string)
  in
  let retain_for_noop_c =
    emit_bridge (fun ctx ->
        Blorp.Core_emit_blorp_prepared_list.emit_retain_for_storage
          ~emit_expr:Blorp.Core_emit.emit_expr
          ~emit_boxed:Blorp.Core_emit.emit_boxed_storage ctx
          (cvar "xs" ty_list_int) boxed_int_for_retain)
  in
  let retain_for_c =
    emit_bridge (fun ctx ->
        Blorp.Core_emit_blorp_prepared_list.emit_retain_for_storage
          ~emit_expr:Blorp.Core_emit.emit_expr
          ~emit_boxed:Blorp.Core_emit.emit_boxed_storage ctx
          (cvar "strings" ty_list_string)
          boxed_string_for_retain)
  in
  let construct_name =
    Blorp.Core_emit_blorp_prepared_list.render_construct_name "0"
  in
  let construct =
    Blorp.Core_emit_blorp_prepared_list.render_construct ~list_tmp:"__lst_0"
      ~alloc_call:"blorp_list_new(2)"
      ~statements:[ "__lst_0 = blorp_list_append(__lst_0, value);" ]
  in
  let construct_release =
    Blorp.Core_emit_blorp_prepared_list.render_construct_init_elem_release
      ~list_tmp:"__lst"
  in
  let construct_inline_struct =
    render_bridge (fun ctx ->
        Blorp.Core_emit_blorp_prepared_list.render_construct_inline_struct_set
          ~emit_expr:Blorp.Core_emit.emit_expr ctx ~list_tmp:"__lst" ~index:2
          ~struct_ty:"Small" (cvar "next" small_ty))
  in
  let construct_set_len =
    Blorp.Core_emit_blorp_prepared_list.render_construct_set_len
      ~list_tmp:"__lst" ~len:3
  in
  let boxed_int =
    Blorp.Core_codegen_prepare.boxed_storage_value
      ~reg:(Blorp.Codegen_types.create_registry ())
      (cint 7)
  in
  let construct_append =
    render_bridge (fun ctx ->
        Blorp.Core_emit_blorp_prepared_list.render_construct_append
          ~emit_boxed:Blorp.Core_emit.emit_boxed_storage ctx ~list_tmp:"__lst"
          ~owned:false boxed_int)
  in
  let construct_append_owned =
    render_bridge (fun ctx ->
        Blorp.Core_emit_blorp_prepared_list.render_construct_append
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
    "({ blorp_List* __list_store_0 = (blorp_List*)xs; long __list_store_idx_0 \
     = 1L; Small __list_elem_0 = next; if (__list_store_0 && \
     __list_store_0->storage_mode == BLORP_LIST_STORAGE_INLINE && \
     __list_store_0->elem_size == (int16_t)sizeof(Small)) { \
     blorp_list_set_raw_copy(__list_store_0, __list_store_idx_0, \
     &__list_elem_0); } else { blorp_list_set_raw((blorp_List*)__list_store_0, \
     __list_store_idx_0, (void*)blorp_box_struct(&__list_elem_0, \
     sizeof(Small))); } })"
    inline_struct_store;
  Alcotest.(check string)
    "pointer swap bridge output"
    "({ blorp_List* __list_swap_0 = (blorp_List*)xs; long __list_swap_i_0 = \
     1L; long __list_swap_j_0 = 2L; if (__builtin_expect(__list_swap_0 && \
     __list_swap_i_0 != __list_swap_j_0, 1)) { void* __list_swap_tmp_0 = \
     blorp_list_get(__list_swap_0, __list_swap_i_0); \
     blorp_list_set_raw(__list_swap_0, __list_swap_i_0, \
     blorp_list_get(__list_swap_0, __list_swap_j_0)); \
     blorp_list_set_raw(__list_swap_0, __list_swap_j_0, __list_swap_tmp_0); } \
     })"
    pointer_swap;
  Alcotest.(check string)
    "inline bits swap bridge output"
    "({ blorp_List* __list_swap_0 = (blorp_List*)xs; long __list_swap_i_0 = \
     1L; long __list_swap_j_0 = 2L; if (__builtin_expect(__list_swap_0 && \
     __list_swap_i_0 != __list_swap_j_0, 1)) { char* __list_swap_base_0 = \
     (char*)__list_swap_0->data; uintptr_t __list_swap_bits_0 = 0; \
     memcpy(&__list_swap_bits_0, __list_swap_base_0 + __list_swap_i_0 * 8, 8); \
     memcpy(__list_swap_base_0 + __list_swap_i_0 * 8, __list_swap_base_0 + \
     __list_swap_j_0 * 8, 8); memcpy(__list_swap_base_0 + __list_swap_j_0 * 8, \
     &__list_swap_bits_0, 8); } })"
    inline_bits_swap;
  Alcotest.(check string)
    "inline struct swap bridge output"
    "({ blorp_List* __list_swap_0 = (blorp_List*)xs; long __list_swap_i_0 = \
     1L; long __list_swap_j_0 = 2L; if (__builtin_expect(__list_swap_0 && \
     __list_swap_i_0 != __list_swap_j_0, 1)) { if (__list_swap_0->storage_mode \
     == BLORP_LIST_STORAGE_INLINE) { char* __list_swap_base_0 = \
     (char*)__list_swap_0->data; size_t __list_swap_size_0 = \
     (size_t)__list_swap_0->elem_size; void* __list_swap_a_0 = \
     __list_swap_base_0 + __list_swap_i_0 * __list_swap_size_0; void* \
     __list_swap_b_0 = __list_swap_base_0 + __list_swap_j_0 * \
     __list_swap_size_0; unsigned char \
     __list_swap_bytes_0[__list_swap_size_0]; memcpy(__list_swap_bytes_0, \
     __list_swap_a_0, __list_swap_size_0); memcpy(__list_swap_a_0, \
     __list_swap_b_0, __list_swap_size_0); memcpy(__list_swap_b_0, \
     __list_swap_bytes_0, __list_swap_size_0); } else { void* \
     __list_swap_tmp_0 = blorp_list_get(__list_swap_0, __list_swap_i_0); \
     blorp_list_set_raw(__list_swap_0, __list_swap_i_0, \
     blorp_list_get(__list_swap_0, __list_swap_j_0)); \
     blorp_list_set_raw(__list_swap_0, __list_swap_j_0, __list_swap_tmp_0); } \
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
    "inline struct unbox get bridge output"
    "({ blorp_List* __lg_list_0 = (blorp_List*)xs; long __lg_idx_0 = 1L; Small \
     __lg_out_0; if (__builtin_expect(!__lg_list_0 || __lg_idx_0 < 0 || \
     __lg_idx_0 >= __lg_list_0->len, 0)) { memset(&__lg_out_0, 0, \
     sizeof(Small)); } else if (__lg_list_0->storage_mode == \
     BLORP_LIST_STORAGE_INLINE && __lg_list_0->elem_size == \
     (int16_t)sizeof(Small)) { memcpy(&__lg_out_0, (char*)__lg_list_0->data + \
     __lg_idx_0 * sizeof(Small), sizeof(Small)); } else { void* __lg_raw_1 = \
     blorp_list_get(__lg_list_0, __lg_idx_0); if (!__lg_raw_1) { \
     memset(&__lg_out_0, 0, sizeof(Small)); } else { __lg_out_0 = \
     blorp_unbox_struct(__lg_raw_1, Small); } } __lg_out_0; })"
    inline_struct_unbox_get;
  Alcotest.(check string)
    "list pointer alloc bridge output" "blorp_list_new(4L)" pointer_alloc;
  Alcotest.(check string)
    "list inline alloc bridge output" "blorp_list_new_inline(4L, 8)"
    inline_alloc;
  Alcotest.(check string)
    "list inline struct alloc bridge output"
    "blorp_list_new_inline(4L, sizeof(Small))" inline_struct_alloc;
  Alcotest.(check string)
    "list pointer storage mode bridge output" "BLORP_LIST_STORAGE_POINTER"
    pointer_storage_mode;
  Alcotest.(check string)
    "list pointer elem size bridge output" "sizeof(void*)" pointer_elem_size;
  Alcotest.(check string)
    "list inline storage mode bridge output" "BLORP_LIST_STORAGE_INLINE"
    inline_storage_mode;
  Alcotest.(check string)
    "list inline elem size bridge output" "8" inline_elem_size;
  Alcotest.(check string)
    "list inline struct storage mode bridge output" "BLORP_LIST_STORAGE_INLINE"
    inline_struct_storage_mode;
  Alcotest.(check string)
    "list inline struct elem size bridge output" "sizeof(Small)"
    inline_struct_elem_size;
  Alcotest.(check string)
    "list unmanaged release arg bridge output" "NULL" unmanaged_release_arg;
  Alcotest.(check string)
    "list managed release arg bridge output" "blorp_elem_release_fn"
    managed_release_arg;
  Alcotest.(check string)
    "list release alloc bridge output"
    "({ blorp_List* __lst = blorp_list_new(4L); \
     blorp_list_init_elem_release(__lst, blorp_elem_release_fn); __lst; })"
    release_alloc;
  Alcotest.(check string)
    "list alloc-for-layout bridge output" "blorp_list_new_inline(4L, 8)"
    alloc_for_layout_c;
  Alcotest.(check string)
    "list alloc-for-type with release bridge output"
    "({ blorp_List* __lst_0 = blorp_list_new(4L); \
     blorp_list_init_elem_release(__lst_0, blorp_elem_release_fn); __lst_0; })"
    alloc_for_type_with_release_c;
  Alcotest.(check string)
    "empty list alloc-for-type with release bridge output"
    "({ blorp_List* __lst_0 = blorp_list_new(0); \
     blorp_list_init_elem_release(__lst_0, blorp_elem_release_fn); __lst_0; })"
    empty_alloc_for_type_with_release_c;
  Alcotest.(check string)
    "list reuse alloc bridge output" "blorp_list_reuse_alloc(xs, 4L)"
    reuse_alloc_c;
  Alcotest.(check string)
    "list reuse alloc with release bridge output"
    "({ blorp_List* __lst_0 = blorp_list_reuse_alloc(strings, 4L); \
     blorp_list_init_elem_release(__lst_0, blorp_elem_release_fn); __lst_0; })"
    reuse_alloc_with_release_c;
  Alcotest.(check string)
    "list retain-for noop bridge output" "((void)0)" retain_for_noop_c;
  Alcotest.(check string)
    "list retain-for bridge output"
    "blorp_list_retain_for((blorp_List*)strings, (void*)({ blorp_String* \
     __box_0 = value; (void*)__box_0; }))"
    retain_for_c;
  Alcotest.(check string)
    "list construct name bridge output" "__lst_0" construct_name;
  Alcotest.(check string)
    "list construct wrapper bridge output"
    "({ blorp_List* __lst_0 = blorp_list_new(2); __lst_0 = \
     blorp_list_append(__lst_0, value); __lst_0; })"
    construct;
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

let test_prepared_dict_bridge_emits_expected_c () =
  let ty_small = Ast.TyNamed ("Small", []) in
  let ty_uint128 = Ast.TyNamed ("UInt128", []) in
  let ty_dict = Ast.TyNamed ("Dict", [ ty_string; ty_int ]) in
  let option_ty payload = Ast.TyNamed ("Option", [ payload ]) in
  let reg = Blorp.Codegen_types.create_registry () in
  Hashtbl.replace reg.value_records "Small" ();
  let stack_option_abi label ty =
    match Blorp.Core_layout_type.generated_stack_option_get_abi ~reg ty with
    | Some abi -> abi
    | None -> Alcotest.fail (label ^ " should have generated stack Option ABI")
  in
  let value_record_get_c =
    emit_bridge (fun ctx ->
        Blorp.Core_emit_blorp_prepared_dict.emit_stack_option_get
          ~emit_expr:Blorp.Core_emit.emit_expr
          ~emit_boxed:Blorp.Core_emit.emit_expr ctx
          (stack_option_abi "Small" (option_ty ty_small))
          (cvar "dict" ty_dict) (cvar "key" ty_string)
          ~key_release_policy:Blorp.Core_emit_blorp_prepared_dict.KeepKey)
  in
  let uint128_release_get_c =
    emit_bridge (fun ctx ->
        Blorp.Core_emit_blorp_prepared_dict.emit_stack_option_get
          ~emit_expr:Blorp.Core_emit.emit_expr
          ~emit_boxed:Blorp.Core_emit.emit_expr ctx
          (stack_option_abi "UInt128" (option_ty ty_uint128))
          (cvar "dict" ty_dict) (cvar "key" ty_string)
          ~key_release_policy:Blorp.Core_emit_blorp_prepared_dict.ReleaseKey)
  in
  let iter_pair_binding_c =
    Blorp.Core_emit_blorp_prepared_dict.render_iter_pair_binding ~entry:"entry"
      ~dict:"__dict_iter_0" ~slot:"__dslot_0"
  in
  let emitted_iter_pair_binding_c =
    emit_bridge (fun ctx ->
        Blorp.Core_emit_blorp_prepared_dict.emit_iter_pair_binding ctx
          ~entry:"entry" ~dict:"__dict_iter_0" ~slot:"__dslot_0")
  in
  let emitted_iter_source_binding_c =
    emit_bridge (fun ctx ->
        Blorp.Core_emit_blorp_prepared_dict.emit_iter_source_binding
          ~emit_expr:Blorp.Core_emit.emit_expr ctx ~dict:"__dict_iter_0"
          (cvar "items" ty_dict))
  in
  let emitted_iter_loop_open_c =
    emit_bridge (fun ctx ->
        Blorp.Core_emit_blorp_prepared_dict.emit_iter_loop_open ctx
          ~index:"__di_0" ~dict:"__dict_iter_0")
  in
  let emitted_iter_slot_binding_c =
    emit_bridge (fun ctx ->
        Blorp.Core_emit_blorp_prepared_dict.emit_iter_slot_binding ctx
          ~slot:"__dslot_0" ~dict:"__dict_iter_0" ~index:"__di_0")
  in
  let emitted_iter_deleted_slot_guard_c =
    emit_bridge (fun ctx ->
        Blorp.Core_emit_blorp_prepared_dict.emit_iter_deleted_slot_guard ctx
          ~slot:"__dslot_0")
  in
  let emitted_iter_key_binding_c =
    emit_bridge (fun ctx ->
        Blorp.Core_emit_blorp_prepared_dict.emit_iter_key_binding ctx
          ~key_c_type:"long" ~binding:"key" ~dict:"__dict_iter_0"
          ~slot:"__dslot_0")
  in
  Alcotest.(check string)
    "dict stack Option value-record get bridge output"
    "({ blorp_Dict* __gso_dict_0 = (blorp_Dict*)dict; void* __gso_key_0 = key; \
     void* __gso_raw_0 = NULL; bool __gso_found_0 = \
     blorp_dict_get_raw(__gso_dict_0, __gso_key_0, &__gso_raw_0); \
     blorp_StackOption_Small __gso_result_0; if (__gso_found_0) { \
     __gso_result_0 = ((blorp_StackOption_Small){ .tag = BLORP_TAG_SOME, \
     .value = blorp_unbox_struct(__gso_raw_0, Small) }); } else { \
     __gso_result_0 = ((blorp_StackOption_Small){ .tag = BLORP_TAG_NONE, \
     .value = {0} }); } __gso_result_0; })"
    value_record_get_c;
  Alcotest.(check string)
    "dict stack Option UInt128 release-key get bridge output"
    "({ blorp_Dict* __gso_dict_0 = (blorp_Dict*)dict; void* __gso_key_0 = key; \
     void* __gso_raw_0 = NULL; bool __gso_found_0 = \
     blorp_dict_get_raw(__gso_dict_0, __gso_key_0, &__gso_raw_0); \
     blorp_StackOption_UInt128 __gso_result_0; if (__gso_found_0) { \
     __gso_result_0 = ((blorp_StackOption_UInt128){ .tag = BLORP_TAG_SOME, \
     .value = blorp_unbox_uint128(__gso_raw_0) }); } else { __gso_result_0 = \
     ((blorp_StackOption_UInt128){ .tag = BLORP_TAG_NONE, .value = 0 }); } \
     blorp_release(__gso_key_0); __gso_result_0; })"
    uint128_release_get_c;
  Alcotest.(check string)
    "dict iter pair binding bridge output"
    "blorp_Tuple* entry = blorp_tuple_new(2, __dict_iter_0->keys[__dslot_0], \
     __dict_iter_0->values[__dslot_0]);"
    iter_pair_binding_c;
  Alcotest.(check string)
    "dict emitted iter pair binding bridge output"
    "blorp_Tuple* entry = blorp_tuple_new(2, __dict_iter_0->keys[__dslot_0], \
     __dict_iter_0->values[__dslot_0]);\n"
    emitted_iter_pair_binding_c;
  Alcotest.(check string)
    "dict emitted iter source binding bridge output"
    "blorp_Dict* __dict_iter_0 = (blorp_Dict*)items;\n"
    emitted_iter_source_binding_c;
  Alcotest.(check string)
    "dict emitted iter loop open bridge output"
    "for (long __di_0 = 0; __di_0 < __dict_iter_0->order_len; __di_0++) {\n"
    emitted_iter_loop_open_c;
  Alcotest.(check string)
    "dict emitted iter slot binding bridge output"
    "long __dslot_0 = __dict_iter_0->order[__di_0];\n"
    emitted_iter_slot_binding_c;
  Alcotest.(check string)
    "dict emitted iter deleted-slot guard bridge output"
    "if (__dslot_0 < 0) continue;\n" emitted_iter_deleted_slot_guard_c;
  Alcotest.(check string)
    "dict emitted iter key binding bridge output"
    "long key = (long)__dict_iter_0->keys[__dslot_0];\n"
    emitted_iter_key_binding_c

let test_prepared_set_bridge_emits_expected_c () =
  let ty_set = Ast.TyNamed ("Set", [ ty_int ]) in
  let emitted_iter_source_binding_c =
    emit_bridge (fun ctx ->
        Blorp.Core_emit_blorp_prepared_set.emit_iter_source_binding
          ~emit_expr:Blorp.Core_emit.emit_expr ctx ~set:"__set_iter_0"
          (cvar "items" ty_set))
  in
  let emitted_iter_retain_c =
    emit_bridge (fun ctx ->
        Blorp.Core_emit_blorp_prepared_set.emit_iter_retain ctx
          ~set:"__set_iter_0")
  in
  let emitted_iter_loop_open_c =
    emit_bridge (fun ctx ->
        Blorp.Core_emit_blorp_prepared_set.emit_iter_loop_open ctx
          ~entry:"__set_entry_0" ~set:"__set_iter_0")
  in
  let iter_entry_key_c =
    Blorp.Core_emit_blorp_prepared_set.render_iter_entry_key
      ~entry:"__set_entry_0"
  in
  let emitted_iter_release_c =
    emit_bridge (fun ctx ->
        Blorp.Core_emit_blorp_prepared_set.emit_iter_release ctx
          ~set:"__set_iter_0")
  in
  Alcotest.(check string)
    "set emitted iter source binding bridge output"
    "blorp_Set* __set_iter_0 = (blorp_Set*)items;\n"
    emitted_iter_source_binding_c;
  Alcotest.(check string)
    "set emitted iter retain bridge output" "blorp_retain(__set_iter_0);\n"
    emitted_iter_retain_c;
  Alcotest.(check string)
    "set emitted iter loop open bridge output"
    "for (blorp_SetEntry* __set_entry_0 = __set_iter_0->first; __set_entry_0 \
     != NULL; __set_entry_0 = __set_entry_0->next_order) {\n"
    emitted_iter_loop_open_c;
  Alcotest.(check string)
    "set iter entry key bridge output" "__set_entry_0->key" iter_entry_key_c;
  Alcotest.(check string)
    "set emitted iter release bridge output" "blorp_release(__set_iter_0);\n"
    emitted_iter_release_c

let test_prepared_tuple_bridge_emits_expected_c () =
  let reg = Blorp.Codegen_types.create_registry () in
  let boxed_int =
    Blorp.Core_codegen_prepare.boxed_storage_value ~reg (cint 7)
  in
  let ty_tuple_int = Ast.TyTuple [ ty_int ] in
  let tuple_args_c =
    emit_bridge (fun ctx ->
        let args =
          Blorp.Core_emit_blorp_prepared_tuple.render_tuple_args
            ~emit_boxed:Blorp.Core_emit.emit_boxed_storage ctx [ boxed_int ]
        in
        Blorp.Core_emit_context.emit ctx args)
  in
  let tuple_name_c =
    Blorp.Core_emit_blorp_prepared_tuple.render_tuple_name "0"
  in
  let tuple_arg_c =
    Blorp.Core_emit_blorp_prepared_tuple.render_tuple_arg "value"
  in
  let tuple_construct_c =
    emit_bridge (fun ctx ->
        Blorp.Core_emit_blorp_prepared_tuple.emit_tuple_construct ctx ~arity:"1"
          ~args:", value")
  in
  let tuple_retain_c =
    Blorp.Core_emit_blorp_prepared_tuple.render_tuple_retain_elem
      ~tuple_tmp:"__tup_0" ~index:0
  in
  let tuple_construct_with_rc_c =
    Blorp.Core_emit_blorp_prepared_tuple.render_tuple_construct_with_rc
      ~tuple_tmp:"__tup_0" ~arity:"1" ~args:", value"
      ~retain_statements:tuple_retain_c ~release_mask:1
  in
  let tuple_field_element_c =
    Blorp.Core_emit_blorp_prepared_tuple.render_tuple_field_element
      ~tuple_tmp:"__tup_0" ~field:"0"
  in
  let tuple_field_access_c =
    Blorp.Core_emit_blorp_prepared_tuple.render_tuple_field_access
      ~tuple_tmp:"__tup_0" ~source:"tuple"
      ~read:"(long)((blorp_Tuple*)__tup_0)->elem[0]"
  in
  let tuple_no_rc_c =
    emit_bridge (fun ctx ->
        Blorp.Core_emit_blorp_prepared_tuple.emit_construct
          ~emit_boxed:Blorp.Core_emit.emit_boxed_storage ctx
          {
            Core.tc_elems = [ boxed_int ];
            tc_release_mask = 0;
            tc_retain_mask = 0;
          })
  in
  let tuple_field_c =
    emit_bridge (fun ctx ->
        Blorp.Core_emit_blorp_prepared_tuple.emit_field_access
          ~emit_expr:Blorp.Core_emit.emit_expr
          ~render_read:(fun element -> Printf.sprintf "(long)%s" element)
          ctx
          (cvar "tuple" ty_tuple_int)
          "0")
  in
  Alcotest.(check string)
    "tuple rendered args bridge output"
    ", ({ long __box_0 = 7L; (void*)(long)(__box_0); })" tuple_args_c;
  Alcotest.(check string) "tuple name bridge output" "__tup_0" tuple_name_c;
  Alcotest.(check string) "tuple arg bridge output" ", value" tuple_arg_c;
  Alcotest.(check string)
    "tuple construct bridge output" "blorp_tuple_new(1, value)"
    tuple_construct_c;
  Alcotest.(check string)
    "tuple retain bridge output"
    "if (__tup_0->elem[0]) blorp_retain(__tup_0->elem[0]);" tuple_retain_c;
  Alcotest.(check string)
    "tuple construct with rc bridge output"
    "({ blorp_Tuple* __tup_0 = blorp_tuple_new(1, value); if \
     (__tup_0->elem[0]) blorp_retain(__tup_0->elem[0]); \
     blorp_tuple_set_rc(__tup_0, 1UL); __tup_0; })"
    tuple_construct_with_rc_c;
  Alcotest.(check string)
    "tuple field element bridge output" "((blorp_Tuple*)__tup_0)->elem[0]"
    tuple_field_element_c;
  Alcotest.(check string)
    "tuple field access bridge output"
    "({ void* __tup_0 = (void*)tuple; (long)((blorp_Tuple*)__tup_0)->elem[0]; \
     })"
    tuple_field_access_c;
  Alcotest.(check string)
    "tuple construct without rc bridge output"
    "blorp_tuple_new(1, ({ long __box_0 = 7L; (void*)(long)(__box_0); }))"
    tuple_no_rc_c;
  Alcotest.(check string)
    "tuple emitted field access bridge output"
    "({ void* __tup_0 = (void*)tuple; (long)((blorp_Tuple*)__tup_0)->elem[0]; \
     })"
    tuple_field_c

let test_prepared_tensor_bridge_emits_expected_c () =
  let ty_small = Ast.TyNamed ("Small", []) in
  let ty_int128 = Ast.TyNamed ("Int128", []) in
  let ty_uint128 = Ast.TyNamed ("UInt128", []) in
  let option_ty payload = Ast.TyNamed ("Option", [ payload ]) in
  let reg = Blorp.Codegen_types.create_registry () in
  Hashtbl.replace reg.value_records "Small" ();
  let stack_option_abi label ty =
    match Blorp.Core_layout_type.generated_stack_option_get_abi ~reg ty with
    | Some abi -> abi
    | None -> Alcotest.fail (label ^ " should have generated stack Option ABI")
  in
  let borrowed_boxed_string =
    Blorp.Core_codegen_prepare.boxed_storage_value ~reg (cvar "boxed" ty_string)
  in
  let owned_boxed_string =
    Blorp.Core_codegen_prepare.boxed_storage_value ~reg
      (core (Core.CBox (cvar "boxed" ty_string, ty_string)) ty_string)
  in
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
  let unchecked_pointer_get_c =
    emit_bridge (fun ctx ->
        Blorp.Core_emit_blorp_prepared_tensor.emit_get_unchecked
          ~emit_expr:Blorp.Core_emit.emit_expr ctx (cvar "out" ty_float)
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
  let checked_inline_struct_get_c =
    emit_bridge (fun ctx ->
        Blorp.Core_emit_blorp_prepared_tensor.emit_inline_struct_get_checked
          ~emit_expr:Blorp.Core_emit.emit_expr ctx
          (cvar "values" ty_tensor_float)
          (cvar "idx" ty_int) ~struct_ty:"Small")
  in
  let checked_inline_struct_matrix_get_c =
    emit_bridge (fun ctx ->
        Blorp.Core_emit_blorp_prepared_tensor
        .emit_inline_struct_matrix_get_checked
          ~emit_expr:Blorp.Core_emit.emit_expr ctx
          (cvar "values" ty_tensor_float)
          (cvar "row" ty_int) (cvar "col" ty_int) ~struct_ty:"Small")
  in
  let stack_option_value_record_get_c =
    emit_bridge (fun ctx ->
        Blorp.Core_emit_blorp_prepared_tensor.emit_stack_option_vector_get
          ~emit_expr:Blorp.Core_emit.emit_expr ctx
          (stack_option_abi "Small" (option_ty ty_small))
          (cvar "values" ty_tensor_float)
          (cvar "idx" ty_int))
  in
  let stack_option_int128_get_c =
    emit_bridge (fun ctx ->
        Blorp.Core_emit_blorp_prepared_tensor.emit_stack_option_vector_get
          ~emit_expr:Blorp.Core_emit.emit_expr ctx
          (stack_option_abi "Int128" (option_ty ty_int128))
          (cvar "values" ty_tensor_float)
          (cvar "idx" ty_int))
  in
  let stack_option_matrix_long_get_c =
    emit_bridge (fun ctx ->
        Blorp.Core_emit_blorp_prepared_tensor.emit_stack_option_matrix_get
          ~emit_expr:Blorp.Core_emit.emit_expr ctx
          (stack_option_abi "Range" (option_ty (Ast.TyRange ty_int)))
          (cvar "values" ty_tensor_float)
          (cvar "row" ty_int) (cvar "col" ty_int))
  in
  let stack_option_matrix_uint128_get_c =
    emit_bridge (fun ctx ->
        Blorp.Core_emit_blorp_prepared_tensor.emit_stack_option_matrix_get
          ~emit_expr:Blorp.Core_emit.emit_expr ctx
          (stack_option_abi "UInt128" (option_ty ty_uint128))
          (cvar "values" ty_tensor_float)
          (cvar "row" ty_int) (cvar "col" ty_int))
  in
  let inline_struct_element_decl_c =
    emit_bridge (fun ctx ->
        Blorp.Core_emit_blorp_prepared_tensor.emit_inline_struct_element_decl
          ctx ~var_c:"item" ~tensor_c:"values" ~index_c:"idx" ~struct_ty:"Small")
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
  let literal_name_c =
    Blorp.Core_emit_blorp_prepared_tensor.render_literal_name "0"
  in
  let literal_construct_c =
    Blorp.Core_emit_blorp_prepared_tensor.render_literal_construct
      ~tensor_tmp:"__ten_0" ~alloc_call:"blorp_vector_new_f64(2)"
      ~statements:[ "blorp_vector_write_f64(__ten_0, 0, value);" ]
  in
  let f64_storage_mode, f64_elem_size =
    Blorp.Core_emit_blorp_prepared_tensor.runtime_storage_args
      (Core.tensor_raw_scalar_storage ~elem_ty:ty_float
         Core.TensorFloat64Elements)
  in
  let inline_struct_storage_mode, inline_struct_elem_size =
    Blorp.Core_emit_blorp_prepared_tensor.runtime_storage_args
      (Core.tensor_inline_struct_storage ~elem_ty:ty_small "Small")
  in
  let boxed_storage_mode, boxed_elem_size =
    Blorp.Core_emit_blorp_prepared_tensor.runtime_storage_args
      (Core.tensor_boxed_storage ~elem_ty:ty_string ())
  in
  let f64_callback_encoding =
    Blorp.Core_emit_blorp_prepared_tensor.callback_result_encoding_arg
      (Core.tensor_raw_scalar_storage ~elem_ty:ty_float
         Core.TensorFloat64Elements)
  in
  let f32_callback_encoding =
    Blorp.Core_emit_blorp_prepared_tensor.callback_result_encoding_arg
      (Core.tensor_raw_scalar_storage ~elem_ty:ty_float
         Core.TensorFloat32Elements)
  in
  let inline_struct_callback_encoding =
    Blorp.Core_emit_blorp_prepared_tensor.callback_result_encoding_arg
      (Core.tensor_inline_struct_storage ~elem_ty:ty_small "Small")
  in
  let boxed_callback_encoding =
    Blorp.Core_emit_blorp_prepared_tensor.callback_result_encoding_arg
      (Core.tensor_boxed_storage ~elem_ty:ty_string ())
  in
  let literal_init_release_c =
    Blorp.Core_emit_blorp_prepared_tensor.render_literal_init_elem_release
      ~tensor_tmp:"vec"
  in
  let literal_f64_write_c =
    render_bridge (fun ctx ->
        Blorp.Core_emit_blorp_prepared_tensor.render_literal_f64_write
          ~emit_expr:Blorp.Core_emit.emit_expr ctx ~tensor_tmp:"vec" ~index:2
          (core (Core.CLit (Ast.LitFloat 2.5)) ty_float))
  in
  let literal_i64_write_c =
    render_bridge (fun ctx ->
        Blorp.Core_emit_blorp_prepared_tensor.render_literal_i64_write
          ~emit_expr:Blorp.Core_emit.emit_expr ctx ~tensor_tmp:"vec" ~index:1
          (cint 42))
  in
  let literal_word_write_c =
    render_bridge (fun ctx ->
        Blorp.Core_emit_blorp_prepared_tensor.render_literal_word_write
          ~emit_expr:Blorp.Core_emit.emit_expr ctx ~tensor_tmp:"vec" ~index:0
          (cint 7))
  in
  let literal_packed_write_c =
    render_bridge (fun ctx ->
        Blorp.Core_emit_blorp_prepared_tensor.render_literal_packed_write
          ~emit_expr:Blorp.Core_emit.emit_expr ctx ~tensor_tmp:"vec" ~index:3
          (cint 1))
  in
  let literal_inline_struct_write_c =
    render_bridge (fun ctx ->
        Blorp.Core_emit_blorp_prepared_tensor.render_literal_inline_struct_write
          ~emit_expr:Blorp.Core_emit.emit_expr ctx ~tensor_tmp:"vec" ~index:4
          ~struct_ty:"Small" (cvar "point" ty_small))
  in
  let literal_boxed_write_c =
    Blorp.Core_emit_blorp_prepared_tensor.render_literal_boxed_write_rendered
      ~tensor_tmp:"vec" ~index:5 ~value_arg:"boxed"
  in
  let literal_boxed_owned_write_c =
    render_bridge (fun ctx ->
        Blorp.Core_emit_blorp_prepared_tensor.render_literal_boxed_owned_write
          ~emit_boxed:Blorp.Core_emit.emit_boxed_storage ctx ~tensor_tmp:"vec"
          ~index:6 owned_boxed_string)
  in
  let literal_boxed_borrowed_write_c =
    render_bridge (fun ctx ->
        Blorp.Core_emit_blorp_prepared_tensor
        .render_literal_boxed_borrowed_write
          ~emit_boxed:Blorp.Core_emit.emit_boxed_storage ctx ~tensor_tmp:"vec"
          ~index:7 borrowed_boxed_string)
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
    "tensor unchecked pointer get bridge output"
    "((blorp_Vector*)values)->data[1L]" unchecked_pointer_get_c;
  Alcotest.(check string)
    "tensor inline struct get bridge output"
    "({ blorp_Vector* __tgu_vec_0 = (blorp_Vector*)values; long __tgu_idx_0 = \
     1L; Small __tgu_out_0; if (__builtin_expect(__tgu_vec_0->storage_mode == \
     BLORP_VECTOR_STORAGE_INLINE && __tgu_vec_0->elem_size == sizeof(Small), \
     1)) { memcpy(&__tgu_out_0, (char*)__tgu_vec_0->data + __tgu_idx_0 * \
     sizeof(Small), sizeof(Small)); } else { void* __tgu_raw_0 = \
     __tgu_vec_0->data[__tgu_idx_0]; __tgu_out_0 = \
     blorp_unbox_struct(__tgu_raw_0, Small); } __tgu_out_0; })"
    inline_struct_get_c;
  Alcotest.(check string)
    "tensor checked inline struct get bridge output"
    "({ blorp_Vector* __tg_vec_0 = (blorp_Vector*)values; long __tg_idx_0 = \
     idx; Small __tg_out_0 = {0}; if (__builtin_expect(__tg_vec_0 && \
     __tg_idx_0 >= 0 && __tg_idx_0 < __tg_vec_0->len, 1)) { if \
     (__builtin_expect(__tg_vec_0->storage_mode == BLORP_VECTOR_STORAGE_INLINE \
     && __tg_vec_0->elem_size == sizeof(Small), 1)) { memcpy(&__tg_out_0, \
     (char*)__tg_vec_0->data + __tg_idx_0 * sizeof(Small), sizeof(Small)); } \
     else { void* __tg_raw_0 = __tg_vec_0->data[__tg_idx_0]; __tg_out_0 = \
     blorp_unbox_struct(__tg_raw_0, Small); } } __tg_out_0; })"
    checked_inline_struct_get_c;
  Alcotest.(check string)
    "tensor checked inline struct matrix get bridge output"
    "({ blorp_Vector* __tgm_vec_0 = (blorp_Vector*)values; long __tgm_row_0 = \
     row; long __tgm_col_0 = col; long __tgm_cols_0 = (__tgm_vec_0 && \
     __tgm_vec_0->len > 0) ? __tgm_vec_0->capacity / __tgm_vec_0->len : 0; \
     long __tgm_idx_0 = __tgm_row_0 * __tgm_cols_0 + __tgm_col_0; Small \
     __tgm_out_0 = {0}; if (__builtin_expect(__tgm_vec_0 && __tgm_row_0 >= 0 \
     && __tgm_col_0 >= 0 && __tgm_idx_0 >= 0 && __tgm_row_0 < __tgm_vec_0->len \
     && __tgm_col_0 < __tgm_cols_0 && __tgm_idx_0 < __tgm_vec_0->capacity, 1)) \
     { if (__builtin_expect(__tgm_vec_0->storage_mode == \
     BLORP_VECTOR_STORAGE_INLINE && __tgm_vec_0->elem_size == sizeof(Small), \
     1)) { memcpy(&__tgm_out_0, (char*)__tgm_vec_0->data + __tgm_idx_0 * \
     sizeof(Small), sizeof(Small)); } else { void* __tgm_raw_0 = \
     __tgm_vec_0->data[__tgm_idx_0]; __tgm_out_0 = \
     blorp_unbox_struct(__tgm_raw_0, Small); } } __tgm_out_0; })"
    checked_inline_struct_matrix_get_c;
  Alcotest.(check string)
    "tensor stack Option value-record get bridge output"
    "({ blorp_Vector* __gso_vec_0 = (blorp_Vector*)values; long __gso_idx_0 = \
     idx; blorp_StackOption_Small __gso_result_0; if (!__gso_vec_0 || \
     __gso_idx_0 < 0 || __gso_idx_0 >= __gso_vec_0->len) { __gso_result_0 = \
     ((blorp_StackOption_Small){ .tag = BLORP_TAG_NONE, .value = {0} }); } \
     else { if (__gso_vec_0->storage_mode == BLORP_VECTOR_STORAGE_INLINE) { \
     Small __gso_payload_0; memcpy(&__gso_payload_0, (char*)__gso_vec_0->data \
     + __gso_idx_0 * __gso_vec_0->elem_size, sizeof(Small)); __gso_result_0 = \
     ((blorp_StackOption_Small){ .tag = BLORP_TAG_SOME, .value = \
     __gso_payload_0 }); } else { void* __gso_raw_0 = \
     __gso_vec_0->data[__gso_idx_0]; __gso_result_0 = \
     ((blorp_StackOption_Small){ .tag = BLORP_TAG_SOME, .value = \
     blorp_unbox_struct(__gso_raw_0, Small) }); } } __gso_result_0; })"
    stack_option_value_record_get_c;
  Alcotest.(check string)
    "tensor stack Option Int128 get bridge output"
    "({ blorp_Vector* __gso_vec_0 = (blorp_Vector*)values; long __gso_idx_0 = \
     idx; blorp_StackOption_Int128 __gso_result_0; if (!__gso_vec_0 || \
     __gso_idx_0 < 0 || __gso_idx_0 >= __gso_vec_0->len) { __gso_result_0 = \
     ((blorp_StackOption_Int128){ .tag = BLORP_TAG_NONE, .value = 0 }); } else \
     { void* __gso_raw_0 = __gso_vec_0->data[__gso_idx_0]; __gso_result_0 = \
     ((blorp_StackOption_Int128){ .tag = BLORP_TAG_SOME, .value = \
     blorp_unbox_int128(__gso_raw_0) }); } __gso_result_0; })"
    stack_option_int128_get_c;
  Alcotest.(check string)
    "tensor stack Option matrix long get bridge output"
    "({ blorp_Vector* __gso_mat_0 = (blorp_Vector*)values; long __gso_row_0 = \
     row; long __gso_col_0 = col; long __gso_cols_0 = (__gso_mat_0 && \
     __gso_mat_0->len > 0) ? __gso_mat_0->capacity / __gso_mat_0->len : 0; \
     long __gso_idx_0 = __gso_row_0 * __gso_cols_0 + __gso_col_0; \
     blorp_StackOption_Range __gso_result_0; if (!__gso_mat_0 || __gso_row_0 < \
     0 || __gso_col_0 < 0 || __gso_idx_0 < 0 || __gso_idx_0 >= \
     __gso_mat_0->capacity) { __gso_result_0 = ((blorp_StackOption_Range){ \
     .tag = BLORP_TAG_NONE, .value = 0 }); } else { __gso_result_0 = \
     ((blorp_StackOption_Range){ .tag = BLORP_TAG_SOME, .value = \
     blorp_vector_read_i64(__gso_mat_0, __gso_idx_0) }); } __gso_result_0; })"
    stack_option_matrix_long_get_c;
  Alcotest.(check string)
    "tensor stack Option matrix UInt128 get bridge output"
    "({ blorp_Vector* __gso_mat_0 = (blorp_Vector*)values; long __gso_row_0 = \
     row; long __gso_col_0 = col; long __gso_cols_0 = (__gso_mat_0 && \
     __gso_mat_0->len > 0) ? __gso_mat_0->capacity / __gso_mat_0->len : 0; \
     long __gso_idx_0 = __gso_row_0 * __gso_cols_0 + __gso_col_0; \
     blorp_StackOption_UInt128 __gso_result_0; if (!__gso_mat_0 || __gso_row_0 \
     < 0 || __gso_col_0 < 0 || __gso_idx_0 < 0 || __gso_idx_0 >= \
     __gso_mat_0->capacity) { __gso_result_0 = ((blorp_StackOption_UInt128){ \
     .tag = BLORP_TAG_NONE, .value = 0 }); } else { void* __gso_raw_0 = \
     __gso_mat_0->data[__gso_idx_0]; __gso_result_0 = \
     ((blorp_StackOption_UInt128){ .tag = BLORP_TAG_SOME, .value = \
     blorp_unbox_uint128(__gso_raw_0) }); } __gso_result_0; })"
    stack_option_matrix_uint128_get_c;
  Alcotest.(check string)
    "tensor inline struct element decl bridge output"
    "Small item = ({ blorp_Vector* __tgu_vec_0 = (blorp_Vector*)values; long \
     __tgu_idx_0 = idx; Small __tgu_out_0; if \
     (__builtin_expect(__tgu_vec_0->storage_mode == \
     BLORP_VECTOR_STORAGE_INLINE && __tgu_vec_0->elem_size == sizeof(Small), \
     1)) { memcpy(&__tgu_out_0, (char*)__tgu_vec_0->data + __tgu_idx_0 * \
     sizeof(Small), sizeof(Small)); } else { void* __tgu_raw_0 = \
     __tgu_vec_0->data[__tgu_idx_0]; __tgu_out_0 = \
     blorp_unbox_struct(__tgu_raw_0, Small); } __tgu_out_0; });\n"
    inline_struct_element_decl_c;
  Alcotest.(check string)
    "tensor f64 raw get bridge output"
    "({ blorp_Vector* __tensor_raw_vec_0 = (blorp_Vector*)values; long \
     __tensor_raw_idx_0 = 1L; double __tensor_raw_0; memcpy(&__tensor_raw_0, \
     (char*)__tensor_raw_vec_0->data + __tensor_raw_idx_0 * sizeof(double), \
     sizeof(double)); __tensor_raw_0; })"
    f64_raw_get_c;
  Alcotest.(check string)
    "tensor f32 raw get bridge output"
    "({ blorp_Vector* __tensor_raw_vec_0 = (blorp_Vector*)values; long \
     __tensor_raw_idx_0 = 1L; float __tensor_raw_0; memcpy(&__tensor_raw_0, \
     (char*)__tensor_raw_vec_0->data + __tensor_raw_idx_0 * sizeof(float), \
     sizeof(float)); __tensor_raw_0; })"
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
    "tensor f64 storage mode bridge output" "BLORP_VECTOR_STORAGE_F64"
    f64_storage_mode;
  Alcotest.(check string)
    "tensor f64 elem size bridge output" "sizeof(double)" f64_elem_size;
  Alcotest.(check string)
    "tensor inline struct storage mode bridge output"
    "BLORP_VECTOR_STORAGE_INLINE" inline_struct_storage_mode;
  Alcotest.(check string)
    "tensor inline struct elem size bridge output" "sizeof(Small)"
    inline_struct_elem_size;
  Alcotest.(check string)
    "tensor boxed storage mode bridge output" "BLORP_VECTOR_STORAGE_POINTER"
    boxed_storage_mode;
  Alcotest.(check string)
    "tensor boxed elem size bridge output" "sizeof(void*)" boxed_elem_size;
  Alcotest.(check string)
    "tensor f64 callback encoding bridge output"
    "BLORP_VECTOR_CALLBACK_BOXED_FLOAT" f64_callback_encoding;
  Alcotest.(check string)
    "tensor f32 callback encoding bridge output"
    "BLORP_VECTOR_CALLBACK_BOXED_FLOAT32" f32_callback_encoding;
  Alcotest.(check string)
    "tensor inline struct callback encoding bridge output"
    "BLORP_VECTOR_CALLBACK_BOXED_STRUCT" inline_struct_callback_encoding;
  Alcotest.(check string)
    "tensor boxed callback encoding bridge output" "BLORP_VECTOR_CALLBACK_BITS"
    boxed_callback_encoding;
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
    "tensor literal name bridge output" "__ten_0" literal_name_c;
  Alcotest.(check string)
    "tensor literal construct bridge output"
    "({ blorp_Vector* __ten_0 = blorp_vector_new_f64(2); \
     blorp_vector_write_f64(__ten_0, 0, value); __ten_0; })"
    literal_construct_c;
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
    "tensor literal boxed owned write bridge output"
    "{ void* __ten_boxed_0 = ({ blorp_String* __box_1 = boxed; (void*)__box_1; \
     }); vec->data[6] = __ten_boxed_0; }"
    literal_boxed_owned_write_c;
  Alcotest.(check string)
    "tensor literal boxed borrowed write bridge output"
    "{ void* __ten_boxed_0 = ({ blorp_String* __box_1 = boxed; (void*)__box_1; \
     }); vec->data[7] = __ten_boxed_0; if (__ten_boxed_0) \
     blorp_retain(__ten_boxed_0); }"
    literal_boxed_borrowed_write_c

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
    ( "core_emit_blorp_backend",
      [
        Alcotest.test_case "routes first slice through backend boundary" `Quick
          test_core_emit_routes_first_slice_through_blorp_backend_boundary;
        Alcotest.test_case "backend boundary emits expected C" `Quick
          test_blorp_backend_boundary_emits_expected_c;
      ] );
    ( "codegen_intrinsic_renderer",
      [
        Alcotest.test_case "compiles and runs smoke" `Slow
          test_codegen_intrinsic_renderer_compiles_and_runs_smoke;
        Alcotest.test_case "manifest matches checked-in templates" `Slow
          (fun () ->
            test_renderer_manifest_matches_checked_in_templates
              intrinsic_renderer);
        Alcotest.test_case "compiler/blorp TestSuites pass" `Slow
          test_compiler_blorp_test_suites;
      ] );
    ( "codegen_prepared_string_renderer",
      [
        Alcotest.test_case "manifest matches checked-in templates" `Slow
          (fun () ->
            test_renderer_manifest_matches_checked_in_templates
              prepared_string_renderer);
        Alcotest.test_case "prepared string bridge emits expected C" `Quick
          test_prepared_string_bridge_emits_expected_c;
      ] );
    ( "codegen_prepared_list_renderer",
      [
        Alcotest.test_case "manifest matches checked-in templates" `Slow
          (fun () ->
            test_renderer_manifest_matches_checked_in_templates
              prepared_list_renderer);
        Alcotest.test_case "prepared list bridge emits expected C" `Quick
          test_prepared_list_bridge_emits_expected_c;
      ] );
    ( "codegen_prepared_dict_renderer",
      [
        Alcotest.test_case "manifest matches checked-in templates" `Slow
          (fun () ->
            test_renderer_manifest_matches_checked_in_templates
              prepared_dict_renderer);
        Alcotest.test_case "prepared dict bridge emits expected C" `Quick
          test_prepared_dict_bridge_emits_expected_c;
      ] );
    ( "codegen_prepared_set_renderer",
      [
        Alcotest.test_case "manifest matches checked-in templates" `Slow
          (fun () ->
            test_renderer_manifest_matches_checked_in_templates
              prepared_set_renderer);
        Alcotest.test_case "prepared set bridge emits expected C" `Quick
          test_prepared_set_bridge_emits_expected_c;
      ] );
    ( "codegen_prepared_tuple_renderer",
      [
        Alcotest.test_case "manifest matches checked-in templates" `Slow
          (fun () ->
            test_renderer_manifest_matches_checked_in_templates
              prepared_tuple_renderer);
        Alcotest.test_case "prepared tuple bridge emits expected C" `Quick
          test_prepared_tuple_bridge_emits_expected_c;
      ] );
    ( "codegen_prepared_tensor_renderer",
      [
        Alcotest.test_case "manifest matches checked-in templates" `Slow
          (fun () ->
            test_renderer_manifest_matches_checked_in_templates
              prepared_tensor_renderer);
        Alcotest.test_case "prepared tensor bridge emits expected C" `Quick
          test_prepared_tensor_bridge_emits_expected_c;
      ] );
  ]
