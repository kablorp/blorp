(** Unit tests for CTFE IR translation boundaries. *)

module TA = Blorp.Typed_ast
module A = Blorp.Ast
module IR = Blorp.Ctfe_ir

let check_bool label expected actual =
  Alcotest.(check bool) label expected actual

let check_string label expected actual =
  Alcotest.(check string) label expected actual

let expect_ok_typed_program source =
  Test_helpers.with_isolated_env (fun () ->
      match
        Blorp.Pipeline.typecheck_module_only_typed ~filename:"ctfe_ir_test.brp"
          ~source
      with
      | Ok (_state, typed_program) -> typed_program
      | Error errors ->
          Alcotest.failf "expected no errors, got %d:\n%s" (List.length errors)
            (Test_helpers.format_errors errors))

let find_typed_function typed_program name =
  List.find_map
    (fun decl ->
      match TA.decl_view decl with
      | TA.DeclFunction func
        when (TA.func_ast func).Blorp.Ast.func_name = Some name ->
          Some func
      | _ -> None)
    (TA.program_decls typed_program)

let require_typed_function typed_program name =
  match find_typed_function typed_program name with
  | Some func -> func
  | None -> Alcotest.failf "expected typed function %S" name

let require_function_body func =
  match TA.func_body_expr func with
  | Ok (Some body) -> body
  | Ok None -> Alcotest.fail "expected function body"
  | Error _ -> Alcotest.fail "expected valid typed function body"

let ty_int = A.TyNamed ("Int", [])
let ty_string = A.TyNamed ("String", [])
let ty_void = A.TyNamed ("Void", [])
let ty_option_int = A.TyNamed ("Option", [ ty_int ])
let ty_dict_string_int = A.TyNamed ("Dict", [ ty_string; ty_int ])
let ty_range = A.TyNamed ("Range", [])
let ty_pair = A.TyTuple [ ty_int; ty_string ]

let typed_expr ty desc =
  A.with_expr_type_info
    {
      A.expr_desc = desc;
      expr_loc = A.dummy_loc;
      expr_type = None;
      expr_type_info = None;
      expr_rc = None;
    }
    (A.expr_type_info_from_type ty)

let typed_int value =
  typed_expr ty_int (A.ELiteral (A.LitInt (Int64.of_int value)))

let typed_string value =
  let flags = A.{ sf_multiline = false; sf_raw = false } in
  typed_expr ty_string (A.ELiteral (A.LitString (value, flags)))

let ty_unary_int_func =
  A.TyFunc { params = [ ty_int ]; return = ty_int; is_pure = true }

let resolved_call target =
  {
    A.call_syntax = A.CallBare;
    call_target = target;
    instantiated_params = [ ty_int ];
    instantiated_return = ty_int;
  }

let typed_call ?resolved target_name =
  let callee = typed_expr ty_unary_int_func (A.EIdent target_name) in
  let call = typed_expr ty_int (A.ECall (callee, [ typed_int 1 ])) in
  match resolved with
  | Some resolved -> A.with_expr_resolved_call call resolved
  | None -> call

let typed_ident ?resolved name ty =
  let ident = typed_expr ty (A.EIdent name) in
  match resolved with
  | Some resolved -> A.with_expr_resolved_call ident resolved
  | None -> ident

let require_call_kind expr =
  match TA.of_ast_expr expr with
  | Error _ -> Alcotest.fail "expected finalized typed call expression"
  | Ok typed -> (
      match IR.of_typed_expr typed with
      | Ok { IR.desc = IR.Call call; _ } -> call.IR.call_kind
      | Ok _ -> Alcotest.fail "expected call expression to translate to IR call"
      | Error _ ->
          Alcotest.fail "expected call expression to translate to CTFE IR")

let require_reference_kind expr =
  match TA.of_ast_expr expr with
  | Error _ -> Alcotest.fail "expected finalized typed identifier expression"
  | Ok typed -> (
      match IR.of_typed_expr typed with
      | Ok { IR.desc = IR.Ident ident; _ } -> ident.IR.reference_kind
      | Ok _ ->
          Alcotest.fail
            "expected identifier expression to translate to IR ident"
      | Error _ ->
          Alcotest.fail "expected identifier expression to translate to CTFE IR"
      )

let require_reference_kind_with_nullary_constructor expr =
  let nullary_constructor name =
    if name = "None" then
      Some
        {
          IR.constructor_name = "None";
          constructor_parent_type = "Option";
          constructor_callable_id = Some 43;
        }
    else None
  in
  match TA.of_ast_expr expr with
  | Error _ -> Alcotest.fail "expected finalized typed identifier expression"
  | Ok typed -> (
      match IR.of_typed_expr ~nullary_constructor typed with
      | Ok { IR.desc = IR.Ident ident; _ } -> ident.IR.reference_kind
      | Ok _ ->
          Alcotest.fail
            "expected identifier expression to translate to IR ident"
      | Error _ ->
          Alcotest.fail "expected identifier expression to translate to CTFE IR"
      )

let direct_call ?(callable_id = 7) ?(source_name = "target#7")
    ?(call_pure = true) origin =
  A.CallDirect { callable_id; source_name; call_pure; origin }

let typed_global_constant name ty value =
  let ast_var =
    {
      A.var_name = Some name;
      var_pattern = None;
      var_type = Some ty;
      var_value = value;
      var_is_mutable = false;
      var_is_const = true;
    }
  in
  match
    TA.of_ast_decl
      { A.decl_desc = A.DVar ast_var; decl_loc = A.dummy_loc; decl_doc = None }
  with
  | Ok typed -> (
      match TA.decl_view typed with
      | TA.DeclVar var -> var
      | _ -> Alcotest.fail "expected typed global constant")
  | Error _ -> Alcotest.fail "expected finalized global constant"

let require_ctfe_ir expr =
  match IR.of_typed_expr expr with
  | Ok expr -> expr
  | Error _ -> Alcotest.fail "expected expression to translate to CTFE IR"

let require_ctfe_ir_from_ast expr =
  match TA.of_ast_expr expr with
  | Ok expr -> require_ctfe_ir expr
  | Error _ -> Alcotest.fail "expected finalized typed expression"

let require_unsupported_form expr =
  match TA.of_ast_expr expr with
  | Error _ -> Alcotest.fail "expected finalized typed expression"
  | Ok typed -> (
      match IR.of_typed_expr typed with
      | Error (IR.Unsupported (_, form)) -> form
      | Error (IR.TypedAstError _) -> Alcotest.fail "expected unsupported form"
      | Ok _ -> Alcotest.fail "expected expression to be unsupported")

let require_field_kind receiver_ty field result_ty =
  let receiver = typed_expr receiver_ty (A.EIdent "receiver") in
  let access = typed_expr result_ty (A.EFieldAccess (receiver, field)) in
  match (require_ctfe_ir_from_ast access).IR.desc with
  | IR.FieldAccess { field_kind; _ } -> field_kind
  | _ -> Alcotest.fail "expected field access IR"

let test_block_bindings_are_normalized () =
  let typed =
    expect_ok_typed_program
      {|
pure func sample(input: Option[Int]) -> Option[Int]:
	value: Int = 1
	(left, right) = (2, 3)
	unwrapped ?= input
	Some(value + left + right + unwrapped)
|}
  in
  let func = require_typed_function typed "sample" in
  let body = require_function_body func in
  match (require_ctfe_ir body).IR.desc with
  | IR.Block block -> (
      match block.items with
      | [
       IR.BindValue ("value", Some (Blorp.Ast.TyNamed ("Int", [])), _, false);
       IR.BindTuple ([ "left"; "right" ], _);
       IR.BindQuestion ("unwrapped", None, _);
      ] ->
          check_bool "result exists" true
            (match block.result.IR.desc with IR.Call _ -> true | _ -> false)
      | _ -> Alcotest.fail "expected normalized block binding items")
  | _ -> Alcotest.fail "expected function body to translate to IR block"

let test_compile_time_initializer_translates_to_ir () =
  let value =
    typed_expr ty_int (A.EBinary (A.Add, typed_int 40, typed_int 2))
  in
  let binding = typed_global_constant "X" ty_int value in
  match IR.of_typed_var_initializer binding with
  | Ok { IR.desc = IR.Binary (Blorp.Ast.Add, _, _); _ } -> ()
  | Ok _ -> Alcotest.fail "expected global initializer binary IR"
  | Error _ -> Alcotest.fail "expected global initializer to translate"

let test_compile_time_initializer_translates_vector_literal () =
  let vector_ty = A.TyArray (ty_int, [ A.TyConstInt 3 ]) in
  let value =
    typed_expr vector_ty (A.EVector [ typed_int 1; typed_int 2; typed_int 3 ])
  in
  let binding = typed_global_constant "VECTOR" vector_ty value in
  match IR.of_typed_var_initializer binding with
  | Ok { IR.desc = IR.Vector [ _; _; _ ]; _ } -> ()
  | Ok _ -> Alcotest.fail "expected global initializer vector IR"
  | Error _ -> Alcotest.fail "expected vector initializer to translate"

let test_void_expression_translates_to_ir () =
  let value = typed_expr ty_void A.EVoid in
  match (require_ctfe_ir_from_ast value).IR.desc with
  | IR.Void -> ()
  | _ -> Alcotest.fail "expected void expression to translate to Void IR"

let test_unsupported_forms_have_specific_labels () =
  let tuple_value =
    typed_expr ty_pair (A.ETuple [ typed_int 1; typed_string "value" ])
  in
  let subscript =
    typed_expr ty_string (A.ESubscript (tuple_value, typed_int 1))
  in
  let debug_block = typed_expr ty_int (A.EDebugBlock [ typed_int 1 ]) in
  check_string "subscript form" "subscript expressions"
    (require_unsupported_form subscript);
  check_string "debug form" "debug blocks"
    (require_unsupported_form debug_block)

let test_empty_dict_literal_translates_to_dict_ir () =
  let empty_dict = typed_expr ty_dict_string_int (A.ERecord []) in
  match (require_ctfe_ir_from_ast empty_dict).IR.desc with
  | IR.Dict [] -> ()
  | _ -> Alcotest.fail "expected empty Dict literal to translate to Dict IR"

let test_empty_record_literal_stays_record_ir () =
  let empty_record =
    typed_expr (A.TyNamed ("EmptyRecord", [])) (A.ERecord [])
  in
  match (require_ctfe_ir_from_ast empty_record).IR.desc with
  | IR.Record [] -> ()
  | _ ->
      Alcotest.fail "expected empty non-Dict record to translate to Record IR"

let test_field_access_kind_is_normalized () =
  match
    ( require_field_kind (A.TyNamed ("Point", [])) "x" ty_int,
      require_field_kind ty_pair "1" ty_string,
      require_field_kind ty_range "start" ty_int,
      require_field_kind ty_range "end" ty_int )
  with
  | ( IR.RecordField "x",
      IR.TupleField { tuple_index = 1; tuple_field_name = "1" },
      IR.RangeField IR.RangeStart,
      IR.RangeField IR.RangeEnd ) ->
      ()
  | _ -> Alcotest.fail "expected normalized field access kinds"

let test_invalid_tuple_field_access_kind_is_explicit () =
  match require_field_kind ty_pair "left" ty_int with
  | IR.TupleInvalidField "left" -> ()
  | _ -> Alcotest.fail "expected invalid tuple field access kind"

let test_call_kind_normalizes_direct_calls () =
  let local =
    typed_call "target" ~resolved:(resolved_call (direct_call A.CallableLocal))
  in
  let imported =
    typed_call "map"
      ~resolved:
        (resolved_call
           (direct_call ~source_name:"map#42"
              (A.CallableImported Blorp.Ctfe_intrinsic.Source.list_module)))
  in
  let builtin =
    typed_call "length"
      ~resolved:
        (resolved_call (direct_call ~source_name:"length#3" A.CallableBuiltin))
  in
  let constructor =
    typed_call "Some"
      ~resolved:
        (resolved_call
           (direct_call ~source_name:"Some#11" (A.CallableConstructor "Option")))
  in
  match
    ( require_call_kind local,
      require_call_kind imported,
      require_call_kind builtin,
      require_call_kind constructor )
  with
  | ( IR.LocalCall { source_name = "target"; callable_id = 7; call_pure = true },
      IR.ImportedCall
        {
          imported_direct =
            { source_name = "map"; callable_id = 7; call_pure = true };
          module_path = "std/list";
          imported_intrinsic =
            Some
              (Blorp.Ctfe_intrinsic.ImportedList Blorp.Ctfe_intrinsic.ListMap);
        },
      IR.BuiltinCall
        {
          builtin_direct =
            { source_name = "length"; callable_id = 7; call_pure = true };
          builtin_intrinsic = Some Blorp.Ctfe_intrinsic.BuiltinLength;
        },
      IR.ConstructorCall
        {
          constructor_direct =
            { source_name = "Some"; callable_id = 7; call_pure = true };
          parent_type = "Option";
          constructor_resolved_call = Some _;
          constructor_callee_ast = { A.expr_desc = A.EIdent "Some"; _ };
        } ) ->
      ()
  | _ -> Alcotest.fail "expected normalized direct call kinds"

let test_call_kind_normalizes_trait_closure_and_unresolved_calls () =
  let trait_call =
    typed_call "to_string"
      ~resolved:
        (resolved_call
           (A.CallTraitMethod
              {
                trait_name = "Stringable";
                method_name = "to_string";
                call_pure = true;
                callable_id = Some 9;
              }))
  in
  let closure_call =
    typed_call "callback"
      ~resolved:(resolved_call (A.CallClosure { call_pure = true }))
  in
  let unresolved = typed_call "unknown" in
  match
    ( require_call_kind trait_call,
      require_call_kind closure_call,
      require_call_kind unresolved )
  with
  | ( IR.TraitCall
        {
          trait_name = "Stringable";
          method_name = "to_string";
          trait_pure = true;
          trait_intrinsic = Some Blorp.Ctfe_intrinsic.TraitStringableToString;
        },
      IR.ClosureCall { closure_pure = true },
      IR.UnresolvedCall ) ->
      ()
  | _ ->
      Alcotest.fail
        "expected normalized trait, closure, and unresolved call kinds"

let test_identifier_reference_kind_is_normalized () =
  let local =
    typed_ident "callback" ty_unary_int_func
      ~resolved:
        (resolved_call (direct_call ~source_name:"callback#7" A.CallableLocal))
  in
  let imported =
    typed_ident "map" ty_unary_int_func
      ~resolved:
        (resolved_call
           (direct_call ~source_name:"map#42"
              (A.CallableImported Blorp.Ctfe_intrinsic.Source.list_module)))
  in
  let impure =
    typed_ident "print" ty_unary_int_func
      ~resolved:
        (resolved_call
           (direct_call ~source_name:"print#3" ~call_pure:false
              A.CallableBuiltin))
  in
  let value = typed_ident "value" ty_int in
  match
    ( require_reference_kind local,
      require_reference_kind imported,
      require_reference_kind impure,
      require_reference_kind value )
  with
  | ( IR.LocalFunctionReference
        { source_name = "callback"; callable_id = 7; call_pure = true },
      IR.UnsupportedFunctionReference "map",
      IR.ImpureFunctionReference,
      IR.ValueReference ) ->
      ()
  | _ -> Alcotest.fail "expected normalized identifier reference kinds"

let test_nullary_constructor_reference_kind_is_normalized () =
  let none_value = typed_ident "None" ty_option_int in
  match require_reference_kind_with_nullary_constructor none_value with
  | IR.NullaryConstructorReference
      {
        constructor_name = "None";
        constructor_parent_type = "Option";
        constructor_callable_id = Some 43;
      } ->
      ()
  | _ -> Alcotest.fail "expected normalized nullary constructor reference"

let suite =
  [
    ( "translation",
      [
        Alcotest.test_case "block bindings are normalized" `Quick
          test_block_bindings_are_normalized;
        Alcotest.test_case "global constant initializer translates to IR" `Quick
          test_compile_time_initializer_translates_to_ir;
        Alcotest.test_case
          "global constant initializer translates vector literal" `Quick
          test_compile_time_initializer_translates_vector_literal;
        Alcotest.test_case "void expression translates to IR" `Quick
          test_void_expression_translates_to_ir;
        Alcotest.test_case "unsupported forms have specific labels" `Quick
          test_unsupported_forms_have_specific_labels;
        Alcotest.test_case "empty Dict literal translates to Dict IR" `Quick
          test_empty_dict_literal_translates_to_dict_ir;
        Alcotest.test_case "empty record literal stays Record IR" `Quick
          test_empty_record_literal_stays_record_ir;
        Alcotest.test_case "field access kind is normalized" `Quick
          test_field_access_kind_is_normalized;
        Alcotest.test_case "invalid tuple field access kind is explicit" `Quick
          test_invalid_tuple_field_access_kind_is_explicit;
        Alcotest.test_case "call kind normalizes direct calls" `Quick
          test_call_kind_normalizes_direct_calls;
        Alcotest.test_case
          "call kind normalizes trait closure and unresolved calls" `Quick
          test_call_kind_normalizes_trait_closure_and_unresolved_calls;
        Alcotest.test_case "identifier reference kind is normalized" `Quick
          test_identifier_reference_kind_is_normalized;
        Alcotest.test_case "nullary constructor reference kind is normalized"
          `Quick test_nullary_constructor_reference_kind_is_normalized;
      ] );
  ]
