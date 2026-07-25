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
      ] );
  ]
