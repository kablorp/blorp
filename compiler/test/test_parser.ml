(** Unit tests for parser edge cases that formatter-driven integration tests
    would normalize before parsing. *)

let check_int msg = Alcotest.(check int) msg
let check_string msg = Alcotest.(check string) msg
let check_bool msg = Alcotest.(check bool) msg

let parse_ok source =
  match Blorp.Modules.parse_source source with
  | Ok program -> program
  | Error err -> Alcotest.fail err.message

let parse_error_message source =
  match Blorp.Modules.parse_source source with
  | Ok _ -> Alcotest.fail "expected parse error"
  | Error err -> err.message

let test_empty_programs_parse_to_no_decls () =
  check_int "empty source" 0 (List.length (parse_ok ""));
  check_int "newline-only source" 0 (List.length (parse_ok "\n\n"))

let test_import_block_accepts_comment_only_lines () =
  let source =
    "import:\n" ^ "\t-- Keep this comment attached to the import block.\n"
    ^ "\toption: Option(Some, None)\n\n\n"
    ^ "func main(args: List[String]) -> Int:\n" ^ "\t0\n"
  in
  let program = parse_ok source in
  check_int "declaration count" 2 (List.length program);
  match program with
  | { Blorp.Ast.decl_desc = Blorp.Ast.DImport imp; _ } :: _ ->
      check_string "module" "option" imp.Blorp.Ast.import_module
  | _ -> Alcotest.fail "expected first declaration to be an import"

let test_builtin_direct_runtime_body () =
  let source =
    "pure func stringify_int(x: Int) -> String:\n"
    ^ "\tbuiltin(\"blorp_to_string\")\n"
  in
  let program = parse_ok source in
  match program with
  | [ { Blorp.Ast.decl_desc = Blorp.Ast.DFunc f; _ } ] -> (
      match f.Blorp.Ast.func_body with
      | Blorp.Ast.FuncBuiltinBody (Blorp.Ast.BuiltinRuntimeHelper c_name, _) ->
          check_string "runtime builtin target" "blorp_to_string" c_name
      | _ -> Alcotest.fail "expected builtin(\"...\") function body")
  | _ -> Alcotest.fail "expected one function declaration"

let test_builtin_std_identity_body () =
  let source =
    "private pure func __unsafe_list_get[T](self: List[T], index: Int) -> T:\n"
    ^ "\tbuiltin(\"std/list.__unsafe_list_get\")\n"
  in
  let program = parse_ok source in
  match program with
  | [ { Blorp.Ast.decl_desc = Blorp.Ast.DPrivate private_decl; _ } ] -> (
      match private_decl.Blorp.Ast.decl_desc with
      | Blorp.Ast.DFunc f -> (
          match f.Blorp.Ast.func_body with
          | Blorp.Ast.FuncBuiltinBody (Blorp.Ast.BuiltinStdIntrinsic identity, _)
            ->
              check_string "std builtin module" "std/list"
                identity.Blorp.Ast.std_builtin_module_path;
              check_string "std builtin function" "__unsafe_list_get"
                identity.Blorp.Ast.std_builtin_func_name
          | _ -> Alcotest.fail "expected std builtin identity body")
      | _ -> Alcotest.fail "expected private function declaration")
  | _ -> Alcotest.fail "expected one private function declaration"

let test_builtin_std_identity_rejects_missing_function_name () =
  let source = "pure func bad() -> Int:\n" ^ "\tbuiltin(\"std/list\")\n" in
  check_string "parse error"
    "std builtin identities must use builtin(\"std/module.function\")"
    (parse_error_message source)

let test_builtin_sentinel_body_has_explicit_kind () =
  let source = "func length(xs: List[Int]) -> Int:\n" ^ "\tbuiltin\n" in
  let program = parse_ok source in
  match program with
  | [ { Blorp.Ast.decl_desc = Blorp.Ast.DFunc f; _ } ] -> (
      match f.Blorp.Ast.func_body with
      | Blorp.Ast.FuncBuiltinBody (Blorp.Ast.BuiltinIntrinsic, _) -> ()
      | _ -> Alcotest.fail "expected explicit builtin sentinel body")
  | _ -> Alcotest.fail "expected one function declaration"

let test_old_builtin_spelling_is_plain_identifier () =
  let old_name = "ir_" ^ "builtin" in
  let source = "func " ^ old_name ^ "(x: Int) -> Int:\n" ^ "\tx\n" in
  let program = parse_ok source in
  match program with
  | [ { Blorp.Ast.decl_desc = Blorp.Ast.DFunc f; _ } ] -> (
      match f.Blorp.Ast.func_name with
      | Some name -> check_string "function name" old_name name
      | None -> Alcotest.fail "expected named function")
  | _ -> Alcotest.fail "expected one function declaration"

let test_leading_dot_chain_continuation () =
  let source =
    "func main(args: List[String]):\n"
    ^ "\tmsg = [\"Hello\", \",\", \"cruel\", \"world\"]\n"
    ^ "\t\t.map(func(x): x.upper())\n" ^ "\t\t.reverse()\n"
    ^ "\t\t.join(\" \")\n" ^ "\tprint(msg)\n"
  in
  ignore (parse_ok source)

let test_formatter_preserves_match_call_arg_parseability () =
  let source =
    "func id_char(c: Char) -> Char:\n" ^ "\tc\n\n\n"
    ^ "func match_as_call_arg(n: Int) -> Char:\n" ^ "\tid_char(\n"
    ^ "\t\tmatch n:\n" ^ "\t\t\t0: '8'\n" ^ "\t\t\t1: '9'\n" ^ "\t\t\t2: 'a'\n"
    ^ "\t\t\t_: 'b'\n" ^ "\t)\n"
  in
  match Blorp.Fmt.format_string source with
  | Error err -> Alcotest.fail err
  | Ok formatted -> ignore (parse_ok formatted)

let format_ok source =
  match Blorp.Fmt.format_string source with
  | Error err -> Alcotest.fail err
  | Ok formatted -> formatted

let test_formatter_inserts_blank_before_block_comments () =
  let source =
    "func main(args: List[String]) -> Int:\n" ^ "\tx: Int = 1\n"
    ^ "\t-- explain x\n" ^ "\tx\n"
  in
  let expected =
    "func main(args: List[String]) -> Int:\n" ^ "\tx: Int = 1\n\n"
    ^ "\t-- explain x\n" ^ "\tx\n"
  in
  check_string "formatted source" expected (format_ok source)

let test_formatter_does_not_insert_blank_before_first_block_comment () =
  let source =
    "func main(args: List[String]) -> Int:\n" ^ "\t-- explain the setup\n"
    ^ "\tx: Int = 1\n" ^ "\twhile x < 3:\n" ^ "\t\t-- explain the loop\n"
    ^ "\t\tx += 1\n" ^ "\tx\n"
  in
  let expected =
    "func main(args: List[String]) -> Int:\n" ^ "\t-- explain the setup\n"
    ^ "\tx: Int = 1\n\n" ^ "\twhile x < 3:\n" ^ "\t\t-- explain the loop\n"
    ^ "\t\tx += 1\n\n" ^ "\tx\n"
  in
  check_string "formatted source" expected (format_ok source)

let test_formatter_preserves_single_block_blank_line () =
  let source =
    "func main(args: List[String]) -> Int:\n" ^ "\ta: Int = 1\n\n"
    ^ "\tb: Int = 2\n\n\n\n" ^ "\ta + b\n"
  in
  let expected =
    "func main(args: List[String]) -> Int:\n" ^ "\ta: Int = 1\n\n"
    ^ "\tb: Int = 2\n\n" ^ "\ta + b\n"
  in
  check_string "formatted source" expected (format_ok source)

let test_formatter_keeps_consecutive_block_comments_together () =
  let source =
    "func f() -> Int:\n" ^ "\tx: Int = 1\n" ^ "\t-- first note\n"
    ^ "\t-- second note\n" ^ "\tx\n"
  in
  let expected =
    "func f() -> Int:\n" ^ "\tx: Int = 1\n\n" ^ "\t-- first note\n"
    ^ "\t-- second note\n" ^ "\tx\n"
  in
  check_string "formatted source" expected (format_ok source)

let test_formatter_preserves_nested_function_declarations () =
  let source =
    "func main(args: List[String]) -> Int:\n"
    ^ "\tpure func helper[T](x: Int) -> Int:\n" ^ "\t\tx + 1\n"
    ^ "\thelper(1)\n"
  in
  let expected =
    "func main(args: List[String]) -> Int:\n"
    ^ "\tpure func helper[T](x: Int) -> Int:\n" ^ "\t\tx + 1\n"
    ^ "\thelper(1)\n"
  in
  check_string "formatted source" expected (format_ok source)

let test_foreign_function_forms_preserve_flags () =
  let source =
    "foreign(include: \"math.h\", link_macos: \"-lm\"):\n"
    ^ "\tpure func c_cos(x: Float) -> Float = \"cos\"\n"
    ^ "\t@no_copy func fill(buf: Bytes) -> Void = \"fill\"\n"
    ^ "\tprivate pure func c_abs(x: Int) -> Int = \"abs\"\n" ^ "foreign:\n"
    ^ "\tfunc puts(s: String) -> Int = \"puts\"\n"
  in
  let program = parse_ok source in
  check_int "declaration count" 4 (List.length program);
  match program with
  | [
   { Blorp.Ast.decl_desc = Blorp.Ast.DFunc c_cos; _ };
   { Blorp.Ast.decl_desc = Blorp.Ast.DFunc fill; _ };
   {
     Blorp.Ast.decl_desc =
       Blorp.Ast.DPrivate { decl_desc = Blorp.Ast.DFunc c_abs; _ };
     _;
   };
   { Blorp.Ast.decl_desc = Blorp.Ast.DFunc puts; _ };
  ] -> (
      check_bool "block pure function" true c_cos.func_is_pure;
      (match c_cos.func_body with
      | Blorp.Ast.FuncForeign
          { foreign_name; foreign_includes; foreign_link_flags } ->
          check_string "block explicit C name" "cos" foreign_name;
          check_int "block include count" 1 (List.length foreign_includes);
          check_int "block link flag count" 1 (List.length foreign_link_flags)
      | _ ->
          Alcotest.fail
            "foreign function should carry explicit foreign implementation");
      check_bool "no_copy annotation" true fill.func_no_copy;
      (match fill.func_body with
      | Blorp.Ast.FuncForeign { foreign_name; _ } ->
          check_string "no_copy explicit C name" "fill" foreign_name
      | _ -> Alcotest.fail "expected foreign function implementation");
      check_bool "private foreign pure" true c_abs.func_is_pure;
      (match c_abs.func_body with
      | Blorp.Ast.FuncForeign
          { foreign_name; foreign_includes; foreign_link_flags } ->
          check_string "private explicit C name" "abs" foreign_name;
          check_int "private include count" 1 (List.length foreign_includes);
          check_int "private link flag count" 1 (List.length foreign_link_flags)
      | _ -> Alcotest.fail "expected foreign function implementation");
      check_bool "single foreign is impure" false puts.func_is_pure;
      match puts.func_body with
      | Blorp.Ast.FuncForeign { foreign_name; _ } ->
          check_string "single explicit C name" "puts" foreign_name
      | _ -> Alcotest.fail "expected foreign function implementation")
  | _ -> Alcotest.fail "expected foreign declarations in source order"

let test_with_multistatement_body_keeps_body_location () =
  let source =
    "func main(args: List[String]) -> Int:\n" ^ "\twith handle = acquire():\n"
    ^ "\t\tuse(handle)\n" ^ "\t\thandle\n"
  in
  let program = parse_ok source in
  match program with
  | [ { Blorp.Ast.decl_desc = Blorp.Ast.DFunc f; _ } ] -> (
      match f.Blorp.Ast.func_body with
      | Blorp.Ast.FuncBodyExpr
          {
            expr_desc =
              Blorp.Ast.EBlock
                [
                  {
                    expr_desc =
                      Blorp.Ast.EWith
                        ( binding,
                          {
                            expr_desc = Blorp.Ast.EBlock _;
                            expr_loc = body_loc;
                            _;
                          } );
                    _;
                  };
                ];
            _;
          } ->
          check_int "acquisition line" 2 binding.with_value.expr_loc.line;
          check_int "body line" 3 body_loc.line
      | _ -> Alcotest.fail "expected with expression body")
  | _ -> Alcotest.fail "expected one function declaration"

let suite =
  [
    ( "program",
      [
        Alcotest.test_case "empty and blank programs" `Quick
          test_empty_programs_parse_to_no_decls;
      ] );
    ( "imports",
      [
        Alcotest.test_case "comment-only lines inside import block" `Quick
          test_import_block_accepts_comment_only_lines;
      ] );
    ( "builtins",
      [
        Alcotest.test_case "builtin direct runtime body" `Quick
          test_builtin_direct_runtime_body;
        Alcotest.test_case "builtin std identity body" `Quick
          test_builtin_std_identity_body;
        Alcotest.test_case "builtin std identity requires function name" `Quick
          test_builtin_std_identity_rejects_missing_function_name;
        Alcotest.test_case "builtin sentinel body has explicit kind" `Quick
          test_builtin_sentinel_body_has_explicit_kind;
        Alcotest.test_case "old builtin spelling is plain identifier" `Quick
          test_old_builtin_spelling_is_plain_identifier;
      ] );
    ( "continuation",
      [
        Alcotest.test_case "leading-dot method chains continue expression"
          `Quick test_leading_dot_chain_continuation;
      ] );
    ( "formatter",
      [
        Alcotest.test_case "match call arg output remains parseable" `Quick
          test_formatter_preserves_match_call_arg_parseability;
        Alcotest.test_case "blank line before block comments" `Quick
          test_formatter_inserts_blank_before_block_comments;
        Alcotest.test_case "no blank before first block comment" `Quick
          test_formatter_does_not_insert_blank_before_first_block_comment;
        Alcotest.test_case "preserve one block blank line" `Quick
          test_formatter_preserves_single_block_blank_line;
        Alcotest.test_case "consecutive block comments stay grouped" `Quick
          test_formatter_keeps_consecutive_block_comments_together;
        Alcotest.test_case "nested function declarations stay nested" `Quick
          test_formatter_preserves_nested_function_declarations;
      ] );
    ( "foreign",
      [
        Alcotest.test_case "foreign function forms preserve flags" `Quick
          test_foreign_function_forms_preserve_flags;
      ] );
    ( "with",
      [
        Alcotest.test_case "multi-statement body keeps body location" `Quick
          test_with_multistatement_body_keeps_body_location;
      ] );
  ]
