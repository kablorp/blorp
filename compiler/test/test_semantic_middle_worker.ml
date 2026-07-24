open Blorp

let kind name fields =
  Lsp_json.Object (("kind", Lsp_json.String name) :: fields)

let synthetic_loc = kind "synthetic" []
let named_type name = kind "named" [ ("name", Lsp_json.String name); ("args", Lsp_json.Array []) ]
let int_type = named_type "Int"

let int_literal value =
  kind "literal"
    [
      ("literal", kind "int" [ ("value", Lsp_json.Int value) ]);
      ("type", int_type);
      ("loc", synthetic_loc);
    ]

let function_decl ?source_module ?(body = int_literal 0) name def_id =
  kind "function"
    [
      ("name", Lsp_json.String name);
      ( "module",
        Option.fold ~none:Lsp_json.Null
          ~some:(fun name -> Lsp_json.String name)
          source_module );
      ("type_params", Lsp_json.Array []);
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

let request_json ?(schema = 2) ?(domain = "compiler_semantic_middle")
    ?(core_phase = "prepared") ?(require_main = false)
    ?(debug = false)
    ?(core = core_program [])
    ?(capabilities = [ "core_pre_middle"; "core_pre_dce"; "rendered_stage_observations" ])
    ?(observations = [ "lower"; "fusion" ]) ?stop_after () =
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
      ("debug", Lsp_json.Bool debug);
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
  expect_decode_error "unsupported_core_phase" (request_json ~core_phase:"post_ctfe" ());
  expect_decode_error "unsupported_capability"
    (request_json ~capabilities:[ "typed_ast_post_ctfe" ] ());
  expect_decode_error "unsupported_stage" (request_json ~observations:[ "dce" ] ())

let test_rejects_missing_and_late_core () =
  expect_decode_error "missing_field"
    (request_json () |> remove_object_field "required_capabilities");
  let late =
    kind "drop"
      [
        ("var", Lsp_json.Object []);
        ("value_type", int_type);
        ("release_policy", Lsp_json.String "none");
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
  expect_decode_error "invalid_pre_middle_core"
    (request_json ~core:(core_program [ malformed ]) ())

let response_or_fail request =
  match Semantic_middle_worker.run_request request with
  | Semantic_middle_worker.Failed diagnostics ->
      Alcotest.fail
        (String.concat "; "
           (List.map (fun d -> d.Semantic_middle_worker.message) diagnostics))
  | response -> response

let test_prepared_core_reaches_pre_dce () =
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
    decode_ok (request_json ~core ~observations:[ "lower"; "mono" ] ~stop_after:"mono" ())
  in
  match response_or_fail request with
  | Semantic_middle_worker.Stopped { stage; rendered; observations } ->
      Alcotest.(check string) "stage" "mono" (Semantic_middle_worker.stage_name stage);
      Alcotest.(check int) "observations" 2 (List.length observations);
      Alcotest.(check bool) "snapshot" true (String.length rendered > 0)
  | Semantic_middle_worker.Compiled _ -> Alcotest.fail "expected stop"
  | Semantic_middle_worker.Failed _ -> assert false

let test_debug_stage_owns_prepared_debug_blocks () =
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
  let rendered_after_debug debug =
    let request =
      decode_ok
        (request_json ~core ~debug ~observations:[] ~stop_after:"debug" ())
    in
    match response_or_fail request with
    | Semantic_middle_worker.Stopped { stage; rendered; _ } ->
        Alcotest.(check string) "stage" "debug"
          (Semantic_middle_worker.stage_name stage);
        rendered
    | Semantic_middle_worker.Compiled _ -> Alcotest.fail "expected debug-stage stop"
    | Semantic_middle_worker.Failed _ -> assert false
  in
  let normal = rendered_after_debug false in
  let debug = rendered_after_debug true in
  Alcotest.(check bool) "normal build erases body" false
    (Modules.contains normal (string_of_int marker));
  Alcotest.(check bool) "debug build retains body" true
    (Modules.contains debug (string_of_int marker))

let test_require_main_validation () =
  match Semantic_middle_worker.run_request (decode_ok (request_json ~require_main:true ())) with
  | Semantic_middle_worker.Failed [ diagnostic ] ->
      Alcotest.(check string) "code" "missing_main" diagnostic.code;
      Alcotest.(check (option string)) "path" (Some "src/main.brp") diagnostic.path
  | _ -> Alcotest.fail "expected one missing-main diagnostic"

let test_response_json_is_versioned () =
  let response = response_or_fail (decode_ok (request_json ())) in
  let json = Semantic_middle_worker.response_json response in
  Alcotest.(check (option int)) "schema" (Some 2) (Lsp_json.get_int "schema" json);
  Alcotest.(check (option string)) "domain" (Some "compiler_semantic_middle")
    (Lsp_json.get_string "domain" json)

let suite =
  [
    ( "protocol",
      [
        Alcotest.test_case "decode prepared-Core request" `Quick
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
        Alcotest.test_case "prepared Core reaches pre-DCE" `Quick
          test_prepared_core_reaches_pre_dce;
        Alcotest.test_case "stop-after returns snapshot" `Quick
          test_stop_after_returns_snapshot;
        Alcotest.test_case "debug stage owns prepared debug blocks" `Quick
          test_debug_stage_owns_prepared_debug_blocks;
        Alcotest.test_case "require-main validation" `Quick test_require_main_validation;
      ] );
  ]
