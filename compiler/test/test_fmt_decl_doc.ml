(** Unit tests for declaration-formatting parity JSON.

    These mirror [tests/test_blorp/tools/test_declaration_documents.brp] so the OCaml
    formatter printer and the Blorp declaration-doc printer stay pinned to the
    same visible syntax while declaration formatting is ported in slices. *)

module Ast = Blorp.Ast
module DeclJson = Blorp.Fmt_decl_json
module Fmt = Blorp.Fmt

let check_string msg = Alcotest.(check string) msg

let string_contains haystack needle =
  let haystack_len = String.length haystack in
  let needle_len = String.length needle in
  let rec loop idx =
    if idx + needle_len > haystack_len then false
    else if String.sub haystack idx needle_len = needle then true
    else loop (idx + 1)
  in
  needle_len = 0 || loop 0

let expr expr_desc =
  {
    Ast.expr_desc;
    expr_loc = Ast.dummy_loc;
    expr_type = None;
    expr_type_info = None;
    expr_rc = None;
  }

let int_lit n = expr (Ast.ELiteral (Ast.LitInt (Int64.of_int n)))
let ident name = expr (Ast.EIdent name)
let ty_named name args = Ast.TyNamed (name, args)

let typed_param name ty =
  {
    Ast.param_name = Some name;
    param_pattern = None;
    param_type = Some ty;
    param_passing = Ast.ParamByValue;
    param_loc = Ast.dummy_loc;
  }

let decl ?doc desc =
  { Ast.decl_desc = desc; decl_loc = Ast.dummy_loc; decl_doc = doc }

let variant name fields =
  {
    Ast.variant_name = name;
    variant_fields = fields;
    variant_tag = 0;
    variant_loc = Ast.dummy_loc;
    variant_def_id = None;
  }

let field_decl name ty =
  { Ast.field_name = name; field_type = ty; field_loc = Ast.dummy_loc }

let trait_method ?return_type ?(is_pure = false) ?body name params =
  {
    Ast.method_name = name;
    method_params = params;
    method_return_type = return_type;
    method_is_pure = is_pure;
    method_default_body = body;
  }

let func ?(type_params = []) ?return_type ?(is_pure = false)
    ?(is_tailrec = false) name params body =
  {
    Ast.func_name = Some name;
    func_type_params = type_params;
    func_params = params;
    func_return_type = return_type;
    func_body = Ast.FuncBodyExpr body;
    func_is_pure = is_pure;
    func_is_tailrec = is_tailrec;
    func_no_copy = false;
    func_debug_only = false;
    func_resource_result_ordinary = false;
    func_dim_constraints = [];
  }

let func_with_body ?(type_params = []) ?return_type ?(is_pure = false)
    ?(is_tailrec = false) ?(no_copy = false) ?(debug_only = false) name params
    body =
  {
    Ast.func_name = Some name;
    func_type_params = type_params;
    func_params = params;
    func_return_type = return_type;
    func_body = body;
    func_is_pure = is_pure;
    func_is_tailrec = is_tailrec;
    func_no_copy = no_copy;
    func_debug_only = debug_only;
    func_resource_result_ordinary = false;
    func_dim_constraints = [];
  }

let test_import_decl_json () =
  let imp =
    {
      Ast.import_module = "list";
      import_alias = None;
      import_symbols =
        Some
          [
            { sym_name = "append"; sym_alias = None; sym_ctors = Ast.CtorNone };
            { sym_name = "get"; sym_alias = None; sym_ctors = Ast.CtorNone };
            {
              sym_name = "Option";
              sym_alias = None;
              sym_ctors = Ast.CtorSome [ "Some"; "None" ];
            };
          ];
    }
  in
  check_string "import declaration JSON"
    {|{"tag":"Import","module":"list","symbols":[{"name":"append"},{"name":"get"},{"name":"Option","ctors":["Some","None"]}]}|}
    (DeclJson.import_to_json imp)

let test_var_decl_json () =
  let var =
    {
      Ast.var_name = Some "total";
      var_pattern = None;
      var_type = Some (ty_named "Int" []);
      var_value = int_lit 0;
      var_is_mutable = true;
      var_is_const = false;
    }
  in
  match DeclJson.decl_to_json (decl (Ast.DVar var)) with
  | None -> Alcotest.fail "expected var declaration to serialize"
  | Some json ->
      Alcotest.(check bool)
        "includes Var tag" true
        (string_contains json {|{"tag":"Var","private":false|});
      Alcotest.(check bool)
        "includes mutable field" true
        (string_contains json {|"mutable":true|});
      Alcotest.(check bool)
        "includes type field" true
        (string_contains json {|"type":{"tag":"Named","name":"Int","args":[]}|})

let test_type_record_alias_decl_json () =
  let type_decl =
    {
      Ast.type_name = "Option";
      type_params = [ Ast.make_type_param "T" [] ];
      type_variants = [ variant "Some" [ ty_named "T" [] ]; variant "None" [] ];
      type_is_enum = false;
      type_is_builtin = false;
      type_is_resource = false;
      type_resource_cleanup = None;
    }
  in
  let record_decl =
    {
      Ast.record_name = "Point";
      record_type_params = [];
      record_fields =
        [
          field_decl "x" (ty_named "Int" []); field_decl "y" (ty_named "Int" []);
        ];
      record_is_value = false;
      record_is_builtin = false;
    }
  in
  let alias_decl =
    {
      Ast.alias_name = "Pair";
      alias_type_params =
        [ Ast.make_type_param "A" []; Ast.make_type_param "B" [] ];
      alias_target = Ast.TyTuple [ Ast.TyVar "A"; Ast.TyVar "B" ];
    }
  in
  match
    ( DeclJson.decl_to_json (decl (Ast.DType type_decl)),
      DeclJson.decl_to_json (decl (Ast.DRecord record_decl)),
      DeclJson.decl_to_json (decl (Ast.DTypeAlias alias_decl)) )
  with
  | Some type_json, Some record_json, Some alias_json ->
      Alcotest.(check bool)
        "includes type declaration" true
        (string_contains type_json {|{"tag":"Type","private":false|});
      Alcotest.(check bool)
        "includes record declaration" true
        (string_contains record_json {|{"tag":"Record","private":false|});
      Alcotest.(check bool)
        "includes alias declaration" true
        (string_contains alias_json {|{"tag":"TypeAlias","private":false|})
  | _ ->
      Alcotest.fail "expected type, record, and alias declarations to serialize"

let test_trait_impl_decl_json () =
  let trait_decl =
    {
      Ast.trait_name = "Incrementable";
      trait_type_params = [];
      trait_supertraits = [];
      trait_methods =
        [
          trait_method ~return_type:Ast.TySelf "increment"
            [ typed_param "self" Ast.TySelf ];
        ];
    }
  in
  let impl_decl =
    {
      Ast.impl_trait = "Incrementable";
      impl_for_type = ty_named "Counter" [];
      impl_methods =
        [
          func ~return_type:(ty_named "Counter" []) "increment"
            [ typed_param "self" (ty_named "Counter" []) ]
            (ident "self");
        ];
    }
  in
  match
    ( DeclJson.decl_to_json (decl (Ast.DTrait trait_decl)),
      DeclJson.decl_to_json (decl (Ast.DImpl impl_decl)) )
  with
  | Some trait_json, Some impl_json ->
      Alcotest.(check bool)
        "includes trait declaration" true
        (string_contains trait_json {|{"tag":"Trait","private":false|});
      Alcotest.(check bool)
        "includes impl declaration" true
        (string_contains impl_json {|{"tag":"Impl","private":false|})
  | _ -> Alcotest.fail "expected trait and impl declarations to serialize"

let test_non_expression_impl_method_decl_json () =
  let impl_decl =
    {
      Ast.impl_trait = "Stringable";
      impl_for_type = ty_named "Char" [];
      impl_methods =
        [
          func_with_body ~is_pure:true ~return_type:(ty_named "String" [])
            "to_string"
            [ typed_param "val" (ty_named "Char" []) ]
            (Ast.FuncBuiltinBody
               (Ast.BuiltinRuntime "blorp_from_char", Ast.dummy_loc));
        ];
    }
  in
  let d = decl (Ast.DImpl impl_decl) in
  match DeclJson.decl_to_json d with
  | None -> Alcotest.fail "expected builtin impl method to serialize"
  | Some decl_json ->
      Alcotest.(check bool)
        "includes builtin method body kind" true
        (string_contains decl_json {|"body_kind":"builtin"|});
      Alcotest.(check bool)
        "includes builtin method name" true
        (string_contains decl_json {|"builtin_name":"blorp_from_char"|});
      Alcotest.(check bool)
        "case keeps expected layout" true
        (string_contains
           (DeclJson.case_json d decl_json)
           {|"expected":"implements Stringable for Char:\n\tpure func to_string(val: Char) -> String:\n\t\tbuiltin(\"blorp_from_char\")\n"|})

let test_non_expression_func_decl_json () =
  let builtin_func =
    func_with_body ~return_type:(ty_named "Int" []) "read_clock" []
      (Ast.FuncBuiltinBody (Ast.BuiltinRuntime "blorp_read_clock", Ast.dummy_loc))
  in
  let foreign_func =
    func_with_body ~return_type:(ty_named "Float" []) "floor"
      [ typed_param "x" (ty_named "Float" []) ]
      (Ast.FuncForeign
         {
           foreign_name = "c_floor";
           foreign_includes = [];
           foreign_link_flags = [];
         })
  in
  let no_body_func =
    func_with_body ~return_type:(ty_named "Int" []) "pending"
      [ typed_param "x" (ty_named "Int" []) ]
      Ast.FuncNoBody
  in
  match
    ( DeclJson.decl_to_json (decl (Ast.DFunc builtin_func)),
      DeclJson.decl_to_json (decl (Ast.DFunc foreign_func)),
      DeclJson.decl_to_json (decl (Ast.DFunc no_body_func)) )
  with
  | Some builtin_json, Some foreign_json, Some no_body_json ->
      Alcotest.(check bool)
        "includes builtin body kind" true
        (string_contains builtin_json {|"body_kind":"builtin"|});
      Alcotest.(check bool)
        "includes builtin runtime name" true
        (string_contains builtin_json {|"builtin_name":"blorp_read_clock"|});
      Alcotest.(check bool)
        "includes foreign body kind" true
        (string_contains foreign_json {|"body_kind":"foreign"|});
      Alcotest.(check bool)
        "includes foreign target name" true
        (string_contains foreign_json {|"foreign_name":"c_floor"|});
      Alcotest.(check bool)
        "includes no-body kind" true
        (string_contains no_body_json {|"body_kind":"none"|})
  | _ ->
      Alcotest.fail
        "expected builtin, foreign, and no-body function declarations to \
         serialize"

let test_docstring_decl_json () =
  let fd =
    func ~return_type:(ty_named "Int" []) ~is_pure:true "add"
      [
        typed_param "x" (ty_named "Int" []); typed_param "y" (ty_named "Int" []);
      ]
      (expr (Ast.EBinary (Ast.Add, ident "x", ident "y")))
  in
  let d =
    decl ~doc:"Adds two numbers.\nKeeps overflow wrapping." (Ast.DFunc fd)
  in
  match DeclJson.decl_to_json d with
  | None -> Alcotest.fail "expected docstring declaration to serialize"
  | Some decl_json ->
      Alcotest.(check bool)
        "wraps declaration docstring" true
        (string_contains decl_json
           {|{"tag":"Doc","doc":"Adds two numbers.\nKeeps overflow wrapping.","decl":{"tag":"Func"|});
      let case_json = DeclJson.case_json d decl_json in
      Alcotest.(check bool)
        "expected layout includes docstring" true
        (string_contains case_json
           {|"expected":"---\nAdds two numbers.\nKeeps overflow wrapping.\n---\npure func add(x: Int, y: Int) -> Int:\n\tx + y\n"|})

let test_doctest_docstring_decl_json_keeps_body_case () =
  let fd =
    func ~return_type:(ty_named "Int" []) "example" []
      (expr (Ast.ELiteral (Ast.LitInt 1L)))
  in
  let d =
    decl ~doc:"Examples\n\ndoctests:\n    :: works\n    1" (Ast.DFunc fd)
  in
  match DeclJson.decl_to_json d with
  | None -> Alcotest.fail "expected declaration body to serialize"
  | Some decl_json ->
      Alcotest.(check bool)
        "wraps doctest docstring" true
        (string_contains decl_json {|{"tag":"Doc"|});
      let case_json = DeclJson.case_json d decl_json in
      Alcotest.(check bool)
        "expected layout includes doctest docstring" true
        (string_contains case_json
           {|"expected":"---\nExamples\n\ndoctests:\n    :: works\n    1\n---\nfunc example() -> Int:\n\t1\n"|})

let test_program_decl_json () =
  let source =
    String.concat "\n"
      [
        "var total: Int = 0";
        "";
        "type alias Pair[A, B] = (A, B)";
        "";
        "pure func add(x: Int, y: Int) -> Int:";
        "    x + y";
        "";
        "pure func add(x: Float, y: Float) -> Float:";
        "    x + y";
        "";
      ]
  in
  match Fmt.format_decl_cases_json_lines_string source with
  | Error msg -> Alcotest.fail msg
  | Ok jsonl ->
      Alcotest.(check bool)
        "includes program case" true
        (string_contains jsonl {|"program":[|});
      Alcotest.(check bool)
        "program expected keeps overloads adjacent" true
        (string_contains jsonl
           {|"expected":"var total: Int = 0\n\ntype alias Pair[A, B] = (A, B)\n\n\npure func add(x: Int, y: Int) -> Int:\n\tx + y\npure func add(x: Float, y: Float) -> Float:\n\tx + y\n"|})

let test_program_decl_json_with_imports () =
  let source =
    String.concat "\n"
      [
        "import:";
        "    list: get, append";
        "    dict as D";
        "";
        "var total: Int = 0";
        "";
      ]
  in
  match Fmt.format_decl_cases_json_lines_string source with
  | Error msg -> Alcotest.fail msg
  | Ok jsonl ->
      Alcotest.(check bool)
        "includes program case" true
        (string_contains jsonl {|"program":[|});
      Alcotest.(check bool)
        "program expected groups leading imports" true
        (string_contains jsonl
           {|"expected":"import:\n\tdict as D\n\tlist: append, get\n\n\nvar total: Int = 0\n"|})

let test_program_decl_json_with_duplicate_imports () =
  let source =
    String.concat "\n"
      [
        "import:";
        "    dict as D";
        "    dict as D";
        "    list: get, append";
        "";
        "var total: Int = 0";
        "";
      ]
  in
  match Fmt.format_decl_cases_json_lines_string source with
  | Error msg -> Alcotest.fail msg
  | Ok jsonl ->
      Alcotest.(check bool)
        "includes program case" true
        (string_contains jsonl {|"program":[|});
      Alcotest.(check bool)
        "program expected deduplicates imports" true
        (string_contains jsonl
           {|"expected":"import:\n\tdict as D\n\tlist: append, get\n\n\nvar total: Int = 0\n"|})

let test_program_decl_json_with_body_imports () =
  let source =
    String.concat "\n"
      [
        "type alias Pair[A, B] = (A, B)";
        "";
        "import:";
        "    list: get, append";
        "    dict as D";
        "";
        "var total: Int = 0";
        "";
      ]
  in
  match Fmt.format_decl_cases_json_lines_string source with
  | Error msg -> Alcotest.fail msg
  | Ok jsonl ->
      Alcotest.(check bool)
        "includes program case" true
        (string_contains jsonl {|"program":[|});
      Alcotest.(check bool)
        "program expected keeps body import block" true
        (string_contains jsonl
           {|"expected":"type alias Pair[A, B] = (A, B)\n\n\nimport:\n\tdict as D\n\tlist: append, get\n\n\nvar total: Int = 0\n"|})

let test_decl_json_preserves_block_blank_lines () =
  let source =
    String.concat "\n"
      [
        "func grouped() -> Int:";
        "    a: Int = 1";
        "";
        "    b: Int = 2";
        "    a + b";
        "";
      ]
  in
  match Fmt.format_decl_cases_json_lines_string source with
  | Error msg -> Alcotest.fail msg
  | Ok jsonl ->
      Alcotest.(check bool)
        "includes block blank metadata" true
        (string_contains jsonl {|"blank_before":[false,true,false]|});
      Alcotest.(check bool)
        "expected layout keeps block blank line" true
        (string_contains jsonl
           {|"expected":"func grouped() -> Int:\n\ta: Int = 1\n\n\tb: Int = 2\n\ta + b\n"|})

let test_program_decl_json_with_body_comments () =
  let source =
    String.concat "\n"
      [
        "func grouped() -> Int:";
        "    a: Int = 1";
        "";
        "    -- keep this with the block";
        "    b: Int = 2";
        "    a + b";
        "";
      ]
  in
  match Fmt.format_decl_cases_json_lines_string source with
  | Error msg -> Alcotest.fail msg
  | Ok jsonl ->
      Alcotest.(check bool)
        "includes block item metadata" true
        (string_contains jsonl {|"items":[|});
      Alcotest.(check bool)
        "includes body comment item" true
        (string_contains jsonl {|"text":"-- keep this with the block"|});
      Alcotest.(check bool)
        "program expected keeps body comment" true
        (string_contains jsonl
           {|"expected":"func grouped() -> Int:\n\ta: Int = 1\n\n\t-- keep this with the block\n\tb: Int = 2\n\ta + b\n"|})

let test_program_decl_json_with_body_trailing_comments () =
  let source =
    String.concat "\n"
      [
        "func grouped() -> Int:";
        "    a: Int = 1 -- first";
        "    b: Int = 2 -- second";
        "    a + b -- result";
        "";
      ]
  in
  match Fmt.format_decl_cases_json_lines_string source with
  | Error msg -> Alcotest.fail msg
  | Ok jsonl ->
      Alcotest.(check bool)
        "includes trailing block item metadata" true
        (string_contains jsonl {|"trailing":"-- first"|});
      Alcotest.(check bool)
        "program expected keeps body trailing comments" true
        (string_contains jsonl
           {|"expected":"func grouped() -> Int:\n\ta: Int = 1 -- first\n\tb: Int = 2 -- second\n\ta + b -- result\n"|})

let test_program_decl_json_with_comments () =
  let source =
    String.concat "\n"
      [
        "-- file header";
        "var total: Int = 0 -- count";
        "-- alias comment";
        "type alias Count = Int";
        "-- eof";
        "";
      ]
  in
  match Fmt.format_decl_cases_json_lines_string source with
  | Error msg -> Alcotest.fail msg
  | Ok jsonl ->
      Alcotest.(check bool)
        "includes program case" true
        (string_contains jsonl {|"program":[|});
      Alcotest.(check bool)
        "includes comments" true
        (string_contains jsonl {|"comments":[|});
      Alcotest.(check bool)
        "program expected keeps comments" true
        (string_contains jsonl
           {|"expected":"-- file header\nvar total: Int = 0 -- count\n\n-- alias comment\ntype alias Count = Int\n-- eof\n"|})

let test_program_decl_json_with_doctest_docstring () =
  let source =
    String.concat "\n"
      [
        "---";
        "Example docs.";
        "";
        "doctests:";
        "    :: unformatted list";
        "    xs: List[Int]=[1,2]";
        "    xs.length()==2";
        "---";
        "func documented() -> Int:";
        "    1";
        "";
      ]
  in
  match Fmt.format_decl_cases_json_lines_string source with
  | Error msg -> Alcotest.fail msg
  | Ok jsonl ->
      Alcotest.(check bool)
        "includes program case" true
        (string_contains jsonl {|"program":[|});
      Alcotest.(check bool)
        "JSON doc body is normalized" true
        (string_contains jsonl {|xs: List[Int] = [1, 2]\n    xs.length() == 2|});
      Alcotest.(check bool)
        "program expected keeps normalized doctest" true
        (string_contains jsonl
           {|"expected":"---\nExample docs.\n\ndoctests:\n    :: unformatted list\n    xs: List[Int] = [1, 2]\n    xs.length() == 2\n---\nfunc documented() -> Int:\n\t1\n"|})

let test_program_decl_json_with_import_comments () =
  let source =
    String.concat "\n"
      [
        "-- file header";
        "import:";
        "    -- dict import";
        "    dict as D -- dict trailing";
        "    -- list import";
        "    list: get, append";
        "-- body comment";
        "var total: Int = 0";
        "";
      ]
  in
  match Fmt.format_decl_cases_json_lines_string source with
  | Error msg -> Alcotest.fail msg
  | Ok jsonl ->
      Alcotest.(check bool)
        "includes program case" true
        (string_contains jsonl {|"program":[|});
      Alcotest.(check bool)
        "includes comments" true
        (string_contains jsonl {|"comments":[|});
      Alcotest.(check bool)
        "program expected keeps import comments" true
        (string_contains jsonl
           {|"expected":"-- file header\n-- dict import\nimport:\n\tdict as D -- dict trailing\n\t-- list import\n\tlist: append, get\n\n\n-- body comment\nvar total: Int = 0\n"|})

let test_program_decl_json_with_foreign_block () =
  let source =
    String.concat "\n"
      [
        "foreign func floor(x: Float) -> Float = \"c_floor\"";
        "";
        "func read_clock() -> Int:";
        "    builtin(\"blorp_read_clock\")";
        "";
      ]
  in
  match Fmt.format_decl_cases_json_lines_string source with
  | Error msg -> Alcotest.fail msg
  | Ok jsonl ->
      Alcotest.(check bool)
        "includes program case" true
        (string_contains jsonl {|"program":[|});
      Alcotest.(check bool)
        "program expected groups foreign functions" true
        (string_contains jsonl
           {|"expected":"foreign:\n\tfunc floor(x: Float) -> Float = \"c_floor\"\n\n\nfunc read_clock() -> Int:\n\tbuiltin(\"blorp_read_clock\")\n"|})

let test_program_decl_json_with_foreign_comments () =
  let source =
    String.concat "\n"
      [
        "-- file header";
        "-- foreign block comment";
        "foreign(include: \"math.h\", link: \"-lm\"):";
        "    -- floor comment";
        "    func floor(x: Float) -> Float = \"c_floor\" -- floor trailing";
        "    -- ceil comment";
        "    func ceil(x: Float) -> Float = \"c_ceil\"";
        "-- body comment";
        "var total: Int = 0";
        "";
      ]
  in
  match Fmt.format_decl_cases_json_lines_string source with
  | Error msg -> Alcotest.fail msg
  | Ok jsonl ->
      Alcotest.(check bool)
        "includes program case" true
        (string_contains jsonl {|"program":[|});
      Alcotest.(check bool)
        "includes foreign includes" true
        (string_contains jsonl {|"foreign_includes":["math.h"]|});
      Alcotest.(check bool)
        "program expected keeps foreign comments" true
        (string_contains jsonl
           {|"expected":"-- file header\n-- foreign block comment\n-- floor comment\nforeign(include: \"math.h\", link: \"-lm\"):\n\tfunc floor(x: Float) -> Float = \"c_floor\" -- floor trailing\n\t-- ceil comment\n\tfunc ceil(x: Float) -> Float = \"c_ceil\"\n\n\n-- body comment\nvar total: Int = 0\n"|})

let test_func_decl_json_case_uses_ocaml_expected_layout () =
  let fd =
    func
      ~type_params:[ Ast.make_type_param "T" [] ]
      ~return_type:(ty_named "Int" []) ~is_pure:true "add"
      [
        typed_param "x" (ty_named "Int" []); typed_param "y" (ty_named "Int" []);
      ]
      (expr (Ast.EBinary (Ast.Add, ident "x", ident "y")))
  in
  let d = decl (Ast.DFunc fd) in
  match DeclJson.decl_to_json d with
  | None -> Alcotest.fail "expected function declaration to serialize"
  | Some decl_json ->
      let case_json = DeclJson.case_json d decl_json in
      check_string "case includes expected layout"
        {|{"line":0,"column":0,"expected":"pure func add[T](x: Int, y: Int) -> Int:\n\tx + y\n","decl":|}
        (String.sub case_json 0
           (String.length
              {|{"line":0,"column":0,"expected":"pure func add[T](x: Int, y: Int) -> Int:\n\tx + y\n","decl":|}))

let test_decl_json_lines_from_source () =
  let source =
    String.concat "\n"
      [
        "import:";
        "    dict as D";
        "    list: get, append";
        "";
        "type alias Pair[A, B] = (A, B)";
        "";
        "record Point {x: Int, y: Int}";
        "";
        "record Counter {value: Int}";
        "";
        "struct Box {value: Int}";
        "";
        "union Option[T]:";
        "    Some(T)";
        "    None";
        "";
        "enum Color:";
        "    Red";
        "    Green";
        "";
        "trait Incrementable:";
        "    func increment(self: Self) -> Self";
        "";
        "trait Named:";
        "    pure func name(self: Self) -> String: \"item\"";
        "";
        "trait Serializable: Incrementable";
        "";
        "implements Incrementable for Counter:";
        "    func increment(self: Counter) -> Counter:";
        "        self";
        "";
        "implements Stringable for Char:";
        "    pure func to_string(val: Char) -> String:";
        "        builtin(\"blorp_from_char\")";
        "";
        "var total: Int = 0";
        "";
        "private name = \"blorp\"";
        "";
        "foreign func floor(x: Float) -> Float = \"c_floor\"";
        "";
        "---";
        "Read the clock.";
        "---";
        "func read_clock() -> Int:";
        "    builtin(\"blorp_read_clock\")";
        "";
        "pure func add[T](x: Int, y: Int) -> Int:";
        "    x + y";
        "";
      ]
  in
  match Fmt.format_decl_cases_json_lines_string source with
  | Error msg -> Alcotest.fail msg
  | Ok jsonl ->
      Alcotest.(check bool)
        "emits declaration cases" true
        (String.contains jsonl '\n');
      Alcotest.(check bool)
        "includes import case" true
        (string_contains jsonl {|{"tag":"Import","module":"dict","alias":"D"|});
      Alcotest.(check bool)
        "includes var case" true
        (string_contains jsonl {|{"tag":"Var","private":false|});
      Alcotest.(check bool)
        "includes private var case" true
        (string_contains jsonl {|{"tag":"Var","private":true|});
      Alcotest.(check bool)
        "includes function case" true
        (string_contains jsonl {|{"tag":"Func","private":false,"name":"add"|});
      Alcotest.(check bool)
        "includes type alias case" true
        (string_contains jsonl {|{"tag":"TypeAlias","private":false|});
      Alcotest.(check bool)
        "includes record case" true
        (string_contains jsonl
           {|{"tag":"Record","private":false,"name":"Point"|});
      Alcotest.(check bool)
        "includes union case" true
        (string_contains jsonl {|{"tag":"Type","private":false,"name":"Option"|});
      Alcotest.(check bool)
        "includes trait case" true
        (string_contains jsonl
           {|{"tag":"Trait","private":false,"name":"Incrementable"|});
      Alcotest.(check bool)
        "includes impl case" true
        (string_contains jsonl {|{"tag":"Impl","private":false|});
      Alcotest.(check bool)
        "includes foreign function case" true
        (string_contains jsonl {|"body_kind":"foreign"|});
      Alcotest.(check bool)
        "includes builtin function case" true
        (string_contains jsonl {|"body_kind":"builtin"|});
      Alcotest.(check bool)
        "includes builtin impl method case" true
        (string_contains jsonl {|"builtin_name":"blorp_from_char"|});
      Alcotest.(check bool)
        "includes docstring case" true
        (string_contains jsonl {|"tag":"Doc","doc":"Read the clock."|})

let suite =
  [
    ( "decl_doc",
      [
        Alcotest.test_case "import declaration JSON" `Quick
          test_import_decl_json;
        Alcotest.test_case "variable declaration JSON" `Quick test_var_decl_json;
        Alcotest.test_case "type, record, alias declaration JSON" `Quick
          test_type_record_alias_decl_json;
        Alcotest.test_case "trait and impl declaration JSON" `Quick
          test_trait_impl_decl_json;
        Alcotest.test_case "non-expression impl method declaration JSON" `Quick
          test_non_expression_impl_method_decl_json;
        Alcotest.test_case "non-expression function declaration JSON" `Quick
          test_non_expression_func_decl_json;
        Alcotest.test_case "docstring declaration JSON" `Quick
          test_docstring_decl_json;
        Alcotest.test_case "doctest docstring keeps body case" `Quick
          test_doctest_docstring_decl_json_keeps_body_case;
        Alcotest.test_case "program declaration JSON" `Quick
          test_program_decl_json;
        Alcotest.test_case "program declaration JSON with imports" `Quick
          test_program_decl_json_with_imports;
        Alcotest.test_case "program declaration JSON with duplicate imports"
          `Quick test_program_decl_json_with_duplicate_imports;
        Alcotest.test_case "program declaration JSON with body imports" `Quick
          test_program_decl_json_with_body_imports;
        Alcotest.test_case "declaration JSON preserves block blank lines" `Quick
          test_decl_json_preserves_block_blank_lines;
        Alcotest.test_case "program declaration JSON with body comments" `Quick
          test_program_decl_json_with_body_comments;
        Alcotest.test_case
          "program declaration JSON with body trailing comments" `Quick
          test_program_decl_json_with_body_trailing_comments;
        Alcotest.test_case "program declaration JSON with comments" `Quick
          test_program_decl_json_with_comments;
        Alcotest.test_case "program declaration JSON with doctest docstring"
          `Quick test_program_decl_json_with_doctest_docstring;
        Alcotest.test_case "program declaration JSON with import comments"
          `Quick test_program_decl_json_with_import_comments;
        Alcotest.test_case "program declaration JSON with foreign block" `Quick
          test_program_decl_json_with_foreign_block;
        Alcotest.test_case "program declaration JSON with foreign comments"
          `Quick test_program_decl_json_with_foreign_comments;
        Alcotest.test_case "declaration JSON case uses OCaml expected layout"
          `Quick test_func_decl_json_case_uses_ocaml_expected_layout;
        Alcotest.test_case "declaration JSONL emits source cases" `Quick
          test_decl_json_lines_from_source;
      ] );
  ]
