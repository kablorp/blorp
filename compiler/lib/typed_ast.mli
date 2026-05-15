(** Compatibility boundary between inferred AST and later typed phases.

    The parser AST still carries [expr_type : type_expr option] during the
    transition to a dedicated typed AST. This module provides an opaque wrapper
    for the subset later phases are allowed to consume: expressions with a
    present, finalized semantic type and no inference-only metas. *)

type expr
type func_decl
type var_decl
type record_decl
type type_alias_decl
type impl_decl
type decl
type program

type type_origin = Ast.expr_type_origin =
  | ExplicitAnnotation of Ast.type_expr
  | Inferred
  | Synthesized of string

type type_info = private {
  source_ty : Ast.type_expr option;
  semantic_ty : Ast.type_expr;
  value_ty : Ast.type_expr;
  origin : type_origin;
  widening : Type_widening_metadata.decision;
  proofs : Type_proof_metadata.expr_proofs;
}

type func_param_info = private {
  param_name : string option;
  source_param_ty : Ast.type_expr;
  semantic_param_ty : Ast.type_expr;
}

type func_info = private {
  source_return_ty : Ast.type_expr option;
  semantic_return_ty : Ast.type_expr;
  param_infos : func_param_info list;
}

type var_info = private {
  source_binding_ty : Ast.type_expr option;
  binding_ty : Ast.type_expr;
}

type record_field_info = private {
  field_name : string;
  source_field_ty : Ast.type_expr;
  semantic_field_ty : Ast.type_expr;
}

type record_info = private { field_infos : record_field_info list }

type type_alias_info = private {
  source_target_ty : Ast.type_expr;
  semantic_target_ty : Ast.type_expr;
}

type decl_view =
  | DeclFunction of func_decl
  | DeclVar of var_decl
  | DeclRecord of record_decl
  | DeclTypeAlias of type_alias_decl
  | DeclImpl of impl_decl
  | DeclPrivate of decl
  | DeclOther

type loop_view = {
  loop_view_kind : Ast.loop_view_kind;
  loop_view_source : expr;
  loop_view_size_arg : expr option;
  loop_view_elem_type : Ast.type_expr;
}

type string_interp_part = InterpLit of string | InterpExpr of expr

type match_case = {
  case_pattern : Ast.pattern;
  case_body : expr;
  case_loc : Ast.loc;
}

type expr_desc =
  | EIdent of string
  | ELiteral of Ast.literal
  | EBinary of Ast.binop * expr * expr
  | EUnary of Ast.unop * expr
  | ELogical of Ast.logop * expr * expr
  | EAscription of expr * Ast.type_expr
  | ECall of expr * expr list
  | EIf of expr * expr * expr option
  | EMatch of expr * match_case list
  | EBlock of expr list
  | ETuple of expr list
  | EVector of expr list
  | EList of expr list
  | ERecord of (string * expr) list
  | ERecordUpdate of expr * (string * expr) list
  | EFieldAccess of expr * string
  | ELambda of func_decl
  | EVoid
  | EWhile of expr * expr
  | EFor of string * expr * expr
  | EForTuple of string list * expr * expr
  | ELoopView of loop_view
  | EAssign of string * expr
  | EVarDecl of string * Ast.type_expr option * expr * bool
  | ETupleDestruct of string list * expr
  | ERange of expr * expr
  | EBreak
  | EContinue
  | ESubscript of expr * expr
  | ESubscriptMulti of expr * expr list
  | ESubscriptAssign of expr * expr list * expr
  | EStringInterp of string_interp_part list * bool
  | EStringInterpRaw of string * bool
  | ETry of expr list
  | ETryBind of string * Ast.type_expr option * expr
  | EDebugBlock of expr list
  | EConcurrent of expr list * expr option * int option
  | EConcurrentBind of string * Ast.type_expr option * expr
  | EConcurrentFor of string * expr * expr * expr option * int option
  | EDetach of expr
  | EDict of (expr * expr) list
  | EBuiltin of string option
  | EFuncDecl of func_decl

type error =
  | MissingExprType of { loc : Ast.loc; context : string }
  | MissingExprTypeInfo of { loc : Ast.loc; context : string }
  | UnfinalizedExprType of {
      loc : Ast.loc;
      context : string;
      ty : Ast.type_expr;
    }
  | MissingRequiredType of { loc : Ast.loc; context : string }
  | UnfinalizedType of { loc : Ast.loc; context : string; ty : Ast.type_expr }
  | InvalidTypeInfo of { loc : Ast.loc; context : string; message : string }

val of_ast_expr : ?context:string -> Ast.expr -> (expr, error) result

val of_ast_expr_with_type_info :
  ?context:string ->
  ?source_ty:Ast.type_expr ->
  ?origin:type_origin ->
  ?proofs:Type_proof_metadata.expr_proofs ->
  semantic_ty:Ast.type_expr ->
  value_ty:Ast.type_expr ->
  widening:Type_widening_metadata.decision ->
  Ast.expr ->
  (expr, error) result

val of_ast_func_decl : Ast.func_decl -> (func_decl, error) result
val of_ast_var_decl : Ast.var_decl -> (var_decl, error) result
val of_ast_decl : Ast.decl -> (decl, error) result
val of_ast_program : Ast.program -> (program, error) result

val of_ast_program_with_sources :
  source_program:Ast.program -> Ast.program -> (program, error) result

val map_inferred_program_types :
  (Ast.type_expr -> Ast.type_expr) -> Ast.program -> Ast.program
(** Compatibility boundary for whole-program type payload rewrites that must run
    after inference but before [Typed_ast] validation. This is intentionally
    narrow: callers provide only a type mapper, while this module owns the
    traversal over transitional AST type metadata. *)

val ast : expr -> Ast.expr
val expr_desc : expr -> (expr_desc, error) result
val func_ast : func_decl -> Ast.func_decl
val func_info : func_decl -> func_info
val func_param_infos : func_decl -> func_param_info list
val func_body_expr : func_decl -> (expr option, error) result
val func_semantic_return_type : func_decl -> Ast.type_expr
val var_ast : var_decl -> Ast.var_decl
val var_info : var_decl -> var_info
val var_value_expr : var_decl -> (expr, error) result
val var_binding_type : var_decl -> Ast.type_expr
val record_ast : record_decl -> Ast.record_decl
val record_info : record_decl -> record_info
val record_field_infos : record_decl -> record_field_info list
val type_alias_ast : type_alias_decl -> Ast.type_alias_decl
val type_alias_info : type_alias_decl -> type_alias_info
val type_alias_semantic_target_type : type_alias_decl -> Ast.type_expr
val impl_ast : impl_decl -> Ast.impl_decl
val impl_methods : impl_decl -> func_decl list
val decl_ast : decl -> Ast.decl
val decl_view : decl -> decl_view
val decl_func : decl -> func_decl option
val program_ast : program -> Ast.program
val program_decls : program -> decl list
val loc : expr -> Ast.loc
val type_info : expr -> type_info
val type_info_to_ast : type_info -> Ast.expr_type_info
val type_info_source_type : type_info -> Ast.type_expr option
val type_info_semantic_type : type_info -> Ast.type_expr
val type_info_value_type : type_info -> Ast.type_expr
val type_info_origin : type_info -> type_origin
val type_info_widening : type_info -> Type_widening_metadata.decision
val type_info_proofs : type_info -> Type_proof_metadata.expr_proofs
val semantic_type : expr -> Ast.type_expr
val value_type : expr -> Ast.type_expr
