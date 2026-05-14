(** Tests for Core_closure: first-class function value normalization. *)

open Blorp.Ast
open Blorp.Core

let loc =
  { line = 1; column = 1; end_line = 1; end_column = 1; loc_file = None }

let ty_int = TyNamed ("Int", [])
let ty_float = TyNamed ("Float", [])
let ty_string = TyNamed ("String", [])
let ty_void = TyNamed ("Void", [])
let str_flags = { sf_triple = false; sf_raw = false }
let tparams names = List.map (fun name -> make_type_param name []) names
let mk d t = { desc = d; ty = t; loc }
let cvar n t = mk (CVar (Var.named n)) t
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

let rec count_dups_for name e =
  let here =
    match e.desc with CDup (v, _, _) when v.vname = name -> 1 | _ -> 0
  in
  fold_immediate_children
    (fun acc child -> acc + count_dups_for name child)
    here e

let adapt_then_perceus prog =
  prog |> Blorp.Core_closure.adapt_function_refs_program
  |> Blorp.Core_perceus.insert_drops_program

let consume_string_arg name =
  mk
    (CCall
       ( CKBuiltin "blorp_string_concat_consume",
         mk CVoid ty_void,
         [ cvar name ty_string; cstr "" ] ))
    ty_string

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
          Blorp.Core_closure.convert_program [ decl double; decl get_doubler ]
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
          Blorp.Core_closure.convert_program [ decl double; decl get_doubler ]
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

let test_eta_adapter_retains_consumed_managed_arg () =
  Blorp.Session.(
    with_current (create ()) (fun () ->
        let consume_ty = fn_ty [ ty_string ] ty_string true in
        let consume =
          mk_func ~is_pure:true "consume"
            [ ("s", ty_string) ]
            ty_string
            (Some (consume_string_arg "s"))
            3
        in
        let get_consume =
          mk_func "get_consume" [] consume_ty
            (Some (cvar "consume" consume_ty))
            4
        in
        let converted = adapt_then_perceus [ decl consume; decl get_consume ] in
        let eta = require_func "_blorp_eta_0" converted in
        match eta.cf_body with
        | Some body when count_dups_for "__eta_arg_0" body = 1 -> ()
        | Some body ->
            Alcotest.failf
              "eta adapter did not retain consumed managed arg:\n%s"
              (pp_to_string_indented body)
        | None -> Alcotest.fail "missing eta body"))

let test_closure_conversion_does_not_insert_eta_rc_ops () =
  Blorp.Session.(
    with_current (create ()) (fun () ->
        let consume_ty = fn_ty [ ty_string ] ty_string true in
        let consume =
          mk_func ~is_pure:true "consume"
            [ ("s", ty_string) ]
            ty_string
            (Some (consume_string_arg "s"))
            300
        in
        let get_consume =
          mk_func "get_consume" [] consume_ty
            (Some (cvar "consume" consume_ty))
            301
        in
        let converted =
          Blorp.Core_closure.convert_program [ decl consume; decl get_consume ]
        in
        let eta = require_func "_blorp_eta_0" converted in
        match eta.cf_body with
        | Some body ->
            Alcotest.(check int)
              "closure conversion should not insert CDup" 0
              (count_dups_for "__eta_arg_0" body)
        | None -> Alcotest.fail "missing eta body"))

let test_closure_conversion_can_disable_function_ref_adapters () =
  Blorp.Session.(
    with_current (create ()) (fun () ->
        let consume_ty = fn_ty [ ty_string ] ty_string true in
        let consume =
          mk_func ~is_pure:true "consume"
            [ ("s", ty_string) ]
            ty_string
            (Some (consume_string_arg "s"))
            310
        in
        let get_consume =
          mk_func "get_consume" [] consume_ty
            (Some (cvar "consume" consume_ty))
            311
        in
        let converted =
          Blorp.Core_closure.convert_program ~wrap_function_refs:false
            [ decl consume; decl get_consume ]
        in
        Alcotest.(check bool)
          "no post-Perceus eta adapter" false
          (Option.is_some (find_func "_blorp_eta_0" converted));
        let get_consume' = require_func "get_consume" converted in
        match get_consume'.cf_body with
        | Some { desc = CVar v; _ } ->
            Alcotest.(check string)
              "raw function ref preserved" "consume" v.vname
        | Some body ->
            Alcotest.failf "unexpected closure conversion body:\n%s"
              (pp_to_string_indented body)
        | None -> Alcotest.fail "missing get_consume body"))

let test_module_fn_ref_retains_consumed_managed_arg () =
  Blorp.Session.(
    with_current (create ()) (fun () ->
        let consume_ty = fn_ty [ ty_string ] ty_string true in
        let consume =
          {
            (mk_func ~is_pure:true "m__consume"
               [ ("s", ty_string) ]
               ty_string
               (Some (consume_string_arg "s"))
               30)
            with
            cf_module = Some "m";
          }
        in
        let get_consume =
          {
            (mk_func "m__get_consume" [] consume_ty
               (Some (cvar "m__consume" consume_ty))
               31)
            with
            cf_module = Some "m";
          }
        in
        let converted = adapt_then_perceus [ decl consume; decl get_consume ] in
        let get_consume' = require_func "m__get_consume" converted in
        (match get_consume'.cf_body with
        | Some { desc = CClosureCreate _; _ } -> ()
        | Some body ->
            Alcotest.failf "module function ref was not closure-adapted:\n%s"
              (pp_to_string_indented body)
        | None -> Alcotest.fail "missing get_consume body");
        let eta = require_func "_blorp_eta_0" converted in
        match eta.cf_body with
        | Some body when count_dups_for "__eta_arg_0" body = 1 -> ()
        | Some body ->
            Alcotest.failf
              "module eta adapter did not retain consumed managed arg:\n%s"
              (pp_to_string_indented body)
        | None -> Alcotest.fail "missing eta body"))

let test_eta_adapter_does_not_retain_borrowed_managed_arg () =
  Blorp.Session.(
    with_current (create ()) (fun () ->
        let inspect_ty = fn_ty [ ty_string ] ty_int true in
        let inspect =
          mk_func ~is_pure:true "inspect"
            [ ("s", ty_string) ]
            ty_int
            (Some (cint 0))
            5
        in
        let get_inspect =
          mk_func "get_inspect" [] inspect_ty
            (Some (cvar "inspect" inspect_ty))
            6
        in
        let converted = adapt_then_perceus [ decl inspect; decl get_inspect ] in
        let eta = require_func "_blorp_eta_0" converted in
        match eta.cf_body with
        | Some body ->
            Alcotest.(check int)
              "borrowed managed arg should not be retained" 0
              (count_dups_for "__eta_arg_0" body)
        | None -> Alcotest.fail "missing eta body"))

let test_eta_adapter_retains_builtin_consumed_managed_args () =
  Blorp.Session.(
    with_current (create ()) (fun () ->
        let concat_ty = fn_ty [ ty_string; ty_string ] ty_string true in
        let concat =
          mk_func ~is_pure:true "concat"
            [ ("a", ty_string); ("b", ty_string) ]
            ty_string
            (Some
               (mk
                  (CCall
                     ( CKBuiltin "blorp_string_concat_consume",
                       mk CVoid ty_void,
                       [ cvar "a" ty_string; cvar "b" ty_string ] ))
                  ty_string))
            7
        in
        let get_concat =
          mk_func "get_concat" [] concat_ty (Some (cvar "concat" concat_ty)) 8
        in
        let converted = adapt_then_perceus [ decl concat; decl get_concat ] in
        let eta = require_func "_blorp_eta_0" converted in
        match eta.cf_body with
        | Some body ->
            Alcotest.(check int)
              "first builtin-consumed arg retained" 1
              (count_dups_for "__eta_arg_0" body);
            Alcotest.(check int)
              "second builtin-consumed arg retained" 1
              (count_dups_for "__eta_arg_1" body)
        | None -> Alcotest.fail "missing eta body"))

let test_concurrent_binding_gets_task_closure_metadata () =
  Blorp.Session.(
    with_current (create ()) (fun () ->
        let result_string_ty =
          TyNamed ("Result", [ ty_string; TyNamed ("ConcurrencyError", []) ])
        in
        let task_rhs = cvar "s" ty_string in
        let conc =
          mk
            (CConcurrent
               {
                 conc_bindings =
                   [
                     {
                       cb_var = Var.named "a";
                       cb_ty = result_string_ty;
                       cb_rhs = task_rhs;
                       cb_task = None;
                     };
                   ];
                 conc_body = mk CVoid ty_void;
                 conc_timeout = None;
                 conc_max_threads = None;
               })
            ty_void
        in
        let run = mk_func "run" [ ("s", ty_string) ] ty_void (Some conc) 10 in
        let converted = Blorp.Core_closure.convert_program [ decl run ] in
        let run' = require_func "run" converted in
        match run'.cf_body with
        | Some { desc = CConcurrent { conc_bindings = [ binding ]; _ }; _ } -> (
            match binding.cb_task with
            | Some task ->
                Alcotest.(check string)
                  "task closure name" "_blorp_task_0" task.tc_func;
                Alcotest.(check int)
                  "one capture" 1
                  (List.length task.tc_captures);
                Alcotest.(check (list (pair string string)))
                  "capture metadata"
                  [ ("s", "String") ]
                  (List.map
                     (fun (n, ty) -> (n, Blorp.Types.type_to_string ty))
                     task.tc_captures);
                let task_func = require_func "_blorp_task_0" converted in
                Alcotest.(check bool)
                  "task closure hoisted" true
                  (match task_func.cf_kind with
                  | CFClosureBody ca -> ca.ca_task_abi
                  | _ -> false)
            | None -> Alcotest.fail "expected concurrent binding task metadata")
        | Some _ -> Alcotest.fail "expected converted CConcurrent body"
        | None -> Alcotest.fail "missing run body"))

let test_detach_gets_task_closure_metadata () =
  Blorp.Session.(
    with_current (create ()) (fun () ->
        let detach =
          mk
            (CDetach { detach_body = cvar "s" ty_string; detach_task = None })
            ty_void
        in
        let run = mk_func "run" [ ("s", ty_string) ] ty_void (Some detach) 11 in
        let converted = Blorp.Core_closure.convert_program [ decl run ] in
        let run' = require_func "run" converted in
        match run'.cf_body with
        | Some { desc = CDetach { detach_task = Some task; _ }; _ } ->
            Alcotest.(check string)
              "task closure name" "_blorp_task_0" task.tc_func;
            Alcotest.(check string)
              "detached task returns void" "Void"
              (Blorp.Types.type_to_string task.tc_return_ty);
            Alcotest.(check (list (pair string string)))
              "capture metadata"
              [ ("s", "String") ]
              (List.map
                 (fun (n, ty) -> (n, Blorp.Types.type_to_string ty))
                 task.tc_captures);
            let task_func = require_func "_blorp_task_0" converted in
            Alcotest.(check bool)
              "task closure hoisted" true
              (match task_func.cf_kind with
              | CFClosureBody ca -> ca.ca_task_abi
              | _ -> false)
        | Some { desc = CDetach { detach_task = None; _ }; _ } ->
            Alcotest.fail "expected detach task metadata"
        | Some _ -> Alcotest.fail "expected converted CDetach body"
        | None -> Alcotest.fail "missing run body"))

let test_concurrent_for_gets_task_closure_metadata () =
  Blorp.Session.(
    with_current (create ()) (fun () ->
        let list_string_ty = TyNamed ("List", [ ty_string ]) in
        let result_string_ty =
          TyNamed ("Result", [ ty_string; TyNamed ("ConcurrencyError", []) ])
        in
        let result_list_ty = TyNamed ("List", [ result_string_ty ]) in
        let cf =
          mk
            (CConcurrentFor
               {
                 cf_var = Var.named "item";
                 cf_iter = cvar "items" list_string_ty;
                 cf_body = cvar "item" ty_string;
                 cf_timeout = None;
                 cf_max_threads = None;
                 cf_task = None;
               })
            result_list_ty
        in
        let run =
          mk_func "run"
            [ ("items", list_string_ty) ]
            result_list_ty (Some cf) 12
        in
        let converted = Blorp.Core_closure.convert_program [ decl run ] in
        let run' = require_func "run" converted in
        match run'.cf_body with
        | Some { desc = CConcurrentFor { cf_task = Some task; _ }; _ } ->
            Alcotest.(check string)
              "task closure name" "_blorp_task_0" task.tc_func;
            Alcotest.(check string)
              "per-iteration task return" "String"
              (Blorp.Types.type_to_string task.tc_return_ty);
            Alcotest.(check (list (pair string string)))
              "capture metadata"
              [ ("item", "String") ]
              (List.map
                 (fun (n, ty) -> (n, Blorp.Types.type_to_string ty))
                 task.tc_captures);
            let task_func = require_func "_blorp_task_0" converted in
            Alcotest.(check bool)
              "task closure hoisted" true
              (match task_func.cf_kind with
              | CFClosureBody ca -> ca.ca_task_abi
              | _ -> false)
        | Some { desc = CConcurrentFor { cf_task = None; _ }; _ } ->
            Alcotest.fail "expected concurrent for task metadata"
        | Some _ -> Alcotest.fail "expected converted CConcurrentFor body"
        | None -> Alcotest.fail "missing run body"))

let test_generic_template_lambdas_are_not_hoisted () =
  Blorp.Session.(
    with_current (create ()) (fun () ->
        let ty_t = TyVar "T" in
        let lam_ty = fn_ty [ ty_t ] ty_t true in
        let lam =
          {
            lam_params = [ (Var.named "x", ty_t) ];
            lam_return_ty = ty_t;
            lam_body = cvar "x" ty_t;
            lam_is_pure = true;
          }
        in
        let generic_template =
          {
            cf_name = "generic_template";
            cf_module = None;
            cf_type_params = tparams [ "T" ];
            cf_params = [];
            cf_return_ty = lam_ty;
            cf_body = Some (mk (CLambda lam) lam_ty);
            cf_is_pure = true;
            cf_kind = CFUser;
            cf_def_id = 20;
          }
        in
        let converted =
          Blorp.Core_closure.convert_program [ decl generic_template ]
        in
        Alcotest.(check bool)
          "generic template pruned before closure conversion" true
          (Option.is_none (find_func "generic_template" converted));
        Alcotest.(check bool)
          "generic lambda body not hoisted" true
          (Option.is_none (find_func "_blorp_clambda_0" converted))))

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
        Alcotest.test_case "eta_adapter_retains_consumed_managed_arg" `Quick
          test_eta_adapter_retains_consumed_managed_arg;
        Alcotest.test_case "closure_conversion_no_eta_rc_ops" `Quick
          test_closure_conversion_does_not_insert_eta_rc_ops;
        Alcotest.test_case "closure_conversion_can_disable_fn_ref_adapters"
          `Quick test_closure_conversion_can_disable_function_ref_adapters;
        Alcotest.test_case "module_fn_ref_retains_consumed_managed_arg" `Quick
          test_module_fn_ref_retains_consumed_managed_arg;
        Alcotest.test_case "eta_adapter_does_not_retain_borrowed_managed_arg"
          `Quick test_eta_adapter_does_not_retain_borrowed_managed_arg;
        Alcotest.test_case "eta_adapter_retains_builtin_consumed_managed_args"
          `Quick test_eta_adapter_retains_builtin_consumed_managed_args;
        Alcotest.test_case "generic_template_lambdas_are_not_hoisted" `Quick
          test_generic_template_lambdas_are_not_hoisted;
      ] );
    ( "concurrency",
      [
        Alcotest.test_case "concurrent_binding_gets_task_closure_metadata"
          `Quick test_concurrent_binding_gets_task_closure_metadata;
        Alcotest.test_case "detach_gets_task_closure_metadata" `Quick
          test_detach_gets_task_closure_metadata;
        Alcotest.test_case "concurrent_for_gets_task_closure_metadata" `Quick
          test_concurrent_for_gets_task_closure_metadata;
      ] );
  ]
