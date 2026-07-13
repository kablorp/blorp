(** Debug formatting for typed AST payloads.

    This is intentionally diagnostic output, not a stable source formatter.
    It exposes type metadata that is otherwise difficult to inspect while
    hardening the typed pipeline. *)

val format_program : Typed_ast.program -> string
