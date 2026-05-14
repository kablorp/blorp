(** Unit tests for LSP signature help formatting. *)

open Blorp

let analyzed_state source =
  Test_helpers.with_isolated_env (fun () ->
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
      (state, uri))

let signature_at state uri ~line ~character =
  let params =
    Lsp_json.Object
      [
        ("textDocument", Object [ ("uri", String uri) ]);
        ("position", Object [ ("line", Int line); ("character", Int character) ]);
      ]
  in
  match Lsp_signature.handle_signature_help state params with
  | Object fields -> (
      match List.assoc_opt "signatures" fields with
      | Some (Array [ Object signature_fields ]) -> (
          match List.assoc_opt "label" signature_fields with
          | Some (String label) -> label
          | _ -> Alcotest.fail "signature response missing label")
      | _ -> Alcotest.fail "signature response missing signatures")
  | Null -> Alcotest.fail "expected signature response, got null"
  | _ -> Alcotest.fail "unexpected signature response shape"

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

let suite =
  [
    ( "format",
      [
        Alcotest.test_case "prefers typed source signature" `Quick
          test_signature_help_prefers_typed_source_signature;
      ] );
  ]
