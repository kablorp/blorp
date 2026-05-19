(** Unit tests for expression-leaf formatting.

    These mirror [tests/test_blorp/tools/test_expression_documents.brp] so the OCaml
    formatter printer and the Blorp expression-doc printer stay pinned to the
    same visible syntax while expression formatting is ported in slices. *)

module Ast = Blorp.Ast
module Comment = Blorp.Fmt_comment
module ExprJson = Blorp.Fmt_expr_json
module Fmt = Blorp.Fmt
module Layout = Blorp.Fmt_layout
module Printer = Blorp.Fmt_printer

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
let call name args = expr (Ast.ECall (ident name, args))

let typed_param name ty =
  {
    Ast.param_name = Some name;
    param_pattern = None;
    param_type = Some ty;
    param_loc = Ast.dummy_loc;
  }

let match_case pattern body =
  { Ast.case_pattern = pattern; case_body = body; case_loc = Ast.dummy_loc }

let func ?name ?(type_params = []) ?return_type ?(is_pure = false) params body =
  {
    Ast.func_name = name;
    func_type_params = type_params;
    func_params = params;
    func_return_type = return_type;
    func_body = Ast.FuncBodyExpr body;
    func_is_pure = is_pure;
    func_is_tailrec = false;
    func_no_copy = false;
    func_debug_only = false;
    func_dim_constraints = [];
  }

let layout_expr e =
  Printer.comments := Comment.create [];
  Layout.layout (Printer.print_expr e)

let layout_expr_width width e =
  Printer.comments := Comment.create [];
  Layout.layout ~width (Printer.print_expr e)

let string_flags = { Ast.sf_raw = false; sf_triple = false }

let test_string_literal_escaping () =
  let e = expr (Ast.ELiteral (Ast.LitString ("line\n\"q\"\\", string_flags))) in
  check_string "string literal escaping" "\"line\\n\\\"q\\\"\\\\\"\n"
    (layout_expr e)

let test_char_literal_escaping () =
  let e = expr (Ast.ELiteral (Ast.LitChar 10)) in
  check_string "char literal escaping" "'\\n'\n" (layout_expr e)

let test_simple_call_and_field_access () =
  let e =
    expr
      (Ast.ECall
         ( ident "add",
           [ int_lit 1; expr (Ast.EFieldAccess (ident "value", "name")) ] ))
  in
  check_string "simple call and field access" "add(1, value.name)\n"
    (layout_expr e)

let test_binary_precedence_parentheses () =
  let e =
    expr
      (Ast.EBinary
         (Ast.Mul, expr (Ast.EBinary (Ast.Add, int_lit 1, int_lit 2)), int_lit 3))
  in
  check_string "binary precedence parentheses" "(1 + 2) * 3\n" (layout_expr e)

let test_binary_precedence_flat () =
  let e =
    expr
      (Ast.EBinary
         (Ast.Add, int_lit 1, expr (Ast.EBinary (Ast.Mul, int_lit 2, int_lit 3))))
  in
  check_string "binary precedence flat" "1 + 2 * 3\n" (layout_expr e)

let test_unary_negation_parentheses () =
  let e = expr (Ast.EUnary (Ast.Neg, expr (Ast.EUnary (Ast.Neg, ident "x")))) in
  check_string "unary negation parentheses" "-(-x)\n" (layout_expr e)

let test_builtin_runtime_call () =
  let e =
    expr
      (Ast.ECall (expr (Ast.EBuiltin (Some "blorp_read_file")), [ ident "path" ]))
  in
  check_string "builtin runtime call" "builtin(\"blorp_read_file\")(path)\n"
    (layout_expr e)

let test_tuple_expr_doc () =
  let e =
    expr
      (Ast.ETuple
         [ int_lit 1; expr (Ast.ELiteral (Ast.LitString ("a", string_flags))) ])
  in
  check_string "tuple expression doc" "(1, \"a\")\n" (layout_expr e)

let test_list_expr_doc () =
  let e = expr (Ast.EList [ ident "alpha"; ident "beta" ]) in
  check_string "list flat" "[alpha, beta]\n" (layout_expr e);
  check_string "list broken" "[\n\talpha,\n\tbeta,\n]\n" (layout_expr_width 8 e)

let test_vector_expr_doc () =
  let e = expr (Ast.EVector [ int_lit 1; int_lit 2 ]) in
  check_string "vector expression doc" "{1, 2}\n" (layout_expr e)

let test_record_expr_doc () =
  let e =
    expr
      (Ast.ERecord
         [
           ("x", int_lit 1);
           ("y", expr (Ast.EFieldAccess (ident "value", "name")));
         ])
  in
  check_string "record expression doc" "{x = 1, y = value.name}\n"
    (layout_expr e)

let test_record_update_expr_doc () =
  let e =
    expr
      (Ast.ERecordUpdate
         (ident "point", [ ("x", int_lit 10); ("y", int_lit 20) ]))
  in
  check_string "record update expression doc" "{ point | x = 10, y = 20 }\n"
    (layout_expr e)

let test_ascription_expr_doc () =
  let e =
    expr
      (Ast.EAscription (ident "value", ty_named "List" [ ty_named "Int" [] ]))
  in
  check_string "ascription expression doc" "value as List[Int]\n"
    (layout_expr e)

let test_range_expr_doc () =
  let e = expr (Ast.ERange (int_lit 0, int_lit 10)) in
  check_string "range expression doc" "0..10\n" (layout_expr e)

let test_subscript_expr_doc () =
  let e = expr (Ast.ESubscript (ident "items", int_lit 0)) in
  check_string "subscript expression doc" "items[0]\n" (layout_expr e)

let test_subscript_multi_expr_doc () =
  let e =
    expr (Ast.ESubscriptMulti (ident "matrix", [ ident "i"; ident "j" ]))
  in
  check_string "subscript multi expression doc" "matrix[i, j]\n" (layout_expr e)

let test_dict_expr_doc () =
  let e =
    expr
      (Ast.EDict
         [
           (expr (Ast.ELiteral (Ast.LitString ("a", string_flags))), int_lit 1);
           ( expr (Ast.ELiteral (Ast.LitString ("b", string_flags))),
             expr (Ast.EFieldAccess (ident "value", "name")) );
         ])
  in
  check_string "dict expression doc" "{\"a\" => 1, \"b\" => value.name}\n"
    (layout_expr e)

let test_field_range_receiver_parenthesized () =
  let e =
    expr
      (Ast.EFieldAccess (expr (Ast.ERange (int_lit 0, int_lit 10)), "length"))
  in
  check_string "field range receiver parenthesized" "(0..10).length\n"
    (layout_expr e)

let test_assign_expr_doc () =
  let e =
    expr
      (Ast.EAssign
         ("total", expr (Ast.EBinary (Ast.Add, ident "total", int_lit 5))))
  in
  check_string "assign expression doc" "total += 5\n" (layout_expr e)

let test_var_decl_expr_doc () =
  let e =
    expr (Ast.EVarDecl ("count", Some (ty_named "Int" []), int_lit 0, true))
  in
  check_string "var declaration expression doc" "var count: Int = 0\n"
    (layout_expr e)

let test_tuple_destruct_expr_doc () =
  let e = expr (Ast.ETupleDestruct ([ "a"; "b" ], ident "pair")) in
  check_string "tuple destructure expression doc" "(a, b) = pair\n"
    (layout_expr e)

let test_subscript_assign_expr_doc () =
  let e =
    expr
      (Ast.ESubscriptAssign
         (ident "matrix", [ ident "i"; ident "j" ], ident "value"))
  in
  check_string "subscript assignment expression doc" "matrix[i, j] = value\n"
    (layout_expr e)

let test_question_bind_expr_doc () =
  let e =
    expr
      (Ast.EQuestionBind ("item", Some (ty_named "Int" []), ident "maybe_item"))
  in
  check_string "question bind expression doc" "item: Int ?= maybe_item\n"
    (layout_expr e)

let test_block_expr_doc () =
  let e =
    expr (Ast.EBlock [ expr (Ast.EAssign ("total", int_lit 1)); ident "total" ])
  in
  check_string "block expression doc" "total = 1\ntotal\n" (layout_expr e)

let test_if_expr_doc () =
  let e =
    expr (Ast.EIf (ident "flag", ident "value", Some (ident "fallback")))
  in
  check_string "if expression doc" "if flag:\n\tvalue\nelse:\n\tfallback\n"
    (layout_expr e)

let test_while_expr_doc () =
  let e =
    expr
      (Ast.EWhile
         ( ident "keep_going",
           expr
             (Ast.EAssign
                ("total", expr (Ast.EBinary (Ast.Add, ident "total", int_lit 1))))
         ))
  in
  check_string "while expression doc" "while keep_going:\n\ttotal += 1\n"
    (layout_expr e)

let test_for_expr_doc () =
  let e =
    expr
      (Ast.EFor
         ( "item",
           ident "items",
           expr
             (Ast.EAssign
                ( "total",
                  expr (Ast.EBinary (Ast.Add, ident "total", ident "item")) ))
         ))
  in
  check_string "for expression doc" "for item in items:\n\ttotal += item\n"
    (layout_expr e)

let test_for_tuple_expr_doc () =
  let e =
    expr
      (Ast.EForTuple
         ( [ "key"; "value" ],
           ident "entries",
           expr
             (Ast.EAssign
                ( "total",
                  expr (Ast.EBinary (Ast.Add, ident "total", ident "value")) ))
         ))
  in
  check_string "for tuple expression doc"
    "for (key, value) in entries:\n\ttotal += value\n" (layout_expr e)

let test_match_expr_doc () =
  let e =
    expr
      (Ast.EMatch
         ( ident "value",
           [
             match_case
               (Ast.PatConstructor ("Some", [ Ast.PatVar "x" ]))
               (ident "x");
             match_case (Ast.PatVar "None") (int_lit 0);
           ] ))
  in
  check_string "match expression doc" "match value:\n\tSome(x): x\n\tNone: 0\n"
    (layout_expr e)

let test_lambda_expr_doc () =
  let body = expr (Ast.EBinary (Ast.Add, ident "x", int_lit 1)) in
  let e =
    expr
      (Ast.ELambda
         (func ~return_type:(ty_named "Int" [])
            [ typed_param "x" (ty_named "Int" []) ]
            body))
  in
  check_string "lambda expression doc" "func(x: Int) -> Int: x + 1\n"
    (layout_expr e)

let test_block_lambda_expr_doc () =
  let body =
    expr (Ast.EBlock [ expr (Ast.EBinary (Ast.Add, ident "x", int_lit 1)) ])
  in
  let e =
    expr
      (Ast.ELambda
         (func ~is_pure:true [ typed_param "x" (ty_named "Int" []) ] body))
  in
  check_string "block lambda expression doc" "pure func(x: Int):\n\tx + 1\n"
    (layout_expr e)

let test_func_decl_expr_doc () =
  let body = expr (Ast.EBinary (Ast.Add, ident "x", int_lit 1)) in
  let e =
    expr
      (Ast.EFuncDecl
         (func ~name:"helper"
            ~type_params:[ Ast.make_type_param "T" [] ]
            ~return_type:(ty_named "Int" []) ~is_pure:true
            [ typed_param "x" (ty_named "Int" []) ]
            body))
  in
  check_string "function declaration expression doc"
    "pure func helper[T](x: Int) -> Int:\n\tx + 1\n" (layout_expr e)

let test_string_interp_expr_doc () =
  let e =
    expr
      (Ast.EStringInterp
         ( [
             Ast.InterpLit "Hello ";
             Ast.InterpExpr (ident "name");
             Ast.InterpLit "!";
           ],
           false ))
  in
  check_string "string interpolation expression doc" "\"Hello ${name}!\"\n"
    (layout_expr e)

let test_triple_string_interp_expr_doc () =
  let e =
    expr
      (Ast.EStringInterp
         ( [
             Ast.InterpLit "line ";
             Ast.InterpExpr (ident "name");
             Ast.InterpLit "\nnext";
           ],
           true ))
  in
  check_string "triple string interpolation expression doc"
    "\"\"\"line ${name}\nnext\"\"\"\n" (layout_expr e)

let test_debug_block_expr_doc () =
  let e = expr (Ast.EDebugBlock [ expr (Ast.EAssign ("total", int_lit 1)) ]) in
  check_string "debug block expression doc" "debug:\n\ttotal = 1\n"
    (layout_expr e)

let test_concurrent_expr_doc () =
  let binding = expr (Ast.EConcurrentBind ("a", None, call "compute" [])) in
  let e = expr (Ast.EConcurrent ([ binding ], Some (int_lit 5), Some 2)) in
  check_string "concurrent expression doc"
    "concurrent(max_threads: 2, timeout: 5):\n\ta = compute()\n" (layout_expr e)

let test_detach_expr_doc () =
  let e = expr (Ast.EDetach (call "send" [ ident "ch"; int_lit 1 ])) in
  check_string "detach expression doc" "detach send(ch, 1)\n" (layout_expr e)

let test_concurrent_for_expr_doc () =
  let body =
    expr
      (Ast.EAssign
         ("total", expr (Ast.EBinary (Ast.Add, ident "total", ident "item"))))
  in
  let e =
    expr (Ast.EConcurrentFor ("item", ident "items", body, None, Some 2))
  in
  check_string "concurrent for expression doc"
    "concurrent(max_threads: 2) for item in items:\n\ttotal += item\n"
    (layout_expr e)

let test_expr_json_case_uses_ocaml_expected_layout () =
  let e =
    expr
      (Ast.ECall
         ( expr (Ast.EFieldAccess (ident "items", "get")),
           [ expr (Ast.EBinary (Ast.Add, int_lit 1, int_lit 2)) ] ))
  in
  match ExprJson.expr_to_json e with
  | None -> Alcotest.fail "expected expression to be serializable"
  | Some expr_json ->
      let case_json = ExprJson.case_json e expr_json in
      check_string "case includes expected layout"
        {|{"line":0,"column":0,"expected":"items.get(1 + 2)\n","expr":|}
        (String.sub case_json 0
           (String.length
              {|{"line":0,"column":0,"expected":"items.get(1 + 2)\n","expr":|}))

let test_expr_json_lines_from_source () =
  let source =
    "func main(args: List[String]) -> Int:\n\
    \    value = add(1 + 2 * 3, items[0])\n\
    \    typed = value as Int\n\
    \    var count: Int = 0\n\
    \    count += 1\n\
    \    if flag:\n\
    \        value\n\
    \    else:\n\
    \        fallback\n\
    \    while keep_going:\n\
    \        count += 1\n\
    \    for item in items:\n\
    \        count += item\n\
    \    match value:\n\
    \        Some(x): x\n\
    \        None: 0\n\
    \    f = func(x: Int) -> Int: x + 1\n\
    \    pure func helper[T](x: Int) -> Int:\n\
    \        x + 1\n\
    \    message = \"value=${value}\"\n\
    \    debug:\n\
    \        count += 1\n\
    \    concurrent(max_threads: 2, timeout: 5):\n\
    \        task = compute()\n\
    \    detach send(ch, 1)\n\
    \    results = concurrent(max_threads: 2) for item in items:\n\
    \        item\n\
    \    value\n"
  in
  match Fmt.format_expr_cases_json_lines_string source with
  | Error msg -> Alcotest.fail msg
  | Ok jsonl ->
      Alcotest.(check bool)
        "emits expression cases" true
        (String.contains jsonl '\n');
      Alcotest.(check bool)
        "includes OCaml expected layout" true
        (string_contains jsonl
           {|{"tag":"Call","callee":{"tag":"Ident","name":"add"}|});
      Alcotest.(check bool)
        "includes ascription case" true
        (string_contains jsonl
           {|{"tag":"Ascription","expr":{"tag":"Ident","name":"value"}|});
      Alcotest.(check bool)
        "includes var declaration case" true
        (string_contains jsonl
           {|{"tag":"VarDecl","name":"count","mutable":true|});
      Alcotest.(check bool)
        "includes assignment case" true
        (string_contains jsonl
           {|{"tag":"Assign","name":"count","value":{"tag":"Binary"|});
      Alcotest.(check bool)
        "includes if case" true
        (string_contains jsonl
           {|{"tag":"If","cond":{"tag":"Ident","name":"flag"}|});
      Alcotest.(check bool)
        "includes match case" true
        (string_contains jsonl
           {|{"tag":"Match","scrutinee":{"tag":"Ident","name":"value"}|});
      Alcotest.(check bool)
        "includes lambda case" true
        (string_contains jsonl {|{"tag":"Lambda","pure":false|});
      Alcotest.(check bool)
        "includes function declaration case" true
        (string_contains jsonl {|{"tag":"FuncDecl","name":"helper","pure":true|});
      Alcotest.(check bool)
        "includes string interpolation case" true
        (string_contains jsonl {|{"tag":"StringInterp","triple":false|});
      Alcotest.(check bool)
        "includes debug block case" true
        (string_contains jsonl {|{"tag":"DebugBlock","exprs":[|});
      Alcotest.(check bool)
        "includes concurrent case" true
        (string_contains jsonl {|{"tag":"Concurrent","bindings":[|});
      Alcotest.(check bool)
        "includes detach case" true
        (string_contains jsonl {|{"tag":"Detach","body":|});
      Alcotest.(check bool)
        "includes concurrent for case" true
        (string_contains jsonl {|{"tag":"ConcurrentFor","var":"item"|})

let suite =
  [
    ( "expr_doc",
      [
        Alcotest.test_case "string literal escaping" `Quick
          test_string_literal_escaping;
        Alcotest.test_case "char literal escaping" `Quick
          test_char_literal_escaping;
        Alcotest.test_case "simple call and field access" `Quick
          test_simple_call_and_field_access;
        Alcotest.test_case "binary precedence parentheses" `Quick
          test_binary_precedence_parentheses;
        Alcotest.test_case "binary precedence flat" `Quick
          test_binary_precedence_flat;
        Alcotest.test_case "unary negation parentheses" `Quick
          test_unary_negation_parentheses;
        Alcotest.test_case "builtin runtime call" `Quick
          test_builtin_runtime_call;
        Alcotest.test_case "tuple expression doc" `Quick test_tuple_expr_doc;
        Alcotest.test_case "list expression doc" `Quick test_list_expr_doc;
        Alcotest.test_case "vector expression doc" `Quick test_vector_expr_doc;
        Alcotest.test_case "record expression doc" `Quick test_record_expr_doc;
        Alcotest.test_case "record update expression doc" `Quick
          test_record_update_expr_doc;
        Alcotest.test_case "ascription expression doc" `Quick
          test_ascription_expr_doc;
        Alcotest.test_case "range expression doc" `Quick test_range_expr_doc;
        Alcotest.test_case "subscript expression doc" `Quick
          test_subscript_expr_doc;
        Alcotest.test_case "subscript multi expression doc" `Quick
          test_subscript_multi_expr_doc;
        Alcotest.test_case "dict expression doc" `Quick test_dict_expr_doc;
        Alcotest.test_case "field range receiver parenthesized" `Quick
          test_field_range_receiver_parenthesized;
        Alcotest.test_case "assign expression doc" `Quick test_assign_expr_doc;
        Alcotest.test_case "var declaration expression doc" `Quick
          test_var_decl_expr_doc;
        Alcotest.test_case "tuple destructure expression doc" `Quick
          test_tuple_destruct_expr_doc;
        Alcotest.test_case "subscript assignment expression doc" `Quick
          test_subscript_assign_expr_doc;
        Alcotest.test_case "question bind expression doc" `Quick
          test_question_bind_expr_doc;
        Alcotest.test_case "block expression doc" `Quick test_block_expr_doc;
        Alcotest.test_case "if expression doc" `Quick test_if_expr_doc;
        Alcotest.test_case "while expression doc" `Quick test_while_expr_doc;
        Alcotest.test_case "for expression doc" `Quick test_for_expr_doc;
        Alcotest.test_case "for tuple expression doc" `Quick
          test_for_tuple_expr_doc;
        Alcotest.test_case "match expression doc" `Quick test_match_expr_doc;
        Alcotest.test_case "lambda expression doc" `Quick test_lambda_expr_doc;
        Alcotest.test_case "block lambda expression doc" `Quick
          test_block_lambda_expr_doc;
        Alcotest.test_case "function declaration expression doc" `Quick
          test_func_decl_expr_doc;
        Alcotest.test_case "string interpolation expression doc" `Quick
          test_string_interp_expr_doc;
        Alcotest.test_case "triple string interpolation expression doc" `Quick
          test_triple_string_interp_expr_doc;
        Alcotest.test_case "debug block expression doc" `Quick
          test_debug_block_expr_doc;
        Alcotest.test_case "concurrent expression doc" `Quick
          test_concurrent_expr_doc;
        Alcotest.test_case "detach expression doc" `Quick test_detach_expr_doc;
        Alcotest.test_case "concurrent for expression doc" `Quick
          test_concurrent_for_expr_doc;
        Alcotest.test_case "expression JSON case uses OCaml expected layout"
          `Quick test_expr_json_case_uses_ocaml_expected_layout;
        Alcotest.test_case "expression JSONL emits source cases" `Quick
          test_expr_json_lines_from_source;
      ] );
  ]
