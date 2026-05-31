(** Unit tests for expression formatter JSON projection.

    Rendered expression output is owned by the Blorp formatter tests in
    [tests/test_blorp/tools/test_expression_documents.brp]. These tests keep
    the OCaml parser/projection boundary honest without invoking the old OCaml
    renderer. *)

module Ast = Blorp.Ast
module ExprJson = Blorp.Fmt_expr_json
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

let test_expr_json_case_is_projection_only () =
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
      check_string "case includes projection only"
        {|{"line":0,"column":0,"expr":|}
        (String.sub case_json 0
           (String.length {|{"line":0,"column":0,"expr":|}))

let test_json_string_escapes_utf8_as_codepoints () =
  let text = "dash \226\128\148 grin \240\159\152\128" in
  check_string "unicode escapes" "\"dash \\u2014 grin \\ud83d\\ude00\""
    (ExprJson.string text)

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
    \    results = for item in items concurrently(limit: 2):\n\
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
        "includes call expression projection" true
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
           {|{"tag":"Assign","name":"count","op":"Add","value":{"tag":"Literal"|});
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
        (string_contains jsonl {|{"tag":"StringInterp","multiline":false|});
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
        "includes for ... concurrently case" true
        (string_contains jsonl {|{"tag":"ConcurrentlyLoop","var":"item"|});
      Alcotest.(check bool)
        "includes for ... concurrently limit" true
        (string_contains jsonl {|"limit":2|})

let suite =
  [
    ( "expr_json",
      [
        Alcotest.test_case "expression JSON case is projection only" `Quick
          test_expr_json_case_is_projection_only;
        Alcotest.test_case "JSON string escapes UTF-8 as codepoints" `Quick
          test_json_string_escapes_utf8_as_codepoints;
        Alcotest.test_case "expression JSONL emits source cases" `Quick
          test_expr_json_lines_from_source;
      ] );
  ]
