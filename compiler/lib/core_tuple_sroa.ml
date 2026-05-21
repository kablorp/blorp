(** Scalar replacement for non-escaping tuples.

    This pass runs before Perceus. It removes heap tuple construction only
    when a local immutable tuple binding is used through tuple field access
    and never as a first-class value. The rewrite keeps each element as an
    explicit local binding, so evaluation, ownership, and later RC insertion
    remain ordinary Core concerns.

    The pass also performs a narrow interprocedural scalar expansion for direct
    calls to monomorphic user functions whose tuple return is a simple tuple of
    unmanaged scalar expressions and whose call result is used only through
    fields or supported tuple matches. This keeps the public tuple ABI intact
    while removing the call-site heap tuple.

    Unsupported shapes are deliberately left unchanged. Heap [blorp_Tuple]
    remains the ABI for escaping tuples, generic/erased storage, lists of
    tuples, closure captures, runtime helper boundaries, and tuple-returning
    functions that do not match the explicit summary shape. *)

open Core

let counter = ref 0
let reset_fresh () = counter := 0

let fresh_var prefix =
  let n = !counter in
  incr counter;
  Var.named (Printf.sprintf "__tuple_%s_%d" prefix n)

let fresh_elem_var () = fresh_var "sroa"
let fresh_arg_var () = fresh_var "arg"
let fresh_local_var () = fresh_var "local"
let fresh_cond_var () = fresh_var "cond"
let fresh_match_var () = fresh_var "match"

type use_analysis = { mutable saw_escape : bool; mutable saw_shadow : bool }

let mark_escape a = a.saw_escape <- true
let mark_shadow a = a.saw_shadow <- true

let int_field_index name =
  match int_of_string_opt name with Some i when i >= 0 -> Some i | _ -> None

let field_index_in_bounds arity name =
  match int_field_index name with Some i when i < arity -> Some i | _ -> None

let is_alias aliases v = List.exists (Var.equal v) aliases
let option_exists f = function Some value -> f value | None -> false

let rec ctree_mentions_alias aliases tree =
  match tree with
  | CTLeaf { ct_bindings; ct_body } ->
      if List.exists (fun (v, _) -> is_alias aliases v) ct_bindings then false
      else expr_mentions_alias aliases ct_body
  | CTFail -> false
  | CTSwitchTag { cts_cases; cts_default; _ } ->
      List.exists (fun (_, sub) -> ctree_mentions_alias aliases sub) cts_cases
      || option_exists (ctree_mentions_alias aliases) cts_default
  | CTSwitchLit { ctl_cases; ctl_default; _ } ->
      List.exists (fun (_, sub) -> ctree_mentions_alias aliases sub) ctl_cases
      || ctree_mentions_alias aliases ctl_default
  | CTSwitchLen { ctl_len_cases; ctl_len_geq; ctl_len_default; _ } ->
      List.exists
        (fun (_, sub) -> ctree_mentions_alias aliases sub)
        ctl_len_cases
      || option_exists
           (fun (_, sub) -> ctree_mentions_alias aliases sub)
           ctl_len_geq
      || option_exists (ctree_mentions_alias aliases) ctl_len_default

and expr_mentions_alias aliases expr =
  match expr.desc with
  | (CVar v | CField ({ desc = CVar v; _ }, _)) when is_alias aliases v -> true
  | CLet (binding, body) -> (
      expr_mentions_alias aliases binding.bind_rhs
      ||
      match binding.bind_rhs.desc with
      | CVar v when (not binding.bind_mut) && is_alias aliases v ->
          expr_mentions_alias (binding.bind_var :: aliases) body
      | _ ->
          (not (is_alias aliases binding.bind_var))
          && expr_mentions_alias aliases body)
  | CBorrowLet (binding, body) ->
      expr_mentions_alias aliases binding.borrow_rhs
      || (not (is_alias aliases binding.borrow_var))
         && expr_mentions_alias aliases body
  | CLambda lam ->
      (not (List.exists (fun (v, _) -> is_alias aliases v) lam.lam_params))
      && expr_mentions_alias aliases lam.lam_body
  | CFor (binder, iter, body) ->
      expr_mentions_alias aliases iter
      || (not (is_alias aliases binder.loop_var))
         && expr_mentions_alias aliases body
  | CResourceScope scope ->
      expr_mentions_alias aliases scope.rs_acquire
      || (not (is_alias aliases scope.rs_var))
         && (expr_mentions_alias aliases scope.rs_body
            || expr_mentions_alias aliases scope.rs_cleanup)
  | CMatch (scrut, tree) ->
      expr_mentions_alias aliases scrut || ctree_mentions_alias aliases tree
  | _ ->
      fold_immediate_children
        (fun found child -> found || expr_mentions_alias aliases child)
        false expr

let direct_tuple_field_index arity = function
  | AccTupleField (AccRoot, index) when index >= 0 && index < arity ->
      Some index
  | _ -> None

type tuple_ctree_plan =
  | TupleLeaf of (var * int) list * core
  | TupleSwitchLit of
      int * (Ast.literal * tuple_ctree_plan) list * tuple_ctree_plan

type tuple_return_expr =
  | ReturnParam of { param_index : int; ty : Ast.type_expr; loc : Ast.loc }
  | ReturnLocal of { local_index : int; ty : Ast.type_expr; loc : Ast.loc }
  | ReturnLit of { lit : Ast.literal; ty : Ast.type_expr; loc : Ast.loc }
  | ReturnUn of {
      op : Ast.unop;
      arg : tuple_return_expr;
      ty : Ast.type_expr;
      loc : Ast.loc;
    }
  | ReturnBin of {
      op : Ast.binop;
      left : tuple_return_expr;
      right : tuple_return_expr;
      ty : Ast.type_expr;
      loc : Ast.loc;
    }
  | ReturnIf of {
      cond : tuple_return_expr;
      then_expr : tuple_return_expr;
      else_expr : tuple_return_expr;
      ty : Ast.type_expr;
      loc : Ast.loc;
    }

type tuple_return_local = {
  trl_rhs : tuple_return_expr;
  trl_ty : Ast.type_expr;
}

type tuple_return_summary = {
  trs_params : core_param list;
  trs_locals : tuple_return_local list;
  trs_elems : tuple_return_expr list;
}

type tuple_return_summaries = {
  by_def_id : (int, tuple_return_summary) Hashtbl.t;
}

type tuple_return_var_ref = SummaryParam of int | SummaryLocal of int

type tuple_return_expansion = {
  tre_arg_params : core_param list;
  tre_local_bindings : binding list;
  tre_elem_vars : var list;
  tre_elems : core list;
}

let empty_tuple_return_summaries = { by_def_id = Hashtbl.create 0 }

let all_some xs =
  List.fold_right
    (fun item acc ->
      match (item, acc) with Some x, Some rest -> Some (x :: rest) | _ -> None)
    xs (Some [])

let map2_same_length f xs ys =
  if List.length xs <> List.length ys then None else Some (List.map2 f xs ys)

let rec tuple_ctree_plan arity tree =
  match tree with
  | CTLeaf { ct_bindings; ct_body } ->
      ct_bindings
      |> List.map (fun (v, acc) ->
          Option.map
            (fun index -> (v, index))
            (direct_tuple_field_index arity acc))
      |> all_some
      |> Option.map (fun bindings -> TupleLeaf (bindings, ct_body))
  | CTFail -> None
  | CTSwitchLit { ctl_scrut; ctl_cases; ctl_default } -> (
      match direct_tuple_field_index arity ctl_scrut with
      | None -> None
      | Some scrut_index ->
          let cases =
            ctl_cases
            |> List.map (fun (lit, sub) ->
                Option.map
                  (fun plan -> (lit, plan))
                  (tuple_ctree_plan arity sub))
            |> all_some
          in
          Option.bind cases (fun cases ->
              Option.map
                (fun default -> TupleSwitchLit (scrut_index, cases, default))
                (tuple_ctree_plan arity ctl_default)))
  | CTSwitchTag _ | CTSwitchLen _ -> None

let rec scan_ctree_uses arity analysis aliases tree =
  match tree with
  | CTLeaf { ct_bindings; ct_body } ->
      if List.exists (fun (v, _) -> is_alias aliases v) ct_bindings then
        mark_shadow analysis
      else scan_uses arity analysis aliases ct_body
  | CTFail -> ()
  | CTSwitchTag { cts_cases; cts_default; _ } ->
      List.iter
        (fun (_, sub) -> scan_ctree_uses arity analysis aliases sub)
        cts_cases;
      Option.iter (scan_ctree_uses arity analysis aliases) cts_default
  | CTSwitchLit { ctl_cases; ctl_default; _ } ->
      List.iter
        (fun (_, sub) -> scan_ctree_uses arity analysis aliases sub)
        ctl_cases;
      scan_ctree_uses arity analysis aliases ctl_default
  | CTSwitchLen { ctl_len_cases; ctl_len_geq; ctl_len_default; _ } ->
      List.iter
        (fun (_, sub) -> scan_ctree_uses arity analysis aliases sub)
        ctl_len_cases;
      Option.iter
        (fun (_, sub) -> scan_ctree_uses arity analysis aliases sub)
        ctl_len_geq;
      Option.iter (scan_ctree_uses arity analysis aliases) ctl_len_default

and scan_uses arity analysis aliases expr =
  match expr.desc with
  | CVar v when is_alias aliases v -> mark_escape analysis
  | CField ({ desc = CVar v; _ }, name) when is_alias aliases v ->
      if Option.is_none (field_index_in_bounds arity name) then
        mark_escape analysis
  | CLet (binding, body) -> (
      match binding.bind_rhs.desc with
      | CVar v when (not binding.bind_mut) && is_alias aliases v ->
          scan_uses arity analysis (binding.bind_var :: aliases) body
      | _ ->
          scan_uses arity analysis aliases binding.bind_rhs;
          if is_alias aliases binding.bind_var then mark_shadow analysis
          else scan_uses arity analysis aliases body)
  | CBorrowLet (binding, body) ->
      scan_uses arity analysis aliases binding.borrow_rhs;
      if is_alias aliases binding.borrow_var then mark_shadow analysis
      else scan_uses arity analysis aliases body
  | CResourceScope scope ->
      if
        expr_mentions_alias aliases scope.rs_acquire
        || (not (is_alias aliases scope.rs_var))
           && (expr_mentions_alias aliases scope.rs_body
              || expr_mentions_alias aliases scope.rs_cleanup)
      then mark_escape analysis;
      if is_alias aliases scope.rs_var then mark_shadow analysis
  | CLambda lam ->
      if List.exists (fun (v, _) -> is_alias aliases v) lam.lam_params then
        mark_shadow analysis
      else scan_uses arity analysis aliases lam.lam_body
  | CAssign (v, rhs) ->
      if is_alias aliases v then mark_escape analysis;
      scan_uses arity analysis aliases rhs
  | CFor (binder, iter, body) ->
      scan_uses arity analysis aliases iter;
      if is_alias aliases binder.loop_var then mark_shadow analysis
      else scan_uses arity analysis aliases body
  | CMatch ({ desc = CVar v; _ }, tree) when is_alias aliases v ->
      if Option.is_some (tuple_ctree_plan arity tree) then
        scan_ctree_uses arity analysis aliases tree
      else mark_escape analysis
  | CMatch (scrut, tree) ->
      scan_uses arity analysis aliases scrut;
      scan_ctree_uses arity analysis aliases tree
  | CMatchArms _ ->
      (* This pass normally runs after [Core_match]. If an unsupported arm form
         survives, keep the tuple heap-allocated rather than reasoning about
         pattern binder shadowing here. *)
      mark_escape analysis
  | CConcurrent cb ->
      List.iter
        (fun b -> scan_uses arity analysis aliases b.cb_rhs)
        cb.conc_bindings;
      Option.iter (scan_uses arity analysis aliases) cb.conc_timeout;
      if List.exists (fun b -> is_alias aliases b.cb_var) cb.conc_bindings then
        mark_shadow analysis
      else scan_uses arity analysis aliases cb.conc_body
  | CConcurrentFor cf ->
      scan_uses arity analysis aliases cf.cf_iter;
      Option.iter (scan_uses arity analysis aliases) cf.cf_timeout;
      if is_alias aliases cf.cf_var then mark_shadow analysis
      else scan_uses arity analysis aliases cf.cf_body
  | CTailrecLoop (TailrecUnmanagedLoop loop) ->
      if List.exists (fun p -> is_alias aliases p.cp_name) loop.tul_params then
        mark_shadow analysis
      else scan_uses arity analysis aliases loop.tul_body
  | CTailrecLoop (TailrecListSpreadLoop loop) ->
      if
        List.exists
          (fun p -> is_alias aliases p.cp_name)
          (loop.tls_list_param :: loop.tls_params)
        || is_alias aliases loop.tls_cursor_var
      then mark_shadow analysis
      else scan_uses arity analysis aliases loop.tls_body
  | _ ->
      ignore
        (map_children
           (fun child ->
             scan_uses arity analysis aliases child;
             child)
           expr)

let tuple_binding_is_sroa_candidate_arity binding arity body =
  if binding.bind_mut then false
  else
    let analysis = { saw_escape = false; saw_shadow = false } in
    scan_uses arity analysis [ binding.bind_var ] body;
    (not analysis.saw_escape) && not analysis.saw_shadow

let tuple_binding_is_sroa_candidate binding elems body =
  tuple_binding_is_sroa_candidate_arity binding (List.length elems) body

let type_is_known_unmanaged ~reg ty =
  try
    not
      (Core_layout_type.source_value_requires_release_or_error
         ~phase:(Core_error.Stage Core_stage.Fusion) ~reg ty Ast.dummy_loc)
  with Core_error.Core_error _ -> false

let tuple_return_scope_of_params params =
  List.mapi (fun index p -> (p.cp_name, SummaryParam index)) params

let tuple_return_ref scope v =
  scope |> List.find_opt (fun (bound, _) -> Var.equal bound v) |> Option.map snd

let tuple_return_expr_type = function
  | ReturnParam { ty; _ }
  | ReturnLocal { ty; _ }
  | ReturnLit { ty; _ }
  | ReturnUn { ty; _ }
  | ReturnBin { ty; _ }
  | ReturnIf { ty; _ } ->
      ty

let tuple_return_expr_loc = function
  | ReturnParam { loc; _ }
  | ReturnLocal { loc; _ }
  | ReturnLit { loc; _ }
  | ReturnUn { loc; _ }
  | ReturnBin { loc; _ }
  | ReturnIf { loc; _ } ->
      loc

let tuple_return_if cond then_expr else_expr =
  let then_ty = tuple_return_expr_type then_expr in
  let else_ty = tuple_return_expr_type else_expr in
  if Types.types_equal then_ty else_ty then
    Some
      (ReturnIf
         {
           cond;
           then_expr;
           else_expr;
           ty = then_ty;
           loc = tuple_return_expr_loc then_expr;
         })
  else None

let rec tuple_return_expr_of_core ~reg scope expr =
  if not (type_is_known_unmanaged ~reg expr.ty) then None
  else
    match expr.desc with
    | CVar v -> (
        match tuple_return_ref scope v with
        | Some (SummaryParam param_index) ->
            Some (ReturnParam { param_index; ty = expr.ty; loc = expr.loc })
        | Some (SummaryLocal local_index) ->
            Some (ReturnLocal { local_index; ty = expr.ty; loc = expr.loc })
        | None -> None)
    | CLit lit -> Some (ReturnLit { lit; ty = expr.ty; loc = expr.loc })
    | CUn (op, arg) ->
        Option.map
          (fun arg -> ReturnUn { op; arg; ty = expr.ty; loc = expr.loc })
          (tuple_return_expr_of_core ~reg scope arg)
    | CBin (op, left, right) -> (
        match
          ( tuple_return_expr_of_core ~reg scope left,
            tuple_return_expr_of_core ~reg scope right )
        with
        | Some left, Some right ->
            Some (ReturnBin { op; left; right; ty = expr.ty; loc = expr.loc })
        | _ -> None)
    | CIf (cond, then_expr, else_expr) -> (
        match
          ( tuple_return_expr_of_core ~reg scope cond,
            tuple_return_expr_of_core ~reg scope then_expr,
            tuple_return_expr_of_core ~reg scope else_expr )
        with
        | Some cond, Some then_expr, Some else_expr ->
            tuple_return_if cond then_expr else_expr
        | _ -> None)
    | _ -> None

let tuple_return_elems_from_body ~reg scope body =
  match body.desc with
  | CTuple elems ->
      elems |> List.map (tuple_return_expr_of_core ~reg scope) |> all_some
  | CLet (binding, { desc = CVar v; _ })
    when (not binding.bind_mut) && Var.equal binding.bind_var v -> (
      match binding.bind_rhs.desc with
      | CTuple elems ->
          elems |> List.map (tuple_return_expr_of_core ~reg scope) |> all_some
      | _ -> None)
  | _ -> None

let tuple_return_summary_from_body ~reg params body =
  let finish scope locals_rev elems =
    elems
    |> List.map (tuple_return_expr_of_core ~reg scope)
    |> all_some
    |> Option.map (fun trs_elems ->
        { trs_params = params; trs_locals = List.rev locals_rev; trs_elems })
  in
  let rec go scope locals_rev local_count body =
    match body.desc with
    | CTuple elems -> finish scope locals_rev elems
    | CLet (binding, { desc = CVar v; _ })
      when (not binding.bind_mut) && Var.equal binding.bind_var v -> (
        match binding.bind_rhs.desc with
        | CTuple elems -> finish scope locals_rev elems
        | _ -> None)
    | CLet (binding, body)
      when (not binding.bind_mut)
           && type_is_known_unmanaged ~reg binding.bind_ty -> (
        match tuple_return_expr_of_core ~reg scope binding.bind_rhs with
        | None -> None
        | Some trl_rhs ->
            let local_ref = SummaryLocal local_count in
            let scope = (binding.bind_var, local_ref) :: scope in
            let local = { trl_rhs; trl_ty = binding.bind_ty } in
            go scope (local :: locals_rev) (local_count + 1) body)
    | CIf (cond, then_body, else_body) -> (
        match
          ( tuple_return_expr_of_core ~reg scope cond,
            tuple_return_elems_from_body ~reg scope then_body,
            tuple_return_elems_from_body ~reg scope else_body )
        with
        | Some trl_rhs, Some then_elems, Some else_elems ->
            let cond_ref =
              ReturnLocal
                { local_index = local_count; ty = cond.ty; loc = cond.loc }
            in
            Option.map
              (fun trs_elems ->
                {
                  trs_params = params;
                  trs_locals =
                    List.rev ({ trl_rhs; trl_ty = cond.ty } :: locals_rev);
                  trs_elems;
                })
              (match
                 map2_same_length (tuple_return_if cond_ref) then_elems
                   else_elems
               with
              | Some elems -> all_some elems
              | None -> None)
        | _ -> None)
    | _ -> None
  in
  go (tuple_return_scope_of_params params) [] 0 body

let tuple_return_summary_of_func ~reg f =
  match (f.cf_kind, f.cf_type_params, f.cf_body, f.cf_return_ty) with
  | CFUser, [], Some body, Ast.TyTuple return_elems -> (
      match tuple_return_summary_from_body ~reg f.cf_params body with
      | Some summary
        when List.length summary.trs_elems = List.length return_elems
             && List.for_all
                  (fun p -> type_is_known_unmanaged ~reg p.cp_ty)
                  f.cf_params ->
          Some summary
      | _ -> None)
  | _ -> None

let build_tuple_return_summaries ~reg prog =
  let summaries = { by_def_id = Hashtbl.create 16 } in
  let add_func f =
    match tuple_return_summary_of_func ~reg f with
    | None -> ()
    | Some summary -> Hashtbl.replace summaries.by_def_id f.cf_def_id summary
  in
  let rec go_decl decl =
    match decl.cd_desc with
    | CDFunc f -> add_func f
    | CDImpl impl -> List.iter add_func impl.ci_methods
    | CDPrivate inner -> go_decl inner
    | CDTrait _ | CDType _ | CDRecord _ | CDImport _ | CDTypeAlias _ | CDVar _
      ->
        ()
  in
  List.iter go_decl prog;
  summaries

let tuple_return_summary_for_call summaries = function
  | CKUser (_, Some def_id) -> Hashtbl.find_opt summaries.by_def_id def_id
  | CKUser (_, None) -> None
  | CKUnknown | CKSelectedDirect _ | CKForeign _ | CKBuiltin _ | CKIntrinsic _
  | CKClosure ->
      None

let rec tuple_return_expr_to_core param_vars local_vars = function
  | ReturnParam { param_index; ty; loc } ->
      Option.map
        (fun param_var -> { desc = CVar param_var; ty; loc })
        (List.nth_opt param_vars param_index)
  | ReturnLocal { local_index; ty; loc } ->
      Option.map
        (fun local_var -> { desc = CVar local_var; ty; loc })
        (List.nth_opt local_vars local_index)
  | ReturnLit { lit; ty; loc } -> Some { desc = CLit lit; ty; loc }
  | ReturnUn { op; arg; ty; loc } ->
      Option.map
        (fun arg -> { desc = CUn (op, arg); ty; loc })
        (tuple_return_expr_to_core param_vars local_vars arg)
  | ReturnBin { op; left; right; ty; loc } -> (
      match
        ( tuple_return_expr_to_core param_vars local_vars left,
          tuple_return_expr_to_core param_vars local_vars right )
      with
      | Some left, Some right -> Some { desc = CBin (op, left, right); ty; loc }
      | _ -> None)
  | ReturnIf { cond; then_expr; else_expr; ty; loc } -> (
      match
        ( tuple_return_expr_to_core param_vars local_vars cond,
          tuple_return_expr_to_core param_vars local_vars then_expr,
          tuple_return_expr_to_core param_vars local_vars else_expr )
      with
      | Some cond, Some then_expr, Some else_expr ->
          Some { desc = CIf (cond, then_expr, else_expr); ty; loc }
      | _ -> None)

let bind_call_args ~loc params args body =
  List.fold_right2
    (fun param arg acc ->
      {
        desc =
          CLet
            ( {
                bind_var = param.cp_name;
                bind_mut = false;
                bind_ty = param.cp_ty;
                bind_rhs = arg;
              },
              acc );
        ty = acc.ty;
        loc;
      })
    params args body

let tuple_elem_ref elem_vars elems loc index =
  let elem = List.nth elems index in
  { desc = CVar (List.nth elem_vars index); ty = elem.ty; loc }

let rec lower_supported_tuple_ctree ~loc ~ty elem_vars elems ~rewrite_body plan
    =
  match plan with
  | TupleLeaf (ct_bindings, ct_body) ->
      let body = rewrite_body ct_body in
      List.fold_right
        (fun (bind_var, index) acc_body ->
          let bind_rhs = tuple_elem_ref elem_vars elems loc index in
          {
            desc =
              CLet
                ( { bind_var; bind_mut = false; bind_ty = bind_rhs.ty; bind_rhs },
                  acc_body );
            ty = acc_body.ty;
            loc;
          })
        ct_bindings body
  | TupleSwitchLit (scrut_index, ctl_cases, ctl_default) ->
      let scrut = tuple_elem_ref elem_vars elems loc scrut_index in
      let lower_subtree sub =
        CTLeaf
          {
            ct_bindings = [];
            ct_body =
              lower_supported_tuple_ctree ~loc ~ty elem_vars elems ~rewrite_body
                sub;
          }
      in
      {
        desc =
          CMatch
            ( scrut,
              CTSwitchLit
                {
                  ctl_scrut = AccRoot;
                  ctl_cases =
                    List.map
                      (fun (lit, sub) -> (lit, lower_subtree sub))
                      ctl_cases;
                  ctl_default = lower_subtree ctl_default;
                } );
        ty;
        loc;
      }

let replace_field_uses root_var elem_vars elems expr =
  let rec go aliases expr =
    match expr.desc with
    | CField ({ desc = CVar v; _ }, name) when is_alias aliases v -> (
        match field_index_in_bounds (List.length elem_vars) name with
        | Some index -> { expr with desc = CVar (List.nth elem_vars index) }
        | None -> expr)
    | CMatch ({ desc = CVar v; _ }, tree) when is_alias aliases v -> (
        match tuple_ctree_plan (List.length elem_vars) tree with
        | None -> expr
        | Some plan ->
            lower_supported_tuple_ctree ~loc:expr.loc ~ty:expr.ty elem_vars
              elems ~rewrite_body:(go aliases) plan)
    | CLet (binding, body) -> (
        match binding.bind_rhs.desc with
        | CVar v when (not binding.bind_mut) && is_alias aliases v ->
            go (binding.bind_var :: aliases) body
        | _ ->
            {
              expr with
              desc =
                CLet
                  ( { binding with bind_rhs = go aliases binding.bind_rhs },
                    go aliases body );
            })
    | CBorrowLet (binding, body) ->
        {
          expr with
          desc =
            CBorrowLet
              ( { binding with borrow_rhs = go aliases binding.borrow_rhs },
                go aliases body );
        }
    | CFor (binder, iter, body) ->
        { expr with desc = CFor (binder, go aliases iter, go aliases body) }
    | CResourceScope scope ->
        let acquire = go aliases scope.rs_acquire in
        if is_alias aliases scope.rs_var then
          {
            expr with
            desc = CResourceScope { scope with rs_acquire = acquire };
          }
        else
          {
            expr with
            desc =
              CResourceScope
                {
                  scope with
                  rs_acquire = acquire;
                  rs_body = go aliases scope.rs_body;
                  rs_cleanup = go aliases scope.rs_cleanup;
                };
          }
    | CConcurrent cb ->
        {
          expr with
          desc =
            CConcurrent
              {
                cb with
                conc_bindings =
                  List.map
                    (fun b -> { b with cb_rhs = go aliases b.cb_rhs })
                    cb.conc_bindings;
                conc_body = go aliases cb.conc_body;
                conc_timeout = Option.map (go aliases) cb.conc_timeout;
              };
        }
    | CConcurrentFor cf ->
        {
          expr with
          desc =
            CConcurrentFor
              {
                cf with
                cf_iter = go aliases cf.cf_iter;
                cf_body = go aliases cf.cf_body;
                cf_timeout = Option.map (go aliases) cf.cf_timeout;
              };
        }
    | _ ->
        let rewritten = map_children (go aliases) expr in
        { expr with desc = rewritten.desc }
  in
  go [ root_var ] expr

let assert_removed_tuple_binding_unreferenced ~loc ~root_var body =
  if
    exists_tree
      (fun node ->
        match node.desc with
        | CVar v when Var.equal v root_var -> true
        | _ -> false)
      body
  then
    Core_error.errorf (Core_error.Stage Core_stage.Fusion) loc
      ~hint:
        "Core_tuple_sroa should only remove a tuple binding after every \
         supported use is rewritten. Leave unsupported use shapes \
         heap-allocated."
      "tuple SROA removed binding `%s` but left a reference to it"
      (Var.to_string root_var)

let bind_tuple_elements ~loc elem_vars elems body =
  List.fold_right2
    (fun bind_var bind_rhs acc ->
      {
        desc =
          CLet
            ( { bind_var; bind_mut = false; bind_ty = bind_rhs.ty; bind_rhs },
              acc );
        ty = acc.ty;
        loc;
      })
    elem_vars elems body

let bind_core_bindings ~loc bindings body =
  List.fold_right
    (fun binding acc -> { desc = CLet (binding, acc); ty = acc.ty; loc })
    bindings body

let immediate_tuple_elements expr =
  match expr.desc with CTuple elems -> Some elems | _ -> None

let tuple_if_elements cond then_elems else_elems =
  match
    map2_same_length
      (fun then_elem else_elem -> (then_elem, else_elem))
      then_elems else_elems
  with
  | None -> None
  | Some pairs
    when List.for_all
           (fun (then_elem, else_elem) ->
             Types.types_equal then_elem.ty else_elem.ty)
           pairs ->
      let cond_var = fresh_cond_var () in
      let cond_ref = { desc = CVar cond_var; ty = cond.ty; loc = cond.loc } in
      let elems =
        List.map
          (fun (then_elem, else_elem) ->
            {
              desc = CIf (cond_ref, then_elem, else_elem);
              ty = then_elem.ty;
              loc = then_elem.loc;
            })
          pairs
      in
      Some
        ( {
            bind_var = cond_var;
            bind_mut = false;
            bind_ty = cond.ty;
            bind_rhs = cond;
          },
          elems )
  | Some _ -> None

let rec tuple_ctree_leaf_elements tree =
  match tree with
  | CTLeaf { ct_body; _ } -> (
      match immediate_tuple_elements ct_body with
      | Some elems -> Some [ elems ]
      | None -> None)
  | CTFail -> Some []
  | CTSwitchTag { cts_cases; cts_default; _ } -> (
      match
        ( cts_cases
          |> List.map (fun (_, sub) -> tuple_ctree_leaf_elements sub)
          |> all_some,
          match cts_default with
          | None -> Some []
          | Some sub -> tuple_ctree_leaf_elements sub )
      with
      | Some cases, Some default -> Some (List.concat cases @ default)
      | _ -> None)
  | CTSwitchLit { ctl_cases; ctl_default; _ } -> (
      match
        ( ctl_cases
          |> List.map (fun (_, sub) -> tuple_ctree_leaf_elements sub)
          |> all_some,
          tuple_ctree_leaf_elements ctl_default )
      with
      | Some cases, Some default -> Some (List.concat cases @ default)
      | _ -> None)
  | CTSwitchLen { ctl_len_cases; ctl_len_geq; ctl_len_default; _ } -> (
      match
        ( ctl_len_cases
          |> List.map (fun (_, sub) -> tuple_ctree_leaf_elements sub)
          |> all_some,
          (match ctl_len_geq with
          | None -> Some []
          | Some (_, sub) -> tuple_ctree_leaf_elements sub),
          match ctl_len_default with
          | None -> Some []
          | Some sub -> tuple_ctree_leaf_elements sub )
      with
      | Some cases, Some geq, Some default ->
          Some (List.concat cases @ geq @ default)
      | _ -> None)

let tuple_leaf_shape leaves =
  match leaves with
  | [] -> None
  | first :: rest ->
      let arity = List.length first in
      let indexes = List.init arity Fun.id in
      if
        List.for_all (fun elems -> List.length elems = arity) rest
        && List.for_all
             (fun index ->
               let expected = (List.nth first index).ty in
               List.for_all
                 (fun elems ->
                   Types.types_equal (List.nth elems index).ty expected)
                 rest)
             indexes
      then Some (List.map (fun elem -> elem.ty) first)
      else None

let rec tuple_ctree_element index tree =
  match tree with
  | CTLeaf { ct_bindings; ct_body } -> (
      match immediate_tuple_elements ct_body with
      | Some elems -> (
          match List.nth_opt elems index with
          | Some ct_body -> Some (CTLeaf { ct_bindings; ct_body })
          | None -> None)
      | None -> None)
  | CTFail -> Some CTFail
  | CTSwitchTag { cts_scrut; cts_cases; cts_default } -> (
      match
        ( cts_cases
          |> List.map (fun (tag, sub) ->
              Option.map
                (fun lowered -> (tag, lowered))
                (tuple_ctree_element index sub))
          |> all_some,
          match cts_default with
          | None -> Some None
          | Some sub ->
              Option.map
                (fun lowered -> Some lowered)
                (tuple_ctree_element index sub) )
      with
      | Some cts_cases, Some cts_default ->
          Some (CTSwitchTag { cts_scrut; cts_cases; cts_default })
      | _ -> None)
  | CTSwitchLit { ctl_scrut; ctl_cases; ctl_default } -> (
      match
        ( ctl_cases
          |> List.map (fun (lit, sub) ->
              Option.map
                (fun lowered -> (lit, lowered))
                (tuple_ctree_element index sub))
          |> all_some,
          tuple_ctree_element index ctl_default )
      with
      | Some ctl_cases, Some ctl_default ->
          Some (CTSwitchLit { ctl_scrut; ctl_cases; ctl_default })
      | _ -> None)
  | CTSwitchLen { ctl_len_scrut; ctl_len_cases; ctl_len_geq; ctl_len_default }
    -> (
      match
        ( ctl_len_cases
          |> List.map (fun (len, sub) ->
              Option.map
                (fun lowered -> (len, lowered))
                (tuple_ctree_element index sub))
          |> all_some,
          (match ctl_len_geq with
          | None -> Some None
          | Some (len, sub) ->
              Option.map
                (fun lowered -> Some (len, lowered))
                (tuple_ctree_element index sub)),
          match ctl_len_default with
          | None -> Some None
          | Some sub ->
              Option.map
                (fun lowered -> Some lowered)
                (tuple_ctree_element index sub) )
      with
      | Some ctl_len_cases, Some ctl_len_geq, Some ctl_len_default ->
          Some
            (CTSwitchLen
               { ctl_len_scrut; ctl_len_cases; ctl_len_geq; ctl_len_default })
      | _ -> None)

let tuple_match_element_trees tree =
  match Option.bind (tuple_ctree_leaf_elements tree) tuple_leaf_shape with
  | None -> None
  | Some elem_tys ->
      elem_tys
      |> List.mapi (fun index ty ->
          Option.map (fun tree -> (ty, tree)) (tuple_ctree_element index tree))
      |> all_some

let lower_tuple_match_binding ~reg binding scrut tree body loc =
  if not (type_is_known_unmanaged ~reg scrut.ty) then None
  else
    match tuple_match_element_trees tree with
    | Some elem_trees
      when tuple_binding_is_sroa_candidate_arity binding
             (List.length elem_trees) body ->
        let match_var = fresh_match_var () in
        let scrut_ref =
          { desc = CVar match_var; ty = scrut.ty; loc = scrut.loc }
        in
        let elems =
          List.map
            (fun (ty, tree) -> { desc = CMatch (scrut_ref, tree); ty; loc })
            elem_trees
        in
        let match_binding =
          {
            bind_var = match_var;
            bind_mut = false;
            bind_ty = scrut.ty;
            bind_rhs = scrut;
          }
        in
        let elem_vars = List.map (fun _ -> fresh_elem_var ()) elems in
        let body = replace_field_uses binding.bind_var elem_vars elems body in
        assert_removed_tuple_binding_unreferenced ~loc
          ~root_var:binding.bind_var body;
        Some
          (body
          |> bind_tuple_elements ~loc elem_vars elems
          |> bind_core_bindings ~loc [ match_binding ])
    | _ -> None

let tuple_return_call_expansion summary args =
  if List.length summary.trs_params <> List.length args then None
  else
    let arg_vars = List.map (fun _ -> fresh_arg_var ()) args in
    let arg_params =
      List.map2
        (fun param arg_var -> { param with cp_name = arg_var })
        summary.trs_params arg_vars
    in
    let local_vars =
      List.map (fun _ -> fresh_local_var ()) summary.trs_locals
    in
    let local_bindings =
      List.map2
        (fun local local_var ->
          Option.map
            (fun bind_rhs ->
              {
                bind_var = local_var;
                bind_mut = false;
                bind_ty = local.trl_ty;
                bind_rhs;
              })
            (tuple_return_expr_to_core arg_vars local_vars local.trl_rhs))
        summary.trs_locals local_vars
      |> all_some
    in
    match
      ( local_bindings,
        summary.trs_elems
        |> List.map (tuple_return_expr_to_core arg_vars local_vars)
        |> all_some )
    with
    | Some tre_local_bindings, Some tre_elems ->
        let elem_vars = List.map (fun _ -> fresh_elem_var ()) tre_elems in
        Some
          {
            tre_arg_params = arg_params;
            tre_local_bindings;
            tre_elem_vars = elem_vars;
            tre_elems;
          }
    | _ -> None

let lower_tuple_return_call_binding summaries binding kind args body loc =
  match tuple_return_summary_for_call summaries kind with
  | None -> None
  | Some summary
    when tuple_binding_is_sroa_candidate_arity binding
           (List.length summary.trs_elems)
           body -> (
      match tuple_return_call_expansion summary args with
      | None -> None
      | Some expansion ->
          let body =
            replace_field_uses binding.bind_var expansion.tre_elem_vars
              expansion.tre_elems body
          in
          assert_removed_tuple_binding_unreferenced ~loc
            ~root_var:binding.bind_var body;
          let body =
            body
            |> bind_tuple_elements ~loc expansion.tre_elem_vars
                 expansion.tre_elems
            |> bind_core_bindings ~loc expansion.tre_local_bindings
            |> bind_call_args ~loc expansion.tre_arg_params args
          in
          Some body)
  | Some _ -> None

let lower_tuple_return_call_field summaries kind args name loc =
  match tuple_return_summary_for_call summaries kind with
  | None -> None
  | Some summary -> (
      match field_index_in_bounds (List.length summary.trs_elems) name with
      | None -> None
      | Some index -> (
          match tuple_return_call_expansion summary args with
          | None -> None
          | Some expansion ->
              let body =
                tuple_elem_ref expansion.tre_elem_vars expansion.tre_elems loc
                  index
              in
              Some
                (body
                |> bind_tuple_elements ~loc expansion.tre_elem_vars
                     expansion.tre_elems
                |> bind_core_bindings ~loc expansion.tre_local_bindings
                |> bind_call_args ~loc expansion.tre_arg_params args)))

let lower_tuple_return_call_match summaries kind args tree loc ty =
  match tuple_return_summary_for_call summaries kind with
  | None -> None
  | Some summary -> (
      match tuple_ctree_plan (List.length summary.trs_elems) tree with
      | Some plan -> (
          match tuple_return_call_expansion summary args with
          | None -> None
          | Some expansion ->
              Some
                (lower_supported_tuple_ctree ~loc ~ty expansion.tre_elem_vars
                   expansion.tre_elems
                   ~rewrite_body:(fun body -> body)
                   plan
                |> bind_tuple_elements ~loc expansion.tre_elem_vars
                     expansion.tre_elems
                |> bind_core_bindings ~loc expansion.tre_local_bindings
                |> bind_call_args ~loc expansion.tre_arg_params args))
      | None -> None)

let rec rewrite_expr ?reg ?(summaries = empty_tuple_return_summaries) expr =
  let expr = map_children (rewrite_expr ?reg ~summaries) expr in
  match expr.desc with
  | CField ({ desc = CTuple elems; _ }, name) -> (
      match field_index_in_bounds (List.length elems) name with
      | None -> expr
      | Some index ->
          let elem_vars = List.map (fun _ -> fresh_elem_var ()) elems in
          tuple_elem_ref elem_vars elems expr.loc index
          |> bind_tuple_elements ~loc:expr.loc elem_vars elems)
  | CField ({ desc = CCall (kind, _, args); _ }, name) -> (
      match lower_tuple_return_call_field summaries kind args name expr.loc with
      | Some body -> body
      | None -> expr)
  | CMatch ({ desc = CTuple elems; _ }, tree) -> (
      match tuple_ctree_plan (List.length elems) tree with
      | None -> expr
      | Some plan ->
          let elem_vars = List.map (fun _ -> fresh_elem_var ()) elems in
          lower_supported_tuple_ctree ~loc:expr.loc ~ty:expr.ty elem_vars elems
            ~rewrite_body:(fun body -> body)
            plan
          |> bind_tuple_elements ~loc:expr.loc elem_vars elems)
  | CMatch ({ desc = CCall (kind, _, args); _ }, tree) -> (
      match
        lower_tuple_return_call_match summaries kind args tree expr.loc expr.ty
      with
      | Some body -> body
      | None -> expr)
  | CLet (binding, ({ desc = _; _ } as body)) -> (
      match binding.bind_rhs.desc with
      | CTuple elems -> (
          match tuple_binding_is_sroa_candidate binding elems body with
          | false -> expr
          | true ->
              let elem_vars = List.map (fun _ -> fresh_elem_var ()) elems in
              let body =
                replace_field_uses binding.bind_var elem_vars elems body
              in
              assert_removed_tuple_binding_unreferenced ~loc:expr.loc
                ~root_var:binding.bind_var body;
              bind_tuple_elements ~loc:expr.loc elem_vars elems body)
      | CCall (kind, _, args) -> (
          match
            lower_tuple_return_call_binding summaries binding kind args body
              expr.loc
          with
          | Some body -> body
          | None -> expr)
      | CIf (cond, then_expr, else_expr) -> (
          match
            ( immediate_tuple_elements then_expr,
              immediate_tuple_elements else_expr )
          with
          | Some then_elems, Some else_elems
            when tuple_binding_is_sroa_candidate_arity binding
                   (List.length then_elems) body -> (
              match tuple_if_elements cond then_elems else_elems with
              | Some (cond_binding, elems) ->
                  let elem_vars = List.map (fun _ -> fresh_elem_var ()) elems in
                  let body =
                    replace_field_uses binding.bind_var elem_vars elems body
                  in
                  assert_removed_tuple_binding_unreferenced ~loc:expr.loc
                    ~root_var:binding.bind_var body;
                  body
                  |> bind_tuple_elements ~loc:expr.loc elem_vars elems
                  |> bind_core_bindings ~loc:expr.loc [ cond_binding ]
              | None -> expr)
          | _ -> expr)
      | CMatch (scrut, tree) -> (
          match reg with
          | Some reg -> (
              match
                lower_tuple_match_binding ~reg binding scrut tree body expr.loc
              with
              | Some body -> body
              | None -> expr)
          | None -> expr)
      | _ -> expr)
  | _ -> expr

let rewrite_func ~reg summaries f =
  { f with cf_body = Option.map (rewrite_expr ~reg ~summaries) f.cf_body }

let rec rewrite_decl ~reg summaries decl =
  let desc =
    match decl.cd_desc with
    | CDFunc f -> CDFunc (rewrite_func ~reg summaries f)
    | CDVar v ->
        CDVar { v with cv_init = rewrite_expr ~reg ~summaries v.cv_init }
    | CDImpl impl ->
        CDImpl
          {
            impl with
            ci_methods = List.map (rewrite_func ~reg summaries) impl.ci_methods;
          }
    | CDPrivate inner -> CDPrivate (rewrite_decl ~reg summaries inner)
    | CDTrait _ | CDType _ | CDRecord _ | CDImport _ | CDTypeAlias _ ->
        decl.cd_desc
  in
  { decl with cd_desc = desc }

let rewrite_program ~reg prog =
  reset_fresh ();
  let summaries = build_tuple_return_summaries ~reg prog in
  List.map (rewrite_decl ~reg summaries) prog
