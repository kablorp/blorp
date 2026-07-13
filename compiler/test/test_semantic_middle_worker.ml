open Blorp

let empty_typed_program_json =
  Lsp_json.Object
    [
      ("kind", Lsp_json.String "typed_program");
      ("source", Lsp_json.Object []);
      ("decls", Lsp_json.Array []);
      ("diagnostics", Lsp_json.Array []);
    ]

let import_binding_json =
  Lsp_json.Object
    [
      ("local_name", Lsp_json.String "Value");
      ("module_path", Lsp_json.String "pkg/value");
      ("original_name", Lsp_json.String "SourceValue");
    ]

let typed_unit_json ~path ~module_name =
  Lsp_json.Object
    [
      ("path", Lsp_json.String path);
      ("module", Lsp_json.String module_name);
      ("typed_program", empty_typed_program_json);
      ("import_bindings", Lsp_json.Array [ import_binding_json ]);
    ]

let request_json ?(schema = 1) ?(domain = "compiler_semantic_middle")
    ?(typed_phase = "post_ctfe") ?(require_main = false)
    ?(observations = [ "lower"; "specialize" ]) ?stop_after () =
  Lsp_json.Object
    [
      ("schema", Lsp_json.Int schema);
      ("domain", Lsp_json.String domain);
      ("kind", Lsp_json.String "compile_pre_dce");
      ("typed_phase", Lsp_json.String typed_phase);
      ("target", typed_unit_json ~path:"src/main.brp" ~module_name:"main");
      ( "modules",
        Lsp_json.Array
          [ typed_unit_json ~path:"src/value.brp" ~module_name:"pkg/value" ] );
      ("debug", Lsp_json.Bool false);
      ("require_main", Lsp_json.Bool require_main);
      ("check_invariants", Lsp_json.Bool true);
      ( "observations",
        Lsp_json.Array (List.map (fun name -> Lsp_json.String name) observations)
      );
      ( "stop_after",
        match stop_after with
        | Some stage -> Lsp_json.String stage
        | None -> Lsp_json.Null );
    ]

let decode_ok json =
  match Semantic_middle_worker.decode_request json with
  | Ok request -> request
  | Error error -> Alcotest.fail error.Semantic_middle_worker.message

let test_decode_phase_specific_request () =
  let request = decode_ok (request_json ()) in
  Alcotest.(check string) "target path" "src/main.brp"
    request.Semantic_middle_worker.target.path;
  Alcotest.(check string) "target module" "main" request.target.module_name;
  Alcotest.(check int) "module count" 1 (List.length request.modules);
  Alcotest.(check int) "observation count" 2
    (List.length request.observations);
  Alcotest.(check bool) "invariants" true request.check_invariants;
  Alcotest.(check (option string)) "no stop" None
    (Option.map Semantic_middle_worker.stage_name request.stop_after)

let expect_decode_error expected_code json =
  match Semantic_middle_worker.decode_request json with
  | Ok _ -> Alcotest.fail ("expected protocol error " ^ expected_code)
  | Error error ->
      Alcotest.(check string) "error code" expected_code error.code

let test_rejects_schema_domain_phase_and_stage () =
  expect_decode_error "unsupported_schema" (request_json ~schema:2 ());
  expect_decode_error "unsupported_domain"
    (request_json ~domain:"compiler_cli" ());
  expect_decode_error "unsupported_typed_phase"
    (request_json ~typed_phase:"pre_ctfe" ());
  expect_decode_error "unsupported_stage"
    (request_json ~observations:[ "dce" ] ())

let test_empty_program_reaches_pre_dce () =
  let response = Semantic_middle_worker.run_request (decode_ok (request_json ())) in
  match response with
  | Semantic_middle_worker.Compiled { core; observations } ->
      Alcotest.(check int) "observations" 2 (List.length observations);
      Alcotest.(check bool) "core object"
        true
        (match core with Lsp_json.Object _ -> true | _ -> false)
  | Semantic_middle_worker.Stopped _ -> Alcotest.fail "unexpected stopped response"
  | Semantic_middle_worker.Failed diagnostics ->
      Alcotest.fail
        ("unexpected semantic failure: "
        ^ String.concat "; "
            (List.map
               (fun diagnostic -> diagnostic.Semantic_middle_worker.message)
               diagnostics))

let test_stop_after_returns_stage_snapshot () =
  let request =
    decode_ok
      (request_json ~observations:[ "lower"; "mono" ] ~stop_after:"mono" ())
  in
  match Semantic_middle_worker.run_request request with
  | Semantic_middle_worker.Stopped { stage; rendered; observations } ->
      Alcotest.(check string) "stage" "mono"
        (Semantic_middle_worker.stage_name stage);
      Alcotest.(check int) "observations include lower and mono" 2
        (List.length observations);
      Alcotest.(check bool) "snapshot rendered" true
        (String.length rendered > 0)
  | Semantic_middle_worker.Compiled _ -> Alcotest.fail "expected stopped response"
  | Semantic_middle_worker.Failed _ -> Alcotest.fail "unexpected failure response"

let test_require_main_is_worker_input_validation () =
  let request = decode_ok (request_json ~require_main:true ()) in
  match Semantic_middle_worker.run_request request with
  | Semantic_middle_worker.Failed [ diagnostic ] ->
      Alcotest.(check string) "diagnostic code" "missing_main" diagnostic.code;
      Alcotest.(check (option string)) "diagnostic path" (Some "src/main.brp")
        diagnostic.path
  | Semantic_middle_worker.Failed _ ->
      Alcotest.fail "expected one missing-main diagnostic"
  | Semantic_middle_worker.Compiled _ | Semantic_middle_worker.Stopped _ ->
      Alcotest.fail "expected missing-main failure"

let test_response_json_is_versioned () =
  let response = Semantic_middle_worker.run_request (decode_ok (request_json ())) in
  let json = Semantic_middle_worker.response_json response in
  Alcotest.(check (option int)) "schema" (Some 1) (Lsp_json.get_int "schema" json);
  Alcotest.(check (option string)) "domain"
    (Some "compiler_semantic_middle")
    (Lsp_json.get_string "domain" json);
  Alcotest.(check (option string)) "kind" (Some "compiled")
    (Lsp_json.get_string "kind" json)

let suite =
  [
    ( "protocol",
      [
        Alcotest.test_case "decode phase-specific request" `Quick
          test_decode_phase_specific_request;
        Alcotest.test_case "reject schema domain phase and stage" `Quick
          test_rejects_schema_domain_phase_and_stage;
        Alcotest.test_case "response JSON is versioned" `Quick
          test_response_json_is_versioned;
      ] );
    ( "worker",
      [
        Alcotest.test_case "empty program reaches pre-DCE" `Quick
          test_empty_program_reaches_pre_dce;
        Alcotest.test_case "stop-after returns snapshot" `Quick
          test_stop_after_returns_stage_snapshot;
        Alcotest.test_case "require-main validation" `Quick
          test_require_main_is_worker_input_validation;
      ] );
  ]
