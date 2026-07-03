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

let parse_typecheck_ok source =
  match Blorp.Modules.parse_typecheck_source source with
  | Ok program -> program
  | Error err -> Alcotest.fail err.message

let rec expr_exists pred expr =
  pred expr || List.exists (expr_exists pred) (Blorp.Ast.expr_children expr)

let func_exists_expr pred func =
  match Blorp.Ast.func_body_expr_opt func.Blorp.Ast.func_body with
  | Some body -> expr_exists pred body
  | None -> false

let rec decl_exists_expr pred decl =
  match decl.Blorp.Ast.decl_desc with
  | Blorp.Ast.DFunc func -> func_exists_expr pred func
  | Blorp.Ast.DVar var -> expr_exists pred var.Blorp.Ast.var_value
  | Blorp.Ast.DPrivate inner -> decl_exists_expr pred inner
  | Blorp.Ast.DImpl impl -> List.exists (func_exists_expr pred) impl.impl_methods
  | Blorp.Ast.DTrait trait_decl ->
      List.exists
        (fun method_decl ->
          match method_decl.Blorp.Ast.method_default_body with
          | Some body -> expr_exists pred body
          | None -> false)
        trait_decl.trait_methods
  | Blorp.Ast.DType _ | Blorp.Ast.DRecord _ | Blorp.Ast.DImport _
  | Blorp.Ast.DTypeAlias _ ->
      false

let program_exists_expr pred program = List.exists (decl_exists_expr pred) program

let is_raw_interpolation expr =
  match expr.Blorp.Ast.expr_desc with
  | Blorp.Ast.EStringInterpRaw _ -> true
  | _ -> false

let is_final_interpolation expr =
  match expr.Blorp.Ast.expr_desc with
  | Blorp.Ast.EStringInterp _ -> true
  | _ -> false

let is_nested_function_expr expr =
  match expr.Blorp.Ast.expr_desc with
  | Blorp.Ast.EFuncDecl _ -> true
  | _ -> false

let is_subscript_read expr =
  match expr.Blorp.Ast.expr_desc with
  | Blorp.Ast.ESubscript _ | Blorp.Ast.ESubscriptMulti _ -> true
  | _ -> false

let is_checked_get_call expr =
  match expr.Blorp.Ast.expr_desc with
  | Blorp.Ast.ECall ({ expr_desc = Blorp.Ast.EIdent "checked_get"; _ }, _) ->
      true
  | _ -> false

let test_raw_and_typecheck_source_phases_are_distinct () =
  let source =
    "message = \"hello ${name}\"\n\n\
     func outer(x: Int) -> Int:\n\
    \    func inner(y: Int) -> Int:\n\
    \        y + 1\n\
    \    inner(x)\n\n\
     func item(v: Int[#3]) -> Int:\n\
    \    v[0]\n"
  in
  let raw_program = parse_ok source in
  let typecheck_program = parse_typecheck_ok source in
  check_bool "raw keeps raw interpolation" true
    (program_exists_expr is_raw_interpolation raw_program);
  check_bool "raw keeps nested function expression" true
    (program_exists_expr is_nested_function_expr raw_program);
  check_bool "raw keeps subscript read" true
    (program_exists_expr is_subscript_read raw_program);
  check_bool "typecheck finalizes interpolation" true
    (program_exists_expr is_final_interpolation typecheck_program);
  check_bool "typecheck hoists nested function expressions" false
    (program_exists_expr is_nested_function_expr typecheck_program);
  check_bool "typecheck rewrites subscript read" false
    (program_exists_expr is_subscript_read typecheck_program);
  check_bool "typecheck emits checked_get call" true
    (program_exists_expr is_checked_get_call typecheck_program)

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
    "private pure func __unsafe_list_set_index[T](self: List[T], index: Int, elem: T) -> List[T]:\n"
    ^ "\tbuiltin(\"std/list.__unsafe_list_set_index\")\n"
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
              check_string "std builtin function" "__unsafe_list_set_index"
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

let test_multiline_var_initializer_after_equals () =
  let source =
    "private X: Int = 1\n" ^ "Y: Int =\n" ^ "\tX + 1\n\n\n"
    ^ "func main(args: List[String]) -> Int:\n" ^ "\tY\n"
  in
  ignore (parse_ok source)

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
        Alcotest.test_case "raw and typecheck source phases are distinct" `Quick
          test_raw_and_typecheck_source_phases_are_distinct;
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
        Alcotest.test_case "multiline var initializer after equals" `Quick
          test_multiline_var_initializer_after_equals;
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
