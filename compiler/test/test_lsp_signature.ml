(** Unit tests for LSP signature help formatting. *)

open Blorp

let analyzed_state_unisolated source =
  let uri = "file:///tmp/lsp_signature_integration.brp" in
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

let signature_response_at state uri ~line ~character =
  let params =
    Lsp_json.Object
      [
        ("textDocument", Object [ ("uri", String uri) ]);
        ("position", Object [ ("line", Int line); ("character", Int character) ]);
      ]
  in
  match Lsp_signature.handle_signature_help state params with
  | Object fields -> (
      match
        ( List.assoc_opt "signatures" fields,
          List.assoc_opt "activeParameter" fields )
      with
      | Some (Array [ Object signature_fields ]), _ -> (
          match List.assoc_opt "label" signature_fields with
          | Some (String label) ->
              let active_param =
                match List.assoc_opt "activeParameter" fields with
                | Some (Int value) -> value
                | _ ->
                    Alcotest.fail "signature response missing activeParameter"
              in
              (label, active_param)
          | _ -> Alcotest.fail "signature response missing label")
      | _, _ -> Alcotest.fail "signature response missing signatures")
  | Null -> Alcotest.fail "expected signature response, got null"
  | _ -> Alcotest.fail "unexpected signature response shape"

let signature_at state uri ~line ~character =
  fst (signature_response_at state uri ~line ~character)

let test_signature_help_uses_parsed_multiline_call_span () =
  let state, uri =
    analyzed_state
      (String.concat "\n"
         [
           "func combine(a: Int, b: Int, c: Int, d: Int, e: Int, f: Int) -> \
            Int:";
           "    f";
           "";
           "func main(args: List[String]) -> Int:";
           "    combine(";
           "        1,";
           "        2,";
           "        3,";
           "        4,";
           "        5,";
           "        6";
           "    )";
         ])
  in
  let label, active_param =
    signature_response_at state uri ~line:10 ~character:9
  in
  Alcotest.(check string)
    "signature finds call whose opening paren is beyond text fallback window"
    "func combine(a: Int, b: Int, c: Int, d: Int, e: Int, f: Int) -> Int" label;
  Alcotest.(check int) "sixth argument is active" 5 active_param

let test_signature_help_uses_resolved_method_call_metadata () =
  let state, uri =
    analyzed_state
      (String.concat "\n"
         [
           "func bump(value: Int, amount: Int) -> Int:";
           "    value + amount";
           "";
           "func main(args: List[String]) -> Int:";
           "    1.bump(2)";
         ])
  in
  let label, active_param =
    signature_response_at state uri ~line:4 ~character:12
  in
  Alcotest.(check string)
    "method syntax resolves to source function signature"
    "func bump(value: Int, amount: Int) -> Int" label;
  Alcotest.(check int)
    "visible method argument maps after receiver parameter" 1 active_param

let test_signature_help_preserves_resolved_qualified_call_name () =
  Test_helpers.with_isolated_env (fun () ->
      let state, uri =
        analyzed_state_unisolated
          (String.concat "\n"
             [
               "import:";
               "    list as L";
               "";
               "func main(args: List[String]) -> Int:";
               "    values = L.append([1], 2)";
               "    0";
             ])
      in
      let label, active_param =
        signature_response_at state uri ~line:4 ~character:27
      in
      Alcotest.(check string)
        "qualified call metadata keeps alias/member lookup"
        "pure func append(self: List[T], elem: T) -> List[T]" label;
      Alcotest.(check int) "second qualified argument is active" 1 active_param)

let test_signature_help_prefers_nested_parsed_call () =
  let state, uri =
    analyzed_state
      (String.concat "\n"
         [
           "func inner(left: Int, right: Int) -> Int:";
           "    left + right";
           "";
           "func outer(value: Int, fallback: Int) -> Int:";
           "    value";
           "";
           "func main(args: List[String]) -> Int:";
           "    outer(inner(1, 2), 3)";
         ])
  in
  let label, active_param =
    signature_response_at state uri ~line:7 ~character:20
  in
  Alcotest.(check string)
    "inner call is selected over enclosing outer call"
    "func inner(left: Int, right: Int) -> Int" label;
  Alcotest.(check int) "second inner parameter is active" 1 active_param

let test_signature_help_ignores_punctuation_inside_string_argument () =
  let state, uri =
    analyzed_state
      (String.concat "\n"
         [
           "func consume_text(text: String, fallback: Int) -> Int:";
           "    fallback";
           "";
           "func main(args: List[String]) -> Int:";
           "    consume_text(\"looks_like(inner, call)\", 2)";
         ])
  in
  let label, active_param =
    signature_response_at state uri ~line:4 ~character:31
  in
  Alcotest.(check string)
    "string punctuation stays inside the outer call argument"
    "func consume_text(text: String, fallback: Int) -> Int" label;
  Alcotest.(check int) "string argument is active" 0 active_param

let test_signature_help_text_fallback_for_incomplete_document () =
  let text = "    consume(1, " in
  let doc : Lsp_state.document =
    {
      uri = "file:///tmp/lsp_signature_incomplete.brp";
      version = 1;
      text;
      diagnostics = [];
      parse_errors = [];
      program = None;
      typed_program = None;
      env = None;
      module_aliases = [];
    }
  in
  match
    Lsp_signature.find_enclosing_call doc
      { Lsp_protocol.line = 0; character = String.length text }
  with
  | Some (name, active_param) ->
      Alcotest.(check string)
        "text fallback finds incomplete call" "consume" name;
      Alcotest.(check int)
        "text fallback counts active parameter" 1 active_param
  | None -> Alcotest.fail "expected text fallback to find incomplete call"

let test_signature_help_prefers_typed_source_signature () =
  let state, uri =
    analyzed_state
      {|
type alias UserId = Int

func consume(user_id: UserId, fallback: UserId) -> UserId:
    user_id

func main(args: List[String]) -> Int:
    consume(1, 2)
|}
  in
  let label = signature_at state uri ~line:7 ~character:15 in
  Alcotest.(check string)
    "signature keeps alias source spelling"
    "func consume(user_id: UserId, fallback: UserId) -> UserId" label

let test_signature_help_prefers_typed_private_source_signature () =
  let state, uri =
    analyzed_state
      {|
type alias UserId = Int

private func consume(user_id: UserId, fallback: UserId) -> UserId:
    user_id

func main(args: List[String]) -> Int:
    consume(1, 2)
|}
  in
  let label = signature_at state uri ~line:7 ~character:15 in
  Alcotest.(check string)
    "private signature keeps alias source spelling"
    "func consume(user_id: UserId, fallback: UserId) -> UserId" label

let suite =
  [
    ( "format",
      [
        Alcotest.test_case "prefers typed source signature" `Quick
          test_signature_help_prefers_typed_source_signature;
        Alcotest.test_case "prefers typed private source signature" `Quick
          test_signature_help_prefers_typed_private_source_signature;
        Alcotest.test_case "uses parsed multiline call span" `Quick
          test_signature_help_uses_parsed_multiline_call_span;
        Alcotest.test_case "uses resolved method call metadata" `Quick
          test_signature_help_uses_resolved_method_call_metadata;
        Alcotest.test_case "preserves resolved qualified call name" `Quick
          test_signature_help_preserves_resolved_qualified_call_name;
        Alcotest.test_case "prefers nested parsed call" `Quick
          test_signature_help_prefers_nested_parsed_call;
        Alcotest.test_case "ignores string punctuation in parsed call" `Quick
          test_signature_help_ignores_punctuation_inside_string_argument;
        Alcotest.test_case "text fallback handles incomplete document" `Quick
          test_signature_help_text_fallback_for_incomplete_document;
      ] );
  ]
