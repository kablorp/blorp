(** Explicit type widening decisions.

    Inference sometimes needs an ergonomic runtime slot type that is less
    precise than an expression's semantic type. This module centralizes those
    decisions so callers record why precision was intentionally widened instead
    of silently rewriting type data. *)

open Ast

type collection_kind = Type_widening_metadata.collection_kind =
  | ListLiteral
  | VectorLiteral
  | DictLiteral
  | SetLiteral

type reason = Type_widening_metadata.reason =
  | MutableBinding
  | ArgumentSlot
  | CollectionElement of collection_kind
  | BitwiseOperator
  | MethodReceiver
  | NumericOperator of binop

type decision = Type_widening_metadata.decision =
  | Keep of type_expr
  | Widen of { from_ty : type_expr; to_ty : type_expr; reason : reason }

type value_slot = { semantic_ty : type_expr; decision : decision }

let semantic_type slot = slot.semantic_ty
let decision slot = slot.decision
let decision_value_type = function Keep ty -> ty | Widen { to_ty; _ } -> to_ty

let value_type slot = decision_value_type slot.decision

let keep_slot semantic_ty = { semantic_ty; decision = Keep semantic_ty }
let scalar_int_value_type ty = Types.Dim.lift_to_int ty

let is_scalar_int_value_type ty =
  Types.types_equal (scalar_int_value_type ty) Types.ty_int

let target_slot reason ~semantic_ty ~value_ty =
  if Types.types_equal semantic_ty value_ty then keep_slot semantic_ty
  else
    {
      semantic_ty;
      decision = Widen { from_ty = semantic_ty; to_ty = value_ty; reason };
    }

let singleton_int_slot reason semantic_ty =
  match semantic_ty with
  | TyConstInt _ -> target_slot reason ~semantic_ty ~value_ty:Types.ty_int
  | _ -> keep_slot semantic_ty

let dim_operand_slot reason semantic_ty =
  target_slot reason ~semantic_ty ~value_ty:(scalar_int_value_type semantic_ty)

let param_accepts_singleton_argument_widening = function
  | TyMeta id -> not (Types.Dim.is_var_name (Types.meta_origin_name id))
  | TySelf -> true
  | _ -> false

let can_use_concrete_argument_target ~target_ty ~semantic_ty =
  match (target_ty, semantic_ty) with
  | TyNamed ("Int", []), TyConstInt _ -> true
  | _ -> false

let target_keeps_semantic_slot = function
  | ty when Types.collect_type_vars ty <> [] -> true
  | ty when Types.Dim.is_value_dim ty -> true
  | TyVarDims _ -> true
  | _ -> false

let mutable_binding_slot semantic_ty =
  singleton_int_slot MutableBinding semantic_ty

let argument_slot ~param_ty ~arg_ty =
  if param_accepts_singleton_argument_widening param_ty then
    singleton_int_slot ArgumentSlot arg_ty
  else keep_slot arg_ty

let argument_target_slot ~param_ty semantic_ty =
  match param_ty with
  | ty when param_accepts_singleton_argument_widening ty ->
      singleton_int_slot ArgumentSlot semantic_ty
  | ty when target_keeps_semantic_slot ty -> keep_slot semantic_ty
  | target_ty when can_use_concrete_argument_target ~target_ty ~semantic_ty ->
      target_slot ArgumentSlot ~semantic_ty ~value_ty:target_ty
  | _ -> keep_slot semantic_ty

let collection_element_slot kind semantic_ty =
  singleton_int_slot (CollectionElement kind) semantic_ty

let collection_element_target_slot kind ~target_ty semantic_ty =
  target_slot (CollectionElement kind) ~semantic_ty ~value_ty:target_ty

let bitwise_operand_slot semantic_ty =
  singleton_int_slot BitwiseOperator semantic_ty

let bitwise_operand_target_slot ~target_ty semantic_ty =
  target_slot BitwiseOperator ~semantic_ty ~value_ty:target_ty

let method_receiver_slot semantic_ty =
  singleton_int_slot MethodReceiver semantic_ty

let numeric_operand_slot op semantic_ty =
  dim_operand_slot (NumericOperator op) semantic_ty

let numeric_operand_type op ty = numeric_operand_slot op ty |> value_type
