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

let replace_object_field name replacement = function
  | Lsp_json.Object fields ->
      Lsp_json.Object
        (List.map
           (fun (field_name, value) ->
             if field_name = name then (field_name, replacement)
             else (field_name, value))
           fields)
  | _ -> Alcotest.fail "fixture must be a JSON object"

let remove_object_field name = function
  | Lsp_json.Object fields ->
      Lsp_json.Object
        (List.filter (fun (field_name, _) -> field_name <> name) fields)
  | _ -> Alcotest.fail "fixture must be a JSON object"

let request_json ?(schema = 1) ?(domain = "compiler_semantic_middle")
    ?(typed_phase = "post_ctfe") ?(require_main = false)
    ?(capabilities =
      [
        "typed_ast_post_ctfe";
        "core_pre_dce";
        "rendered_stage_observations";
      ])
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
      ( "required_capabilities",
        Lsp_json.Array
          (List.map (fun capability -> Lsp_json.String capability) capabilities)
      );
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

let typecheck_fixture ~path source =
  match Pipeline.typecheck_module_only_typed ~filename:path ~source with
  | Ok (_, typed_program) -> typed_program
  | Error errors ->
      Alcotest.fail
        ("fixture did not typecheck: "
        ^ String.concat "; "
            (List.map (fun (error : Ast.compiler_error) -> error.message) errors))

let test_decode_phase_specific_request () =
  let request = decode_ok (request_json ()) in
  Alcotest.(check string) "target path" "src/main.brp"
    request.Semantic_middle_worker.target.path;
  Alcotest.(check string) "target module" "main" request.target.module_name;
  Alcotest.(check int) "module count" 1 (List.length request.modules);
  Alcotest.(check int) "observation count" 2
    (List.length request.observations);
  Alcotest.(check bool) "invariants" true request.check_invariants;
  Alcotest.(check int) "capability count" 3
    (List.length request.required_capabilities);
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
  expect_decode_error "unsupported_capability"
    (request_json ~capabilities:[ "source_loading" ] ());
  expect_decode_error "unsupported_stage"
    (request_json ~observations:[ "dce" ] ())

let test_rejects_missing_and_malformed_typed_fields () =
  let without_required_capabilities =
    request_json () |> remove_object_field "required_capabilities"
  in
  expect_decode_error "missing_field" without_required_capabilities;
  let malformed_target =
    typed_unit_json ~path:"src/main.brp" ~module_name:"main"
    |> replace_object_field "typed_program" (Lsp_json.Object [])
  in
  let malformed_request =
    request_json () |> replace_object_field "target" malformed_target
  in
  expect_decode_error "invalid_typed_program" malformed_request

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

let test_explicit_typed_graph_reaches_pre_dce_without_module_cache () =
  let target_program =
    typecheck_fixture ~path:"virtual/main.brp"
      "func main(args: List[String]) -> Int:\n\t0\n"
  in
  let module_program name value =
    typecheck_fixture ~path:("virtual/" ^ name ^ ".brp")
      (Printf.sprintf "pure func value() -> Int:\n\t%d\n" value)
  in
  let request = decode_ok (request_json ~require_main:true ()) in
  let typed_unit path module_name typed_program =
    { Semantic_middle_worker.path; module_name; typed_program; import_bindings = [] }
  in
  let request =
    {
      request with
      target = typed_unit "virtual/main.brp" "main" target_program;
      modules =
        [
          typed_unit "virtual/left.brp" "pkg/left"
            (module_program "left" 1);
          typed_unit "virtual/right.brp" "pkg/right"
            (module_program "right" 2);
        ];
    }
  in
  match Semantic_middle_worker.run_request request with
  | Semantic_middle_worker.Compiled { core; _ } ->
      let rendered = Lsp_json.to_string core in
      Alcotest.(check bool) "target main projected" true
        (Modules.contains rendered "main");
      Alcotest.(check bool) "left module projected" true
        (Modules.contains rendered "pkg_left");
      Alcotest.(check bool) "right module projected" true
        (Modules.contains rendered "pkg_right")
  | Semantic_middle_worker.Stopped _ -> Alcotest.fail "unexpected stop"
  | Semantic_middle_worker.Failed diagnostics ->
      Alcotest.fail
        ("explicit typed graph failed: "
        ^ String.concat "; "
            (List.map
               (fun diagnostic -> diagnostic.Semantic_middle_worker.message)
               diagnostics))

let test_prepare_restores_module_resource_cleanup_metadata () =
  let loc = Ast.point_loc_in ~file:"virtual/resource.brp" ~line:1 ~column:1 in
  let cleanup = Ast.ResourceCleanupBuiltin "close_handle" in
  let resource_decl =
    {
      Ast.decl_desc =
        Ast.DType
          {
            type_name = "Handle";
            type_params = [];
            type_variants = [];
            type_is_enum = false;
            type_is_builtin = true;
            type_is_resource = true;
            type_resource_cleanup = Some cleanup;
          };
      decl_loc = loc;
      decl_doc = None;
    }
  in
  let typed_module = Test_helpers.expect_valid_typed_program [ resource_decl ] in
  let session = Session.create () in
  Session.with_current session (fun () ->
      let modules =
        [
          {
            Core_pipeline.typed_module_name = "pkg/resource";
            typed_module_program = typed_module;
            typed_module_import_bindings = [];
          };
        ]
      in
      ignore
        (Core_pipeline.prepare_typed_with_module_inputs ~modules
           (Typed_ast.make_program []));
      Alcotest.(check bool) "local cleanup registered" true
        (Session.find_resource_cleanup session "Handle" = Some cleanup);
      Alcotest.(check bool) "canonical cleanup registered" true
        (Session.find_resource_cleanup session "pkg/resource::Handle"
        = Some cleanup))

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
    (Lsp_json.get_string "kind" json);
  Alcotest.(check int) "advertised capabilities" 3
    (match json with
    | Lsp_json.Object fields -> (
        match List.assoc_opt "capabilities" fields with
        | Some (Lsp_json.Array capabilities) -> List.length capabilities
        | _ -> 0)
    | _ -> 0)

let suite =
  [
    ( "protocol",
      [
        Alcotest.test_case "decode phase-specific request" `Quick
          test_decode_phase_specific_request;
        Alcotest.test_case "reject schema domain phase and stage" `Quick
          test_rejects_schema_domain_phase_and_stage;
        Alcotest.test_case "reject missing and malformed typed fields" `Quick
          test_rejects_missing_and_malformed_typed_fields;
        Alcotest.test_case "response JSON is versioned" `Quick
          test_response_json_is_versioned;
      ] );
    ( "worker",
      [
        Alcotest.test_case "empty program reaches pre-DCE" `Quick
          test_empty_program_reaches_pre_dce;
        Alcotest.test_case "explicit typed graph reaches pre-DCE" `Quick
          test_explicit_typed_graph_reaches_pre_dce_without_module_cache;
        Alcotest.test_case "restore module resource cleanup metadata" `Quick
          test_prepare_restores_module_resource_cleanup_metadata;
        Alcotest.test_case "stop-after returns snapshot" `Quick
          test_stop_after_returns_stage_snapshot;
        Alcotest.test_case "require-main validation" `Quick
          test_require_main_is_worker_input_validation;
      ] );
  ]
