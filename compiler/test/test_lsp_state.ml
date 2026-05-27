(** Unit tests for LSP document state. *)

open Blorp

let document ?(module_aliases = []) ~uri text : Lsp_state.document =
  {
    uri;
    version = 1;
    text;
    diagnostics = [];
    parse_errors = [];
    program = None;
    typed_program = None;
    env = None;
    module_aliases;
  }

let analyze_doc source =
  Test_helpers.with_isolated_env (fun () ->
      let uri = "file:///tmp/lsp_state.brp" in
      let state = Lsp_state.create () in
      let doc = document ~uri source in
      Lsp_state.analyze state doc;
      doc)

let test_module_aliases_include_qualified_imports () =
  let doc =
    analyze_doc
      (String.concat "\n"
         [
           "import:";
           "    option as O";
           "    list";
           "    dict: Dict";
           "";
           "func main(args: List[String]) -> Int:";
           "    0";
           "";
         ])
  in
  Alcotest.(check (list (pair string string)))
    "module aliases"
    [ ("O", "option"); ("list", "list") ]
    doc.module_aliases

let test_parse_error_clears_stale_analysis_state () =
  Test_helpers.with_isolated_env (fun () ->
      let uri = "file:///tmp/lsp_state_parse_error.brp" in
      let state = Lsp_state.create () in
      let doc =
        document ~uri ~module_aliases:[ ("stale", "option") ] "func main("
      in
      Lsp_state.analyze state doc;
      Alcotest.(check bool) "parse errors recorded" true (doc.parse_errors <> []);
      Alcotest.(check (list (pair string string)))
        "stale aliases cleared" [] doc.module_aliases;
      Alcotest.(check bool) "program cleared" true (doc.program = None);
      Alcotest.(check bool)
        "typed program cleared" true (doc.typed_program = None);
      Alcotest.(check bool) "env cleared" true (doc.env = None))

let suite =
  [
    ( "state",
      [
        Alcotest.test_case "module aliases include qualified imports" `Quick
          test_module_aliases_include_qualified_imports;
        Alcotest.test_case "parse error clears stale analysis state" `Quick
          test_parse_error_clears_stale_analysis_state;
      ] );
  ]
