(** Debug formatting for typed AST payloads. *)

let type_to_string = Types.type_to_string

let source_spelling_to_string ty =
  Type_metadata_format.(
    source_spelling_to_string (source_spelling_of_optional_type ty))

let format_type_info info =
  Type_metadata_format.format_debug_type_info (Typed_ast.type_info_to_ast info)

let indent depth = String.make (depth * 2) ' '

let literal_label = function
  | Ast.LitInt n -> Printf.sprintf "literal_int %Ld" n
  | Ast.LitInt128 n -> Printf.sprintf "literal_int128 %s" n
  | Ast.LitFloat f -> Printf.sprintf "literal_float %g" f
  | Ast.LitString _ -> "literal_string"
  | Ast.LitBool b -> Printf.sprintf "literal_bool %b" b
  | Ast.LitChar c -> Printf.sprintf "literal_char %d" c

let binop_label = function
  | Ast.Add -> "binary Add"
  | Ast.Sub -> "binary Sub"
  | Ast.Mul -> "binary Mul"
  | Ast.Div -> "binary Div"
  | Ast.Mod -> "binary Mod"
  | Ast.Eq -> "binary Eq"
  | Ast.Ne -> "binary Ne"
  | Ast.Lt -> "binary Lt"
  | Ast.Gt -> "binary Gt"
  | Ast.Le -> "binary Le"
  | Ast.Ge -> "binary Ge"

let expr_label (expr : Ast.expr) =
  match expr.expr_desc with
  | EIdent name -> "ident " ^ name
  | ELiteral lit -> literal_label lit
  | EBinary (op, _, _) -> binop_label op
  | EUnary _ -> "unary"
  | ELogical _ -> "logical"
  | EAscription _ -> "ascription"
  | ECall _ -> "call"
  | EIf _ -> "if"
  | EMatch _ -> "match"
  | EBlock _ -> "block"
  | ETuple _ -> "tuple"
  | EVector _ -> "vector"
  | EList _ -> "list"
  | ERecord _ -> "record"
  | ERecordUpdate _ -> "record_update"
  | EFieldAccess (_, field) -> "field_access " ^ field
  | ELambda _ -> "lambda"
  | EVoid -> "void"
  | EWhile _ -> "while"
  | EFor (name, _, _) -> "for " ^ name
  | EForTuple _ -> "for_tuple"
  | ELoopView _ -> "loop_view"
  | EAssign (name, _) -> "assign " ^ name
  | EVarDecl (name, _, _, is_mutable) ->
      if is_mutable then "var_decl mutable " ^ name else "var_decl " ^ name
  | ETupleDestruct _ -> "tuple_destruct"
  | ERange _ -> "range"
  | EBreak -> "break"
  | EContinue -> "continue"
  | ESubscript _ -> "subscript"
  | ESubscriptMulti _ -> "subscript_multi"
  | ESubscriptAssign _ -> "subscript_assign"
  | EStringInterp _ -> "string_interp"
  | EStringInterpRaw _ -> "string_interp_raw"
  | EQuestionBind (name, _, _) -> "question_bind " ^ name
  | EWith (binding, _) -> "with " ^ binding.with_name
  | EDebugBlock _ -> "debug_block"
  | EConcurrent _ -> "concurrent"
  | EConcurrentBind (name, _, _) -> "concurrent_bind " ^ name
  | EConcurrentFor (name, _, _, _, _) -> "concurrent_for " ^ name
  | EDetach _ -> "detach"
  | EDict _ -> "dict"
  | EBuiltin None -> "builtin"
  | EBuiltin (Some name) -> "builtin " ^ name
  | EFuncDecl _ -> "func_decl"

let typed_func_body_children func =
  match Typed_ast.func_body_expr func with
  | Ok (Some body) -> [ body ]
  | _ -> []

let expr_children_from_desc = function
  | Typed_ast.EIdent _ | ELiteral _ | EVoid | EBuiltin _ | EBreak | EContinue
  | EStringInterpRaw _ ->
      []
  | EUnary (_, expr)
  | EAscription (expr, _)
  | EFieldAccess (expr, _)
  | EAssign (_, expr)
  | EQuestionBind (_, _, expr)
  | EConcurrentBind (_, _, expr)
  | EDetach expr ->
      [ expr ]
  | EWith (binding, body) -> [ binding.with_value; body ]
  | EBinary (_, left, right)
  | ELogical (_, left, right)
  | EWhile (left, right)
  | EFor (_, left, right)
  | EForTuple (_, left, right)
  | ERange (left, right)
  | ESubscript (left, right) ->
      [ left; right ]
  | ELoopView view ->
      view.loop_view_source
      ::
      (match view.loop_view_size_arg with
      | Some expr -> [ expr ]
      | None -> [])
  | ECall (callee, args) -> callee :: args
  | EIf (cond, then_, else_) ->
      cond :: then_ :: (match else_ with Some expr -> [ expr ] | None -> [])
  | EMatch (scrutinee, cases) ->
      scrutinee :: List.map (fun case -> case.Typed_ast.case_body) cases
  | EBlock exprs
  | ETuple exprs
  | EVector exprs
  | EList exprs
  | EDebugBlock exprs
  | EConcurrent (exprs, None, _) ->
      exprs
  | EConcurrent (exprs, Some timeout, _) -> exprs @ [ timeout ]
  | ERecord fields -> List.map snd fields
  | ERecordUpdate (base, fields) -> base :: List.map snd fields
  | ELambda func | EFuncDecl func -> typed_func_body_children func
  | EVarDecl (_, _, init, _) | ETupleDestruct (_, init) -> [ init ]
  | ESubscriptMulti (coll, indices) -> coll :: indices
  | ESubscriptAssign (coll, indices, value) -> coll :: (indices @ [ value ])
  | EStringInterp (parts, _) ->
      List.filter_map
        (function
          | Typed_ast.InterpLit _ -> None | InterpExpr expr -> Some expr)
        parts
  | EConcurrentFor (_, iter, body, None, _) -> [ iter; body ]
  | EConcurrentFor (_, iter, body, Some timeout, _) -> [ iter; body; timeout ]
  | EDict pairs -> List.concat_map (fun (key, value) -> [ key; value ]) pairs

let rec format_expr depth expr =
  let ast = Typed_ast.ast expr in
  let line =
    Printf.sprintf "%s%s {%s}" (indent depth) (expr_label ast)
      (format_type_info (Typed_ast.type_info expr))
  in
  let child_lines =
    match Typed_ast.expr_desc expr with
    | Ok desc ->
        List.map (format_expr (depth + 1)) (expr_children_from_desc desc)
    | Error _ ->
        [ Printf.sprintf "%s<invalid typed children>" (indent (depth + 1)) ]
  in
  String.concat "\n" (line :: child_lines)

let format_func depth func =
  let ast = Typed_ast.func_ast func in
  let info = Typed_ast.func_info func in
  let name = Option.value ast.func_name ~default:"<lambda>" in
  let source =
    "source return type: " ^ source_spelling_to_string info.source_return_ty
  in
  let semantic =
    "semantic return type: " ^ type_to_string info.semantic_return_ty
  in
  let header =
    Printf.sprintf "%sfunc %s {%s}" (indent depth) name
      (String.concat "; " [ source; semantic ])
  in
  match Typed_ast.func_body_expr func with
  | Ok (Some body) -> header ^ "\n" ^ format_expr (depth + 1) body
  | Ok None -> header
  | Error _ -> header ^ "\n" ^ indent (depth + 1) ^ "<invalid typed body>"

let format_var depth var =
  let ast = Typed_ast.var_ast var in
  let info = Typed_ast.var_info var in
  let name = Option.value ast.var_name ~default:"_" in
  let source =
    "source binding type: " ^ source_spelling_to_string info.source_binding_ty
  in
  let binding = "binding value-slot type: " ^ type_to_string info.binding_ty in
  let header =
    Printf.sprintf "%svar %s {%s}" (indent depth) name
      (String.concat "; " [ source; binding ])
  in
  match Typed_ast.var_value_expr var with
  | Ok value -> header ^ "\n" ^ format_expr (depth + 1) value
  | Error _ -> header ^ "\n" ^ indent (depth + 1) ^ "<invalid typed value>"

let format_record depth record =
  let ast = Typed_ast.record_ast record in
  let label = if ast.record_is_value then "struct" else "record" in
  let fields =
    record |> Typed_ast.record_field_infos
    |> List.map (fun (field : Typed_ast.record_field_info) ->
        Printf.sprintf "%s%s: %s {semantic: %s}"
          (indent (depth + 1))
          field.field_name
          (type_to_string field.source_field_ty)
          (type_to_string field.semantic_field_ty))
    |> String.concat "\n"
  in
  let header = Printf.sprintf "%s%s %s" (indent depth) label ast.record_name in
  if fields = "" then header else header ^ "\n" ^ fields

let format_type_alias depth alias =
  let ast = Typed_ast.type_alias_ast alias in
  let info = Typed_ast.type_alias_info alias in
  Printf.sprintf "%stype_alias %s = %s {semantic: %s}" (indent depth)
    ast.alias_name
    (type_to_string info.source_target_ty)
    (type_to_string info.semantic_target_ty)

let decl_label decl =
  match (Typed_ast.decl_ast decl).decl_desc with
  | Ast.DType t -> "union " ^ t.type_name
  | Ast.DRecord r ->
      if r.record_is_value then "struct " ^ r.record_name
      else "record " ^ r.record_name
  | Ast.DImport i -> "import " ^ i.import_module
  | Ast.DTrait t -> "trait " ^ t.trait_name
  | Ast.DImpl i -> "impl " ^ i.impl_trait
  | Ast.DTypeAlias a -> "type_alias " ^ a.alias_name
  | Ast.DPrivate _ | Ast.DFunc _ | Ast.DVar _ -> "decl"

let rec format_decl depth decl =
  match Typed_ast.decl_view decl with
  | DeclFunction func -> format_func depth func
  | DeclVar var -> format_var depth var
  | DeclRecord record -> format_record depth record
  | DeclTypeAlias alias -> format_type_alias depth alias
  | DeclImpl impl ->
      let ast = Typed_ast.impl_ast impl in
      let header =
        Printf.sprintf "%simpl %s for %s" (indent depth) ast.impl_trait
          (type_to_string ast.impl_for_type)
      in
      let methods =
        impl |> Typed_ast.impl_methods
        |> List.map (format_func (depth + 1))
        |> String.concat "\n"
      in
      if methods = "" then header else header ^ "\n" ^ methods
  | DeclPrivate inner ->
      Printf.sprintf "%sprivate\n%s" (indent depth)
        (format_decl (depth + 1) inner)
  | DeclOther -> Printf.sprintf "%s%s" (indent depth) (decl_label decl)

let format_program program =
  program |> Typed_ast.program_decls
  |> List.map (format_decl 0)
  |> String.concat "\n"
