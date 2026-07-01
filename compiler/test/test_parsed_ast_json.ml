open Blorp

let span_json ?(path = "main.brp") ?(module_name = "main") start_offset
    start_column end_offset end_column =
  Lsp_json.Object
    [
      ("path", Lsp_json.String path);
      ("module", Lsp_json.String module_name);
      ("start_offset", Lsp_json.Int start_offset);
      ("start_line", Lsp_json.Int 1);
      ("start_column", Lsp_json.Int start_column);
      ("end_offset", Lsp_json.Int end_offset);
      ("end_line", Lsp_json.Int 1);
      ("end_column", Lsp_json.Int end_column);
    ]

let ident_json text start_offset start_column end_offset end_column =
  Lsp_json.Object
    [
      ("text", Lsp_json.String text);
      ("span", span_json start_offset start_column end_offset end_column);
    ]

let int_expr_json value start_offset start_column end_offset end_column =
  Lsp_json.Object
    [
      ("kind", Lsp_json.String "int_literal");
      ("value", Lsp_json.String value);
      ("span", span_json start_offset start_column end_offset end_column);
    ]

let char_expr_json value start_offset start_column end_offset end_column =
  Lsp_json.Object
    [
      ("kind", Lsp_json.String "char_literal");
      ("value", Lsp_json.Int value);
      ("span", span_json start_offset start_column end_offset end_column);
    ]

let string_expr_json value start_offset start_column end_offset end_column =
  Lsp_json.Object
    [
      ("kind", Lsp_json.String "string_literal");
      ("value", Lsp_json.String value);
      ("span", span_json start_offset start_column end_offset end_column);
    ]

let name_expr_json name start_offset start_column end_offset end_column =
  Lsp_json.Object
    [
      ("kind", Lsp_json.String "name");
      ("name", ident_json name start_offset start_column end_offset end_column);
    ]

let block_expr_json items start_offset start_column end_offset end_column =
  Lsp_json.Object
    [
      ("kind", Lsp_json.String "block");
      ("items", Lsp_json.Array items);
      ("span", span_json start_offset start_column end_offset end_column);
    ]

let named_type_json name start_offset start_column end_offset end_column =
  Lsp_json.Object
    [
      ("kind", Lsp_json.String "named");
      ("name", ident_json name start_offset start_column end_offset end_column);
      ("args", Lsp_json.Array []);
      ("span", span_json start_offset start_column end_offset end_column);
    ]

let qualified_type_json module_name name args =
  Lsp_json.Object
    [
      ("kind", Lsp_json.String "qualified_named");
      ("module", ident_json module_name 0 1 4 5);
      ("name", ident_json name 6 7 10 11);
      ("args", Lsp_json.Array args);
      ("span", span_json 0 1 10 11);
    ]

let bounded_type_json name bounds =
  Lsp_json.Object
    [
      ("kind", Lsp_json.String "bounded");
      ("name", ident_json name 0 1 1 2);
      ( "bounds",
        Lsp_json.Array (List.map (fun bound -> ident_json bound 0 1 4 5) bounds)
      );
      ("span", span_json 0 1 8 9);
    ]

let dim_name_type_json ?(is_variadic = false) name =
  Lsp_json.Object
    [
      ("kind", Lsp_json.String "dim_name");
      ("name", ident_json name 0 1 1 2);
      ("is_variadic", Lsp_json.Bool is_variadic);
      ("span", span_json 0 1 1 2);
    ]

let dim_literal_type_json value =
  Lsp_json.Object
    [
      ("kind", Lsp_json.String "dim_literal");
      ("value", Lsp_json.String value);
      ("span", span_json 0 1 1 2);
    ]

let dim_binary_type_json op left right =
  Lsp_json.Object
    [
      ("kind", Lsp_json.String "dim_binary");
      ("op", Lsp_json.String op);
      ("left", left);
      ("right", right);
      ("span", span_json 0 1 4 5);
    ]

let range_type_json limit =
  Lsp_json.Object
    [
      ("kind", Lsp_json.String "range");
      ("limit", limit);
      ("span", span_json 0 1 4 5);
    ]

let tuple_type_json items =
  Lsp_json.Object
    [
      ("kind", Lsp_json.String "tuple");
      ("items", Lsp_json.Array items);
      ("span", span_json 0 1 10 11);
    ]

let function_type_json ?(is_pure = true) params return_type =
  Lsp_json.Object
    [
      ("kind", Lsp_json.String "function");
      ("is_pure", Lsp_json.Bool is_pure);
      ("params", Lsp_json.Array params);
      ("return_type", return_type);
      ("span", span_json 0 1 20 21);
    ]

let array_type_json element dims =
  Lsp_json.Object
    [
      ("kind", Lsp_json.String "array");
      ("element", element);
      ("dims", Lsp_json.Array dims);
      ("span", span_json 0 1 12 13);
    ]

let record_expr_field_json name value start_offset start_column end_offset
    end_column =
  Lsp_json.Object
    [
      ("name", ident_json name start_offset start_column end_offset end_column);
      ("value", value);
      ("span", span_json start_offset start_column end_offset end_column);
    ]

let record_expr_json fields =
  Lsp_json.Object
    [
      ("kind", Lsp_json.String "record");
      ("fields", Lsp_json.Array fields);
      ("span", span_json 0 1 10 11);
    ]

let record_update_expr_json base fields =
  Lsp_json.Object
    [
      ("kind", Lsp_json.String "record_update");
      ("base", base);
      ("fields", Lsp_json.Array fields);
      ("span", span_json 0 1 20 21);
    ]

let dict_entry_json key value =
  Lsp_json.Object
    [
      ("key", key);
      ("value", value);
      ("span", span_json 0 1 12 13);
    ]

let dict_expr_json entries =
  Lsp_json.Object
    [
      ("kind", Lsp_json.String "dict");
      ("entries", Lsp_json.Array entries);
      ("span", span_json 0 1 16 17);
    ]

let wildcard_pattern_json () =
  Lsp_json.Object
    [
      ("kind", Lsp_json.String "wildcard");
      ("span", span_json 0 1 1 2);
    ]

let name_pattern_json name =
  Lsp_json.Object
    [
      ("kind", Lsp_json.String "name");
      ("name", ident_json name 0 1 1 2);
    ]

let int_pattern_json value =
  Lsp_json.Object
    [
      ("kind", Lsp_json.String "int");
      ("value", Lsp_json.String value);
      ("span", span_json 0 1 1 2);
    ]

let float_pattern_json value =
  Lsp_json.Object
    [
      ("kind", Lsp_json.String "float");
      ("value", Lsp_json.String value);
      ("span", span_json 0 1 1 2);
    ]

let char_pattern_json value =
  Lsp_json.Object
    [
      ("kind", Lsp_json.String "char");
      ("value", Lsp_json.Int value);
      ("span", span_json 0 1 1 2);
    ]

let or_pattern_json patterns =
  Lsp_json.Object
    [
      ("kind", Lsp_json.String "or");
      ("patterns", Lsp_json.Array patterns);
      ("span", span_json 0 1 8 9);
    ]

let tuple_pattern_json items =
  Lsp_json.Object
    [
      ("kind", Lsp_json.String "tuple");
      ("items", Lsp_json.Array items);
      ("span", span_json 0 1 8 9);
    ]

let list_spread_name_json name =
  Lsp_json.Object
    [
      ("kind", Lsp_json.String "name");
      ("name", ident_json name 0 1 1 2);
    ]

let list_spread_wildcard_json () =
  Lsp_json.Object
    [
      ("kind", Lsp_json.String "wildcard");
      ("span", span_json 0 1 1 2);
    ]

let list_pattern_json ?spread items =
  Lsp_json.Object
    [
      ("kind", Lsp_json.String "list");
      ("items", Lsp_json.Array items);
      ("spread", Option.value spread ~default:Lsp_json.Null);
      ("span", span_json 0 1 8 9);
    ]

let constructor_pattern_json name args =
  Lsp_json.Object
    [
      ("kind", Lsp_json.String "constructor");
      ("name", ident_json name 0 1 4 5);
      ("args", Lsp_json.Array args);
      ("span", span_json 0 1 4 5);
    ]

let match_case_json pattern body =
  Lsp_json.Object
    [
      ("pattern", pattern);
      ("body", body);
      ("span", span_json 0 1 12 13);
    ]

let match_expr_json value cases =
  Lsp_json.Object
    [
      ("kind", Lsp_json.String "match");
      ("value", value);
      ("cases", Lsp_json.Array cases);
      ("span", span_json 0 1 30 31);
    ]

let ascription_expr_json value type_expr =
  Lsp_json.Object
    [
      ("kind", Lsp_json.String "ascription");
      ("value", value);
      ("type", type_expr);
      ("span", span_json 0 1 18 19);
    ]

let lambda_param_json name type_expr =
  Lsp_json.Object
    [
      ("name", ident_json name 0 1 1 2);
      ("type", Option.value type_expr ~default:Lsp_json.Null);
      ("span", span_json 0 1 1 2);
    ]

let param_name_binder_json name =
  Lsp_json.Object
    [
      ("kind", Lsp_json.String "name");
      ("name", ident_json name 0 1 1 2);
    ]

let param_wildcard_binder_json () =
  Lsp_json.Object
    [
      ("kind", Lsp_json.String "wildcard");
      ("span", span_json 0 1 1 2);
    ]

let param_tuple_binder_json names =
  Lsp_json.Object
    [
      ("kind", Lsp_json.String "tuple");
      ("items", Lsp_json.Array (List.map (fun name -> ident_json name 0 1 1 2) names));
      ("span", span_json 0 1 8 9);
    ]

let param_json ?type_expr binder =
  Lsp_json.Object
    [
      ("binder", binder);
      ("type", Option.value type_expr ~default:Lsp_json.Null);
      ("span", span_json 0 1 12 13);
    ]

let lambda_expr_json ?(is_pure = true) ?return_type params body =
  Lsp_json.Object
    [
      ("kind", Lsp_json.String "lambda");
      ("is_pure", Lsp_json.Bool is_pure);
      ("params", Lsp_json.Array params);
      ("return_type", Option.value return_type ~default:Lsp_json.Null);
      ("body", body);
      ("span", span_json 0 1 18 19);
    ]

let with_error_map_json name value =
  Lsp_json.Object
    [
      ("name", ident_json name 0 1 3 4);
      ("value", value);
      ("span", span_json 0 1 8 9);
    ]

let with_binding_json ?type_expr ?error_map ~kind name value =
  Lsp_json.Object
    [
      ("name", ident_json name 0 1 3 4);
      ("type", Option.value type_expr ~default:Lsp_json.Null);
      ("value", value);
      ("kind", Lsp_json.String kind);
      ("error_map", Option.value error_map ~default:Lsp_json.Null);
      ("span", span_json 0 1 12 13);
    ]

let with_expr_json binding body =
  Lsp_json.Object
    [
      ("kind", Lsp_json.String "with");
      ("binding", binding);
      ("body", body);
      ("span", span_json 0 1 24 25);
    ]

let select_arm_kind_json kind fields =
  Lsp_json.Object (("kind", Lsp_json.String kind) :: fields)

let select_arm_json kind body =
  Lsp_json.Object
    [
      ("kind", kind);
      ("body", body);
      ("span", span_json 0 1 12 13);
    ]

let select_expr_json arms =
  Lsp_json.Object
    [
      ("kind", Lsp_json.String "select");
      ("arms", Lsp_json.Array arms);
      ("span", span_json 0 1 24 25);
    ]

let debug_block_expr_json body =
  Lsp_json.Object
    [
      ("kind", Lsp_json.String "debug_block");
      ("body", body);
      ("span", span_json 0 1 24 25);
    ]

let for_name_binder_json name =
  Lsp_json.Object
    [
      ("kind", Lsp_json.String "name");
      ("name", ident_json name 0 1 1 2);
    ]

let for_tuple_binder_json names =
  Lsp_json.Object
    [
      ("kind", Lsp_json.String "tuple");
      ("items", Lsp_json.Array (List.map (fun name -> ident_json name 0 1 1 2) names));
      ("span", span_json 0 1 8 9);
    ]

let for_expr_json binder iterable body =
  Lsp_json.Object
    [
      ("kind", Lsp_json.String "for");
      ("binder", binder);
      ("iterable", iterable);
      ("body", body);
      ("span", span_json 0 1 24 25);
    ]

let tuple_destruct_expr_json names value =
  Lsp_json.Object
    [
      ("kind", Lsp_json.String "tuple_destruct");
      ( "names",
        Lsp_json.Array
          (List.map (fun name -> ident_json name 0 1 1 2) names) );
      ("value", value);
      ("span", span_json 0 1 24 25);
    ]

let subscript_assign_expr_json target indices value =
  Lsp_json.Object
    [
      ("kind", Lsp_json.String "subscript_assign");
      ("target", target);
      ("indices", Lsp_json.Array indices);
      ("value", value);
      ("span", span_json 0 1 24 25);
    ]

let opaque_into_expr_json type_expr value =
  Lsp_json.Object
    [
      ("kind", Lsp_json.String "opaque_into");
      ("type", type_expr);
      ("value", value);
      ("span", span_json 0 1 24 25);
    ]

let opaque_from_expr_json type_expr value =
  Lsp_json.Object
    [
      ("kind", Lsp_json.String "opaque_from");
      ("type", type_expr);
      ("value", value);
      ("span", span_json 0 1 24 25);
    ]

let concurrent_param_json name value =
  Lsp_json.Object
    [
      ("name", ident_json name 0 1 3 4);
      ("value", value);
      ("span", span_json 0 1 8 9);
    ]

let concurrent_block_expr_json params body =
  Lsp_json.Object
    [
      ("kind", Lsp_json.String "concurrent_block");
      ("params", Lsp_json.Array params);
      ("body", body);
      ("span", span_json 0 1 24 25);
    ]

let concurrent_for_expr_json name iterable params body =
  Lsp_json.Object
    [
      ("kind", Lsp_json.String "concurrent_for");
      ("name", ident_json name 0 1 1 2);
      ("iterable", iterable);
      ("params", Lsp_json.Array params);
      ("body", body);
      ("span", span_json 0 1 24 25);
    ]

let detach_expr_json body =
  Lsp_json.Object
    [
      ("kind", Lsp_json.String "detach");
      ("body", body);
      ("span", span_json 0 1 12 13);
    ]

let type_param_json name bounds start_offset start_column end_offset end_column =
  Lsp_json.Object
    [
      ("name", ident_json name start_offset start_column end_offset end_column);
      ( "bounds",
        Lsp_json.Array
          (List.map
             (fun bound -> ident_json bound start_offset start_column end_offset end_column)
             bounds) );
      ("span", span_json start_offset start_column end_offset end_column);
    ]

let field_decl_json name type_expr start_offset start_column end_offset end_column =
  Lsp_json.Object
    [
      ("name", ident_json name start_offset start_column end_offset end_column);
      ("type", type_expr);
      ("span", span_json start_offset start_column end_offset end_column);
    ]

let variant_decl_json name fields start_offset start_column end_offset end_column =
  Lsp_json.Object
    [
      ("name", ident_json name start_offset start_column end_offset end_column);
      ("fields", Lsp_json.Array fields);
      ("span", span_json start_offset start_column end_offset end_column);
    ]

let function_json ?(annotations = []) ?params ?return_type ?(doc = Lsp_json.Null)
    ?(body = Some (int_expr_json "42" 36 37 38 39)) () =
  let function_params =
    Option.value params
      ~default:
        [
          param_json
            ~type_expr:(named_type_json "List" 16 17 28 29)
            (param_name_binder_json "args");
        ]
  in
  let function_body =
    Lsp_json.Object
      [
        ("name", ident_json "main" 5 6 9 10);
        ("type_params", Lsp_json.Array []);
        ("params", Lsp_json.Array function_params);
        ("return_type", Option.value return_type ~default:Lsp_json.Null);
        ("body", Option.value body ~default:Lsp_json.Null);
        ("is_pure", Lsp_json.Bool false);
        ( "annotations",
          Lsp_json.Array (List.map (fun s -> Lsp_json.String s) annotations)
        );
        ("doc", doc);
        ("span", span_json 0 1 39 40);
      ]
  in
  Lsp_json.Object
    [
      ("kind", Lsp_json.String "function");
      ("name", Lsp_json.String "main");
      ("function", function_body);
    ]

let function_payload_json () =
  match function_json () with
  | Lsp_json.Object fields -> (
      match List.assoc_opt "function" fields with
      | Some payload -> payload
      | None -> Alcotest.fail "function fixture must include function payload")
  | _ -> Alcotest.fail "function fixture must be an object"

let var_decl_json ?(is_mutable = false) () =
  Lsp_json.Object
    [
      ("kind", Lsp_json.String "var");
      ("name", Lsp_json.String "answer");
      ( "var",
        Lsp_json.Object
          [
            ("name", ident_json "answer" 0 1 6 7);
            ("type", named_type_json "Int" 8 9 11 12);
            ("value", int_expr_json "42" 14 15 16 17);
            ("is_mutable", Lsp_json.Bool is_mutable);
            ("span", span_json 0 1 16 17);
          ] );
    ]

let import_symbol_json ?alias ?(constructors = []) name =
  Lsp_json.Object
    [
      ("name", ident_json name 0 1 6 7);
      ( "alias",
        match alias with
        | Some alias -> ident_json alias 0 1 6 7
        | None -> Lsp_json.Null );
      ( "constructors",
        Lsp_json.Array
          (List.map
             (fun ctor -> ident_json ctor 0 1 6 7)
             constructors) );
      ("span", span_json 0 1 6 7);
    ]

let import_decl_json ?alias ?symbols module_path =
  Lsp_json.Object
    [
      ("module_path", Lsp_json.String module_path);
      ( "module_alias",
        match alias with
        | Some alias -> ident_json alias 0 1 6 7
        | None -> Lsp_json.Null );
      ( "symbols",
        match symbols with
        | Some symbols -> Lsp_json.Array symbols
        | None -> Lsp_json.Null );
      ("span", span_json 0 1 20 21);
    ]

let import_block_json imports =
  Lsp_json.Object
    [
      ("kind", Lsp_json.String "import_block");
      ("imports", Lsp_json.Array imports);
      ("span", span_json 0 1 20 21);
    ]

let foreign_block_arg_json name value =
  Lsp_json.Object
    [
      ("name", ident_json name 0 1 6 7);
      ("value", Lsp_json.String value);
      ("span", span_json 0 1 12 13);
    ]

let foreign_function_decl_json ?(annotations = []) ?(is_private = false)
    ?(is_pure = false) ?c_name name =
  Lsp_json.Object
    [
      ("name", ident_json name 0 1 6 7);
      ( "params",
        Lsp_json.Array
          [
            param_json
              ~type_expr:(named_type_json "Float" 11 12 16 17)
              (param_name_binder_json "x");
          ] );
      ("return_type", named_type_json "Float" 21 22 26 27);
      ( "c_name",
        match c_name with Some name -> Lsp_json.String name | None -> Lsp_json.Null
      );
      ("is_pure", Lsp_json.Bool is_pure);
      ("is_private", Lsp_json.Bool is_private);
      ( "annotations",
        Lsp_json.Array (List.map (fun s -> Lsp_json.String s) annotations)
      );
      ("span", span_json 0 1 26 27);
    ]

let foreign_block_json args functions =
  Lsp_json.Object
    [
      ("kind", Lsp_json.String "foreign_block");
      ("args", Lsp_json.Array args);
      ("functions", Lsp_json.Array functions);
      ("span", span_json 0 1 40 41);
    ]

let record_decl_json ?(is_struct = false) ?(doc = Lsp_json.Null) () =
  Lsp_json.Object
    [
      ("kind", Lsp_json.String "record");
      ("name", Lsp_json.String "Point");
      ( "record",
        Lsp_json.Object
          [
            ("name", ident_json "Point" 7 8 12 13);
            ("type_params", Lsp_json.Array []);
            ( "fields",
              Lsp_json.Array
                [
                  field_decl_json "x" (named_type_json "Int" 16 17 19 20) 14
                    15 20 21;
                ] );
            ("is_struct", Lsp_json.Bool is_struct);
            ("doc", doc);
            ("span", span_json 0 1 22 23);
          ] );
    ]

let union_decl_json ?(is_enum = false) ?(doc = Lsp_json.Null) () =
  Lsp_json.Object
    [
      ("kind", Lsp_json.String "union");
      ("name", Lsp_json.String "Maybe");
      ( "union",
        Lsp_json.Object
          [
            ("name", ident_json "Maybe" 6 7 11 12);
            ( "type_params",
              Lsp_json.Array [ type_param_json "T" [] 12 13 13 14 ] );
            ( "variants",
              Lsp_json.Array
                [
                  variant_decl_json "Some"
                    [ named_type_json "T" 18 19 19 20 ]
                    14 15 21 22;
                  variant_decl_json "None" [] 23 24 27 28;
                ] );
            ("is_enum", Lsp_json.Bool is_enum);
            ("doc", doc);
            ("span", span_json 0 1 27 28);
          ] );
    ]

let builtin_type_decl_json ?(is_resource = false) ?(cleanup = Lsp_json.Null) ()
    =
  Lsp_json.Object
    [
      ("kind", Lsp_json.String "builtin_type");
      ("name", Lsp_json.String "FileReader");
      ( "type",
        Lsp_json.Object
          [
            ("name", ident_json "FileReader" 14 15 24 25);
            ("type_params", Lsp_json.Array []);
            ("is_resource", Lsp_json.Bool is_resource);
            ("cleanup", cleanup);
            ("doc", Lsp_json.Null);
            ("span", span_json 0 1 34 35);
          ] );
    ]

let resource_cleanup_json name =
  Lsp_json.Object
    [
      ("kind", Lsp_json.String "builtin");
      ("name", Lsp_json.String name);
      ("span", span_json 25 26 34 35);
    ]

let type_alias_decl_json ?(is_opaque = false) ?target () =
  let alias_target =
    Option.value target ~default:(named_type_json "Int" 20 21 23 24)
  in
  Lsp_json.Object
    [
      ("kind", Lsp_json.String "type_alias");
      ("name", Lsp_json.String "UserId");
      ( "alias",
        Lsp_json.Object
          [
            ("name", ident_json "UserId" 11 12 17 18);
            ("type_params", Lsp_json.Array []);
            ("target", alias_target);
            ("is_opaque", Lsp_json.Bool is_opaque);
            ("doc", Lsp_json.String "alias docs");
            ("span", span_json 0 1 23 24);
          ] );
    ]

let private_decl_json decl =
  Lsp_json.Object
    [
      ("kind", Lsp_json.String "private");
      ("decl", decl);
      ("span", span_json 0 1 39 40);
    ]

let trait_decl_json () =
  Lsp_json.Object
    [
      ("kind", Lsp_json.String "trait");
      ("name", Lsp_json.String "Show");
      ( "trait",
        Lsp_json.Object
          [
            ("name", ident_json "Show" 6 7 10 11);
            ("type_params", Lsp_json.Array []);
            ( "supertraits",
              Lsp_json.Array [ ident_json "Debug" 12 13 17 18 ] );
            ( "methods",
              Lsp_json.Array
                [
                  Lsp_json.Object
                    [
                      ("name", ident_json "show" 20 21 24 25);
                      ( "params",
                        Lsp_json.Array
                          [
                            param_json
                              ~type_expr:(named_type_json "Self" 31 32 35 36)
                              (param_name_binder_json "self");
                          ] );
                      ("return_type", named_type_json "String" 40 41 46 47);
                      ("body", Lsp_json.Null);
                      ("is_pure", Lsp_json.Bool true);
                      ("span", span_json 20 21 46 47);
                    ];
                ] );
            ("doc", Lsp_json.Null);
            ("span", span_json 0 1 46 47);
          ] );
    ]

let impl_decl_json () =
  Lsp_json.Object
    [
      ("kind", Lsp_json.String "impl");
      ( "impl",
        Lsp_json.Object
          [
            ("trait_name", ident_json "Show" 11 12 15 16);
            ("for_type", named_type_json "Int" 20 21 23 24);
            ("methods", Lsp_json.Array [ function_payload_json () ]);
            ("doc", Lsp_json.Null);
            ("span", span_json 0 1 40 41);
          ] );
    ]

let program_json decls diagnostics =
  Lsp_json.Object
    [
      ("kind", Lsp_json.String "parsed_program");
      ( "source",
        Lsp_json.Object
          [
            ("kind", Lsp_json.String "source_file");
            ("path", Lsp_json.String "main.brp");
            ("module", Lsp_json.String "main");
            ("text", Lsp_json.String "func main(args: List[String]) -> Int: 42");
          ] );
      ("decls", Lsp_json.Array decls);
      ("diagnostics", Lsp_json.Array diagnostics);
    ]

let decode_ok json =
  match Parsed_ast_json.decode_program json with
  | Ok program -> program
  | Error err -> Alcotest.fail (Parsed_ast_json.decode_error_to_string err)

let decode_error json =
  match Parsed_ast_json.decode_program json with
  | Ok _ -> Alcotest.fail "expected decode error"
  | Error err -> Parsed_ast_json.decode_error_to_string err

let decode_error_record json =
  match Parsed_ast_json.decode_program json with
  | Ok _ -> Alcotest.fail "expected decode error"
  | Error err -> err

let decode_parse_diagnostics_ok json =
  match Parsed_ast_json.decode_parse_diagnostics json with
  | Ok diagnostics -> diagnostics
  | Error err -> Alcotest.fail (Parsed_ast_json.decode_error_to_string err)

let test_decodes_simple_function_program () =
  let program =
    decode_ok
      (program_json
         [
           function_json
             ~return_type:(named_type_json "Int" 32 33 35 36)
             ();
         ]
         [])
  in
  match program with
  | [
   {
     Ast.decl_desc = Ast.DFunc func;
     decl_doc = None;
     decl_loc =
       {
         line = 1;
         column = 1;
         end_line = 1;
         end_column = 40;
         loc_file = Some "main.brp";
       };
   };
  ] -> (
      Alcotest.(check (option string)) "function name" (Some "main") func.func_name;
      Alcotest.(check int) "param count" 1 (List.length func.func_params);
      Alcotest.(check bool) "not pure" false func.func_is_pure;
      Alcotest.(check bool) "not tailrec" false func.func_is_tailrec;
      Alcotest.(check (option string))
        "return type"
        (Some "Int")
        (Option.map
           (function Ast.TyNamed (name, []) -> name | _ -> "<other>")
           func.func_return_type);
      match func.func_body with
      | Ast.FuncBodyExpr { Ast.expr_desc = Ast.ELiteral (Ast.LitInt value); _ } ->
          Alcotest.(check int64) "literal" 42L value
      | _ -> Alcotest.fail "expected int literal body")
  | _ -> Alcotest.fail "expected one function declaration"

let test_decodes_parameter_binders () =
  let tuple_type =
    tuple_type_json
      [ named_type_json "Int" 0 1 3 4; named_type_json "Int" 0 1 3 4 ]
  in
  let program =
    decode_ok
      (program_json
         [
           function_json
             ~params:
               [
                 param_json
                   ~type_expr:(named_type_json "String" 0 1 6 7)
                   (param_name_binder_json "value");
                 param_json (param_wildcard_binder_json ());
                 param_json ~type_expr:tuple_type
                   (param_tuple_binder_json [ "left"; "right" ]);
               ]
             ();
         ]
         [])
  in
  match program with
  | [ { Ast.decl_desc = Ast.DFunc { func_params = params; _ }; _ } ] -> (
      match params with
      | [
       { Ast.param_name = Some "value"; param_pattern = None; _ };
       { Ast.param_name = None; param_pattern = Some Ast.PatWildcard; _ };
       {
         Ast.param_name = None;
         param_pattern = Some (Ast.PatTuple [ Ast.PatVar "left"; Ast.PatVar "right" ]);
         param_type = Some (Ast.TyTuple [ Ast.TyNamed ("Int", []); Ast.TyNamed ("Int", []) ]);
         _;
       };
      ] -> ()
      | _ -> Alcotest.fail "expected decoded parameter binders")
  | _ -> Alcotest.fail "expected function declaration"

let test_decodes_function_annotations_and_doc () =
  let program =
    decode_ok
      (program_json
         [
           function_json
             ~annotations:[ "tail_recursive"; "debug_only"; "no_copy" ]
             ~doc:(Lsp_json.String "docs")
             ();
         ]
         [])
  in
  match program with
  | [ { Ast.decl_desc = Ast.DFunc func; decl_doc = Some "docs"; _ } ] ->
      Alcotest.(check bool) "tail recursive" true func.func_is_tailrec;
      Alcotest.(check bool) "debug only" true func.func_debug_only;
      Alcotest.(check bool) "no copy" true func.func_no_copy
  | _ -> Alcotest.fail "expected documented function"

let test_decodes_builtin_body_like_parser () =
  let body =
    Lsp_json.Object
      [
        ("kind", Lsp_json.String "builtin");
        ("name", Lsp_json.String "std/list.__unsafe_list_get");
        ("span", span_json 10 11 17 18);
      ]
  in
  let program = decode_ok (program_json [ function_json ~body:(Some body) () ] []) in
  match program with
  | [
   {
     Ast.decl_desc =
       Ast.DFunc
         {
           func_body =
             Ast.FuncBuiltinBody (Ast.BuiltinStdIntrinsic identity, _);
           _;
         };
     _;
   };
  ] ->
      Alcotest.(check string)
        "std builtin module" "std/list"
        identity.Ast.std_builtin_module_path;
      Alcotest.(check string)
        "std builtin function" "__unsafe_list_get"
        identity.Ast.std_builtin_func_name
  | _ -> Alcotest.fail "expected std builtin body"

let test_decodes_top_level_value_and_type_declarations () =
  let program =
    decode_ok
      (program_json
         [
           var_decl_json ();
           record_decl_json ~doc:(Lsp_json.String "point docs") ();
           union_decl_json ~doc:(Lsp_json.String "maybe docs") ();
           builtin_type_decl_json ~is_resource:true
             ~cleanup:(resource_cleanup_json "blorp_file_close_reader")
             ();
           type_alias_decl_json ();
         ]
         [])
  in
  match program with
  | [
   { Ast.decl_desc = Ast.DVar var; _ };
   { Ast.decl_desc = Ast.DRecord record; decl_doc = Some "point docs"; _ };
   { Ast.decl_desc = Ast.DType union_decl; decl_doc = Some "maybe docs"; _ };
   { Ast.decl_desc = Ast.DType builtin_decl; _ };
   { Ast.decl_desc = Ast.DTypeAlias alias; decl_doc = Some "alias docs"; _ };
  ] ->
      Alcotest.(check (option string)) "var name" (Some "answer") var.var_name;
      Alcotest.(check bool) "immutable top-level var is const" true var.var_is_const;
      Alcotest.(check string) "record name" "Point" record.record_name;
      Alcotest.(check bool) "record is heap record" false record.record_is_value;
      Alcotest.(check int) "record fields" 1 (List.length record.record_fields);
      Alcotest.(check string) "union name" "Maybe" union_decl.type_name;
      Alcotest.(check bool) "union is not enum" false union_decl.type_is_enum;
      Alcotest.(check int) "union variants" 2 (List.length union_decl.type_variants);
      Alcotest.(check string) "builtin type name" "FileReader" builtin_decl.type_name;
      Alcotest.(check bool) "builtin type" true builtin_decl.type_is_builtin;
      Alcotest.(check bool) "resource type" true builtin_decl.type_is_resource;
      (match builtin_decl.type_resource_cleanup with
      | Some (Ast.ResourceCleanupBuiltin name) ->
          Alcotest.(check string)
            "resource cleanup" "blorp_file_close_reader" name
      | None -> Alcotest.fail "expected resource cleanup");
      Alcotest.(check string) "alias name" "UserId" alias.alias_name;
      Alcotest.(check bool) "alias is not opaque" false alias.alias_is_opaque
  | _ -> Alcotest.fail "expected value/type declaration sequence"

let test_decodes_complex_type_expressions () =
  let dim_limit =
    dim_binary_type_json "add" (dim_name_type_json "N") (dim_literal_type_json "1")
  in
  let target =
    function_type_json
      [
        bounded_type_json "T" [ "Show" ];
        qualified_type_json "math" "Vec"
          [ named_type_json "Float" 0 1 5 6 ];
      ]
      (array_type_json
         (tuple_type_json
            [
              named_type_json "Int" 0 1 3 4;
              range_type_json dim_limit;
            ])
         [ dim_name_type_json ~is_variadic:true "Ds" ])
  in
  let program =
    decode_ok (program_json [ type_alias_decl_json ~target () ] [])
  in
  match program with
  | [
   {
     Ast.decl_desc =
       Ast.DTypeAlias
         {
           alias_target =
             Ast.TyFunc
               {
                 is_pure = true;
                 params =
                   [
                     Ast.TyBoundVar bound;
                     Ast.TyNamed ("math.Vec", [ Ast.TyNamed ("Float", []) ]);
                   ];
                 return =
                   Ast.TyArray
                     ( Ast.TyTuple
                         [
                           Ast.TyNamed ("Int", []);
                           Ast.TyRange
                             (Ast.TyDimOp
                                (Ast.DimAdd, Ast.TyVar "N", Ast.TyConstInt 1));
                         ],
                       [ Ast.TyVarDims "Ds" ] );
               };
           _;
         };
     _;
   };
  ] ->
      Alcotest.(check string) "bound name" "T" bound.Ast.param_name;
      Alcotest.(check (list string))
        "bounds" [ "Show" ]
        (Generic_params.trait_ref_names bound.Ast.param_bounds)
  | _ -> Alcotest.fail "expected complex type alias target"

let test_decodes_private_declaration_wrapper () =
  let program = decode_ok (program_json [ private_decl_json (function_json ()) ] []) in
  match program with
  | [
   {
     Ast.decl_desc =
       Ast.DPrivate { Ast.decl_desc = Ast.DFunc { func_name = Some "main"; _ }; _ };
     _;
   };
  ] -> ()
  | _ -> Alcotest.fail "expected private function wrapper"

let test_decodes_import_block_to_import_declarations () =
  let option_symbol =
    import_symbol_json ~constructors:[ "Some"; "None" ] "Option"
  in
  let program =
    decode_ok
      (program_json
         [
           import_block_json
             [
               import_decl_json ~symbols:[ option_symbol ] "option";
               import_decl_json ~alias:"D" "dict";
             ];
         ]
         [])
  in
  match program with
  | [
   { Ast.decl_desc = Ast.DImport option_import; _ };
   { Ast.decl_desc = Ast.DImport dict_import; _ };
  ] ->
      Alcotest.(check string) "module" "option" option_import.import_module;
      Alcotest.(check (option string)) "dict alias" (Some "D") dict_import.import_alias;
      (match option_import.import_symbols with
      | Some [ symbol ] -> (
          Alcotest.(check string) "symbol" "Option" symbol.sym_name;
          match symbol.sym_ctors with
          | Ast.CtorSome ctors ->
              Alcotest.(check (list string)) "constructors" [ "Some"; "None" ] ctors
          | Ast.CtorNone -> Alcotest.fail "expected imported constructors")
      | _ -> Alcotest.fail "expected selective import symbol")
  | _ -> Alcotest.fail "expected import block to flatten into imports"

let test_decodes_trait_and_impl_declarations () =
  let program = decode_ok (program_json [ trait_decl_json (); impl_decl_json () ] []) in
  match program with
  | [
   { Ast.decl_desc = Ast.DTrait trait_decl; _ };
   { Ast.decl_desc = Ast.DImpl impl_decl; _ };
  ] ->
      Alcotest.(check string) "trait name" "Show" trait_decl.trait_name;
      Alcotest.(check (list string)) "supertraits" [ "Debug" ] trait_decl.trait_supertraits;
      (match trait_decl.trait_methods with
      | [ method_decl ] -> (
          match method_decl.method_params with
          | [ { Ast.param_type = Some Ast.TySelf; _ } ] -> ()
          | _ -> Alcotest.fail "expected Self trait method parameter")
      | _ -> Alcotest.fail "expected one trait method");
      Alcotest.(check string) "impl trait" "Show" impl_decl.impl_trait;
      Alcotest.(check int) "impl methods" 1 (List.length impl_decl.impl_methods)
  | _ -> Alcotest.fail "expected trait and impl declarations"

let function_body_expr program =
  match program with
  | [ { Ast.decl_desc = Ast.DFunc { func_body = Ast.FuncBodyExpr body; _ }; _ } ] ->
      body
  | _ -> Alcotest.fail "expected function body expression"

let test_decodes_data_match_and_lambda_expressions () =
  let record_field =
    record_expr_field_json "x" (int_expr_json "1" 4 5 5 6) 2 3 5 6
  in
  let record_expr = record_expr_json [ record_field ] in
  let update_expr =
    record_update_expr_json (name_expr_json "point" 0 1 5 6)
      [ record_expr_field_json "x" (int_expr_json "2" 8 9 9 10) 6 7 9 10 ]
  in
  let dict_expr =
    dict_expr_json
      [
        dict_entry_json (string_expr_json "a" 1 2 4 5)
          (int_expr_json "3" 8 9 9 10);
      ]
  in
  let match_expr =
    match_expr_json (name_expr_json "maybe" 0 1 5 6)
      [
        match_case_json
          (constructor_pattern_json "Some" [ name_pattern_json "value" ])
          (name_expr_json "value" 14 15 19 20);
        match_case_json (float_pattern_json "3.5") (int_expr_json "1" 0 1 1 2);
        match_case_json (char_pattern_json 65) (int_expr_json "2" 0 1 1 2);
        match_case_json
          (or_pattern_json [ int_pattern_json "0"; int_pattern_json "1" ])
          (int_expr_json "3" 0 1 1 2);
        match_case_json
          (tuple_pattern_json
             [ int_pattern_json "0"; int_pattern_json "0"; int_pattern_json "0" ])
          (int_expr_json "4" 0 1 1 2);
        match_case_json
          (list_pattern_json
             ~spread:(list_spread_name_json "rest")
             [ name_pattern_json "head" ])
          (int_expr_json "5" 0 1 1 2);
        match_case_json
          (list_pattern_json ~spread:(list_spread_wildcard_json ()) [])
          (int_expr_json "6" 0 1 1 2);
        match_case_json (wildcard_pattern_json ()) (int_expr_json "0" 22 23 23 24);
      ]
  in
  let lambda_expr =
    lambda_expr_json
      [ lambda_param_json "n" (Some (named_type_json "Int" 3 4 6 7)) ]
      (name_expr_json "n" 11 12 12 13)
  in
  let ascription_expr =
    ascription_expr_json (name_expr_json "value" 0 1 5 6)
      (named_type_json "Int" 9 10 12 13)
  in
  let char_expr = char_expr_json 65 0 1 3 4 in
  let body =
    block_expr_json
      [
        record_expr;
        update_expr;
        dict_expr;
        match_expr;
        lambda_expr;
        ascription_expr;
        char_expr;
      ]
      0 1 60 61
  in
  let decoded = decode_ok (program_json [ function_json ~body:(Some body) () ] []) in
  match (function_body_expr decoded).Ast.expr_desc with
  | Ast.EBlock
      [
        { Ast.expr_desc = Ast.ERecord record_fields; _ };
        { Ast.expr_desc = Ast.ERecordUpdate (_, update_fields); _ };
        { Ast.expr_desc = Ast.EDict dict_entries; _ };
        { Ast.expr_desc = Ast.EMatch (_, match_cases); _ };
        { Ast.expr_desc = Ast.ELambda lambda_decl; _ };
        { Ast.expr_desc = Ast.EAscription (_, Ast.TyNamed ("Int", [])); _ };
        { Ast.expr_desc = Ast.ELiteral (Ast.LitChar 65); _ };
      ] ->
      Alcotest.(check int) "record fields" 1 (List.length record_fields);
      Alcotest.(check int) "update fields" 1 (List.length update_fields);
      Alcotest.(check int) "dict entries" 1 (List.length dict_entries);
      Alcotest.(check int) "match cases" 8 (List.length match_cases);
      (match List.nth_opt match_cases 1 with
      | Some { Ast.case_pattern = Ast.PatLiteral (Ast.LitFloat value); _ } ->
          Alcotest.(check (float 0.0)) "float pattern" 3.5 value
      | _ -> Alcotest.fail "expected float literal pattern");
      (match List.nth_opt match_cases 2 with
      | Some { Ast.case_pattern = Ast.PatLiteral (Ast.LitChar value); _ } ->
          Alcotest.(check int) "char pattern" 65 value
      | _ -> Alcotest.fail "expected char literal pattern");
      (match List.nth_opt match_cases 3 with
      | Some { Ast.case_pattern = Ast.PatOr patterns; _ } ->
          Alcotest.(check int) "or pattern count" 2 (List.length patterns)
      | _ -> Alcotest.fail "expected or pattern");
      (match List.nth_opt match_cases 4 with
      | Some { Ast.case_pattern = Ast.PatTuple patterns; _ } ->
          Alcotest.(check int) "tuple pattern count" 3 (List.length patterns)
      | _ -> Alcotest.fail "expected tuple pattern");
      (match List.nth_opt match_cases 5 with
      | Some { Ast.case_pattern = Ast.PatList (patterns, Some (Ast.PatVar "rest")); _ } ->
          Alcotest.(check int) "list pattern count" 1 (List.length patterns)
      | _ -> Alcotest.fail "expected list pattern");
      (match List.nth_opt match_cases 6 with
      | Some { Ast.case_pattern = Ast.PatList ([], Some Ast.PatWildcard); _ } -> ()
      | _ -> Alcotest.fail "expected wildcard spread list pattern");
      Alcotest.(check bool) "lambda purity" true lambda_decl.func_is_pure;
      Alcotest.(check int) "lambda params" 1 (List.length lambda_decl.func_params)
  | _ -> Alcotest.fail "expected decoded data/match/lambda expressions"

let test_decodes_resource_select_and_concurrency_expressions () =
  let void_body = block_expr_json [] 0 1 8 9 in
  let with_expr =
    with_expr_json
      (with_binding_json ~kind:"try"
         ~type_expr:(named_type_json "Reader" 3 4 9 10)
         ~error_map:
           (with_error_map_json "err" (string_expr_json "open" 5 6 11 12))
         "reader" (name_expr_json "open_reader" 10 11 21 22))
      void_body
  in
  let select_expr =
    select_expr_json
      [
        select_arm_json
          (select_arm_kind_json "receive"
             [
               ("name", ident_json "item" 0 1 4 5);
               ("source", name_expr_json "channel" 8 9 15 16);
             ])
          void_body;
        select_arm_json
          (select_arm_kind_json "sealed"
             [ ("source", name_expr_json "channel" 8 9 15 16) ])
          void_body;
        select_arm_json
          (select_arm_kind_json "after"
             [ ("source", int_expr_json "10" 8 9 10 11) ])
          void_body;
      ]
  in
  let debug_expr = debug_block_expr_json void_body in
  let concurrent_block =
    concurrent_block_expr_json
      [
        concurrent_param_json "max_threads" (int_expr_json "4" 0 1 1 2);
        concurrent_param_json "timeout" (int_expr_json "50" 0 1 2 3);
      ]
      (block_expr_json [ name_expr_json "work" 0 1 4 5 ] 0 1 8 9)
  in
  let concurrent_for =
    concurrent_for_expr_json "item" (name_expr_json "items" 0 1 5 6)
      [
        concurrent_param_json "limit" (int_expr_json "2" 0 1 1 2);
        concurrent_param_json "timeout" (int_expr_json "50" 0 1 2 3);
      ]
      void_body
  in
  let detach_expr = detach_expr_json (name_expr_json "background" 0 1 10 11) in
  let body =
    block_expr_json
      [
        with_expr;
        select_expr;
        debug_expr;
        concurrent_block;
        concurrent_for;
        detach_expr;
      ]
      0 1 80 81
  in
  let decoded = decode_ok (program_json [ function_json ~body:(Some body) () ] []) in
  match (function_body_expr decoded).Ast.expr_desc with
  | Ast.EBlock
      [
        { Ast.expr_desc = Ast.EWith (binding, _); _ };
        { Ast.expr_desc = Ast.ESelect select_arms; _ };
        { Ast.expr_desc = Ast.EDebugBlock debug_items; _ };
        { Ast.expr_desc = Ast.EConcurrent (items, timeout, max_threads); _ };
        { Ast.expr_desc = Ast.EConcurrentlyLoop (_, _, _, loop_timeout, loop_width); _ };
        { Ast.expr_desc = Ast.EDetach _; _ };
      ] ->
      Alcotest.(check string) "with binding" "reader" binding.with_name;
      Alcotest.(check int) "select arms" 3 (List.length select_arms);
      Alcotest.(check int) "debug items" 0 (List.length debug_items);
      Alcotest.(check int) "concurrent items" 1 (List.length items);
      Alcotest.(check bool) "concurrent timeout" true (Option.is_some timeout);
      Alcotest.(check (option int)) "max_threads" (Some 4) max_threads;
      Alcotest.(check bool) "loop timeout" true (Option.is_some loop_timeout);
      (match loop_width with
      | Ast.ConcurrentlyLoopLimit n ->
          Alcotest.(check int) "concurrent loop limit" 2 n)
	  | _ -> Alcotest.fail "expected decoded resource/select/concurrency expressions"

let test_concurrent_param_validation_errors_keep_source_loc () =
  let void_body = block_expr_json [] 0 1 8 9 in
  let concurrent_for =
    concurrent_for_expr_json "item" (name_expr_json "items" 0 1 5 6)
      [ concurrent_param_json "limit" (name_expr_json "threads" 10 11 17 18) ]
      void_body
  in
  let body = block_expr_json [ concurrent_for ] 0 1 24 25 in
  let err =
    decode_error_record (program_json [ function_json ~body:(Some body) () ] [])
  in
  Alcotest.(check string)
    "message" "concurrently limit must be an integer literal" err.message;
  match err.loc with
  | Some loc ->
      Alcotest.(check int) "line" 1 loc.Ast.line;
      Alcotest.(check int) "column" 11 loc.Ast.column
  | None -> Alcotest.fail "expected source location"

let test_decodes_for_loop_binders () =
  let void_body = block_expr_json [] 0 1 8 9 in
  let named_for =
    for_expr_json (for_name_binder_json "item") (name_expr_json "items" 0 1 5 6)
      void_body
  in
  let tuple_for =
    for_expr_json
      (for_tuple_binder_json [ "key"; "value" ])
      (name_expr_json "pairs" 0 1 5 6)
      void_body
  in
  let body = block_expr_json [ named_for; tuple_for ] 0 1 80 81 in
  let decoded = decode_ok (program_json [ function_json ~body:(Some body) () ] []) in
  match (function_body_expr decoded).Ast.expr_desc with
  | Ast.EBlock
      [
        { Ast.expr_desc = Ast.EFor (name, _, _); _ };
        { Ast.expr_desc = Ast.EForTuple (names, _, _); _ };
      ] ->
      Alcotest.(check string) "for name binder" "item" name;
      Alcotest.(check (list string)) "for tuple binder" [ "key"; "value" ] names
  | _ -> Alcotest.fail "expected decoded for loop binders"

let test_decodes_tuple_destruct_assignment () =
  let body =
    tuple_destruct_expr_json [ "left"; "right" ]
      (name_expr_json "pair" 0 1 4 5)
  in
  let decoded = decode_ok (program_json [ function_json ~body:(Some body) () ] []) in
  match (function_body_expr decoded).Ast.expr_desc with
  | Ast.ETupleDestruct (names, { Ast.expr_desc = Ast.EIdent "pair"; _ }) ->
      Alcotest.(check (list string)) "tuple destruct names" [ "left"; "right" ] names
  | _ -> Alcotest.fail "expected decoded tuple destruct assignment"

let test_decodes_subscript_assignment () =
  let body =
    subscript_assign_expr_json
      (name_expr_json "items" 0 1 5 6)
      [ name_expr_json "i" 6 7 7 8 ]
      (int_expr_json "99" 12 13 14 15)
  in
  let decoded = decode_ok (program_json [ function_json ~body:(Some body) () ] []) in
  match (function_body_expr decoded).Ast.expr_desc with
  | Ast.ESubscriptAssign
      ( { Ast.expr_desc = Ast.EIdent "items"; _ },
        [ { Ast.expr_desc = Ast.EIdent "i"; _ } ],
        { Ast.expr_desc = Ast.ELiteral (Ast.LitInt 99L); _ } ) -> ()
  | _ -> Alcotest.fail "expected decoded subscript assignment"

let test_decodes_opaque_alias_and_conversions () =
  let alias_program =
    decode_ok (program_json [ type_alias_decl_json ~is_opaque:true () ] [])
  in
  let () =
    match alias_program with
    | [ { Ast.decl_desc = Ast.DTypeAlias alias; _ } ] ->
        Alcotest.(check string) "alias name" "UserId" alias.alias_name;
        Alcotest.(check bool) "alias is opaque" true alias.alias_is_opaque
    | _ -> Alcotest.fail "expected opaque type alias declaration"
  in
  let body =
    block_expr_json
      [
        opaque_into_expr_json
          (named_type_json "UserId" 0 1 6 7)
          (int_expr_json "1" 12 13 13 14);
        opaque_from_expr_json
          (named_type_json "UserId" 0 1 6 7)
          (name_expr_json "id" 12 13 14 15);
      ]
      0 1 24 25
  in
  let decoded = decode_ok (program_json [ function_json ~body:(Some body) () ] []) in
  match (function_body_expr decoded).Ast.expr_desc with
  | Ast.EBlock
      [
        {
          expr_desc =
            Ast.EOpaqueInto
              ( Ast.TyNamed ("UserId", []),
                { expr_desc = Ast.ELiteral (Ast.LitInt 1L); _ } );
          _;
        };
        {
          expr_desc =
            Ast.EOpaqueFrom (Ast.TyNamed ("UserId", []), { expr_desc = Ast.EIdent "id"; _ });
          _;
        };
      ] -> ()
  | _ -> Alcotest.fail "expected decoded opaque conversion expressions"

let test_decodes_parse_diagnostics () =
  let diagnostic =
    Lsp_json.Object
      [
        ("severity", Lsp_json.String "error");
        ("span", span_json 0 1 4 5);
        ("message", Lsp_json.String "expected declaration");
        ("expected", Lsp_json.Array []);
        ("help", Lsp_json.Null);
      ]
  in
  let diagnostics = decode_parse_diagnostics_ok (program_json [] [ diagnostic ]) in
  (match diagnostics with
  | [ diagnostic ] ->
      Alcotest.(check string)
        "message" "expected declaration" diagnostic.parsed_diagnostic_message;
      Alcotest.(check int)
        "column" 1 diagnostic.parsed_diagnostic_span.Ast.column;
      Alcotest.(check (list string))
        "expected" [] diagnostic.parsed_diagnostic_expected;
      Alcotest.(check (option string))
        "help" None diagnostic.parsed_diagnostic_help
  | _ -> Alcotest.fail "expected one parse diagnostic");
  Alcotest.(check string)
    "AST decoder still rejects diagnostics"
    "$.diagnostics: parsed AST diagnostics must be handled before AST decoding"
    (decode_error (program_json [] [ diagnostic ]))

let test_decodes_foreign_block_declarations () =
  let program =
    decode_ok
      (program_json
         [
           foreign_block_json
             [
               foreign_block_arg_json "include" "math.h";
               foreign_block_arg_json "link_linux" "-ldl";
             ]
             [
               foreign_function_decl_json ~is_pure:true ~c_name:"sqrt" "sqrt";
               foreign_function_decl_json ~annotations:[ "no_copy" ] "process";
               foreign_function_decl_json ~is_private:true ~is_pure:true
                 ~c_name:"secret_c" "secret";
             ];
         ]
         [])
  in
  match program with
  | [
   { Ast.decl_desc = Ast.DFunc sqrt_func; _ };
   { Ast.decl_desc = Ast.DFunc process_func; _ };
   { Ast.decl_desc = Ast.DPrivate { Ast.decl_desc = Ast.DFunc secret_func; _ }; _ };
  ] -> (
      let foreign_info func =
        match func.Ast.func_body with
        | Ast.FuncForeign foreign -> foreign
        | _ -> Alcotest.fail "expected foreign function"
      in
      let sqrt_foreign = foreign_info sqrt_func in
      let process_foreign = foreign_info process_func in
      let secret_foreign = foreign_info secret_func in
      Alcotest.(check (option string)) "sqrt name" (Some "sqrt") sqrt_func.func_name;
      Alcotest.(check bool) "sqrt pure" true sqrt_func.func_is_pure;
      Alcotest.(check string) "sqrt c name" "sqrt" sqrt_foreign.foreign_name;
      Alcotest.(check (list string)) "includes" [ "math.h" ]
        sqrt_foreign.foreign_includes;
      Alcotest.(check (list (pair (option string) string)))
        "link flags" [ (Some "linux", "-ldl") ] sqrt_foreign.foreign_link_flags;
      Alcotest.(check bool) "process no_copy" true process_func.func_no_copy;
      Alcotest.(check string) "process c name defaults" "process"
        process_foreign.foreign_name;
      Alcotest.(check bool) "private pure" true secret_func.func_is_pure;
      Alcotest.(check string) "private c name" "secret_c" secret_foreign.foreign_name)
  | _ -> Alcotest.fail "expected foreign block to expand into foreign decls"

let suite =
  [
    ( "decode",
      [
        Alcotest.test_case "simple function program" `Quick
          test_decodes_simple_function_program;
        Alcotest.test_case "parameter binders" `Quick
          test_decodes_parameter_binders;
        Alcotest.test_case "function annotations and doc" `Quick
          test_decodes_function_annotations_and_doc;
        Alcotest.test_case "builtin body" `Quick test_decodes_builtin_body_like_parser;
        Alcotest.test_case "top-level value and type declarations" `Quick
          test_decodes_top_level_value_and_type_declarations;
        Alcotest.test_case "complex type expressions" `Quick
          test_decodes_complex_type_expressions;
        Alcotest.test_case "private declaration wrapper" `Quick
          test_decodes_private_declaration_wrapper;
        Alcotest.test_case "import block expands to imports" `Quick
          test_decodes_import_block_to_import_declarations;
        Alcotest.test_case "trait and impl declarations" `Quick
          test_decodes_trait_and_impl_declarations;
        Alcotest.test_case "data, match, and lambda expressions" `Quick
          test_decodes_data_match_and_lambda_expressions;
	        Alcotest.test_case "resource, select, and concurrency expressions" `Quick
	          test_decodes_resource_select_and_concurrency_expressions;
        Alcotest.test_case "concurrent validation keeps source loc" `Quick
          test_concurrent_param_validation_errors_keep_source_loc;
	        Alcotest.test_case "for loop binders" `Quick test_decodes_for_loop_binders;
        Alcotest.test_case "tuple destruct assignment" `Quick
          test_decodes_tuple_destruct_assignment;
        Alcotest.test_case "subscript assignment" `Quick
          test_decodes_subscript_assignment;
        Alcotest.test_case "opaque alias and conversions" `Quick
          test_decodes_opaque_alias_and_conversions;
        Alcotest.test_case "decodes parse diagnostics" `Quick
          test_decodes_parse_diagnostics;
        Alcotest.test_case "foreign block declarations" `Quick
          test_decodes_foreign_block_declarations;
      ] );
  ]
