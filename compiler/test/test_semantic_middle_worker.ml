open Blorp

let kind name fields =
  Lsp_json.Object (("kind", Lsp_json.String name) :: fields)

let synthetic_loc = kind "synthetic" []
let named_type name = kind "named" [ ("name", Lsp_json.String name); ("args", Lsp_json.Array []) ]
let type_parameter name = kind "type_parameter" [ ("name", Lsp_json.String name) ]
let int_type = named_type "Int"

let function_type params return_type =
  kind "function"
    [
      ("pure", Lsp_json.Bool true);
      ("params", Lsp_json.Array params);
      ("return_type", return_type);
    ]

let variable name ?def_id () =
  Lsp_json.Object
    [
      ("name", Lsp_json.String name);
      ("uniq", Lsp_json.Int 0);
      ( "def_id",
        Option.fold ~none:Lsp_json.Null ~some:(fun id -> Lsp_json.Int id) def_id );
    ]

let variable_expr name ?def_id value_type =
  kind "var"
    [
      ("var", variable name ?def_id ());
      ("type", value_type);
      ("loc", synthetic_loc);
    ]

let int_literal value =
  kind "literal"
    [
      ("literal", kind "int" [ ("value", Lsp_json.Int value) ]);
      ("type", int_type);
      ("loc", synthetic_loc);
    ]

let function_decl ?source_module ?(type_params = []) ?(body = int_literal 0)
    name def_id =
  kind "function"
    [
      ("name", Lsp_json.String name);
      ( "module",
        Option.fold ~none:Lsp_json.Null
          ~some:(fun name -> Lsp_json.String name)
          source_module );
      ("type_params", Lsp_json.Array type_params);
      ("params", Lsp_json.Array []);
      ("return_type", int_type);
      ("body", body);
      ("pure", Lsp_json.Bool false);
      ("function_kind", kind "user" []);
      ("def_id", Lsp_json.Int def_id);
      ("loc", synthetic_loc);
    ]

let core_program ?(foreign_includes = []) decls =
  kind "program"
    [
      ("decls", Lsp_json.Array decls);
      ( "foreign_includes",
        Lsp_json.Array (List.map (fun include_ -> Lsp_json.String include_) foreign_includes) );
    ]

let import_binding_json =
  Lsp_json.Object
    [
      ("local_name", Lsp_json.String "Value");
      ("module_path", Lsp_json.String "pkg/value");
      ("original_name", Lsp_json.String "SourceValue");
    ]

let module_imports_json =
  Lsp_json.Object
    [
      ("module", Lsp_json.String "pkg/client");
      ("import_bindings", Lsp_json.Array [ import_binding_json ]);
    ]

let request_json ?(schema = 5) ?(domain = "compiler_semantic_middle")
    ?(core_phase = "post_match") ?(require_main = false)
    ?(core = core_program [])
    ?(capabilities = [ "core_post_match"; "core_pre_dce"; "rendered_stage_observations" ])
    ?(observations = [ "trait_resolve"; "fusion" ]) ?stop_after () =
  Lsp_json.Object
    [
      ("schema", Lsp_json.Int schema);
      ("domain", Lsp_json.String domain);
      ("kind", Lsp_json.String "compile_pre_dce");
      ("core_phase", Lsp_json.String core_phase);
      ("target_path", Lsp_json.String "src/main.brp");
      ("target_module", Lsp_json.String "main");
      ("core", core);
      ("next_def_id", Lsp_json.Int 20);
      ("import_bindings", Lsp_json.Array [ import_binding_json ]);
      ("module_imports", Lsp_json.Array [ module_imports_json ]);
      ("require_main", Lsp_json.Bool require_main);
      ("check_invariants", Lsp_json.Bool true);
      ( "required_capabilities",
        Lsp_json.Array
          (List.map (fun capability -> Lsp_json.String capability) capabilities) );
      ( "observations",
        Lsp_json.Array (List.map (fun name -> Lsp_json.String name) observations) );
      ( "stop_after",
        match stop_after with
        | Some stage -> Lsp_json.String stage
        | None -> Lsp_json.Null );
    ]

let remove_object_field name = function
  | Lsp_json.Object fields ->
      Lsp_json.Object (List.filter (fun (field_name, _) -> field_name <> name) fields)
  | _ -> Alcotest.fail "fixture must be an object"

let decode_ok json =
  match Semantic_middle_worker.decode_request json with
  | Ok request -> request
  | Error error -> Alcotest.fail error.Semantic_middle_worker.message

let expect_decode_error expected_code json =
  match Semantic_middle_worker.decode_request json with
  | Ok _ -> Alcotest.fail ("expected protocol error " ^ expected_code)
  | Error error -> Alcotest.(check string) "error code" expected_code error.code

let test_decode_phase_specific_request () =
  let request = decode_ok (request_json ()) in
  Alcotest.(check string) "target path" "src/main.brp" request.target_path;
  Alcotest.(check string) "target module" "main" request.target_module;
  Alcotest.(check int) "next def id" 20 request.next_def_id;
  Alcotest.(check int) "root imports" 1 (List.length request.import_bindings);
  Alcotest.(check int) "module imports" 1 (List.length request.module_imports);
  Alcotest.(check int) "observations" 2 (List.length request.observations)

let test_rejects_schema_domain_phase_capability_and_stage () =
  expect_decode_error "unsupported_schema" (request_json ~schema:1 ());
  expect_decode_error "unsupported_domain" (request_json ~domain:"compiler_cli" ());
  expect_decode_error "unsupported_core_phase" (request_json ~core_phase:"prepared" ());
  expect_decode_error "unsupported_capability"
    (request_json ~capabilities:[ "typed_ast_post_ctfe" ] ());
  expect_decode_error "missing_capability"
    (request_json
       ~capabilities:[ "core_pre_dce"; "rendered_stage_observations" ]
       ());
  expect_decode_error "unsupported_stage"
    (request_json ~observations:[ "lower" ] ());
  expect_decode_error "unsupported_stage"
    (request_json ~observations:[ "synth" ] ());
  expect_decode_error "unsupported_stage"
    (request_json ~observations:[ "specialize" ] ())

let test_rejects_missing_and_late_core () =
  expect_decode_error "missing_field"
    (request_json () |> remove_object_field "required_capabilities");
  let late =
    kind "dup"
      [
        ("var", Lsp_json.Object []);
        ("value_type", int_type);
        ("retain_policy", Lsp_json.String "none");
        ("body", int_literal 0);
        ("type", int_type);
        ("loc", synthetic_loc);
      ]
  in
  let malformed =
    function_decl "main" 1
    |> function
    | Lsp_json.Object fields ->
        Lsp_json.Object
          (List.map (fun (name, value) -> if name = "body" then (name, late) else (name, value)) fields)
    | value -> value
  in
  expect_decode_error "invalid_post_match_core"
    (request_json ~core:(core_program [ malformed ]) ())

let response_or_fail request =
  match Semantic_middle_worker.run_request request with
  | Semantic_middle_worker.Failed diagnostics ->
      Alcotest.fail
        (String.concat "; "
           (List.map (fun d -> d.Semantic_middle_worker.message) diagnostics))
  | response -> response

let test_post_match_core_reaches_pre_dce () =
  let core =
    core_program ~foreign_includes:[ "boundary_fixture.h" ]
      [
        function_decl ~source_module:"pkg/left" "pkg_left__value" 1;
        function_decl "main" 2;
      ]
  in
  match response_or_fail (decode_ok (request_json ~core ~require_main:true ())) with
  | Semantic_middle_worker.Compiled { core; observations } ->
      let rendered = Lsp_json.to_string core in
      Alcotest.(check int) "observations" 2 (List.length observations);
      Alcotest.(check bool) "root function" true (Modules.contains rendered "main");
      Alcotest.(check bool) "module function" true
        (Modules.contains rendered "pkg_left__value");
      Alcotest.(check bool) "program foreign includes" true
        (Modules.contains rendered "boundary_fixture.h")
  | Semantic_middle_worker.Stopped _ -> Alcotest.fail "unexpected stop"
  | Semantic_middle_worker.Failed _ -> assert false

let test_stop_after_returns_snapshot () =
  let core = core_program [ function_decl "main" 2 ] in
  let request =
    decode_ok
      (request_json ~core ~observations:[ "trait_resolve" ]
         ~stop_after:"trait_resolve" ())
  in
  match response_or_fail request with
  | Semantic_middle_worker.Stopped { stage; rendered; observations } ->
      Alcotest.(check string) "stage" "trait_resolve"
        (Semantic_middle_worker.stage_name stage);
      Alcotest.(check int) "observations" 1 (List.length observations);
      Alcotest.(check bool) "snapshot" true (String.length rendered > 0)
  | Semantic_middle_worker.Compiled _ -> Alcotest.fail "expected stop"
  | Semantic_middle_worker.Failed _ -> assert false

let test_rejects_core_from_before_debug_lowering () =
  let marker = 987654 in
  let debug_body =
    kind "debug_block"
      [
        ("body", int_literal marker);
        ("type", named_type "Void");
        ("loc", synthetic_loc);
      ]
  in
  let core = core_program [ function_decl ~body:debug_body "main" 2 ] in
  expect_decode_error "invalid_post_match_core" (request_json ~core ())

let test_accepts_synthesis_introduced_mutable_local () =
  let mutable_let =
    kind "let"
      [
        ("name", variable "value" ());
        ("mutable", Lsp_json.Bool true);
        ("type", int_type);
        ("rhs", int_literal 1);
        ("body", int_literal 2);
      ]
  in
  let core = core_program [ function_decl ~body:mutable_let "main" 2 ] in
  ignore (decode_ok (request_json ~core ()))

let test_rejects_core_from_before_monomorphization () =
  let generic_type = type_parameter "T" in
  let call =
    kind "call"
      [
        ( "call_kind",
          kind "user"
            [ ("name", Lsp_json.String "identity"); ("def_id", Lsp_json.Int 1) ] );
        ("callee", variable_expr "identity" ~def_id:1 (function_type [ generic_type ] generic_type));
        ("args", Lsp_json.Array [ int_literal 1 ]);
        ("type", generic_type);
        ("loc", synthetic_loc);
      ]
  in
  let core = core_program [ function_decl ~body:call "main" 2 ] in
  expect_decode_error "invalid_post_match_core" (request_json ~core ())

let test_rejects_closed_call_to_generic_function () =
  let type_param =
    Lsp_json.Object
      [
        ("name", Lsp_json.String "T");
        ("bounds", Lsp_json.Array []);
      ]
  in
  let generic = function_decl ~type_params:[ type_param ] "identity" 1 in
  let call =
    kind "call"
      [
        ("call_kind", kind "selected_direct" [ ("def_id", Lsp_json.Int 1) ]);
        ("callee", variable_expr "identity" ~def_id:1 (function_type [ int_type ] int_type));
        ("args", Lsp_json.Array [ int_literal 1 ]);
        ("type", int_type);
        ("loc", synthetic_loc);
      ]
  in
  let core = core_program [ generic; function_decl ~body:call "main" 2 ] in
  expect_decode_error "invalid_post_match_core" (request_json ~core ())

let test_require_main_validation () =
  match Semantic_middle_worker.run_request (decode_ok (request_json ~require_main:true ())) with
  | Semantic_middle_worker.Failed [ diagnostic ] ->
      Alcotest.(check string) "code" "missing_main" diagnostic.code;
      Alcotest.(check (option string)) "path" (Some "src/main.brp") diagnostic.path
  | _ -> Alcotest.fail "expected one missing-main diagnostic"

let test_response_json_is_versioned () =
  let response = response_or_fail (decode_ok (request_json ())) in
  let json = Semantic_middle_worker.response_json response in
  Alcotest.(check (option int)) "schema" (Some 5) (Lsp_json.get_int "schema" json);
  Alcotest.(check (option string)) "domain" (Some "compiler_semantic_middle")
    (Lsp_json.get_string "domain" json)

let suite =
  [
    ( "protocol",
      [
        Alcotest.test_case "decode post-match Core request" `Quick
          test_decode_phase_specific_request;
        Alcotest.test_case "reject incompatible protocol fields" `Quick
          test_rejects_schema_domain_phase_capability_and_stage;
        Alcotest.test_case "reject missing and late Core" `Quick
          test_rejects_missing_and_late_core;
        Alcotest.test_case "response JSON is versioned" `Quick
          test_response_json_is_versioned;
      ] );
    ( "worker",
      [
        Alcotest.test_case "post-match Core reaches pre-DCE" `Quick
          test_post_match_core_reaches_pre_dce;
        Alcotest.test_case "stop-after returns snapshot" `Quick
          test_stop_after_returns_snapshot;
        Alcotest.test_case "reject Core from before debug lowering" `Quick
          test_rejects_core_from_before_debug_lowering;
        Alcotest.test_case "accept synthesis-introduced mutable local" `Quick
          test_accepts_synthesis_introduced_mutable_local;
        Alcotest.test_case "reject Core from before monomorphization" `Quick
          test_rejects_core_from_before_monomorphization;
        Alcotest.test_case "reject closed call to generic function" `Quick
          test_rejects_closed_call_to_generic_function;
        Alcotest.test_case "require-main validation" `Quick test_require_main_validation;
      ] );
  ]
