(** Unit tests for LSP completion formatting. *)

open Blorp

let analyzed_state_unisolated source =
  let uri = "file:///tmp/lsp_completion_integration.brp" in
  let state = Lsp_state.create () in
  let doc = Lsp_state.create_document ~uri ~version:1 ~text:source () in
  Hashtbl.add state.documents uri doc;
  Lsp_state.analyze state doc;
  if doc.diagnostics <> [] then
    Alcotest.fail
      ("expected analyzed document without diagnostics, got:\n"
      ^ Test_helpers.format_errors doc.diagnostics);
  (state, uri)

let analyzed_state source =
  Test_helpers.with_isolated_env (fun () -> analyzed_state_unisolated source)

let completion_items_at state uri ~line ~character =
  let params =
    Lsp_json.Object
      [
        ("textDocument", Object [ ("uri", String uri) ]);
        ("position", Object [ ("line", Int line); ("character", Int character) ]);
      ]
  in
  match Lsp_completion.handle_completion state params with
  | Object fields -> (
      match List.assoc_opt "items" fields with
      | Some (Array items) -> items
      | _ -> Alcotest.fail "completion response missing items")
  | _ -> Alcotest.fail "unexpected completion response shape"

let item_detail label items =
  let field name fields = List.assoc_opt name fields in
  let item_labels =
    items
    |> List.filter_map (function
      | Lsp_json.Object fields -> (
          match field "label" fields with
          | Some (String label) -> Some label
          | _ -> None)
      | _ -> None)
    |> String.concat ", "
  in
  let matches_label = function
    | Lsp_json.Object fields -> (
        match field "label" fields with
        | Some (String item_label) -> item_label = label
        | _ -> false)
    | _ -> false
  in
  match List.find_opt matches_label items with
  | Some (Object fields) -> (
      match field "detail" fields with
      | Some (String detail) -> detail
      | _ -> Alcotest.failf "completion item %s missing detail" label)
  | Some _ -> Alcotest.failf "completion item %s has unexpected shape" label
  | None ->
      Alcotest.failf "missing completion item %s; got: [%s]" label item_labels

let item_labels items =
  items
  |> List.filter_map (function
    | Lsp_json.Object fields -> (
        match List.assoc_opt "label" fields with
        | Some (String label) -> Some label
        | _ -> None)
    | _ -> None)

let check_item_absent label items =
  let labels = item_labels items in
  if List.mem label labels then
    Alcotest.failf "unexpected completion item %s; got: [%s]" label
      (String.concat ", " labels)

let check_context text col expected_prefix expected_qualifier =
  let prefix, qualifier = Lsp_completion.get_completion_context text col in
  Alcotest.(check string) "prefix" expected_prefix prefix;
  Alcotest.(check (option string)) "qualifier" expected_qualifier qualifier

let check_type_context text col expected =
  Alcotest.(check bool)
    "type completion context" expected
    (Lsp_completion.is_type_completion_context text col)

let test_completion_context_detects_prefix_and_qualifier () =
  check_context "    glob" 8 "glob" None;
  check_context "    O.So" 8 "So" (Some "O");
  check_context "    O." 6 "" (Some "O");
  check_context "    map2.value_1" 16 "value_1" (Some "map2")

let test_completion_context_detects_type_positions () =
  check_type_context "    thing: Value = {id = value_count}" 13 true;
  check_type_context "func make_value() -> Value:" 23 true;
  check_type_context "    thing: Int = value_count" 26 false;
  check_type_context "func make_value() -> Int: value_count" 33 false

let test_completion_prefers_typed_function_source_signature () =
  let state, uri =
    analyzed_state
      {|
type alias UserId = Int

func consume(user_id: UserId) -> UserId:
    user_id

func main(args: List[String]) -> Int:
    consume(1)
|}
  in
  let items = completion_items_at state uri ~line:7 ~character:8 in
  Alcotest.(check string)
    "completion keeps alias source spelling"
    "func consume(user_id: UserId) -> UserId"
    (item_detail "consume" items)

let test_completion_uses_env_source_type_for_local_variables () =
  let state, uri =
    analyzed_state
      {|
type alias UserId = Int

global_user_id: UserId = 1

func main(args: List[String]) -> Int:
    global_user_id
|}
  in
  let items = completion_items_at state uri ~line:6 ~character:8 in
  Alcotest.(check string)
    "completion keeps annotation source spelling" "UserId"
    (item_detail "global_user_id" items)

let test_completion_includes_function_parameters_and_locals () =
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
  let items = completion_items_at state uri ~line:2 ~character:7 in
  Alcotest.(check string)
    "local completion keeps annotation source spelling" "Int"
    (item_detail "local_count" items);
  let all_items = completion_items_at state uri ~line:2 ~character:4 in
  Alcotest.(check string)
    "parameter completion keeps source type" "List[String]"
    (item_detail "args" all_items)

let test_completion_in_type_context_excludes_values_and_keywords () =
  let state, uri =
    analyzed_state
      (String.concat "\n"
         [
           "record Value {id: Int}";
           "";
           "func value_identity(value: Value) -> Value:";
           "    value";
           "";
           "func main(args: List[String]) -> Int:";
           "    value_count: Int = 1";
           "    thing: Value = {id = value_count}";
           "    thing.id";
           "";
         ])
  in
  let items = completion_items_at state uri ~line:7 ~character:13 in
  Alcotest.(check string)
    "type completion includes source record" "record Value"
    (item_detail "Value" items);
  check_item_absent "value_count" items;
  check_item_absent "value_identity" items;
  check_item_absent "var" items

let test_completion_in_type_context_includes_type_parameters () =
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
  let items = completion_items_at state uri ~line:0 ~character:25 in
  Alcotest.(check string)
    "type completion includes enclosing generic parameter" "type parameter T"
    (item_detail "T" items);
  check_item_absent "trait" items

let test_completion_in_record_literal_suggests_fields () =
  let state, uri =
    analyzed_state
      (String.concat "\n"
         [
           "record Point {x: Int, y: Int}";
           "";
           "func main(args: List[String]) -> Int:";
           "    point: Point = {x = 1, y = 2}";
           "    point.x";
           "";
         ])
  in
  let items = completion_items_at state uri ~line:3 ~character:20 in
  Alcotest.(check string) "literal field x" "Int" (item_detail "x" items);
  Alcotest.(check string) "literal field y" "Int" (item_detail "y" items);
  check_item_absent "point" items;
  check_item_absent "func" items

let test_completion_in_record_literal_omits_assigned_fields () =
  let state, uri =
    analyzed_state
      (String.concat "\n"
         [
           "record Point {x: Int, y: Int}";
           "";
           "func main(args: List[String]) -> Int:";
           "    point: Point = {x = 1, y = 2}";
           "    point.y";
           "";
         ])
  in
  let items = completion_items_at state uri ~line:3 ~character:28 in
  Alcotest.(check string) "remaining field y" "Int" (item_detail "y" items);
  check_item_absent "x" items

let test_completion_in_record_update_suggests_receiver_fields () =
  let state, uri =
    analyzed_state
      (String.concat "\n"
         [
           "record Point {x: Int, y: Int}";
           "";
           "func main(args: List[String]) -> Int:";
           "    point: Point = {x = 1, y = 2}";
           "    updated = {point | x = 3, y = 4}";
           "    updated.y";
           "";
         ])
  in
  let items = completion_items_at state uri ~line:4 ~character:23 in
  Alcotest.(check string) "update field x" "Int" (item_detail "x" items);
  Alcotest.(check string) "update field y" "Int" (item_detail "y" items);
  check_item_absent "point" items;
  check_item_absent "main" items

let test_completion_in_record_field_value_uses_general_scope () =
  let state, uri =
    analyzed_state
      (String.concat "\n"
         [
           "record Point {x: Int, y: Int}";
           "";
           "func main(args: List[String]) -> Int:";
           "    value_count: Int = 1";
           "    point: Point = {x = value_count, y = 2}";
           "    point.x";
           "";
         ])
  in
  let items = completion_items_at state uri ~line:4 ~character:25 in
  Alcotest.(check string)
    "field value sees local scope" "Int"
    (item_detail "value_count" items)

let test_completion_does_not_leak_previous_function_locals_at_top_level () =
  let state, uri =
    analyzed_state
      (String.concat "\n"
         [
           "func helper(arg: Int) -> Int:";
           "    local_only: Int = 1";
           "    local_only";
           "";
           "top_level_value: Int = 0";
           "";
         ])
  in
  let items = completion_items_at state uri ~line:3 ~character:0 in
  check_item_absent "arg" items;
  check_item_absent "local_only" items;
  Alcotest.(check string)
    "top-level binding remains available" "Int"
    (item_detail "top_level_value" items)

let test_completion_resolves_selective_import_alias_members () =
  Test_helpers.with_isolated_env (fun () ->
      let state, uri =
        analyzed_state_unisolated
          (String.concat "\n"
             [
               "import:";
               "    option as O: Option(Some, None)";
               "";
               "func main(args: List[String]) -> Int:";
               "    value: Option[Int] = O.None";
               "    0";
               "";
             ])
      in
      (match Lsp_state.find_document state uri with
      | Some doc ->
          let actual = List.assoc_opt "O" doc.module_aliases in
          if actual <> Some "option" then
            let aliases =
              doc.module_aliases
              |> List.map (fun (alias, path) -> alias ^ " -> " ^ path)
              |> String.concat ", "
            in
            Alcotest.failf
              "selective alias is available for qualified completion: expected \
               O -> option, got [%s]"
              aliases
      | None -> Alcotest.fail "missing analyzed document");
      let direct_items =
        match Lsp_state.find_document state uri with
        | Some doc ->
            Lsp_state.with_document_session doc (fun () ->
                Lsp_completion.completions_from_module "option" "")
        | None -> Alcotest.fail "missing analyzed document"
      in
      let _ = item_detail "None" direct_items in
      let items = completion_items_at state uri ~line:4 ~character:27 in
      let _ = item_detail "None" items in
      ())

let suite =
  [
    ( "format",
      [
        Alcotest.test_case "detects prefix and dot qualifier" `Quick
          test_completion_context_detects_prefix_and_qualifier;
        Alcotest.test_case "detects type completion positions" `Quick
          test_completion_context_detects_type_positions;
        Alcotest.test_case "prefers typed function source signature" `Quick
          test_completion_prefers_typed_function_source_signature;
        Alcotest.test_case "uses env source type for variables" `Quick
          test_completion_uses_env_source_type_for_local_variables;
        Alcotest.test_case "includes function parameters and local bindings"
          `Quick test_completion_includes_function_parameters_and_locals;
        Alcotest.test_case "type context excludes values and keywords" `Quick
          test_completion_in_type_context_excludes_values_and_keywords;
        Alcotest.test_case "type context includes type parameters" `Quick
          test_completion_in_type_context_includes_type_parameters;
        Alcotest.test_case "record literal suggests fields" `Quick
          test_completion_in_record_literal_suggests_fields;
        Alcotest.test_case "record literal omits assigned fields" `Quick
          test_completion_in_record_literal_omits_assigned_fields;
        Alcotest.test_case "record update suggests receiver fields" `Quick
          test_completion_in_record_update_suggests_receiver_fields;
        Alcotest.test_case "record field values use general scope" `Quick
          test_completion_in_record_field_value_uses_general_scope;
        Alcotest.test_case "does not leak previous function locals at top level"
          `Quick
          test_completion_does_not_leak_previous_function_locals_at_top_level;
        Alcotest.test_case "resolves selective import aliases" `Quick
          test_completion_resolves_selective_import_alias_members;
      ] );
  ]
