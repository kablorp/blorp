(** Small bridge helpers still needed by the Core -> JSON projector.

    Do not add C-emission helpers here. Emission belongs to the Blorp backend;
    this module only carries representation-neutral Core facts that the JSON
    projector still needs while the boundary moves left. *)

open Core

(** Collect types for all variables used in an expression.
    Returns a map from variable name -> type, found from [CVar] usage. *)
let collect_var_types (e : core) : (string, Ast.type_expr) Hashtbl.t =
  let types = Hashtbl.create 8 in
  let _ =
    transform_bottom_up
      (fun node ->
        (match node.desc with
        | CVar v when not (Hashtbl.mem types v.vname) ->
            Hashtbl.replace types v.vname node.ty
        | _ -> ());
        node)
      e
  in
  types

(** Look up a variable's type in a [collect_var_types] map, or
    return [TyVar "?"] as a placeholder when not found. *)
let find_var_type (name : string) (types : (string, Ast.type_expr) Hashtbl.t) :
    Ast.type_expr =
  match Hashtbl.find_opt types name with Some ty -> ty | None -> Ast.TyVar "?"
