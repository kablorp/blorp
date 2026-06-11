(** Unit tests for LSP go-to-definition locations. *)

open Blorp

let location_link_capabilities =
  {
    Lsp_state.definition_link_support = true;
    declaration_link_support = true;
    type_definition_link_support = true;
  }

let analyzed_state
    ?(client_capabilities = Lsp_state.default_client_capabilities) source =
  Test_helpers.with_isolated_env (fun () ->
      let uri = "file:///tmp/lsp_definition_integration.brp" in
      let state = Lsp_state.create () in
      state.client_capabilities <- client_capabilities;
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

let first_location_has_field field response =
  match first_location_or_fail "definition" response with
  | Lsp_json.Object fields -> List.mem_assoc field fields
  | _ -> false

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

let rec location_uri_or_fail label = function
  | Lsp_json.Array _ as response ->
      location_uri_or_fail label (first_location_or_fail label response)
  | Lsp_json.Object fields -> (
      match
        (List.assoc_opt "targetUri" fields, List.assoc_opt "uri" fields)
      with
      | Some (String uri), _ | None, Some (String uri) -> uri
      | _ -> Alcotest.fail (label ^ " response missing target URI"))
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

let definition_uri_at state uri ~line ~character =
  let params = request_params uri ~line ~character in
  location_uri_or_fail "definition" (Lsp_server.handle_definition state params)

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

let test_definition_jumps_to_function_name () =
  let state, uri =
    analyzed_state
      (String.concat "\n"
         [
           "func add(a: Int, b: Int) -> Int:";
           "    a + b";
           "";
           "func main(args: List[String]) -> Int:";
           "    add(1, 2)";
           "";
         ])
  in
  Alcotest.(check (pair int int))
    "definition points at the function name" (0, 5)
    (definition_start_at state uri ~line:4 ~character:6)

let test_definition_resolves_list_ufcs_to_list_module () =
  let state, uri =
    analyzed_state ~client_capabilities:location_link_capabilities
      (String.concat "\n"
         [
           "func main(args: List[String]) -> Int:";
           "    xs: List[Int] = [1, 2]";
           "    ys: List[Int] = xs.append(3)";
           "    ys.length()";
           "";
         ])
  in
  Alcotest.(check (pair int int))
    "definition points at the std/list append name" (98, 10)
    (definition_start_at state uri ~line:2 ~character:25);
  let target_uri = definition_uri_at state uri ~line:2 ~character:25 in
  Alcotest.(check bool)
    "definition targets std/list" true
    (Test_helpers.contains_substring target_uri "std/list")

let test_definition_resolves_local_ufcs_to_function_name () =
  let state, uri =
    analyzed_state
      (String.concat "\n"
         [
           "func increment(self: Int, amount: Int) -> Int:";
           "    self + amount";
           "";
           "func main(args: List[String]) -> Int:";
           "    base: Int = 1";
           "    base.increment(2)";
           "";
         ])
  in
  Alcotest.(check (pair int int))
    "definition points at the local UFCS function name" (0, 5)
    (definition_start_at state uri ~line:5 ~character:13)

let test_definition_response_defaults_to_location () =
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
  Alcotest.(check bool)
    "legacy clients get Location.uri" true
    (first_location_has_field "uri" response);
  Alcotest.(check bool)
    "legacy clients do not get LocationLink.targetUri" false
    (first_location_has_field "targetUri" response)

let test_definition_response_has_origin_selection_range () =
  let state, uri =
    analyzed_state ~client_capabilities:location_link_capabilities
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

let test_definition_jumps_to_local_trait_bound () =
  let state, uri =
    analyzed_state
      (String.concat "\n"
         [
           "trait Describe:";
           "    pure func describe(value: Self) -> String";
           "";
           "pure func show[T:Describe](x: T) -> String:";
           "    describe(x)";
           "";
         ])
  in
  Alcotest.(check (pair int int))
    "trait bound resolves to local trait name" (0, 6)
    (definition_start_at state uri ~line:3 ~character:19)

let test_definition_jumps_to_imported_trait_bound () =
  let state, uri =
    analyzed_state ~client_capabilities:location_link_capabilities
      (String.concat "\n"
         [
           "import:";
           "    traits: Stringable";
           "";
           "pure func show[T:Stringable](x: T) -> String:";
           "    to_string(x)";
           "";
         ])
  in
  Alcotest.(check (pair int int))
    "trait bound resolves to imported trait name" (8, 6)
    (definition_start_at state uri ~line:3 ~character:19);
  let target_uri = definition_uri_at state uri ~line:3 ~character:19 in
  Alcotest.(check bool)
    "definition targets std/traits" true
    (Test_helpers.contains_substring target_uri "std/traits")

let test_definition_jumps_to_prelude_trait_bound () =
  let state, uri =
    analyzed_state ~client_capabilities:location_link_capabilities
      (String.concat "\n"
         [
           "pure func show[T:Stringable](x: T) -> String:";
           "    to_string(x)";
           "";
         ])
  in
  Alcotest.(check (pair int int))
    "prelude trait bound resolves to std trait name" (8, 6)
    (definition_start_at state uri ~line:0 ~character:19);
  let target_uri = definition_uri_at state uri ~line:0 ~character:19 in
  Alcotest.(check bool)
    "definition targets std/traits" true
    (Test_helpers.contains_substring target_uri "std/traits")

let suite =
  [
    ( "locations",
      [
        Alcotest.test_case "jumps to function parameter" `Quick
          test_definition_jumps_to_function_parameter;
        Alcotest.test_case "jumps to local binding" `Quick
          test_definition_jumps_to_local_binding;
        Alcotest.test_case "jumps to function name" `Quick
          test_definition_jumps_to_function_name;
        Alcotest.test_case "resolves List UFCS to std/list" `Quick
          test_definition_resolves_list_ufcs_to_list_module;
        Alcotest.test_case "resolves local UFCS to function name" `Quick
          test_definition_resolves_local_ufcs_to_function_name;
        Alcotest.test_case "response defaults to Location" `Quick
          test_definition_response_defaults_to_location;
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
        Alcotest.test_case "jumps to local trait bound" `Quick
          test_definition_jumps_to_local_trait_bound;
        Alcotest.test_case "jumps to imported trait bound" `Quick
          test_definition_jumps_to_imported_trait_bound;
        Alcotest.test_case "jumps to prelude trait bound" `Quick
          test_definition_jumps_to_prelude_trait_bound;
        Alcotest.test_case "advertises declaration navigation" `Quick
          check_definition_capabilities;
      ] );
  ]
