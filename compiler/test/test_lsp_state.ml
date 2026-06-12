(** Unit tests for LSP document state. *)

open Blorp

let document ?(module_aliases = []) ~uri text : Lsp_state.document =
  let doc = Lsp_state.create_document ~uri ~version:1 ~text () in
  doc.module_aliases <- module_aliases;
  doc

let analyze_doc source =
  Test_helpers.with_isolated_env (fun () ->
      let uri = "file:///tmp/lsp_state.brp" in
      let state = Lsp_state.create () in
      let doc = document ~uri source in
      Lsp_state.analyze state doc;
      doc)

let rec find_project_root dir =
  let has_repo_markers =
    Sys.file_exists (Filename.concat dir "blorp.toml")
    && Sys.file_exists (Filename.concat dir "std")
  in
  if has_repo_markers then dir
  else
    let parent = Filename.dirname dir in
    if parent = dir then
      Alcotest.failf "could not find project root from %s" (Sys.getcwd ());
    find_project_root parent

let analyze_file path source =
  Test_helpers.with_isolated_env (fun () ->
      let uri = Lsp_protocol.path_to_uri path in
      let state = Lsp_state.create () in
      let doc = document ~uri source in
      Lsp_state.analyze state doc;
      doc)

let write_file path contents =
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out oc)
    (fun () -> output_string oc contents)

let rec remove_tree path =
  if Sys.file_exists path then
    if Sys.is_directory path then begin
      Sys.readdir path
      |> Array.iter (fun name -> remove_tree (Filename.concat path name));
      Unix.rmdir path
    end
    else Sys.remove path

let with_temp_project f =
  let root = Filename.temp_file "blorp-lsp-state" "" in
  Sys.remove root;
  Unix.mkdir root 0o700;
  Fun.protect ~finally:(fun () -> remove_tree root) (fun () -> f root)

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
        "source program cleared" true
        (doc.source_program = None);
      Alcotest.(check bool)
        "typed program cleared" true (doc.typed_program = None);
      Alcotest.(check bool) "env cleared" true (doc.env = None))

let test_std_source_uses_stdlib_origin () =
  let root = find_project_root (Sys.getcwd ()) in
  let path = Filename.concat root "std/int.brp" in
  let source = Modules.read_file path in
  let doc = analyze_file path source in
  let builtin_policy_error =
    List.exists
      (fun (err : Ast.compiler_error) ->
        Test_helpers.contains_substring err.message
          "can only be used in the standard library")
      doc.diagnostics
  in
  Alcotest.(check bool)
    "std files allow builtin declarations in LSP analysis" false
    builtin_policy_error

let test_loaded_module_callback_types_share_import_origins () =
  with_temp_project (fun root ->
      write_file
        (Filename.concat root "json_fields.brp")
        (String.concat "\n"
           [
             "import:";
             "    json: JsonValue";
             "";
             "pure func apply_json[T](";
             "    value: JsonValue,";
             "    parse_item: pure (JsonValue) -> Result[T, String],";
             ") -> Result[T, String]:";
             "    parse_item(value)";
             "";
           ]);
      write_file
        (Filename.concat root "type_documents.brp")
        (String.concat "\n"
           [
             "import:";
             "    json: JsonValue";
             "";
             "pure func parse_type(value: JsonValue) -> Result[Int, String]:";
             "    Ok(1)";
             "";
           ]);
      let main_path = Filename.concat root "main.brp" in
      let source =
        String.concat "\n"
          [
            "import:";
            "    ./json_fields: apply_json";
            "    ./type_documents: parse_type";
            "    json: JsonValue";
            "";
            "pure func parse(value: JsonValue) -> Result[Int, String]:";
            "    value.apply_json(parse_type)";
            "";
          ]
      in
      let doc = analyze_file main_path source in
      Alcotest.(check string)
        "LSP analysis keeps std JsonValue identity across loaded modules" ""
        (Test_helpers.format_errors doc.diagnostics))

let test_reuses_unchanged_import_parse_cache_between_lsp_analyses () =
  with_temp_project (fun root ->
      let helper_path = Filename.concat root "helper.brp" in
      write_file helper_path
        (String.concat "\n" [ "func value() -> Int:"; "    1"; "" ]);
      let main_path = Filename.concat root "main.brp" in
      let source =
        String.concat "\n"
          [
            "import:";
            "    ./helper: value";
            "";
            "func main(args: List[String]) -> Int:";
            "    value()";
            "";
          ]
      in
      let uri = Lsp_protocol.path_to_uri main_path in
      let state = Lsp_state.create () in
      let doc = document ~uri source in
      Lsp_state.analyze state doc;
      Alcotest.(check string)
        "first analysis has no diagnostics" ""
        (Test_helpers.format_errors doc.diagnostics);
      let first_entry = Hashtbl.find doc.session.parse_cache "./helper" in
      Lsp_state.analyze state doc;
      Alcotest.(check string)
        "second analysis has no diagnostics" ""
        (Test_helpers.format_errors doc.diagnostics);
      let second_entry = Hashtbl.find doc.session.parse_cache "./helper" in
      Alcotest.(check bool)
        "unchanged imported module parse cache entry was reused" true
        (first_entry == second_entry))

let test_replaces_changed_import_parse_cache_between_lsp_analyses () =
  with_temp_project (fun root ->
      let helper_path = Filename.concat root "helper.brp" in
      write_file helper_path
        (String.concat "\n" [ "func value() -> Int:"; "    1"; "" ]);
      let main_path = Filename.concat root "main.brp" in
      let source =
        String.concat "\n"
          [
            "import:";
            "    ./helper: value";
            "";
            "func main(args: List[String]) -> Int:";
            "    value()";
            "";
          ]
      in
      let uri = Lsp_protocol.path_to_uri main_path in
      let state = Lsp_state.create () in
      let doc = document ~uri source in
      Lsp_state.analyze state doc;
      Alcotest.(check string)
        "first analysis has no diagnostics" ""
        (Test_helpers.format_errors doc.diagnostics);
      let first_entry = Hashtbl.find doc.session.parse_cache "./helper" in
      write_file helper_path
        (String.concat "\n" [ "func value() -> String:"; "    \"oops\""; "" ]);
      Lsp_state.analyze state doc;
      let second_entry = Hashtbl.find doc.session.parse_cache "./helper" in
      Alcotest.(check bool)
        "changed imported module parse cache entry was replaced" false
        (first_entry == second_entry);
      Alcotest.(check bool)
        "changed imported module diagnostics are visible" true
        (doc.diagnostics <> []))

let test_prunes_dropped_user_import_parse_cache_after_lsp_analysis () =
  with_temp_project (fun root ->
      let helper_path = Filename.concat root "helper.brp" in
      write_file helper_path
        (String.concat "\n" [ "func value() -> Int:"; "    1"; "" ]);
      let main_path = Filename.concat root "main.brp" in
      let source_with_import =
        String.concat "\n"
          [
            "import:";
            "    ./helper: value";
            "";
            "func main(args: List[String]) -> Int:";
            "    value()";
            "";
          ]
      in
      let source_without_import =
        String.concat "\n"
          [ "func main(args: List[String]) -> Int:"; "    0"; "" ]
      in
      let uri = Lsp_protocol.path_to_uri main_path in
      let state = Lsp_state.create () in
      let doc = document ~uri source_with_import in
      Lsp_state.analyze state doc;
      Alcotest.(check bool)
        "imported user module is cached" true
        (Hashtbl.mem doc.session.parse_cache "./helper");
      let edited_doc =
        Lsp_state.create_document ~session:doc.session ~uri ~version:2
          ~text:source_without_import ()
      in
      Lsp_state.analyze state edited_doc;
      Alcotest.(check bool)
        "dropped user import parse cache entry is pruned" false
        (Hashtbl.mem edited_doc.session.parse_cache "./helper"))

let suite =
  [
    ( "state",
      [
        Alcotest.test_case "module aliases include qualified imports" `Quick
          test_module_aliases_include_qualified_imports;
        Alcotest.test_case "parse error clears stale analysis state" `Quick
          test_parse_error_clears_stale_analysis_state;
        Alcotest.test_case "std source uses stdlib origin" `Quick
          test_std_source_uses_stdlib_origin;
        Alcotest.test_case "loaded module callback types share import origins"
          `Quick test_loaded_module_callback_types_share_import_origins;
        Alcotest.test_case
          "reuses unchanged import parse cache between LSP analyses" `Quick
          test_reuses_unchanged_import_parse_cache_between_lsp_analyses;
        Alcotest.test_case
          "replaces changed import parse cache between LSP analyses" `Quick
          test_replaces_changed_import_parse_cache_between_lsp_analyses;
        Alcotest.test_case
          "prunes dropped user import parse cache after LSP analysis" `Quick
          test_prunes_dropped_user_import_parse_cache_after_lsp_analysis;
      ] );
  ]
