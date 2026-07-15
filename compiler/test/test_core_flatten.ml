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

let test_std_module_local_builtin_type_is_module_owned () =
  let session_ty = TyNamed ("TlsSession", []) in
  let session_decl =
    {
      type_name = "TlsSession";
      type_params = [];
      type_variants = [];
      type_is_enum = false;
      type_is_builtin = true;
      type_is_resource = true;
      type_resource_cleanup = None;
    }
  in
  let impl =
    { ci_trait = "Resource"; ci_for_type = session_ty; ci_methods = [] }
  in
  let rewritten =
    Core_flatten.prefix_module_names "std/net/tls"
      [ decl (CDType session_decl); decl (CDImpl impl) ]
  in
  match rewritten with
  | [ { cd_desc = CDType type_decl; _ }; { cd_desc = CDImpl impl'; _ } ] ->
      Alcotest.(check string)
        "builtin declaration is module-owned" "std_net_tls__TlsSession"
        type_decl.type_name;
      Alcotest.(check bool)
        "impl receiver matches module-owned type" true
        (Types.types_equal impl'.ci_for_type
           (TyNamed ("std_net_tls__TlsSession", [])))
  | _ -> Alcotest.fail "unexpected rewritten declaration shape"

let test_imported_function_signature_exposes_module_type_rewrite () =
  let rewrites = Core_flatten.create_imported_type_rewrites () in
  let duration = TyNamed ("Duration", []) in
  let function_decl =
    {
      func_name = Some "milliseconds";
      func_type_params = [];
      func_params =
        [
          {
            param_name = Some "value";
            param_pattern = None;
            param_type = Some ty_int;
            param_loc = loc;
          };
        ];
      func_return_type = Some duration;
      func_body = FuncNoBody;
      func_is_pure = true;
      func_is_tailrec = false;
      func_no_copy = false;
      func_debug_only = false;
      func_resource_result_ordinary = false;
      func_dim_constraints = [];
    }
  in
  Core_flatten.add_imported_signature_type_rewrites rewrites
    [ ("Duration", "std_units__Duration") ]
    { decl_desc = DFunc function_decl; decl_loc = loc; decl_doc = None };
  Alcotest.(check (option string))
    "signature return type uses owner identity"
    (Some "std_units__Duration")
    (Core_flatten.find_imported_type_rewrite rewrites "Duration")

let test_main_imported_result_type_rewrites_without_module_cache () =
  let send_attempt = TyNamed ("SendAttempt", []) in
  let send_attempt_decl =
    {
      type_name = "SendAttempt";
      type_params = [];
      type_variants = [];
      type_is_enum = false;
      type_is_builtin = false;
      type_is_resource = false;
      type_resource_cleanup = None;
    }
  in
  let try_send_attempt =
    {
      func_name = Some "try_send_attempt";
      func_type_params = [];
      func_params = [];
      func_return_type = Some send_attempt;
      func_body = FuncNoBody;
      func_is_pure = false;
      func_is_tailrec = false;
      func_no_copy = false;
      func_debug_only = false;
      func_resource_result_ordinary = false;
      func_dim_constraints = [];
    }
  in
  let main =
    {
      cf_name = "main";
      cf_module = None;
      cf_type_params = [];
      cf_params = [];
      cf_return_ty = send_attempt;
      cf_body = None;
      cf_is_pure = false;
      cf_kind = CFUser;
      cf_def_id = 1;
    }
  in
  let module_program =
    [
      { decl_desc = DType send_attempt_decl; decl_loc = loc; decl_doc = None };
      { decl_desc = DFunc try_send_attempt; decl_loc = loc; decl_doc = None };
    ]
  in
  let rewritten =
    Core_flatten.rewrite_main_imported_type_names_from_bindings
      ~main_import_bindings:
        [
          {
            Session.local_name = "try_send_attempt";
            module_path = "std/channel";
            original_name = Some "try_send_attempt";
          };
        ]
      ~module_programs:[ ("std/channel", module_program) ]
      [ decl (CDFunc main) ]
  in
  match rewritten with
  | [ { cd_desc = CDFunc rewritten_main; _ } ] ->
      Alcotest.(check bool)
        "inferred result type uses explicit module identity" true
        (Types.types_equal rewritten_main.cf_return_ty
           (TyNamed ("std_channel__SendAttempt", [])))
  | _ -> Alcotest.fail "unexpected rewritten declaration shape"

let test_module_imported_type_rewrites_without_module_cache () =
  let duration = TyNamed ("Duration", []) in
  let duration_decl =
    {
      type_name = "Duration";
      type_params = [];
      type_variants = [];
      type_is_enum = false;
      type_is_builtin = false;
      type_is_resource = false;
      type_resource_cleanup = None;
    }
  in
  let benchmark =
    {
      cf_name = "benchmark";
      cf_module = None;
      cf_type_params = [];
      cf_params = [];
      cf_return_ty = duration;
      cf_body = None;
      cf_is_pure = false;
      cf_kind = CFUser;
      cf_def_id = 2;
    }
  in
  let rewritten =
    Core_flatten.prefix_module_names
      ~import_bindings:
        [
          {
            Session.local_name = "Duration";
            module_path = "std/units";
            original_name = Some "Duration";
          };
        ]
      ~module_programs:
        [
          ( "std/units",
            [
              {
                decl_desc = DType duration_decl;
                decl_loc = loc;
                decl_doc = None;
              };
            ] );
        ]
      "benchmarks/support" [ decl (CDFunc benchmark) ]
  in
  match rewritten with
  | [ { cd_desc = CDFunc rewritten_benchmark; _ } ] ->
      Alcotest.(check bool)
        "module annotation uses explicit imported type identity" true
        (Types.types_equal rewritten_benchmark.cf_return_ty
           (TyNamed ("std_units__Duration", [])))
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

let import_binding ?original_name local_name module_path :
    Session.import_binding =
  { local_name; module_path; original_name }

let test_import_tables_build_from_explicit_bindings () =
  let main_imports =
    [
      import_binding ~original_name:"SourceValue" "Value" "pkg/value";
      import_binding "qualified" "pkg/qualified";
    ]
  in
  let module_bindings =
    [
      ( "pkg/consumer",
        [ import_binding ~original_name:"make" "create" "pkg/provider" ] );
      ("pkg/empty", []);
    ]
  in
  let main_table, module_tables =
    Core_flatten.build_import_tables_from_bindings
      ~main_import_bindings:main_imports module_bindings
  in
  Alcotest.(check (option (pair string string)))
    "main alias preserves original name"
    (Some ("pkg/value", "SourceValue"))
    (Hashtbl.find_opt main_table "Value");
  Alcotest.(check (option (pair string string)))
    "qualified import preserves empty original name"
    (Some ("pkg/qualified", ""))
    (Hashtbl.find_opt main_table "qualified");
  let consumer = Hashtbl.find_opt module_tables "pkg/consumer" in
  Alcotest.(check bool) "consumer table exists" true (Option.is_some consumer);
  Alcotest.(check bool) "empty table is omitted" false
    (Hashtbl.mem module_tables "pkg/empty");
  match consumer with
  | Some table ->
      Alcotest.(check (option (pair string string)))
        "module alias preserves owner"
        (Some ("pkg/provider", "make"))
        (Hashtbl.find_opt table "create")
  | None -> Alcotest.fail "expected consumer import table"

let suite =
  [
    ( "type_names",
      [
        Alcotest.test_case "std non-ABI types are module-owned" `Quick
          test_std_non_abi_types_are_module_owned;
        Alcotest.test_case "std global ABI type stays stable" `Quick
          test_std_global_abi_type_stays_stable;
        Alcotest.test_case "std module-local builtin type is module-owned"
          `Quick test_std_module_local_builtin_type_is_module_owned;
        Alcotest.test_case
          "imported function signature exposes module type rewrite" `Quick
          test_imported_function_signature_exposes_module_type_rewrite;
        Alcotest.test_case
          "main imported result type rewrites without module cache" `Quick
          test_main_imported_result_type_rewrites_without_module_cache;
        Alcotest.test_case
          "module imported type rewrites without module cache" `Quick
          test_module_imported_type_rewrites_without_module_cache;
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
    ( "imports",
      [
        Alcotest.test_case "build tables from explicit bindings" `Quick
          test_import_tables_build_from_explicit_bindings;
      ] );
  ]
