(** Unit tests for LSP completion formatting. *)

open Blorp

let analyzed_state_unisolated source =
  let uri = "file:///tmp/lsp_completion_integration.brp" in
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
      let direct_items = Lsp_completion.completions_from_module "option" "" in
      let _ = item_detail "None" direct_items in
      let items = completion_items_at state uri ~line:4 ~character:27 in
      let _ = item_detail "None" items in
      ())

let suite =
  [
    ( "format",
      [
        Alcotest.test_case "prefers typed function source signature" `Quick
          test_completion_prefers_typed_function_source_signature;
        Alcotest.test_case "uses env source type for variables" `Quick
          test_completion_uses_env_source_type_for_local_variables;
        Alcotest.test_case "includes function parameters and local bindings"
          `Quick test_completion_includes_function_parameters_and_locals;
        Alcotest.test_case "resolves selective import aliases" `Quick
          test_completion_resolves_selective_import_alias_members;
      ] );
  ]
