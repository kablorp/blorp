(** JSON serialization for expression-formatting parity cases.

    This is a temporary dogfooding boundary while the formatter printer moves
    from OCaml to Blorp in slices. OCaml still owns parsing and the reference
    expression printer; Blorp consumes this supported expression subset and
    must render the same layout. *)

module Layout = Fmt_layout
module Printer = Fmt_printer

let string = Fmt_doc_json.string
let bool b = if b then "true" else "false"
let field name value = Printf.sprintf "%s:%s" (string name) value
let obj fields = Printf.sprintf "{%s}" (String.concat "," fields)
let array values = Printf.sprintf "[%s]" (String.concat "," values)

let optional_field name = function
  | None -> []
  | Some value -> [ field name value ]

let option_map_all f values =
  let rec loop acc = function
    | [] -> Some (List.rev acc)
    | value :: rest -> (
        match f value with
        | Some mapped -> loop (mapped :: acc) rest
        | None -> None)
  in
  loop [] values

let option_map_opt f = function
  | None -> Some None
  | Some value -> Option.map (fun mapped -> Some mapped) (f value)

let optional_int_field name = function
  | None -> []
  | Some value -> [ field name (string_of_int value) ]

let float_literal_source f =
  (* Blorp lexer requires decimal notation, so mirror [Fmt_printer.print_literal]. *)
  let rec try_precision n =
    if n > 20 then Printf.sprintf "%.20f" f
    else
      let s = Printf.sprintf "%.*f" n f in
      if float_of_string s = f then s else try_precision (n + 1)
  in
  try_precision 1

let dim_op_to_json = function
  | Ast.DimAdd -> "Add"
  | Ast.DimSub -> "Sub"
  | Ast.DimMul -> "Mul"
  | Ast.DimDiv -> "Div"

let rec type_expr_to_json = function
  | Ast.TyNamed (name, args) ->
      obj
        [
          field "tag" (string "Named");
          field "name" (string name);
          field "args" (array (List.map type_expr_to_json args));
        ]
  | Ast.TyArray (elem, dims) ->
      obj
        [
          field "tag" (string "Array");
          field "elem" (type_expr_to_json elem);
          field "dims" (array (List.map type_expr_to_json dims));
        ]
  | Ast.TyFunc { params; return; is_pure } ->
      obj
        [
          field "tag" (string "Func");
          field "pure" (bool is_pure);
          field "params" (array (List.map type_expr_to_json params));
          field "return" (type_expr_to_json return);
        ]
  | Ast.TyVar name ->
      obj [ field "tag" (string "Var"); field "name" (string name) ]
  | Ast.TyBoundVar param ->
      obj
        [
          field "tag" (string "BoundVar");
          field "source" (string (Ast.type_param_to_parser_string param));
        ]
  | Ast.TyConstInt value ->
      obj
        [ field "tag" (string "ConstInt"); field "value" (string_of_int value) ]
  | Ast.TyTuple elems ->
      obj
        [
          field "tag" (string "Tuple");
          field "elems" (array (List.map type_expr_to_json elems));
        ]
  | Ast.TySelf -> obj [ field "tag" (string "Self") ]
  | Ast.TyVarDims name ->
      obj [ field "tag" (string "VarDims"); field "name" (string name) ]
  | Ast.TyRange inner ->
      obj
        [
          field "tag" (string "Range"); field "inner" (type_expr_to_json inner);
        ]
  | Ast.TyDimOp (op, left, right) ->
      obj
        [
          field "tag" (string "DimOp");
          field "op" (string (dim_op_to_json op));
          field "left" (type_expr_to_json left);
          field "right" (type_expr_to_json right);
        ]
  | Ast.TyMeta id ->
      obj [ field "tag" (string "Meta"); field "id" (string_of_int id) ]

let literal_to_json = function
  | Ast.LitInt value ->
      obj
        [
          field "tag" (string "Int");
          field "value" (string (Int64.to_string value));
        ]
  | Ast.LitInt128 value ->
      obj [ field "tag" (string "Int128"); field "value" (string value) ]
  | Ast.LitFloat value ->
      obj
        [
          field "tag" (string "Float");
          field "value" (string (float_literal_source value));
        ]
  | Ast.LitString (text, flags) ->
      obj
        [
          field "tag" (string "String");
          field "text" (string text);
          field "raw" (bool flags.Ast.sf_raw);
          field "triple" (bool flags.Ast.sf_triple);
        ]
  | Ast.LitBool value ->
      obj [ field "tag" (string "Bool"); field "value" (bool value) ]
  | Ast.LitChar value ->
      obj [ field "tag" (string "Char"); field "value" (string_of_int value) ]

let unary_op_to_json = function Ast.Neg -> "Neg" | Ast.Not -> "Not"

let binary_op_to_json = function
  | Ast.Add -> "Add"
  | Ast.Sub -> "Sub"
  | Ast.Mul -> "Mul"
  | Ast.Div -> "Div"
  | Ast.Mod -> "Mod"
  | Ast.Lt -> "Lt"
  | Ast.Gt -> "Gt"
  | Ast.Le -> "Le"
  | Ast.Ge -> "Ge"
  | Ast.Eq -> "Eq"
  | Ast.Ne -> "Ne"

let logical_op_to_json = function Ast.And -> "And" | Ast.Or -> "Or"

let record_field_to_json (name, expr_json) =
  obj [ field "name" (string name); field "value" expr_json ]

let dict_entry_to_json (key_json, value_json) =
  obj [ field "key" key_json; field "value" value_json ]

let string_array values = array (List.map string values)

let rec pattern_to_json = function
  | Ast.PatWildcard -> obj [ field "tag" (string "Wildcard") ]
  | Ast.PatVar name ->
      obj [ field "tag" (string "Var"); field "name" (string name) ]
  | Ast.PatConstructor (name, args) ->
      obj
        [
          field "tag" (string "Constructor");
          field "name" (string name);
          field "args" (array (List.map pattern_to_json args));
        ]
  | Ast.PatLiteral lit ->
      obj
        [
          field "tag" (string "Literal"); field "literal" (literal_to_json lit);
        ]
  | Ast.PatTuple elems ->
      obj
        [
          field "tag" (string "Tuple");
          field "elems" (array (List.map pattern_to_json elems));
        ]
  | Ast.PatQualified (module_name, name, args) ->
      obj
        [
          field "tag" (string "Qualified");
          field "module" (string module_name);
          field "name" (string name);
          field "args" (array (List.map pattern_to_json args));
        ]
  | Ast.PatList (elems, spread) ->
      obj
        ([
           field "tag" (string "List");
           field "elems" (array (List.map pattern_to_json elems));
         ]
        @ optional_field "spread" (Option.map pattern_to_json spread))
  | Ast.PatOr patterns ->
      obj
        [
          field "tag" (string "Or");
          field "patterns" (array (List.map pattern_to_json patterns));
        ]

let param_to_json param =
  match
    (param.Ast.param_pattern, param.Ast.param_name, param.Ast.param_type)
  with
  | Some pattern, _, Some ty ->
      obj
        [
          field "tag" (string "TypedPattern");
          field "pattern" (pattern_to_json pattern);
          field "type" (type_expr_to_json ty);
        ]
  | Some pattern, _, None ->
      obj
        [
          field "tag" (string "Pattern");
          field "pattern" (pattern_to_json pattern);
        ]
  | None, Some name, Some ty ->
      obj
        [
          field "tag" (string "TypedName");
          field "name" (string name);
          field "type" (type_expr_to_json ty);
        ]
  | None, Some name, None ->
      obj [ field "tag" (string "Name"); field "name" (string name) ]
  | None, None, Some ty ->
      obj
        [
          field "tag" (string "TypedName");
          field "name" (string "_");
          field "type" (type_expr_to_json ty);
        ]
  | None, None, None ->
      obj [ field "tag" (string "Name"); field "name" (string "_") ]

let rec expr_to_json expr =
  match expr.Ast.expr_desc with
  | Ast.EIdent name ->
      Some (obj [ field "tag" (string "Ident"); field "name" (string name) ])
  | Ast.ELiteral lit ->
      Some
        (obj
           [
             field "tag" (string "Literal");
             field "literal" (literal_to_json lit);
           ])
  | Ast.EVoid -> Some (obj [ field "tag" (string "Void") ])
  | Ast.EBreak -> Some (obj [ field "tag" (string "Break") ])
  | Ast.EContinue -> Some (obj [ field "tag" (string "Continue") ])
  | Ast.EBuiltin None -> Some (obj [ field "tag" (string "Builtin") ])
  | Ast.EBuiltin (Some name) ->
      Some
        (obj
           [ field "tag" (string "BuiltinRuntime"); field "name" (string name) ])
  | Ast.EFieldAccess (receiver, field_name) -> (
      match expr_to_json receiver with
      | None -> None
      | Some receiver_json ->
          Some
            (obj
               [
                 field "tag" (string "FieldAccess");
                 field "receiver" receiver_json;
                 field "field" (string field_name);
               ]))
  | Ast.ECall (callee, args) -> (
      match (expr_to_json callee, option_map_all expr_to_json args) with
      | Some callee_json, Some arg_jsons ->
          Some
            (obj
               [
                 field "tag" (string "Call");
                 field "callee" callee_json;
                 field "args" (array arg_jsons);
               ])
      | _ -> None)
  | Ast.EUnary (op, inner) -> (
      match expr_to_json inner with
      | None -> None
      | Some inner_json ->
          Some
            (obj
               [
                 field "tag" (string "Unary");
                 field "op" (string (unary_op_to_json op));
                 field "expr" inner_json;
               ]))
  | Ast.EBinary (op, left, right) -> (
      match (expr_to_json left, expr_to_json right) with
      | Some left_json, Some right_json ->
          Some
            (obj
               [
                 field "tag" (string "Binary");
                 field "op" (string (binary_op_to_json op));
                 field "left" left_json;
                 field "right" right_json;
               ])
      | _ -> None)
  | Ast.ELogical (op, left, right) -> (
      match (expr_to_json left, expr_to_json right) with
      | Some left_json, Some right_json ->
          Some
            (obj
               [
                 field "tag" (string "Logical");
                 field "op" (string (logical_op_to_json op));
                 field "left" left_json;
                 field "right" right_json;
               ])
      | _ -> None)
  | Ast.ETuple elems -> (
      match option_map_all expr_to_json elems with
      | Some elem_jsons ->
          Some
            (obj
               [
                 field "tag" (string "Tuple"); field "elems" (array elem_jsons);
               ])
      | None -> None)
  | Ast.EList elems -> (
      match option_map_all expr_to_json elems with
      | Some elem_jsons ->
          Some
            (obj
               [ field "tag" (string "List"); field "elems" (array elem_jsons) ])
      | None -> None)
  | Ast.EVector elems -> (
      match option_map_all expr_to_json elems with
      | Some elem_jsons ->
          Some
            (obj
               [
                 field "tag" (string "Vector"); field "elems" (array elem_jsons);
               ])
      | None -> None)
  | Ast.ERecord fields -> (
      let field_json_opt =
        option_map_all
          (fun (name, value) ->
            match expr_to_json value with
            | Some value_json -> Some (record_field_to_json (name, value_json))
            | None -> None)
          fields
      in
      match field_json_opt with
      | Some field_jsons ->
          Some
            (obj
               [
                 field "tag" (string "Record");
                 field "fields" (array field_jsons);
               ])
      | None -> None)
  | Ast.ERecordUpdate (base, fields) -> (
      let base_json_opt = expr_to_json base in
      let field_json_opt =
        option_map_all
          (fun (name, value) ->
            match expr_to_json value with
            | Some value_json -> Some (record_field_to_json (name, value_json))
            | None -> None)
          fields
      in
      match (base_json_opt, field_json_opt) with
      | Some base_json, Some field_jsons ->
          Some
            (obj
               [
                 field "tag" (string "RecordUpdate");
                 field "base" base_json;
                 field "fields" (array field_jsons);
               ])
      | _ -> None)
  | Ast.EAscription (inner, ty) -> (
      match expr_to_json inner with
      | None -> None
      | Some inner_json ->
          Some
            (obj
               [
                 field "tag" (string "Ascription");
                 field "expr" inner_json;
                 field "type" (type_expr_to_json ty);
               ]))
  | Ast.ERange (left, right) -> (
      match (expr_to_json left, expr_to_json right) with
      | Some left_json, Some right_json ->
          Some
            (obj
               [
                 field "tag" (string "Range");
                 field "left" left_json;
                 field "right" right_json;
               ])
      | _ -> None)
  | Ast.ESubscript (target, index) -> (
      match (expr_to_json target, expr_to_json index) with
      | Some target_json, Some index_json ->
          Some
            (obj
               [
                 field "tag" (string "Subscript");
                 field "target" target_json;
                 field "index" index_json;
               ])
      | _ -> None)
  | Ast.ESubscriptMulti (target, indices) -> (
      match (expr_to_json target, option_map_all expr_to_json indices) with
      | Some target_json, Some index_jsons ->
          Some
            (obj
               [
                 field "tag" (string "SubscriptMulti");
                 field "target" target_json;
                 field "indices" (array index_jsons);
               ])
      | _ -> None)
  | Ast.EDict entries -> (
      let entry_jsons_opt =
        option_map_all
          (fun (key, value) ->
            match (expr_to_json key, expr_to_json value) with
            | Some key_json, Some value_json ->
                Some (dict_entry_to_json (key_json, value_json))
            | _ -> None)
          entries
      in
      match entry_jsons_opt with
      | Some entry_jsons ->
          Some
            (obj
               [
                 field "tag" (string "Dict");
                 field "entries" (array entry_jsons);
               ])
      | None -> None)
  | Ast.EAssign (name, value) -> (
      match expr_to_json value with
      | Some value_json ->
          Some
            (obj
               [
                 field "tag" (string "Assign");
                 field "name" (string name);
                 field "value" value_json;
               ])
      | None -> None)
  | Ast.EVarDecl (name, ty_opt, value, is_mutable) -> (
      match expr_to_json value with
      | Some value_json ->
          Some
            (obj
               ([
                  field "tag" (string "VarDecl");
                  field "name" (string name);
                  field "mutable" (bool is_mutable);
                  field "value" value_json;
                ]
               @ optional_field "type" (Option.map type_expr_to_json ty_opt)))
      | None -> None)
  | Ast.ETupleDestruct (names, value) -> (
      match expr_to_json value with
      | Some value_json ->
          Some
            (obj
               [
                 field "tag" (string "TupleDestruct");
                 field "names" (string_array names);
                 field "value" value_json;
               ])
      | None -> None)
  | Ast.ESubscriptAssign (target, indices, value) -> (
      match
        ( expr_to_json target,
          option_map_all expr_to_json indices,
          expr_to_json value )
      with
      | Some target_json, Some index_jsons, Some value_json ->
          Some
            (obj
               [
                 field "tag" (string "SubscriptAssign");
                 field "target" target_json;
                 field "indices" (array index_jsons);
                 field "value" value_json;
               ])
      | _ -> None)
  | Ast.EQuestionBind (name, ty_opt, expr) -> (
      match expr_to_json expr with
      | Some expr_json ->
          Some
            (obj
               ([
                  field "tag" (string "QuestionBind");
                  field "name" (string name);
                  field "expr" expr_json;
                ]
               @ optional_field "type" (Option.map type_expr_to_json ty_opt)))
      | None -> None)
  | Ast.EBlock exprs -> (
      match option_map_all expr_to_json exprs with
      | Some expr_jsons ->
          Some
            (obj
               [
                 field "tag" (string "Block"); field "exprs" (array expr_jsons);
               ])
      | None -> None)
  | Ast.EIf (cond, then_expr, else_opt) -> (
      match
        ( expr_to_json cond,
          expr_to_json then_expr,
          Option.map expr_to_json else_opt )
      with
      | Some cond_json, Some then_json, None ->
          Some
            (obj
               [
                 field "tag" (string "If");
                 field "cond" cond_json;
                 field "then" then_json;
               ])
      | Some cond_json, Some then_json, Some (Some else_json) ->
          Some
            (obj
               [
                 field "tag" (string "If");
                 field "cond" cond_json;
                 field "then" then_json;
                 field "else" else_json;
               ])
      | _ -> None)
  | Ast.EMatch (scrutinee, cases) -> (
      let case_to_json case =
        match expr_to_json case.Ast.case_body with
        | Some body_json ->
            Some
              (obj
                 [
                   field "pattern" (pattern_to_json case.Ast.case_pattern);
                   field "body" body_json;
                 ])
        | None -> None
      in
      match (expr_to_json scrutinee, option_map_all case_to_json cases) with
      | Some scrutinee_json, Some case_jsons ->
          Some
            (obj
               [
                 field "tag" (string "Match");
                 field "scrutinee" scrutinee_json;
                 field "cases" (array case_jsons);
               ])
      | _ -> None)
  | Ast.EWhile (cond, body) -> (
      match (expr_to_json cond, expr_to_json body) with
      | Some cond_json, Some body_json ->
          Some
            (obj
               [
                 field "tag" (string "While");
                 field "cond" cond_json;
                 field "body" body_json;
               ])
      | _ -> None)
  | Ast.EFor (name, iter, body) -> (
      match (expr_to_json iter, expr_to_json body) with
      | Some iter_json, Some body_json ->
          Some
            (obj
               [
                 field "tag" (string "For");
                 field "name" (string name);
                 field "iter" iter_json;
                 field "body" body_json;
               ])
      | _ -> None)
  | Ast.EForTuple (names, iter, body) -> (
      match (expr_to_json iter, expr_to_json body) with
      | Some iter_json, Some body_json ->
          Some
            (obj
               [
                 field "tag" (string "ForTuple");
                 field "names" (string_array names);
                 field "iter" iter_json;
                 field "body" body_json;
               ])
      | _ -> None)
  | Ast.ELambda func -> (
      match func.Ast.func_body with
      | Ast.FuncBodyExpr body -> (
          match expr_to_json body with
          | Some body_json ->
              Some
                (obj
                   ([
                      field "tag" (string "Lambda");
                      field "pure" (bool func.Ast.func_is_pure);
                      field "params"
                        (array (List.map param_to_json func.Ast.func_params));
                      field "body" body_json;
                    ]
                   @ optional_field "return"
                       (Option.map type_expr_to_json func.Ast.func_return_type)
                   ))
          | None -> None)
      | Ast.FuncBuiltinBody _ | Ast.FuncForeign _ | Ast.FuncNoBody -> None)
  | Ast.EFuncDecl func -> (
      match func.Ast.func_body with
      | Ast.FuncBodyExpr body -> (
          match expr_to_json body with
          | Some body_json ->
              let name =
                match func.Ast.func_name with Some name -> name | None -> ""
              in
              Some
                (obj
                   ([
                      field "tag" (string "FuncDecl");
                      field "name" (string name);
                      field "pure" (bool func.Ast.func_is_pure);
                      field "type_params"
                        (string_array
                           (List.map Ast.type_param_to_parser_string
                              func.Ast.func_type_params));
                      field "params"
                        (array (List.map param_to_json func.Ast.func_params));
                      field "body" body_json;
                    ]
                   @ optional_field "return"
                       (Option.map type_expr_to_json func.Ast.func_return_type)
                   ))
          | None -> None)
      | Ast.FuncBuiltinBody _ | Ast.FuncForeign _ | Ast.FuncNoBody -> None)
  | Ast.EDebugBlock exprs -> (
      match option_map_all expr_to_json exprs with
      | Some expr_jsons ->
          Some
            (obj
               [
                 field "tag" (string "DebugBlock");
                 field "exprs" (array expr_jsons);
               ])
      | None -> None)
  | Ast.EConcurrent (bindings, timeout, max_threads) -> (
      match
        ( option_map_all expr_to_json bindings,
          option_map_opt expr_to_json timeout )
      with
      | Some binding_jsons, Some timeout_json ->
          Some
            (obj
               ([
                  field "tag" (string "Concurrent");
                  field "bindings" (array binding_jsons);
                ]
               @ optional_field "timeout" timeout_json
               @ optional_int_field "max_threads" max_threads))
      | _ -> None)
  | Ast.EConcurrentBind (name, ty, value) -> (
      match expr_to_json value with
      | Some value_json ->
          Some
            (obj
               ([
                  field "tag" (string "ConcurrentBind");
                  field "name" (string name);
                  field "value" value_json;
                ]
               @ optional_field "type" (Option.map type_expr_to_json ty)))
      | None -> None)
  | Ast.EDetach body -> (
      match expr_to_json body with
      | Some body_json ->
          Some (obj [ field "tag" (string "Detach"); field "body" body_json ])
      | None -> None)
  | Ast.EConcurrentFor (var, iter, body, timeout, max_threads) -> (
      match
        ( expr_to_json iter,
          expr_to_json body,
          option_map_opt expr_to_json timeout )
      with
      | Some iter_json, Some body_json, Some timeout_json ->
          Some
            (obj
               ([
                  field "tag" (string "ConcurrentFor");
                  field "var" (string var);
                  field "iter" iter_json;
                  field "body" body_json;
                ]
               @ optional_field "timeout" timeout_json
               @ optional_int_field "max_threads" max_threads))
      | _ -> None)
  | Ast.EStringInterp (parts, is_triple) -> (
      let part_to_json = function
        | Ast.InterpLit text ->
            Some
              (obj [ field "tag" (string "Text"); field "text" (string text) ])
        | Ast.InterpExpr expr -> (
            match expr_to_json expr with
            | Some expr_json ->
                Some
                  (obj [ field "tag" (string "Expr"); field "expr" expr_json ])
            | None -> None)
      in
      match option_map_all part_to_json parts with
      | Some part_jsons ->
          Some
            (obj
               [
                 field "tag" (string "StringInterp");
                 field "triple" (bool is_triple);
                 field "parts" (array part_jsons);
               ])
      | None -> None)
  | Ast.ELoopView _ | Ast.EStringInterpRaw _ -> None

let expected_layout expr =
  Printer.comments := Fmt_comment.create [];
  Layout.layout (Printer.print_expr expr)

let case_json expr expr_json =
  obj
    [
      field "line" (string_of_int expr.Ast.expr_loc.line);
      field "column" (string_of_int expr.Ast.expr_loc.column);
      field "expected" (string (expected_layout expr));
      field "expr" expr_json;
    ]

let collect_expr_cases_from_expr expr =
  let rec loop acc e =
    let acc =
      match expr_to_json e with
      | Some expr_json -> case_json e expr_json :: acc
      | None -> acc
    in
    List.fold_left loop acc (Ast.expr_children e)
  in
  loop [] expr

let collect_expr_cases_from_func acc func =
  match Ast.func_body_expr_opt func.Ast.func_body with
  | Some body -> collect_expr_cases_from_expr body @ acc
  | None -> acc

let rec collect_expr_cases_from_decl acc decl =
  match decl.Ast.decl_desc with
  | Ast.DFunc func -> collect_expr_cases_from_func acc func
  | Ast.DVar var -> collect_expr_cases_from_expr var.Ast.var_value @ acc
  | Ast.DPrivate inner -> collect_expr_cases_from_decl acc inner
  | Ast.DTrait trait_decl ->
      List.fold_left
        (fun acc method_decl ->
          match method_decl.Ast.method_default_body with
          | Some body -> collect_expr_cases_from_expr body @ acc
          | None -> acc)
        acc trait_decl.Ast.trait_methods
  | Ast.DImpl impl_decl ->
      List.fold_left collect_expr_cases_from_func acc impl_decl.Ast.impl_methods
  | Ast.DType _ | Ast.DRecord _ | Ast.DImport _ | Ast.DTypeAlias _ -> acc

let collect_expr_cases program =
  List.rev (List.fold_left collect_expr_cases_from_decl [] program)

let cases_json_lines program = String.concat "\n" (collect_expr_cases program)
