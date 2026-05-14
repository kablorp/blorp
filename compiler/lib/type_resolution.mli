(** Centralized resolution for source-level type annotations.

    This module is the boundary where parsed type syntax is converted into the
    semantic type identity needed by typecheck and inference. Callers choose a
    named use case instead of spelling out the resolver chain locally. *)

type alias_policy = ExpandAliases | PreserveAliasSource
type context

type resolved_type = private {
  source : Ast.type_expr;
  canonical : Ast.type_expr;
}

val make_context :
  ?alias_policy:alias_policy ->
  env:Env.env ->
  module_aliases:(string * string) list ->
  unit ->
  context

val annotation :
  ?qualify_owner:(Ast.type_expr -> Ast.type_expr) ->
  context ->
  Ast.type_expr ->
  resolved_type

val annotation_canonical :
  ?qualify_owner:(Ast.type_expr -> Ast.type_expr) ->
  context ->
  Ast.type_expr ->
  Ast.type_expr

val value_ascription :
  ?qualify_owner:(Ast.type_expr -> Ast.type_expr) ->
  context ->
  Ast.type_expr ->
  resolved_type

val value_ascription_canonical :
  ?qualify_owner:(Ast.type_expr -> Ast.type_expr) ->
  context ->
  Ast.type_expr ->
  Ast.type_expr

val local_binding_annotation :
  ?qualify_owner:(Ast.type_expr -> Ast.type_expr) ->
  context ->
  Ast.type_expr ->
  resolved_type

val local_binding_annotation_canonical :
  ?qualify_owner:(Ast.type_expr -> Ast.type_expr) ->
  context ->
  Ast.type_expr ->
  Ast.type_expr

val function_parameter_annotation :
  ?qualify_owner:(Ast.type_expr -> Ast.type_expr) ->
  context ->
  Ast.type_expr ->
  resolved_type

val function_parameter_annotation_canonical :
  ?qualify_owner:(Ast.type_expr -> Ast.type_expr) ->
  context ->
  Ast.type_expr ->
  Ast.type_expr

val function_return_annotation :
  ?qualify_owner:(Ast.type_expr -> Ast.type_expr) ->
  context ->
  Ast.type_expr ->
  resolved_type

val function_return_annotation_canonical :
  ?qualify_owner:(Ast.type_expr -> Ast.type_expr) ->
  context ->
  Ast.type_expr ->
  Ast.type_expr

val imported_signature :
  ?qualify_owner:(Ast.type_expr -> Ast.type_expr) ->
  context ->
  Ast.type_expr ->
  resolved_type

val imported_signature_canonical :
  ?qualify_owner:(Ast.type_expr -> Ast.type_expr) ->
  context ->
  Ast.type_expr ->
  Ast.type_expr

val record_field_type :
  ?qualify_owner:(Ast.type_expr -> Ast.type_expr) ->
  context ->
  Ast.type_expr ->
  resolved_type

val record_field_type_canonical :
  ?qualify_owner:(Ast.type_expr -> Ast.type_expr) ->
  context ->
  Ast.type_expr ->
  Ast.type_expr

val variant_field_type :
  ?qualify_owner:(Ast.type_expr -> Ast.type_expr) ->
  context ->
  Ast.type_expr ->
  resolved_type

val variant_field_type_canonical :
  ?qualify_owner:(Ast.type_expr -> Ast.type_expr) ->
  context ->
  Ast.type_expr ->
  Ast.type_expr

val type_alias_target :
  ?qualify_owner:(Ast.type_expr -> Ast.type_expr) ->
  context ->
  Ast.type_expr ->
  resolved_type

val type_alias_target_canonical :
  ?qualify_owner:(Ast.type_expr -> Ast.type_expr) ->
  context ->
  Ast.type_expr ->
  Ast.type_expr

val source : resolved_type -> Ast.type_expr
val canonical : resolved_type -> Ast.type_expr
