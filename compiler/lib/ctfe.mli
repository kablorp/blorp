(** Public boundary for compile-time evaluation.

    CTFE internals are intentionally split across focused modules. The rest of
    the compiler should only need constructor metadata for fallback lookups and
    the program rewrite entry point. *)

type constructor_info

val make_constructor_info :
  parent_type:string -> arity:int -> callable_id:int option -> constructor_info

val evaluate_program :
  ?constructor_info:(string -> constructor_info option) ->
  ?import_bindings:Session.import_binding list ->
  Typed_ast.program ->
  (Typed_ast.program, Ast.compiler_error list) result
