(** Shared formatting for source/semantic/value-slot type metadata.

    This module is for diagnostics and tooling surfaces. It does not infer,
    normalize, widen, or otherwise change type semantics. *)

type source_spelling = private SourceType of Ast.type_expr | NoSourceType

val source_spelling_of_optional_type : Ast.type_expr option -> source_spelling
val source_spelling_to_string : source_spelling -> string
val format_debug_type_info : Ast.expr_type_info -> string

type hover_type_view = private { primary_type : string; details : string list }

val hover_type_view :
  ?fallback_ty:Ast.type_expr -> Ast.expr_type_info -> hover_type_view

val hover_type_view_for_expr :
  ?fallback_ty:Ast.type_expr -> Ast.expr -> hover_type_view option
