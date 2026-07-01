(** Unit tests for LSP cursor-position helpers. *)

open Blorp

let check_word text ~line ~col expected =
  Alcotest.(check (option string))
    "word at cursor" expected
    (Lsp_position.word_at text ~line ~col)

let test_word_at_finds_identifier_boundaries () =
  let source = "first\n    value_1.field\n" in
  check_word source ~line:1 ~col:4 (Some "value_1");
  check_word source ~line:1 ~col:10 (Some "value_1");
  check_word source ~line:1 ~col:3 None;
  check_word source ~line:1 ~col:12 (Some "field");
  check_word source ~line:3 ~col:0 None;
  check_word source ~line:1 ~col:99 None

let import_symbol ?sym_alias ?(sym_ctors = Ast.CtorNone) sym_name :
    Ast.import_symbol =
  { sym_name; sym_alias; sym_ctors }

let import_decl ?import_symbols ?import_alias import_module : Ast.import_decl =
  { import_module; import_symbols; import_alias }

let check_imported_name import local expected =
  Alcotest.(check (option string))
    "resolved import name" expected
    (Lsp_position.resolve_imported_name import local)

let test_resolve_imported_name_handles_aliases_and_constructors () =
  let selective =
    import_decl "list"
      ~import_symbols:
        [
          import_symbol "append" ~sym_alias:"push";
          import_symbol "Option" ~sym_ctors:(Ast.CtorSome [ "Some"; "None" ]);
        ]
  in
  check_imported_name selective "push" (Some "append");
  check_imported_name selective "append" None;
  check_imported_name selective "Some" (Some "Some");
  check_imported_name selective "Missing" None;
  let qualified = import_decl "dict" in
  check_imported_name qualified "get" (Some "get")

let loc file ~line ~column =
  {
    Ast.line = line;
    column;
    end_line = line;
    end_column = column + 1;
    loc_file = Some file;
  }

let ident_expr file name ~line ~column =
  Ast.untyped_expr ~loc:(loc file ~line ~column) (Ast.EIdent name)

let var_decl file name value =
  let value_loc = (value : Ast.expr).expr_loc in
  {
    Ast.decl_desc =
      Ast.DVar
        {
          var_name = Some name;
          var_pattern = None;
          var_type = None;
          var_value = value;
          var_is_mutable = false;
          var_is_const = false;
        };
    decl_loc = loc file ~line:value_loc.line ~column:1;
    decl_doc = None;
  }

let ident_name = function
  | Some { Ast.expr_desc = Ast.EIdent name; _ } -> Some name
  | _ -> None

let test_find_expr_at_filters_by_file () =
  let source_expr = ident_expr "source.brp" "source_value" ~line:1 ~column:5 in
  let imported_expr = ident_expr "std/prelude.brp" "imported_value" ~line:1 ~column:9 in
  let program =
    [
      var_decl "source.brp" "source_value" source_expr;
      var_decl "std/prelude.brp" "imported_value" imported_expr;
    ]
  in
  Alcotest.(check (option string))
    "unfiltered lookup keeps closest expression"
    (Some "imported_value")
    (Lsp_position.find_expr_at program ~line:0 ~col:12 |> ident_name);
  Alcotest.(check (option string))
    "file-filtered lookup ignores imported expression"
    (Some "source_value")
    (Lsp_position.find_expr_at program ~file:"source.brp" ~line:0 ~col:12
    |> ident_name)

let suite =
  [
    ( "position",
      [
        Alcotest.test_case "word_at finds identifier boundaries" `Quick
          test_word_at_finds_identifier_boundaries;
        Alcotest.test_case "resolve_imported_name handles import forms" `Quick
          test_resolve_imported_name_handles_aliases_and_constructors;
        Alcotest.test_case "find_expr_at filters by file" `Quick
          test_find_expr_at_filters_by_file;
      ] );
  ]
