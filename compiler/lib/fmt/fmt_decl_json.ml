(** JSON serialization for declaration-formatting parity cases.

    This is a temporary dogfooding boundary while declaration printing moves
    from OCaml to Blorp in small slices. OCaml still owns parsing and the
    reference declaration printer; Blorp consumes this supported declaration
    subset and must render the same layout. *)

module Layout = Fmt_layout
module Printer = Fmt_printer
module Doc = Fmt_doc

let string = Fmt_expr_json.string
let bool = Fmt_expr_json.bool
let field = Fmt_expr_json.field
let obj = Fmt_expr_json.obj
let array = Fmt_expr_json.array
let optional_field = Fmt_expr_json.optional_field
let string_array values = array (List.map string values)

let normalize_docstring doc =
  String.concat "\n"
    (Printer.format_docstring_doctests (String.split_on_char '\n' doc))

let with_supported_doc decl decl_json =
  match decl.Ast.decl_doc with
  | Some doc ->
      obj
        [
          field "tag" (string "Doc");
          field "doc" (string (normalize_docstring doc));
          field "decl" decl_json;
        ]
  | _ -> decl_json

let ctor_import_fields = function
  | Ast.CtorNone -> []
  | Ast.CtorSome ctors -> [ field "ctors" (string_array ctors) ]

let import_symbol_to_json symbol =
  obj
    ([ field "name" (string symbol.Ast.sym_name) ]
    @ optional_field "alias" (Option.map string symbol.Ast.sym_alias)
    @ ctor_import_fields symbol.Ast.sym_ctors)

let import_to_json imp =
  obj
    ([
       field "tag" (string "Import");
       field "module" (string imp.Ast.import_module);
     ]
    @ optional_field "alias" (Option.map string imp.Ast.import_alias)
    @ optional_field "symbols"
        (Option.map
           (fun symbols -> array (List.map import_symbol_to_json symbols))
           imp.Ast.import_symbols))

let type_params_to_json params =
  string_array (List.map Ast.type_param_to_parser_string params)

let variant_to_json variant =
  obj
    [
      field "name" (string variant.Ast.variant_name);
      field "fields"
        (array
           (List.map Fmt_expr_json.type_expr_to_json variant.variant_fields));
    ]

let type_to_json ~is_private type_decl =
  obj
    [
      field "tag" (string "Type");
      field "private" (bool is_private);
      field "name" (string type_decl.Ast.type_name);
      field "type_params" (type_params_to_json type_decl.Ast.type_params);
      field "enum" (bool type_decl.Ast.type_is_enum);
      field "builtin" (bool type_decl.Ast.type_is_builtin);
      field "variants"
        (array (List.map variant_to_json type_decl.Ast.type_variants));
    ]

let field_to_json field_decl =
  obj
    [
      field "name" (string field_decl.Ast.field_name);
      field "type" (Fmt_expr_json.type_expr_to_json field_decl.Ast.field_type);
    ]

let record_to_json ~is_private record_decl =
  obj
    [
      field "tag" (string "Record");
      field "private" (bool is_private);
      field "name" (string record_decl.Ast.record_name);
      field "type_params"
        (type_params_to_json record_decl.Ast.record_type_params);
      field "value" (bool record_decl.Ast.record_is_value);
      field "builtin" (bool record_decl.Ast.record_is_builtin);
      field "fields"
        (array (List.map field_to_json record_decl.Ast.record_fields));
    ]

let type_alias_to_json ~is_private alias_decl =
  obj
    [
      field "tag" (string "TypeAlias");
      field "private" (bool is_private);
      field "name" (string alias_decl.Ast.alias_name);
      field "type_params" (type_params_to_json alias_decl.Ast.alias_type_params);
      field "target"
        (Fmt_expr_json.type_expr_to_json alias_decl.Ast.alias_target);
    ]

let var_to_json ~is_private var =
  match Fmt_expr_json.expr_to_json var.Ast.var_value with
  | None -> None
  | Some value_json ->
      Some
        (obj
           ([
              field "tag" (string "Var");
              field "private" (bool is_private);
              field "mutable" (bool var.Ast.var_is_mutable);
              field "value" value_json;
            ]
           @ optional_field "name" (Option.map string var.Ast.var_name)
           @ optional_field "pattern"
               (Option.map Fmt_expr_json.pattern_to_json var.Ast.var_pattern)
           @ optional_field "type"
               (Option.map Fmt_expr_json.type_expr_to_json var.Ast.var_type)))

let builtin_body_fields = function
  | Ast.BuiltinIntrinsic -> [ field "body_kind" (string "builtin") ]
  | Ast.BuiltinRuntime name ->
      [
        field "body_kind" (string "builtin"); field "builtin_name" (string name);
      ]

let foreign_link_flag_to_json (platform, value) =
  obj
    ([ field "value" (string value) ]
    @ optional_field "platform" (Option.map string platform))

let func_body_fields = function
  | Ast.FuncBodyExpr body -> (
      match Fmt_expr_json.expr_to_json body with
      | Some body_json -> Some [ field "body" body_json ]
      | None -> None)
  | Ast.FuncBuiltinBody (builtin, _) -> Some (builtin_body_fields builtin)
  | Ast.FuncForeign foreign ->
      Some
        [
          field "body_kind" (string "foreign");
          field "foreign_name" (string foreign.Ast.foreign_name);
          field "foreign_includes" (string_array foreign.Ast.foreign_includes);
          field "foreign_link_flags"
            (array
               (List.map foreign_link_flag_to_json
                  foreign.Ast.foreign_link_flags));
        ]
  | Ast.FuncNoBody -> Some [ field "body_kind" (string "none") ]

let func_to_json ~is_private func =
  match func_body_fields func.Ast.func_body with
  | None -> None
  | Some body_fields ->
      let name =
        match func.Ast.func_name with Some name -> name | None -> ""
      in
      Some
        (obj
           ([
              field "tag" (string "Func");
              field "private" (bool is_private);
              field "name" (string name);
              field "pure" (bool func.Ast.func_is_pure);
              field "tailrec" (bool func.Ast.func_is_tailrec);
              field "debug_only" (bool func.Ast.func_debug_only);
              field "no_copy" (bool func.Ast.func_no_copy);
              field "type_params"
                (string_array
                   (List.map Ast.type_param_to_parser_string
                      func.Ast.func_type_params));
              field "params"
                (array
                   (List.map Fmt_expr_json.param_to_json func.Ast.func_params));
            ]
           @ body_fields
           @ optional_field "return"
               (Option.map Fmt_expr_json.type_expr_to_json
                  func.Ast.func_return_type)))

let trait_method_to_json method_decl =
  match
    Fmt_expr_json.option_map_opt Fmt_expr_json.expr_to_json
      method_decl.Ast.method_default_body
  with
  | None -> None
  | Some body_json ->
      Some
        (obj
           ([
              field "name" (string method_decl.Ast.method_name);
              field "pure" (bool method_decl.Ast.method_is_pure);
              field "params"
                (array
                   (List.map Fmt_expr_json.param_to_json
                      method_decl.Ast.method_params));
            ]
           @ optional_field "return"
               (Option.map Fmt_expr_json.type_expr_to_json
                  method_decl.Ast.method_return_type)
           @ optional_field "body" body_json))

let trait_to_json ~is_private trait_decl =
  match
    Fmt_expr_json.option_map_all trait_method_to_json
      trait_decl.Ast.trait_methods
  with
  | None -> None
  | Some methods ->
      Some
        (obj
           [
             field "tag" (string "Trait");
             field "private" (bool is_private);
             field "name" (string trait_decl.Ast.trait_name);
             field "type_params"
               (type_params_to_json trait_decl.Ast.trait_type_params);
             field "supertraits" (string_array trait_decl.Ast.trait_supertraits);
             field "methods" (array methods);
           ])

let impl_method_to_json func =
  match func_body_fields func.Ast.func_body with
  | None -> None
  | Some body_fields ->
      let name =
        match func.Ast.func_name with Some name -> name | None -> ""
      in
      Some
        (obj
           ([
              field "name" (string name);
              field "pure" (bool func.Ast.func_is_pure);
              field "tailrec" (bool func.Ast.func_is_tailrec);
              field "debug_only" (bool func.Ast.func_debug_only);
              field "no_copy" (bool func.Ast.func_no_copy);
              field "type_params"
                (type_params_to_json func.Ast.func_type_params);
              field "params"
                (array
                   (List.map Fmt_expr_json.param_to_json func.Ast.func_params));
            ]
           @ body_fields
           @ optional_field "return"
               (Option.map Fmt_expr_json.type_expr_to_json
                  func.Ast.func_return_type)))

let impl_to_json ~is_private impl_decl =
  match
    Fmt_expr_json.option_map_all impl_method_to_json impl_decl.Ast.impl_methods
  with
  | None -> None
  | Some methods ->
      Some
        (obj
           [
             field "tag" (string "Impl");
             field "private" (bool is_private);
             field "trait" (string impl_decl.Ast.impl_trait);
             field "for"
               (Fmt_expr_json.type_expr_to_json impl_decl.Ast.impl_for_type);
             field "methods" (array methods);
           ])

let rec decl_to_json ?(is_private = false) decl =
  match decl.Ast.decl_desc with
  | Ast.DImport imp -> Some (with_supported_doc decl (import_to_json imp))
  | Ast.DType type_decl ->
      Some (with_supported_doc decl (type_to_json ~is_private type_decl))
  | Ast.DRecord record_decl ->
      Some (with_supported_doc decl (record_to_json ~is_private record_decl))
  | Ast.DVar var ->
      Option.map (with_supported_doc decl) (var_to_json ~is_private var)
  | Ast.DFunc func ->
      Option.map (with_supported_doc decl) (func_to_json ~is_private func)
  | Ast.DPrivate inner -> decl_to_json ~is_private:true inner
  | Ast.DTypeAlias alias_decl ->
      Some (with_supported_doc decl (type_alias_to_json ~is_private alias_decl))
  | Ast.DTrait trait_decl ->
      Option.map (with_supported_doc decl)
        (trait_to_json ~is_private trait_decl)
  | Ast.DImpl impl_decl ->
      Option.map (with_supported_doc decl) (impl_to_json ~is_private impl_decl)

let rec expected_doc ?(is_private = false) decl =
  match decl.Ast.decl_desc with
  | Ast.DPrivate inner -> expected_doc ~is_private:true inner
  | _ ->
      let doc_doc =
        match decl.Ast.decl_doc with
        | Some doc -> Printer.print_docstring doc
        | _ -> Doc.Nil
      in
      let decl_doc = Printer.print_decl_desc ~is_private decl.Ast.decl_desc in
      Doc.(doc_doc ^^ decl_doc)

let expected_layout decl =
  Printer.comments := Fmt_comment.create [];
  Layout.layout (expected_doc decl)

let case_json decl decl_json =
  obj
    [
      field "line" (string_of_int decl.Ast.decl_loc.line);
      field "column" (string_of_int decl.Ast.decl_loc.column);
      field "expected" (string (expected_layout decl));
      field "decl" decl_json;
    ]

let comment_to_json (comment : Lexer.collected_comment) =
  obj
    [
      field "text" (string comment.Lexer.cc_text);
      field "line" (string_of_int comment.Lexer.cc_line);
      field "column" (string_of_int comment.Lexer.cc_col);
      field "trailing" (bool comment.Lexer.cc_trailing);
    ]

let rec decl_source_end_line decl =
  let loc_end = max decl.Ast.decl_loc.line decl.Ast.decl_loc.end_line in
  max loc_end (decl_desc_source_end_line decl.Ast.decl_desc)

and decl_desc_source_end_line = function
  | Ast.DFunc func -> Printer.func_source_end_line func
  | Ast.DVar var -> Printer.expr_source_end_line var.Ast.var_value
  | Ast.DPrivate inner -> decl_source_end_line inner
  | Ast.DTrait trait_decl ->
      List.fold_left
        (fun acc method_decl ->
          match method_decl.Ast.method_default_body with
          | None -> acc
          | Some body -> max acc (Printer.expr_source_end_line body))
        0 trait_decl.Ast.trait_methods
  | Ast.DImpl impl_decl ->
      List.fold_left
        (fun acc func -> max acc (Printer.func_source_end_line func))
        0 impl_decl.Ast.impl_methods
  | Ast.DImport _ | Ast.DType _ | Ast.DRecord _ | Ast.DTypeAlias _ -> 0

let located_decl_to_json decl decl_json =
  obj
    [
      field "line" (string_of_int decl.Ast.decl_loc.line);
      field "column" (string_of_int decl.Ast.decl_loc.column);
      field "end_line" (string_of_int (decl_source_end_line decl));
      field "decl" decl_json;
    ]

let decl_body_comments comments decl =
  let start_line = decl.Ast.decl_loc.line in
  let end_line = decl_source_end_line decl in
  List.filter
    (fun comment ->
      comment.Lexer.cc_line > start_line && comment.Lexer.cc_line <= end_line)
    comments

let program_supported ~comments:_ program = program <> []

let program_to_json ~comments program =
  if not (program_supported ~comments program) then None
  else
    Option.map array
      (Fmt_expr_json.option_map_all
         (fun decl ->
           Fmt_expr_json.with_comments (decl_body_comments comments decl)
             (fun () ->
               Option.map (located_decl_to_json decl) (decl_to_json decl)))
         program)

let program_expected_layout ~comments program =
  Printer.comments := Fmt_comment.create comments;
  Layout.layout (Printer.print_program program)

let program_case_json ~comments program =
  Option.map
    (fun program_json ->
      obj
        [
          field "line" "0";
          field "column" "0";
          field "expected" (string (program_expected_layout ~comments program));
          field "comments" (array (List.map comment_to_json comments));
          field "program" program_json;
        ])
    (program_to_json ~comments program)

let collect_decl_cases program =
  let rec loop acc = function
    | [] -> List.rev acc
    | decl :: rest -> (
        match decl_to_json decl with
        | Some decl_json -> loop (case_json decl decl_json :: acc) rest
        | None -> loop acc rest)
  in
  loop [] program

let cases_json_lines ?(comments = []) program =
  let decl_cases = collect_decl_cases program in
  let cases =
    match program_case_json ~comments program with
    | Some program_case -> decl_cases @ [ program_case ]
    | None -> decl_cases
  in
  String.concat "\n" cases
