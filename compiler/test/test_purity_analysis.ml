(** Unit tests for inferred-AST purity analysis. *)

open Blorp.Ast
open Blorp.Types

let check_int msg = Alcotest.(check int) msg
let check_int_option msg = Alcotest.(check (option int)) msg
let check_string msg = Alcotest.(check string) msg

let with_isolated_env f =
  let sess = Blorp.Session.create () in
  Blorp.Session.with_current sess f

let mk_expr desc = untyped_expr ~loc:dummy_loc desc

let mk_call_with_resolved_target ~env_purity ~callee_type_pure ~target =
  let fn_ty = ty_func [] ty_int ~pure:callee_type_pure in
  let env =
    Blorp.Env.add_func (Blorp.Env.empty ()) "f" fn_ty ~callable_id:1
      ~purity:env_purity ()
  in
  let callee =
    mk_expr (EIdent "f") |> fun e ->
    with_expr_type_info e (expr_type_info_from_type fn_ty)
  in
  let call =
    mk_expr (ECall (callee, [])) |> fun e ->
    with_expr_type_info e (expr_type_info_from_type ty_int)
  in
  let resolved =
    {
      call_syntax = CallBare;
      call_target = target;
      instantiated_params = [];
      instantiated_return = ty_int;
    }
  in
  (env, with_expr_resolved_call call resolved)

let test_resolved_pure_call_overrides_stale_impure_env () =
  with_isolated_env (fun () ->
      let env, call =
        mk_call_with_resolved_target ~env_purity:Blorp.Env.Impure
          ~callee_type_pure:false
          ~target:
            (CallDirect
               {
                 callable_id = 1;
                 source_name = "f";
                 call_pure = true;
                 origin = CallableLocal;
               })
      in
      let refs =
        Blorp.Purity_analysis.collect_impure_calls ~strict:true env [] call
      in
      check_int "no impure calls" 0 (List.length refs))

let test_resolved_impure_call_overrides_stale_pure_env () =
  with_isolated_env (fun () ->
      let env, call =
        mk_call_with_resolved_target ~env_purity:Blorp.Env.Pure
          ~callee_type_pure:true
          ~target:
            (CallDirect
               {
                 callable_id = 1;
                 source_name = "f";
                 call_pure = false;
                 origin = CallableLocal;
               })
      in
      let refs =
        Blorp.Purity_analysis.collect_impure_calls ~strict:true env [] call
      in
      check_int "one impure call" 1 (List.length refs);
      match refs with
      | [ { Blorp.Purity_analysis.called_name; called_id; _ } ] ->
          check_string "called name" "f" called_name;
          check_int_option "called id" (Some 1) called_id
      | _ -> Alcotest.fail "unexpected impure-call refs")

let test_prefer_env_purity_does_not_override_resolved_call () =
  with_isolated_env (fun () ->
      let env, call =
        mk_call_with_resolved_target ~env_purity:Blorp.Env.Pure
          ~callee_type_pure:false
          ~target:
            (CallDirect
               {
                 callable_id = 1;
                 source_name = "f";
                 call_pure = false;
                 origin = CallableLocal;
               })
      in
      let refs =
        Blorp.Purity_analysis.collect_impure_calls ~prefer_env_purity:true
          ~strict:true env [] call
      in
      check_int "one impure call" 1 (List.length refs))

let test_assumed_callable_id_overrides_resolved_call () =
  with_isolated_env (fun () ->
      let env, call =
        mk_call_with_resolved_target ~env_purity:Blorp.Env.Impure
          ~callee_type_pure:false
          ~target:
            (CallDirect
               {
                 callable_id = 1;
                 source_name = "f";
                 call_pure = false;
                 origin = CallableLocal;
               })
      in
      let refs =
        Blorp.Purity_analysis.collect_impure_calls
          ~assume_pure_callable_ids:[ 1 ] ~strict:true env [] call
      in
      check_int "no impure calls" 0 (List.length refs))

let suite =
  [
    ( "resolved calls",
      [
        Alcotest.test_case "resolved pure call overrides stale impure env"
          `Quick test_resolved_pure_call_overrides_stale_impure_env;
        Alcotest.test_case "resolved impure call overrides stale pure env"
          `Quick test_resolved_impure_call_overrides_stale_pure_env;
        Alcotest.test_case "prefer env purity does not override resolved call"
          `Quick test_prefer_env_purity_does_not_override_resolved_call;
        Alcotest.test_case "assumed callable id overrides resolved call" `Quick
          test_assumed_callable_id_overrides_resolved_call;
      ] );
  ]
