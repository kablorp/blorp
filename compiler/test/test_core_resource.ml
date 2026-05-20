(** Tests for resource-scope cleanup edge rewriting. *)

open Blorp.Ast
open Blorp.Core

let loc = dummy_loc
let ty_bool = TyNamed ("Bool", [])
let ty_void = TyNamed ("Void", [])
let ty_test_resource = TyNamed ("TestResource", [])
let mk ty desc = { desc; ty; loc }
let cbool b = mk ty_bool (CLit (LitBool b))
let cvar name ty = mk ty (CVar (Var.named name))

let cleanup_call resource_name =
  let callee =
    cvar ("close_" ^ resource_name)
      (TyFunc
         { params = [ ty_test_resource ]; return = ty_void; is_pure = false })
  in
  mk ty_void
    (CCall
       ( CKUser ("close_" ^ resource_name, None),
         callee,
         [ cvar resource_name ty_test_resource ] ))

let resource_scope name body =
  mk body.ty
    (CResourceScope
       {
         rs_var = Var.named name;
         rs_ty = ty_test_resource;
         rs_acquire = cvar ("open_" ^ name) ty_test_resource;
         rs_body = body;
         rs_cleanup = cleanup_call name;
       })

let cleanup_target cleanup =
  match cleanup.desc with
  | CCall (_, _, [ { desc = CVar v; _ } ]) -> v.vname
  | _ -> Alcotest.fail "expected cleanup call with resource argument"

let cleanup_targets cleanups = List.map cleanup_target cleanups

let test_rewrites_direct_break_to_cleanup_exit () =
  let scoped = resource_scope "handle" (mk ty_void CBreak) in
  match Blorp.Core_resource.rewrite_nonlocal_exits_expr scoped with
  | { desc = CResourceScope { rs_body; _ }; _ } -> (
      match rs_body.desc with
      | CResourceCleanupExit { rce_exit = ResourceBreak; rce_cleanups } ->
          Alcotest.(check (list string))
            "cleanup targets" [ "handle" ]
            (cleanup_targets rce_cleanups)
      | _ ->
          Alcotest.failf "expected cleanup exit, got %s" (pp_to_string rs_body))
  | other ->
      Alcotest.failf "expected resource scope, got %s" (pp_to_string other)

let test_nested_loop_local_break_stays_plain_break () =
  let loop = mk ty_void (CWhile (cbool true, mk ty_void CBreak)) in
  let scoped = resource_scope "handle" loop in
  match Blorp.Core_resource.rewrite_nonlocal_exits_expr scoped with
  | { desc = CResourceScope { rs_body = { desc = CWhile (_, body); _ }; _ }; _ }
    -> (
      match body.desc with
      | CBreak -> ()
      | _ -> Alcotest.failf "expected plain break, got %s" (pp_to_string body))
  | other -> Alcotest.failf "expected scoped loop, got %s" (pp_to_string other)

let test_nested_resources_cleanup_in_reverse_order () =
  let inner = resource_scope "inner" (mk ty_void CContinue) in
  let outer = resource_scope "outer" inner in
  match Blorp.Core_resource.rewrite_nonlocal_exits_expr outer with
  | {
   desc =
     CResourceScope
       {
         rs_body =
           {
             desc =
               CResourceScope
                 {
                   rs_body =
                     {
                       desc =
                         CResourceCleanupExit
                           { rce_exit = ResourceContinue; rce_cleanups };
                       _;
                     };
                   _;
                 };
             _;
           };
         _;
       };
   _;
  } ->
      Alcotest.(check (list string))
        "cleanup targets" [ "inner"; "outer" ]
        (cleanup_targets rce_cleanups)
  | other ->
      Alcotest.failf "expected nested cleanup exit, got %s" (pp_to_string other)

let suite =
  [
    ( "rewrite",
      [
        Alcotest.test_case "direct break" `Quick
          test_rewrites_direct_break_to_cleanup_exit;
        Alcotest.test_case "loop local break" `Quick
          test_nested_loop_local_break_stays_plain_break;
        Alcotest.test_case "nested resources reverse cleanup" `Quick
          test_nested_resources_cleanup_in_reverse_order;
      ] );
  ]
