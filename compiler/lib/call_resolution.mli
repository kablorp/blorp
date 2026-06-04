(** Shared call-resolution metadata helpers.

    This module owns call metadata shape and small pure decisions. The recursive
    bidirectional expression checker still orchestrates callee/argument
    inference in [Infer]. *)

type callee_resolution = {
  callee_ty : Ast.type_expr;
  callee_expr : Ast.expr;
  source_callee : Ast.expr;
  args : Ast.expr list;
  resolved_trait : (string * string * bool * int option) option;
  resolved_target : Ast.resolved_call_target option;
  syntax_hint : Ast.call_syntax option;
}

val strip_callable_id_suffix : string -> string
val parse_callable_id_suffix : string -> int option
val is_ufcs_mangled_name : string -> bool
val call_purity_bool : Env.purity -> bool

val callable_origin_of_env :
  module_path:string option -> Env.func_origin -> Ast.callable_origin

val get_callee_name : Ast.expr -> string option
val has_flexible_lambda : Ast.expr list -> bool
val overload_pure_callback_count : Env.overload_entry -> int

val select_by_typed_args :
  Env.overload_entry list -> Ast.type_expr list -> Env.overload_entry option

val select_by_first_arg :
  Env.env -> string -> Ast.type_expr option -> Env.overload_entry option

val select_by_context_purity :
  current_function_pure:bool ->
  overloads:Env.overload_entry list ->
  first_arg_ty:Ast.type_expr option ->
  Env.overload_entry option

val call_syntax_of_source_callee :
  module_aliases:(string * string) list ->
  source_callee:Ast.expr ->
  Ast.resolved_call_target ->
  Ast.call_syntax

val resolved_target_from_overload :
  string -> Env.overload_entry -> Ast.resolved_call_target

val resolved_target_from_callee :
  env:Env.env ->
  callee_name:string option ->
  callee_ty:Ast.type_expr ->
  Ast.resolved_call_target option

val resolved_call_metadata :
  ?call_syntax_hint:Ast.call_syntax ->
  module_aliases:(string * string) list ->
  resolved_target_from_qualified:(Ast.expr -> Ast.resolved_call_target option) ->
  source_callee:Ast.expr ->
  resolved_callee:Ast.expr ->
  resolved_overload:Env.overload_entry option ->
  resolved_trait:(string * string * bool * int option) option ->
  resolved_target_hint:Ast.resolved_call_target option ->
  callee_ty:Ast.type_expr ->
  instantiated_params:Ast.type_expr list ->
  instantiated_return:Ast.type_expr ->
  Env.env ->
  Ast.resolved_call option
