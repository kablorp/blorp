(** Tests for Core_closure: first-class function value normalization. *)

open Blorp.Ast
open Blorp.Core

let loc =
  { line = 1; column = 1; end_line = 1; end_column = 1; loc_file = None }

let ty_int = TyNamed ("Int", [])
let ty_float = TyNamed ("Float", [])
let ty_string = TyNamed ("String", [])
let ty_bool = TyNamed ("Bool", [])
let ty_void = TyNamed ("Void", [])
let str_flags = { sf_multiline = false; sf_raw = false }
let mk d t = { desc = d; ty = t; loc }
let cvar n t = mk (CVar (Var.named n)) t
let cvar_def n def_id t =
  mk (CVar { (Var.named n) with vdef_id = Some def_id }) t

let cint n = mk (CLit (LitInt (Int64.of_int n))) ty_int
let cstr s = mk (CLit (LitString (s, str_flags))) ty_string
let fn_ty params return is_pure = TyFunc { params; return; is_pure }

let mk_func ?(is_pure = false) name params return body def_id : core_func =
  {
    cf_name = name;
    cf_module = None;
    cf_type_params = [];
    cf_params =
      List.map
        (fun (n, t) -> { cp_name = Var.named n; cp_ty = t; cp_loc = loc })
        params;
    cf_return_ty = return;
    cf_body = body;
    cf_is_pure = is_pure;
    cf_kind = CFUser;
    cf_def_id = def_id;
  }

let decl f = { cd_desc = CDFunc f; cd_loc = loc; cd_doc = None }

let find_func name prog =
  List.find_map
    (function
      | { cd_desc = CDFunc f; _ } when f.cf_name = name -> Some f | _ -> None)
    prog

let require_func name prog =
  match find_func name prog with
  | Some f -> f
  | None -> Alcotest.failf "missing function %s" name

let test_returned_function_ref_becomes_closure_create () =
  Blorp.Session.(
    with_current (create ()) (fun () ->
        let double_ty = fn_ty [ ty_int ] ty_int true in
        let double =
          mk_func ~is_pure:true "double"
            [ ("x", ty_int) ]
            ty_int
            (Some (cvar "x" ty_int))
            1
        in
        let get_doubler =
          mk_func "get_doubler" [] double_ty (Some (cvar "double" double_ty)) 2
        in
        let converted =
          Blorp.Core_closure.adapt_function_refs_program
            [ decl double; decl get_doubler ]
        in
        let get_doubler' = require_func "get_doubler" converted in
        match get_doubler'.cf_body with
        | Some { desc = CClosureCreate cc; _ } ->
            Alcotest.(check string) "eta closure name" "_blorp_eta_0" cc.cc_func;
            Alcotest.(check int) "no captures" 0 (List.length cc.cc_captures);
            Alcotest.(check bool)
              "eta function hoisted" true
              (Option.is_some (find_func "_blorp_eta_0" converted))
        | Some { desc = CVar v; _ } ->
            Alcotest.failf "raw function ref survived as CVar %s" v.vname
        | Some _ ->
            Alcotest.fail
              "expected returned function ref to become CClosureCreate"
        | None -> Alcotest.fail "missing get_doubler body"))

let test_let_body_function_ref_becomes_closure_create () =
  Blorp.Session.(
    with_current (create ()) (fun () ->
        let double_ty = fn_ty [ ty_int ] ty_int true in
        let unit_ty = TyNamed ("Void", []) in
        let double =
          mk_func ~is_pure:true "double"
            [ ("x", ty_int) ]
            ty_int
            (Some (cvar "x" ty_int))
            1
        in
        let body =
          mk
            (CLet
               ( {
                   bind_var = Var.named "_";
                   bind_mut = false;
                   bind_ty = unit_ty;
                   bind_rhs = mk CVoid unit_ty;
                 },
                 cvar "double" double_ty ))
            double_ty
        in
        let get_doubler = mk_func "get_doubler" [] double_ty (Some body) 2 in
        let converted =
          Blorp.Core_closure.adapt_function_refs_program
            [ decl double; decl get_doubler ]
        in
        let get_doubler' = require_func "get_doubler" converted in
        match get_doubler'.cf_body with
        | Some { desc = CLet (_, { desc = CClosureCreate _; _ }); _ } -> ()
        | Some { desc = CLet (_, { desc = CVar v; _ }); _ } ->
            Alcotest.failf "let body raw function ref survived as CVar %s"
              v.vname
        | Some _ ->
            Alcotest.fail
              "expected let body function ref to become CClosureCreate"
        | None -> Alcotest.fail "missing get_doubler body"))

let test_local_function_value_shadows_global_name () =
  Blorp.Session.(
    with_current (create ()) (fun () ->
        let local_ty = fn_ty [] ty_int true in
        let global_add =
          mk_func ~is_pure:true "add" [] ty_int (Some (cint 99)) 100
        in
        let local_lambda =
          mk
            (CLambda
               {
                 lam_params = [];
                 lam_return_ty = ty_int;
                 lam_body = cint 1;
                 lam_is_pure = true;
               })
            local_ty
        in
        let local_call =
          mk (CCall (CKClosure, cvar "add" local_ty, [])) ty_int
        in
        let body =
          mk
            (CLet
               ( {
                   bind_var = Var.named "add";
                   bind_mut = false;
                   bind_ty = local_ty;
                   bind_rhs = local_lambda;
                 },
                 local_call ))
            ty_int
        in
        let run = mk_func "run" [] ty_int (Some body) 101 in
        let adapted =
          Blorp.Core_closure.adapt_function_refs_program
            [ decl global_add; decl run ]
        in
        Alcotest.(check bool)
          "local function value did not create global eta adapter" false
          (Option.is_some (find_func "_blorp_eta_0" adapted));
        let run' = require_func "run" adapted in
        match run'.cf_body with
        | Some
            {
              desc =
                CLet
                  ( _,
                    {
                      desc = CCall (CKClosure, { desc = CVar callee; _ }, []);
                      _;
                    } );
              _;
            } ->
            Alcotest.(check string) "local callee preserved" "add" callee.vname
        | Some body ->
            Alcotest.failf
              "local function value was adapted as a global function ref:\n%s"
              (pp_to_string_indented body)
        | None -> Alcotest.fail "missing run body"))

let test_passthrough_builtin_function_ref_becomes_closure_create () =
  Blorp.Session.(
    with_current (create ()) (fun () ->
        let sqrt_ty = fn_ty [ ty_float ] ty_float true in
        let get_sqrt =
          mk_func "get_sqrt" [] sqrt_ty (Some (cvar "sqrt" sqrt_ty)) 102
        in
        let converted =
          Blorp.Core_closure.adapt_function_refs_program [ decl get_sqrt ]
        in
        let get_sqrt' = require_func "get_sqrt" converted in
        (match get_sqrt'.cf_body with
        | Some { desc = CClosureCreate cc; _ } ->
            Alcotest.(check string) "eta closure name" "_blorp_eta_0" cc.cc_func;
            Alcotest.(check int) "no captures" 0 (List.length cc.cc_captures)
        | Some { desc = CVar v; _ } ->
            Alcotest.failf "raw builtin function ref survived as CVar %s"
              v.vname
        | Some body ->
            Alcotest.failf
              "expected builtin function ref to become CClosureCreate:\n%s"
              (pp_to_string_indented body)
        | None -> Alcotest.fail "missing get_sqrt body");
        let eta = require_func "_blorp_eta_0" converted in
        match eta.cf_body with
        | Some
            {
              desc =
                CCall
                  ( CKBuiltin "sqrt",
                    { desc = CVar callee; _ },
                    [ { desc = CVar arg; _ } ] );
              _;
            } ->
            Alcotest.(check string) "callee name preserved" "sqrt" callee.vname;
            Alcotest.(check string)
              "eta arg passed through" "__eta_arg_0" arg.vname
        | Some body ->
            Alcotest.failf "eta adapter did not call builtin sqrt:\n%s"
              (pp_to_string_indented body)
        | None -> Alcotest.fail "missing eta body"))

let test_function_ref_def_id_collision_uses_name_identity () =
  Blorp.Session.(
    with_current (create ()) (fun () ->
        let ty_span = TyNamed ("CompilerSourceSpan", []) in
        let ty_json = TyNamed ("JsonValue", []) in
        let ty_action = TyNamed ("CliAction", []) in
        let span_to_json_ty = fn_ty [ ty_span ] ty_json true in
        let span_to_json =
          mk_func ~is_pure:true "parsed_source_span_to_json"
            [ ("span", ty_span) ]
            ty_json
            (Some (cvar "json" ty_json))
            77
        in
        let action_uses_auto_format =
          mk_func "action_uses_auto_format"
            [ ("action", ty_action) ]
            ty_bool
            (Some (cvar "flag" ty_bool))
            77
        in
        let get_span_to_json =
          mk_func "get_span_to_json" [] span_to_json_ty
            (Some (cvar_def "parsed_source_span_to_json" 77 span_to_json_ty))
            78
        in
        let converted =
          Blorp.Core_closure.adapt_function_refs_program
            [
              decl span_to_json;
              decl action_uses_auto_format;
              decl get_span_to_json;
            ]
        in
        let eta = require_func "_blorp_eta_0" converted in
        match eta.cf_body with
        | Some
            {
              desc =
                CCall
                  ( CKUser ("parsed_source_span_to_json", Some 77),
                    _,
                    [ { ty = arg_ty; _ } ] );
              ty = return_ty;
              _;
            } ->
            Alcotest.(check bool) "eta argument type preserved" true
              (Blorp.Types.types_equal arg_ty ty_span);
            Alcotest.(check bool) "eta return type preserved" true
              (Blorp.Types.types_equal return_ty ty_json)
        | Some body ->
            Alcotest.failf "eta adapter selected wrong target:\n%s"
              (pp_to_string_indented body)
        | None -> Alcotest.fail "missing eta body"))

let test_resource_scope_binding_shadows_global_function_ref () =
  Blorp.Session.(
    with_current (create ()) (fun () ->
        let resource_ty = fn_ty [ ty_int ] ty_int true in
        let resource =
          mk_func ~is_pure:true "resource"
            [ ("x", ty_int) ]
            ty_int
            (Some (cvar "x" ty_int))
            31
        in
        let acquire =
          mk
            (CClosureCreate
               {
                 cc_func = "_dummy_resource";
                 cc_def_id = 999;
                 cc_captures = [];
               })
            resource_ty
        in
        let scope =
          mk
            (CResourceScope
               {
                 rs_var = Var.named "resource";
                 rs_ty = resource_ty;
                 rs_acquire = acquire;
                 rs_body = cvar "resource" resource_ty;
                 rs_cleanup = mk CVoid ty_void;
               })
            resource_ty
        in
        let get = mk_func "get" [] resource_ty (Some scope) 32 in
        let converted =
          Blorp.Core_closure.adapt_function_refs_program [ decl resource; decl get ]
        in
        let get' = require_func "get" converted in
        match get'.cf_body with
        | Some
            { desc = CResourceScope { rs_body = { desc = CVar v; _ }; _ }; _ }
          ->
            Alcotest.(check string)
              "resource binding stayed local" "resource" v.vname
        | Some
            {
              desc =
                CResourceScope { rs_body = { desc = CClosureCreate _; _ }; _ };
              _;
            } ->
            Alcotest.fail
              "resource binding was wrapped as a global function ref"
        | Some _ -> Alcotest.fail "expected resource scope body"
        | None -> Alcotest.fail "missing get body"))

let test_lambda_capture_shadows_global_function_ref () =
  Blorp.Session.(
    with_current (create ()) (fun () ->
        let greeting_ty = fn_ty [] ty_string true in
        let global_greeting =
          mk_func ~is_pure:true "greeting" [] ty_string
            (Some (cstr "global"))
            33
        in
        let lam =
          {
            lam_params = [];
            lam_return_ty = ty_string;
            lam_body = cvar "greeting" ty_string;
            lam_is_pure = true;
          }
        in
        let body =
          mk
            (CLet
               ( {
                   bind_var = Var.named "greeting";
                   bind_mut = false;
                   bind_ty = ty_string;
                   bind_rhs = cstr "local";
                 },
                 mk (CLambda lam) greeting_ty ))
            greeting_ty
        in
        let make = mk_func ~is_pure:true "make" [] greeting_ty (Some body) 34 in
        let converted =
          Blorp.Core_closure.adapt_function_refs_program
            [ decl global_greeting; decl make ]
        in
        let make' = require_func "make" converted in
        match make'.cf_body with
        | Some
            {
              desc =
                CLet
                  ( _,
                    {
                      desc = CLambda { lam_body = { desc = CVar v; _ }; _ };
                      _;
                    } );
              _;
            } ->
            Alcotest.(check string)
              "local lambda capture stays a local var" "greeting" v.vname
        | Some
            {
              desc =
                CLet
                  ( _,
                    { desc = CLambda { lam_body = { desc = CClosureCreate _; _ }; _ }; _ } );
              _;
            } ->
            Alcotest.fail "lambda-local capture was wrapped as a global function"
        | Some body ->
            Alcotest.failf "expected lambda body:\n%s" (pp_to_string_indented body)
        | None -> Alcotest.fail "missing make body"))

let suite =
  [
    ( "function_refs",
      [
        Alcotest.test_case "returned_function_ref_becomes_closure_create" `Quick
          test_returned_function_ref_becomes_closure_create;
        Alcotest.test_case "let_body_function_ref_becomes_closure_create" `Quick
          test_let_body_function_ref_becomes_closure_create;
        Alcotest.test_case "local_function_value_shadows_global_name" `Quick
          test_local_function_value_shadows_global_name;
        Alcotest.test_case
          "passthrough_builtin_function_ref_becomes_closure_create" `Quick
          test_passthrough_builtin_function_ref_becomes_closure_create;
        Alcotest.test_case "function_ref_def_id_collision_uses_name_identity"
          `Quick test_function_ref_def_id_collision_uses_name_identity;
        Alcotest.test_case "resource_scope_shadows_global_function_ref" `Quick
          test_resource_scope_binding_shadows_global_function_ref;
        Alcotest.test_case "lambda_capture_shadows_global_function_ref" `Quick
          test_lambda_capture_shadows_global_function_ref;
      ] );
  ]
