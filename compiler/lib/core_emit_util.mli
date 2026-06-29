(** Small bridge helpers still needed by the Core -> JSON projector.

    Do not add C-emission helpers here. Emission belongs to the Blorp backend;
    this module only carries representation-neutral Core facts that the JSON
    projector still needs while the boundary moves left. *)

val collect_var_types : Core.core -> (string, Ast.type_expr) Hashtbl.t
(** Collect (variable name -> type) pairs for every [CVar] in an expression.
    Used by the JSON projector to recover the type of a binding at its use site. *)

val find_var_type : string -> (string, Ast.type_expr) Hashtbl.t -> Ast.type_expr
(** Look up a variable's type in a [collect_var_types] map. Falls back to
    [TyVar "?"] when the name is not recorded; the current caller treats this as
    advisory metadata. *)
