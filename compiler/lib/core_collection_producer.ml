(** Typed collection producer policy.

    This module is the shared decision point for collection pipeline lowering:
    it turns element/result types into explicit source-access and storage
    policies. The fusion pass should ask for a policy instead of hard-coding
    individual type names. *)

type source_access = BindUnboxedValue | BorrowManagedAlias

type filter_map_payload_policy =
  | NoFilterMapPayload
  | BorrowedPayloadAliasFromOwnedOption
      (** A [filter_map] stage binds [Some(payload)] as a borrowed alias into
          the owned callback result. If that payload is later transferred into
          result storage, Perceus must retain the alias before the transfer and
          then drop the callback result normally. *)

type collect_policy = {
  source_access : source_access;
  result_elem_ty : Ast.type_expr;
  filter_map_payload_policy : filter_map_payload_policy;
}

type source_access_policy = {
  sap_access : source_access;
  sap_elem_ty : Ast.type_expr;
}

type model = Model of { reg : Codegen_types.registry }

type ineligible_reason =
  | NotSameTypeCollect
  | ArcBoxedScalarStorage
  | UnknownLayout of string
  | InvalidValueType of string

type 'a eligibility = Eligible of 'a | Ineligible of ineligible_reason

let default_model = Model { reg = Codegen_types.create_registry () }
let model_of_registry reg = Model { reg }
let reg_of_model (Model { reg }) = reg

let canonical_type model ty =
  Core_layout_type.canonical_type ~reg:(reg_of_model model) ty

let scalar_name_is_unboxed_pipeline_eligible = function
  | "Int" | "Int8" | "Int16" | "Int32" | "Int64" | "UInt8" | "UInt16" | "UInt32"
  | "UInt64" | "Bool" | "Char" | "Float" | "Float32" | "Float16" ->
      true
  | _ -> false

let type_is_unboxed_pipeline_scalar model ty =
  match canonical_type model ty with
  | Ast.TyNamed (name, []) when scalar_name_is_unboxed_pipeline_eligible name ->
      true
  | Ast.TyRange _ -> true
  | _ -> false

let canonical_types_equal model a b =
  Types.types_equal (canonical_type model a) (canonical_type model b)

let list_elem_ty = function
  | Ast.TyNamed ("List", [ elem_ty ]) -> Some elem_ty
  | _ -> None

let source_access_for_layout (layout : Core_layout_type.source_value_layout) =
  match layout.sv_ownership with
  | Core_layout_type.SourceValueManaged -> BorrowManagedAlias
  | Core_layout_type.SourceValueUnmanaged -> BindUnboxedValue

let classify_value_layout model ty =
  let reg = reg_of_model model in
  match
    Core_layout_type.classify_source_value_layout_of_type ~reg ty Ast.dummy_loc
  with
  | Core_layout_type.SourceValueKnown layout -> Eligible layout
  | Core_layout_type.SourceValueUnknownNamed name ->
      Ineligible (UnknownLayout name)
  | Core_layout_type.SourceValueInvalid msg -> Ineligible (InvalidValueType msg)

let stage_types_match_source model ~source_elem_ty stage_value_tys =
  List.for_all
    (fun stage_ty -> canonical_types_equal model source_elem_ty stage_ty)
    stage_value_tys

let source_uses_arc_boxed_storage model source_elem_ty =
  match
    Core_layout_type.boxed_storage_scalar_kind ~reg:(reg_of_model model)
      source_elem_ty
  with
  | Core_layout_type.BoxedStorageArcBoxedScalar -> true
  | Core_layout_type.BoxedStorageInlineScalar
  | Core_layout_type.BoxedStorageNonScalar ->
      false

let collect_result_elem_ty model ~source_elem_ty ~result_ty =
  match list_elem_ty result_ty with
  | Some result_elem_ty
    when canonical_types_equal model source_elem_ty result_elem_ty ->
      Some result_elem_ty
  | _ -> None

let same_type_source_access_policy model ~(source_elem_ty : Ast.type_expr)
    ~(stage_value_tys : Ast.type_expr list) : source_access_policy eligibility =
  if not (stage_types_match_source model ~source_elem_ty stage_value_tys) then
    Ineligible NotSameTypeCollect
  else if source_uses_arc_boxed_storage model source_elem_ty then
    Ineligible ArcBoxedScalarStorage
  else
    match classify_value_layout model source_elem_ty with
    | Eligible layout ->
        Eligible
          {
            sap_access = source_access_for_layout layout;
            sap_elem_ty = source_elem_ty;
          }
    | Ineligible reason -> Ineligible reason

let same_type_collect_policy_for_stages model ~filter_map_payload_policy
    ~(source_elem_ty : Ast.type_expr) ~(stage_value_tys : Ast.type_expr list)
    ~(result_ty : Ast.type_expr) : collect_policy eligibility =
  match
    same_type_source_access_policy model ~source_elem_ty ~stage_value_tys
  with
  | Ineligible reason -> Ineligible reason
  | Eligible source_policy -> (
      match collect_result_elem_ty model ~source_elem_ty ~result_ty with
      | Some result_elem_ty ->
          Eligible
            {
              source_access = source_policy.sap_access;
              result_elem_ty;
              filter_map_payload_policy;
            }
      | _ -> Ineligible NotSameTypeCollect)
