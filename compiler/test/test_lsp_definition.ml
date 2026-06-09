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
          source_program = None;
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

let range_start_or_fail label range_json =
  match range_json with
  | Lsp_json.Object range_fields -> (
      match List.assoc_opt "start" range_fields with
      | Some (Object start_fields) -> (
          match
            ( List.assoc_opt "line" start_fields,
              List.assoc_opt "character" start_fields )
          with
          | Some (Int line), Some (Int character) -> (line, character)
          | _ -> Alcotest.fail (label ^ " start missing position"))
      | _ -> Alcotest.fail (label ^ " range missing start"))
  | _ -> Alcotest.fail (label ^ " response missing range")

let range_end_or_fail label range_json =
  match range_json with
  | Lsp_json.Object range_fields -> (
      match List.assoc_opt "end" range_fields with
      | Some (Object end_fields) -> (
          match
            ( List.assoc_opt "line" end_fields,
              List.assoc_opt "character" end_fields )
          with
          | Some (Int line), Some (Int character) -> (line, character)
          | _ -> Alcotest.fail (label ^ " end missing position"))
      | _ -> Alcotest.fail (label ^ " range missing end"))
  | _ -> Alcotest.fail (label ^ " response missing range")

let first_location_or_fail label = function
  | Lsp_json.Array (first :: _) -> first
  | Lsp_json.Array [] -> Alcotest.fail (label ^ " response had no locations")
  | response -> response

let rec location_start_or_fail label = function
  | Lsp_json.Array _ as response ->
      location_start_or_fail label (first_location_or_fail label response)
  | Lsp_json.Object fields -> (
      match
        ( List.assoc_opt "targetSelectionRange" fields,
          List.assoc_opt "range" fields )
      with
      | Some range, _ | None, Some range -> range_start_or_fail label range
      | None, None -> Alcotest.fail (label ^ " response missing range"))
  | Null -> Alcotest.fail ("expected " ^ label ^ " response, got null")
  | _ -> Alcotest.fail ("unexpected " ^ label ^ " response shape")

let rec origin_selection_range_or_fail label = function
  | Lsp_json.Array _ as response ->
      origin_selection_range_or_fail label
        (first_location_or_fail label response)
  | Lsp_json.Object fields -> (
      match List.assoc_opt "originSelectionRange" fields with
      | Some (Object range_fields) ->
          let range = Lsp_json.Object range_fields in
          (range_start_or_fail label range, range_end_or_fail label range)
      | _ -> Alcotest.fail (label ^ " response missing originSelectionRange"))
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

let type_definition_start_at state uri ~line ~character =
  let params = request_params uri ~line ~character in
  location_start_or_fail "type definition"
    (Lsp_server.handle_type_definition state params)

let definition_response_at state uri ~line ~character =
  let params = request_params uri ~line ~character in
  Lsp_server.handle_definition state params

let check_definition_capabilities () =
  match Lsp_protocol.capabilities with
  | Object fields ->
      Alcotest.(check bool)
        "definition provider is advertised" true
        (List.mem_assoc "definitionProvider" fields);
      Alcotest.(check bool)
        "declaration provider is advertised" true
        (List.mem_assoc "declarationProvider" fields);
      Alcotest.(check bool)
        "type definition provider is advertised" true
        (List.mem_assoc "typeDefinitionProvider" fields)
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

let test_definition_response_has_origin_selection_range () =
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
  let response = definition_response_at state uri ~line:2 ~character:6 in
  Alcotest.(check (pair int int))
    "definition points at the local binding" (1, 4)
    (location_start_or_fail "definition" response);
  Alcotest.(check (pair (pair int int) (pair int int)))
    "definition carries clicked identifier range"
    ((2, 4), (2, 15))
    (origin_selection_range_or_fail "definition" response)

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

let test_type_definition_jumps_to_record_declaration () =
  let state, uri =
    analyzed_state
      (String.concat "\n"
         [
           "record Point {x: Int, y: Int}";
           "";
           "func main(args: List[String]) -> Int:";
           "    p: Point = {x = 1, y = 2}";
           "    0";
           "";
         ])
  in
  Alcotest.(check (pair int int))
    "type definition points at the record declaration" (0, 7)
    (type_definition_start_at state uri ~line:3 ~character:8)

let test_definition_jumps_to_variant_declaration () =
  let state, uri =
    analyzed_state
      (String.concat "\n"
         [
           "union Shape:";
           "    Circle(Float)";
           "    Square(Float)";
           "";
           "func area(s: Shape) -> Float:";
           "    match s:";
           "        Circle(r): r * r";
           "        Square(s): s * s";
           "";
         ])
  in
  Alcotest.(check (pair int int))
    "definition points at the variant declaration" (1, 4)
    (definition_start_at state uri ~line:6 ~character:10)

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

let test_definition_jumps_to_function_type_parameter () =
  let state, uri =
    analyzed_state
      (String.concat "\n"
         [
           "func identity[T](value: T) -> T:";
           "    value";
           "";
           "func main(args: List[String]) -> Int:";
           "    identity(1)";
           "";
         ])
  in
  Alcotest.(check (pair int int))
    "parameter type points at the type parameter" (0, 14)
    (definition_start_at state uri ~line:0 ~character:24);
  Alcotest.(check (pair int int))
    "return type points at the type parameter" (0, 14)
    (definition_start_at state uri ~line:0 ~character:30)

let suite =
  [
    ( "locations",
      [
        Alcotest.test_case "jumps to function parameter" `Quick
          test_definition_jumps_to_function_parameter;
        Alcotest.test_case "jumps to local binding" `Quick
          test_definition_jumps_to_local_binding;
        Alcotest.test_case "response carries origin selection range" `Quick
          test_definition_response_has_origin_selection_range;
        Alcotest.test_case "declaration jumps to local binding" `Quick
          test_declaration_jumps_to_local_binding;
        Alcotest.test_case "type definition jumps to record declaration" `Quick
          test_type_definition_jumps_to_record_declaration;
        Alcotest.test_case "definition jumps to variant declaration" `Quick
          test_definition_jumps_to_variant_declaration;
        Alcotest.test_case "does not leak previous function scope" `Quick
          test_definition_does_not_leak_previous_function_scope;
        Alcotest.test_case "jumps to function type parameter" `Quick
          test_definition_jumps_to_function_type_parameter;
        Alcotest.test_case "advertises declaration navigation" `Quick
          check_definition_capabilities;
      ] );
  ]
