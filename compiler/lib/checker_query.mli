(** Diagnostic-free checker queries.

    These helpers answer cheap resolution questions for speculative checker
    paths. They must not format diagnostics, search edit-distance suggestions,
    or infer expressions. *)

val module_alias_path : (string * string) list -> string -> string option
(** Resolve an imported module alias without producing diagnostics. *)

val identifier_may_resolve_as_call_target : Env.env -> string -> bool
(** True when an identifier can cheaply resolve to a value that may be called. *)

val receiver_family : Ast.type_expr -> string option
(** Nominal family used for inexpensive UFCS candidate prefiltering. *)
