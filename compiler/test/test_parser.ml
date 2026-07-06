(** OCaml wrapper tests for parser bridge phase routing.

    Parser behavior itself lives in [compiler/blorp/tests/test_compiler_parser.brp]
    and [tests/test_compiler/parser]. Keep this file limited to checks that the
    OCaml entry points still select the right Blorp frontend phase. *)

let check_bool msg = Alcotest.(check bool) msg

let parse_ok source =
  match Blorp.Modules.parse_source source with
  | Ok program -> program
  | Error err -> Alcotest.fail err.message

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

let suite =
  [
    ( "phase-routing",
      [
        Alcotest.test_case "raw and typecheck source phases are distinct" `Quick
          test_raw_and_typecheck_source_phases_are_distinct;
      ] );
  ]
