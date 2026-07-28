(** Tests for Core_trait_resolve. *)

open Blorp.Ast
open Blorp.Core
module P = Blorp.Core_trait_resolve

let loc =
  { line = 1; column = 1; end_line = 1; end_column = 1; loc_file = None }

let ty_void = TyNamed ("Void", [])
let ty_string = TyNamed ("String", [])
let ty_string_slice = TyNamed ("StringSlice", [])
let ty_widget = TyNamed ("Widget", [])
let mk desc ty = { desc; ty; loc }
let cvoid = mk CVoid ty_void
let cvar name ty = mk (CVar (Var.named name)) ty

let call_unknown name args ret_ty =
  let fn_ty =
    TyFunc
      {
        params = List.map (fun arg -> arg.ty) args;
        return = ret_ty;
        is_pure = true;
      }
  in
  mk (CCall (CKUnknown, cvar name fn_ty, args)) ret_ty

let call_selected_direct selected_id name args ret_ty =
  let fn_ty =
    TyFunc
      {
        params = List.map (fun arg -> arg.ty) args;
        return = ret_ty;
        is_pure = true;
      }
  in
  mk (CCall (CKSelectedDirect selected_id, cvar name fn_ty, args)) ret_ty

let call_builtin name args ret_ty =
  let fn_ty =
    TyFunc
      {
        params = List.map (fun arg -> arg.ty) args;
        return = ret_ty;
        is_pure = true;
      }
  in
  mk (CCall (CKBuiltin name, cvar name fn_ty, args)) ret_ty

let func ?(name = "main") ?(params = []) ?(ret = ty_string) body =
  {
    cf_name = name;
    cf_module = None;
    cf_type_params = [];
    cf_params = params;
    cf_return_ty = ret;
    cf_body = Some body;
    cf_is_pure = true;
    cf_kind = CFUser;
    cf_def_id = 0;
  }

let decl desc = { cd_desc = desc; cd_loc = loc; cd_doc = None }

let widget_stringable_trait =
  decl
    (CDTrait
       {
         ct_name = "Stringable";
         ct_type_params = [];
         ct_supertraits = [];
         ct_methods =
           [
             {
               ctm_name = "to_string";
               ctm_params =
                 [
                   {
                     cp_name = Var.named "value";
                     cp_ty = ty_widget;
                     cp_loc = loc;
                   };
                 ];
               ctm_return_ty = Some ty_string;
               ctm_is_pure = true;
             };
           ];
       })

let widget_stringable_impl =
  let method_body =
    mk
      (CLit (LitString ("widget", { sf_multiline = false; sf_raw = false })))
      ty_string
  in
  let method_func =
    func ~name:"to_string"
      ~params:
        [ { cp_name = Var.named "value"; cp_ty = ty_widget; cp_loc = loc } ]
      method_body
  in
  decl
    (CDImpl
       {
         ci_trait = "Stringable";
         ci_for_type = ty_widget;
         ci_methods = [ method_func ];
       })

let string_slice_stringable_impl =
  let method_body =
    mk
      (CLit (LitString ("slice", { sf_multiline = false; sf_raw = false })))
      ty_string
  in
  let method_func =
    func ~name:"to_string"
      ~params:
        [
          {
            cp_name = Var.named "value";
            cp_ty = ty_string_slice;
            cp_loc = loc;
          };
        ]
      method_body
  in
  decl
    (CDImpl
       {
         ci_trait = "Stringable";
         ci_for_type = ty_string_slice;
         ci_methods = [ method_func ];
       })

let single_body = function
  | [ _; _; { cd_desc = CDFunc { cf_body = Some body; _ }; _ } ] -> body
  | _ -> Alcotest.fail "expected trait, impl, and one function"

let test_selected_direct_trait_method_rewrites_to_impl () =
  let value = cvar "value" ty_widget in
  let body = call_selected_direct 42 "to_string" [ value ] ty_string in
  let main =
    decl
      (CDFunc
         (func
            ~params:
              [
                { cp_name = Var.named "value"; cp_ty = ty_widget; cp_loc = loc };
              ]
            body))
  in
  let resolved =
    P.resolve_program [ widget_stringable_trait; widget_stringable_impl; main ]
  in
  match (single_body resolved).desc with
  | CCall (CKUnknown, { desc = CVar v; _ }, _) ->
      Alcotest.(check string)
        "selected direct trait method resolves to impl"
        "Stringable_to_string_Widget" v.vname
  | CCall (CKSelectedDirect _, _, _) ->
      Alcotest.fail "selected direct trait method was not rewritten"
  | _ -> Alcotest.fail "expected rewritten trait method call"

let test_to_string_builtin_rewrites_to_string_slice_impl () =
  let value = cvar "value" ty_string_slice in
  let body = call_builtin "blorp_to_string" [ value ] ty_string in
  let main =
    decl
      (CDFunc
         (func
            ~params:
              [
                {
                  cp_name = Var.named "value";
                  cp_ty = ty_string_slice;
                  cp_loc = loc;
                };
              ]
            body))
  in
  let resolved =
    P.resolve_program
      [ widget_stringable_trait; string_slice_stringable_impl; main ]
  in
  match (single_body resolved).desc with
  | CCall (CKUnknown, { desc = CVar v; _ }, _) ->
      Alcotest.(check string)
        "StringSlice to_string resolves to its ordinary impl"
        "Stringable_to_string_StringSlice" v.vname
  | CCall (CKBuiltin _, _, _) ->
      Alcotest.fail "StringSlice impl was left as a builtin call"
  | _ -> Alcotest.fail "expected rewritten StringSlice to_string call"

let test_resource_scope_binding_shadows_trait_method_body_only () =
  let value = cvar "value" ty_widget in
  let acquired = call_unknown "to_string" [ value ] ty_string in
  let body_call = call_unknown "to_string" [ value ] ty_string in
  let fn_ty =
    TyFunc { params = [ ty_widget ]; return = ty_string; is_pure = true }
  in
  let scoped =
    mk
      (CResourceScope
         {
           rs_var = Var.named "to_string";
           rs_ty = fn_ty;
           rs_acquire = acquired;
           rs_body = body_call;
           rs_cleanup = cvoid;
         })
      ty_string
  in
  let main =
    decl
      (CDFunc
         (func
            ~params:
              [
                { cp_name = Var.named "value"; cp_ty = ty_widget; cp_loc = loc };
              ]
            scoped))
  in
  let resolved =
    P.resolve_program [ widget_stringable_trait; widget_stringable_impl; main ]
  in
  match (single_body resolved).desc with
  | CResourceScope { rs_acquire; rs_body; _ } -> (
      (match rs_acquire.desc with
      | CCall (CKUnknown, { desc = CVar v; _ }, _) ->
          Alcotest.(check string)
            "acquisition resolves outside resource binding"
            "Stringable_to_string_Widget" v.vname
      | _ -> Alcotest.fail "expected acquisition trait method rewrite");
      match rs_body.desc with
      | CCall (CKUnknown, { desc = CVar v; _ }, _) ->
          Alcotest.(check string)
            "body keeps shadowing resource binding" "to_string" v.vname
      | CCall (CKUnknown, _, _) -> Alcotest.fail "expected body callee variable"
      | _ ->
          Alcotest.fail
            "body trait method was rewritten through resource binding")
  | _ -> Alcotest.fail "expected resource scope"

let test_dispatch_type_facts_preserve_nominal_identity () =
  let nominal_t = TyNamed ("T", []) in
  let reg = Blorp.Codegen_types.create_registry () in
  Alcotest.(check (option string))
    "nominal T has an impl key" (Some "T")
    (Blorp.Codegen_types.type_key_for_impl nominal_t);
  Alcotest.(check bool)
    "nominal T is concrete" false
    (Blorp.Codegen_types.has_type_vars nominal_t);
  Alcotest.(check (option string))
    "nominal T has a dispatch head" (Some "T")
    (P.first_arg_type_head [ cvar "value" nominal_t ]);
  Alcotest.(check (option string))
    "type parameter has no dispatch head" None
    (P.first_arg_type_head [ cvar "value" (TyVar "T") ]);
  Alcotest.(check string)
    "nominal T keeps its nominal C representation" "T*"
    (Blorp.Codegen_types.type_to_c ~reg nominal_t);
  Alcotest.(check string)
    "type parameter remains erased at the C boundary" "void*"
    (Blorp.Codegen_types.type_to_c ~reg (TyVar "T"))

let suite =
  [
    ( "selected_direct",
      [
        Alcotest.test_case "trait_method_rewrites_to_impl" `Quick
          test_selected_direct_trait_method_rewrites_to_impl;
        Alcotest.test_case "to_string_builtin_rewrites_to_string_slice_impl"
          `Quick test_to_string_builtin_rewrites_to_string_slice_impl;
        Alcotest.test_case "dispatch facts preserve nominal identity" `Quick
          test_dispatch_type_facts_preserve_nominal_identity;
      ] );
    ( "resource_scope",
      [
        Alcotest.test_case "binding_shadows_trait_method_body_only" `Quick
          test_resource_scope_binding_shadows_trait_method_body_only;
      ] );
  ]
