(** Consuming-call specialization before Perceus.

    This pass recognizes the common owned-rewrite shape

    {[
      expr := rewrite(expr, ...)
    ]}

    for source-managed records/unions. When the called function can be proven
    not to return the same owned parameter, the pass clones the callee and adds
    a terminal [CDrop] for that parameter. Perceus then infers a consuming call
    contract for the clone and can suppress the old-slot drop around the
    reassignment.

    The pass deliberately runs before Perceus and after DCE: before Perceus so
    contract inference sees the explicit consumption, after DCE so only live
    call sites can request clones. *)

open Core

module StringSet = Set.Make (String)

type clone_request = { original : core_func; clone : core_func }

type state = {
  reg : Codegen_types.registry;
  funcs_by_identity : (string * int, core_func) Hashtbl.t;
  clones_by_key : (string * int * int, clone_request) Hashtbl.t;
}

let source_managed_type_name (reg : Codegen_types.registry) (ty : Ast.type_expr)
    : string option =
  match Core_layout_type.canonical_type ~reg ty with
  | Ast.TyNamed (name, _) -> (
      match Codegen_types.managed_type_info reg name with
      | Some
          {
            Codegen_types.managed_kind =
              Codegen_types.ManagedHeapRecord | Codegen_types.ManagedUnion;
            _;
          } ->
          Some name
      | _ -> None)
  | _ -> None

let same_type (reg : Codegen_types.registry) a b =
  Types.types_equal
    (Core_layout_type.canonical_type ~reg a)
    (Core_layout_type.canonical_type ~reg b)

let direct_variant_field_type reg scrut_ty ctor idx =
  match Core_layout_type.canonical_type ~reg scrut_ty with
  | Ast.TyNamed (type_name, _) -> (
      match Codegen_types.lookup_union_variant reg type_name ctor with
      | Some variant -> List.nth_opt variant.Ast.variant_fields idx
      | None -> None)
  | _ -> None

let update_assoc key value env = (key, value) :: List.remove_assoc key env

let rec direct_var_name = function
  | { desc = CVar v; _ } -> Some v.vname
  | { desc = CCast (inner, _) | CUnbox (inner, _) | CBox (inner, _); _ } ->
      direct_var_name inner
  | _ -> None

let known_contract_for_call_kind kind arg_count =
  Core_ownership.contract_for_call_kind kind ~arg_count

let rec consuming_arg_contains_name name arg =
  match direct_var_name arg with
  | Some vname -> String.equal vname name
  | None -> expr_consumes_name name arg

and expr_consumes_name name expr =
  match expr.desc with
  | CDrop (v, _, body) ->
      String.equal v.vname name || expr_consumes_name name body
  | CCall (kind, fn, args) ->
      let fn_consumes =
        match kind with CKClosure -> expr_consumes_name name fn | _ -> false
      in
      let arg_consumes =
        match known_contract_for_call_kind kind (List.length args) with
        | Some { Core_ownership.args = modes; _ }
          when List.length modes = List.length args ->
            List.exists2
              (fun mode arg ->
                if Core_ownership.arg_consumes_caller mode then
                  consuming_arg_contains_name name arg
                else expr_consumes_name name arg)
              modes args
        | _ -> false
      in
      fn_consumes || arg_consumes
  | CLet (b, body) ->
      expr_consumes_name name b.bind_rhs
      || (not (String.equal b.bind_var.vname name))
         && expr_consumes_name name body
  | CBorrowLet (b, body) ->
      expr_consumes_name name b.borrow_rhs
      || (not (String.equal b.borrow_var.vname name))
         && expr_consumes_name name body
  | CTensorRawViewLet (b, body) ->
      expr_consumes_name name b.trv_source || expr_consumes_name name body
  | CSeq (head, tail) ->
      expr_consumes_name name head || expr_consumes_name name tail
  | CIf (cond, then_e, else_e) ->
      expr_consumes_name name cond
      || expr_consumes_name name then_e
      || expr_consumes_name name else_e
  | CFor (binder, iter, body) ->
      expr_consumes_name name iter
      || (not (String.equal binder.loop_var.vname name))
         && expr_consumes_name name body
  | CWhile (cond, body) ->
      expr_consumes_name name cond || expr_consumes_name name body
  | CMatch (scrut, tree) ->
      expr_consumes_name name scrut || ctree_consumes_name name tree
  | CMatchArms (scrut, arms) ->
      expr_consumes_name name scrut
      || List.exists (fun (_, body) -> expr_consumes_name name body) arms
  | CLambda lam ->
      if List.exists (fun (v, _) -> String.equal v.vname name) lam.lam_params
      then false
      else expr_consumes_name name lam.lam_body
  | CTailrecLoop (TailrecUnmanagedLoop loop) ->
      if
        List.exists (fun p -> String.equal p.cp_name.vname name) loop.tul_params
      then false
      else expr_consumes_name name loop.tul_body
  | CTailrecLoop (TailrecListSpreadLoop loop) ->
      if
        String.equal loop.tls_list_param.cp_name.vname name
        || List.exists
             (fun p -> String.equal p.cp_name.vname name)
             loop.tls_params
      then false
      else expr_consumes_name name loop.tls_body
  | _ ->
      Core.fold_immediate_children
        (fun found child -> found || expr_consumes_name name child)
        false expr

and ctree_consumes_name name tree =
  match tree with
  | CTLeaf { ct_bindings; ct_body } ->
      if
        List.exists
          (fun binding -> String.equal binding.mb_var.vname name)
          ct_bindings
      then false
      else expr_consumes_name name ct_body
  | CTFail -> false
  | CTSwitchTag { cts_cases; cts_default; _ } ->
      List.exists (fun (_, sub) -> ctree_consumes_name name sub) cts_cases
      || Option.fold ~none:false ~some:(ctree_consumes_name name) cts_default
  | CTSwitchLit { ctl_cases; ctl_default; _ } ->
      List.exists (fun (_, sub) -> ctree_consumes_name name sub) ctl_cases
      || ctree_consumes_name name ctl_default
  | CTSwitchLen { ctl_len_cases; ctl_len_geq; ctl_len_default; _ } ->
      List.exists (fun (_, sub) -> ctree_consumes_name name sub) ctl_len_cases
      || Option.fold ~none:false
           ~some:(fun (_, sub) -> ctree_consumes_name name sub)
           ctl_len_geq
      || Option.fold ~none:false ~some:(ctree_consumes_name name)
           ctl_len_default

let aliases_name name aliases v =
  String.equal v.vname name
  || Option.value ~default:false (List.assoc_opt v.vname aliases)

let rec union_constructor_call_aliases_name reg name aliases expr ctor_name
    def_id args =
  match Core_layout_type.canonical_type ~reg expr.ty with
  | Ast.TyNamed (type_name, _) -> (
      let by_name =
        Codegen_types.lookup_union_variant reg type_name ctor_name
      in
      let by_id =
        match def_id with
        | None -> None
        | Some id -> (
            match
              Hashtbl.find_opt reg.Codegen_types.union_variants type_name
            with
            | None -> None
            | Some variants ->
                Hashtbl.fold
                  (fun _ (variant : Ast.variant) found ->
                    match (found, variant.variant_def_id) with
                    | Some _, _ -> found
                    | None, Some variant_id when variant_id = id -> Some variant
                    | _ -> None)
                  variants None)
      in
      match (by_name, by_id) with
      | Some _, _ | _, Some _ ->
          List.exists (result_aliases_name reg name aliases) args
      | None, None -> false)
  | _ -> false

and boxed_storage_aliases_name reg name aliases value =
  result_aliases_name reg name aliases value.bsv_box.box_value

and record_field_aliases_name reg name aliases = function
  | RecordRawField (_, value) -> result_aliases_name reg name aliases value
  | RecordErasedField (_, value) ->
      boxed_storage_aliases_name reg name aliases value

and result_aliases_name reg name aliases expr =
  match expr.desc with
  | CVar v -> aliases_name name aliases v
  | CField (owner, _) -> result_aliases_name reg name aliases owner
  | CLet (b, body) ->
      let bind_aliases = result_aliases_name reg name aliases b.bind_rhs in
      result_aliases_name reg name
        (update_assoc b.bind_var.vname bind_aliases aliases)
        body
  | CBorrowLet (b, body) ->
      let bind_aliases = result_aliases_name reg name aliases b.borrow_rhs in
      result_aliases_name reg name
        (update_assoc b.borrow_var.vname bind_aliases aliases)
        body
  | CTensorRawViewLet (b, body) ->
      let source_aliases = result_aliases_name reg name aliases b.trv_source in
      result_aliases_name reg name
        (update_assoc b.trv_var.vname source_aliases aliases)
        body
  | CSeq (_, tail)
  | CDup (_, _, tail)
  | CDrop (_, _, tail)
  | CCast (tail, _)
  | CUnbox (tail, _)
  | CBox (tail, _) ->
      result_aliases_name reg name aliases tail
  | CIf (_, then_e, else_e) ->
      result_aliases_name reg name aliases then_e
      || result_aliases_name reg name aliases else_e
  | CMatch (scrut, tree) ->
      let scrut_aliases = result_aliases_name reg name aliases scrut in
      ctree_result_aliases_name reg name aliases scrut_aliases tree
  | CMatchArms (_, arms) ->
      List.exists
        (fun (_, body) -> result_aliases_name reg name aliases body)
        arms
  | CCall (CKUnknown, _, args)
  | CCall (CKClosure, _, args)
  | CCall (CKForeign _, _, args)
  | CCall (CKBuiltin _, _, args)
  | CCall (CKIntrinsic _, _, args) ->
      (* Opaque managed call results may be borrowed aliases when they consume
         or project from an aliased argument. User calls are source-value
         boundaries and managed returns are owned by convention. *)
      List.exists (result_aliases_name reg name aliases) args
  | CCall (CKUser (ctor_name, def_id), _, args) ->
      union_constructor_call_aliases_name reg name aliases expr ctor_name def_id
        args
  | CCall (CKSelectedDirect _, _, _) -> false
  | CRecord fields ->
      List.exists
        (fun (_, value) -> result_aliases_name reg name aliases value)
        fields
  | CRecordConstruct rc ->
      List.exists (record_field_aliases_name reg name aliases) rc.rc_fields
  | CRecordUpdate (base, fields) ->
      result_aliases_name reg name aliases base
      || List.exists
           (fun (_, value) -> result_aliases_name reg name aliases value)
           fields
  | CTuple elems | CList { ll_elems = elems; _ } | CVector elems ->
      List.exists (result_aliases_name reg name aliases) elems
  | CTupleConstruct tc ->
      List.exists (boxed_storage_aliases_name reg name aliases) tc.tc_elems
  | CListConstruct lc ->
      List.exists (boxed_storage_aliases_name reg name aliases) lc.lc_elems
  | CDict entries ->
      List.exists
        (fun (key, value) ->
          result_aliases_name reg name aliases key
          || result_aliases_name reg name aliases value)
        entries
  | CDictConstruct dc ->
      List.exists
        (fun (key, value) ->
          boxed_storage_aliases_name reg name aliases key
          || boxed_storage_aliases_name reg name aliases value)
        dc.dc_entries
  | CUnionConstruct uc ->
      List.exists (boxed_storage_aliases_name reg name aliases) uc.uc_args
  | CBoxTyped box -> result_aliases_name reg name aliases box.box_value
  | CUnboxTyped unbox -> result_aliases_name reg name aliases unbox.unbox_value
  | _ -> false

and ctree_result_aliases_name reg name aliases scrut_aliases tree =
  match tree with
  | CTLeaf { ct_bindings; ct_body } ->
      let aliases =
        List.fold_left
          (fun acc binding ->
            update_assoc binding.mb_var.vname scrut_aliases acc)
          aliases ct_bindings
      in
      result_aliases_name reg name aliases ct_body
  | CTFail -> false
  | CTSwitchTag { cts_cases; cts_default; _ } ->
      List.exists
        (fun (_, sub) ->
          ctree_result_aliases_name reg name aliases scrut_aliases sub)
        cts_cases
      || Option.fold ~none:false
           ~some:(ctree_result_aliases_name reg name aliases scrut_aliases)
           cts_default
  | CTSwitchLit { ctl_cases; ctl_default; _ } ->
      List.exists
        (fun (_, sub) ->
          ctree_result_aliases_name reg name aliases scrut_aliases sub)
        ctl_cases
      || ctree_result_aliases_name reg name aliases scrut_aliases ctl_default
  | CTSwitchLen { ctl_len_cases; ctl_len_geq; ctl_len_default; _ } ->
      List.exists
        (fun (_, sub) ->
          ctree_result_aliases_name reg name aliases scrut_aliases sub)
        ctl_len_cases
      || Option.fold ~none:false
           ~some:(fun (_, sub) ->
             ctree_result_aliases_name reg name aliases scrut_aliases sub)
           ctl_len_geq
      || Option.fold ~none:false
           ~some:(ctree_result_aliases_name reg name aliases scrut_aliases)
           ctl_len_default

let function_is_cloneable state arg_index f =
  match f.cf_kind with
  | CFUser -> (
      match (f.cf_body, f.cf_type_params) with
      | Some body, [] -> (
          match List.nth_opt f.cf_params arg_index with
          | Some param ->
              source_managed_type_name state.reg param.cp_ty <> None
              && same_type state.reg param.cp_ty f.cf_return_ty
              && (not (expr_consumes_name param.cp_name.vname body))
              && not (result_aliases_name state.reg param.cp_name.vname [] body)
          | None -> false)
      | _ -> false)
  | CFBuiltin | CFForeign _ | CFClosureBody _ -> false

let clone_name original arg_index =
  Printf.sprintf "%s__consume_arg%d" original.cf_name arg_index

let clone_callee_var clone =
  { vname = clone.cf_name; vuniq = 0; vdef_id = Some clone.cf_def_id }

let rewrite_callee_expr clone callee =
  match callee.desc with
  | CVar _ -> { callee with desc = CVar (clone_callee_var clone) }
  | _ -> callee

let is_call_to_func target kind =
  match kind with
  | CKUser (_, Some def_id) -> def_id = target.cf_def_id
  | _ -> false

let direct_arg_name args index =
  match List.nth_opt args index with
  | Some arg -> direct_var_name arg
  | None -> None

type owned_use_analysis = {
  owned_use_safe : bool;
  owned_use_min_count : int;
  owned_use_max_count : int;
}

let empty_owned_use =
  { owned_use_safe = true; owned_use_min_count = 0; owned_use_max_count = 0 }

let unsafe_owned_use =
  { owned_use_safe = false; owned_use_min_count = 0; owned_use_max_count = 0 }

let seq_owned_use a b =
  {
    owned_use_safe = a.owned_use_safe && b.owned_use_safe;
    owned_use_min_count = a.owned_use_min_count + b.owned_use_min_count;
    owned_use_max_count = a.owned_use_max_count + b.owned_use_max_count;
  }

let seq_owned_uses analyses =
  List.fold_left seq_owned_use empty_owned_use analyses

let join_owned_use a b =
  {
    owned_use_safe = a.owned_use_safe && b.owned_use_safe;
    owned_use_min_count = min a.owned_use_min_count b.owned_use_min_count;
    owned_use_max_count = max a.owned_use_max_count b.owned_use_max_count;
  }

let join_owned_uses = function
  | [] -> empty_owned_use
  | first :: rest -> List.fold_left join_owned_use first rest

let allowed_owned_call_use original arg_index name kind args =
  is_call_to_func original kind
  &&
  match direct_arg_name args arg_index with
  | Some arg_name -> String.equal arg_name name
  | None -> false

let rec analyze_owned_binding_use original arg_index name expr =
  match expr.desc with
  | CVar v when String.equal v.vname name -> unsafe_owned_use
  | CDup (v, _, body) | CDrop (v, _, body) ->
      if String.equal v.vname name then unsafe_owned_use
      else analyze_owned_binding_use original arg_index name body
  | CCall (kind, fn, args)
    when allowed_owned_call_use original arg_index name kind args ->
      let callee_use =
        match kind with
        | CKClosure -> analyze_owned_binding_use original arg_index name fn
        | _ -> empty_owned_use
      in
      let arg_use = analyze_owned_call_args original arg_index name args in
      seq_owned_use
        {
          owned_use_safe = true;
          owned_use_min_count = 1;
          owned_use_max_count = 1;
        }
        (seq_owned_use callee_use arg_use)
  | CCall (kind, fn, args) ->
      let callee_use =
        match kind with
        | CKClosure -> analyze_owned_binding_use original arg_index name fn
        | _ -> empty_owned_use
      in
      seq_owned_use callee_use
        (List.map (analyze_owned_binding_use original arg_index name) args
        |> seq_owned_uses)
  | CLet (b, body) ->
      let rhs_use =
        analyze_owned_binding_use original arg_index name b.bind_rhs
      in
      if String.equal b.bind_var.vname name then rhs_use
      else
        seq_owned_use rhs_use
          (analyze_owned_binding_use original arg_index name body)
  | CBorrowLet (b, body) ->
      let rhs_use =
        analyze_owned_binding_use original arg_index name b.borrow_rhs
      in
      if String.equal b.borrow_var.vname name then rhs_use
      else
        seq_owned_use rhs_use
          (analyze_owned_binding_use original arg_index name body)
  | CTensorRawViewLet (b, body) ->
      let source_use =
        analyze_owned_binding_use original arg_index name b.trv_source
      in
      if String.equal b.trv_var.vname name then source_use
      else
        seq_owned_use source_use
          (analyze_owned_binding_use original arg_index name body)
  | CSeq (head, tail) ->
      seq_owned_use
        (analyze_owned_binding_use original arg_index name head)
        (analyze_owned_binding_use original arg_index name tail)
  | CIf (cond, then_e, else_e) ->
      seq_owned_use
        (analyze_owned_binding_use original arg_index name cond)
        (join_owned_uses
           [
             analyze_owned_binding_use original arg_index name then_e;
             analyze_owned_binding_use original arg_index name else_e;
           ])
  | CLambda lam ->
      if List.exists (fun (v, _) -> String.equal v.vname name) lam.lam_params
      then empty_owned_use
      else analyze_owned_binding_use original arg_index name lam.lam_body
  | CFor (binder, iter, body) ->
      let iter_use = analyze_owned_binding_use original arg_index name iter in
      if String.equal binder.loop_var.vname name then iter_use
      else
        seq_owned_use iter_use
          (analyze_owned_binding_use original arg_index name body)
  | CMatch (scrut, tree) ->
      seq_owned_use
        (analyze_owned_binding_use original arg_index name scrut)
        (analyze_owned_binding_use_ctree original arg_index name tree)
  | CMatchArms (scrut, arms) ->
      let scrut_use = analyze_owned_binding_use original arg_index name scrut in
      let arm_uses =
        List.map
          (fun (pat, body) ->
            if List.exists (String.equal name) (Ast.collect_pattern_vars pat)
            then empty_owned_use
            else analyze_owned_binding_use original arg_index name body)
          arms
        |> join_owned_uses
      in
      seq_owned_use scrut_use arm_uses
  | CTailrecLoop (TailrecUnmanagedLoop loop) ->
      if
        List.exists (fun p -> String.equal p.cp_name.vname name) loop.tul_params
      then empty_owned_use
      else analyze_owned_binding_use original arg_index name loop.tul_body
  | CTailrecLoop (TailrecListSpreadLoop loop) ->
      if
        String.equal loop.tls_list_param.cp_name.vname name
        || List.exists
             (fun p -> String.equal p.cp_name.vname name)
             loop.tls_params
      then empty_owned_use
      else analyze_owned_binding_use original arg_index name loop.tls_body
  | _ ->
      Core.fold_immediate_children
        (fun acc child ->
          seq_owned_use acc
            (analyze_owned_binding_use original arg_index name child))
        empty_owned_use expr

and analyze_owned_binding_use_ctree original arg_index name tree =
  match tree with
  | CTLeaf { ct_bindings; ct_body } ->
      if match_bindings_shadow name ct_bindings then empty_owned_use
      else analyze_owned_binding_use original arg_index name ct_body
  | CTFail -> empty_owned_use
  | CTSwitchTag { cts_cases; cts_default; _ } ->
      join_owned_uses
        (List.map
           (fun (_, sub) ->
             analyze_owned_binding_use_ctree original arg_index name sub)
           cts_cases
        @ [
            Option.fold ~none:empty_owned_use
              ~some:(analyze_owned_binding_use_ctree original arg_index name)
              cts_default;
          ])
  | CTSwitchLit { ctl_cases; ctl_default; _ } ->
      join_owned_uses
        (List.map
           (fun (_, sub) ->
             analyze_owned_binding_use_ctree original arg_index name sub)
           ctl_cases
        @ [
            analyze_owned_binding_use_ctree original arg_index name ctl_default;
          ])
  | CTSwitchLen { ctl_len_cases; ctl_len_geq; ctl_len_default; _ } ->
      join_owned_uses
        (List.map
           (fun (_, sub) ->
             analyze_owned_binding_use_ctree original arg_index name sub)
           ctl_len_cases
        @ [
            Option.fold ~none:empty_owned_use
              ~some:(fun (_, sub) ->
                analyze_owned_binding_use_ctree original arg_index name sub)
              ctl_len_geq;
            Option.fold ~none:empty_owned_use
              ~some:(analyze_owned_binding_use_ctree original arg_index name)
              ctl_len_default;
          ])

and analyze_owned_call_args original arg_index name args =
  List.mapi
    (fun index arg ->
      if index = arg_index then
        match direct_var_name arg with
        | Some arg_name when String.equal arg_name name -> empty_owned_use
        | _ -> analyze_owned_binding_use original arg_index name arg
      else analyze_owned_binding_use original arg_index name arg)
    args
  |> seq_owned_uses

let can_own_binding original arg_index binding body =
  match
    analyze_owned_binding_use original arg_index binding.mb_var.vname body
  with
  | { owned_use_safe = true; owned_use_min_count = 1; owned_use_max_count = 1 }
    ->
      true
  | _ -> false

let direct_owned_binding_candidate state param_ty binding =
  match (binding.mb_mode, binding.mb_accessor) with
  | MatchBorrow, AccVariantField (AccRoot, ctor, idx) -> (
      match direct_variant_field_type state.reg param_ty ctor idx with
      | Some field_ty
        when same_type state.reg field_ty param_ty
             && source_managed_type_name state.reg field_ty <> None ->
          true
      | _ -> false)
  | _ -> false

let rewrite_owned_recursive_call original clone arg_index owned_names expr =
  let rec rewrite expr =
    let expr = Core.map_children rewrite expr in
    match expr.desc with
    | CCall (kind, callee, args)
      when is_call_to_func original kind
           && Option.value ~default:false
                (Option.map
                   (fun arg_name -> StringSet.mem arg_name owned_names)
                   (direct_arg_name args arg_index)) ->
        {
          expr with
          desc =
            CCall
              ( CKUser (clone.cf_name, Some clone.cf_def_id),
                rewrite_callee_expr clone callee,
                args );
        }
    | _ -> expr
  in
  rewrite expr

let rewrite_owned_match_leaf state original clone arg_index param_ty ct_bindings
    ct_body =
  let owned_names =
    ct_bindings
    |> List.filter (direct_owned_binding_candidate state param_ty)
    |> List.filter (fun binding ->
        can_own_binding original arg_index binding ct_body)
    |> List.fold_left
         (fun names binding -> StringSet.add binding.mb_var.vname names)
         StringSet.empty
  in
  if StringSet.is_empty owned_names then (ct_bindings, ct_body)
  else
    let ct_bindings =
      List.map
        (fun binding ->
          if StringSet.mem binding.mb_var.vname owned_names then
            { binding with mb_mode = MatchOwn }
          else binding)
        ct_bindings
    in
    let ct_body =
      rewrite_owned_recursive_call original clone arg_index owned_names ct_body
    in
    (ct_bindings, ct_body)

let rec rewrite_owned_match_ctree state original clone arg_index param_ty tree =
  match tree with
  | CTLeaf { ct_bindings; ct_body } ->
      let ct_bindings, ct_body =
        rewrite_owned_match_leaf state original clone arg_index param_ty
          ct_bindings ct_body
      in
      CTLeaf { ct_bindings; ct_body }
  | CTFail -> CTFail
  | CTSwitchTag { cts_scrut; cts_cases; cts_default } ->
      CTSwitchTag
        {
          cts_scrut;
          cts_cases =
            List.map
              (fun (tag, sub) ->
                ( tag,
                  rewrite_owned_match_ctree state original clone arg_index
                    param_ty sub ))
              cts_cases;
          cts_default =
            Option.map
              (rewrite_owned_match_ctree state original clone arg_index param_ty)
              cts_default;
        }
  | CTSwitchLit { ctl_scrut; ctl_cases; ctl_default } ->
      CTSwitchLit
        {
          ctl_scrut;
          ctl_cases =
            List.map
              (fun (lit, sub) ->
                ( lit,
                  rewrite_owned_match_ctree state original clone arg_index
                    param_ty sub ))
              ctl_cases;
          ctl_default =
            rewrite_owned_match_ctree state original clone arg_index param_ty
              ctl_default;
        }
  | CTSwitchLen { ctl_len_scrut; ctl_len_cases; ctl_len_geq; ctl_len_default }
    ->
      CTSwitchLen
        {
          ctl_len_scrut;
          ctl_len_cases =
            List.map
              (fun (len, sub) ->
                ( len,
                  rewrite_owned_match_ctree state original clone arg_index
                    param_ty sub ))
              ctl_len_cases;
          ctl_len_geq =
            Option.map
              (fun (len, sub) ->
                ( len,
                  rewrite_owned_match_ctree state original clone arg_index
                    param_ty sub ))
              ctl_len_geq;
          ctl_len_default =
            Option.map
              (rewrite_owned_match_ctree state original clone arg_index param_ty)
              ctl_len_default;
        }

let rec rewrite_owned_match_expr state original clone arg_index param expr =
  let expr =
    Core.map_children
      (rewrite_owned_match_expr state original clone arg_index param)
      expr
  in
  match expr.desc with
  | CMatch (({ desc = CVar scrut; _ } as scrut_expr), tree)
    when Var.equal scrut param.cp_name ->
      {
        expr with
        desc =
          CMatch
            ( scrut_expr,
              rewrite_owned_match_ctree state original clone arg_index
                param.cp_ty tree );
      }
  | _ -> expr

let make_consuming_clone state original arg_index =
  let param =
    match List.nth_opt original.cf_params arg_index with
    | Some param -> param
    | None -> invalid_arg "make_consuming_clone: arg index out of range"
  in
  let body =
    match original.cf_body with
    | Some body -> body
    | None -> invalid_arg "make_consuming_clone: bodyless function"
  in
  let def_id = Session.mint_def_id (Session.current ()) in
  let clone =
    {
      original with
      cf_name = clone_name original arg_index;
      cf_body = None;
      cf_def_id = def_id;
    }
  in
  let body =
    rewrite_owned_match_expr state original clone arg_index param body
  in
  let result_var =
    Var.named (Printf.sprintf "__consume_result_%s" param.cp_name.vname)
  in
  let result_ref =
    { desc = CVar result_var; ty = original.cf_return_ty; loc = body.loc }
  in
  let drop_then_return =
    {
      desc = CDrop (param.cp_name, param.cp_ty, result_ref);
      ty = original.cf_return_ty;
      loc = body.loc;
    }
  in
  let clone_body =
    {
      desc =
        CLet
          ( {
              bind_var = result_var;
              bind_mut = false;
              bind_ty = original.cf_return_ty;
              bind_rhs = body;
            },
            drop_then_return );
      ty = original.cf_return_ty;
      loc = body.loc;
    }
  in
  { clone with cf_body = Some clone_body }

let clone_for state original arg_index =
  let key = (original.cf_name, original.cf_def_id, arg_index) in
  match Hashtbl.find_opt state.clones_by_key key with
  | Some request -> request.clone
  | None ->
      let clone = make_consuming_clone state original arg_index in
      let request = { original; clone } in
      Hashtbl.add state.clones_by_key key request;
      clone

let call_arg_consumes_target state target target_ty kind args =
  let candidate_indices =
    List.mapi
      (fun index arg ->
        match direct_var_name arg with
        | Some name when String.equal name target.vname -> Some index
        | _ -> None)
      args
    |> List.filter_map Fun.id
  in
  match candidate_indices with
  | [ arg_index ] -> (
      match kind with
      | CKUser (call_name, Some def_id) -> (
          match Hashtbl.find_opt state.funcs_by_identity (call_name, def_id) with
          | Some f -> (
              match List.nth_opt f.cf_params arg_index with
              | Some param
                when same_type state.reg target_ty param.cp_ty
                     && same_type state.reg target_ty f.cf_return_ty
                     && function_is_cloneable state arg_index f ->
                  Some (f, arg_index)
              | _ -> None)
          | None -> None)
      | _ -> None)
  | _ -> None

let rewrite_assignment_call state target target_ty rhs =
  match rhs.desc with
  | CCall (kind, callee, args) -> (
      match call_arg_consumes_target state target target_ty kind args with
      | Some (original, arg_index) ->
          let clone = clone_for state original arg_index in
          let kind = CKUser (clone.cf_name, Some clone.cf_def_id) in
          let callee = rewrite_callee_expr clone callee in
          { rhs with desc = CCall (kind, callee, args) }
      | None -> rhs)
  | _ -> rhs

let rec rewrite_expr state expr =
  let expr = Core.map_children (rewrite_expr state) expr in
  match expr.desc with
  | CAssign (target, rhs) -> (
      match source_managed_type_name state.reg rhs.ty with
      | Some _ ->
          {
            expr with
            desc =
              CAssign (target, rewrite_assignment_call state target rhs.ty rhs);
          }
      | None -> expr)
  | _ -> expr

let rewrite_func state f =
  { f with cf_body = Option.map (rewrite_expr state) f.cf_body }

let rec collect_function_map funcs_by_id decl =
  match decl.cd_desc with
  | CDFunc f -> Hashtbl.replace funcs_by_id (f.cf_name, f.cf_def_id) f
  | CDPrivate inner -> collect_function_map funcs_by_id inner
  | CDImpl impl ->
      List.iter
        (fun f -> Hashtbl.replace funcs_by_id (f.cf_name, f.cf_def_id) f)
        impl.ci_methods
  | _ -> ()

let make_state reg prog =
  let funcs_by_identity = Hashtbl.create 128 in
  List.iter (collect_function_map funcs_by_identity) prog;
  { reg; funcs_by_identity; clones_by_key = Hashtbl.create 32 }

let clone_decls_after state decl f =
  Hashtbl.fold
    (fun _key request acc ->
      if
        request.original.cf_name = f.cf_name
        && request.original.cf_def_id = f.cf_def_id
      then
        { cd_desc = CDFunc request.clone; cd_loc = decl.cd_loc; cd_doc = None }
        :: acc
      else acc)
    state.clones_by_key []
  |> List.sort (fun a b ->
      let af = match a.cd_desc with CDFunc f -> f.cf_name | _ -> "" in
      let bf = match b.cd_desc with CDFunc f -> f.cf_name | _ -> "" in
      String.compare af bf)

let rec rewrite_decl_body state decl =
  match decl.cd_desc with
  | CDFunc f -> { decl with cd_desc = CDFunc (rewrite_func state f) }
  | CDPrivate inner ->
      { decl with cd_desc = CDPrivate (rewrite_decl_body state inner) }
  | CDImpl impl ->
      {
        decl with
        cd_desc =
          CDImpl
            {
              impl with
              ci_methods = List.map (rewrite_func state) impl.ci_methods;
            };
      }
  | CDVar v ->
      {
        decl with
        cd_desc = CDVar { v with cv_init = rewrite_expr state v.cv_init };
      }
  | CDType _ | CDRecord _ | CDImport _ | CDTypeAlias _ | CDTrait _ -> decl

let rec insert_clones state decl =
  match decl.cd_desc with
  | CDFunc f -> decl :: clone_decls_after state decl f
  | CDPrivate ({ cd_desc = CDFunc f; _ } as inner) ->
      let clones =
        clone_decls_after state inner f
        |> List.map (fun clone_decl ->
            { clone_decl with cd_desc = CDPrivate clone_decl })
      in
      decl :: clones
  | CDPrivate inner ->
      insert_clones state inner
      |> List.map (fun inner -> { decl with cd_desc = CDPrivate inner })
  | _ -> [ decl ]

let rewrite_program ~reg prog =
  let state = make_state reg prog in
  let rewritten = List.map (rewrite_decl_body state) prog in
  List.concat_map (insert_clones state) rewritten
