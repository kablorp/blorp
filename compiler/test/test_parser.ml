(** Unit tests for parser edge cases that formatter-driven integration tests
    would normalize before parsing. *)

let check_int msg = Alcotest.(check int) msg
let check_string msg = Alcotest.(check string) msg
let check_bool msg = Alcotest.(check bool) msg

let parse_ok source =
  match Blorp.Modules.parse_source ~hoist_nested:false source with
  | Ok program -> program
  | Error err -> Alcotest.fail err.message

let parse_error_message source =
  match Blorp.Modules.parse_source ~hoist_nested:false source with
  | Ok _ -> Alcotest.fail "expected parse error"
  | Error err -> err.message

let ast_expr expr_desc expr_loc =
  {
    Blorp.Ast.expr_desc;
    expr_loc;
    expr_type = None;
    expr_type_info = None;
    expr_rc = None;
  }

let test_interpolation_transform_uses_supplied_batch_parser () =
  let loc = Blorp.Ast.point_loc ~line:1 ~column:1 in
  let var_decl name raw =
    {
      Blorp.Ast.decl_desc =
        Blorp.Ast.DVar
          {
            var_name = Some name;
            var_pattern = None;
            var_type = None;
            var_value =
              ast_expr (Blorp.Ast.EStringInterpRaw (raw, false)) loc;
            var_is_mutable = false;
            var_is_const = false;
          };
      decl_loc = loc;
      decl_doc = None;
    }
  in
  let decl = var_decl "message" "Hello {name} and {count + 1}" in
  let second_decl = var_decl "other" "Other {later}" in
  let batches = ref [] in
  let parse_batch requests =
    batches := requests :: !batches;
    List.mapi
      (fun index request ->
        ast_expr
          (Blorp.Ast.EIdent (Printf.sprintf "parsed_%d" index))
          request.Blorp.Interp_parser.loc)
      requests
  in
  match
    Blorp.Interp_parser.transform_program_with_expr_batch_parser parse_batch
      [ decl; second_decl ]
  with
  | [
      {
        Blorp.Ast.decl_desc =
          Blorp.Ast.DVar
            {
              var_value =
                {
                  expr_desc =
                    Blorp.Ast.EStringInterp
                      ( [
                          Blorp.Ast.InterpLit "Hello ";
                          Blorp.Ast.InterpExpr
                            { expr_desc = Blorp.Ast.EIdent parsed_first; _ };
                          Blorp.Ast.InterpLit " and ";
                          Blorp.Ast.InterpExpr
                            { expr_desc = Blorp.Ast.EIdent parsed_second; _ };
                        ],
                        false );
                  _;
                };
              _;
            };
        _;
      };
      {
        Blorp.Ast.decl_desc =
          Blorp.Ast.DVar
            {
              var_value =
                {
                  expr_desc =
                    Blorp.Ast.EStringInterp
                      ( [
                          Blorp.Ast.InterpLit "Other ";
                          Blorp.Ast.InterpExpr
                            { expr_desc = Blorp.Ast.EIdent parsed_later; _ };
                        ],
                        false );
                  _;
                };
              _;
            };
        _;
      };
    ] ->
      let requests =
        match !batches with
        | [ requests ] -> requests
        | _ -> Alcotest.fail "expected one interpolation parse batch"
      in
      check_int "batch size" 3 (List.length requests);
      check_string "first parser input" "name"
        (List.nth requests 0).Blorp.Interp_parser.text;
      check_string "second parser input" "count + 1"
        (List.nth requests 1).Blorp.Interp_parser.text;
      check_string "third parser input" "later"
        (List.nth requests 2).Blorp.Interp_parser.text;
      check_string "first parsed expression" "parsed_0" parsed_first;
      check_string "second parsed expression" "parsed_1" parsed_second;
      check_string "third parsed expression" "parsed_2" parsed_later
  | _ -> Alcotest.fail "expected transformed string interpolation"

let interpolation_ident_names expr =
  match expr.Blorp.Ast.expr_desc with
  | Blorp.Ast.EStringInterp (parts, _) ->
      List.filter_map
        (function
          | Blorp.Ast.InterpLit _ -> None
          | Blorp.Ast.InterpExpr { expr_desc = Blorp.Ast.EIdent name; _ } ->
              Some name
          | Blorp.Ast.InterpExpr _ ->
              Alcotest.fail "expected interpolation hole to parse as identifier")
        parts
  | _ -> Alcotest.fail "expected string interpolation expression"

let collect_interpolation_ident_names program =
  let rec collect_expr acc expr =
    match expr.Blorp.Ast.expr_desc with
    | Blorp.Ast.EStringInterp _ -> acc @ [ interpolation_ident_names expr ]
    | _ -> List.fold_left collect_expr acc (Blorp.Ast.expr_children expr)
  in
  let collect_func acc func =
    match Blorp.Ast.func_body_expr_opt func.Blorp.Ast.func_body with
    | Some body -> collect_expr acc body
    | None -> acc
  in
  let collect_decl acc decl =
    match decl.Blorp.Ast.decl_desc with
    | Blorp.Ast.DFunc func -> collect_func acc func
    | _ -> acc
  in
  List.fold_left collect_decl [] program

let test_interpolation_bridge_preserves_hole_order_in_nested_blocks () =
  let source =
    {|
pure func closest_candidate(type_name: String, sorted_candidates: List[String]) -> Option[String]:
	None

pure func render_no_impl_hint(type_name: String, method_name: String, candidates: List[String]) -> String:
	if candidates.length() == 0:
		"no type in scope implements `${method_name}`. Define an `implements <trait> for ${type_name}:` block with a `${method_name}` method."
	else:
		sorted_candidates: List[String] = candidates.sort()

		match closest_candidate(type_name, sorted_candidates):
			Some(suggestion):
				"did you mean to call it on a ${suggestion}? Or add `implements <trait> for ${type_name}:` defining `${method_name}`."
			None:
				candidate_text: String = sorted_candidates.join(", ")
				"types with an `${method_name}` impl in scope: ${candidate_text}. Add `implements <trait> for ${type_name}:` to extend it."
|}
  in
  let program = parse_ok source in
  Alcotest.(check (list (list string)))
    "interpolation hole identifiers"
    [
      [ "method_name"; "type_name"; "method_name" ];
      [ "suggestion"; "type_name"; "method_name" ];
      [ "method_name"; "candidate_text"; "type_name" ];
    ]
    (collect_interpolation_ident_names program)

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
      ] );
    ( "interpolation",
      [
        Alcotest.test_case "transform uses supplied batch parser" `Quick
          test_interpolation_transform_uses_supplied_batch_parser;
        Alcotest.test_case
          "bridge preserves hole order in nested blocks" `Quick
          test_interpolation_bridge_preserves_hole_order_in_nested_blocks;
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
