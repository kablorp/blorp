(** Tests for the legacy late-Core JSON producer used while bootstrapping the
    Blorp-owned compiler tail. *)

open Blorp
open Blorp.Ast
open Blorp.Core

let loc =
  { line = 1; column = 1; end_line = 1; end_column = 1; loc_file = None }

let project_global source_module =
  let ty = TyNamed ("Int", []) in
  let init = { desc = CLit (LitInt 1L); ty; loc } in
  let global =
    {
      cv_name = Var.named "answer";
      cv_module = source_module;
      cv_ty = ty;
      cv_init = init;
      cv_is_mutable = false;
      cv_is_const = true;
      cv_def_id = 7;
    }
  in
  let program = [ { cd_desc = CDVar global; cd_loc = loc; cd_doc = None } ] in
  let reg = Codegen_types.create_registry () in
  match Core_emit_blorp_c.program_json ~reg program with
  | Ok json -> Lsp_json.to_string json
  | Error error ->
      Alcotest.fail (Core_emit_blorp_c.unsupported_to_string error)

let test_global_projection_preserves_source_module () =
  let projected = project_global (Some "std/constants") in
  Alcotest.(check bool)
    "source module is explicit" true
    (Modules.contains projected {|"source_module":"std/constants"|})

let test_global_projection_preserves_absent_source_module () =
  let projected = project_global None in
  Alcotest.(check bool)
    "absent source module remains explicit" true
    (Modules.contains projected {|"source_module":null|})

let test_projection_accepts_scoped_closure_call_argument () =
  let string_ty = TyNamed ("String", []) in
  let closure_ty =
    TyFunc { params = [ string_ty ]; return = string_ty; is_pure = true }
  in
  let source_var = Var.named "source" in
  let borrowed_var = Var.named "borrowed" in
  let source = { desc = CVar source_var; ty = string_ty; loc } in
  let borrowed = { desc = CVar borrowed_var; ty = string_ty; loc } in
  let scoped_argument =
    {
      desc =
        CBorrowLet
          ( {
              borrow_var = borrowed_var;
              borrow_ty = string_ty;
              borrow_rhs = source;
            },
            borrowed );
      ty = string_ty;
      loc;
    }
  in
  let body =
    {
      desc =
        CCall
          ( CKClosure,
            { desc = CVar (Var.named "callback"); ty = closure_ty; loc },
            [ scoped_argument ] );
      ty = string_ty;
      loc;
    }
  in
  let func =
    {
      cf_name = "apply";
      cf_module = None;
      cf_type_params = [];
      cf_params =
        [
          { cp_name = Var.named "callback"; cp_ty = closure_ty; cp_loc = loc };
          { cp_name = source_var; cp_ty = string_ty; cp_loc = loc };
        ];
      cf_return_ty = string_ty;
      cf_body = Some body;
      cf_is_pure = true;
      cf_kind = CFUser;
      cf_def_id = 8;
    }
  in
  let program =
    [ { cd_desc = CDFunc func; cd_loc = loc; cd_doc = None } ]
  in
  let reg = Codegen_types.create_registry () in
  match Core_emit_blorp_c.program_json ~reg program with
  | Ok json ->
      Alcotest.(check bool)
        "scoped argument crosses the late-Core boundary" true
        (Modules.contains (Lsp_json.to_string json) {|"kind":"borrow_let"|})
  | Error error ->
      Alcotest.fail (Core_emit_blorp_c.unsupported_to_string error)

let test_projection_accepts_length_match_nested_in_literal_case () =
  let int_ty = TyNamed ("Int", []) in
  let string_ty = TyNamed ("String", []) in
  let list_ty = TyNamed ("List", [ int_ty ]) in
  let scrutinee_ty = TyTuple [ string_ty; list_ty ] in
  let scrutinee_var = Var.named "input" in
  let body =
    {
      desc =
        CMatch
          ( { desc = CVar scrutinee_var; ty = scrutinee_ty; loc },
            CTSwitchLit
              {
                ctl_scrut = AccTupleField (AccRoot, 0);
                ctl_cases =
                  [
                    ( LitString
                        ("items", { sf_multiline = false; sf_raw = false }),
                      CTSwitchLen
                        {
                          ctl_len_scrut = AccTupleField (AccRoot, 1);
                          ctl_len_cases =
                            [
                              ( 1,
                                CTLeaf
                                  {
                                    ct_bindings = [];
                                    ct_body =
                                      { desc = CLit (LitInt 1L); ty = int_ty; loc };
                                  } );
                            ];
                          ctl_len_geq = None;
                          ctl_len_default = Some CTFail;
                        } );
                  ];
                ctl_default =
                  CTLeaf
                    {
                      ct_bindings = [];
                      ct_body = { desc = CLit (LitInt 0L); ty = int_ty; loc };
                    };
              } );
      ty = int_ty;
      loc;
    }
  in
  let func =
    {
      cf_name = "classify";
      cf_module = None;
      cf_type_params = [];
      cf_params =
        [ { cp_name = scrutinee_var; cp_ty = scrutinee_ty; cp_loc = loc } ];
      cf_return_ty = int_ty;
      cf_body = Some body;
      cf_is_pure = true;
      cf_kind = CFUser;
      cf_def_id = 10;
    }
  in
  let program = [ { cd_desc = CDFunc func; cd_loc = loc; cd_doc = None } ] in
  let reg = Codegen_types.create_registry () in
  match Core_emit_blorp_c.program_json ~reg program with
  | Ok json ->
      Alcotest.(check bool)
        "literal case preserves nested length decision" true
        (Modules.contains
           (Lsp_json.to_string json)
           {|"kind":"length_match"|})
  | Error error ->
      Alcotest.fail (Core_emit_blorp_c.unsupported_to_string error)

let deferred_inline_struct_list_program ~layout_c_type ~layout_element_ty
    ~box_source_ty ~value_ty ~needs_release ~transfers_ownership =
  let point_list_ty = TyNamed ("List", [ layout_element_ty ]) in
  let point_var = Var.named "point" in
  let point_ref = { desc = CVar point_var; ty = value_ty; loc } in
  let layout =
    {
      lsl_slots = ListInlineStructStorage layout_c_type;
      lsl_elem_ty = Some layout_element_ty;
      lsl_value_layout = ListElementStackStruct layout_c_type;
      lsl_policy = StoragePolicyUnmanagedBits;
    }
  in
  let body =
    {
      desc =
        CListConstruct
          {
            lc_layout = layout;
            lc_elems =
              [
                {
                  bsv_box =
                    {
                      box_value = point_ref;
                      box_source_ty;
                      box_kind = BoxPointer;
                    };
                  bsv_needs_release = needs_release;
                  bsv_transfers_ownership = transfers_ownership;
                };
              ];
            lc_elem_needs_release = false;
          };
      ty = point_list_ty;
      loc;
    }
  in
  let point_decl =
    {
      record_name = "Point";
      record_type_params = [];
      record_fields = [];
      record_is_value = true;
      record_is_builtin = false;
    }
  in
  let make_points =
    {
      cf_name = "make_points";
      cf_module = None;
      cf_type_params = [];
      cf_params = [ { cp_name = point_var; cp_ty = value_ty; cp_loc = loc } ];
      cf_return_ty = point_list_ty;
      cf_body = Some body;
      cf_is_pure = true;
      cf_kind = CFUser;
      cf_def_id = 9;
    }
  in
  [
    { cd_desc = CDRecord point_decl; cd_loc = loc; cd_doc = None };
    { cd_desc = CDFunc make_points; cd_loc = loc; cd_doc = None };
  ]

let deferred_inline_struct_registry () =
  let reg = Codegen_types.create_registry () in
  Hashtbl.replace reg.value_records "Point" ();
  reg

let test_projection_accepts_deferred_inline_struct_list_reboxing () =
  let point_ty = TyNamed ("Point", []) in
  let program =
    deferred_inline_struct_list_program ~layout_c_type:"Point"
      ~layout_element_ty:point_ty
      ~box_source_ty:point_ty ~value_ty:point_ty ~needs_release:false
      ~transfers_ownership:false
  in
  let reg = deferred_inline_struct_registry () in
  match Core_emit_blorp_c.program_json ~reg program with
  | Ok json ->
      Alcotest.(check bool)
        "pointer box crosses the pre-prepare boundary" true
        (Modules.contains (Lsp_json.to_string json) {|"kind":"pointer"|})
  | Error error ->
      Alcotest.fail (Core_emit_blorp_c.unsupported_to_string error)

let test_projection_accepts_deferred_stack_option_list_reboxing () =
  let option_int_ty = TyNamed ("Option", [ TyNamed ("Int", []) ]) in
  let program =
    deferred_inline_struct_list_program
      ~layout_c_type:"blorp_StackOption_Int"
      ~layout_element_ty:option_int_ty ~box_source_ty:option_int_ty
      ~value_ty:option_int_ty ~needs_release:false ~transfers_ownership:false
  in
  let reg = deferred_inline_struct_registry () in
  match Core_emit_blorp_c.program_json ~reg program with
  | Ok json ->
      Alcotest.(check bool)
        "stack option pointer box crosses the pre-prepare boundary" true
        (Modules.contains (Lsp_json.to_string json) {|"kind":"pointer"|})
  | Error error ->
      Alcotest.fail (Core_emit_blorp_c.unsupported_to_string error)

let check_projection_rejects program expected =
  let reg = deferred_inline_struct_registry () in
  match Core_emit_blorp_c.program_json ~reg program with
  | Ok _ -> Alcotest.fail ("expected projection rejection: " ^ expected)
  | Error error ->
      Alcotest.(check bool)
        expected true
        (Modules.contains
           (Core_emit_blorp_c.unsupported_to_string error)
           expected)

let test_projection_rejects_deferred_inline_struct_type_mismatch () =
  let point_ty = TyNamed ("Point", []) in
  let string_ty = TyNamed ("String", []) in
  deferred_inline_struct_list_program ~layout_c_type:"Point"
    ~layout_element_ty:point_ty
    ~box_source_ty:string_ty ~value_ty:string_ty ~needs_release:false
    ~transfers_ownership:false
  |> fun program ->
  check_projection_rejects program
    "transitional inline-struct element/list type mismatch"

let test_projection_rejects_deferred_inline_struct_layout_name_mismatch () =
  let point_ty = TyNamed ("Point", []) in
  deferred_inline_struct_list_program ~layout_c_type:"Other"
    ~layout_element_ty:point_ty ~box_source_ty:point_ty ~value_ty:point_ty
    ~needs_release:false
    ~transfers_ownership:false
  |> fun program ->
  check_projection_rejects program
    "inline-struct list layout type Point does not match storage Other"

let test_projection_rejects_managed_deferred_inline_struct_element () =
  let point_ty = TyNamed ("Point", []) in
  deferred_inline_struct_list_program ~layout_c_type:"Point"
    ~layout_element_ty:point_ty
    ~box_source_ty:point_ty ~value_ty:point_ty ~needs_release:true
    ~transfers_ownership:false
  |> fun program ->
  check_projection_rejects program
    "managed transitional inline-struct element"

let test_projection_rejects_owned_deferred_inline_struct_element () =
  let point_ty = TyNamed ("Point", []) in
  deferred_inline_struct_list_program ~layout_c_type:"Point"
    ~layout_element_ty:point_ty
    ~box_source_ty:point_ty ~value_ty:point_ty ~needs_release:false
    ~transfers_ownership:true
  |> fun program ->
  check_projection_rejects program
    "owned transitional inline-struct element transfer"

let suite =
  [
    ( "projection",
      [
        Alcotest.test_case "global source module" `Quick
          test_global_projection_preserves_source_module;
        Alcotest.test_case "absent global source module" `Quick
          test_global_projection_preserves_absent_source_module;
        Alcotest.test_case "scoped closure-call argument" `Quick
          test_projection_accepts_scoped_closure_call_argument;
        Alcotest.test_case "length match nested in literal case" `Quick
          test_projection_accepts_length_match_nested_in_literal_case;
        Alcotest.test_case "deferred inline-struct list reboxing" `Quick
          test_projection_accepts_deferred_inline_struct_list_reboxing;
        Alcotest.test_case "deferred stack-option list reboxing" `Quick
          test_projection_accepts_deferred_stack_option_list_reboxing;
        Alcotest.test_case "deferred inline-struct list type mismatch" `Quick
          test_projection_rejects_deferred_inline_struct_type_mismatch;
        Alcotest.test_case "deferred inline-struct list layout name mismatch"
          `Quick
          test_projection_rejects_deferred_inline_struct_layout_name_mismatch;
        Alcotest.test_case "managed deferred inline-struct list element" `Quick
          test_projection_rejects_managed_deferred_inline_struct_element;
        Alcotest.test_case "owned deferred inline-struct list element" `Quick
          test_projection_rejects_owned_deferred_inline_struct_element;
      ] );
  ]
