(** Leaf layout helpers shared by the Core -> JSON projector and Blorp-owned
    prepared renderers.

    This module intentionally depends only on layout/type facts, not on
    [Core_emit_util] or backend emission modules. Keeping it low in the
    dependency graph lets the single Blorp backend facade depend on prepared
    renderers without creating cycles through shared emitter utilities. *)

open Core

let list_storage_mode_pointer_arg = "BLORP_LIST_STORAGE_POINTER"
let list_storage_mode_inline_arg = "BLORP_LIST_STORAGE_INLINE"
let list_element_size_pointer_arg = "sizeof(void*)"

let list_runtime_storage_args (layout : Core.list_storage_layout) :
    string * string =
  match layout.lsl_slots with
  | Core.ListPointerStorage ->
      (list_storage_mode_pointer_arg, list_element_size_pointer_arg)
  | Core.ListInlineStorage width ->
      ( list_storage_mode_inline_arg,
        string_of_int (Core.inline_storage_width_bytes width) )
  | Core.ListInlineStructStorage c_ty ->
      (list_storage_mode_inline_arg, Printf.sprintf "sizeof(%s)" c_ty)

let tensor_element_storage_for_reg ~reg elem_ty =
  Core_layout_type.tensor_element_storage ~reg elem_ty

let tensor_storage_layout_of_type_for_reg ~reg tensor_ty loc =
  Core_layout_type.tensor_storage_layout_of_type ~reg tensor_ty loc

let c_type_for_reg ~reg ty = Core_layout_type.c_type ~reg ty

let final_phase = Core_error.Stage Core_stage.Final

let emit_phase = Core_error.Emit

let boxed_storage_needs_release ~reg ty loc =
  Core_layout_type.boxed_storage_requires_release_or_error ~phase:final_phase
    ~reg ty loc

let canonical_type ~reg ty = Core_layout_type.canonical_type ~reg ty

let classify_box_kind ~reg ty loc =
  Core_layout_type.box_kind_of_type ~phase:final_phase ~reg ty loc

let release_policy_tag ~reg (ty : Ast.type_expr) =
  if
    not
      (Core_layout_type.source_value_requires_release_or_error
         ~phase:emit_phase ~reg ty Ast.dummy_loc)
  then "none"
  else if Core_layout_type.is_stack_result_type ~reg ty then "stack_result"
  else
    let layout =
      Core_layout_type.source_value_layout_of_type ~phase:emit_phase ~reg ty
        Ast.dummy_loc
    in
    match Core_layout_type.source_value_release_path layout with
    | Core_layout_type.SourceValueArcReleaseOnly -> "arc_only"
    | Core_layout_type.SourceValueArcReleaseWithDestructor -> "arc"
    | Core_layout_type.SourceValueNoRelease -> "none"

let retain_policy_tag ~reg (ty : Ast.type_expr) =
  if
    not
      (Core_layout_type.source_value_requires_retain_or_error ~phase:emit_phase
         ~reg ty Ast.dummy_loc)
  then "none"
  else if Core_layout_type.is_stack_result_type ~reg ty then "stack_result"
  else "arc"

let union_field_release_policy_tag ~reg payload_storage field_ty loc =
  match payload_storage with
  | Codegen_types.TypedUnionPayloadStorage -> release_policy_tag ~reg field_ty
  | Codegen_types.ErasedUnionPayloadStorage
    when match field_ty with Ast.TyVar _ | Ast.TyBoundVar _ -> true | _ -> false
    ->
      "arc"
  | Codegen_types.ErasedUnionPayloadStorage ->
      if boxed_storage_needs_release ~reg field_ty loc then "arc" else "none"

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

let dict_value_needs_release ~reg dict_ty loc =
  match canonical_type ~reg dict_ty with
  | Ast.TyNamed ("Dict", [ _key_ty; value_ty ]) ->
      boxed_storage_needs_release ~reg value_ty loc
  | _ -> false
