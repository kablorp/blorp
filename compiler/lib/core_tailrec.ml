(** Core-level lowering for tail-recursive self-calls.

    The type checker verifies source [@tailrec] annotations before Core. Core
    does not retain that source annotation, so this pass lowers supported
    resolved self-tail-call shapes into explicit loop IR. Later ownership/reuse
    passes and non-C backends then see the same loop shape. *)

open Core

let counter = ref 0
let reset_fresh () = counter := 0

let fresh prefix =
  let n = !counter in
  incr counter;
  Printf.sprintf "__tailrec_%s_%d" prefix n

let type_is_known_unmanaged ~(reg : Codegen_types.registry) (ty : Ast.type_expr)
    : bool =
  try
    not
      (Core_layout_type.source_value_requires_release_or_error
         ~phase:(Core_error.Stage Core_stage.Tailrec) ~reg ty Ast.dummy_loc)
  with Core_error.Core_error _ -> false

let node_is_unmanaged ~reg (e : core) : bool =
  let node_ty_ok = type_is_known_unmanaged ~reg e.ty in
  let carried_ty_ok =
    match e.desc with
    | CLet (b, _) -> type_is_known_unmanaged ~reg b.bind_ty
    | CBorrowLet (b, _) -> type_is_known_unmanaged ~reg b.borrow_ty
    | CDup (_, ty, _) | CDrop (_, ty, _) -> type_is_known_unmanaged ~reg ty
    | _ -> true
  in
  node_ty_ok && carried_ty_ok

let rec ctree_unmanaged_safe ~reg (tree : ctree) : bool =
  match tree with
  | CTLeaf { ct_body; _ } -> expr_unmanaged_safe ~reg ct_body
  | CTFail -> true
  | CTSwitchTag { cts_cases; cts_default; _ } ->
      List.for_all (fun (_, sub) -> ctree_unmanaged_safe ~reg sub) cts_cases
      && Option.fold ~none:true ~some:(ctree_unmanaged_safe ~reg) cts_default
  | CTSwitchLit { ctl_cases; ctl_default; _ } ->
      List.for_all (fun (_, sub) -> ctree_unmanaged_safe ~reg sub) ctl_cases
      && ctree_unmanaged_safe ~reg ctl_default
  | CTSwitchLen { ctl_len_cases; ctl_len_geq; ctl_len_default; _ } ->
      List.for_all (fun (_, sub) -> ctree_unmanaged_safe ~reg sub) ctl_len_cases
      && Option.fold ~none:true
           ~some:(fun (_, sub) -> ctree_unmanaged_safe ~reg sub)
           ctl_len_geq
      && Option.fold ~none:true
           ~some:(ctree_unmanaged_safe ~reg)
           ctl_len_default

and expr_unmanaged_safe ~reg (e : core) : bool =
  node_is_unmanaged ~reg e
  &&
  match e.desc with
  | CCall
      ( ( CKSelectedDirect _ | CKUser _ | CKBuiltin _ | CKForeign _
        | CKIntrinsic _ ),
        _,
        args ) ->
      List.for_all (expr_unmanaged_safe ~reg) args
  | CMatch (scrut, tree) ->
      expr_unmanaged_safe ~reg scrut && ctree_unmanaged_safe ~reg tree
  | _ ->
      Core.fold_immediate_children
        (fun ok child -> ok && expr_unmanaged_safe ~reg child)
        true e

let unmanaged_safe ~reg (f : core_func) (body : core) : bool =
  type_is_known_unmanaged ~reg f.cf_return_ty
  && List.for_all
       (fun (p : core_param) -> type_is_known_unmanaged ~reg p.cp_ty)
       f.cf_params
  && expr_unmanaged_safe ~reg body

let self_tail_call_args (f : core_func) (e : core) : core list option =
  match e.desc with
  | CCall (CKUser (_, Some id), _, args) when id = f.cf_def_id -> Some args
  | CCall (CKUser (name, None), _, args) when name = f.cf_name -> Some args
  | _ -> None

let rec ctree_has_tail_self_call (f : core_func) (tree : ctree) : bool =
  match tree with
  | CTLeaf { ct_body; _ } -> expr_has_tail_self_call f ct_body
  | CTFail -> false
  | CTSwitchTag { cts_cases; cts_default; _ } ->
      List.exists (fun (_, sub) -> ctree_has_tail_self_call f sub) cts_cases
      || Option.fold ~none:false ~some:(ctree_has_tail_self_call f) cts_default
  | CTSwitchLit { ctl_cases; ctl_default; _ } ->
      List.exists (fun (_, sub) -> ctree_has_tail_self_call f sub) ctl_cases
      || ctree_has_tail_self_call f ctl_default
  | CTSwitchLen { ctl_len_cases; ctl_len_geq; ctl_len_default; _ } ->
      List.exists (fun (_, sub) -> ctree_has_tail_self_call f sub) ctl_len_cases
      || Option.fold ~none:false
           ~some:(fun (_, sub) -> ctree_has_tail_self_call f sub)
           ctl_len_geq
      || Option.fold ~none:false
           ~some:(ctree_has_tail_self_call f)
           ctl_len_default

and expr_has_tail_self_call (f : core_func) (e : core) : bool =
  match self_tail_call_args f e with
  | Some _ -> true
  | None -> (
      match e.desc with
      | CLet (_, body)
      | CBorrowLet (_, body)
      | CSeq (_, body)
      | CDup (_, _, body)
      | CDrop (_, _, body) ->
          expr_has_tail_self_call f body
      | CIf (_, then_e, else_e) ->
          expr_has_tail_self_call f then_e || expr_has_tail_self_call f else_e
      | CMatch (_, tree) -> ctree_has_tail_self_call f tree
      | _ -> false)

let should_lower_unmanaged ~reg (f : core_func) (body : core) : bool =
  f.cf_name <> "main" && f.cf_params <> [] && unmanaged_safe ~reg f body
  && expr_has_tail_self_call f body

let list_type ~reg ty = Option.is_some (Core_layout_type.list_type ~reg ty)

let list_param_plan ~reg (f : core_func) : (int * core_param) option =
  let rec collect i acc = function
    | [] -> List.rev acc
    | (p : core_param) :: rest ->
        let acc' = if list_type ~reg p.cp_ty then (i, p) :: acc else acc in
        collect (i + 1) acc' rest
  in
  match collect 0 [] f.cf_params with
  | [ (list_index, list_param) ] ->
      let rec non_list_params_unmanaged i = function
        | [] -> true
        | (p : core_param) :: rest ->
            (i = list_index || type_is_known_unmanaged ~reg p.cp_ty)
            && non_list_params_unmanaged (i + 1) rest
      in
      if
        f.cf_name <> "main"
        && type_is_known_unmanaged ~reg f.cf_return_ty
        && non_list_params_unmanaged 0 f.cf_params
      then Some (list_index, list_param)
      else None
  | _ -> None

let nth_opt xs n =
  let rec go i = function
    | [] -> None
    | x :: _ when i = n -> Some x
    | _ :: rest -> go (i + 1) rest
  in
  if n < 0 then None else go 0 xs

let rec core_uses_var (target : var) (e : core) : bool =
  match e.desc with
  | CVar v -> Var.equal v target
  | CResourceScope scope ->
      core_uses_var target scope.rs_acquire
      ||
      if Var.equal scope.rs_var target then false
      else
        core_uses_var target scope.rs_body
        || core_uses_var target scope.rs_cleanup
  | _ ->
      Core.fold_immediate_children
        (fun found child -> found || core_uses_var target child)
        false e

let list_self_call_spread_binding (f : core_func) (list_index : int)
    (bindings : (var * accessor) list) (e : core) :
    (var * int * core list) option =
  match self_tail_call_args f e with
  | None -> None
  | Some args -> (
      match nth_opt args list_index with
      | Some { desc = CVar spread_var; _ } -> (
          match
            List.find_opt
              (fun (v, acc) ->
                Var.equal v spread_var
                &&
                match acc with
                | AccListSpread (AccRoot, _) -> true
                | _ -> false)
              bindings
          with
          | Some (_, AccListSpread (AccRoot, offset))
            when List.for_all
                   (fun (i, arg) ->
                     i = list_index || not (core_uses_var spread_var arg))
                   (List.mapi (fun i arg -> (i, arg)) args) ->
              Some (spread_var, offset, args)
          | _ -> None)
      | _ -> None)

let rec list_accessor_supported = function
  | AccRoot -> true
  | AccListElem (AccRoot, _) | AccListSpread (AccRoot, _) -> true
  | AccVariantField (parent, _, _) | AccTupleField (parent, _) ->
      list_accessor_supported parent
  | AccListElem (parent, _) -> list_accessor_supported parent
  | AccListSpread _ -> false

let rec list_ctree_supported (f : core_func) (list_index : int) (tree : ctree) :
    bool =
  match tree with
  | CTLeaf { ct_bindings; ct_body } ->
      List.for_all (fun (_, acc) -> list_accessor_supported acc) ct_bindings
      && ((not (expr_has_tail_self_call f ct_body))
         || Option.is_some
              (list_self_call_spread_binding f list_index ct_bindings ct_body))
  | CTFail -> true
  | CTSwitchTag { cts_scrut; cts_cases; cts_default } ->
      list_accessor_supported cts_scrut
      && List.for_all
           (fun (_, sub) -> list_ctree_supported f list_index sub)
           cts_cases
      && Option.fold ~none:true
           ~some:(list_ctree_supported f list_index)
           cts_default
  | CTSwitchLit { ctl_scrut; ctl_cases; ctl_default } ->
      list_accessor_supported ctl_scrut
      && List.for_all
           (fun (_, sub) -> list_ctree_supported f list_index sub)
           ctl_cases
      && list_ctree_supported f list_index ctl_default
  | CTSwitchLen
      { ctl_len_scrut = AccRoot; ctl_len_cases; ctl_len_geq; ctl_len_default }
    ->
      List.for_all
        (fun (_, sub) -> list_ctree_supported f list_index sub)
        ctl_len_cases
      && Option.fold ~none:true
           ~some:(fun (_, sub) -> list_ctree_supported f list_index sub)
           ctl_len_geq
      && Option.fold ~none:true
           ~some:(list_ctree_supported f list_index)
           ctl_len_default
  | CTSwitchLen _ -> false

let rec list_tail_body_supported (f : core_func) (list_index : int)
    (list_param : core_param) (body : core) : bool =
  match body.desc with
  | CLet (_, tail_body)
  | CBorrowLet (_, tail_body)
  | CSeq (_, tail_body)
  | CDup (_, _, tail_body)
  | CDrop (_, _, tail_body) ->
      list_tail_body_supported f list_index list_param tail_body
  | CMatch (scrut, tree) -> (
      match scrut.desc with
      | CVar v ->
          Var.equal v list_param.cp_name
          && ctree_has_tail_self_call f tree
          && list_ctree_supported f list_index tree
      | _ -> false)
  | _ -> false

let list_spread_plan ~reg (f : core_func) (body : core) :
    (int * core_param) option =
  match list_param_plan ~reg f with
  | Some (list_index, list_param)
    when list_tail_body_supported f list_index list_param body ->
      Some (list_index, list_param)
  | _ -> None

let rec rewrite_unmanaged_tail (f : core_func) (e : core) : core =
  match self_tail_call_args f e with
  | Some args ->
      { e with desc = CTailrecRecur (TailrecRecur { tr_args = args }) }
  | None -> (
      match e.desc with
      | CLet (b, body) ->
          { e with desc = CLet (b, rewrite_unmanaged_tail f body) }
      | CBorrowLet (b, body) ->
          { e with desc = CBorrowLet (b, rewrite_unmanaged_tail f body) }
      | CSeq (head, body) ->
          { e with desc = CSeq (head, rewrite_unmanaged_tail f body) }
      | CDup (v, ty, body) ->
          { e with desc = CDup (v, ty, rewrite_unmanaged_tail f body) }
      | CDrop (v, ty, body) ->
          { e with desc = CDrop (v, ty, rewrite_unmanaged_tail f body) }
      | CIf (cond, then_e, else_e) ->
          {
            e with
            desc =
              CIf
                ( cond,
                  rewrite_unmanaged_tail f then_e,
                  rewrite_unmanaged_tail f else_e );
          }
      | CMatch (scrut, tree) ->
          { e with desc = CMatch (scrut, rewrite_unmanaged_ctree f tree) }
      | _ -> e)

and rewrite_unmanaged_ctree (f : core_func) (tree : ctree) : ctree =
  match tree with
  | CTLeaf { ct_bindings; ct_body } ->
      CTLeaf { ct_bindings; ct_body = rewrite_unmanaged_tail f ct_body }
  | CTFail -> CTFail
  | CTSwitchTag { cts_scrut; cts_cases; cts_default } ->
      CTSwitchTag
        {
          cts_scrut;
          cts_cases =
            List.map
              (fun (ctor, sub) -> (ctor, rewrite_unmanaged_ctree f sub))
              cts_cases;
          cts_default = Option.map (rewrite_unmanaged_ctree f) cts_default;
        }
  | CTSwitchLit { ctl_scrut; ctl_cases; ctl_default } ->
      CTSwitchLit
        {
          ctl_scrut;
          ctl_cases =
            List.map
              (fun (lit, sub) -> (lit, rewrite_unmanaged_ctree f sub))
              ctl_cases;
          ctl_default = rewrite_unmanaged_ctree f ctl_default;
        }
  | CTSwitchLen { ctl_len_scrut; ctl_len_cases; ctl_len_geq; ctl_len_default }
    ->
      CTSwitchLen
        {
          ctl_len_scrut;
          ctl_len_cases =
            List.map
              (fun (len, sub) -> (len, rewrite_unmanaged_ctree f sub))
              ctl_len_cases;
          ctl_len_geq =
            Option.map
              (fun (len, sub) -> (len, rewrite_unmanaged_ctree f sub))
              ctl_len_geq;
          ctl_len_default =
            Option.map (rewrite_unmanaged_ctree f) ctl_len_default;
        }

let list_recur_rebinds list_index args =
  List.filter_map
    (fun (i, arg) -> if i = list_index then None else Some (i, arg))
    (List.mapi (fun i arg -> (i, arg)) args)

let rec rewrite_list_ctree (f : core_func) (list_index : int) (tree : ctree) :
    ctree =
  match tree with
  | CTLeaf { ct_bindings; ct_body } -> (
      match list_self_call_spread_binding f list_index ct_bindings ct_body with
      | Some (_, offset, args) ->
          CTLeaf
            {
              ct_bindings;
              ct_body =
                {
                  ct_body with
                  desc =
                    CTailrecRecur
                      (TailrecListSpreadRecur
                         {
                           tr_rebinds = list_recur_rebinds list_index args;
                           tr_cursor_advance = offset;
                         });
                };
            }
      | None -> CTLeaf { ct_bindings; ct_body })
  | CTFail -> CTFail
  | CTSwitchTag { cts_scrut; cts_cases; cts_default } ->
      CTSwitchTag
        {
          cts_scrut;
          cts_cases =
            List.map
              (fun (ctor, sub) -> (ctor, rewrite_list_ctree f list_index sub))
              cts_cases;
          cts_default = Option.map (rewrite_list_ctree f list_index) cts_default;
        }
  | CTSwitchLit { ctl_scrut; ctl_cases; ctl_default } ->
      CTSwitchLit
        {
          ctl_scrut;
          ctl_cases =
            List.map
              (fun (lit, sub) -> (lit, rewrite_list_ctree f list_index sub))
              ctl_cases;
          ctl_default = rewrite_list_ctree f list_index ctl_default;
        }
  | CTSwitchLen { ctl_len_scrut; ctl_len_cases; ctl_len_geq; ctl_len_default }
    ->
      CTSwitchLen
        {
          ctl_len_scrut;
          ctl_len_cases =
            List.map
              (fun (len, sub) -> (len, rewrite_list_ctree f list_index sub))
              ctl_len_cases;
          ctl_len_geq =
            Option.map
              (fun (len, sub) -> (len, rewrite_list_ctree f list_index sub))
              ctl_len_geq;
          ctl_len_default =
            Option.map (rewrite_list_ctree f list_index) ctl_len_default;
        }

let rec rewrite_list_tail_body (f : core_func) (list_index : int) (body : core)
    : core =
  match body.desc with
  | CLet (binding, tail_body) ->
      {
        body with
        desc = CLet (binding, rewrite_list_tail_body f list_index tail_body);
      }
  | CBorrowLet (binding, tail_body) ->
      {
        body with
        desc =
          CBorrowLet (binding, rewrite_list_tail_body f list_index tail_body);
      }
  | CSeq (head, tail_body) ->
      {
        body with
        desc = CSeq (head, rewrite_list_tail_body f list_index tail_body);
      }
  | CDup (v, ty, tail_body) ->
      {
        body with
        desc = CDup (v, ty, rewrite_list_tail_body f list_index tail_body);
      }
  | CDrop (v, ty, tail_body) ->
      {
        body with
        desc = CDrop (v, ty, rewrite_list_tail_body f list_index tail_body);
      }
  | CMatch (scrut, tree) ->
      { body with desc = CMatch (scrut, rewrite_list_ctree f list_index tree) }
  | _ -> body

let lower_func ~reg (f : core_func) : core_func =
  match f.cf_body with
  | None -> f
  | Some body -> (
      match list_spread_plan ~reg f body with
      | Some (list_index, list_param) ->
          let cursor_var = Var.named (fresh "list_index") in
          let tls_body = rewrite_list_tail_body f list_index body in
          {
            f with
            cf_body =
              Some
                {
                  body with
                  desc =
                    CTailrecLoop
                      (TailrecListSpreadLoop
                         {
                           tls_params = f.cf_params;
                           tls_return_ty = f.cf_return_ty;
                           tls_list_index = list_index;
                           tls_list_param = list_param;
                           tls_cursor_var = cursor_var;
                           tls_body;
                         });
                };
          }
      | None when should_lower_unmanaged ~reg f body ->
          let tul_body = rewrite_unmanaged_tail f body in
          {
            f with
            cf_body =
              Some
                {
                  body with
                  desc =
                    CTailrecLoop
                      (TailrecUnmanagedLoop
                         {
                           tul_params = f.cf_params;
                           tul_return_ty = f.cf_return_ty;
                           tul_body;
                         });
                };
          }
      | None -> f)

let rec lower_decl ~reg (decl : core_decl) : core_decl =
  let desc =
    match decl.cd_desc with
    | CDFunc f -> CDFunc (lower_func ~reg f)
    | CDImpl i ->
        CDImpl { i with ci_methods = List.map (lower_func ~reg) i.ci_methods }
    | CDPrivate inner -> CDPrivate (lower_decl ~reg inner)
    | other -> other
  in
  { decl with cd_desc = desc }

let lower_program ~(reg : Codegen_types.registry) (prog : core_program) :
    core_program =
  reset_fresh ();
  List.map (lower_decl ~reg) prog
