(** Reuse eligibility analysis and narrow rewrites.

    This pass runs after Perceus, where [CDrop] marks last ownership use, and
    before closure conversion. It records fail-closed candidates where a dead
    managed collection is followed by a compatible fresh allocation. Rewrites
    only target collection families with explicit runtime COW/reuse boundaries
    that consume and clear the dropped owner. The matcher may scan through safe
    straight-line statements, but it fails closed on owner reads, owner RC
    operations, known intervening allocations, and non-linear control flow. *)

open Core

type collection_family = List | Dict | Set | String | Bytes

type allocation_site = {
  allocation_family : collection_family;
  allocation_name : string;
  allocation_ty : Ast.type_expr;
  allocation_loc : Ast.loc;
  allocation_list_layout : list_storage_layout option;
}

type reuse_candidate = {
  dropped_var : var;
  dropped_ty : Ast.type_expr;
  allocation_binding : var option;
  allocation : allocation_site;
  family : collection_family;
  loc : Ast.loc;
}

type interference_reason =
  | ReadsDroppedOwner
  | IncompatibleAllocation
  | DroppedOwnerUsedAfterAllocation
  | NonLinearControlFlow

type block_fact =
  | SafeBinding of var
  | SafeStatement of Ast.loc
  | FreshAllocation of var option * allocation_site
  | Interference of interference_reason * Ast.loc

type drop_block_analysis = {
  dropped_var : var;
  dropped_ty : Ast.type_expr;
  facts : block_fact list;
  candidate : reuse_candidate option;
}

type reuse_env = { reg : Codegen_types.registry }

let make_env ?reg () =
  let reg =
    match reg with Some reg -> reg | None -> Codegen_types.create_registry ()
  in
  { reg }

let reuse_phase = Core_error.Stage Core_stage.Reuse

let collection_family_to_string = function
  | List -> "list"
  | Dict -> "dict"
  | Set -> "set"
  | String -> "string"
  | Bytes -> "bytes"

let interference_reason_to_string = function
  | ReadsDroppedOwner -> "reads dropped owner"
  | IncompatibleAllocation -> "incompatible allocation"
  | DroppedOwnerUsedAfterAllocation -> "dropped owner used after allocation"
  | NonLinearControlFlow -> "nonlinear control flow"

let collection_family_of_type = function
  | Ast.TyNamed ("List", _) -> Some List
  | Ast.TyNamed ("Dict", _) -> Some Dict
  | Ast.TyNamed ("Set", _) -> Some Set
  | Ast.TyNamed ("String", []) -> Some String
  | Ast.TyNamed ("Bytes", []) -> Some Bytes
  | _ -> None

let collection_family_of_type_with_env env ty =
  match Core_layout_type.canonical_type ~reg:env.reg ty with
  | Ast.TyNamed ("List", _) -> Some List
  | Ast.TyNamed ("Dict", _) -> Some Dict
  | Ast.TyNamed ("Set", _) -> Some Set
  | Ast.TyNamed ("String", []) -> Some String
  | Ast.TyNamed ("Bytes", []) -> Some Bytes
  | _ -> None

let allocation_family_of_name = function
  | "list_alloc" -> Some List
  | "string_alloc" -> Some String
  | "bytes_alloc" -> Some Bytes
  | "set_alloc" -> Some Set
  | "blorp_set_new" | "blorp_set_new_string" | "blorp_set_new_float"
  | "blorp_set_new_custom" ->
      Some Set
  | "dict_alloc" -> Some Dict
  | "blorp_dict_new" | "blorp_dict_new_string" | "blorp_dict_new_float"
  | "blorp_dict_new_custom" | "blorp_dict_with_capacity"
  | "blorp_dict_with_capacity_string" | "blorp_dict_with_capacity_float"
  | "blorp_dict_with_capacity_custom" ->
      Some Dict
  | _ -> None

let reuse_boundary_for_family = function
  | List -> Some "list_reuse_alloc"
  | Dict -> Some "dict_reuse_alloc"
  | Set -> Some "set_reuse_alloc"
  | String | Bytes -> None

let allocation_site_of_expr (e : core) : allocation_site option =
  let allocation_name, allocation_list_layout =
    match e.desc with
    | CListAlloc alloc -> (Some "list_alloc", Some alloc.la_layout)
    | CSetAlloc _ -> (Some "set_alloc", None)
    | CDictConstruct _ -> (Some "dict_alloc", None)
    | CCall (CKIntrinsic name, _, _) | CCall (CKBuiltin name, _, _) ->
        (Some name, None)
    | _ -> (None, None)
  in
  match allocation_name with
  | Some allocation_name -> (
      match
        ( allocation_family_of_name allocation_name,
          collection_family_of_type e.ty )
      with
      | Some allocation_family, Some type_family
        when allocation_family = type_family ->
          Some
            {
              allocation_family;
              allocation_name;
              allocation_ty = e.ty;
              allocation_loc = e.loc;
              allocation_list_layout;
            }
      | _ -> None)
  | None -> None

let rec owner_touched (target : var) (e : core) : bool =
  let here =
    match e.desc with
    | CVar v -> Var.equal v target
    | CDup (v, _, _) | CDrop (v, _, _) -> Var.equal v target
    | CAssign (v, _) -> Var.equal v target
    | _ -> false
  in
  here
  ||
  match e.desc with
  | CResourceScope s ->
      owner_touched target s.rs_acquire
      || (not (Var.equal s.rs_var target))
         && (owner_touched target s.rs_body || owner_touched target s.rs_cleanup)
  | _ ->
      fold_immediate_children
        (fun touched child -> touched || owner_touched target child)
        false e

let contains_resource_scope (e : core) : bool =
  exists_tree
    (fun node -> match node.desc with CResourceScope _ -> true | _ -> false)
    e

let list_layout_of_type env ty loc =
  Core_layout_type.list_storage_layout_of_type ~reg:env.reg ty loc

let list_elem_release_policy env ty loc =
  match Core_layout_type.canonical_type ~reg:env.reg ty with
  | Ast.TyNamed ("List", [ elem_ty ]) -> (
      try
        Some
          (Core_layout_type.boxed_storage_requires_release_or_error
             ~phase:reuse_phase ~reg:env.reg elem_ty loc)
      with Core_error.Core_error _ -> None)
  | _ -> None

let compatible_list_storage_slots a b = a.lsl_slots = b.lsl_slots

let compatible_list_reuse_type env ?allocation_layout dropped_ty allocation_ty
    loc =
  match
    ( list_elem_release_policy env dropped_ty loc,
      list_elem_release_policy env allocation_ty loc )
  with
  | Some dropped_release, Some allocation_release ->
      let dropped_layout = list_layout_of_type env dropped_ty loc in
      let allocation_layout =
        Option.value allocation_layout
          ~default:(list_layout_of_type env allocation_ty loc)
      in
      compatible_list_storage_slots dropped_layout allocation_layout
      && dropped_release = allocation_release
  | _ -> false

let allocation_layout_matches_type env allocation =
  match allocation.allocation_list_layout with
  | None -> true
  | Some layout ->
      compatible_list_storage_slots layout
        (list_layout_of_type env allocation.allocation_ty
           allocation.allocation_loc)

let compatible_reuse_type env dropped_ty allocation_ty loc =
  match
    ( collection_family_of_type_with_env env dropped_ty,
      collection_family_of_type_with_env env allocation_ty )
  with
  | Some List, Some List ->
      compatible_list_reuse_type env dropped_ty allocation_ty loc
  | Some dropped_family, Some allocation_family
    when dropped_family = allocation_family ->
      Types.types_equal dropped_ty allocation_ty
  | _ -> false

let compatible_allocation env dropped_ty allocation =
  match
    ( collection_family_of_type_with_env env dropped_ty,
      allocation.allocation_family )
  with
  | Some List, List ->
      allocation_layout_matches_type env allocation
      && compatible_list_reuse_type env
           ?allocation_layout:allocation.allocation_list_layout dropped_ty
           allocation.allocation_ty allocation.allocation_loc
  | Some dropped_family, allocation_family
    when dropped_family = allocation_family ->
      Types.types_equal dropped_ty allocation.allocation_ty
  | _ -> false

let make_candidate dropped_var dropped_ty allocation_binding allocation loc =
  {
    dropped_var;
    dropped_ty;
    allocation_binding;
    allocation;
    family = allocation.allocation_family;
    loc;
  }

let analyze_drop_block_with_env env dropped_var dropped_ty body =
  let finish facts candidate =
    { dropped_var; dropped_ty; facts = List.rev facts; candidate }
  in
  let compatible allocation = compatible_allocation env dropped_ty allocation in
  let rec scan facts expr =
    match expr.desc with
    | CLet (binding, rest) -> (
        if owner_touched dropped_var binding.bind_rhs then
          finish
            (Interference (ReadsDroppedOwner, binding.bind_rhs.loc) :: facts)
            None
        else if contains_resource_scope binding.bind_rhs then
          finish
            (Interference (NonLinearControlFlow, binding.bind_rhs.loc) :: facts)
            None
        else
          match allocation_site_of_expr binding.bind_rhs with
          | Some allocation when compatible allocation ->
              let allocation_fact =
                FreshAllocation (Some binding.bind_var, allocation)
              in
              if owner_touched dropped_var rest then
                finish
                  (Interference (DroppedOwnerUsedAfterAllocation, rest.loc)
                  :: allocation_fact :: facts)
                  None
              else
                finish (allocation_fact :: facts)
                  (Some
                     (make_candidate dropped_var dropped_ty
                        (Some binding.bind_var) allocation expr.loc))
          | Some allocation ->
              finish
                (Interference (IncompatibleAllocation, allocation.allocation_loc)
                :: facts)
                None
          | None -> scan (SafeBinding binding.bind_var :: facts) rest)
    | CBorrowLet (binding, rest) ->
        if owner_touched dropped_var binding.borrow_rhs then
          finish
            (Interference (ReadsDroppedOwner, binding.borrow_rhs.loc) :: facts)
            None
        else if contains_resource_scope binding.borrow_rhs then
          finish
            (Interference (NonLinearControlFlow, binding.borrow_rhs.loc)
            :: facts)
            None
        else scan facts rest
    | CSeq (head, rest) -> (
        if owner_touched dropped_var head then
          finish (Interference (ReadsDroppedOwner, head.loc) :: facts) None
        else if contains_resource_scope head then
          finish (Interference (NonLinearControlFlow, head.loc) :: facts) None
        else
          match allocation_site_of_expr head with
          | Some allocation ->
              finish
                (Interference (IncompatibleAllocation, allocation.allocation_loc)
                :: facts)
                None
          | None -> (
              let analysis = scan (SafeStatement head.loc :: facts) rest in
              match analysis.candidate with
              | Some _ -> analysis
              | None ->
                  finish
                    (Interference (NonLinearControlFlow, expr.loc) :: facts)
                    None))
    | CResourceScope _ ->
        finish (Interference (NonLinearControlFlow, expr.loc) :: facts) None
    | _ -> finish facts None
  in
  scan [] body

let analyze_drop_block ?reg dropped_var dropped_ty body =
  analyze_drop_block_with_env (make_env ?reg ()) dropped_var dropped_ty body

let candidate_for_drop_with_env env dropped_var dropped_ty body =
  (analyze_drop_block_with_env env dropped_var dropped_ty body).candidate

let var_expr loc v ty = { desc = CVar v; ty; loc }

let int_expr loc n =
  {
    desc = CLit (Ast.LitInt (Int64.of_int n));
    ty = Ast.TyNamed ("Int", []);
    loc;
  }

let reuse_boundary_call bind_rhs dropped_var dropped_ty reuse_name capacity =
  {
    bind_rhs with
    desc =
      CCall
        ( CKIntrinsic reuse_name,
          { bind_rhs with desc = CVoid; ty = Ast.TyNamed ("Void", []) },
          [ var_expr bind_rhs.loc dropped_var dropped_ty; capacity ] );
  }

let reuse_alloc_rhs env dropped_var dropped_ty bind_rhs =
  match allocation_site_of_expr bind_rhs with
  | Some allocation when compatible_allocation env dropped_ty allocation -> (
      match
        (reuse_boundary_for_family allocation.allocation_family, bind_rhs.desc)
      with
      | Some reuse_name, CListAlloc alloc ->
          Some
            (reuse_boundary_call bind_rhs dropped_var dropped_ty reuse_name
               alloc.la_capacity)
      | Some reuse_name, CSetAlloc _ ->
          Some
            (reuse_boundary_call bind_rhs dropped_var dropped_ty reuse_name
               (int_expr bind_rhs.loc 0))
      | Some reuse_name, CDictConstruct { dc_entries = []; _ } ->
          Some
            (reuse_boundary_call bind_rhs dropped_var dropped_ty reuse_name
               (int_expr bind_rhs.loc 0))
      | Some reuse_name, CCall ((CKIntrinsic _ | CKBuiltin _), callee, [ cap ])
        ->
          Some
            {
              bind_rhs with
              desc =
                CCall
                  ( CKIntrinsic reuse_name,
                    callee,
                    [ var_expr bind_rhs.loc dropped_var dropped_ty; cap ] );
            }
      | Some reuse_name, CCall ((CKIntrinsic _ | CKBuiltin _), _, []) ->
          Some
            (reuse_boundary_call bind_rhs dropped_var dropped_ty reuse_name
               (int_expr bind_rhs.loc 0))
      | _ -> None)
  | _ -> None

let is_var_ref expected e =
  match e.desc with CVar got -> Var.equal expected got | _ -> false

let handoff_layout_matches_type env h loc =
  compatible_list_storage_slots h.lh_layout
    (list_layout_of_type env h.lh_result_ty loc)

let consume_handoff_rhs env dropped_var dropped_ty bind_rhs =
  match bind_rhs.desc with
  | CListHandoff h
    when h.lh_mode = BorrowFresh
         && is_var_ref dropped_var h.lh_source
         && compatible_reuse_type env dropped_ty h.lh_source_ty bind_rhs.loc
         && compatible_reuse_type env dropped_ty h.lh_result_ty bind_rhs.loc
         && handoff_layout_matches_type env h bind_rhs.loc
         && (not (owner_touched dropped_var h.lh_capacity))
         && not (owner_touched dropped_var h.lh_body) ->
      Some
        { bind_rhs with desc = CListHandoff { h with lh_mode = ConsumeReuse } }
  | _ -> None

let rec rewrite_expr env (e : core) : core =
  match e.desc with
  | CLet (binding, { desc = CDrop (dropped_var, dropped_ty, result); _ }) ->
      if is_var_ref binding.bind_var result then
        match
          consume_handoff_rhs env dropped_var dropped_ty binding.bind_rhs
        with
        | Some handoff -> rewrite_expr env handoff
        | None -> (
            match
              consume_handoff_in_linear_expr env dropped_var dropped_ty
                binding.bind_rhs
            with
            | Some bind_rhs -> rewrite_expr env bind_rhs
            | None -> map_children (rewrite_expr env) e)
      else map_children (rewrite_expr env) e
  | CDrop (dropped_var, dropped_ty, body) -> (
      match rewrite_drop_body env dropped_var dropped_ty body with
      | Some rewritten -> rewritten
      | None ->
          {
            e with
            desc = CDrop (dropped_var, dropped_ty, rewrite_expr env body);
          })
  | _ -> map_children (rewrite_expr env) e

and consume_handoff_in_linear_expr env dropped_var dropped_ty expr =
  let rec scan expr =
    match expr.desc with
    | CLet (binding, rest) -> (
        match
          consume_handoff_rhs env dropped_var dropped_ty binding.bind_rhs
        with
        | Some bind_rhs ->
            if owner_touched dropped_var rest then
              match scan rest with
              | Some rest' ->
                  Some
                    {
                      expr with
                      desc =
                        CLet
                          ( {
                              binding with
                              bind_rhs = rewrite_expr env binding.bind_rhs;
                            },
                            rest' );
                    }
              | None -> None
            else
              Some
                {
                  expr with
                  desc = CLet ({ binding with bind_rhs }, rewrite_expr env rest);
                }
        | None -> (
            if owner_touched dropped_var binding.bind_rhs then
              if owner_touched dropped_var rest then None
              else
                match scan binding.bind_rhs with
                | Some bind_rhs ->
                    Some
                      {
                        expr with
                        desc =
                          CLet ({ binding with bind_rhs }, rewrite_expr env rest);
                      }
                | None -> None
            else if contains_resource_scope binding.bind_rhs then None
            else
              match scan rest with
              | Some rest' ->
                  Some
                    {
                      expr with
                      desc =
                        CLet
                          ( {
                              binding with
                              bind_rhs = rewrite_expr env binding.bind_rhs;
                            },
                            rest' );
                    }
              | None -> None))
    | CBorrowLet (binding, rest) -> (
        if owner_touched dropped_var binding.borrow_rhs then None
        else if contains_resource_scope binding.borrow_rhs then None
        else
          match scan rest with
          | Some rest' ->
              Some
                {
                  expr with
                  desc =
                    CBorrowLet
                      ( {
                          binding with
                          borrow_rhs = rewrite_expr env binding.borrow_rhs;
                        },
                        rest' );
                }
          | None -> None)
    | CSeq (head, rest) -> (
        if owner_touched dropped_var head then None
        else if contains_resource_scope head then None
        else
          match scan rest with
          | Some rest' ->
              Some { expr with desc = CSeq (rewrite_expr env head, rest') }
          | None -> None)
    | CResourceScope _ -> None
    | _ -> None
  in
  scan expr

and rewrite_drop_body env dropped_var dropped_ty body =
  let compatible allocation = compatible_allocation env dropped_ty allocation in
  let rec scan expr =
    match expr.desc with
    | CLet (binding, rest) -> (
        if owner_touched dropped_var binding.bind_rhs then None
        else if contains_resource_scope binding.bind_rhs then None
        else
          match allocation_site_of_expr binding.bind_rhs with
          | Some allocation when compatible allocation -> (
              if owner_touched dropped_var rest then None
              else
                match
                  reuse_alloc_rhs env dropped_var dropped_ty binding.bind_rhs
                with
                | Some bind_rhs ->
                    Some
                      {
                        expr with
                        desc =
                          CLet ({ binding with bind_rhs }, rewrite_expr env rest);
                      }
                | None -> None)
          | Some _ -> None
          | None -> (
              match scan rest with
              | Some rest' ->
                  Some
                    {
                      expr with
                      desc =
                        CLet
                          ( {
                              binding with
                              bind_rhs = rewrite_expr env binding.bind_rhs;
                            },
                            rest' );
                    }
              | None -> None))
    | CBorrowLet (binding, rest) -> (
        if owner_touched dropped_var binding.borrow_rhs then None
        else if contains_resource_scope binding.borrow_rhs then None
        else
          match scan rest with
          | Some rest' ->
              Some
                {
                  expr with
                  desc =
                    CBorrowLet
                      ( {
                          binding with
                          borrow_rhs = rewrite_expr env binding.borrow_rhs;
                        },
                        rest' );
                }
          | None -> None)
    | CSeq (head, rest) -> (
        if owner_touched dropped_var head then None
        else if contains_resource_scope head then None
        else
          match allocation_site_of_expr head with
          | Some _ -> None
          | None -> (
              match scan rest with
              | Some rest' ->
                  Some { expr with desc = CSeq (rewrite_expr env head, rest') }
              | None -> None))
    | CResourceScope _ -> None
    | _ -> None
  in
  scan body

let analyze_expr ?reg (e : core) : reuse_candidate list =
  let env = make_env ?reg () in
  fold_tree
    (fun acc node ->
      match node.desc with
      | CDrop (dropped_var, dropped_ty, body) -> (
          match candidate_for_drop_with_env env dropped_var dropped_ty body with
          | Some candidate -> candidate :: acc
          | None -> acc)
      | _ -> acc)
    [] e
  |> List.rev

let rewrite_decl env (d : core_decl) : core_decl =
  let rec go d =
    let cd_desc =
      match d.cd_desc with
      | CDFunc f ->
          CDFunc { f with cf_body = Option.map (rewrite_expr env) f.cf_body }
      | CDVar v -> CDVar { v with cv_init = rewrite_expr env v.cv_init }
      | CDImpl impl ->
          CDImpl
            {
              impl with
              ci_methods =
                List.map
                  (fun f ->
                    { f with cf_body = Option.map (rewrite_expr env) f.cf_body })
                  impl.ci_methods;
            }
      | CDPrivate inner -> CDPrivate (go inner)
      | CDTrait _ | CDType _ | CDRecord _ | CDImport _ | CDTypeAlias _ ->
          d.cd_desc
    in
    { d with cd_desc }
  in
  go d

let rewrite_program ?reg (prog : core_program) : core_program =
  let env = make_env ?reg () in
  List.map (rewrite_decl env) prog
