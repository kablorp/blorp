(** Unit tests for LSP go-to-definition locations. *)

open Blorp

let analyzed_state source =
  Test_helpers.with_isolated_env (fun () ->
      let uri = "file:///tmp/lsp_definition_integration.brp" in
      let state = Lsp_state.create () in
      let doc : Lsp_state.document =
        {
          uri;
          version = 1;
          text = source;
          diagnostics = [];
          parse_errors = [];
          program = None;
          typed_program = None;
          env = None;
          module_aliases = [];
        }
      in
      Hashtbl.add state.documents uri doc;
      Lsp_state.analyze state doc;
      if doc.diagnostics <> [] then
        Alcotest.fail
          ("expected analyzed document without diagnostics, got:\n"
          ^ Test_helpers.format_errors doc.diagnostics);
      (state, uri))

let request_params uri ~line ~character =
  Lsp_json.Object
    [
      ("textDocument", Object [ ("uri", String uri) ]);
      ("position", Object [ ("line", Int line); ("character", Int character) ]);
    ]

let location_start_or_fail label = function
  | Lsp_json.Object fields -> (
      match List.assoc_opt "range" fields with
      | Some (Object range_fields) -> (
          match List.assoc_opt "start" range_fields with
          | Some (Object start_fields) -> (
              match
                ( List.assoc_opt "line" start_fields,
                  List.assoc_opt "character" start_fields )
              with
              | Some (Int line), Some (Int character) -> (line, character)
              | _ -> Alcotest.fail (label ^ " start missing position"))
          | _ -> Alcotest.fail (label ^ " range missing start"))
      | _ -> Alcotest.fail (label ^ " response missing range"))
  | Null -> Alcotest.fail ("expected " ^ label ^ " response, got null")
  | _ -> Alcotest.fail ("unexpected " ^ label ^ " response shape")

let definition_start_at state uri ~line ~character =
  let params = request_params uri ~line ~character in
  location_start_or_fail "definition"
    (Lsp_server.handle_definition state params)

let declaration_start_at state uri ~line ~character =
  let params = request_params uri ~line ~character in
  location_start_or_fail "declaration"
    (Lsp_server.handle_declaration state params)

let check_definition_capabilities () =
  match Lsp_protocol.capabilities with
  | Object fields ->
      Alcotest.(check bool)
        "definition provider is advertised" true
        (List.mem_assoc "definitionProvider" fields);
      Alcotest.(check bool)
        "declaration provider is advertised" true
        (List.mem_assoc "declarationProvider" fields)
  | _ -> Alcotest.fail "unexpected capabilities shape"

let test_definition_jumps_to_function_parameter () =
  let state, uri =
    analyzed_state
      (String.concat "\n"
         [ "func main(args: List[String]) -> Int:"; "    args.length()"; "" ])
  in
  Alcotest.(check (pair int int))
    "definition points at the parameter name" (0, 10)
    (definition_start_at state uri ~line:1 ~character:6)

let test_definition_jumps_to_local_binding () =
  let state, uri =
    analyzed_state
      (String.concat "\n"
         [
           "func main(args: List[String]) -> Int:";
           "    local_count: Int = 1";
           "    local_count";
           "";
         ])
  in
  Alcotest.(check (pair int int))
    "definition points at the local binding" (1, 4)
    (definition_start_at state uri ~line:2 ~character:6)

let test_declaration_jumps_to_local_binding () =
  let state, uri =
    analyzed_state
      (String.concat "\n"
         [
           "func main(args: List[String]) -> Int:";
           "    local_count: Int = 1";
           "    local_count";
           "";
         ])
  in
  Alcotest.(check (pair int int))
    "declaration points at the local binding" (1, 4)
    (declaration_start_at state uri ~line:2 ~character:6)

let test_definition_does_not_leak_previous_function_scope () =
  let state, uri =
    analyzed_state
      (String.concat "\n"
         [
           "func helper(arg: Int) -> Int:";
           "    local_only: Int = 1";
           "    local_only";
           "";
           "arg: Int = 0";
           "";
           "func main(local_only: List[String]) -> Int:";
           "    arg";
           "    local_only.length()";
           "";
         ])
  in
  Alcotest.(check (pair int int))
    "top-level use of arg ignores previous function parameter" (4, 0)
    (definition_start_at state uri ~line:7 ~character:5);
  Alcotest.(check (pair int int))
    "current function parameter ignores previous function local" (6, 10)
    (definition_start_at state uri ~line:8 ~character:8)

let suite =
  [
    ( "locations",
      [
        Alcotest.test_case "jumps to function parameter" `Quick
          test_definition_jumps_to_function_parameter;
        Alcotest.test_case "jumps to local binding" `Quick
          test_definition_jumps_to_local_binding;
        Alcotest.test_case "declaration jumps to local binding" `Quick
          test_declaration_jumps_to_local_binding;
        Alcotest.test_case "does not leak previous function scope" `Quick
          test_definition_does_not_leak_previous_function_scope;
        Alcotest.test_case "advertises declaration navigation" `Quick
          check_definition_capabilities;
      ] );
  ]
