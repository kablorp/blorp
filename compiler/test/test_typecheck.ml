(** Unit tests for type-checking phases: purity, mutability, exhaustiveness,
    type inference errors, and main signature validation.

    Each test is a small blorp source string run through [parse_and_typecheck].
    Error tests assert on error message substrings (same as .brp EXPECT tests
    but in-process and with structured error count assertions).
    Success tests assert on [expr_type] in the typed AST.

    These complement the .brp should_pass/should_fail integration tests:
    - .brp tests verify the user-facing error message formatting
    - These tests verify the type checker's internal decisions *)

open Test_helpers

(* ============================================================================
   Purity
   ============================================================================ *)

let test_purity_pure_calls_print () =
  expect_error
    {|
pure func bad(x: Int) -> Int:
    print(to_string(x))
    x
|}
    ~message:"cannot call impure"

let test_purity_pure_calls_user_impure () =
  expect_error
    {|
func side_effect(x: Int) -> Int:
    print(to_string(x))
    x

pure func bad(x: Int) -> Int:
    side_effect(x)
|}
    ~message:"cannot call impure"

let test_purity_local_mutation_ok () =
  expect_ok
    {|
pure func sum(n: Int) -> Int:
    var total: Int = 0
    var i: Int = 0
    while i < n:
        total = total + i
        i = i + 1
    total
|}

let expect_origin_error src ~module_origin ~message =
  Test_helpers.with_isolated_env (fun () ->
      let sess = Blorp.Session.current () in
      Blorp.Modules.init_module_paths ~sess (Sys.getcwd ());
      match
        Blorp.Modules.parse_source ~sess ~filename:"origin_policy.brp" src
      with
      | Error err -> Alcotest.failf "parse failed: %s" err.message
      | Ok program ->
          let _typed, errors =
            Blorp.Typecheck.typecheck ~module_origin program
          in
          if errors = [] then
            Alcotest.failf
              "expected an error containing %S, but typechecked successfully"
              message;
          let found =
            List.exists
              (fun (e : Blorp.Ast.compiler_error) ->
                Test_helpers.contains_substring e.message message)
              errors
          in
          if not found then
            Alcotest.failf "no error contains %S\nActual errors:\n%s" message
              (Test_helpers.format_errors errors))

let test_package_origin_rejects_builtin_body () =
  expect_origin_error
    {|
func native_helper(x: Int) -> Int:
    builtin
|}
    ~module_origin:(Blorp.Session.package_origin "sqlite")
    ~message:"'builtin' can only be used in the standard library"

let test_std_origin_rejects_foreign_decl () =
  expect_origin_error
    {|
foreign(include: "math.h"):
    func c_abs(x: Int) -> Int = "abs"
|}
    ~module_origin:Blorp.Session.Stdlib_module
    ~message:"'foreign' declarations cannot be used in the standard library"

let test_typecheck_typed_returns_valid_program () =
  Test_helpers.with_isolated_env (fun () ->
      let sess = Blorp.Session.current () in
      Blorp.Modules.init_module_paths ~sess (Sys.getcwd ());
      let src = {|
func main(args: List[String]) -> Int:
    0
|} in
      match Blorp.Modules.parse_source ~filename:"typed_api.brp" src with
      | Error err -> Alcotest.failf "parse failed: %s" err.message
      | Ok program -> (
          match Blorp.Typecheck.typecheck_typed program with
          | Ok typed ->
              Alcotest.(check int)
                "typed decl count" 1
                (List.length (Blorp.Typed_ast.program_decls typed))
          | Error errors ->
              Alcotest.failf "expected typed program, got: %s"
                (Test_helpers.format_errors errors)))

let test_typecheck_typed_returns_errors_without_program () =
  Test_helpers.with_isolated_env (fun () ->
      let sess = Blorp.Session.current () in
      Blorp.Modules.init_module_paths ~sess (Sys.getcwd ());
      let src = {|
func main(args: List[String]) -> Int:
    "not an int"
|} in
      match Blorp.Modules.parse_source ~filename:"typed_api_error.brp" src with
      | Error err -> Alcotest.failf "parse failed: %s" err.message
      | Ok program -> (
          match Blorp.Typecheck.typecheck_typed program with
          | Ok _ -> Alcotest.fail "expected type errors"
          | Error errors ->
              Alcotest.(check bool) "has typecheck errors" true (errors <> [])))

let test_state_callable_ids_are_loc_keyed_for_overloads () =
  Test_helpers.with_isolated_env (fun () ->
      let sess = Blorp.Session.current () in
      Blorp.Modules.init_module_paths ~sess (Sys.getcwd ());
      let src =
        {|
func same(x: Int) -> Int:
    x

pure func same(x: String) -> String:
    x
|}
      in
      match
        Blorp.Modules.parse_source ~filename:"callable_overloads.brp" src
      with
      | Error err -> Alcotest.failf "parse failed: %s" err.message
      | Ok program -> (
          let same_locs =
            List.filter_map
              (fun (decl : Blorp.Ast.decl) ->
                match decl.decl_desc with
                | DFunc { func_name = Some "same"; _ } -> Some decl.decl_loc
                | _ -> None)
              program
          in
          match Blorp.Typecheck.typecheck_with_state_typed program with
          | Error errors ->
              Alcotest.failf "expected typed program, got: %s"
                (Test_helpers.format_errors errors)
          | Ok (state, _) -> (
              match
                List.map
                  (fun loc ->
                    Blorp.Typecheck.get_state_func_callable_id state
                      ~name:"same" ~loc)
                  same_locs
              with
              | [ Some first_id; Some second_id ] ->
                  Alcotest.(check bool)
                    "same-name declaration ids differ" true
                    (first_id <> second_id)
              | _ ->
                  Alcotest.fail
                    "expected callable ids for both same-name declarations")))

let expect_typed_program ~filename src =
  Test_helpers.with_isolated_env (fun () ->
      let sess = Blorp.Session.current () in
      Blorp.Modules.init_module_paths ~sess (Sys.getcwd ());
      match Blorp.Modules.parse_source ~filename src with
      | Error err -> Alcotest.failf "parse failed: %s" err.message
      | Ok program -> (
          match Blorp.Typecheck.typecheck_typed program with
          | Error errors ->
              Alcotest.failf "expected typed program, got: %s"
                (Test_helpers.format_errors errors)
          | Ok typed -> typed))

let expect_typed_main_body ~filename src =
  let typed = expect_typed_program ~filename src in
  match
    Test_helpers.find_func_body (Blorp.Typed_ast.program_ast typed) "main"
  with
  | Some body -> body
  | None -> Alcotest.fail "main body not found"

let expect_typed_func typed name =
  Blorp.Typed_ast.program_decls typed
  |> List.find_map (fun decl ->
      match Blorp.Typed_ast.decl_view decl with
      | Blorp.Typed_ast.DeclFunction func
        when (Blorp.Typed_ast.func_ast func).func_name = Some name ->
          Some func
      | _ -> None)
  |> function
  | Some func -> func
  | None -> Alcotest.failf "function %s not found" name

let expect_typed_record typed name =
  Blorp.Typed_ast.program_decls typed
  |> List.find_map (fun decl ->
      match Blorp.Typed_ast.decl_view decl with
      | Blorp.Typed_ast.DeclRecord record
        when (Blorp.Typed_ast.record_ast record).record_name = name ->
          Some record
      | _ -> None)
  |> function
  | Some record -> record
  | None -> Alcotest.failf "record %s not found" name

let expect_typed_type_alias typed name =
  Blorp.Typed_ast.program_decls typed
  |> List.find_map (fun decl ->
      match Blorp.Typed_ast.decl_view decl with
      | Blorp.Typed_ast.DeclTypeAlias alias
        when (Blorp.Typed_ast.type_alias_ast alias).alias_name = name ->
          Some alias
      | _ -> None)
  |> function
  | Some alias -> alias
  | None -> Alcotest.failf "type alias %s not found" name

let expect_typed_impl_method typed name =
  Blorp.Typed_ast.program_decls typed
  |> List.find_map (fun decl ->
      match Blorp.Typed_ast.decl_view decl with
      | Blorp.Typed_ast.DeclImpl impl ->
          Blorp.Typed_ast.impl_methods impl
          |> List.find_opt (fun func ->
              (Blorp.Typed_ast.func_ast func).func_name = Some name)
      | _ -> None)
  |> function
  | Some func -> func
  | None -> Alcotest.failf "impl method %s not found" name

let test_typecheck_value_type_helper_rejects_missing_metadata () =
  let legacy_expr =
    {
      Blorp.Ast.expr_desc = Blorp.Ast.ELiteral (Blorp.Ast.LitInt 1L);
      expr_loc = Blorp.Ast.dummy_loc;
      expr_type = Some Blorp.Types.ty_int;
      expr_type_info = None;
      expr_rc = None;
    }
  in
  match
    Blorp.Typecheck.typed_expr_value_type_for_typecheck
      ~context:"global variable finalization" legacy_expr
  with
  | Ok _ -> Alcotest.fail "expected missing metadata error"
  | Error err ->
      Alcotest.(check bool)
        "reports missing value metadata" true
        (Test_helpers.contains_substring err.message
           "partially typed expression reached global variable finalization")

let test_typecheck_typed_top_level_mutable_var_uses_value_type () =
  let typed =
    expect_typed_program ~filename:"typed_global_var_widening.brp"
      {|
var global_counter = 1

func main(args: List[String]) -> Int:
    global_counter
|}
  in
  let typed_var =
    Blorp.Typed_ast.program_decls typed
    |> List.find_map (fun decl ->
        match Blorp.Typed_ast.decl_view decl with
        | Blorp.Typed_ast.DeclVar var
          when (Blorp.Typed_ast.var_ast var).var_name = Some "global_counter" ->
            Some var
        | _ -> None)
  in
  match typed_var with
  | None -> Alcotest.fail "global_counter declaration not found"
  | Some var ->
      Alcotest.(check bool)
        "binding type uses value slot" true
        (Blorp.Types.types_equal
           (Blorp.Typed_ast.var_binding_type var)
           Blorp.Types.ty_int)

let test_debug_only_validation_rejects_missing_metadata () =
  let debug_func_ty =
    Blorp.Ast.TyFunc
      {
        params = [ Blorp.Types.ty_string ];
        return = Blorp.Types.ty_void;
        is_pure = true;
      }
  in
  let state = Blorp.Typecheck.init_state () in
  let state =
    {
      state with
      env =
        Blorp.Env.add_func state.env "log" debug_func_ty ~purity:Blorp.Env.Pure
          ~debug_only:true ();
    }
  in
  let debug_ref =
    {
      Blorp.Ast.expr_desc = Blorp.Ast.EIdent "log";
      expr_loc = Blorp.Ast.dummy_loc;
      expr_type = Some debug_func_ty;
      expr_type_info = None;
      expr_rc = None;
    }
  in
  let checked = Blorp.Typecheck.validate_debug_usage state debug_ref in
  let found =
    List.exists
      (fun (err : Blorp.Ast.compiler_error) ->
        Test_helpers.contains_substring err.message
          "partially typed expression reached debug-only validation")
      checked.Blorp.Typecheck.errors
  in
  Alcotest.(check bool) "reports missing debug metadata" true found

let test_expr_function_purity_uses_structured_metadata () =
  let impure_func_ty =
    Blorp.Ast.TyFunc
      {
        params = [ Blorp.Types.ty_int ];
        return = Blorp.Types.ty_int;
        is_pure = false;
      }
  in
  let legacy_expr =
    {
      Blorp.Ast.expr_desc = Blorp.Ast.EIdent "callback";
      expr_loc = Blorp.Ast.dummy_loc;
      expr_type = Some impure_func_ty;
      expr_type_info = None;
      expr_rc = None;
    }
  in
  let structured_expr =
    Blorp.Ast.with_expr_type_info legacy_expr
      (Blorp.Ast.expr_type_info_from_type impure_func_ty)
  in
  let env = (Blorp.Typecheck.init_state ()).env in
  Alcotest.(check bool)
    "bare compatibility mirror ignored" true
    (Option.is_none (Blorp.Typecheck.expr_function_purity env legacy_expr));
  Alcotest.(check bool)
    "structured function metadata classified" true
    (Blorp.Typecheck.expr_function_purity env structured_expr
    = Some Blorp.Env.Impure)

let assert_expr_widening ~label expr ~semantic_ty ~value_ty ~reason =
  match Blorp.Typed_ast.of_ast_expr expr with
  | Error _ -> Alcotest.failf "%s did not validate" label
  | Ok typed_expr -> (
      let info = Blorp.Typed_ast.type_info typed_expr in
      Alcotest.(check bool)
        (label ^ " semantic type") true
        (Blorp.Types.types_equal
           (Blorp.Typed_ast.type_info_semantic_type info)
           semantic_ty);
      Alcotest.(check bool)
        (label ^ " value type") true
        (Blorp.Types.types_equal
           (Blorp.Typed_ast.type_info_value_type info)
           value_ty);
      match Blorp.Typed_ast.type_info_widening info with
      | Blorp.Type_widening.Widen { from_ty; to_ty; reason = actual_reason } ->
          Alcotest.(check bool)
            (label ^ " widening source")
            true
            (Blorp.Types.types_equal from_ty semantic_ty);
          Alcotest.(check bool)
            (label ^ " widening target")
            true
            (Blorp.Types.types_equal to_ty value_ty);
          Alcotest.(check bool)
            (label ^ " widening reason")
            true (actual_reason = reason)
      | Blorp.Type_widening.Keep _ ->
          Alcotest.failf "expected %s widening" label)

let test_typecheck_typed_preserves_mutable_initializer_widening () =
  let body =
    expect_typed_main_body ~filename:"typed_mutable_widening.brp"
      {|
func main(args: List[String]) -> Int:
    var total = 1
    total
|}
  in
  let init =
    match body.expr_desc with
    | Blorp.Ast.EBlock ({ expr_desc = EVarDecl (_, _, init, true); _ } :: _) ->
        init
    | Blorp.Ast.EVarDecl (_, _, init, true) -> init
    | _ -> Alcotest.fail "mutable initializer not found"
  in
  assert_expr_widening ~label:"mutable initializer" init
    ~semantic_ty:(Blorp.Ast.TyConstInt 1) ~value_ty:Blorp.Types.ty_int
    ~reason:Blorp.Type_widening.MutableBinding

let test_typecheck_typed_preserves_list_element_widening () =
  let body =
    expect_typed_main_body ~filename:"typed_list_widening.brp"
      {|
func main(args: List[String]) -> Int:
    xs = [1, 2]
    0
|}
  in
  let first_elem =
    match body.expr_desc with
    | Blorp.Ast.EBlock
        ({
           expr_desc =
             EVarDecl (_, _, { expr_desc = EList (first :: _); _ }, false);
           _;
         }
        :: _) ->
        first
    | _ -> Alcotest.fail "list element not found"
  in
  assert_expr_widening ~label:"list element" first_elem
    ~semantic_ty:(Blorp.Ast.TyConstInt 1) ~value_ty:Blorp.Types.ty_int
    ~reason:
      (Blorp.Type_widening.CollectionElement Blorp.Type_widening.ListLiteral)

let test_typecheck_typed_preserves_bitwise_operand_widening () =
  let body =
    expect_typed_main_body ~filename:"typed_bitwise_widening.brp"
      {|
func main(args: List[String]) -> Int:
    result = bit_and(1, 3)
    result
|}
  in
  let first_arg =
    match body.expr_desc with
    | Blorp.Ast.EBlock
        ({
           expr_desc =
             EVarDecl
               ( _,
                 _,
                 {
                   expr_desc =
                     ECall
                       (_, first :: { expr_desc = ELiteral (LitInt 3L); _ } :: _);
                   _;
                 },
                 false );
           _;
         }
        :: _) ->
        first
    | _ -> Alcotest.fail "bitwise argument not found"
  in
  assert_expr_widening ~label:"bitwise operand" first_arg
    ~semantic_ty:(Blorp.Ast.TyConstInt 1) ~value_ty:Blorp.Types.ty_int
    ~reason:Blorp.Type_widening.BitwiseOperator

let test_typecheck_typed_preserves_dict_rest_element_widening () =
  let body =
    expect_typed_main_body ~filename:"typed_dict_rest_widening.brp"
      {|
func main(args: List[String]) -> Int:
    xs = {1 => 10, 2 => 20}
    0
|}
  in
  let second_key =
    match body.expr_desc with
    | Blorp.Ast.EBlock
        ({
           expr_desc =
             EVarDecl
               (_, _, { expr_desc = EDict (_ :: (key, _) :: _); _ }, false);
           _;
         }
        :: _) ->
        key
    | _ -> Alcotest.fail "dict rest key not found"
  in
  assert_expr_widening ~label:"dict rest key" second_key
    ~semantic_ty:(Blorp.Ast.TyConstInt 2) ~value_ty:Blorp.Types.ty_int
    ~reason:
      (Blorp.Type_widening.CollectionElement Blorp.Type_widening.DictLiteral)

let test_typecheck_typed_preserves_call_argument_widening () =
  let body =
    expect_typed_main_body ~filename:"typed_call_argument_widening.brp"
      {|
func identity[T](x: T) -> T:
    x

func main(args: List[String]) -> Int:
    result = identity(1)
    0
|}
  in
  let first_arg =
    match body.expr_desc with
    | Blorp.Ast.EBlock
        ({
           expr_desc =
             EVarDecl (_, _, { expr_desc = ECall (_, first :: _); _ }, false);
           _;
         }
        :: _) ->
        first
    | _ -> Alcotest.fail "call argument not found"
  in
  assert_expr_widening ~label:"call argument" first_arg
    ~semantic_ty:(Blorp.Ast.TyConstInt 1) ~value_ty:Blorp.Types.ty_int
    ~reason:Blorp.Type_widening.ArgumentSlot

let test_typecheck_typed_preserves_numeric_operand_widening () =
  let body =
    expect_typed_main_body ~filename:"typed_numeric_operand_widening.brp"
      {|
func main(args: List[String]) -> Int:
    x: Int = 2
    result = 1 + x
    0
|}
  in
  let left_operand =
    match body.expr_desc with
    | Blorp.Ast.EBlock
        (_
        :: {
             expr_desc =
               EVarDecl (_, _, { expr_desc = EBinary (Add, left, _); _ }, false);
             _;
           }
        :: _) ->
        left
    | _ -> Alcotest.fail "numeric operand not found"
  in
  assert_expr_widening ~label:"numeric operand" left_operand
    ~semantic_ty:(Blorp.Ast.TyConstInt 1) ~value_ty:Blorp.Types.ty_int
    ~reason:(Blorp.Type_widening.NumericOperator Blorp.Ast.Add)

let assert_ascription_metadata ~label expr ~source_ty ~semantic_ty ~value_ty =
  match Blorp.Typed_ast.of_ast_expr expr with
  | Error _ -> Alcotest.failf "%s did not validate" label
  | Ok typed_expr ->
      let info = Blorp.Typed_ast.type_info typed_expr in
      (match Blorp.Typed_ast.type_info_source_type info with
      | Some actual ->
          Alcotest.(check bool)
            (label ^ " source type") true
            (Blorp.Types.types_equal actual source_ty)
      | None -> Alcotest.failf "%s source type missing" label);
      (match Blorp.Typed_ast.type_info_origin info with
      | Blorp.Typed_ast.ExplicitAnnotation actual ->
          Alcotest.(check bool)
            (label ^ " origin annotation")
            true
            (Blorp.Types.types_equal actual source_ty)
      | _ -> Alcotest.failf "%s origin should be explicit annotation" label);
      Alcotest.(check bool)
        (label ^ " semantic type") true
        (Blorp.Types.types_equal
           (Blorp.Typed_ast.type_info_semantic_type info)
           semantic_ty);
      Alcotest.(check bool)
        (label ^ " value type") true
        (Blorp.Types.types_equal
           (Blorp.Typed_ast.type_info_value_type info)
           value_ty)

let assert_expr_source_metadata ~label expr ~source_ty ~semantic_ty ~value_ty =
  match Blorp.Typed_ast.of_ast_expr expr with
  | Error _ -> Alcotest.failf "%s did not validate" label
  | Ok typed_expr ->
      let info = Blorp.Typed_ast.type_info typed_expr in
      (match Blorp.Typed_ast.type_info_source_type info with
      | Some actual ->
          Alcotest.(check bool)
            (label ^ " source type") true
            (Blorp.Types.types_equal actual source_ty)
      | None -> Alcotest.failf "%s source type missing" label);
      Alcotest.(check bool)
        (label ^ " semantic type") true
        (Blorp.Types.types_equal
           (Blorp.Typed_ast.type_info_semantic_type info)
           semantic_ty);
      Alcotest.(check bool)
        (label ^ " value type") true
        (Blorp.Types.types_equal
           (Blorp.Typed_ast.type_info_value_type info)
           value_ty)

let test_typecheck_typed_preserves_ascription_metadata () =
  let source_ty = Blorp.Ast.TyNamed ("Int32", []) in
  let body =
    expect_typed_main_body ~filename:"typed_ascription_metadata.brp"
      {|
func main(args: List[String]) -> Int:
    value = 1 as Int32
    0
|}
  in
  let ascribed =
    match body.expr_desc with
    | Blorp.Ast.EBlock
        ({
           expr_desc =
             EVarDecl (_, _, ({ expr_desc = EAscription _; _ } as init), false);
           _;
         }
        :: _) ->
        init
    | _ -> Alcotest.fail "ascribed initializer not found"
  in
  assert_ascription_metadata ~label:"ascribed initializer" ascribed ~source_ty
    ~semantic_ty:source_ty ~value_ty:source_ty

let test_typecheck_typed_preserves_alias_ascription_source_metadata () =
  let source_ty = Blorp.Ast.TyNamed ("UserId", []) in
  let semantic_ty = Blorp.Types.ty_int in
  let body =
    expect_typed_main_body ~filename:"typed_alias_ascription_metadata.brp"
      {|
type alias UserId = Int

func main(args: List[String]) -> Int:
    value = 1 as UserId
    0
|}
  in
  let ascribed, annotation =
    match body.expr_desc with
    | Blorp.Ast.EBlock
        ({
           expr_desc =
             EVarDecl
               ( _,
                 _,
                 ({ expr_desc = EAscription (_, annotation); _ } as init),
                 false );
           _;
         }
        :: _) ->
        (init, annotation)
    | _ -> Alcotest.fail "alias ascribed initializer not found"
  in
  Alcotest.(check bool)
    "ascription syntax keeps source alias" true
    (Blorp.Types.types_equal annotation source_ty);
  assert_ascription_metadata ~label:"alias ascribed initializer" ascribed
    ~source_ty ~semantic_ty ~value_ty:semantic_ty

let test_typecheck_typed_preserves_local_alias_binding_source_metadata () =
  let source_ty = Blorp.Ast.TyNamed ("UserId", []) in
  let semantic_ty = Blorp.Types.ty_int in
  let body =
    expect_typed_main_body ~filename:"typed_local_alias_binding_metadata.brp"
      {|
type alias UserId = Int

func main(args: List[String]) -> Int:
    user_id: UserId = 1
    user_id
|}
  in
  let init_expr, use_expr =
    match body.expr_desc with
    | Blorp.Ast.EBlock
        [
          {
            expr_desc =
              EVarDecl
                ( _,
                  Some annotation,
                  ({ expr_desc = ELiteral (LitInt _); _ } as init),
                  false );
            _;
          };
          ({ expr_desc = EIdent "user_id"; _ } as use_expr);
        ]
      when Blorp.Types.types_equal annotation semantic_ty ->
        (init, use_expr)
    | _ -> Alcotest.fail "local alias binding expressions not found"
  in
  assert_expr_source_metadata ~label:"local alias initializer" init_expr
    ~source_ty ~semantic_ty ~value_ty:semantic_ty;
  assert_expr_source_metadata ~label:"local alias identifier" use_expr
    ~source_ty ~semantic_ty ~value_ty:semantic_ty

let test_typecheck_typed_preserves_function_param_alias_source_metadata () =
  let source_ty = Blorp.Ast.TyNamed ("UserId", []) in
  let semantic_ty = Blorp.Types.ty_int in
  let typed =
    expect_typed_program ~filename:"typed_function_param_alias_metadata.brp"
      {|
type alias UserId = Int

func identity(user_id: UserId) -> Int:
    user_id

func main(args: List[String]) -> Int:
    identity(1)
|}
  in
  let use_expr =
    match
      Test_helpers.find_func_body (Blorp.Typed_ast.program_ast typed) "identity"
    with
    | Some
        {
          expr_desc =
            EBlock [ ({ expr_desc = EIdent "user_id"; _ } as use_expr) ];
          _;
        } ->
        use_expr
    | Some ({ expr_desc = EIdent "user_id"; _ } as use_expr) -> use_expr
    | _ -> Alcotest.fail "function parameter identifier not found"
  in
  assert_expr_source_metadata ~label:"function parameter identifier" use_expr
    ~source_ty ~semantic_ty ~value_ty:semantic_ty

let test_typecheck_typed_func_decl_preserves_param_alias_source_metadata () =
  let source_ty = Blorp.Ast.TyNamed ("UserId", []) in
  let semantic_ty = Blorp.Types.ty_int in
  let typed =
    expect_typed_program
      ~filename:"typed_function_param_decl_alias_metadata.brp"
      {|
type alias UserId = Int

func identity(user_id: UserId) -> Int:
    user_id

func main(args: List[String]) -> Int:
    identity(1)
|}
  in
  let identity = expect_typed_func typed "identity" in
  match Blorp.Typed_ast.func_param_infos identity with
  | [ param ] ->
      Alcotest.(check (option string))
        "param name" (Some "user_id") param.param_name;
      Alcotest.(check bool)
        "param source type keeps alias" true
        (Blorp.Types.types_equal param.source_param_ty source_ty);
      Alcotest.(check bool)
        "param semantic type is canonical" true
        (Blorp.Types.types_equal param.semantic_param_ty semantic_ty)
  | _ -> Alcotest.fail "expected one parameter metadata entry"

let test_typecheck_typed_preserves_lambda_param_alias_source_metadata () =
  let source_ty = Blorp.Ast.TyNamed ("UserId", []) in
  let semantic_ty = Blorp.Types.ty_int in
  let body =
    expect_typed_main_body ~filename:"typed_lambda_param_alias_metadata.brp"
      {|
type alias UserId = Int

func main(args: List[String]) -> Int:
    f = func(user_id: UserId): user_id
    f(1)
|}
  in
  let use_expr =
    match body.expr_desc with
    | Blorp.Ast.EBlock
        ({
           expr_desc =
             EVarDecl
               ( _,
                 _,
                 {
                   expr_desc =
                     ELambda
                       {
                         func_body =
                           FuncBodyExpr
                             ({ expr_desc = EIdent "user_id"; _ } as use_expr);
                         _;
                       };
                   _;
                 },
                 false );
           _;
         }
        :: _) ->
        use_expr
    | _ -> Alcotest.fail "lambda parameter identifier not found"
  in
  assert_expr_source_metadata ~label:"lambda parameter identifier" use_expr
    ~source_ty ~semantic_ty ~value_ty:semantic_ty

let test_typecheck_typed_preserves_global_alias_binding_source_metadata () =
  let source_ty = Blorp.Ast.TyNamed ("UserId", []) in
  let semantic_ty = Blorp.Types.ty_int in
  let body =
    expect_typed_main_body ~filename:"typed_global_alias_binding_metadata.brp"
      {|
type alias UserId = Int

global_id: UserId = 1

func main(args: List[String]) -> Int:
    global_id
|}
  in
  let use_expr =
    match body.expr_desc with
    | Blorp.Ast.EBlock [ ({ expr_desc = EIdent "global_id"; _ } as use_expr) ]
      ->
        use_expr
    | _ -> Alcotest.fail "global alias identifier not found"
  in
  assert_expr_source_metadata ~label:"global alias identifier" use_expr
    ~source_ty ~semantic_ty ~value_ty:semantic_ty

let test_typecheck_typed_preserves_alias_return_source_metadata () =
  let source_ty = Blorp.Ast.TyNamed ("UserId", []) in
  let semantic_ty = Blorp.Types.ty_int in
  let typed =
    expect_typed_program ~filename:"typed_alias_return_metadata.brp"
      {|
type alias UserId = Int

func make_id() -> UserId:
    1

func main(args: List[String]) -> Int:
    make_id()
|}
  in
  let make_id = expect_typed_func typed "make_id" in
  let info = Blorp.Typed_ast.func_info make_id in
  (match info.source_return_ty with
  | Some actual ->
      Alcotest.(check bool)
        "return source type keeps alias" true
        (Blorp.Types.types_equal actual source_ty)
  | None -> Alcotest.fail "return source type missing");
  Alcotest.(check bool)
    "return semantic type is canonical" true
    (Blorp.Types.types_equal
       (Blorp.Typed_ast.func_semantic_return_type make_id)
       semantic_ty)

let test_typecheck_typed_preserves_lambda_alias_return_source_metadata () =
  let source_ty = Blorp.Ast.TyNamed ("UserId", []) in
  let semantic_ty = Blorp.Types.ty_int in
  let body =
    expect_typed_main_body ~filename:"typed_lambda_alias_return_metadata.brp"
      {|
type alias UserId = Int

func main(args: List[String]) -> Int:
    f = func() -> UserId: 1
    f()
|}
  in
  let lambda =
    match body.expr_desc with
    | Blorp.Ast.EBlock
        ({
           expr_desc =
             EVarDecl
               (_, _, ({ expr_desc = ELambda lambda; _ } as _lambda_expr), false);
           _;
         }
        :: _) ->
        lambda
    | _ -> Alcotest.fail "lambda declaration not found"
  in
  match Blorp.Typed_ast.of_ast_func_decl lambda with
  | Error _ -> Alcotest.fail "lambda did not validate"
  | Ok typed_lambda ->
      let info = Blorp.Typed_ast.func_info typed_lambda in
      (match info.source_return_ty with
      | Some actual ->
          Alcotest.(check bool)
            "lambda return source type keeps alias" true
            (Blorp.Types.types_equal actual source_ty)
      | None -> Alcotest.fail "lambda return source type missing");
      Alcotest.(check bool)
        "lambda return semantic type is canonical" true
        (Blorp.Types.types_equal
           (Blorp.Typed_ast.func_semantic_return_type typed_lambda)
           semantic_ty)

let test_typecheck_typed_preserves_impl_method_alias_return_source_metadata () =
  let source_ty = Blorp.Ast.TyNamed ("UserId", []) in
  let semantic_ty = Blorp.Types.ty_int in
  let typed =
    expect_typed_program ~filename:"typed_impl_method_alias_return_metadata.brp"
      {|
type alias UserId = Int

trait HasUserId:
    pure func extract_user_id(value: Self) -> UserId

struct User {id: Int}

implements HasUserId for User:
    pure func extract_user_id(value: User) -> UserId:
        value.id

func main(args: List[String]) -> Int:
    0
|}
  in
  let method_ = expect_typed_impl_method typed "extract_user_id" in
  let info = Blorp.Typed_ast.func_info method_ in
  (match info.source_return_ty with
  | Some actual ->
      Alcotest.(check bool)
        "impl method return source type keeps alias" true
        (Blorp.Types.types_equal actual source_ty)
  | None -> Alcotest.fail "impl method return source type missing");
  Alcotest.(check bool)
    "impl method return semantic type is canonical" true
    (Blorp.Types.types_equal
       (Blorp.Typed_ast.func_semantic_return_type method_)
       semantic_ty)

let test_typecheck_typed_preserves_record_field_alias_source_metadata () =
  let source_ty = Blorp.Ast.TyNamed ("UserId", []) in
  let semantic_ty = Blorp.Types.ty_int in
  let typed =
    expect_typed_program ~filename:"typed_record_field_alias_metadata.brp"
      {|
type alias UserId = Int

record User {id: UserId}

func main(args: List[String]) -> Int:
    user: User = {id = 1}
    user.id
|}
  in
  let record = expect_typed_record typed "User" in
  let ast_record = Blorp.Typed_ast.record_ast record in
  (match ast_record.record_fields with
  | [ field ] ->
      Alcotest.(check bool)
        "record AST field type is canonical" true
        (Blorp.Types.types_equal field.field_type semantic_ty)
  | _ -> Alcotest.fail "expected one record field");
  match Blorp.Typed_ast.record_field_infos record with
  | [ field ] ->
      Alcotest.(check string) "field name" "id" field.field_name;
      Alcotest.(check bool)
        "record field source type keeps alias" true
        (Blorp.Types.types_equal field.source_field_ty source_ty);
      Alcotest.(check bool)
        "record field semantic type is canonical" true
        (Blorp.Types.types_equal field.semantic_field_ty semantic_ty)
  | _ -> Alcotest.fail "expected one record field metadata entry"

let test_typecheck_typed_preserves_type_alias_target_source_metadata () =
  let source_ty =
    Blorp.Ast.TyNamed ("Option", [ Blorp.Ast.TyNamed ("UserId", []) ])
  in
  let semantic_ty = Blorp.Ast.TyNamed ("Option", [ Blorp.Types.ty_int ]) in
  let typed =
    expect_typed_program ~filename:"typed_type_alias_target_metadata.brp"
      {|
type alias UserId = Int
type alias MaybeUserId = Option[UserId]

func main(args: List[String]) -> Int:
    0
|}
  in
  let alias = expect_typed_type_alias typed "MaybeUserId" in
  let ast_alias = Blorp.Typed_ast.type_alias_ast alias in
  Alcotest.(check bool)
    "type alias AST target is canonical" true
    (Blorp.Types.types_equal ast_alias.alias_target semantic_ty);
  let info = Blorp.Typed_ast.type_alias_info alias in
  Alcotest.(check bool)
    "type alias target source keeps alias" true
    (Blorp.Types.types_equal info.source_target_ty source_ty);
  Alcotest.(check bool)
    "type alias target semantic type is canonical" true
    (Blorp.Types.types_equal info.semantic_target_ty semantic_ty)

let test_typecheck_typed_preserves_ascribed_collection_element_widening () =
  let body =
    expect_typed_main_body ~filename:"typed_ascription_collection_widening.brp"
      {|
func main(args: List[String]) -> Int:
    xs = [1] as List[Int]
    0
|}
  in
  let source_ty = Blorp.Ast.TyNamed ("List", [ Blorp.Types.ty_int ]) in
  let ascribed, first_elem =
    match body.expr_desc with
    | Blorp.Ast.EBlock
        ({
           expr_desc =
             EVarDecl
               ( _,
                 _,
                 ({
                    expr_desc =
                      EAscription ({ expr_desc = EList (first :: _); _ }, _);
                    _;
                  } as init),
                 false );
           _;
         }
        :: _) ->
        (init, first)
    | _ -> Alcotest.fail "ascribed list element not found"
  in
  assert_ascription_metadata ~label:"ascribed list" ascribed ~source_ty
    ~semantic_ty:source_ty ~value_ty:source_ty;
  assert_expr_widening ~label:"ascribed list element" first_elem
    ~semantic_ty:(Blorp.Ast.TyConstInt 1) ~value_ty:Blorp.Types.ty_int
    ~reason:
      (Blorp.Type_widening.CollectionElement Blorp.Type_widening.ListLiteral)

let test_typecheck_typed_preserves_method_receiver_widening () =
  let body =
    expect_typed_main_body ~filename:"typed_method_receiver_widening.brp"
      {|
func main(args: List[String]) -> Int:
    result = 1.to_string()
    0
|}
  in
  let receiver =
    match body.expr_desc with
    | Blorp.Ast.EBlock
        ({
           expr_desc =
             EVarDecl (_, _, { expr_desc = ECall (_, first :: _); _ }, false);
           _;
         }
        :: _) ->
        first
    | _ -> Alcotest.fail "method receiver not found"
  in
  assert_expr_widening ~label:"method receiver" receiver
    ~semantic_ty:(Blorp.Ast.TyConstInt 1) ~value_ty:Blorp.Types.ty_int
    ~reason:Blorp.Type_widening.MethodReceiver

let test_typecheck_with_env_typed_returns_valid_program_and_env () =
  Test_helpers.with_isolated_env (fun () ->
      let sess = Blorp.Session.current () in
      Blorp.Modules.init_module_paths ~sess (Sys.getcwd ());
      let src =
        {|
func helper() -> Int:
    41

func main(args: List[String]) -> Int:
    helper() + 1
|}
      in
      match Blorp.Modules.parse_source ~filename:"typed_env_api.brp" src with
      | Error err -> Alcotest.failf "parse failed: %s" err.message
      | Ok program -> (
          match Blorp.Typecheck.typecheck_with_env_typed program with
          | Ok (typed, env) ->
              Alcotest.(check int)
                "typed decl count" 2
                (List.length (Blorp.Typed_ast.program_decls typed));
              Alcotest.(check bool)
                "env contains helper" true
                (Option.is_some (Blorp.Env.lookup env "helper"))
          | Error (errors, _env) ->
              Alcotest.failf "expected typed program, got: %s"
                (Test_helpers.format_errors errors)))

let test_typecheck_with_env_typed_returns_errors_without_program () =
  Test_helpers.with_isolated_env (fun () ->
      let sess = Blorp.Session.current () in
      Blorp.Modules.init_module_paths ~sess (Sys.getcwd ());
      let src = {|
func main(args: List[String]) -> Int:
    "not an int"
|} in
      match
        Blorp.Modules.parse_source ~filename:"typed_env_api_error.brp" src
      with
      | Error err -> Alcotest.failf "parse failed: %s" err.message
      | Ok program -> (
          match Blorp.Typecheck.typecheck_with_env_typed program with
          | Ok _ -> Alcotest.fail "expected type errors"
          | Error (errors, env) ->
              Alcotest.(check bool) "has typecheck errors" true (errors <> []);
              Alcotest.(check bool)
                "still returns env" true
                (Option.is_some (Blorp.Env.lookup env "main"))))

let test_purity_impure_calls_anything_ok () =
  expect_ok {|
func f() -> Int:
    print("hello")
    42
|}

let test_purity_pure_with_for_loop_ok () =
  expect_ok
    {|
pure func count(xs: List[Int]) -> Int:
    var n: Int = 0
    for x in xs:
        n = n + 1
    n
|}

let test_purity_transitive () =
  expect_error
    {|
func impure_leaf() -> Int:
    print("side effect")
    1

func impure_mid() -> Int:
    impure_leaf()

pure func bad() -> Int:
    impure_mid()
|}
    ~message:"cannot call impure"

let test_purity_pure_callback_to_pure_hof_ok () =
  expect_ok
    {|
pure func apply(x: Int, f: pure (Int) -> Int) -> Int:
    f(x)

pure func double(x: Int) -> Int:
    x * 2

pure func test() -> Int:
    apply(5, double)
|}

let test_purity_unannotated_pure_lambda_to_pure_callback_ok () =
  expect_ok
    {|
pure func apply(x: Int, f: pure (Int) -> Int) -> Int:
    f(x)

pure func test() -> Int:
    apply(5, func(y: Int) -> Int: y + 1)
|}

let test_purity_impure_hof_with_pure_callback_rejected () =
  expect_error
    {|
func impure_apply(x: Int, f: pure (Int) -> Int) -> Int:
    print("side effect")
    f(x)

pure func double(x: Int) -> Int:
    x * 2

pure func bad(x: Int) -> Int:
    impure_apply(x, double)
|}
    ~message:"cannot call impure"

let test_purity_impure_callback_alias_param_rejected () =
  expect_error
    {|
type alias Callback = (Int) -> Int

pure func stores_callback(cb: Callback) -> Int:
    0
|}
    ~message:"impure callback parameter"

let test_purity_error_names_function () =
  (* The error message should mention which impure function was called *)
  expect_error
    {|
pure func bad() -> Int:
    print("hello")
    0
|}
    ~message:"print"

let test_purity_getenv_is_impure () =
  expect_error
    {|
pure func bad() -> String:
    match getenv("HOME"):
        Some(v): v
        None: ""
|}
    ~message:"cannot call impure"

let test_purity_setenv_is_impure () =
  expect_error
    {|
pure func bad() -> Void:
    setenv("KEY", "VAL")
|}
    ~message:"cannot call impure"

let test_purity_recv_timeout_is_impure () =
  expect_error
    {|
pure func bad(ch: Channel[Int]) -> Option[Int]:
    recv_timeout(ch, 100)
|}
    ~message:"cannot call impure"

let test_purity_send_timeout_is_impure () =
  expect_error
    {|
pure func bad(ch: Channel[Int]) -> Bool:
    send_timeout(ch, 42, 100)
|}
    ~message:"cannot call impure"

let test_exit_not_available () =
  expect_error {|
func f() -> Void:
    exit(1)
|} ~message:"ndefined"

(* ============================================================================
   Import validation
   ============================================================================ *)

let test_import_bare_constructor_prelude () =
  expect_error
    {|
import:
    option: None

func main(args: List[String]):
    void
|}
    ~message:"is a constructor of"

let test_import_bare_constructor_result () =
  expect_error
    {|
import:
    result: Ok

func main(args: List[String]):
    void
|}
    ~message:"is a constructor of"

let test_import_constructor_with_type_ok () =
  expect_ok
    {|
import:
    option: Option(Some, None)

func main(args: List[String]):
    maybe: Option[Int] = Some(1)
    _ = maybe
    void
|}

(* ============================================================================
   Mutability
   ============================================================================ *)

let test_mut_assign_immutable () =
  expect_error
    {|
func f() -> Int:
    x = 5
    x = 10
    x
|}
    ~message:"annot assign"

let test_mut_assign_param () =
  expect_error
    {|
func f(x: Int) -> Int:
    x = 10
    x
|}
    ~message:"annot assign"

let test_mut_var_ok () =
  expect_ok {|
func f() -> Int:
    var x: Int = 5
    x = 10
    x
|}

let test_mut_for_loop_var () =
  expect_error
    {|
func f() -> Int:
    for i in 0..10:
        i = 5
    0
|}
    ~message:"annot assign"

let test_mut_closure_captures_mutable () =
  expect_error
    {|
func f() -> Int:
    var x: Int = 5
    g = func(): x + 1
    g()
|}
    ~message:"capture mutable"

let test_mut_closure_captures_immutable_ok () =
  expect_ok {|
func f() -> Int:
    x: Int = 5
    g = func(): x + 1
    g()
|}

(* ============================================================================
   Exhaustiveness
   ============================================================================ *)

let test_exhaust_option_missing_none () =
  expect_error
    {|
import:
    option: Option(Some, None)

func f(x: Option[Int]) -> Int:
    match x:
        Some(v): v
|}
    ~message:"Non-exhaustive"

let test_exhaust_bool_complete_ok () =
  expect_ok
    {|
func f(b: Bool) -> Int:
    match b:
        True: 1
        False: 0
|}

let test_exhaust_wildcard_ok () =
  expect_ok
    {|
import:
    option: Option(Some, None)

func f(x: Option[Int]) -> Int:
    match x:
        Some(v): v
        _: 0
|}

let test_exhaust_custom_union () =
  expect_error
    {|
union Color:
    Red
    Green
    Blue

func name(c: Color) -> String:
    match c:
        Red: "red"
        Green: "green"
|}
    ~message:"Non-exhaustive"

let test_exhaust_custom_union_complete_ok () =
  expect_ok
    {|
union Color:
    Red
    Green
    Blue

func name(c: Color) -> String:
    match c:
        Red: "red"
        Green: "green"
        Blue: "blue"
|}

let test_exhaust_or_pattern_ok () =
  expect_ok
    {|
union Color:
    Red
    Green
    Blue

func is_warm(c: Color) -> Bool:
    match c:
        Red | Green: True
        Blue: False
|}

let typecheck_test_expr desc =
  {
    Blorp.Ast.expr_desc = desc;
    expr_loc = Blorp.Ast.dummy_loc;
    expr_type = None;
    expr_type_info = None;
    expr_rc = None;
  }

let typed_typecheck_test_expr desc ty =
  Blorp.Ast.with_expr_type_info (typecheck_test_expr desc)
    (Blorp.Ast.expr_type_info_from_type ty)

let test_exhaustiveness_rejects_untyped_scrutinee_boundary () =
  let scrutinee = typecheck_test_expr (Blorp.Ast.EIdent "x") in
  let case_body =
    typed_typecheck_test_expr (Blorp.Ast.ELiteral (Blorp.Ast.LitInt 0L))
      Blorp.Types.ty_int
  in
  let match_expr =
    typed_typecheck_test_expr
      (Blorp.Ast.EMatch
         ( scrutinee,
           [
             {
               Blorp.Ast.case_pattern = Blorp.Ast.PatWildcard;
               case_body;
               case_loc = Blorp.Ast.dummy_loc;
             };
           ] ))
      Blorp.Types.ty_int
  in
  let state = Blorp.Typecheck.init_state () in
  let checked = Blorp.Typecheck.check_matches_in_expr state match_expr in
  let found =
    List.exists
      (fun (err : Blorp.Ast.compiler_error) ->
        Test_helpers.contains_substring err.message
          "partially typed expression reached match exhaustiveness checking")
      checked.Blorp.Typecheck.errors
  in
  Alcotest.(check bool) "reports missing scrutinee type info" true found

(* ============================================================================
   Void-typed scrutinee rejection (Phase-boundary defense in depth)
   ============================================================================ *)

(* Regression: matching on a Void-returning expression must be rejected at
   typecheck. Otherwise codegen emits invalid C like "void __scrut = ...;"
   which has no storage — C rejects it with "variable has incomplete type 'void'".
   The defect surfaces when wildcard-or-only patterns slip past the "constructor
   X belongs to type Option" checks. *)
let test_match_scrutinee_void_wildcard () =
  expect_error
    {|
func do_nothing() -> Void:
    void

func main(args: List[String]):
    match do_nothing():
        _: print("x")
|}
    ~message:"Void"

let test_match_scrutinee_void_direct () =
  (* Literal void expression as scrutinee — same violation. *)
  expect_error
    {|
func main(args: List[String]):
    match void:
        _: print("x")
|}
    ~message:"Void"

(* Void in a tuple element is a value position — typecheck must reject
   it just like Void in a var-decl, match scrutinee, or function argument. *)
let test_void_in_tuple_element () =
  expect_error
    {|
func do_nothing() -> Void:
    void

func main(args: List[String]):
    pair: (Int, Void) = (1, do_nothing())
    print("x")
|}
    ~message:"Void"

let test_void_in_list_element () =
  expect_error
    {|
func do_nothing() -> Void:
    void

func main(args: List[String]):
    xs: List[Void] = [do_nothing()]
    print("x")
|}
    ~message:"Void"

let test_void_in_record_field () =
  expect_error
    {|
record Bad {x: Int, y: Void}

func do_nothing() -> Void:
    void

func main(args: List[String]):
    b: Bad = {x = 1, y = do_nothing()}
    print("x")
|}
    ~message:"Void"

(* ============================================================================
   Type inference errors
   ============================================================================ *)

let test_infer_arg_type_mismatch () =
  expect_error
    {|
func double(x: Int) -> Int:
    x * 2

func f() -> Int:
    double("hello")
|}
    ~message:"argument"

let test_infer_return_type_mismatch () =
  expect_error {|
func f() -> String:
    42
|} ~message:"return"

let test_infer_if_branch_mismatch () =
  expect_error
    {|
func f(b: Bool) -> Int:
    if b:
        42
    else:
        "hello"
|}
    ~message:"If-else type mismatch"

let test_infer_too_many_args () =
  expect_error
    {|
func add(a: Int, b: Int) -> Int:
    a + b

func f() -> Int:
    add(1, 2, 3)
|}
    ~message:"argument"

let test_infer_identity_resolves_int () =
  expect_body_type
    {|
func id[T](x: T) -> T:
    x

func f() -> Int:
    id(42)
|}
    ~func:"f" ~ty:Blorp.Types.ty_int

let test_infer_binary_op_mismatch () =
  expect_error {|
func f() -> Int:
    42 + "hello"
|} ~message:"Cannot apply"

let test_infer_undefined_ident () =
  expect_error {|
func f() -> Int:
    nonexistent_var
|} ~message:"ndefined"

(* ============================================================================
   Main signature
   ============================================================================ *)

let test_main_void_ok () =
  expect_ok {|
func main(args: List[String]):
    print("hello")
|}

let test_main_int_ok () =
  expect_ok {|
func main(args: List[String]) -> Int:
    0
|}

let test_main_int_void_body_rejected () =
  expect_error
    {|
func main(args: List[String]) -> Int:
    print("hello")
|}
    ~message:"returns wrong type"

let test_main_explicit_void_ok () =
  expect_ok {|
func main(args: List[String]) -> Void:
    print("hello")
|}

let test_main_bad_return_type () =
  expect_error
    {|
func main(args: List[String]) -> String:
    "hello"
|}
    ~message:"must return Int or Void"

(* ============================================================================
   Checked Function Signatures
   ============================================================================ *)

let loc =
  {
    Blorp.Ast.line = 1;
    column = 1;
    end_line = 1;
    end_column = 1;
    loc_file = None;
  }

let typed_param name ty : Blorp.Ast.param =
  {
    param_name = Some name;
    param_pattern = None;
    param_type = Some ty;
    param_passing = ParamByValue;
    param_loc = loc;
  }

let test_checked_func_signature_carries_normalized_boundary () =
  let state = Blorp.Typecheck.init_state () in
  let func : Blorp.Ast.func_decl =
    {
      func_name = Some "identity";
      func_type_params = [];
      func_params = [ typed_param "x" (Blorp.Ast.TyNamed ("T", [])) ];
      func_return_type = Some (Blorp.Ast.TyNamed ("T", []));
      func_body = Blorp.Ast.FuncNoBody;
      func_is_pure = true;
      func_is_tailrec = false;
      func_no_copy = false;
      func_debug_only = false;
      func_resource_result_ordinary = false;
      func_dim_constraints = [];
    }
  in
  match
    Blorp.Typecheck.checked_func_signature_of_func ~module_path:"math/id" state
      func
  with
  | None -> Alcotest.fail "expected named function signature"
  | Some sig_ ->
      Alcotest.(check string) "name" "identity" sig_.cfs_name;
      Alcotest.(check (list string))
        "effective type params" [ "T" ]
        (Blorp.Ast.type_param_names sig_.cfs_effective_type_params);
      Alcotest.(check int) "one param" 1 (List.length sig_.cfs_param_types);
      Alcotest.(check (option string))
        "param name" (Some "x")
        (List.hd sig_.cfs_param_names);
      (match sig_.cfs_func_type with
      | Blorp.Ast.TyFunc
          {
            params = [ Blorp.Ast.TyVar "T" ];
            return = Blorp.Ast.TyVar "T";
            is_pure = true;
          } ->
          ()
      | other ->
          Alcotest.failf "unexpected function type: %s"
            (Blorp.Types.type_to_string other));
      (match sig_.cfs_purity with
      | Blorp.Env.Pure -> ()
      | Blorp.Env.Impure -> Alcotest.fail "expected pure signature");
      (match sig_.cfs_origin with
      | Blorp.Env.UserDefined -> ()
      | Blorp.Env.Builtin | Blorp.Env.Foreign ->
          Alcotest.fail "expected user-defined signature");
      Alcotest.(check (option string))
        "module path" (Some "math/id") sig_.cfs_module_path

(* ============================================================================
   canonical_module_path (Phase 3.4)
   ============================================================================ *)

(** Every supported input shape must normalize to the bare module
    identifier that [primitive_home] and [type_home] compare against.
    Regression for the reviewer-flagged FS-path gap: when std loads
    from disk through an explicit override, loc_file is an absolute or
    relative filesystem path, not the `<embedded:std/foo>` form. Both
    must compare equal to `std/foo`. *)
let test_canonical_embedded () =
  Alcotest.(check string)
    "embedded stdlib" "std/int"
    (Blorp.Typecheck.canonical_module_path "<embedded:std/int>");
  Alcotest.(check string)
    "embedded nested" "std/net/http"
    (Blorp.Typecheck.canonical_module_path "<embedded:std/net/http>")

let test_canonical_dot_slash () =
  Alcotest.(check string)
    "./std/int.brp" "std/int"
    (Blorp.Typecheck.canonical_module_path "./std/int.brp");
  Alcotest.(check string)
    "./std/int" "std/int"
    (Blorp.Typecheck.canonical_module_path "./std/int")

let test_canonical_absolute () =
  Alcotest.(check string)
    "absolute stdlib" "std/int"
    (Blorp.Typecheck.canonical_module_path "/workspace/blorp/std/int.brp");
  Alcotest.(check string)
    "absolute nested stdlib" "std/net/http"
    (Blorp.Typecheck.canonical_module_path "/path/to/blorp/std/net/http.brp")

let test_canonical_tests_tree () =
  Alcotest.(check string)
    "relative tests" "tests/test_blorp/types/foo"
    (Blorp.Typecheck.canonical_module_path "tests/test_blorp/types/foo.brp");
  Alcotest.(check string)
    "absolute tests" "tests/test_blorp/types/foo"
    (Blorp.Typecheck.canonical_module_path
       "/Users/x/blorp/tests/test_blorp/types/foo.brp")

let test_canonical_user_file () =
  Alcotest.(check string)
    "user file outside standard trees" "user_file"
    (Blorp.Typecheck.canonical_module_path "user_file.brp");
  Alcotest.(check string)
    "user ./file" "user_file"
    (Blorp.Typecheck.canonical_module_path "./user_file.brp")

(* ============================================================================
   Variant DefIds

   Every variant gets a canonical [variant_def_id] minted at typecheck
   [process_type_decl] or at [env_builtins] registration. These tests
   lock in: (1) decoration is total — no variant survives with [None]
   after typecheck; (2) DefIds are unique within a program; (3)
   built-in unions registered via [env_builtins] also carry DefIds.
   ============================================================================ *)

(** Collect every variant from the typed program's [DType] decls. *)
let collect_typed_variants (prog : Blorp.Ast.program) : Blorp.Ast.variant list =
  List.concat_map
    (fun (d : Blorp.Ast.decl) ->
      match d.decl_desc with Blorp.Ast.DType t -> t.type_variants | _ -> [])
    prog

let test_variant_def_ids_user_union () =
  Test_helpers.with_isolated_env (fun () ->
      let src =
        {|
union Shape:
    Circle(Float)
    Square(Float, Float)
    Point

func main(args: List[String]):
    print("hi")
|}
      in
      let typed, errors = Test_helpers.parse_and_typecheck src in
      if errors <> [] then
        Alcotest.failf "expected no errors, got: %s"
          (Test_helpers.format_errors errors);
      let variants = collect_typed_variants typed in
      Alcotest.(check int) "three variants" 3 (List.length variants);
      List.iter
        (fun (v : Blorp.Ast.variant) ->
          match v.variant_def_id with
          | Some _ -> ()
          | None ->
              Alcotest.failf "variant '%s' has no def_id after typecheck"
                v.variant_name)
        variants)

let test_variant_def_ids_enum () =
  Test_helpers.with_isolated_env (fun () ->
      let src =
        {|
enum Direction:
    North
    South
    East
    West

func main(args: List[String]):
    print("hi")
|}
      in
      let typed, errors = Test_helpers.parse_and_typecheck src in
      if errors <> [] then
        Alcotest.failf "expected no errors, got: %s"
          (Test_helpers.format_errors errors);
      let variants = collect_typed_variants typed in
      Alcotest.(check int) "four variants" 4 (List.length variants);
      List.iter
        (fun (v : Blorp.Ast.variant) ->
          match v.variant_def_id with
          | Some _ -> ()
          | None ->
              Alcotest.failf "enum variant '%s' has no def_id after typecheck"
                v.variant_name)
        variants)

let test_variant_def_ids_unique () =
  Test_helpers.with_isolated_env (fun () ->
      let src =
        {|
union A:
    A1(Int)
    A2

union B:
    B1
    B2(String)
    B3(Int, Int)

func main(args: List[String]):
    print("hi")
|}
      in
      let typed, errors = Test_helpers.parse_and_typecheck src in
      if errors <> [] then
        Alcotest.failf "expected no errors, got: %s"
          (Test_helpers.format_errors errors);
      let variants = collect_typed_variants typed in
      let ids =
        List.filter_map
          (fun (v : Blorp.Ast.variant) -> v.variant_def_id)
          variants
      in
      Alcotest.(check int) "all five variants decorated" 5 (List.length ids);
      let unique = List.sort_uniq compare ids in
      Alcotest.(check int)
        "def_ids unique" (List.length ids) (List.length unique))

(* Builtin-variant DefIds: intentionally [None].
   [env_builtins] registers Option/Result/ConcurrencyError as
   env symbols so the typechecker can resolve [Some], [Ok], etc.
   without requiring [std/option.brp] to be loaded first. Those
   constructors are emitted via runtime helpers ([blorp_option_some],
   [blorp_result_ok], [blorp_TaskFailed]) — never as user-generated C
   functions — so their DefIds are unused by codegen. Leaving them
   [None] also avoids the previous re-entry bug where repeated
   [with_builtins] calls minted fresh DefIds into the same env. *)
let test_variant_def_ids_builtin_option () =
  Test_helpers.with_isolated_env (fun () ->
      let env = Blorp.Env_builtins.with_builtins (Blorp.Env.empty ()) in
      match Blorp.Env.get_type_decl env "Option" with
      | None -> Alcotest.fail "Option type missing from builtin env"
      | Some (_, variants) ->
          Alcotest.(check int) "two variants" 2 (List.length variants);
          List.iter
            (fun (v : Blorp.Ast.variant) ->
              Alcotest.(check (option int))
                (Printf.sprintf "builtin Option.%s has no def_id" v.variant_name)
                None v.variant_def_id)
            variants)

let test_variant_def_ids_builtin_result () =
  Test_helpers.with_isolated_env (fun () ->
      let env = Blorp.Env_builtins.with_builtins (Blorp.Env.empty ()) in
      match Blorp.Env.get_type_decl env "Result" with
      | None -> Alcotest.fail "Result type missing from builtin env"
      | Some (_, variants) ->
          Alcotest.(check int) "two variants" 2 (List.length variants);
          List.iter
            (fun (v : Blorp.Ast.variant) ->
              Alcotest.(check (option int))
                (Printf.sprintf "builtin Result.%s has no def_id" v.variant_name)
                None v.variant_def_id)
            variants)

let test_variant_def_ids_builtin_concurrency_error () =
  Test_helpers.with_isolated_env (fun () ->
      let env = Blorp.Env_builtins.with_builtins (Blorp.Env.empty ()) in
      match Blorp.Env.get_type_decl env "ConcurrencyError" with
      | None -> Alcotest.fail "ConcurrencyError type missing from builtin env"
      | Some (_, variants) ->
          List.iter
            (fun (v : Blorp.Ast.variant) ->
              Alcotest.(check (option int))
                (Printf.sprintf "builtin ConcurrencyError.%s has no def_id"
                   v.variant_name)
                None v.variant_def_id)
            variants)

(* Regression: running [with_builtins] multiple times on the same
   env (as pipeline.ml / typecheck.ml do) must not mint fresh DefIds
   for builtin variants. Since they now default to [None], re-entry
   leaves the state untouched. *)
let test_with_builtins_idempotent_for_variants () =
  Test_helpers.with_isolated_env (fun () ->
      let base = Blorp.Env.empty () in
      let env1 = Blorp.Env_builtins.with_builtins base in
      let env2 = Blorp.Env_builtins.with_builtins env1 in
      let env3 = Blorp.Env_builtins.with_builtins env2 in
      List.iter
        (fun name ->
          let variants_of e =
            match Blorp.Env.get_type_decl e name with
            | Some (_, vs) -> vs
            | None -> []
          in
          let v1 = variants_of env1 in
          let v3 = variants_of env3 in
          Alcotest.(check int)
            (Printf.sprintf "%s variant count stable" name)
            (List.length v1) (List.length v3);
          List.iter2
            (fun (a : Blorp.Ast.variant) (b : Blorp.Ast.variant) ->
              Alcotest.(check string)
                "variant name stable" a.variant_name b.variant_name;
              Alcotest.(check (option int))
                "no def_id on either" None a.variant_def_id;
              Alcotest.(check (option int))
                "no def_id on either" None b.variant_def_id)
            v1 v3)
        [ "Option"; "Result"; "ConcurrencyError" ])

(* ============================================================================
   Suite registration
   ============================================================================ *)

let suite =
  [
    ( "purity",
      [
        Alcotest.test_case "pure calls print" `Quick
          test_purity_pure_calls_print;
        Alcotest.test_case "pure calls user impure" `Quick
          test_purity_pure_calls_user_impure;
        Alcotest.test_case "local mutation ok" `Quick
          test_purity_local_mutation_ok;
        Alcotest.test_case "impure calls anything ok" `Quick
          test_purity_impure_calls_anything_ok;
        Alcotest.test_case "pure with for loop ok" `Quick
          test_purity_pure_with_for_loop_ok;
        Alcotest.test_case "transitive impurity" `Quick test_purity_transitive;
        Alcotest.test_case "pure callback to pure hof ok" `Quick
          test_purity_pure_callback_to_pure_hof_ok;
        Alcotest.test_case "unannotated pure lambda to pure callback ok" `Quick
          test_purity_unannotated_pure_lambda_to_pure_callback_ok;
        Alcotest.test_case "impure hof with pure callback rejected" `Quick
          test_purity_impure_hof_with_pure_callback_rejected;
        Alcotest.test_case "impure callback alias param rejected" `Quick
          test_purity_impure_callback_alias_param_rejected;
        Alcotest.test_case "error names function" `Quick
          test_purity_error_names_function;
        Alcotest.test_case "getenv is impure" `Quick
          test_purity_getenv_is_impure;
        Alcotest.test_case "setenv is impure" `Quick
          test_purity_setenv_is_impure;
        Alcotest.test_case "recv_timeout is impure" `Quick
          test_purity_recv_timeout_is_impure;
        Alcotest.test_case "send_timeout is impure" `Quick
          test_purity_send_timeout_is_impure;
      ] );
    ( "import validation",
      [
        Alcotest.test_case "bare constructor prelude" `Quick
          test_import_bare_constructor_prelude;
        Alcotest.test_case "bare constructor result" `Quick
          test_import_bare_constructor_result;
        Alcotest.test_case "constructor with type ok" `Quick
          test_import_constructor_with_type_ok;
      ] );
    ( "origin policy",
      [
        Alcotest.test_case "package rejects builtin body" `Quick
          test_package_origin_rejects_builtin_body;
        Alcotest.test_case "std rejects foreign decl" `Quick
          test_std_origin_rejects_foreign_decl;
      ] );
    ( "typed api",
      [
        Alcotest.test_case "returns typed program" `Quick
          test_typecheck_typed_returns_valid_program;
        Alcotest.test_case "returns errors without program" `Quick
          test_typecheck_typed_returns_errors_without_program;
        Alcotest.test_case "callable ids are keyed by declaration location"
          `Quick test_state_callable_ids_are_loc_keyed_for_overloads;
        Alcotest.test_case "value helper rejects missing metadata" `Quick
          test_typecheck_value_type_helper_rejects_missing_metadata;
        Alcotest.test_case "top-level mutable var uses value type" `Quick
          test_typecheck_typed_top_level_mutable_var_uses_value_type;
        Alcotest.test_case "debug-only boundary rejects missing metadata" `Quick
          test_debug_only_validation_rejects_missing_metadata;
        Alcotest.test_case "function purity uses structured metadata" `Quick
          test_expr_function_purity_uses_structured_metadata;
        Alcotest.test_case "preserves mutable initializer widening" `Quick
          test_typecheck_typed_preserves_mutable_initializer_widening;
        Alcotest.test_case "preserves list element widening" `Quick
          test_typecheck_typed_preserves_list_element_widening;
        Alcotest.test_case "preserves bitwise operand widening" `Quick
          test_typecheck_typed_preserves_bitwise_operand_widening;
        Alcotest.test_case "preserves dict rest element widening" `Quick
          test_typecheck_typed_preserves_dict_rest_element_widening;
        Alcotest.test_case "preserves call argument widening" `Quick
          test_typecheck_typed_preserves_call_argument_widening;
        Alcotest.test_case "preserves numeric operand widening" `Quick
          test_typecheck_typed_preserves_numeric_operand_widening;
        Alcotest.test_case "preserves ascription metadata" `Quick
          test_typecheck_typed_preserves_ascription_metadata;
        Alcotest.test_case "preserves alias ascription source metadata" `Quick
          test_typecheck_typed_preserves_alias_ascription_source_metadata;
        Alcotest.test_case "preserves local alias binding source metadata"
          `Quick
          test_typecheck_typed_preserves_local_alias_binding_source_metadata;
        Alcotest.test_case "preserves function param alias source metadata"
          `Quick
          test_typecheck_typed_preserves_function_param_alias_source_metadata;
        Alcotest.test_case
          "preserves function param declaration alias source metadata" `Quick
          test_typecheck_typed_func_decl_preserves_param_alias_source_metadata;
        Alcotest.test_case "preserves lambda param alias source metadata" `Quick
          test_typecheck_typed_preserves_lambda_param_alias_source_metadata;
        Alcotest.test_case "preserves global alias binding source metadata"
          `Quick
          test_typecheck_typed_preserves_global_alias_binding_source_metadata;
        Alcotest.test_case "preserves alias return source metadata" `Quick
          test_typecheck_typed_preserves_alias_return_source_metadata;
        Alcotest.test_case "preserves lambda alias return source metadata"
          `Quick
          test_typecheck_typed_preserves_lambda_alias_return_source_metadata;
        Alcotest.test_case "preserves impl method alias return source metadata"
          `Quick
          test_typecheck_typed_preserves_impl_method_alias_return_source_metadata;
        Alcotest.test_case "preserves record field alias source metadata" `Quick
          test_typecheck_typed_preserves_record_field_alias_source_metadata;
        Alcotest.test_case "preserves type alias target source metadata" `Quick
          test_typecheck_typed_preserves_type_alias_target_source_metadata;
        Alcotest.test_case "preserves ascribed collection element widening"
          `Quick
          test_typecheck_typed_preserves_ascribed_collection_element_widening;
        Alcotest.test_case "preserves method receiver widening" `Quick
          test_typecheck_typed_preserves_method_receiver_widening;
        Alcotest.test_case "with env returns typed program and env" `Quick
          test_typecheck_with_env_typed_returns_valid_program_and_env;
        Alcotest.test_case "with env returns errors without program" `Quick
          test_typecheck_with_env_typed_returns_errors_without_program;
      ] );
    ( "removed builtins",
      [ Alcotest.test_case "exit not available" `Quick test_exit_not_available ]
    );
    ( "mutability",
      [
        Alcotest.test_case "assign immutable" `Quick test_mut_assign_immutable;
        Alcotest.test_case "assign param" `Quick test_mut_assign_param;
        Alcotest.test_case "var ok" `Quick test_mut_var_ok;
        Alcotest.test_case "for loop var" `Quick test_mut_for_loop_var;
        Alcotest.test_case "closure captures mutable" `Quick
          test_mut_closure_captures_mutable;
        Alcotest.test_case "closure captures immutable ok" `Quick
          test_mut_closure_captures_immutable_ok;
      ] );
    ( "exhaustiveness",
      [
        Alcotest.test_case "option missing None" `Quick
          test_exhaust_option_missing_none;
        Alcotest.test_case "bool complete ok" `Quick
          test_exhaust_bool_complete_ok;
        Alcotest.test_case "wildcard ok" `Quick test_exhaust_wildcard_ok;
        Alcotest.test_case "custom union missing" `Quick
          test_exhaust_custom_union;
        Alcotest.test_case "custom union complete ok" `Quick
          test_exhaust_custom_union_complete_ok;
        Alcotest.test_case "or pattern ok" `Quick test_exhaust_or_pattern_ok;
        Alcotest.test_case "untyped scrutinee boundary rejected" `Quick
          test_exhaustiveness_rejects_untyped_scrutinee_boundary;
      ] );
    ( "void scrutinee",
      [
        Alcotest.test_case "match on void-returning fn" `Quick
          test_match_scrutinee_void_wildcard;
        Alcotest.test_case "match on literal void" `Quick
          test_match_scrutinee_void_direct;
      ] );
    ( "void value position",
      [
        Alcotest.test_case "tuple element" `Quick test_void_in_tuple_element;
        Alcotest.test_case "list element" `Quick test_void_in_list_element;
        Alcotest.test_case "record field" `Quick test_void_in_record_field;
      ] );
    ( "inference errors",
      [
        Alcotest.test_case "arg type mismatch" `Quick
          test_infer_arg_type_mismatch;
        Alcotest.test_case "return type mismatch" `Quick
          test_infer_return_type_mismatch;
        Alcotest.test_case "if branch mismatch" `Quick
          test_infer_if_branch_mismatch;
        Alcotest.test_case "too many args" `Quick test_infer_too_many_args;
        Alcotest.test_case "identity resolves int" `Quick
          test_infer_identity_resolves_int;
        Alcotest.test_case "binary op mismatch" `Quick
          test_infer_binary_op_mismatch;
        Alcotest.test_case "undefined ident" `Quick test_infer_undefined_ident;
      ] );
    ( "main signature",
      [
        Alcotest.test_case "void main ok" `Quick test_main_void_ok;
        Alcotest.test_case "int main ok" `Quick test_main_int_ok;
        Alcotest.test_case "int main rejects void body" `Quick
          test_main_int_void_body_rejected;
        Alcotest.test_case "explicit void ok" `Quick test_main_explicit_void_ok;
        Alcotest.test_case "bad return type" `Quick test_main_bad_return_type;
      ] );
    ( "checked function signatures",
      [
        Alcotest.test_case "normalized boundary" `Quick
          test_checked_func_signature_carries_normalized_boundary;
      ] );
    ( "canonical_module_path",
      [
        Alcotest.test_case "<embedded:...>" `Quick test_canonical_embedded;
        Alcotest.test_case "./path/foo.brp" `Quick test_canonical_dot_slash;
        Alcotest.test_case "/abs/path/foo.brp" `Quick test_canonical_absolute;
        Alcotest.test_case "tests/ tree" `Quick test_canonical_tests_tree;
        Alcotest.test_case "user file outside standard trees" `Quick
          test_canonical_user_file;
      ] );
    ( "variant def_ids",
      [
        Alcotest.test_case "user union decorated" `Quick
          test_variant_def_ids_user_union;
        Alcotest.test_case "enum decorated" `Quick test_variant_def_ids_enum;
        Alcotest.test_case "unique within program" `Quick
          test_variant_def_ids_unique;
        Alcotest.test_case "builtin Option has None def_id" `Quick
          test_variant_def_ids_builtin_option;
        Alcotest.test_case "builtin Result has None def_id" `Quick
          test_variant_def_ids_builtin_result;
        Alcotest.test_case "builtin ConcurrencyError has None def_id" `Quick
          test_variant_def_ids_builtin_concurrency_error;
        Alcotest.test_case "with_builtins idempotent for variants" `Quick
          test_with_builtins_idempotent_for_variants;
      ] );
  ]
