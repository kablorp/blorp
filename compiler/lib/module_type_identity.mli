(** Module-local type identity helpers.

    Public signatures that cross module boundaries must owner-qualify names for
    module-local records, unions, and aliases. Keep that syntactic inventory in
    one place so typecheck, inference, and pipeline coherence agree. *)

val local_type_names_from_decls : Ast.program -> string list
(** Return sorted unique record, union/resource/builtin type, and type-alias
    names declared directly by a module. Private wrappers are transparent for
    identity purposes. *)
