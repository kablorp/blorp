let local_type_names_from_decls (decls : Ast.program) : string list =
  let rec collect acc decl =
    match decl.Ast.decl_desc with
    | DPrivate inner -> collect acc inner
    | DRecord record -> record.record_name :: acc
    | DType type_decl -> type_decl.type_name :: acc
    | DTypeAlias alias -> alias.alias_name :: acc
    | _ -> acc
  in
  List.fold_left collect [] decls |> List.sort_uniq String.compare
