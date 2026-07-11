(** Explicit representation for recognized List pipelines.

    This module owns recognition and construction of list pipeline plans. The
    plan type is private so later optimization passes can rely on the key
    invariant: a plan always has at least one transformation stage. *)

type source = private
  | SourceList of { expr : Core.core; elem_ty : Ast.type_expr }
  | SourceRange of { start : Core.core; stop : Core.core }

type stage = private
  | StageFilter of { callback : Core.core; input_ty : Ast.type_expr }
  | StageMap of {
      callback : Core.core;
      input_ty : Ast.type_expr;
      output_ty : Ast.type_expr;
    }
  | StageFilterMap of {
      callback : Core.core;
      input_ty : Ast.type_expr;
      output_ty : Ast.type_expr;
      option_ty : Ast.type_expr;
    }

type cardinality = Exact | UpperBound | Terminal

type sink = private
  | SinkCollect of { result_ty : Ast.type_expr }
  | SinkFold of {
      init : Core.core;
      reducer : Core.core;
      acc_ty : Ast.type_expr;
    }
  | SinkLength

type nonempty_stages = private { first : stage; rest : stage list }

type t = private {
  source : source;
  stage_chain : nonempty_stages;
  sink : sink;
  cardinality : cardinality;
  result_ty : Ast.type_expr;
  loc : Ast.loc;
}

val list_elem_ty : Ast.type_expr -> Ast.type_expr option
val base_list_func_name : string -> string option
val call_base_and_args : Core.core -> (string * Core.core list) option
val plan_of_expr : Core.core -> t option
val source : t -> source
val stages : t -> stage list
val sink : t -> sink
val cardinality : t -> cardinality
val result_ty : t -> Ast.type_expr
val loc : t -> Ast.loc
val describe_plan : t -> string
