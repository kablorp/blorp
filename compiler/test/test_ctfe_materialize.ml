(** Unit tests for CTFE value materialization boundaries. *)

module A = Blorp.Ast
module M = Blorp.Ctfe_materialize
module V = Blorp.Ctfe_value

let check_bool label expected actual =
  Alcotest.(check bool) label expected actual

let check_int label expected actual = Alcotest.(check int) label expected actual

let check_string label expected actual =
  Alcotest.(check string) label expected actual

let ty_int = A.TyNamed ("Int", [])
let ty_option_int = A.TyNamed ("Option", [ ty_int ])
let loc = A.dummy_loc

let typed_expr ty desc =
  A.with_expr_type_info
    {
      A.expr_desc = desc;
      expr_loc = loc;
      expr_type = None;
      expr_type_info = None;
      expr_rc = None;
    }
    (A.expr_type_info_from_type ty)

let int_value value = { V.ty = ty_int; desc = V.VInt (Int64.of_int value); loc }

let typed_global_constant name ty init =
  let ast_var =
    {
      A.var_name = Some name;
      var_pattern = None;
      var_type = Some ty;
      var_value = init;
      var_is_mutable = false;
      var_is_const = true;
    }
  in
  let ast_decl =
    { A.decl_desc = A.DVar ast_var; decl_loc = loc; decl_doc = None }
  in
  match Blorp.Typed_ast.of_ast_decl ast_decl with
  | Ok typed_decl -> (
      match Blorp.Typed_ast.decl_view typed_decl with
      | Blorp.Typed_ast.DeclVar var -> var
      | _ -> Alcotest.fail "expected typed global constant")
  | Error _ -> Alcotest.fail "expected finalized global constant"

let constructor_info ?(arity = 1) ?(callable_id = Some 42) parent_type =
  {
    V.constructor_parent_type = parent_type;
    constructor_arity = arity;
    constructor_callable_id = callable_id;
  }

let option_some_resolved_call =
  {
    A.call_syntax = A.CallBare;
    call_target =
      A.CallDirect
        {
          callable_id = 42;
          source_name = "Some";
          call_pure = true;
          origin = A.CallableConstructor "Option";
        };
    instantiated_params = [ ty_int ];
    instantiated_return = ty_option_int;
  }

let option_some_callee =
  typed_expr
    (A.TyFunc { params = [ ty_int ]; return = ty_option_int; is_pure = true })
    (A.EIdent "Some")

let require_materialized value =
  match M.value_to_expr value with
  | Ok expr -> expr
  | Error errors ->
      Alcotest.failf "expected value to materialize, got %d error(s)"
        (List.length errors)

let require_direct_constructor_call expr =
  match expr.A.expr_desc with
  | A.ECall (callee, args) -> (callee, args)
  | _ -> Alcotest.fail "expected materialized constructor call"

let require_identifier expr =
  match expr.A.expr_desc with
  | A.EIdent name -> name
  | _ -> Alcotest.fail "expected materialized identifier"

let require_global_var_decl ?private_ ?doc typed_var value =
  match M.global_var_decl ?private_ ?doc ~loc typed_var value with
  | Ok decl -> decl
  | Error errors ->
      Alcotest.failf "expected global to materialize, got %d error(s)"
        (List.length errors)

let require_var_decl decl =
  match Blorp.Typed_ast.decl_view decl with
  | Blorp.Typed_ast.DeclVar var -> var
  | _ -> Alcotest.fail "expected materialized var declaration"

let require_private_var_decl decl =
  match Blorp.Typed_ast.decl_view decl with
  | Blorp.Typed_ast.DeclPrivate inner -> require_var_decl inner
  | _ -> Alcotest.fail "expected materialized private var declaration"

let test_source_constructor_preserves_callee_and_resolved_call () =
  let value =
    {
      V.ty = ty_option_int;
      desc =
        V.VConstructor
          {
            name = "Some";
            args = [ int_value 7 ];
            constructor_info = constructor_info "Option";
            constructor_origin =
              V.ConstructorSourceCall
                {
                  callee = option_some_callee;
                  resolved_call = Some option_some_resolved_call;
                };
          };
      loc;
    }
  in
  let expr = require_materialized value in
  let callee, args = require_direct_constructor_call expr in
  check_bool "source callee preserved" true (callee = option_some_callee);
  check_bool "source resolved call preserved" true
    (A.expr_resolved_call expr = Some option_some_resolved_call);
  check_int "argument count" 1 (List.length args)

let test_synthesized_payload_constructor_builds_typed_call () =
  let value =
    {
      V.ty = ty_option_int;
      desc =
        V.VConstructor
          {
            name = "Some";
            args = [ int_value 7 ];
            constructor_info = constructor_info "Option";
            constructor_origin = V.ConstructorSynthesized;
          };
      loc;
    }
  in
  let expr = require_materialized value in
  let callee, args = require_direct_constructor_call expr in
  check_string "synthetic callee" "Some" (require_identifier callee);
  check_bool "synthetic resolved call" true
    (A.expr_resolved_call expr = Some option_some_resolved_call);
  check_int "argument count" 1 (List.length args)

let test_synthesized_nullary_constructor_materializes_identifier () =
  let value =
    {
      V.ty = ty_option_int;
      desc =
        V.VConstructor
          {
            name = "None";
            args = [];
            constructor_info =
              constructor_info ~arity:0 ~callable_id:(Some 43) "Option";
            constructor_origin = V.ConstructorSynthesized;
          };
      loc;
    }
  in
  let expr = require_materialized value in
  check_string "nullary constructor" "None" (require_identifier expr);
  check_bool "nullary constructor has no call metadata" true
    (A.expr_resolved_call expr = None)

let test_public_binding_materializes_immutable_global () =
  let init = typed_expr ty_int (A.ELiteral (A.LitInt 0L)) in
  let binding = typed_global_constant "ANSWER" ty_int init in
  let decl = require_global_var_decl binding (int_value 42) in
  let var = require_var_decl decl in
  let ast_var = Blorp.Typed_ast.var_ast var in
  check_bool "global is immutable" false ast_var.var_is_mutable;
  check_bool "global is const" true ast_var.var_is_const;
  check_string "global name" "ANSWER"
    (Option.value ast_var.var_name ~default:"");
  check_bool "declaration doc is absent" true
    ((Blorp.Typed_ast.decl_ast decl).decl_doc = None)

let test_private_binding_preserves_inner_doc () =
  let doc = "Materialized private value." in
  let init = typed_expr ty_int (A.ELiteral (A.LitInt 0L)) in
  let binding = typed_global_constant "PRIVATE_ANSWER" ty_int init in
  let decl =
    require_global_var_decl ~private_:true ~doc binding (int_value 7)
  in
  let var = require_private_var_decl decl in
  let inner_ast_var = Blorp.Typed_ast.var_ast var in
  check_string "private global name" "PRIVATE_ANSWER"
    (Option.value inner_ast_var.var_name ~default:"");
  check_bool "private wrapper has no doc" true
    ((Blorp.Typed_ast.decl_ast decl).decl_doc = None);
  match Blorp.Typed_ast.decl_view decl with
  | Blorp.Typed_ast.DeclPrivate inner ->
      check_bool "inner declaration keeps doc" true
        ((Blorp.Typed_ast.decl_ast inner).decl_doc = Some doc)
  | _ -> Alcotest.fail "expected private declaration"

let suite =
  [
    ( "materialization",
      [
        Alcotest.test_case
          "source constructor preserves callee and resolved call" `Quick
          test_source_constructor_preserves_callee_and_resolved_call;
        Alcotest.test_case "synthesized payload constructor builds typed call"
          `Quick test_synthesized_payload_constructor_builds_typed_call;
        Alcotest.test_case
          "synthesized nullary constructor materializes identifier" `Quick
          test_synthesized_nullary_constructor_materializes_identifier;
        Alcotest.test_case "public binding materializes immutable global" `Quick
          test_public_binding_materializes_immutable_global;
        Alcotest.test_case "private binding preserves inner doc" `Quick
          test_private_binding_preserves_inner_doc;
      ] );
  ]
