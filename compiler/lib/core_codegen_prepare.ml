(** Final Core preparation.

    This pass moves representation decisions that used to live in
    [Core_emit] into explicit Core nodes. After this pass, collection
    constructors, record constructors, union constructors, and boxed storage
    operations carry the layout/ownership facts the C emitter needs. *)

open Core

type env = {
  reg : Codegen_types.registry;
  record_decls : (string, Ast.record_decl) Hashtbl.t;
  variants_by_type : (string, (string, Ast.variant) Hashtbl.t) Hashtbl.t;
}

let phase = Core_error.Stage Core_stage.Final

let boxed_storage_needs_release ~reg ty loc =
  Core_layout_type.boxed_storage_requires_release_or_error ~phase ~reg ty loc

let canonical_type ~reg ty = Core_layout_type.canonical_type ~reg ty

let type_requires_retain ~reg ty loc =
  Core_layout_type.source_value_requires_retain_or_error ~phase ~reg ty loc

let classify_box_kind ~reg ty loc =
  Core_layout_type.box_kind_of_type ~phase ~reg ty loc

let classify_unbox_kind ~reg ty loc =
  Core_layout_type.unbox_kind_of_type ~phase ~reg ty loc

let make_box_op ~reg value source_ty =
  {
    box_value = value;
    box_source_ty = source_ty;
    box_kind = classify_box_kind ~reg source_ty value.loc;
  }

let boxed_expr_transfers_ownership ~reg (expr : core) =
  match expr.desc with
  | CBox (_, source_ty) -> boxed_storage_needs_release ~reg source_ty expr.loc
  | CBoxTyped b -> boxed_storage_needs_release ~reg b.box_source_ty expr.loc
  | CVar _ | CField _ | CUnbox _ | CUnboxTyped _ | CLit (Ast.LitString _) -> (
      match classify_box_kind ~reg expr.ty expr.loc with
      | BoxStruct _ -> true
      | _ -> false)
  | _ -> boxed_storage_needs_release ~reg expr.ty expr.loc

let boxed_storage_value ~reg (expr : core) =
  let box =
    match expr.desc with
    | CBox (value, source_ty) -> make_box_op ~reg value source_ty
    | CBoxTyped b -> b
    | _ -> make_box_op ~reg expr expr.ty
  in
  {
    bsv_box = box;
    bsv_needs_release =
      boxed_storage_needs_release ~reg box.box_source_ty expr.loc;
    bsv_transfers_ownership = boxed_expr_transfers_ownership ~reg expr;
  }

let tuple_field_needs_retain ~reg (field : core) =
  boxed_storage_needs_release ~reg field.ty field.loc
  &&
  match field.desc with
  | CField _ | CUnbox _ | CUnboxTyped _ | CLit (Ast.LitString _) -> true
  | _ -> false

let release_mask values =
  values
  |> List.mapi (fun i v -> if v.bsv_needs_release then 1 lsl i else 0)
  |> List.fold_left ( lor ) 0

let retain_mask ~reg fields =
  fields
  |> List.mapi (fun i f ->
      if tuple_field_needs_retain ~reg f then 1 lsl i else 0)
  |> List.fold_left ( lor ) 0

let dict_value_needs_release ~reg dict_ty loc =
  match canonical_type ~reg dict_ty with
  | Ast.TyNamed ("Dict", [ _key_ty; value_ty ]) ->
      boxed_storage_needs_release ~reg value_ty loc
  | _ -> false

let tensor_literal_payload_for_elem_type ~reg elem_ty elems =
  match Core_layout_type.tensor_element_storage ~reg elem_ty with
  | Core_layout_type.TensorElementInlineStruct c_ty ->
      TensorInlineStructElements (c_ty, elems)
  | Core_layout_type.TensorElementRawScalar scalar ->
      TensorRawElements (scalar, elems)
  | Core_layout_type.TensorElementPackedBits width ->
      TensorPackedElements (width, elems)
  | Core_layout_type.TensorElementBoxed ->
      TensorBoxedElements (List.map (boxed_storage_value ~reg) elems)

let dict_constructor_for_key ~reg key_ty =
  Core_hash_container_layout.dict_constructor_kind ~reg key_ty

let set_constructor_for_elem ~reg elem_ty =
  Core_hash_container_layout.set_constructor_kind ~reg elem_ty

let zero_capacity loc =
  { desc = CLit (Ast.LitInt 0L); ty = Ast.TyNamed ("Int", []); loc }

let is_erased_record_field ~reg ty =
  Core_layout_type.record_field_uses_erased_storage ~reg ty

let tensor_type_of_expr env (expr : core) =
  Core_tensor_type.of_core ~reg:env.reg expr

let is_tensor_type env ty = Core_tensor_type.is_type ~reg:env.reg ty

let tensor_type_or_error env (expr : core) =
  match tensor_type_of_expr env expr with
  | Some tensor_ty -> tensor_ty
  | None ->
      Core_error.errorf phase expr.loc
        ~hint:
          "CVector nodes should only reach final Core preparation with a \
           tensor, vector, or matrix semantic type"
        "final Core preparation saw tensor literal with non-tensor type `%s`"
        (Types.type_to_string expr.ty)

let type_name_or_error ~reg ty loc =
  match canonical_type ~reg ty with
  | Ast.TyNamed (name, _) -> name
  | _ ->
      Core_error.errorf phase loc
        ~hint:"record/union construction requires a named result type"
        "final Core preparation saw non-named constructed type `%s`"
        (Types.type_to_string ty)

let lookup_variant env type_name ctor_name =
  match Hashtbl.find_opt env.variants_by_type type_name with
  | None -> None
  | Some by_name -> Hashtbl.find_opt by_name ctor_name

let register_type_decl env (td : Ast.type_decl) =
  let by_name =
    match Hashtbl.find_opt env.variants_by_type td.type_name with
    | Some tbl -> tbl
    | None ->
        let tbl = Hashtbl.create 8 in
        Hashtbl.add env.variants_by_type td.type_name tbl;
        tbl
  in
  List.iter
    (fun (v : Ast.variant) -> Hashtbl.replace by_name v.variant_name v)
    td.type_variants

let rec collect_decls env (decl : core_decl) =
  match decl.cd_desc with
  | CDRecord r -> Hashtbl.replace env.record_decls r.record_name r
  | CDType t -> register_type_decl env t
  | CDPrivate inner -> collect_decls env inner
  | CDFunc _ | CDVar _ | CDImpl _ | CDTrait _ | CDImport _ | CDTypeAlias _ -> ()

let record_subst ~reg (record_decl : Ast.record_decl option) expr_ty =
  match (record_decl, canonical_type ~reg expr_ty) with
  | Some r, Ast.TyNamed (_, args)
    when List.length r.record_type_params = List.length args ->
      List.combine (Ast.type_param_names r.record_type_params) args
  | _ -> []

let prepare_record_construct env (expr : core) fields =
  let type_name = type_name_or_error ~reg:env.reg expr.ty expr.loc in
  let record_decl = Hashtbl.find_opt env.record_decls type_name in
  let subst = record_subst ~reg:env.reg record_decl expr.ty in
  let field_decl_type field_name =
    match record_decl with
    | None -> None
    | Some r ->
        List.find_opt
          (fun (fd : Ast.field_decl) -> fd.field_name = field_name)
          r.record_fields
        |> Option.map (fun (fd : Ast.field_decl) -> fd.field_type)
  in
  let expected_field_ty field_name =
    Option.map
      (Codegen_types.apply_codegen_subst subst)
      (field_decl_type field_name)
  in
  let field_value_for_emit field_name value =
    match (expected_field_ty field_name, value.desc) with
    | Some ty, CRecord [] -> { value with ty }
    | _ -> value
  in
  let ordered_fields =
    match record_decl with
    | None -> fields
    | Some r ->
        List.map
          (fun (fd : Ast.field_decl) ->
            match List.assoc_opt fd.field_name fields with
            | Some value -> (fd.field_name, value)
            | None ->
                Core_error.errorf phase expr.loc
                  ~hint:
                    "record literals should be validated during type checking \
                     before final Core preparation"
                  "record literal for %s is missing field %s" type_name
                  fd.field_name)
          r.record_fields
  in
  let rc_fields =
    List.map
      (fun (field_name, value) ->
        let value = field_value_for_emit field_name value in
        match field_decl_type field_name with
        | Some field_ty when is_erased_record_field ~reg:env.reg field_ty ->
            RecordErasedField
              (field_name, boxed_storage_value ~reg:env.reg value)
        | _ -> RecordRawField (field_name, value))
      ordered_fields
  in
  let erased_release_mask =
    let has_erased_field =
      List.exists
        (function RecordErasedField _ -> true | RecordRawField _ -> false)
        rc_fields
    in
    if not has_erased_field then None
    else
      let bits =
        rc_fields
        |> List.mapi (fun i field ->
            match field with
            | RecordErasedField (_, value) when value.bsv_needs_release ->
                Some (1 lsl i)
            | _ -> None)
        |> List.filter_map (fun x -> x)
      in
      Some (List.fold_left ( lor ) 0 bits)
  in
  CRecordConstruct
    {
      rc_type_name = type_name;
      rc_fields;
      rc_erased_release_mask = erased_release_mask;
    }

let prepare_empty_record env (expr : core) =
  match canonical_type ~reg:env.reg expr.ty with
  | Ast.TyNamed ("Dict", key_ty :: _) ->
      CDictConstruct
        {
          dc_constructor = dict_constructor_for_key ~reg:env.reg key_ty;
          dc_entries = [];
          dc_value_needs_release =
            dict_value_needs_release ~reg:env.reg expr.ty expr.loc;
        }
  | Ast.TyNamed ("Set", [ elem_ty ]) ->
      CSetAlloc
        { sa_constructor = set_constructor_for_elem ~reg:env.reg elem_ty }
  | Ast.TyNamed ("List", _) ->
      CListAlloc
        {
          la_layout =
            Core_layout_type.list_storage_layout_of_type ~reg:env.reg expr.ty
              expr.loc;
          la_capacity = zero_capacity expr.loc;
        }
  | ty -> (
      match Core_tensor_type.of_type ~reg:env.reg ty with
      | Some tensor_ty ->
          let layout =
            Core_layout_type.tensor_storage_layout_of_type ~reg:env.reg ty
              expr.loc
          in
          let payload =
            tensor_literal_payload_for_elem_type ~reg:env.reg tensor_ty.elem_ty
              []
          in
          CTensorLiteral
            {
              tl_shape = TensorVectorLength 0;
              tl_layout = layout;
              tl_payload = payload;
            }
      | None -> prepare_record_construct env expr [])

let collect_vector_leaves elems =
  let rec collect acc expr =
    match expr.desc with
    | CVector inner -> List.fold_left collect acc inner
    | CTensorLiteral tl ->
        let elems =
          match tl.tl_payload with
          | TensorRawElements (_, elems) -> elems
          | TensorWordElements elems -> elems
          | TensorPackedElements (_, elems) -> elems
          | TensorInlineStructElements (_, elems) -> elems
          | TensorBoxedElements elems ->
              List.map (fun value -> value.bsv_box.box_value) elems
        in
        List.rev_append elems acc
    | _ -> expr :: acc
  in
  List.rev (List.fold_left collect [] elems)

let prepare_tensor_literal env (expr : core) elems =
  let tensor_ty = tensor_type_or_error env expr in
  let elem_ty = tensor_ty.elem_ty in
  let dims = tensor_ty.dims in
  let flat =
    if List.length dims >= 2 then collect_vector_leaves elems else elems
  in
  let shape =
    let const_dims =
      List.map (function Ast.TyConstInt n -> Some n | _ -> None) dims
    in
    if List.length dims >= 2 && List.for_all Option.is_some const_dims then
      TensorStaticShape (List.map Option.get const_dims)
    else TensorVectorLength (List.length elems)
  in
  let payload =
    tensor_literal_payload_for_elem_type ~reg:env.reg elem_ty flat
  in
  let layout =
    Core_layout_type.tensor_storage_layout_of_elem ~reg:env.reg elem_ty expr.loc
  in
  CTensorLiteral { tl_shape = shape; tl_layout = layout; tl_payload = payload }

let prepare_dict_construct env (expr : core) kvs =
  let key_ty =
    match canonical_type ~reg:env.reg expr.ty with
    | Ast.TyNamed ("Dict", key_ty :: _) -> key_ty
    | _ -> Ast.TyNamed ("Any", [])
  in
  CDictConstruct
    {
      dc_constructor = dict_constructor_for_key ~reg:env.reg key_ty;
      dc_entries =
        List.map
          (fun (k, v) ->
            ( boxed_storage_value ~reg:env.reg k,
              boxed_storage_value ~reg:env.reg v ))
          kvs;
      dc_value_needs_release =
        dict_value_needs_release ~reg:env.reg expr.ty expr.loc;
    }

let union_construct_c_name variant ctor_name def_id =
  match variant.Ast.variant_def_id with
  | Some id -> Codegen_names.mangle_by_def_id id ctor_name
  | None -> (
      match def_id with
      | Some id -> Codegen_names.mangle_by_def_id id ctor_name
      | None -> ctor_name)

let option_layout_or_error env expr =
  Core_layout_type.option_layout_or_error ~phase ~reg:env.reg expr.ty expr.loc

let result_layout env expr =
  Core_layout_type.stack_result_layout ~reg:env.reg expr.ty

let union_representation env expr type_name =
  match type_name with
  | "Option" -> OptionUnion (option_layout_or_error env expr)
  | "Result" -> (
      match result_layout env expr with
      | Some layout -> ResultUnion layout
      | None -> GenericUnion)
  | _ -> GenericUnion

let prepare_union_construct env expr type_name ctor_name def_id args variant =
  let uc_args = List.map (boxed_storage_value ~reg:env.reg) args in
  CUnionConstruct
    {
      uc_type_name = type_name;
      uc_constructor_name = ctor_name;
      uc_c_name = union_construct_c_name variant ctor_name def_id;
      uc_tag = variant.variant_tag;
      uc_representation = union_representation env expr type_name;
      uc_args;
      uc_release_mask = release_mask uc_args;
    }

let try_prepare_nullary_option_constructor_name env expr ctor_name def_id =
  match canonical_type ~reg:env.reg expr.ty with
  | Ast.TyNamed ("Option", _) -> (
      match lookup_variant env "Option" ctor_name with
      | Some variant when variant.variant_fields = [] ->
          Some
            (prepare_union_construct env expr "Option" ctor_name def_id []
               variant)
      | _ -> None)
  | _ -> None

let try_prepare_nullary_option_constructor env expr v =
  try_prepare_nullary_option_constructor_name env expr v.vname v.vdef_id

let try_prepare_union_call env expr kind args =
  let expr_ty = canonical_type ~reg:env.reg expr.ty in
  let from_builtin =
    match (kind, expr_ty, args) with
    | CKBuiltin "blorp_option_some", Ast.TyNamed ("Option", _), [ _ ] ->
        Some ("Option", "Some", None)
    | CKBuiltin "blorp_option_none", Ast.TyNamed ("Option", _), [] ->
        Some ("Option", "None", None)
    | CKBuiltin "blorp_result_ok", Ast.TyNamed ("Result", _), [ _ ] ->
        Some ("Result", "Ok", None)
    | CKBuiltin "blorp_result_err", Ast.TyNamed ("Result", _), [ _ ] ->
        Some ("Result", "Err", None)
    | _ -> None
  in
  let from_user =
    match (kind, expr_ty) with
    | CKUser (ctor_name, def_id), Ast.TyNamed (type_name, _) ->
        Some (type_name, ctor_name, def_id)
    | _ -> None
  in
  match
    match from_builtin with Some data -> Some data | None -> from_user
  with
  | None -> None
  | Some (type_name, ctor_name, def_id) -> (
      match lookup_variant env type_name ctor_name with
      | Some variant ->
          Some
            (prepare_union_construct env expr type_name ctor_name def_id args
               variant)
      | None -> None)

let refresh_prepared_expr_type env (expr : core) (expected_ty : Ast.type_expr) =
  let expr = { expr with ty = expected_ty } in
  match expr.desc with
  | CUnionConstruct uc ->
      {
        expr with
        desc =
          CUnionConstruct
            {
              uc with
              uc_representation = union_representation env expr uc.uc_type_name;
            };
      }
  | _ -> expr

let rec refresh_tail_expr_type env (expr : core) (expected_ty : Ast.type_expr) =
  let expr = { expr with ty = expected_ty } in
  match expr.desc with
  | CSeq (first, second) ->
      {
        expr with
        desc = CSeq (first, refresh_tail_expr_type env second expected_ty);
      }
  | CLet (binding, body) ->
      {
        expr with
        desc = CLet (binding, refresh_tail_expr_type env body expected_ty);
      }
  | CBorrowLet (binding, body) ->
      {
        expr with
        desc = CBorrowLet (binding, refresh_tail_expr_type env body expected_ty);
      }
  | CDup (var, ty, body) ->
      {
        expr with
        desc = CDup (var, ty, refresh_tail_expr_type env body expected_ty);
      }
  | CDrop (var, ty, body) ->
      {
        expr with
        desc = CDrop (var, ty, refresh_tail_expr_type env body expected_ty);
      }
  | CIf (cond, then_expr, else_expr) ->
      {
        expr with
        desc =
          CIf
            ( cond,
              refresh_tail_expr_type env then_expr expected_ty,
              refresh_tail_expr_type env else_expr expected_ty );
      }
  | _ -> refresh_prepared_expr_type env expr expected_ty

let prepare_node env (expr : core) =
  let desc =
    match expr.desc with
    | CTuple elems ->
        let tc_elems = List.map (boxed_storage_value ~reg:env.reg) elems in
        CTupleConstruct
          {
            tc_elems;
            tc_release_mask = release_mask tc_elems;
            tc_retain_mask = retain_mask ~reg:env.reg elems;
          }
    | CList lit ->
        let layout = lit.ll_layout in
        CListConstruct
          {
            lc_layout = layout;
            lc_elems = List.map (boxed_storage_value ~reg:env.reg) lit.ll_elems;
            lc_elem_needs_release =
              list_storage_layout_requires_release_or_error ~phase ~loc:expr.loc
                layout;
          }
    | CVector elems -> prepare_tensor_literal env expr elems
    | CDict kvs -> prepare_dict_construct env expr kvs
    | CRecord [] -> prepare_empty_record env expr
    | CRecord fields -> prepare_record_construct env expr fields
    | CCall (CKBuiltin "blorp_list_new", _, [ capacity ])
    | CCall (CKIntrinsic "list_alloc", _, [ capacity ]) ->
        CListAlloc
          {
            la_layout =
              Core_layout_type.list_storage_layout_of_type ~reg:env.reg expr.ty
                expr.loc;
            la_capacity = capacity;
          }
    | CCall (CKIntrinsic "list_get", _, [ list; index ]) ->
        CListGet
          {
            lg_layout =
              Core_layout_type.list_storage_layout_of_type ~reg:env.reg list.ty
                list.loc;
            lg_list = list;
            lg_index = index;
            lg_bounds = ListBoundsChecked;
          }
    | CCall (CKIntrinsic "list_get_unchecked", _, [ list; index ]) ->
        CListGet
          {
            lg_layout =
              Core_layout_type.list_storage_layout_of_type ~reg:env.reg list.ty
                list.loc;
            lg_list = list;
            lg_index = index;
            lg_bounds = ListBoundsProven;
          }
    | CCall (CKIntrinsic "string_get_byte", _, [ source; index ]) ->
        CStringByteRead
          {
            sbr_source = source;
            sbr_index = index;
            sbr_proof = StringReadBoundsProven;
          }
    | CCall (CKIntrinsic "string_set_byte", _, [ target; index; byte ]) ->
        CStringByteWrite
          {
            sbw_target = target;
            sbw_index = index;
            sbw_byte = byte;
            sbw_proof = StringWriteBoundsProven;
          }
    | CCall
        (CKIntrinsic "string_copy_bytes", _, [ dst; dst_pos; src; src_pos; len ])
      ->
        CStringByteCopy
          {
            sbc_dst = dst;
            sbc_dst_pos = dst_pos;
            sbc_src = src;
            sbc_src_pos = src_pos;
            sbc_len = len;
            sbc_proof = StringCopyBoundsProven;
          }
    | CCall (CKIntrinsic "string_set_len", _, [ target; len ]) ->
        CStringSetLen
          {
            ssl_target = target;
            ssl_len = len;
            ssl_proof = StringSetLenBoundsProven;
          }
    | CVar v -> (
        match try_prepare_nullary_option_constructor env expr v with
        | Some desc -> desc
        | None -> expr.desc)
    | CField ({ ty = Ast.TyNamed ("Module", []); _ }, field_name) -> (
        match
          try_prepare_nullary_option_constructor_name env expr field_name None
        with
        | Some desc -> desc
        | None -> expr.desc)
    | CCall (kind, callee, args) -> (
        match try_prepare_union_call env expr kind args with
        | Some desc -> desc
        | None -> CCall (kind, callee, args))
    | CUnbox (value, target_ty) ->
        CUnboxTyped
          {
            unbox_value = value;
            unbox_target_ty = target_ty;
            unbox_kind = classify_unbox_kind ~reg:env.reg target_ty expr.loc;
          }
    | CBox (value, source_ty) ->
        CBoxTyped (make_box_op ~reg:env.reg value source_ty)
    | CLet (binding, body) ->
        CLet
          ( {
              binding with
              bind_rhs =
                refresh_tail_expr_type env binding.bind_rhs binding.bind_ty;
            },
            body )
    | CBorrowLet (binding, body) ->
        CBorrowLet
          ( {
              binding with
              borrow_rhs =
                refresh_tail_expr_type env binding.borrow_rhs binding.borrow_ty;
            },
            body )
    | _ -> expr.desc
  in
  { expr with desc }

module Storage_env = struct
  type t = (var * tensor_storage_provenance) list

  let empty = []

  let lookup var env =
    env
    |> List.find_opt (fun (candidate, _) -> Var.equal candidate var)
    |> Option.map snd

  let remove_var var env =
    List.filter (fun (candidate, _) -> not (Var.equal candidate var)) env

  let remove_name name env =
    List.filter (fun (candidate, _) -> candidate.vname <> name) env

  let remove_names names env =
    List.fold_left (fun e n -> remove_name n e) env names

  let add var proof env = (var, proof) :: remove_var var env
end

let tensor_storage_layout_for_expr env expr =
  Core_layout_type.tensor_storage_layout_of_type ~reg:env.reg expr.ty expr.loc

module Tensor_producer = Core_tensor_storage_producer

let list_nth_opt xs index =
  if index < 0 then None
  else
    let rec go i = function
      | [] -> None
      | x :: _ when i = 0 -> Some x
      | _ :: rest -> go (i - 1) rest
    in
    go index xs

let tensor_storage_unknown_for_expr expr reason =
  TensorStorageUnknown
    (Printf.sprintf "%s for %s" reason (Types.type_to_string expr.ty))

let rec tensor_storage_provenance_of_expr env storage_env expr =
  if Option.is_none (tensor_type_of_expr env expr) then
    tensor_storage_unknown_for_expr expr "expression is not a tensor"
  else
    match expr.desc with
    | CVar var -> (
        match Storage_env.lookup var storage_env with
        | Some proof -> proof
        | None ->
            tensor_storage_unknown_for_expr expr
              "variable storage comes from an unproven boundary")
    | CTensorLiteral literal -> tensor_storage_known_producer literal.tl_layout
    | CCall (CKIntrinsic "tensor_alloc", _, _) ->
        tensor_storage_known_producer (tensor_storage_layout_for_expr env expr)
    | CCall (kind, _, args) -> (
        match Tensor_producer.of_call_kind kind with
        | Some producer ->
            tensor_storage_provenance_of_producer_rule env storage_env expr
              producer args
        | None ->
            tensor_storage_unknown_for_expr expr
              "expression is not a compiler-owned tensor producer")
    | _ ->
        tensor_storage_unknown_for_expr expr
          "expression is not a compiler-owned tensor producer"

and tensor_storage_provenance_of_producer_rule env storage_env expr producer
    args =
  let rule = Tensor_producer.storage_rule producer in
  Tensor_producer.fold_storage_rule
    ~known_result:(fun () ->
      tensor_storage_known_producer (tensor_storage_layout_for_expr env expr))
    ~preserves_arg:(fun index ->
      match list_nth_opt args index with
      | Some source ->
          tensor_storage_preserved_from_source env storage_env expr source
      | None ->
          tensor_storage_unknown_for_expr expr
            (Printf.sprintf
               "tensor producer `%s` is missing preserved source argument %d"
               (Tensor_producer.producer_debug_name producer)
               index))
    rule

and tensor_storage_preserved_from_source env storage_env expr source =
  match tensor_storage_provenance_of_expr env storage_env source with
  | TensorStorageProven { tsp_layout; _ } ->
      let result_layout = tensor_storage_layout_for_expr env expr in
      tensor_storage_preserved_producer
        { tsp_layout with tsl_elem_ty = result_layout.tsl_elem_ty }
  | TensorStorageUnknown reason -> TensorStorageUnknown reason

let tensor_storage_provenance_for_binding env storage_env binding =
  if binding.bind_mut then None
  else if is_tensor_type env binding.bind_ty then
    let proof =
      tensor_storage_provenance_of_expr env storage_env binding.bind_rhs
    in
    match proof with
    | TensorStorageProven _ -> Some proof
    | TensorStorageUnknown _ -> None
  else None

let tensor_storage_provenance_for_borrow env storage_env binding =
  if is_tensor_type env binding.borrow_ty then
    match
      tensor_storage_provenance_of_expr env storage_env binding.borrow_rhs
    with
    | TensorStorageProven { tsp_layout; _ } ->
        Some (tensor_storage_preserved_producer tsp_layout)
    | TensorStorageUnknown _ -> None
  else None

let raw_tensor_kind_of_safe_get = function
  | "tensor_get_f64" -> Some TensorFloat64Elements
  | "tensor_get_f32" -> Some TensorFloat32Elements
  | "tensor_get_i64" -> Some TensorInt64Elements
  | _ -> None

let same_tensor_source left right =
  match (left.desc, right.desc) with
  | CVar left_var, CVar right_var -> Var.equal left_var right_var
  | _ -> false

let tensor_storage_proves_raw_kind proof raw_kind =
  match proof with
  | TensorStorageProven
      { tsp_layout = { tsl_slots = TensorRawScalarStorage proven_kind; _ }; _ }
    ->
      proven_kind = raw_kind
  | TensorStorageProven _ | TensorStorageUnknown _ -> false

let simplify_proven_tensor_storage_guard env storage_env expr =
  match expr.desc with
  | CIf
      ( { desc = CCall (CKIntrinsic storage_pred, _, [ pred_source ]); _ },
        ({ desc = CCall (CKIntrinsic raw_get, _, [ raw_source; _ ]); _ } as
         raw_read),
        { desc = CCall (CKIntrinsic safe_get, _, [ safe_source; _ ]); _ } ) -> (
      match
        ( Core_specialize.raw_tensor_kind_of_storage_pred storage_pred,
          Core_specialize.raw_tensor_kind_of_raw_get raw_get,
          raw_tensor_kind_of_safe_get safe_get )
      with
      | Some pred_kind, Some raw_kind, Some safe_kind
        when pred_kind = raw_kind && raw_kind = safe_kind
             && same_tensor_source pred_source raw_source
             && same_tensor_source raw_source safe_source ->
          let proof =
            tensor_storage_provenance_of_expr env storage_env raw_source
          in
          if tensor_storage_proves_raw_kind proof raw_kind then Some raw_read
          else None
      | _ -> None)
  | _ -> None

let simplify_proven_tensor_raw_view_guard env storage_env binding body =
  match (binding.bind_rhs.desc, body.desc) with
  | ( CCall (CKIntrinsic storage_pred, _, [ pred_source ]),
      CIf
        ( { desc = CVar guard_var; _ },
          ({ desc = CTensorRawViewLet (view_binding, _); _ } as fast_path),
          _fallback ) )
    when (not binding.bind_mut)
         && Var.equal binding.bind_var guard_var
         && canonical_type ~reg:env.reg binding.bind_ty
            = Ast.TyNamed ("Bool", []) -> (
      match Core_specialize.raw_tensor_kind_of_storage_pred storage_pred with
      | Some pred_kind
        when pred_kind = view_binding.trv_kind
             && same_tensor_source pred_source view_binding.trv_source ->
          let proof =
            tensor_storage_provenance_of_expr env storage_env pred_source
          in
          if tensor_storage_proves_raw_kind proof pred_kind then Some fast_path
          else None
      | _ -> None)
  | _ -> None

let rec annotate_tensor_storage_provenance env storage_env expr =
  let annotate = annotate_tensor_storage_provenance env in
  match expr.desc with
  | CLet (binding, body) -> (
      let rhs = annotate storage_env binding.bind_rhs in
      let binding' = { binding with bind_rhs = rhs } in
      let body_env =
        match
          tensor_storage_provenance_for_binding env storage_env binding'
        with
        | Some proof -> Storage_env.add binding.bind_var proof storage_env
        | None -> Storage_env.remove_var binding.bind_var storage_env
      in
      let body' = annotate body_env body in
      match
        simplify_proven_tensor_raw_view_guard env body_env binding' body'
      with
      | Some simplified -> simplified
      | None -> { expr with desc = CLet (binding', body') })
  | CBorrowLet (binding, body) ->
      let rhs = annotate storage_env binding.borrow_rhs in
      let binding' = { binding with borrow_rhs = rhs } in
      let body_env =
        match tensor_storage_provenance_for_borrow env storage_env binding' with
        | Some proof -> Storage_env.add binding.borrow_var proof storage_env
        | None -> Storage_env.remove_var binding.borrow_var storage_env
      in
      { expr with desc = CBorrowLet (binding', annotate body_env body) }
  | CResourceScope scope ->
      let acquire = annotate storage_env scope.rs_acquire in
      let scope_env = Storage_env.remove_var scope.rs_var storage_env in
      {
        expr with
        desc =
          CResourceScope
            {
              scope with
              rs_acquire = acquire;
              rs_body = annotate scope_env scope.rs_body;
              rs_cleanup = annotate scope_env scope.rs_cleanup;
            };
      }
  | CFor (binder, iter, body) ->
      let iter' = annotate storage_env iter in
      let loop_source_storage =
        tensor_storage_provenance_of_expr env storage_env iter'
      in
      let binder' = { binder with loop_source_storage } in
      let body_env = Storage_env.remove_var binder.loop_var storage_env in
      { expr with desc = CFor (binder', iter', annotate body_env body) }
  | CIf (cond, then_expr, else_expr) -> (
      let expr' =
        {
          expr with
          desc =
            CIf
              ( annotate storage_env cond,
                annotate storage_env then_expr,
                annotate storage_env else_expr );
        }
      in
      match simplify_proven_tensor_storage_guard env storage_env expr' with
      | Some simplified -> simplified
      | None -> expr')
  | CLambda lambda ->
      let lambda_env =
        List.fold_left
          (fun e (param, _) -> Storage_env.remove_var param e)
          storage_env lambda.lam_params
      in
      {
        expr with
        desc =
          CLambda { lambda with lam_body = annotate lambda_env lambda.lam_body };
      }
  | CMatchArms (scrutinee, arms) ->
      let scrutinee' = annotate storage_env scrutinee in
      let arms' =
        List.map
          (fun (pat, body) ->
            let arm_env =
              Storage_env.remove_names
                (Ast.collect_pattern_vars pat)
                storage_env
            in
            (pat, annotate arm_env body))
          arms
      in
      { expr with desc = CMatchArms (scrutinee', arms') }
  | CMatch (scrutinee, tree) ->
      let scrutinee' = annotate storage_env scrutinee in
      {
        expr with
        desc = CMatch (scrutinee', annotate_ctree env storage_env tree);
      }
  | CTailrecLoop loop ->
      let loop' =
        match loop with
        | TailrecUnmanagedLoop l ->
            let loop_env =
              List.fold_left
                (fun e p -> Storage_env.remove_var p.cp_name e)
                storage_env l.tul_params
            in
            TailrecUnmanagedLoop
              { l with tul_body = annotate loop_env l.tul_body }
        | TailrecListSpreadLoop l ->
            let loop_env =
              List.fold_left
                (fun e p -> Storage_env.remove_var p.cp_name e)
                storage_env l.tls_params
              |> Storage_env.remove_var l.tls_list_param.cp_name
              |> Storage_env.remove_var l.tls_cursor_var
            in
            TailrecListSpreadLoop
              { l with tls_body = annotate loop_env l.tls_body }
      in
      { expr with desc = CTailrecLoop loop' }
  | CConcurrent block ->
      let bindings' =
        List.map
          (fun binding ->
            { binding with cb_rhs = annotate storage_env binding.cb_rhs })
          block.conc_bindings
      in
      let body_env =
        List.fold_left
          (fun e binding -> Storage_env.remove_var binding.cb_var e)
          storage_env block.conc_bindings
      in
      {
        expr with
        desc =
          CConcurrent
            {
              block with
              conc_bindings = bindings';
              conc_body = annotate body_env block.conc_body;
              conc_timeout =
                Option.map (annotate storage_env) block.conc_timeout;
            };
      }
  | CConcurrentFor cf ->
      let body_env = Storage_env.remove_var cf.cf_var storage_env in
      {
        expr with
        desc =
          CConcurrentFor
            {
              cf with
              cf_iter = annotate storage_env cf.cf_iter;
              cf_body = annotate body_env cf.cf_body;
              cf_timeout = Option.map (annotate storage_env) cf.cf_timeout;
            };
      }
  | _ -> Core.map_children (annotate storage_env) expr

and annotate_ctree env storage_env tree =
  let annotate = annotate_tensor_storage_provenance env in
  match tree with
  | CTLeaf { ct_bindings; ct_body } ->
      let leaf_env =
        List.fold_left
          (fun e (binding, _) -> Storage_env.remove_var binding e)
          storage_env ct_bindings
      in
      CTLeaf { ct_bindings; ct_body = annotate leaf_env ct_body }
  | CTFail -> CTFail
  | CTSwitchTag { cts_scrut; cts_cases; cts_default } ->
      CTSwitchTag
        {
          cts_scrut;
          cts_cases =
            List.map
              (fun (name, sub) -> (name, annotate_ctree env storage_env sub))
              cts_cases;
          cts_default = Option.map (annotate_ctree env storage_env) cts_default;
        }
  | CTSwitchLit { ctl_scrut; ctl_cases; ctl_default } ->
      CTSwitchLit
        {
          ctl_scrut;
          ctl_cases =
            List.map
              (fun (lit, sub) -> (lit, annotate_ctree env storage_env sub))
              ctl_cases;
          ctl_default = annotate_ctree env storage_env ctl_default;
        }
  | CTSwitchLen { ctl_len_scrut; ctl_len_cases; ctl_len_geq; ctl_len_default }
    ->
      CTSwitchLen
        {
          ctl_len_scrut;
          ctl_len_cases =
            List.map
              (fun (len, sub) -> (len, annotate_ctree env storage_env sub))
              ctl_len_cases;
          ctl_len_geq =
            Option.map
              (fun (len, sub) -> (len, annotate_ctree env storage_env sub))
              ctl_len_geq;
          ctl_len_default =
            Option.map (annotate_ctree env storage_env) ctl_len_default;
        }

let prepare_expr_with_env env expr =
  expr
  |> Core.transform_bottom_up (prepare_node env)
  |> annotate_tensor_storage_provenance env Storage_env.empty

let empty_env reg =
  {
    reg;
    record_decls = Hashtbl.create 16;
    variants_by_type = Hashtbl.create 16;
  }

let prepare_expr ~reg expr =
  let env = empty_env reg in
  prepare_expr_with_env env expr

let rec prepare_decl env decl =
  let desc =
    match decl.cd_desc with
    | CDFunc f ->
        CDFunc
          {
            f with
            cf_body =
              Option.map
                (fun body ->
                  refresh_tail_expr_type env
                    (prepare_expr_with_env env body)
                    f.cf_return_ty)
                f.cf_body;
          }
    | CDVar v ->
        CDVar
          {
            v with
            cv_init =
              refresh_tail_expr_type env
                (prepare_expr_with_env env v.cv_init)
                v.cv_ty;
          }
    | CDImpl impl ->
        CDImpl
          {
            impl with
            ci_methods =
              List.map
                (fun f ->
                  {
                    f with
                    cf_body =
                      Option.map
                        (fun body ->
                          refresh_tail_expr_type env
                            (prepare_expr_with_env env body)
                            f.cf_return_ty)
                        f.cf_body;
                  })
                impl.ci_methods;
          }
    | CDPrivate inner -> CDPrivate (prepare_decl env inner)
    | (CDTrait _ | CDType _ | CDRecord _ | CDImport _ | CDTypeAlias _) as other
      ->
        other
  in
  { decl with cd_desc = desc }

let prepare_program ~reg prog =
  let env = empty_env reg in
  List.iter (collect_decls env) prog;
  List.map (prepare_decl env) prog
