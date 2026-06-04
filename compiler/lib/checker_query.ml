(** Diagnostic-free checker queries. *)

let module_alias_path module_aliases name = List.assoc_opt name module_aliases

let identifier_may_resolve_as_call_target env name =
  match Env.lookup env name with
  | Some
      { kind = Env.FuncSymbol _ | Env.VarSymbol _ | Env.ConstructorSymbol _; _ }
    ->
      true
  | Some _ -> false
  | None ->
      Option.is_some (Env.get_constructor env name)
      || Option.is_some (Env.get_function_trait env name)

let receiver_family = function
  | Ast.TyNamed (name, _) -> Some name
  | Ast.TyArray _ -> Some Types.array_head_name
  | _ -> None
