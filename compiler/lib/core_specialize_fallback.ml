(** Core builders for semantic-middle specializations that cannot use a
    representation-specific runtime builtin.

    Early std-body synthesis is owned by Blorp. This module contains only the
    fallback still required by the OCaml [Core_specialize] stage. *)

open Core

module B = Core.Build

let ty_int = B.ty_int
let ty_void = B.ty_void
let ty_ptr = Ast.TyNamed ("Ptr", [])
let mk ty desc = B.mk ~loc:Ast.dummy_loc ~ty desc
let var name ty = B.var ~loc:Ast.dummy_loc ~ty name
let int_lit value = B.lit_int ~loc:Ast.dummy_loc value
let void = B.void ~loc:Ast.dummy_loc

let intrinsic name args ty =
  mk ty (CCall (CKIntrinsic name, void, args))

let closure_call function_expr args ty =
  mk ty (CCall (CKClosure, function_expr, args))

let immutable_let name rhs body =
  mk body.ty
    (CLet
       ( {
           bind_var = Var.named name;
           bind_mut = false;
           bind_ty = rhs.ty;
           bind_rhs = rhs;
         },
         body ))

let mutable_let name rhs body =
  mk body.ty
    (CLet
       ( {
           bind_var = Var.named name;
           bind_mut = true;
           bind_ty = rhs.ty;
           bind_rhs = rhs;
         },
         body ))

let borrow name rhs body =
  mk body.ty
    (CBorrowLet
       ( { borrow_var = Var.named name; borrow_ty = rhs.ty; borrow_rhs = rhs },
         body ))

let sequence first second = mk second.ty (CSeq (first, second))

let assign name value =
  mk ty_void (CAssign (Var.named name, value))

let list_alloc_intrinsic func_name =
  match
    Core_ownership.collection_strategy ~module_path:"std/list" ~func_name
  with
  | Some
      {
        result_collection = Core_ownership.AllocateFresh { alloc; _ };
        _;
      } ->
      alloc
  | Some _ ->
      invalid_arg
        ("std/list." ^ func_name ^ " is not a fresh-allocation strategy")
  | None -> invalid_arg ("missing std/list collection strategy for " ^ func_name)

(** Build the sequential [List.filter_map] fallback used when the parallel
    runtime has no direct ABI for [Option[U]]. The callback result remains an
    owned Option binding; Perceus owns wrapper release placement. *)
let list_filter_map self_ty result_ty self function_expr =
  let alloc = list_alloc_intrinsic "filter_map" in
  let elem_ty =
    match self_ty with
    | Ast.TyNamed (("List" | "ParallelList"), [ elem ]) -> elem
    | _ -> ty_ptr
  in
  let result_elem_ty =
    match result_ty with
    | Ast.TyNamed (("List" | "ParallelList"), [ elem ]) -> elem
    | _ -> ty_ptr
  in
  let option_ty = Ast.TyNamed ("Option", [ result_elem_ty ]) in
  let index = var "__i" ty_int in
  let output_index = var "__out" ty_int in
  let value = var "__value" result_elem_ty in
  let keep =
    sequence
      (intrinsic "list_set_owned"
         [ var "__result" result_ty; output_index; value ]
         ty_void)
      (assign "__out"
         (mk ty_int (CBin (Ast.Add, output_index, int_lit 1))))
  in
  let match_mapped =
    mk ty_void
      (CMatch
         ( var "__mapped" option_ty,
           CTSwitchTag
             {
               cts_scrut = AccRoot;
               cts_cases =
                 [
                   ( "Some",
                     CTLeaf
                       {
                         ct_bindings =
                           [
                             borrowed_match_binding (Var.named "__value")
                               (AccVariantField (AccRoot, "Some", 0));
                           ];
                         ct_body = keep;
                       } );
                   ("None", CTLeaf { ct_bindings = []; ct_body = void });
                 ];
               cts_default = None;
             } ))
  in
  let elem = mk elem_ty (CUnbox (var "__raw" ty_ptr, elem_ty)) in
  let loop_body =
    immutable_let "__raw"
      (intrinsic "list_get" [ var "__self" self_ty; index ] ty_ptr)
      (immutable_let "__mapped"
         (closure_call function_expr [ elem ] option_ty)
         match_mapped)
  in
  borrow "__self" self
    (immutable_let "__n"
       (intrinsic "list_len" [ var "__self" self_ty ] ty_int)
       (immutable_let "__result"
          (intrinsic alloc [ var "__n" ty_int ] result_ty)
          (mutable_let "__out" (int_lit 0)
             (sequence
                (mk ty_void
                   (CFor
                      ( loop_binder_named "__i" ty_int,
                        mk ty_int
                          (CRange (int_lit 0, var "__n" ty_int)),
                        loop_body )))
                (sequence
                   (intrinsic "list_set_len"
                      [ var "__result" result_ty; var "__out" ty_int ]
                      ty_void)
                   (var "__result" result_ty))))))
