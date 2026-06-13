(** Unit tests for LSP server request handlers. *)

open Blorp

let with_temp_output_channel f =
  let path = Filename.temp_file "blorp-lsp-server-test" ".out" in
  Fun.protect
    ~finally:(fun () -> try Sys.remove path with Sys_error _ -> ())
    (fun () ->
      let oc = open_out path in
      Fun.protect ~finally:(fun () -> close_out_noerr oc) (fun () -> f oc))

let text_document_change_params uri ~version ~text =
  Lsp_json.Object
    [
      ("textDocument", Object [ ("uri", String uri); ("version", Int version) ]);
      ("contentChanges", Array [ Object [ ("text", String text) ] ]);
    ]

let document_text state uri =
  match Lsp_state.find_document state uri with
  | Some doc -> doc.text
  | None -> Alcotest.fail "expected document to be tracked"

let test_initialize_records_location_link_capabilities () =
  let state = Lsp_state.create () in
  let params =
    Lsp_json.Object
      [
        ( "capabilities",
          Object
            [
              ( "textDocument",
                Object
                  [
                    ("definition", Object [ ("linkSupport", Bool true) ]);
                    ("declaration", Object [ ("linkSupport", Bool true) ]);
                    ("typeDefinition", Object [ ("linkSupport", Bool true) ]);
                  ] );
            ] );
      ]
  in
  let _ = Lsp_server.handle_initialize state params in
  Alcotest.(check bool)
    "definition links" true state.client_capabilities.definition_link_support;
  Alcotest.(check bool)
    "declaration links" true state.client_capabilities.declaration_link_support;
  Alcotest.(check bool)
    "type definition links" true
    state.client_capabilities.type_definition_link_support

let test_did_change_opens_untracked_document_with_change_text () =
  Test_helpers.with_isolated_env (fun () ->
      let state = Lsp_state.create () in
      let uri = "file:///tmp/lsp_server_change.brp" in
      let text =
        String.concat "\n"
          [ "func main(args: List[String]) -> Int:"; "    0"; "" ]
      in
      with_temp_output_channel (fun oc ->
          Lsp_server.handle_did_change state oc
            (text_document_change_params uri ~version:3 ~text));
      Alcotest.(check string)
        "untracked didChange uses contentChanges text" text
        (document_text state uri))

let suite =
  [
    ( "handlers",
      [
        Alcotest.test_case "initialize records location link capabilities"
          `Quick test_initialize_records_location_link_capabilities;
        Alcotest.test_case
          "didChange opens untracked document with contentChanges text" `Quick
          test_did_change_opens_untracked_document_with_change_text;
      ] );
  ]
