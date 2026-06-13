(** Tests for Core cooperative-fairness checkpoint insertion. *)

open Blorp.Ast
open Blorp.Core

let loc = dummy_loc
let ty_bool = TyNamed ("Bool", [])
let ty_int = TyNamed ("Int", [])
let ty_void = TyNamed ("Void", [])
let mk ty desc = { desc; ty; loc }
let cbool b = mk ty_bool (CLit (LitBool b))
let cint n = mk ty_int (CLit (LitInt (Int64.of_int n)))
let cvoid = mk ty_void CVoid

let func body : core_func =
  {
    cf_name = "main";
    cf_module = None;
    cf_type_params = [];
    cf_params = [];
    cf_return_ty = body.ty;
    cf_body = Some body;
    cf_is_pure = true;
    cf_kind = CFUser;
    cf_def_id = 1;
  }

let decl body = { cd_desc = CDFunc (func body); cd_loc = loc; cd_doc = None }

let rewritten_body body =
  match Blorp.Core_fairness.insert_program_checkpoints [ decl body ] with
  | [ { cd_desc = CDFunc { cf_body = Some body; _ }; _ } ] -> body
  | _ -> Alcotest.fail "expected one rewritten function body"

let rewritten_impl_method_body body =
  let impl =
    { ci_trait = "Show"; ci_for_type = ty_int; ci_methods = [ func body ] }
  in
  match
    Blorp.Core_fairness.insert_program_checkpoints
      [ { cd_desc = CDImpl impl; cd_loc = loc; cd_doc = None } ]
  with
  | [
   { cd_desc = CDImpl { ci_methods = [ { cf_body = Some body; _ } ]; _ }; _ };
  ] ->
      body
  | _ -> Alcotest.fail "expected one rewritten impl method body"

let starts_with_checkpoint body =
  match body.desc with
  | CSeq ({ desc = CCooperativeCheckpoint; _ }, _) -> true
  | CCooperativeCheckpoint -> true
  | _ -> false

let test_inserts_checkpoint_in_while_body () =
  let loop = mk ty_void (CWhile (cbool true, cvoid)) in
  match (rewritten_body loop).desc with
  | CWhile (_, body) ->
      Alcotest.(check bool)
        "while body starts with checkpoint" true
        (starts_with_checkpoint body)
  | other ->
      Alcotest.failf "expected while, got %s"
        (pp_to_string { loop with desc = other })

let test_inserts_checkpoint_in_for_body () =
  let loop =
    mk ty_void
      (CFor
         ( loop_binder_named "i" ty_int,
           mk ty_int (CRange (cint 0, cint 3)),
           cvoid ))
  in
  match (rewritten_body loop).desc with
  | CFor (_, _, body) ->
      Alcotest.(check bool)
        "for body starts with checkpoint" true
        (starts_with_checkpoint body)
  | other ->
      Alcotest.failf "expected for, got %s"
        (pp_to_string { loop with desc = other })

let test_inserts_checkpoint_in_impl_method_loop () =
  let loop = mk ty_void (CWhile (cbool true, cvoid)) in
  match (rewritten_impl_method_body loop).desc with
  | CWhile (_, body) ->
      Alcotest.(check bool)
        "impl method loop body starts with checkpoint" true
        (starts_with_checkpoint body)
  | other ->
      Alcotest.failf "expected impl method while, got %s"
        (pp_to_string { loop with desc = other })

let test_inserts_nested_loop_checkpoints () =
  let inner = mk ty_void (CWhile (cbool true, cvoid)) in
  let outer = mk ty_void (CWhile (cbool true, inner)) in
  match (rewritten_body outer).desc with
  | CWhile (_, { desc = CSeq ({ desc = CCooperativeCheckpoint; _ }, body); _ })
    -> (
      match body.desc with
      | CWhile (_, inner_body) ->
          Alcotest.(check bool)
            "inner while body starts with checkpoint" true
            (starts_with_checkpoint inner_body)
      | _ -> Alcotest.fail "expected inner while after outer checkpoint")
  | _ -> Alcotest.fail "expected outer checkpoint"

let test_inserts_checkpoint_in_unmanaged_tailrec_body () =
  let loop =
    mk ty_int
      (CTailrecLoop
         (TailrecUnmanagedLoop
            {
              tul_params = [];
              tul_return_ty = ty_int;
              tul_body =
                mk ty_int (CTailrecRecur (TailrecRecur { tr_args = [] }));
            }))
  in
  match (rewritten_body loop).desc with
  | CTailrecLoop (TailrecUnmanagedLoop { tul_body; _ }) ->
      Alcotest.(check bool)
        "unmanaged tailrec body starts with checkpoint" true
        (starts_with_checkpoint tul_body)
  | other ->
      Alcotest.failf "expected unmanaged tailrec loop, got %s"
        (pp_to_string { loop with desc = other })

let test_inserts_checkpoint_in_list_tailrec_body () =
  let list_ty = TyNamed ("List", [ ty_int ]) in
  let list_param =
    { cp_name = Var.named "items"; cp_ty = list_ty; cp_loc = loc }
  in
  let loop =
    mk ty_int
      (CTailrecLoop
         (TailrecListSpreadLoop
            {
              tls_params = [ list_param ];
              tls_return_ty = ty_int;
              tls_list_index = 0;
              tls_list_param = list_param;
              tls_cursor_var = Var.named "__cursor";
              tls_body =
                mk ty_int
                  (CTailrecRecur
                     (TailrecListSpreadRecur
                        { tr_rebinds = []; tr_cursor_advance = 1 }));
            }))
  in
  match (rewritten_body loop).desc with
  | CTailrecLoop (TailrecListSpreadLoop { tls_body; _ }) ->
      Alcotest.(check bool)
        "list tailrec body starts with checkpoint" true
        (starts_with_checkpoint tls_body)
  | other ->
      Alcotest.failf "expected list tailrec loop, got %s"
        (pp_to_string { loop with desc = other })

let test_checkpoint_insertion_is_idempotent () =
  let body = mk ty_void (CSeq (mk ty_void CCooperativeCheckpoint, cvoid)) in
  let loop = mk ty_void (CWhile (cbool true, body)) in
  match (rewritten_body loop).desc with
  | CWhile (_, { desc = CSeq ({ desc = CCooperativeCheckpoint; _ }, tail); _ })
    -> (
      match tail.desc with
      | CSeq ({ desc = CCooperativeCheckpoint; _ }, _) ->
          Alcotest.fail "checkpoint was inserted twice"
      | CVoid -> ()
      | _ -> Alcotest.fail "unexpected checkpoint tail")
  | _ -> Alcotest.fail "expected one checkpoint"

let suite =
  [
    ( "insert",
      [
        Alcotest.test_case "while body" `Quick
          test_inserts_checkpoint_in_while_body;
        Alcotest.test_case "for body" `Quick test_inserts_checkpoint_in_for_body;
        Alcotest.test_case "impl method loop" `Quick
          test_inserts_checkpoint_in_impl_method_loop;
        Alcotest.test_case "nested loops" `Quick
          test_inserts_nested_loop_checkpoints;
        Alcotest.test_case "unmanaged tailrec body" `Quick
          test_inserts_checkpoint_in_unmanaged_tailrec_body;
        Alcotest.test_case "list tailrec body" `Quick
          test_inserts_checkpoint_in_list_tailrec_body;
        Alcotest.test_case "idempotent" `Quick
          test_checkpoint_insertion_is_idempotent;
      ] );
  ]
