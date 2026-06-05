(** Reuse eligibility analysis and narrow rewrites.

    This pass runs after Perceus, where [CDrop] marks last ownership use, and
    before closure conversion. It records fail-closed candidates where a dead
    managed collection or managed union is followed by a compatible fresh
    allocation. Rewrites only target families with explicit runtime COW/reuse
    boundaries that consume and clear the dropped owner. The matcher may scan
    through safe straight-line statements, but it fails closed on owner reads,
    owner RC operations, known intervening allocations, and non-linear control
    flow. *)

open Core

type collection_family =
  | List
  | Dict
  | Set
  | String
  | Bytes
  | ManagedUnion of string

type managed_constructor_allocation = {
  managed_type_name : string;
  managed_constructor_name : string;
  managed_constructor_def_id : int option;
  managed_constructor_tag : int;
  managed_constructor_arity : int;
}

type allocation_site = {
  allocation_family : collection_family;
  allocation_name : string;
  allocation_ty : Ast.type_expr;
  allocation_loc : Ast.loc;
  allocation_list_layout : list_storage_layout option;
  allocation_managed_constructor : managed_constructor_allocation option;
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
  | ManagedUnion name -> "managed-union:" ^ name

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
  | Ast.TyNamed (name, _) -> (
      match Codegen_types.managed_type_info env.reg name with
      | Some { managed_kind = ManagedUnion; _ } -> Some (ManagedUnion name)
      | _ -> None)
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
  | String | Bytes | ManagedUnion _ -> None

let constructor_identity_matches (variant : Ast.variant) def_id =
  match (variant.variant_def_id, def_id) with
  | Some expected, Some actual -> expected = actual
  | None, None -> true
  | _ -> false

let managed_union_constructor_site env (e : core) : allocation_site option =
  match (e.desc, Core_layout_type.canonical_type ~reg:env.reg e.ty) with
  | CCall (CKUser (ctor_name, def_id), _, args), Ast.TyNamed (type_name, _) -> (
      match Codegen_types.managed_type_info env.reg type_name with
      | Some { managed_kind = ManagedUnion; _ } -> (
          match
            Codegen_types.lookup_union_variant env.reg type_name ctor_name
          with
          | Some variant
            when constructor_identity_matches variant def_id
                 && List.length variant.variant_fields = List.length args ->
              Some
                {
                  allocation_family = ManagedUnion type_name;
                  allocation_name = ctor_name;
                  allocation_ty = e.ty;
                  allocation_loc = e.loc;
                  allocation_list_layout = None;
                  allocation_managed_constructor =
                    Some
                      {
                        managed_type_name = type_name;
                        managed_constructor_name = ctor_name;
                        managed_constructor_def_id = def_id;
                        managed_constructor_tag = variant.variant_tag;
                        managed_constructor_arity = List.length args;
                      };
                }
          | _ -> None)
      | _ -> None)
  | CUnionConstruct uc, Ast.TyNamed (type_name, _) -> (
      match Codegen_types.managed_type_info env.reg type_name with
      | Some { managed_kind = ManagedUnion; _ }
        when String.equal type_name uc.uc_type_name ->
          Some
            {
              allocation_family = ManagedUnion type_name;
              allocation_name = uc.uc_constructor_name;
              allocation_ty = e.ty;
              allocation_loc = e.loc;
              allocation_list_layout = None;
              allocation_managed_constructor =
                Some
                  {
                    managed_type_name = type_name;
                    managed_constructor_name = uc.uc_constructor_name;
                    managed_constructor_def_id = None;
                    managed_constructor_tag = uc.uc_tag;
                    managed_constructor_arity = List.length uc.uc_args;
                  };
            }
      | _ -> None)
  | _ -> None

let allocation_site_of_expr env (e : core) : allocation_site option =
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
              allocation_managed_constructor = None;
            }
      | _ -> managed_union_constructor_site env e)
  | None -> managed_union_constructor_site env e

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
  | Some (ManagedUnion dropped_name), Some (ManagedUnion allocation_name)
    when String.equal dropped_name allocation_name ->
      Types.types_equal dropped_ty allocation_ty
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
  | Some (ManagedUnion dropped_name), ManagedUnion allocation_name
    when String.equal dropped_name allocation_name ->
      Types.types_equal dropped_ty allocation.allocation_ty
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
          match allocation_site_of_expr env binding.bind_rhs with
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
          match allocation_site_of_expr env head with
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
  match allocation_site_of_expr env bind_rhs with
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
          match allocation_site_of_expr env binding.bind_rhs with
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
          match allocation_site_of_expr env head with
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

let prepared_union_type_name env ty =
  match Core_layout_type.canonical_type ~reg:env.reg ty with
  | Ast.TyNamed (name, _) -> (
      match Codegen_types.managed_type_info env.reg name with
      | Some { managed_kind = ManagedUnion; _ } -> Some name
      | _ -> None)
  | _ -> None

let source_field_requires_release env ty loc =
  try
    Core_layout_type.source_value_requires_release_or_error ~phase:reuse_phase
      ~reg:env.reg ty loc
  with Core_error.Core_error _ -> false

let direct_owned_field_binding ctor idx binding =
  match (binding.mb_mode, binding.mb_accessor) with
  | MatchOwn, AccVariantField (AccRoot, binding_ctor, binding_idx) ->
      String.equal ctor binding_ctor && idx = binding_idx
  | _ -> false

let leaf_owns_managed_variant_fields env type_name ctor ct_bindings loc =
  match Codegen_types.lookup_union_variant env.reg type_name ctor with
  | None -> false
  | Some variant ->
      variant.variant_fields
      |> List.mapi (fun idx field_ty -> (idx, field_ty))
      |> List.for_all (fun (idx, field_ty) ->
          (not (source_field_requires_release env field_ty loc))
          || List.exists (direct_owned_field_binding ctor idx) ct_bindings)

let union_reuse_construct source uc =
  CUnionReuseConstruct
    {
      urc_source = source;
      urc_type_name = uc.uc_type_name;
      urc_constructor_name = uc.uc_constructor_name;
      urc_c_name = uc.uc_c_name;
      urc_reuse_c_name =
        Codegen_names.union_reuse_constructor_name ~type_name:uc.uc_type_name
          ~constructor_c_name:uc.uc_c_name;
      urc_tag = uc.uc_tag;
      urc_representation = uc.uc_representation;
      urc_args = uc.uc_args;
      urc_release_mask = uc.uc_release_mask;
    }

let update_bool_assoc key value env = (key, value) :: List.remove_assoc key env

let rec result_may_alias_source source_name aliases expr =
  match expr.desc with
  | CVar v ->
      String.equal v.vname source_name
      || Option.value ~default:false (List.assoc_opt v.vname aliases)
  | CCast (inner, _) | CUnbox (inner, _) | CBox (inner, _) ->
      result_may_alias_source source_name aliases inner
  | CBoxTyped box -> result_may_alias_source source_name aliases box.box_value
  | CUnboxTyped unbox ->
      result_may_alias_source source_name aliases unbox.unbox_value
  | CLet (binding, body) ->
      String.equal binding.bind_var.vname source_name
      ||
      let binding_aliases =
        result_may_alias_source source_name aliases binding.bind_rhs
      in
      result_may_alias_source source_name
        (update_bool_assoc binding.bind_var.vname binding_aliases aliases)
        body
  | CBorrowLet (binding, body) ->
      String.equal binding.borrow_var.vname source_name
      ||
      let binding_aliases =
        result_may_alias_source source_name aliases binding.borrow_rhs
      in
      result_may_alias_source source_name
        (update_bool_assoc binding.borrow_var.vname binding_aliases aliases)
        body
  | CSeq (_, tail) | CDup (_, _, tail) | CDrop (_, _, tail) ->
      result_may_alias_source source_name aliases tail
  | CIf (_, then_e, else_e) ->
      result_may_alias_source source_name aliases then_e
      || result_may_alias_source source_name aliases else_e
  | CMatch (_, tree) -> ctree_result_may_alias_source source_name aliases tree
  | CMatchArms (_, arms) ->
      List.exists
        (fun (_, body) -> result_may_alias_source source_name aliases body)
        arms
  | CUnionConstruct uc ->
      List.exists
        (fun arg ->
          result_may_alias_source source_name aliases arg.bsv_box.box_value)
        uc.uc_args
  | CUnionReuseConstruct urc ->
      result_may_alias_source source_name aliases urc.urc_source
      || List.exists
           (fun arg ->
             result_may_alias_source source_name aliases arg.bsv_box.box_value)
           urc.urc_args
  | CRecord fields ->
      List.exists
        (fun (_, value) -> result_may_alias_source source_name aliases value)
        fields
  | CRecordConstruct rc ->
      List.exists
        (function
          | RecordRawField (_, value) ->
              result_may_alias_source source_name aliases value
          | RecordErasedField (_, value) ->
              result_may_alias_source source_name aliases
                value.bsv_box.box_value)
        rc.rc_fields
  | CRecordUpdate (base, fields) ->
      result_may_alias_source source_name aliases base
      || List.exists
           (fun (_, value) -> result_may_alias_source source_name aliases value)
           fields
  | CTuple elems | CList { ll_elems = elems; _ } | CVector elems ->
      List.exists (result_may_alias_source source_name aliases) elems
  | CTupleConstruct tc ->
      List.exists
        (fun elem ->
          result_may_alias_source source_name aliases elem.bsv_box.box_value)
        tc.tc_elems
  | CListConstruct lc ->
      List.exists
        (fun elem ->
          result_may_alias_source source_name aliases elem.bsv_box.box_value)
        lc.lc_elems
  | CDict entries ->
      List.exists
        (fun (key, value) ->
          result_may_alias_source source_name aliases key
          || result_may_alias_source source_name aliases value)
        entries
  | CDictConstruct dc ->
      List.exists
        (fun (key, value) ->
          result_may_alias_source source_name aliases key.bsv_box.box_value
          || result_may_alias_source source_name aliases value.bsv_box.box_value)
        dc.dc_entries
  | CCall (_, _, args) ->
      List.exists (result_may_alias_source source_name aliases) args
  | _ ->
      Core.fold_immediate_children
        (fun aliases_source child ->
          aliases_source || result_may_alias_source source_name aliases child)
        false expr

and ctree_result_may_alias_source source_name aliases tree =
  match tree with
  | CTLeaf { ct_bindings; ct_body } ->
      let aliases =
        List.fold_left
          (fun aliases binding ->
            update_bool_assoc binding.mb_var.vname false aliases)
          aliases ct_bindings
      in
      result_may_alias_source source_name aliases ct_body
  | CTFail -> false
  | CTSwitchTag { cts_cases; cts_default; _ } ->
      List.exists
        (fun (_, sub) -> ctree_result_may_alias_source source_name aliases sub)
        cts_cases
      || Option.fold ~none:false
           ~some:(ctree_result_may_alias_source source_name aliases)
           cts_default
  | CTSwitchLit { ctl_cases; ctl_default; _ } ->
      List.exists
        (fun (_, sub) -> ctree_result_may_alias_source source_name aliases sub)
        ctl_cases
      || ctree_result_may_alias_source source_name aliases ctl_default
  | CTSwitchLen { ctl_len_cases; ctl_len_geq; ctl_len_default; _ } ->
      List.exists
        (fun (_, sub) -> ctree_result_may_alias_source source_name aliases sub)
        ctl_len_cases
      || Option.fold ~none:false
           ~some:(fun (_, sub) ->
             ctree_result_may_alias_source source_name aliases sub)
           ctl_len_geq
      || Option.fold ~none:false
           ~some:(ctree_result_may_alias_source source_name aliases)
           ctl_len_default

let union_construct_args_alias_source source_name aliases uc =
  List.exists
    (fun arg ->
      result_may_alias_source source_name aliases arg.bsv_box.box_value)
    uc.uc_args

let rec rewrite_prepared_union_result source source_name aliases type_name expr
    =
  match expr.desc with
  | CUnionConstruct uc
    when String.equal uc.uc_type_name type_name
         && uc.uc_representation = GenericUnion
         && not (union_construct_args_alias_source source_name aliases uc) ->
      Some { expr with desc = union_reuse_construct source uc }
  | CIf (cond, then_e, else_e) -> (
      match
        ( rewrite_prepared_union_result source source_name aliases type_name
            then_e,
          rewrite_prepared_union_result source source_name aliases type_name
            else_e )
      with
      | Some then_e, Some else_e ->
          Some { expr with desc = CIf (cond, then_e, else_e) }
      | _ -> None)
  | CLet (binding, body) ->
      if String.equal binding.bind_var.vname source_name then None
      else
        let aliases =
          update_bool_assoc binding.bind_var.vname
            (result_may_alias_source source_name aliases binding.bind_rhs)
            aliases
        in
        Option.map
          (fun body -> { expr with desc = CLet (binding, body) })
          (rewrite_prepared_union_result source source_name aliases type_name
             body)
  | CBorrowLet (binding, body) ->
      if String.equal binding.borrow_var.vname source_name then None
      else
        let aliases =
          update_bool_assoc binding.borrow_var.vname
            (result_may_alias_source source_name aliases binding.borrow_rhs)
            aliases
        in
        Option.map
          (fun body -> { expr with desc = CBorrowLet (binding, body) })
          (rewrite_prepared_union_result source source_name aliases type_name
             body)
  | CSeq (head, tail) ->
      Option.map
        (fun tail -> { expr with desc = CSeq (head, tail) })
        (rewrite_prepared_union_result source source_name aliases type_name tail)
  | _ -> None

let rec rewrite_prepared_match_tree env source source_name type_name
    current_ctor tree =
  match tree with
  | CTLeaf { ct_bindings; ct_body } -> (
      match current_ctor with
      | Some ctor
        when leaf_owns_managed_variant_fields env type_name ctor ct_bindings
               ct_body.loc -> (
          match
            rewrite_prepared_union_result source source_name [] type_name
              ct_body
          with
          | Some ct_body -> Some (CTLeaf { ct_bindings; ct_body })
          | None -> None)
      | _ -> None)
  | CTFail -> Some CTFail
  | CTSwitchTag { cts_scrut; cts_cases; cts_default } ->
      let rewrite_case (ctor, sub) =
        let leaf_ctor =
          match cts_scrut with AccRoot -> Some ctor | _ -> current_ctor
        in
        Option.map
          (fun sub -> (ctor, sub))
          (rewrite_prepared_match_tree env source source_name type_name
             leaf_ctor sub)
      in
      let cases = List.map rewrite_case cts_cases in
      if List.exists Option.is_none cases then None
      else
        let default =
          match cts_default with
          | None -> Some None
          | Some tree ->
              Option.map
                (fun tree -> Some tree)
                (rewrite_prepared_match_tree env source source_name type_name
                   current_ctor tree)
        in
        Option.map
          (fun cts_default ->
            CTSwitchTag
              {
                cts_scrut;
                cts_cases = List.filter_map Fun.id cases;
                cts_default;
              })
          default
  | CTSwitchLit { ctl_scrut; ctl_cases; ctl_default } ->
      let rewrite_case (lit, sub) =
        Option.map
          (fun sub -> (lit, sub))
          (rewrite_prepared_match_tree env source source_name type_name
             current_ctor sub)
      in
      let cases = List.map rewrite_case ctl_cases in
      if List.exists Option.is_none cases then None
      else
        Option.map
          (fun ctl_default ->
            CTSwitchLit
              {
                ctl_scrut;
                ctl_cases = List.filter_map Fun.id cases;
                ctl_default;
              })
          (rewrite_prepared_match_tree env source source_name type_name
             current_ctor ctl_default)
  | CTSwitchLen { ctl_len_scrut; ctl_len_cases; ctl_len_geq; ctl_len_default }
    ->
      let rewrite_case (len, sub) =
        Option.map
          (fun sub -> (len, sub))
          (rewrite_prepared_match_tree env source source_name type_name
             current_ctor sub)
      in
      let cases = List.map rewrite_case ctl_len_cases in
      if List.exists Option.is_none cases then None
      else
        let geq =
          match ctl_len_geq with
          | None -> Some None
          | Some (len, sub) ->
              Option.map
                (fun sub -> Some (len, sub))
                (rewrite_prepared_match_tree env source source_name type_name
                   current_ctor sub)
        in
        let default =
          match ctl_len_default with
          | None -> Some None
          | Some sub ->
              Option.map
                (fun sub -> Some sub)
                (rewrite_prepared_match_tree env source source_name type_name
                   current_ctor sub)
        in
        Option.bind geq (fun ctl_len_geq ->
            Option.map
              (fun ctl_len_default ->
                CTSwitchLen
                  {
                    ctl_len_scrut;
                    ctl_len_cases = List.filter_map Fun.id cases;
                    ctl_len_geq;
                    ctl_len_default;
                  })
              default)

let rewrite_prepared_drop_result env binding dropped_var dropped_ty result =
  match result.desc with
  | CVar result_var when Var.equal binding.bind_var result_var -> (
      match
        (prepared_union_type_name env dropped_ty, binding.bind_rhs.desc)
      with
      | Some type_name, CMatch (({ desc = CVar scrut; _ } as source), tree)
        when Var.equal dropped_var scrut -> (
          match
            rewrite_prepared_match_tree env source scrut.vname type_name None
              tree
          with
          | Some tree ->
              Some { binding.bind_rhs with desc = CMatch (source, tree) }
          | None -> None)
      | _ -> None)
  | _ -> None

let rec rewrite_prepared_expr env expr =
  let expr = Core.map_children (rewrite_prepared_expr env) expr in
  match expr.desc with
  | CLet (binding, { desc = CDrop (dropped_var, dropped_ty, result); _ }) -> (
      match
        rewrite_prepared_drop_result env binding dropped_var dropped_ty result
      with
      | Some rewritten -> rewritten
      | None -> expr)
  | _ -> expr

let rewrite_prepared_decl env (d : core_decl) : core_decl =
  let rec go d =
    let cd_desc =
      match d.cd_desc with
      | CDFunc f ->
          CDFunc
            {
              f with
              cf_body = Option.map (rewrite_prepared_expr env) f.cf_body;
            }
      | CDVar v ->
          CDVar { v with cv_init = rewrite_prepared_expr env v.cv_init }
      | CDImpl impl ->
          CDImpl
            {
              impl with
              ci_methods =
                List.map
                  (fun f ->
                    {
                      f with
                      cf_body = Option.map (rewrite_prepared_expr env) f.cf_body;
                    })
                  impl.ci_methods;
            }
      | CDPrivate inner -> CDPrivate (go inner)
      | CDTrait _ | CDType _ | CDRecord _ | CDImport _ | CDTypeAlias _ ->
          d.cd_desc
    in
    { d with cd_desc }
  in
  go d

let rewrite_prepared_program ?reg (prog : core_program) : core_program =
  let env = make_env ?reg () in
  List.map (rewrite_prepared_decl env) prog
