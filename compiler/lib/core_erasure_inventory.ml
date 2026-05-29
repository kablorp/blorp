(** Inventory of typed values crossing erased storage boundaries.

    This module is intentionally pure and observational. It does not enforce
    an invariant yet; it classifies the remaining [void*]-style boundaries so
    ABI work can replace each category with a typed representation without
    relying on name or shape heuristics. *)

type severity =
  | ExplicitBoundary
      (** A generic or intentionally opaque boundary. This is real erasure, but
          not a monomorphic optimization gap. *)
  | ManagedPointerErasure
      (** The value is already represented as a managed pointer, but storage
          loses its static type. *)
  | MonomorphicValueErasure
      (** A concrete by-value layout is being erased into generic storage. This
          is the main optimization gap for stack options and value types. *)
  | UnknownLayout
      (** The ownership/layout classifier could not identify the type. *)

type site_kind =
  | BoxToErasedStorage
  | UnboxFromErasedStorage
  | ListPointerElementStorage
  | ListElementValue of int
  | ListElementLoad
  | TupleField of int
  | ClosureCapture of string
  | ClosureParam of string
  | ClosureReturn
  | TaskCapture of string
  | TaskReturn
  | UnionPayload of string * int
  | RecordErasedField of string
  | DictKey
  | DictValue
  | TensorElement of int

type site = {
  kind : site_kind;
  ty : Ast.type_expr;
  loc : Ast.loc;
  severity : severity;
  reason : string;
}

open Core

let site_kind_to_string = function
  | BoxToErasedStorage -> "box-to-erased-storage"
  | UnboxFromErasedStorage -> "unbox-from-erased-storage"
  | ListPointerElementStorage -> "list-pointer-element-storage"
  | ListElementValue i -> Printf.sprintf "list-element-value[%d]" i
  | ListElementLoad -> "list-element-load"
  | TupleField i -> Printf.sprintf "tuple-field[%d]" i
  | ClosureCapture name -> Printf.sprintf "closure-capture[%s]" name
  | ClosureParam name -> Printf.sprintf "closure-param[%s]" name
  | ClosureReturn -> "closure-return"
  | TaskCapture name -> Printf.sprintf "task-capture[%s]" name
  | TaskReturn -> "task-return"
  | UnionPayload (ctor, i) -> Printf.sprintf "union-payload[%s.%d]" ctor i
  | RecordErasedField name -> Printf.sprintf "record-erased-field[%s]" name
  | DictKey -> "dict-key"
  | DictValue -> "dict-value"
  | TensorElement i -> Printf.sprintf "tensor-element[%d]" i

let severity_to_string = function
  | ExplicitBoundary -> "explicit-boundary"
  | ManagedPointerErasure -> "managed-pointer-erasure"
  | MonomorphicValueErasure -> "monomorphic-value-erasure"
  | UnknownLayout -> "unknown-layout"

let site_to_string (site : site) =
  Printf.sprintf "%s: %s (%s: %s)"
    (site_kind_to_string site.kind)
    (Types.type_to_string site.ty)
    (severity_to_string site.severity)
    site.reason

let canonical_type ~(reg : Codegen_types.registry) ty =
  Core_layout_type.canonical_type ~reg ty

let rec has_open_type ty =
  match ty with
  | Ast.TyVar name when Types.Dim.is_var_name name -> false
  | Ast.TyVar _ | Ast.TyBoundVar _ | Ast.TyVarDims _ | Ast.TyMeta _ | Ast.TySelf
    ->
      true
  | Ast.TyNamed (name, args) ->
      Types.is_type_param_name name || List.exists has_open_type args
  | Ast.TyArray (elem, dims) ->
      has_open_type elem || List.exists has_open_type dims
  | Ast.TyTuple elems -> List.exists has_open_type elems
  | Ast.TyFunc f -> List.exists has_open_type f.params || has_open_type f.return
  | Ast.TyRange inner -> has_open_type inner
  | Ast.TyDimOp _ -> false
  | Ast.TyConstInt _ -> false

let is_explicit_opaque_type = function
  | Ast.TyNamed (("Void" | "Ptr"), []) -> true
  | _ -> false

let is_void_type ~reg ty =
  match canonical_type ~reg ty with
  | Ast.TyNamed ("Void", []) -> true
  | _ -> false

let classify_type ~(reg : Codegen_types.registry) ty =
  let ty = canonical_type ~reg ty in
  if has_open_type ty then (ty, ExplicitBoundary, "open generic type")
  else if is_explicit_opaque_type ty then
    (ty, ExplicitBoundary, "opaque or void runtime boundary")
  else
    match Core_layout_type.option_erasure_layout_of_type ~reg ty with
    | Core_layout_type.OptionErasureStackValue ->
        (ty, MonomorphicValueErasure, "stack Option value")
    | Core_layout_type.OptionErasureNullableManagedPointer ->
        (ty, ManagedPointerErasure, "nullable managed Option pointer")
    | Core_layout_type.OptionErasureBoxedUnion reason ->
        (ty, ManagedPointerErasure, reason)
    | Core_layout_type.OptionErasureUnknownPayload name ->
        (ty, UnknownLayout, "unknown Option payload type " ^ name)
    | Core_layout_type.OptionErasureInvalid _ -> (
        match
          Core_layout_type.classify_source_value_layout_of_type ~reg ty
            Ast.dummy_loc
        with
        | Core_layout_type.SourceValueKnown
            { sv_ownership = Core_layout_type.SourceValueManaged; _ } ->
            (ty, ManagedPointerErasure, "managed pointer value")
        | Core_layout_type.SourceValueKnown
            { sv_ownership = Core_layout_type.SourceValueUnmanaged; _ } ->
            (ty, MonomorphicValueErasure, "concrete unmanaged value")
        | Core_layout_type.SourceValueUnknownNamed name ->
            (ty, UnknownLayout, "unknown type " ^ name)
        | Core_layout_type.SourceValueInvalid msg -> (ty, UnknownLayout, msg))

let make_site ~reg ~kind ~loc ty =
  let ty, severity, reason = classify_type ~reg ty in
  { kind; ty; loc; severity; reason }

let box_site ~reg ~kind ~loc (box : Core.box_op) =
  make_site ~reg ~kind ~loc box.box_source_ty

let unbox_site ~reg ~loc (unbox : Core.unbox_op) =
  make_site ~reg ~kind:UnboxFromErasedStorage ~loc unbox.unbox_target_ty

let boxed_storage_site ~reg ~kind ~loc (value : Core.boxed_storage_value) =
  box_site ~reg ~kind ~loc value.bsv_box

let add_boxed_storage_site ~reg ~kind ~loc value acc =
  boxed_storage_site ~reg ~kind ~loc value :: acc

let fold_indexed_boxed_sites ~reg ~loc ~kind_of_index values acc =
  List.fold_left
    (fun (index, acc) value ->
      ( index + 1,
        add_boxed_storage_site ~reg ~kind:(kind_of_index index) ~loc value acc
      ))
    (0, acc) values
  |> snd

let list_elem_type ~(reg : Codegen_types.registry) ty =
  match canonical_type ~reg ty with
  | Ast.TyNamed ("List", [ elem ]) -> Some elem
  | _ -> None

let add_list_pointer_storage_site ~reg ~loc list_ty acc =
  match list_elem_type ~reg list_ty with
  | None -> acc
  | Some elem -> make_site ~reg ~kind:ListPointerElementStorage ~loc elem :: acc

let collect_task_closure ~reg ~loc (task : Core.task_closure) acc =
  let acc =
    if is_void_type ~reg task.tc_return_ty then acc
    else make_site ~reg ~kind:TaskReturn ~loc task.tc_return_ty :: acc
  in
  List.fold_left
    (fun acc capture ->
      let name, ty = Core.task_capture_binding capture in
      make_site ~reg ~kind:(TaskCapture name) ~loc ty :: acc)
    acc task.tc_captures

let collect_optional_task_closure ~reg ~loc task acc =
  match task with
  | None -> acc
  | Some task -> collect_task_closure ~reg ~loc task acc

let collect_expr_sites ~(reg : Codegen_types.registry) acc (expr : Core.core) =
  let loc = expr.loc in
  match expr.desc with
  | CBox (_, source_ty) ->
      make_site ~reg ~kind:BoxToErasedStorage ~loc source_ty :: acc
  | CUnbox (_, target_ty) ->
      make_site ~reg ~kind:UnboxFromErasedStorage ~loc target_ty :: acc
  | CBoxTyped box -> box_site ~reg ~kind:BoxToErasedStorage ~loc box :: acc
  | CUnboxTyped unbox -> unbox_site ~reg ~loc unbox :: acc
  | CList lit -> (
      match lit.ll_layout.lsl_slots with
      | ListPointerStorage ->
          add_list_pointer_storage_site ~reg ~loc expr.ty acc
      | ListInlineStorage _ | ListInlineStructStorage _ -> acc)
  | CListAlloc alloc -> (
      match alloc.la_layout.lsl_slots with
      | ListPointerStorage ->
          add_list_pointer_storage_site ~reg ~loc expr.ty acc
      | ListInlineStorage _ | ListInlineStructStorage _ -> acc)
  | CListGet get -> (
      match get.lg_layout.lsl_slots with
      | ListPointerStorage ->
          make_site ~reg ~kind:ListElementLoad ~loc expr.ty :: acc
      | ListInlineStorage _ | ListInlineStructStorage _ -> acc)
  | CListConstruct lc -> (
      match lc.lc_layout.lsl_slots with
      | ListPointerStorage ->
          let acc = add_list_pointer_storage_site ~reg ~loc expr.ty acc in
          fold_indexed_boxed_sites ~reg ~loc
            ~kind_of_index:(fun i -> ListElementValue i)
            lc.lc_elems acc
      | ListInlineStorage _ | ListInlineStructStorage _ -> acc)
  | CListHandoff handoff -> (
      match handoff.lh_layout.lsl_slots with
      | ListPointerStorage ->
          add_list_pointer_storage_site ~reg ~loc handoff.lh_result_ty acc
      | ListInlineStorage _ | ListInlineStructStorage _ -> acc)
  | CTupleConstruct tuple ->
      fold_indexed_boxed_sites ~reg ~loc
        ~kind_of_index:(fun i -> TupleField i)
        tuple.tc_elems acc
  | CDictConstruct dict ->
      List.fold_left
        (fun acc (key, value) ->
          let acc = boxed_storage_site ~reg ~kind:DictKey ~loc key :: acc in
          boxed_storage_site ~reg ~kind:DictValue ~loc value :: acc)
        acc dict.dc_entries
  | CRecordConstruct record ->
      List.fold_left
        (fun acc field ->
          match field with
          | RecordRawField _ -> acc
          | RecordErasedField (name, value) ->
              boxed_storage_site ~reg ~kind:(RecordErasedField name) ~loc value
              :: acc)
        acc record.rc_fields
  | CTensorLiteral tensor -> (
      match tensor.tl_payload with
      | TensorRawElements _ -> acc
      | TensorWordElements _ -> acc
      | TensorPackedElements _ -> acc
      | TensorInlineStructElements _ -> acc
      | TensorBoxedElements elems ->
          fold_indexed_boxed_sites ~reg ~loc
            ~kind_of_index:(fun i -> TensorElement i)
            elems acc)
  | CUnionConstruct union ->
      fold_indexed_boxed_sites ~reg ~loc
        ~kind_of_index:(fun i -> UnionPayload (union.uc_constructor_name, i))
        union.uc_args acc
  | CClosureCreate closure ->
      List.fold_left
        (fun acc (name, ty) ->
          make_site ~reg ~kind:(ClosureCapture name) ~loc ty :: acc)
        acc closure.cc_captures
  | CConcurrent block ->
      List.fold_left
        (fun acc binding ->
          collect_optional_task_closure ~reg ~loc binding.cb_task acc)
        acc block.conc_bindings
  | CConcurrentlyLoop cf ->
      collect_optional_task_closure ~reg ~loc cf.cf_task acc
  | CDetach detach ->
      collect_optional_task_closure ~reg ~loc detach.detach_task acc
  | _ -> acc

let collect_expr ~reg acc expr =
  Core.fold_tree (collect_expr_sites ~reg) acc expr

let collect_closure_abi ~reg ~loc ~return_ty (abi : Core.closure_abi) acc =
  let acc =
    if is_void_type ~reg return_ty then acc
    else make_site ~reg ~kind:ClosureReturn ~loc return_ty :: acc
  in
  let acc =
    List.fold_left
      (fun acc (param, ty) ->
        make_site ~reg ~kind:(ClosureParam (Core.Var.to_string param)) ~loc ty
        :: acc)
      acc abi.ca_params
  in
  List.fold_left
    (fun acc (name, ty) ->
      make_site ~reg ~kind:(ClosureCapture name) ~loc ty :: acc)
    acc abi.ca_captures

let rec collect_decl ~reg acc (decl : Core.core_decl) =
  match decl.cd_desc with
  | CDFunc fn ->
      let acc =
        match fn.cf_body with
        | None -> acc
        | Some body -> collect_expr ~reg acc body
      in
      begin match fn.cf_kind with
      | CFClosureBody abi ->
          collect_closure_abi ~reg ~loc:decl.cd_loc ~return_ty:fn.cf_return_ty
            abi acc
      | CFUser | CFBuiltin | CFForeign _ -> acc
      end
  | CDVar var -> collect_expr ~reg acc var.cv_init
  | CDImpl impl ->
      List.fold_left
        (fun acc method_fn ->
          collect_decl ~reg acc
            { cd_desc = CDFunc method_fn; cd_loc = decl.cd_loc; cd_doc = None })
        acc impl.ci_methods
  | CDPrivate inner -> collect_decl ~reg acc inner
  | CDTrait _ | CDType _ | CDRecord _ | CDImport _ | CDTypeAlias _ -> acc

let collect_program ~(reg : Codegen_types.registry)
    (program : Core.core_program) =
  List.fold_left (collect_decl ~reg) [] program |> List.rev
