(** Tests for Core_flatten module/name rewriting. *)

open Blorp
open Blorp.Ast
open Blorp.Core

let loc =
  { line = 1; column = 1; end_line = 1; end_column = 1; loc_file = None }

let ty_float = TyNamed ("Float", [])
let ty_int = TyNamed ("Int", [])
let ty_void = TyNamed ("Void", [])
let field field_name field_type = { field_name; field_type; field_loc = loc }

let record_decl ?(builtin = false) record_name fields =
  {
    record_name;
    record_type_params = [];
    record_fields = fields;
    record_is_value = true;
    record_is_builtin = builtin;
  }

let decl desc = { cd_desc = desc; cd_loc = loc; cd_doc = None }
let mk desc ty = { desc; ty; loc }
let cvar name ty = { desc = CVar (Var.named name); ty; loc }
let cvoid = mk CVoid ty_void

let resource_scope name ty acquire body cleanup =
  mk
    (CResourceScope
       {
         rs_var = Var.named name;
         rs_ty = ty;
         rs_acquire = acquire;
         rs_body = body;
         rs_cleanup = cleanup;
       })
    body.ty

let test_std_non_abi_types_are_module_owned () =
  let vec3_ty = TyNamed ("Vec3", []) in
  let aabb3_ty = TyNamed ("AABB3", []) in
  let vec3 =
    record_decl "Vec3"
      [ field "x" ty_float; field "y" ty_float; field "z" ty_float ]
  in
  let aabb3 =
    record_decl "AABB3" [ field "min" vec3_ty; field "max" vec3_ty ]
  in
  let fn =
    {
      cf_name = "aabb3";
      cf_module = None;
      cf_type_params = [];
      cf_params =
        [
          { cp_name = Var.named "min"; cp_ty = vec3_ty; cp_loc = loc };
          { cp_name = Var.named "max"; cp_ty = vec3_ty; cp_loc = loc };
        ];
      cf_return_ty = aabb3_ty;
      cf_body =
        Some
          {
            desc =
              CRecord
                [ ("min", cvar "min" vec3_ty); ("max", cvar "max" vec3_ty) ];
            ty = aabb3_ty;
            loc;
          };
      cf_is_pure = true;
      cf_kind = CFUser;
      cf_def_id = 1;
    }
  in
  let rewritten =
    Core_flatten.prefix_module_names "std/geometry"
      [ decl (CDRecord vec3); decl (CDRecord aabb3); decl (CDFunc fn) ]
  in
  match rewritten with
  | { cd_desc = CDRecord vec3'; _ }
    :: { cd_desc = CDRecord aabb3'; _ }
    :: { cd_desc = CDFunc fn'; _ }
    :: _ -> (
      Alcotest.(check string)
        "Vec3 is module-owned" "std_geometry__Vec3" vec3'.record_name;
      Alcotest.(check string)
        "AABB3 is module-owned" "std_geometry__AABB3" aabb3'.record_name;
      Alcotest.(check bool)
        "function return type is module-owned" true
        (Types.types_equal fn'.cf_return_ty
           (TyNamed ("std_geometry__AABB3", [])));
      match fn'.cf_body with
      | Some body ->
          Alcotest.(check bool)
            "record literal type is module-owned" true
            (Types.types_equal body.ty (TyNamed ("std_geometry__AABB3", [])))
      | None -> Alcotest.fail "expected rewritten function body")
  | _ -> Alcotest.fail "unexpected rewritten declaration shape"

let test_std_global_abi_type_stays_stable () =
  let list_decl =
    record_decl ~builtin:true "List" [ field "opaque" (TyNamed ("Ptr", [])) ]
  in
  let rewritten =
    Core_flatten.prefix_module_names "std/list" [ decl (CDRecord list_decl) ]
  in
  match rewritten with
  | [ { cd_desc = CDRecord r; _ } ] ->
      Alcotest.(check string) "List stays ABI-stable" "List" r.record_name
  | _ -> Alcotest.fail "unexpected rewritten declaration shape"

let test_global_assignment_targets_are_module_owned () =
  let global =
    {
      cv_name = Var.named "call_count";
      cv_module = None;
      cv_ty = ty_int;
      cv_init = mk (CLit (LitInt 0L)) ty_int;
      cv_is_mutable = true;
      cv_is_const = false;
      cv_def_id = 1;
    }
  in
  let assign =
    mk (CAssign (Var.named "call_count", cvar "call_count" ty_int)) ty_void
  in
  let fn =
    {
      cf_name = "bump";
      cf_module = None;
      cf_type_params = [];
      cf_params = [];
      cf_return_ty = ty_void;
      cf_body = Some assign;
      cf_is_pure = false;
      cf_kind = CFUser;
      cf_def_id = 2;
    }
  in
  let rewritten =
    Core_flatten.prefix_module_names "tests/example"
      [ decl (CDVar global); decl (CDFunc fn) ]
  in
  match rewritten with
  | { cd_desc = CDVar global'; _ } :: { cd_desc = CDFunc fn'; _ } :: _ -> (
      Alcotest.(check string)
        "global decl is module-owned" "tests_example__call_count"
        global'.cv_name.vname;
      match fn'.cf_body with
      | Some { desc = CAssign (target, { desc = CVar rhs; _ }); _ } ->
          Alcotest.(check string)
            "assignment target is module-owned" "tests_example__call_count"
            target.vname;
          Alcotest.(check string)
            "assignment rhs is module-owned" "tests_example__call_count"
            rhs.vname
      | _ -> Alcotest.fail "expected rewritten assignment body")
  | _ -> Alcotest.fail "unexpected rewritten declaration shape"

let test_local_assignment_target_stays_local () =
  let local_binding =
    {
      bind_var = Var.named "call_count";
      bind_mut = true;
      bind_ty = ty_int;
      bind_rhs = mk (CLit (LitInt 0L)) ty_int;
    }
  in
  let body =
    mk
      (CLet
         ( local_binding,
           mk
             (CAssign (Var.named "call_count", cvar "call_count" ty_int))
             ty_void ))
      ty_void
  in
  let fn =
    {
      cf_name = "bump";
      cf_module = None;
      cf_type_params = [];
      cf_params = [];
      cf_return_ty = ty_void;
      cf_body = Some body;
      cf_is_pure = false;
      cf_kind = CFUser;
      cf_def_id = 3;
    }
  in
  let rewritten =
    Core_flatten.prefix_module_names "tests/example" [ decl (CDFunc fn) ]
  in
  match rewritten with
  | [ { cd_desc = CDFunc fn'; _ } ] -> (
      match fn'.cf_body with
      | Some
          {
            desc =
              CLet (_, { desc = CAssign (target, { desc = CVar rhs; _ }); _ });
            _;
          } ->
          Alcotest.(check string) "target stays local" "call_count" target.vname;
          Alcotest.(check string) "rhs stays local" "call_count" rhs.vname
      | _ -> Alcotest.fail "expected local assignment body")
  | _ -> Alcotest.fail "unexpected rewritten declaration shape"

let test_resource_scope_binding_stays_local () =
  let handle_ty = TyNamed ("Handle", []) in
  let handle_record = record_decl "Handle" [] in
  let global =
    {
      cv_name = Var.named "handle";
      cv_module = None;
      cv_ty = handle_ty;
      cv_init = cvar "make_handle" handle_ty;
      cv_is_mutable = false;
      cv_is_const = false;
      cv_def_id = 4;
    }
  in
  let body =
    resource_scope "handle" handle_ty (cvar "handle" handle_ty)
      (cvar "handle" handle_ty) cvoid
  in
  let fn =
    {
      cf_name = "use_handle";
      cf_module = None;
      cf_type_params = [];
      cf_params = [];
      cf_return_ty = handle_ty;
      cf_body = Some body;
      cf_is_pure = false;
      cf_kind = CFUser;
      cf_def_id = 5;
    }
  in
  let rewritten =
    Core_flatten.prefix_module_names "tests/example"
      [ decl (CDRecord handle_record); decl (CDVar global); decl (CDFunc fn) ]
  in
  match rewritten with
  | { cd_desc = CDRecord record'; _ }
    :: { cd_desc = CDVar global'; _ }
    :: { cd_desc = CDFunc fn'; _ }
    :: _ -> (
      Alcotest.(check string)
        "record type is module-owned" "tests_example__Handle"
        record'.record_name;
      Alcotest.(check string)
        "global value is module-owned" "tests_example__handle"
        global'.cv_name.vname;
      match fn'.cf_body with
      | Some
          {
            desc =
              CResourceScope
                {
                  rs_var;
                  rs_ty;
                  rs_acquire = { desc = CVar acquire; _ };
                  rs_body = { desc = CVar body_var; ty = body_ty; _ };
                  _;
                };
            _;
          } ->
          Alcotest.(check string)
            "scope binding stays local" "handle" rs_var.vname;
          Alcotest.(check bool)
            "resource type is module-owned" true
            (Types.types_equal rs_ty (TyNamed ("tests_example__Handle", [])));
          Alcotest.(check string)
            "acquisition reads global" "tests_example__handle" acquire.vname;
          Alcotest.(check string)
            "body reads scoped binding" "handle" body_var.vname;
          Alcotest.(check bool)
            "body type is module-owned" true
            (Types.types_equal body_ty (TyNamed ("tests_example__Handle", [])))
      | _ -> Alcotest.fail "expected resource scope body")
  | _ -> Alcotest.fail "unexpected rewritten declaration shape"

let suite =
  [
    ( "type_names",
      [
        Alcotest.test_case "std non-ABI types are module-owned" `Quick
          test_std_non_abi_types_are_module_owned;
        Alcotest.test_case "std global ABI type stays stable" `Quick
          test_std_global_abi_type_stays_stable;
      ] );
    ( "values",
      [
        Alcotest.test_case "global assignment targets are module-owned" `Quick
          test_global_assignment_targets_are_module_owned;
        Alcotest.test_case "local assignment target stays local" `Quick
          test_local_assignment_target_stays_local;
        Alcotest.test_case "resource scope binding stays local" `Quick
          test_resource_scope_binding_stays_local;
      ] );
  ]
