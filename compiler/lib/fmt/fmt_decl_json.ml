(** JSON serialization for formatter declarations.

    OCaml still owns parsing, comment collection, and JSON projection. The
    Blorp formatter consumes this representation and owns rendering. This
    module must not include rendered declaration text in the JSON projection. *)

module Span = Fmt_source_span

let string = Fmt_expr_json.string
let bool = Fmt_expr_json.bool
let field = Fmt_expr_json.field
let obj = Fmt_expr_json.obj
let array = Fmt_expr_json.array
let optional_field = Fmt_expr_json.optional_field
let string_array values = array (List.map string values)

let with_supported_doc decl decl_json =
  match decl.Ast.decl_doc with
  | Some doc ->
      obj
        [
          field "tag" (string "Doc");
          field "doc" (Fmt_docstring_json.doc_to_json doc);
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

let dim_constraint_to_json (left, right) =
  obj
    [
      field "left" (Fmt_expr_json.type_expr_to_json left);
      field "right" (Fmt_expr_json.type_expr_to_json right);
    ]

let dim_constraints_field constraints =
  match constraints with
  | [] -> []
  | _ -> [ field "where" (array (List.map dim_constraint_to_json constraints)) ]

let variant_to_json variant =
  obj
    [
      field "name" (string variant.Ast.variant_name);
      field "fields"
        (array
           (List.map Fmt_expr_json.type_expr_to_json variant.variant_fields));
    ]

let resource_cleanup_to_string = function
  | Ast.ResourceCleanupBuiltin name -> name

let type_to_json ~is_private type_decl =
  obj
    ([
       field "tag" (string "Type");
       field "private" (bool is_private);
       field "name" (string type_decl.Ast.type_name);
       field "type_params" (type_params_to_json type_decl.Ast.type_params);
       field "enum" (bool type_decl.Ast.type_is_enum);
       field "builtin" (bool type_decl.Ast.type_is_builtin);
       field "resource" (bool type_decl.Ast.type_is_resource);
       field "variants"
         (array (List.map variant_to_json type_decl.Ast.type_variants));
     ]
    @ optional_field "resource_cleanup_builtin"
        (Option.map
           (fun cleanup -> string (resource_cleanup_to_string cleanup))
           type_decl.Ast.type_resource_cleanup))

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
      field "opaque" (bool alias_decl.Ast.alias_is_opaque);
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

let compile_time_binding_to_json binding =
  var_to_json ~is_private:binding.Ast.ctb_private binding.Ast.ctb_var

let compile_time_block_to_json bindings =
  match Fmt_expr_json.option_map_all compile_time_binding_to_json bindings with
  | None -> None
  | Some binding_jsons ->
      Some
        (obj
           [
             field "tag" (string "CompileTime");
             field "bindings" (array binding_jsons);
           ])

let builtin_body_fields = function
  | Ast.BuiltinIntrinsic -> [ field "body_kind" (string "builtin") ]
  | Ast.BuiltinStdIntrinsic identity ->
      [
        field "body_kind" (string "builtin");
        field "builtin_name"
          (string (Ast.std_builtin_identity_to_string identity));
      ]
  | Ast.BuiltinRuntimeHelper name ->
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
              field "resource_result_ordinary"
                (bool func.Ast.func_resource_result_ordinary);
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
                  func.Ast.func_return_type)
           @ dim_constraints_field func.Ast.func_dim_constraints))

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
              field "resource_result_ordinary"
                (bool func.Ast.func_resource_result_ordinary);
              field "type_params"
                (type_params_to_json func.Ast.func_type_params);
              field "params"
                (array
                   (List.map Fmt_expr_json.param_to_json func.Ast.func_params));
            ]
           @ body_fields
           @ optional_field "return"
               (Option.map Fmt_expr_json.type_expr_to_json
                  func.Ast.func_return_type)
           @ dim_constraints_field func.Ast.func_dim_constraints))

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
  | Ast.DCompileTimeBlock bindings ->
      Option.map (with_supported_doc decl) (compile_time_block_to_json bindings)
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

let case_json decl decl_json =
  obj
    [
      field "line" (string_of_int decl.Ast.decl_loc.line);
      field "column" (string_of_int decl.Ast.decl_loc.column);
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
  | Ast.DFunc func -> Span.func_source_end_line func
  | Ast.DVar var -> Span.expr_source_end_line var.Ast.var_value
  | Ast.DCompileTimeBlock bindings ->
      List.fold_left
        (fun acc binding ->
          max acc (Span.expr_source_end_line binding.Ast.ctb_var.var_value))
        0 bindings
  | Ast.DPrivate inner -> decl_source_end_line inner
  | Ast.DTrait trait_decl ->
      List.fold_left
        (fun acc method_decl ->
          match method_decl.Ast.method_default_body with
          | None -> acc
          | Some body -> max acc (Span.expr_source_end_line body))
        0 trait_decl.Ast.trait_methods
  | Ast.DImpl impl_decl ->
      List.fold_left
        (fun acc func -> max acc (Span.func_source_end_line func))
        0 impl_decl.Ast.impl_methods
  | Ast.DImport _ | Ast.DType _ | Ast.DRecord _ | Ast.DTypeAlias _ -> 0

let capped_decl_source_end_line ?next_decl decl =
  let end_line = decl_source_end_line decl in
  let capped =
    match next_decl with
    | Some next -> min end_line (next.Ast.decl_loc.line - 1)
    | None -> end_line
  in
  max decl.Ast.decl_loc.line capped

let located_decl_to_json ?next_decl decl decl_json =
  obj
    [
      field "line" (string_of_int decl.Ast.decl_loc.line);
      field "column" (string_of_int decl.Ast.decl_loc.column);
      field "end_line"
        (string_of_int (capped_decl_source_end_line ?next_decl decl));
      field "decl" decl_json;
    ]

let decl_body_comments comments decl end_line =
  let start_line = decl.Ast.decl_loc.line in
  List.filter
    (fun comment ->
      comment.Lexer.cc_line > start_line && comment.Lexer.cc_line <= end_line)
    comments

let program_to_json ~comments program =
  let rec loop acc = function
    | [] -> Some (array (List.rev acc))
    | decl :: rest -> (
        let next_decl = match rest with next :: _ -> Some next | [] -> None in
        let end_line = capped_decl_source_end_line ?next_decl decl in
        match
          Fmt_expr_json.with_comments
            (decl_body_comments comments decl end_line) (fun () ->
              Option.map
                (located_decl_to_json ?next_decl decl)
                (decl_to_json decl))
        with
        | Some decl_json -> loop (decl_json :: acc) rest
        | None -> None)
  in
  loop [] program

let program_json_fields ~comments program =
  Option.map
    (fun program_json ->
      [
        field "comments" (array (List.map comment_to_json comments));
        field "program" program_json;
      ])
    (program_to_json ~comments program)

let program_json ~comments program =
  Option.map obj (program_json_fields ~comments program)

let program_case_json ~comments program =
  Option.map
    (fun fields -> obj ([ field "line" "0"; field "column" "0" ] @ fields))
    (program_json_fields ~comments program)

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
