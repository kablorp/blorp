(** Tests for Core_emit_util helpers shared by C emission. *)

open Blorp.Ast
open Blorp.Core

let loc =
  { line = 1; column = 1; end_line = 1; end_column = 1; loc_file = None }

let ty_int = TyNamed ("Int", [])
let ty_void = TyNamed ("Void", [])
let mk desc ty = { desc; ty; loc }
let cvar name ty = mk (CVar (Var.named name)) ty
let cvoid = mk CVoid ty_void

let resource_scope ?(acquire = cvar "open_resource" ty_int) name body =
  mk
    (CResourceScope
       {
         rs_var = Var.named name;
         rs_ty = ty_int;
         rs_acquire = acquire;
         rs_body = body;
         rs_cleanup = cvar name ty_int;
       })
    body.ty

let free_var_names expr =
  expr |> Blorp.Core_emit_util.collect_free_vars |> List.map fst

let check_names label expected expr =
  Alcotest.(check (list string)) label expected (free_var_names expr)

let test_resource_scope_binding_not_free_in_body_or_cleanup () =
  let body = mk (CSeq (cvar "resource" ty_int, cvar "tail" ty_int)) ty_int in
  let scoped = resource_scope ~acquire:(cvar "outer" ty_int) "resource" body in
  check_names "free vars" [ "outer"; "tail" ] scoped

let test_resource_scope_acquire_uses_outer_name () =
  let scoped =
    resource_scope ~acquire:(cvar "resource" ty_int) "resource" cvoid
  in
  check_names "free vars" [ "resource" ] scoped

let suite =
  [
    ( "free_vars",
      [
        Alcotest.test_case "resource_scope_body_cleanup_binding" `Quick
          test_resource_scope_binding_not_free_in_body_or_cleanup;
        Alcotest.test_case "resource_scope_acquire_outer_name" `Quick
          test_resource_scope_acquire_uses_outer_name;
      ] );
  ]
