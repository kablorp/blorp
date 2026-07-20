(** Shared formatting for source/semantic/value-slot type metadata. *)

let type_to_string = Types.type_to_string

let collection_kind_to_string = function
  | Type_widening_metadata.ListLiteral -> "list literal element"
  | Type_widening_metadata.VectorLiteral -> "vector literal element"
  | Type_widening_metadata.DictLiteral -> "dict literal element"
  | Type_widening_metadata.SetLiteral -> "set literal element"

let binop_to_string = function
  | Ast.Add -> "+"
  | Ast.Sub -> "-"
  | Ast.Mul -> "*"
  | Ast.Div -> "/"
  | Ast.Mod -> "%"
  | Ast.Eq -> "=="
  | Ast.Ne -> "!="
  | Ast.Lt -> "<"
  | Ast.Gt -> ">"
  | Ast.Le -> "<="
  | Ast.Ge -> ">="

let widening_reason_to_string = function
  | Type_widening_metadata.MutableBinding -> "mutable binding"
  | Type_widening_metadata.ArgumentSlot -> "argument slot"
  | Type_widening_metadata.CollectionElement kind ->
      collection_kind_to_string kind
  | Type_widening_metadata.BitwiseOperator -> "bitwise operator"
  | Type_widening_metadata.MethodReceiver -> "method receiver"
  | Type_widening_metadata.RangeProofErasure -> "range proof erasure"
  | Type_widening_metadata.TupleLiteral -> "tuple literal"
  | Type_widening_metadata.NumericOperator op ->
      Printf.sprintf "numeric operator %s" (binop_to_string op)

let widening_to_string = function
  | Type_widening_metadata.Keep ty ->
      Printf.sprintf "none (kept %s)" (type_to_string ty)
  | Type_widening_metadata.Widen { from_ty; to_ty; reason } ->
      Printf.sprintf "%s (%s -> %s)"
        (widening_reason_to_string reason)
        (type_to_string from_ty) (type_to_string to_ty)

let widening_detail = function
  | Type_widening_metadata.Keep _ -> None
  | Type_widening_metadata.Widen _ as decision ->
      Some ("widening: " ^ widening_to_string decision)

let canonical_or_semantic_detail ~source_ty ~fallback_ty ~semantic_ty =
  match source_ty with
  | Some source_ty when not (Types.types_equal source_ty semantic_ty) ->
      Some ("canonical type: " ^ type_to_string semantic_ty)
  | _ when not (Types.types_equal fallback_ty semantic_ty) ->
      Some ("semantic type: " ^ type_to_string semantic_ty)
  | _ -> None

let value_slot_detail ~value_ty ~semantic_ty =
  if Types.types_equal value_ty semantic_ty then None
  else Some ("value-slot type: " ^ type_to_string value_ty)

let optional_details details =
  List.filter_map (function Some detail -> Some detail | None -> None) details

type hover_type_view = { primary_type : string; details : string list }

let hover_type_view ?fallback_ty (info : Ast.expr_type_info) =
  let fallback_ty =
    match fallback_ty with Some ty -> ty | None -> info.semantic_ty
  in
  let primary_ty =
    match info.source_ty with Some ty -> ty | None -> fallback_ty
  in
  let details =
    optional_details
      [
        canonical_or_semantic_detail ~source_ty:info.source_ty ~fallback_ty
          ~semantic_ty:info.semantic_ty;
        value_slot_detail ~value_ty:info.value_ty ~semantic_ty:info.semantic_ty;
        widening_detail info.widening;
      ]
  in
  { primary_type = type_to_string primary_ty; details }

let fallback_hover_type_view ty =
  { primary_type = type_to_string ty; details = [] }

let hover_type_view_for_expr ?fallback_ty (expr : Ast.expr) =
  match expr.expr_type_info with
  | Some info -> Some (hover_type_view ?fallback_ty info)
  | None -> Option.map fallback_hover_type_view fallback_ty
