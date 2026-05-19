(** Tests for Core-level tail-recursive loop lowering. *)

open Blorp.Ast
open Blorp.Core
module T = Blorp.Core_tailrec

let loc = dummy_loc
let ty_int = TyNamed ("Int", [])
let ty_bool = TyNamed ("Bool", [])
let ty_void = TyNamed ("Void", [])
let ty_list elem = TyNamed ("List", [ elem ])
let ty_func params return = TyFunc { params; return; is_pure = true }
let mk ty desc = { desc; ty; loc }
let cvar name ty = mk ty (CVar (Var.named name))
let cint n = mk ty_int (CLit (LitInt (Int64.of_int n)))
let cvoid = mk ty_void CVoid
let param name ty = { cp_name = Var.named name; cp_ty = ty; cp_loc = loc }

let resource_scope name ty acquire body cleanup =
  mk body.ty
    (CResourceScope
       {
         rs_var = Var.named name;
         rs_ty = ty;
         rs_acquire = acquire;
         rs_body = body;
         rs_cleanup = cleanup;
       })

let call_self ~def_id name args ty =
  let fn = cvar name (ty_func (List.map (fun arg -> arg.ty) args) ty) in
  mk ty (CCall (CKUser (name, Some def_id), fn, args))

let func ?(name = "sum_to") ?(def_id = 7) params body : core_func =
  {
    cf_name = name;
    cf_module = None;
    cf_type_params = [];
    cf_params = params;
    cf_return_ty = body.ty;
    cf_body = Some body;
    cf_is_pure = true;
    cf_kind = CFUser;
    cf_def_id = def_id;
  }

let decl f = { cd_desc = CDFunc f; cd_loc = loc; cd_doc = None }

let lowered_func_body ?(reg = Blorp.Codegen_types.create_registry ()) prog =
  match T.lower_program ~reg prog with
  | [ { cd_desc = CDFunc { cf_body = Some body; _ }; _ } ] -> body
  | _ -> Alcotest.fail "expected one lowered function body"

let test_unmanaged_self_call_becomes_tailrec_loop () =
  let def_id = 11 in
  let n = cvar "n" ty_int in
  let acc = cvar "acc" ty_int in
  let body =
    mk ty_int
      (CIf
         ( mk ty_bool (CBin (Le, n, cint 0)),
           acc,
           call_self ~def_id "sum_to"
             [
               mk ty_int (CBin (Sub, n, cint 1)); mk ty_int (CBin (Add, acc, n));
             ]
             ty_int ))
  in
  let body =
    lowered_func_body
      [ decl (func ~def_id [ param "n" ty_int; param "acc" ty_int ] body) ]
  in
  match body.desc with
  | CTailrecLoop
      (TailrecUnmanagedLoop
         {
           tul_params;
           tul_return_ty;
           tul_body = { desc = CIf (_, _, recur); _ };
         }) -> (
      Alcotest.(check int) "param count" 2 (List.length tul_params);
      Alcotest.(check string)
        "return type" "Int"
        (Blorp.Types.type_to_string tul_return_ty);
      match recur.desc with
      | CTailrecRecur (TailrecRecur { tr_args }) ->
          Alcotest.(check int) "recur arg count" 2 (List.length tr_args)
      | _ ->
          Alcotest.failf "expected tailrec recur, got %s"
            (Blorp.Core.pp_to_string recur))
  | _ ->
      Alcotest.failf "expected unmanaged tailrec loop, got %s"
        (Blorp.Core.pp_to_string body)

let test_list_spread_recur_omits_list_rebind () =
  let def_id = 19 in
  let list_int = ty_list ty_int in
  let list_param = param "lst" list_int in
  let acc_param = param "acc" ty_int in
  let scrut = cvar "lst" list_int in
  let rest = Var.named "rest" in
  let x = Var.named "x" in
  let recur =
    call_self ~def_id "sum_recursive"
      [
        mk list_int (CVar rest);
        mk ty_int (CBin (Add, cvar "acc" ty_int, mk ty_int (CVar x)));
      ]
      ty_int
  in
  let tree =
    CTSwitchLen
      {
        ctl_len_scrut = AccRoot;
        ctl_len_cases =
          [ (0, CTLeaf { ct_bindings = []; ct_body = cvar "acc" ty_int }) ];
        ctl_len_geq =
          Some
            ( 1,
              CTLeaf
                {
                  ct_bindings =
                    [
                      (x, AccListElem (AccRoot, 0));
                      (rest, AccListSpread (AccRoot, 1));
                    ];
                  ct_body = recur;
                } );
        ctl_len_default = None;
      }
  in
  let body = mk ty_int (CMatch (scrut, tree)) in
  let body =
    lowered_func_body
      [
        decl (func ~name:"sum_recursive" ~def_id [ list_param; acc_param ] body);
      ]
  in
  match body.desc with
  | CTailrecLoop
      (TailrecListSpreadLoop
         {
           tls_list_index;
           tls_list_param;
           tls_cursor_var;
           tls_body = { desc = CMatch (_, rewritten_tree); _ };
           _;
         }) -> (
      Alcotest.(check int) "list index" 0 tls_list_index;
      Alcotest.(check string) "list param" "lst" tls_list_param.cp_name.vname;
      Alcotest.(check bool)
        "cursor name is explicit" true
        (String.length tls_cursor_var.vname > 0);
      match rewritten_tree with
      | CTSwitchLen { ctl_len_geq = Some (_, CTLeaf { ct_body; _ }); _ } -> (
          match ct_body.desc with
          | CTailrecRecur
              (TailrecListSpreadRecur { tr_rebinds; tr_cursor_advance }) ->
              Alcotest.(check int) "cursor advance" 1 tr_cursor_advance;
              Alcotest.(check (list int))
                "only non-list params rebind" [ 1 ] (List.map fst tr_rebinds)
          | _ ->
              Alcotest.failf "expected list-spread recur, got %s"
                (Blorp.Core.pp_to_string ct_body))
      | _ -> Alcotest.fail "expected rewritten spread branch")
  | _ ->
      Alcotest.failf "expected list-spread tailrec loop, got %s"
        (Blorp.Core.pp_to_string body)

let test_list_spread_loop_preserves_prefix_binding () =
  let def_id = 23 in
  let list_int = ty_list ty_int in
  let list_param = param "lst" list_int in
  let acc_param = param "acc" ty_int in
  let bias_binding =
    {
      bind_var = Var.named "bias";
      bind_mut = false;
      bind_ty = ty_int;
      bind_rhs = cint 0;
    }
  in
  let rest = Var.named "rest" in
  let x = Var.named "x" in
  let recur =
    call_self ~def_id "sum_recursive"
      [
        mk list_int (CVar rest);
        mk ty_int
          (CBin
             ( Add,
               mk ty_int (CBin (Add, cvar "acc" ty_int, mk ty_int (CVar x))),
               cvar "bias" ty_int ));
      ]
      ty_int
  in
  let tree =
    CTSwitchLen
      {
        ctl_len_scrut = AccRoot;
        ctl_len_cases =
          [
            ( 0,
              CTLeaf
                {
                  ct_bindings = [];
                  ct_body =
                    mk ty_int
                      (CBin (Add, cvar "acc" ty_int, cvar "bias" ty_int));
                } );
          ];
        ctl_len_geq =
          Some
            ( 1,
              CTLeaf
                {
                  ct_bindings =
                    [
                      (x, AccListElem (AccRoot, 0));
                      (rest, AccListSpread (AccRoot, 1));
                    ];
                  ct_body = recur;
                } );
        ctl_len_default = None;
      }
  in
  let body =
    mk ty_int
      (CLet (bias_binding, mk ty_int (CMatch (cvar "lst" list_int, tree))))
  in
  let body =
    lowered_func_body
      [
        decl (func ~name:"sum_recursive" ~def_id [ list_param; acc_param ] body);
      ]
  in
  match body.desc with
  | CTailrecLoop
      (TailrecListSpreadLoop
         {
           tls_body =
             { desc = CLet (_, { desc = CMatch (_, rewritten_tree); _ }); _ };
           _;
         }) -> (
      match rewritten_tree with
      | CTSwitchLen { ctl_len_geq = Some (_, CTLeaf { ct_body; _ }); _ } -> (
          match ct_body.desc with
          | CTailrecRecur (TailrecListSpreadRecur _) -> ()
          | _ ->
              Alcotest.failf "expected list-spread recur, got %s"
                (Blorp.Core.pp_to_string ct_body))
      | _ -> Alcotest.fail "expected rewritten spread branch")
  | _ ->
      Alcotest.failf "expected let-wrapped list-spread tailrec loop, got %s"
        (Blorp.Core.pp_to_string body)

let test_list_spread_loop_recognizes_alias_param () =
  let reg = Blorp.Codegen_types.create_registry () in
  Hashtbl.replace reg.type_aliases "IntList" ([], ty_list ty_int);
  let def_id = 29 in
  let list_alias = TyNamed ("IntList", []) in
  let list_param = param "lst" list_alias in
  let acc_param = param "acc" ty_int in
  let rest = Var.named "rest" in
  let x = Var.named "x" in
  let recur =
    call_self ~def_id "sum_recursive"
      [
        mk list_alias (CVar rest);
        mk ty_int (CBin (Add, cvar "acc" ty_int, mk ty_int (CVar x)));
      ]
      ty_int
  in
  let tree =
    CTSwitchLen
      {
        ctl_len_scrut = AccRoot;
        ctl_len_cases =
          [ (0, CTLeaf { ct_bindings = []; ct_body = cvar "acc" ty_int }) ];
        ctl_len_geq =
          Some
            ( 1,
              CTLeaf
                {
                  ct_bindings =
                    [
                      (x, AccListElem (AccRoot, 0));
                      (rest, AccListSpread (AccRoot, 1));
                    ];
                  ct_body = recur;
                } );
        ctl_len_default = None;
      }
  in
  let body = mk ty_int (CMatch (cvar "lst" list_alias, tree)) in
  let body =
    lowered_func_body ~reg
      [
        decl (func ~name:"sum_recursive" ~def_id [ list_param; acc_param ] body);
      ]
  in
  match body.desc with
  | CTailrecLoop
      (TailrecListSpreadLoop
         { tls_list_param; tls_body = { desc = CMatch _; _ }; _ }) ->
      Alcotest.(check string)
        "alias list param" "lst" tls_list_param.cp_name.vname
  | _ ->
      Alcotest.failf "expected aliased list-spread tailrec loop, got %s"
        (Blorp.Core.pp_to_string body)

let test_list_spread_ignores_resource_scope_shadowed_spread_var () =
  let def_id = 31 in
  let list_int = ty_list ty_int in
  let list_param = param "lst" list_int in
  let acc_param = param "acc" ty_int in
  let scrut = cvar "lst" list_int in
  let rest = Var.named "rest" in
  let x = Var.named "x" in
  let scoped_arg =
    resource_scope "rest" ty_int (cint 0) (mk ty_int (CVar rest)) cvoid
  in
  let recur =
    call_self ~def_id "sum_recursive"
      [ mk list_int (CVar rest); scoped_arg ]
      ty_int
  in
  let tree =
    CTSwitchLen
      {
        ctl_len_scrut = AccRoot;
        ctl_len_cases =
          [ (0, CTLeaf { ct_bindings = []; ct_body = cvar "acc" ty_int }) ];
        ctl_len_geq =
          Some
            ( 1,
              CTLeaf
                {
                  ct_bindings =
                    [
                      (x, AccListElem (AccRoot, 0));
                      (rest, AccListSpread (AccRoot, 1));
                    ];
                  ct_body = recur;
                } );
        ctl_len_default = None;
      }
  in
  let body = mk ty_int (CMatch (scrut, tree)) in
  let body =
    lowered_func_body
      [
        decl (func ~name:"sum_recursive" ~def_id [ list_param; acc_param ] body);
      ]
  in
  match body.desc with
  | CTailrecLoop
      (TailrecListSpreadLoop
         { tls_body = { desc = CMatch (_, rewritten_tree); _ }; _ }) -> (
      match rewritten_tree with
      | CTSwitchLen { ctl_len_geq = Some (_, CTLeaf { ct_body; _ }); _ } -> (
          match ct_body.desc with
          | CTailrecRecur (TailrecListSpreadRecur { tr_rebinds; _ }) ->
              Alcotest.(check int)
                "non-list arg is still rebound" 1 (List.length tr_rebinds)
          | _ ->
              Alcotest.failf "expected list-spread recur, got %s"
                (Blorp.Core.pp_to_string ct_body))
      | _ -> Alcotest.fail "expected rewritten spread branch")
  | _ ->
      Alcotest.failf "expected resource-shadowed list-spread loop, got %s"
        (Blorp.Core.pp_to_string body)

let suite =
  [
    ( "lowering",
      [
        Alcotest.test_case "unmanaged self call" `Quick
          test_unmanaged_self_call_becomes_tailrec_loop;
        Alcotest.test_case "list spread cursor" `Quick
          test_list_spread_recur_omits_list_rebind;
        Alcotest.test_case "list spread with prefix binding" `Quick
          test_list_spread_loop_preserves_prefix_binding;
        Alcotest.test_case "list spread alias param" `Quick
          test_list_spread_loop_recognizes_alias_param;
        Alcotest.test_case "list spread resource shadow" `Quick
          test_list_spread_ignores_resource_scope_shadowed_spread_var;
      ] );
  ]
