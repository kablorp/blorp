(** Shared formatting for source/semantic/value-slot type metadata. *)

let type_to_string = Types.type_to_string

type source_spelling = SourceType of Ast.type_expr | NoSourceType

let source_spelling_of_optional_type = function
  | Some ty -> SourceType ty
  | None -> NoSourceType

let source_spelling_to_string = function
  | SourceType ty -> type_to_string ty
  | NoSourceType -> "<none>"

let type_origin_to_string = function
  | Ast.ExplicitAnnotation ty ->
      Printf.sprintf "explicit annotation (%s)" (type_to_string ty)
  | Ast.Inferred -> "inferred"
  | Ast.Synthesized label -> Printf.sprintf "synthesized (%s)" label

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

let format_debug_type_info (info : Ast.expr_type_info) =
  let source =
    "source type: "
    ^ source_spelling_to_string
        (source_spelling_of_optional_type info.source_ty)
  in
  let semantic = "semantic type: " ^ type_to_string info.semantic_ty in
  let value = "value-slot type: " ^ type_to_string info.value_ty in
  let origin = "origin: " ^ type_origin_to_string info.origin in
  let widening = "widening: " ^ widening_to_string info.widening in
  String.concat "; " [ source; semantic; value; origin; widening ]

type hover_type_view = { primary_type : string; details : string list }

let hover_type_view ?fallback_ty (info : Ast.expr_type_info) =
  let fallback_ty =
    match fallback_ty with Some ty -> ty | None -> info.semantic_ty
  in
  let primary_ty =
    match info.source_ty with Some ty -> ty | None -> fallback_ty
  in
  let details =
    match info.source_ty with
    | Some source_ty when not (Types.types_equal source_ty info.semantic_ty) ->
        [ "canonical type: " ^ type_to_string info.semantic_ty ]
    | _ when not (Types.types_equal fallback_ty info.semantic_ty) ->
        [ "semantic type: " ^ type_to_string info.semantic_ty ]
    | _ -> []
  in
  let details =
    if Types.types_equal info.value_ty info.semantic_ty then details
    else details @ [ "value-slot type: " ^ type_to_string info.value_ty ]
  in
  let details =
    match widening_detail info.widening with
    | Some detail -> details @ [ detail ]
    | None -> details
  in
  { primary_type = type_to_string primary_ty; details }

let fallback_hover_type_view ty =
  { primary_type = type_to_string ty; details = [] }
