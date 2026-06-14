(** Runtime values and execution context for compile-time evaluation.

    This module is intentionally data-only. The evaluator owns execution, while
    materialization and intrinsic support can share this representation without
    depending on the monolithic evaluator module. *)

type constructor_info = {
  constructor_parent_type : string;
  constructor_arity : int;
  constructor_callable_id : int option;
}

type closure = { closure_func : Typed_ast.func_decl; closure_env : env }

and value_desc =
  | VInt of int64
  | VFloat of float
  | VBool of bool
  | VChar of int
  | VString of string * Ast.string_flags
  | VTuple of value list
  | VList of value list
  | VDict of (value * value) list
  | VRecord of (string * value) list
  | VRange of value * value
  | VVoid
  | VClosure of closure
  | VConstructor of {
      name : string;
      args : value list;
      callee : Ast.expr option;
      resolved_call : Ast.resolved_call option;
      constructor_info : constructor_info option;
    }

and value = { ty : Ast.type_expr; desc : value_desc; loc : Ast.loc }
and binding = { mutable_binding : bool; cell : value ref }
and env = (string * binding) list

type option_state = OptionSome of value | OptionNone
type result_state = ResultOk of value | ResultErr of value
type function_table = (int * Typed_ast.func_decl) list

type ctx = {
  functions : function_table;
  constructor_info : string -> constructor_info option;
}
