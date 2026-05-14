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

let value_type slot =
  match slot.decision with Keep ty -> ty | Widen { to_ty; _ } -> to_ty

let decision slot = slot.decision

let widening_reason slot =
  match slot.decision with Keep _ -> None | Widen { reason; _ } -> Some reason

let collection_kind_to_string = function
  | ListLiteral -> "ListLiteral"
  | VectorLiteral -> "VectorLiteral"
  | DictLiteral -> "DictLiteral"
  | SetLiteral -> "SetLiteral"

let binop_to_string = function
  | Add -> "Add"
  | Sub -> "Sub"
  | Mul -> "Mul"
  | Div -> "Div"
  | Mod -> "Mod"
  | Eq -> "Eq"
  | Ne -> "Ne"
  | Lt -> "Lt"
  | Gt -> "Gt"
  | Le -> "Le"
  | Ge -> "Ge"

let reason_to_string = function
  | MutableBinding -> "MutableBinding"
  | ArgumentSlot -> "ArgumentSlot"
  | CollectionElement kind ->
      Printf.sprintf "CollectionElement(%s)" (collection_kind_to_string kind)
  | BitwiseOperator -> "BitwiseOperator"
  | MethodReceiver -> "MethodReceiver"
  | NumericOperator op ->
      Printf.sprintf "NumericOperator(%s)" (binop_to_string op)

let decision_to_string = function
  | Keep ty -> Printf.sprintf "Keep(%s)" (Types.type_to_string ty)
  | Widen { from_ty; to_ty; reason } ->
      Printf.sprintf "%s(%s -> %s)" (reason_to_string reason)
        (Types.type_to_string from_ty)
        (Types.type_to_string to_ty)

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

let mutable_binding_slot semantic_ty =
  singleton_int_slot MutableBinding semantic_ty

let argument_slot ~param_ty ~arg_ty =
  match param_ty with
  | TyMeta id when not (Types.Dim.is_var_name (Types.meta_origin_name id)) ->
      singleton_int_slot ArgumentSlot arg_ty
  | TySelf -> singleton_int_slot ArgumentSlot arg_ty
  | _ -> keep_slot arg_ty

let argument_target_slot ~param_ty semantic_ty =
  let can_use_concrete_target target_ty =
    match (target_ty, semantic_ty) with
    | TyNamed ("Int", []), TyConstInt _ -> true
    | _ -> false
  in
  match param_ty with
  | TyMeta id when not (Types.Dim.is_var_name (Types.meta_origin_name id)) ->
      singleton_int_slot ArgumentSlot semantic_ty
  | TySelf -> singleton_int_slot ArgumentSlot semantic_ty
  | ty when Types.collect_type_vars ty <> [] -> keep_slot semantic_ty
  | ty when Types.Dim.is_value_dim ty -> keep_slot semantic_ty
  | TyVarDims _ -> keep_slot semantic_ty
  | target_ty when can_use_concrete_target target_ty ->
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
