open Blorp

module Bridge = Blorp.Compiler_blorp_bridge

let contains haystack needle =
  let haystack_len = String.length haystack in
  let needle_len = String.length needle in
  let rec loop index =
    if needle_len = 0 then true
    else if index + needle_len > haystack_len then false
    else if String.sub haystack index needle_len = needle then true
    else loop (index + 1)
  in
  loop 0

let parse_json_exn text =
  try Lsp_json.parse text
  with Lsp_json.Parse_error message -> Alcotest.fail ("invalid JSON: " ^ message)

let object_fields = function
  | Lsp_json.Object fields -> fields
  | _ -> Alcotest.fail "expected JSON object"

let field name value =
  match List.assoc_opt name (object_fields value) with
  | Some field -> field
  | None -> Alcotest.fail ("missing JSON field " ^ name)

let string_field name value =
  match field name value with
  | Lsp_json.String text -> text
  | _ -> Alcotest.fail ("expected string JSON field " ^ name)

let bool_field name value =
  match field name value with
  | Lsp_json.Bool flag -> flag
  | _ -> Alcotest.fail ("expected bool JSON field " ^ name)

let array_field name value =
  match field name value with
  | Lsp_json.Array items -> items
  | _ -> Alcotest.fail ("expected array JSON field " ^ name)

let expect_invalid_response_contains expected = function
  | Ok _ -> Alcotest.fail "expected invalid bridge response"
  | Error ("invalid_response", message) ->
      if not (contains message expected) then
        Alcotest.fail
          ("expected invalid response containing " ^ expected ^ ", got " ^ message)
  | Error (code, message) ->
      Alcotest.fail
        ("expected invalid_response, got " ^ code ^ ": " ^ message)

let with_env name value f =
  let old = Sys.getenv_opt name in
  Unix.putenv name value;
  Fun.protect
    ~finally:(fun () ->
      match old with
      | Some previous -> Unix.putenv name previous
      | None -> Unix.putenv name "")
    f

let parsed_program_json ?(diagnostics = []) decls =
  Lsp_json.Object
    [
      ("kind", Lsp_json.String "parsed_program");
      ( "source",
        Lsp_json.Object
          [
            ("kind", Lsp_json.String "source_file");
            ("path", Lsp_json.String "main.brp");
            ("module", Lsp_json.String "main");
            ("text", Lsp_json.String "");
          ] );
      ("decls", Lsp_json.Array decls);
      ("diagnostics", Lsp_json.Array diagnostics);
    ]

let typed_program_json ?(diagnostics = []) decls =
  Lsp_json.Object
    [
      ("kind", Lsp_json.String "typed_program");
      ( "source",
        Lsp_json.Object
          [
            ("kind", Lsp_json.String "source_file");
            ("path", Lsp_json.String "main.brp");
            ("module", Lsp_json.String "main");
            ("text", Lsp_json.String "");
          ] );
      ("decls", Lsp_json.Array decls);
      ("diagnostics", Lsp_json.Array diagnostics);
    ]

let span_json ?(path = "main.brp") ?(module_name = "main") start_offset
    start_column end_offset end_column =
  Lsp_json.Object
    [
      ("path", Lsp_json.String path);
      ("module", Lsp_json.String module_name);
      ("start_offset", Lsp_json.Int start_offset);
      ("start_line", Lsp_json.Int 1);
      ("start_column", Lsp_json.Int start_column);
      ("end_offset", Lsp_json.Int end_offset);
      ("end_line", Lsp_json.Int 1);
      ("end_column", Lsp_json.Int end_column);
    ]

let diagnostic_json ?(severity = "error") ?(expected = []) ?help ~message
    span =
  Lsp_json.Object
    [
      ("severity", Lsp_json.String severity);
      ("span", span);
      ("message", Lsp_json.String message);
      ("expected", Lsp_json.Array (List.map (fun s -> Lsp_json.String s) expected));
      ( "help",
        match help with
        | Some text -> Lsp_json.String text
        | None -> Lsp_json.Null );
    ]

let bridge_success_json artifact =
  Lsp_json.to_string
    (Lsp_json.Object
       [
         ("schema", Lsp_json.Int Blorp.Compiler_blorp_bridge.schema_version);
         ("ok", Lsp_json.Bool true);
         ("artifact", artifact);
       ])

let string_array values = Lsp_json.Array (List.map (fun s -> Lsp_json.String s) values)

let module_surface_symbol_source_json ?method_index kind decl_index =
  let fields =
    [ ("kind", Lsp_json.String kind); ("decl_index", Lsp_json.Int decl_index) ]
    @
    match method_index with
    | Some value -> [ ("method_index", Lsp_json.Int value) ]
    | None -> []
  in
  Lsp_json.Object fields

let module_surface_symbol_json ?(kind = "function") ?(source_kind = "decl")
    ?method_index ?(decl_index = 0) name =
  Lsp_json.Object
    [
      ("name", Lsp_json.String name);
      ("kind", Lsp_json.String kind);
      ( "source",
        module_surface_symbol_source_json ?method_index source_kind decl_index );
    ]

let module_surface_import_json module_path =
  Lsp_json.Object [ ("module_path", Lsp_json.String module_path) ]

let module_surface_json ?(imports = []) ?(exports = [])
    ?(private_names = []) ?(private_traits = []) module_name =
  Lsp_json.Object
    [
      ("kind", Lsp_json.String "module_surface");
      ("module", Lsp_json.String module_name);
      ("imports", Lsp_json.Array (List.map module_surface_import_json imports));
      ("exports", Lsp_json.Array exports);
      ("private_names", Lsp_json.Array private_names);
      ("private_traits", string_array private_traits);
    ]

let parsed_ast_artifact ?(ast_phase = "raw_parse") ?comments ?module_surface
    program =
  let base_fields =
    match comments with
    | Some values ->
        [
          ("ast_phase", Lsp_json.String ast_phase);
          ("parsed_ast", program);
          ("comments", Lsp_json.Array values);
        ]
    | None ->
        [ ("ast_phase", Lsp_json.String ast_phase); ("parsed_ast", program) ]
  in
  let fields =
    match module_surface with
    | Some surface -> base_fields @ [ ("module_surface", surface) ]
    | None -> base_fields
  in
  Lsp_json.Object fields

let compile_options_json files =
  Lsp_json.Object
    [
      ("kind", Lsp_json.String "compile");
      ("ast_only", Lsp_json.Bool false);
      ("dump_ast", Lsp_json.Bool false);
      ("dump_typed_ast", Lsp_json.Bool false);
      ("dump_core_after", Lsp_json.Array []);
      ("dump_file", Lsp_json.Null);
      ("stop_after", Lsp_json.Null);
      ("time_phases", Lsp_json.Bool false);
      ("check_invariants", Lsp_json.Bool false);
      ("debug", Lsp_json.Bool false);
      ("no_format", Lsp_json.Bool true);
      ("embed_runtime", Lsp_json.Bool true);
      ("std_dir", Lsp_json.Null);
      ("output", Lsp_json.Null);
      ("files", string_array files);
    ]

let test_options_json paths =
  Lsp_json.Object
    [
      ("kind", Lsp_json.String "test");
      ("profile", Lsp_json.Bool true);
      ("debug", Lsp_json.Bool true);
      ("sanitizer", Lsp_json.String "undefined");
      ("leak_check", Lsp_json.Bool true);
      ("no_format", Lsp_json.Bool true);
      ("timeout", Lsp_json.Int 5);
      ("jobs", Lsp_json.Int 8);
      ("repeat", Lsp_json.Int 3);
      ("mode", Lsp_json.String "doc");
      ("cache", Lsp_json.Bool false);
      ("std_dir", Lsp_json.String "custom-std");
      ("paths", string_array paths);
    ]

let purify_options_json paths =
  Lsp_json.Object
    [
      ("kind", Lsp_json.String "purify");
      ("dry_run", Lsp_json.Bool true);
      ("verbose", Lsp_json.Bool true);
      ("paths", string_array paths);
    ]

let comment_json ~text ~line ~column ~trailing =
  Lsp_json.Object
    [
      ("text", Lsp_json.String text);
      ("line", Lsp_json.Int line);
      ("column", Lsp_json.Int column);
      ("trailing", Lsp_json.Bool trailing);
    ]

let test_renderer_bridge_compile_renames_generated_main () =
  let args =
    Blorp.Compiler_blorp_bridge.renderer_bridge_compile_object_args
      ~c_path:"bridge.c" ~obj_path:"bridge.o"
  in
  Alcotest.(check bool)
    "generated bridge main is renamed" true
    (List.exists
       (( = )
          ("-Dmain=" ^ Blorp.Compiler_blorp_bridge.renderer_bridge_user_main_symbol))
       args);
  Alcotest.(check bool) "compiles to object" true (List.exists (( = ) "-c") args)

let test_renderer_bridge_link_uses_wrapper_main () =
  let args =
    Blorp.Compiler_blorp_bridge.renderer_bridge_link_args ~obj_path:"bridge.o"
      ~wrapper_path:"bridge_main.c" ~bin_path:"bridge.bin"
  in
  Alcotest.(check bool)
    "links generated object" true
    (List.exists (( = ) "bridge.o") args);
  Alcotest.(check bool)
    "links wrapper source" true
    (List.exists (( = ) "bridge_main.c") args);
  Alcotest.(check bool)
    "links pthread for stack wrapper" true
    (List.exists (( = ) "-lpthread") args)

let test_renderer_bridge_wrapper_sets_explicit_stack () =
  let source = Blorp.Compiler_blorp_bridge.renderer_bridge_wrapper_source () in
  Alcotest.(check bool)
    "sets pthread stack size" true
    (contains source "pthread_attr_setstacksize");
  Alcotest.(check bool)
    "uses configured stack size" true
    (contains source
       (string_of_int
          Blorp.Compiler_blorp_bridge.renderer_bridge_stack_size_bytes));
  Alcotest.(check bool)
    "calls renamed generated entrypoint" true
    (contains source Blorp.Compiler_blorp_bridge.renderer_bridge_user_main_symbol)

let test_bridge_helper_compile_env_supports_pinned_bootstrap () =
  let env = Blorp.Compiler_blorp_bridge.bridge_helper_compile_env in
  Alcotest.(check (option string))
    "renderer helper marker" (Some "1")
    (List.assoc_opt Blorp.Compiler_blorp_bridge.renderer_bridge_helper_env env);
  Alcotest.(check (option string))
    "retired bootstrap parser selector" (Some "ocaml")
    (List.assoc_opt "BLORP_FRONTEND_PARSER" env)

let test_parser_bridge_compile_env_supports_pinned_bootstrap () =
  let env = Blorp.Compiler_blorp_bridge.parser_bridge_helper_compile_env in
  Alcotest.(check (option string))
    "renderer helper marker" (Some "1")
    (List.assoc_opt Blorp.Compiler_blorp_bridge.renderer_bridge_helper_env env);
  Alcotest.(check (option string))
    "retired bootstrap parser selector" (Some "ocaml")
    (List.assoc_opt "BLORP_FRONTEND_PARSER" env)

let test_typecheck_bridge_compile_env_supports_pinned_bootstrap () =
  let env = Blorp.Compiler_blorp_bridge.typecheck_bridge_helper_compile_env in
  Alcotest.(check (option string))
    "renderer helper marker" (Some "1")
    (List.assoc_opt Blorp.Compiler_blorp_bridge.renderer_bridge_helper_env env);
  Alcotest.(check (option string))
    "retired bootstrap parser selector" (Some "ocaml")
    (List.assoc_opt "BLORP_FRONTEND_PARSER" env)

let test_parse_source_request_uses_bridge_envelope () =
  let request =
    Blorp.Compiler_blorp_bridge.parse_source_request_json_at_phase
      ~phase:Blorp.Compiler_blorp_bridge.RawParsedProgram
      ~path:"src/main.brp" ~module_name:"main" ~text:"func main(): 0"
    |> parse_json_exn
  in
  Alcotest.(check string) "domain" "compiler" (string_field "domain" request);
  Alcotest.(check string)
    "action" "parse_source" (string_field "action" request);
  let payload = field "payload" request in
  Alcotest.(check string)
    "path" "src/main.brp" (string_field "path" payload);
  Alcotest.(check string) "module" "main" (string_field "module" payload);
  Alcotest.(check string) "text" "func main(): 0" (string_field "text" payload);
  Alcotest.(check string)
    "phase" "raw_parse" (string_field "ast_phase" payload)

let test_parse_source_file_request_omits_source_text () =
  let request =
    Blorp.Compiler_blorp_bridge.parse_source_file_request_json_at_phase
      ~phase:Blorp.Compiler_blorp_bridge.RawParsedProgram
      ~path:"src/main.brp" ~module_name:"main"
    |> parse_json_exn
  in
  Alcotest.(check string) "domain" "compiler" (string_field "domain" request);
  Alcotest.(check string)
    "action" "parse_source" (string_field "action" request);
  let payload = field "payload" request in
  Alcotest.(check string)
    "path" "src/main.brp" (string_field "path" payload);
  Alcotest.(check string) "module" "main" (string_field "module" payload);
  Alcotest.(check string)
    "phase" "raw_parse" (string_field "ast_phase" payload);
  match List.assoc_opt "text" (object_fields payload) with
  | None -> ()
  | Some _ -> Alcotest.fail "path-only parse request must omit source text"

let test_parse_source_request_can_use_typecheck_phase () =
  let request =
    Blorp.Compiler_blorp_bridge.parse_source_request_json_at_phase
      ~phase:Blorp.Compiler_blorp_bridge.TypecheckSourceProgram
      ~path:"src/main.brp" ~module_name:"main" ~text:"func main(): 0"
    |> parse_json_exn
  in
  let payload = field "payload" request in
  Alcotest.(check string)
    "phase" "typecheck_source" (string_field "ast_phase" payload)

let test_parse_source_file_request_can_use_typecheck_phase () =
  let request =
    Blorp.Compiler_blorp_bridge.parse_source_file_request_json_at_phase
      ~phase:Blorp.Compiler_blorp_bridge.TypecheckSourceProgram
      ~path:"src/main.brp" ~module_name:"main"
    |> parse_json_exn
  in
  let payload = field "payload" request in
  Alcotest.(check string)
    "phase" "typecheck_source" (string_field "ast_phase" payload)

let test_parse_sources_request_uses_bridge_envelope () =
  let request =
    Blorp.Compiler_blorp_bridge.parse_sources_request_json
      [
        {
          Bridge.batch_parse_path = "src/a.brp";
          batch_parse_module_name = "a";
          batch_parse_text = "a = 1";
        };
        {
          Bridge.batch_parse_path = "src/b.brp";
          batch_parse_module_name = "b";
          batch_parse_text = "b = 2";
        };
      ]
    |> parse_json_exn
  in
  Alcotest.(check string) "domain" "compiler" (string_field "domain" request);
  Alcotest.(check string)
    "action" "parse_sources" (string_field "action" request);
  let payload = field "payload" request in
  Alcotest.(check bool)
    "batch parse omits comments" false
    (bool_field "include_comments" payload);
  match array_field "sources" payload with
  | [ first; second ] ->
      Alcotest.(check string)
        "first path" "src/a.brp" (string_field "path" first);
      Alcotest.(check string) "first module" "a" (string_field "module" first);
      Alcotest.(check string) "first text" "a = 1" (string_field "text" first);
      Alcotest.(check string)
        "first phase" "raw_parse" (string_field "ast_phase" first);
      Alcotest.(check string)
        "second path" "src/b.brp" (string_field "path" second);
      Alcotest.(check string)
        "second module" "b" (string_field "module" second);
      Alcotest.(check string)
        "second text" "b = 2" (string_field "text" second);
      Alcotest.(check string)
        "second phase" "raw_parse" (string_field "ast_phase" second)
  | _ -> Alcotest.fail "expected two parse source request items"

let test_parse_sources_request_can_use_typecheck_phase () =
  let request =
    Blorp.Compiler_blorp_bridge.parse_sources_request_json
      ~phase:Blorp.Compiler_blorp_bridge.TypecheckSourceProgram
      [
        {
          Bridge.batch_parse_path = "src/a.brp";
          batch_parse_module_name = "a";
          batch_parse_text = "a = 1";
        };
      ]
    |> parse_json_exn
  in
  let payload = field "payload" request in
  match array_field "sources" payload with
  | [ first ] ->
      Alcotest.(check string)
        "phase" "typecheck_source" (string_field "ast_phase" first)
  | _ -> Alcotest.fail "expected one parse source request item"

let test_typecheck_graph_request_uses_single_graph_envelope () =
  let target =
    {
      Bridge.typecheck_import_path = "src/main.brp";
      typecheck_import_module_name = "main";
      typecheck_import_module_path = "main";
      typecheck_import_text = "import:\n\tdep: answer\n";
      typecheck_import_origin = Bridge.CliFrontendUserModule;
    }
  in
  let dependency =
    {
      Bridge.typecheck_import_path = "src/dep.brp";
      typecheck_import_module_name = "dep";
      typecheck_import_module_path = "dep";
      typecheck_import_text = "pure func answer() -> Int: 1\n";
      typecheck_import_origin = Bridge.CliFrontendUserModule;
    }
  in
  let request =
    Bridge.typecheck_graph_request_json_with_policy ~resolved_imports:[]
      ~allow_debug_only_calls:false ~target ~modules:[ dependency ]
      ~module_targets:[ "dep" ]
    |> parse_json_exn
  in
  Alcotest.(check string)
    "action" "typecheck_graph" (string_field "action" request);
  let payload = field "payload" request in
  Alcotest.(check string)
    "target path" "src/main.brp" (string_field "path" (field "target" payload));
  match array_field "modules" payload with
  | [ first ] ->
      Alcotest.(check string)
        "dependency path" "src/dep.brp" (string_field "path" first);
      (match array_field "module_targets" payload with
      | [ Lsp_json.String target ] ->
          Alcotest.(check string) "module target" "dep" target
      | _ -> Alcotest.fail "expected one graph module target")
  | _ -> Alcotest.fail "expected one graph module"

let test_cli_run_request_uses_bridge_envelope () =
  let request =
    Blorp.Compiler_blorp_bridge.cli_run_request_json
      [ "format"; "--check"; "main.brp" ]
    |> parse_json_exn
  in
  Alcotest.(check string) "domain" "compiler" (string_field "domain" request);
  Alcotest.(check string) "action" "run_cli" (string_field "action" request);
  let payload = field "payload" request in
  match array_field "args" payload with
  | [ Lsp_json.String "format"; Lsp_json.String "--check"; Lsp_json.String "main.brp" ] ->
      ()
  | _ -> Alcotest.fail "expected CLI args in payload"

let test_cli_run_request_can_include_version_context () =
  let request =
    Blorp.Compiler_blorp_bridge.cli_run_request_json ~version:"blorp test"
      [ "--version" ]
    |> parse_json_exn
  in
  Alcotest.(check string) "domain" "compiler" (string_field "domain" request);
  Alcotest.(check string) "action" "run_cli" (string_field "action" request);
  let payload = field "payload" request in
  match array_field "args" payload with
  | [ Lsp_json.String "--version" ] ->
      Alcotest.(check string) "version" "blorp test"
        (string_field "version" payload)
  | _ -> Alcotest.fail "expected CLI args in payload"

let test_parse_source_response_decodes_parsed_ast_artifact () =
  let response = bridge_success_json (parsed_ast_artifact (parsed_program_json [])) in
  match Blorp.Compiler_blorp_bridge.parse_source_response_json response with
  | Ok
      (Blorp.Compiler_blorp_bridge.ParsedSource
        {
          parsed_program = [];
          parsed_comments = [];
          parsed_phase = Blorp.Compiler_blorp_bridge.RawParsedProgram;
          parsed_module_surface = None;
        }) ->
      ()
  | Ok (Blorp.Compiler_blorp_bridge.ParsedSource _) ->
      Alcotest.fail "expected empty decoded program"
  | Ok (Blorp.Compiler_blorp_bridge.ParseSourceDiagnostics _) ->
      Alcotest.fail "expected decoded program, got diagnostics"
  | Error (_, message) -> Alcotest.fail message

let test_parse_source_response_decodes_comments () =
  let response =
    bridge_success_json
      (parsed_ast_artifact
         ~comments:[ comment_json ~text:"-- note" ~line:2 ~column:3 ~trailing:false ]
         (parsed_program_json []))
  in
  match Blorp.Compiler_blorp_bridge.parse_source_response_json response with
  | Ok
      (Blorp.Compiler_blorp_bridge.ParsedSource
        {
          parsed_program = [];
          parsed_comments = [ comment ];
          parsed_phase = Blorp.Compiler_blorp_bridge.RawParsedProgram;
          parsed_module_surface = None;
        }) ->
      Alcotest.(check string)
        "comment text" "-- note" comment.Bridge.cc_text;
      Alcotest.(check int) "comment line" 2 comment.Bridge.cc_line;
      Alcotest.(check int) "comment column" 3 comment.Bridge.cc_col;
      Alcotest.(check bool)
        "comment trailing" false comment.Bridge.cc_trailing
  | Ok (Blorp.Compiler_blorp_bridge.ParsedSource _) ->
      Alcotest.fail "expected one decoded comment"
  | Ok (Blorp.Compiler_blorp_bridge.ParseSourceDiagnostics _) ->
      Alcotest.fail "expected decoded program, got diagnostics"
  | Error (_, message) -> Alcotest.fail message

let test_parse_source_response_decodes_module_surface () =
  let response =
    bridge_success_json
      (parsed_ast_artifact
         ~module_surface:
           (module_surface_json ~imports:[ "option" ]
              ~exports:
                [
                  module_surface_symbol_json "main";
                  module_surface_symbol_json ~kind:"trait_method"
                    ~source_kind:"trait_method" ~decl_index:1 ~method_index:0
                    "render";
                ]
              "main")
         (parsed_program_json []))
  in
  match Blorp.Compiler_blorp_bridge.parse_source_response_json response with
  | Ok
      (Blorp.Compiler_blorp_bridge.ParsedSource
        { parsed_module_surface = Some surface; _ }) ->
      Alcotest.(check string) "module" "main" surface.Module_surface.module_name;
      Alcotest.(check (list string))
        "imports" [ "option" ] (Module_surface.import_module_names surface);
      Alcotest.(check (list string))
        "exports" [ "main"; "render" ]
        (List.map
           (fun (symbol : Module_surface.symbol) -> symbol.name)
           surface.exports)
  | Ok (Blorp.Compiler_blorp_bridge.ParsedSource _) ->
      Alcotest.fail "expected decoded module surface"
  | Ok (Blorp.Compiler_blorp_bridge.ParseSourceDiagnostics _) ->
      Alcotest.fail "expected decoded program, got diagnostics"
  | Error (_, message) -> Alcotest.fail message

let test_parse_source_response_rejects_invalid_module_surface_kind () =
  let response =
    bridge_success_json
      (parsed_ast_artifact
         ~module_surface:
           (module_surface_json
              ~exports:[ module_surface_symbol_json ~kind:"mystery" "main" ]
              "main")
         (parsed_program_json []))
  in
  Blorp.Compiler_blorp_bridge.parse_source_response_json response
  |> expect_invalid_response_contains "unsupported module surface symbol kind"

let test_parse_source_response_returns_diagnostics () =
  let response =
    bridge_success_json
      (parsed_ast_artifact
         (parsed_program_json
            ~diagnostics:
              [
                diagnostic_json
                  ~message:"Expected ':' after if condition"
                  ~expected:[ ":" ]
                  ~help:"add `:` after the condition"
                  (span_json 3 4 5 6);
              ]
            []))
  in
  match Blorp.Compiler_blorp_bridge.parse_source_response_json response with
  | Ok (Blorp.Compiler_blorp_bridge.ParseSourceDiagnostics [ err ]) ->
      Alcotest.(check string)
        "message" "Expected ':' after if condition" err.Ast.message;
      Alcotest.(check int) "line" 1 err.loc.line;
      Alcotest.(check int) "column" 4 err.loc.column;
      Alcotest.(check (option string))
        "help" (Some "add `:` after the condition") err.help
  | Ok (Blorp.Compiler_blorp_bridge.ParseSourceDiagnostics _) ->
      Alcotest.fail "expected exactly one diagnostic"
  | Ok (Blorp.Compiler_blorp_bridge.ParsedSource _) ->
      Alcotest.fail "expected parse diagnostics"
  | Error (_, message) -> Alcotest.fail message

let typecheck_artifact ?(ast_phase = "typecheck_source") ?(type_errors = [])
    ?(import_bindings = []) ?ctfe_status ?comments ?module_surface typed_program =
  let optional_fields =
    (match comments with Some value -> [ ("comments", Lsp_json.Array value) ] | None -> [])
    @ (match ctfe_status with
      | Some value -> [ ("ctfe_status", Lsp_json.String value) ]
      | None -> [])
    @
    match module_surface with
    | Some value -> [ ("module_surface", value) ]
    | None -> []
  in
  Lsp_json.Object
    ([
       ("ast_phase", Lsp_json.String ast_phase);
       ("typed_program", typed_program);
       ("type_errors", string_array type_errors);
       ("import_bindings", Lsp_json.Array import_bindings);
     ]
    @ optional_fields)

let graph_source_artifact path module_name artifact =
  match artifact with
  | Lsp_json.Object fields ->
      Lsp_json.Object
        (("path", Lsp_json.String path)
        :: ("module", Lsp_json.String module_name)
        :: fields)
  | _ -> assert false

let typecheck_graph_source_artifact path module_name typed_program =
  typecheck_artifact ~ctfe_status:"evaluated" typed_program
  |> graph_source_artifact path module_name

let test_typecheck_graph_response_rejects_invalid_ctfe_status () =
  typecheck_artifact ~ctfe_status:"pending_ocaml" (typed_program_json [])
  |> graph_source_artifact "main.brp" "main"
  |> bridge_success_json
  |> Blorp.Compiler_blorp_bridge.typecheck_graph_source_response_json
  |> expect_invalid_response_contains "unsupported ctfe_status `pending_ocaml`"

let test_typecheck_graph_response_preserves_errors_for_invalid_typed_tree ()
    =
  let invalid_typed_program =
    typed_program_json
      [
        Lsp_json.Object
          [ ("kind", Lsp_json.String "not_a_decodable_typed_decl") ];
      ]
  in
  let response =
    typecheck_artifact
      ~type_errors:[ "Function 'bad' returns wrong type" ] invalid_typed_program
    |> graph_source_artifact "main.brp" "main"
    |> bridge_success_json
  in
  match Blorp.Compiler_blorp_bridge.typecheck_graph_source_response_json response with
  | Ok
      {
        Bridge.typechecked_graph_artifact =
          {
            typechecked_errors = [ "Function 'bad' returns wrong type" ];
            typechecked_program;
            typechecked_ctfe_evaluated_by_blorp = false;
            _;
          };
        _;
      } ->
      Alcotest.(check int)
        "fallback typed program decls" 0
        (List.length (Blorp.Typed_ast.program_decls typechecked_program))
  | Ok _ -> Alcotest.fail "expected typecheck errors to be preserved"
  | Error (_, message) -> Alcotest.fail message

let test_typecheck_graph_response_rejects_raw_phase () =
  typecheck_artifact ~ast_phase:"raw_parse" (typed_program_json [])
  |> graph_source_artifact "main.brp" "main"
  |> bridge_success_json
  |> Blorp.Compiler_blorp_bridge.typecheck_graph_source_response_json
  |> expect_invalid_response_contains
       "typecheck_source artifact must have ast_phase typecheck_source"

let test_typecheck_graph_stream_response_decodes_all_artifacts () =
  let response =
    String.concat "\n"
      [
        bridge_success_json
          (typecheck_graph_source_artifact "src/dep.brp" "dep"
             (typed_program_json []));
        bridge_success_json
          (typecheck_graph_source_artifact "src/main.brp" "main"
             (typed_program_json []));
      ]
  in
  match Bridge.typecheck_graph_stream_response_json ~module_count:1 response with
  | Ok
      {
        Bridge.typechecked_graph_modules =
          [
            {
              typechecked_graph_path = "src/dep.brp";
              typechecked_graph_module_name = "dep";
              _;
            };
          ];
        typechecked_graph_target =
          {
            typechecked_graph_path = "src/main.brp";
            typechecked_graph_module_name = "main";
            _;
          };
      } ->
      ()
  | Ok _ -> Alcotest.fail "expected one module and one target artifact"
  | Error (_, message) -> Alcotest.fail message

let test_typecheck_graph_stream_response_requires_target () =
  bridge_success_json
    (typecheck_graph_source_artifact "src/dep.brp" "dep"
       (typed_program_json []))
  |> Bridge.typecheck_graph_stream_response_json ~module_count:1
  |> expect_invalid_response_contains "expected one target"

let test_parse_sources_response_decodes_items () =
  let response =
    bridge_success_json
      (Lsp_json.Object
         [
           ( "sources",
             Lsp_json.Array
               [
                 Lsp_json.Object
                   [
                     ("ast_phase", Lsp_json.String "raw_parse");
                     ("path", Lsp_json.String "src/a.brp");
                     ("module", Lsp_json.String "a");
                     ("parsed_ast", parsed_program_json []);
                     ( "comments",
                       Lsp_json.Array
                         [
                           comment_json ~text:"-- batch" ~line:2 ~column:1
                             ~trailing:false;
                         ] );
                   ];
                 Lsp_json.Object
                   [
                     ("ast_phase", Lsp_json.String "raw_parse");
                     ("path", Lsp_json.String "src/b.brp");
                     ("module", Lsp_json.String "b");
                     ( "parsed_ast",
                       parsed_program_json
                         ~diagnostics:
                           [
                             diagnostic_json ~message:"Expected expression"
                               (span_json 1 2 3 4);
                           ]
                         [] );
                     ("comments", Lsp_json.Array []);
                   ];
               ] );
         ])
  in
  match Blorp.Compiler_blorp_bridge.parse_sources_response_json response with
  | Ok
      [
        {
          Bridge.batch_parsed_path = "src/a.brp";
          batch_parsed_module_name = "a";
          batch_parsed_response =
            Bridge.ParsedSource
              {
                parsed_program = [];
                parsed_comments = [ comment ];
                parsed_phase = Bridge.RawParsedProgram;
                parsed_module_surface = None;
              };
        };
        {
          Bridge.batch_parsed_path = "src/b.brp";
          batch_parsed_module_name = "b";
          batch_parsed_response = Bridge.ParseSourceDiagnostics [ err ];
        };
      ] ->
      Alcotest.(check string)
        "comment text" "-- batch" comment.Bridge.cc_text;
      Alcotest.(check string) "diagnostic" "Expected expression" err.Ast.message
  | Ok _ -> Alcotest.fail "expected one parsed item and one diagnostic item"
  | Error (_, message) -> Alcotest.fail message

let test_cli_run_response_decodes_handled () =
  let response =
    bridge_success_json
      (Lsp_json.Object
         [
           ("kind", Lsp_json.String "handled");
           ("status", Lsp_json.Int 1);
           ("stdout", Lsp_json.String "");
           ("stderr", Lsp_json.String "unknown format option: --bogus\n");
         ])
  in
  match Blorp.Compiler_blorp_bridge.cli_run_response_json response with
  | Ok
      (Blorp.Compiler_blorp_bridge.CliRunHandled
        {
          cli_run_status = 1;
          cli_run_stdout = "";
          cli_run_stderr = "unknown format option: --bogus\n";
        }) ->
      ()
  | Ok _ -> Alcotest.fail "expected decoded CLI handled result"
  | Error (_, message) -> Alcotest.fail message

let test_cli_run_response_decodes_delegate () =
  let response =
    bridge_success_json
      (Lsp_json.Object
         [
           ("kind", Lsp_json.String "delegate");
           ("args", string_array [ "repl" ]);
           ("io", Lsp_json.String "terminal");
         ])
  in
  match Blorp.Compiler_blorp_bridge.cli_run_response_json response with
  | Ok
      (Blorp.Compiler_blorp_bridge.CliRunDelegate
        {
          cli_run_delegate_args = [ "repl" ];
          cli_run_delegate_io =
            Blorp.Compiler_blorp_bridge.CliFrontendTerminalDelegation;
        }) ->
      ()
  | Ok _ -> Alcotest.fail "expected decoded CLI delegate"
  | Error (_, message) -> Alcotest.fail message

let test_cli_run_response_decodes_test_options () =
  let response =
    bridge_success_json
      (Lsp_json.Object
         [
           ("kind", Lsp_json.String "test");
           ( "args",
             string_array
               [
                 "test";
                 "--doc";
                 "--repeat";
                 "3";
                 "-j";
                 "8";
                 "--no-cache";
                 "--sanitize=undefined";
                 "--timeout";
                 "5";
                 "--std-dir";
                 "custom-std";
                 "--no-format";
                 "tests";
               ] );
           ("options", test_options_json [ "tests" ]);
         ])
  in
  match Blorp.Compiler_blorp_bridge.cli_run_response_json response with
  | Ok
      (Blorp.Compiler_blorp_bridge.CliRunTestOptions
        (Blorp.Compiler_blorp_bridge.CliTestRunOptions options)) ->
      Alcotest.(check (list string))
        "raw args"
        [
          "test";
          "--doc";
          "--repeat";
          "3";
          "-j";
          "8";
          "--no-cache";
          "--sanitize=undefined";
          "--timeout";
          "5";
          "--std-dir";
          "custom-std";
          "--no-format";
          "tests";
        ]
        options.cli_test_raw_args;
      Alcotest.(check bool) "profile" true options.cli_test_profile;
      Alcotest.(check bool) "debug" true options.cli_test_debug;
      Alcotest.(check bool) "leak check" true options.cli_test_leak_check;
      Alcotest.(check bool) "no format" true options.cli_test_no_format;
      Alcotest.(check (option int)) "timeout" (Some 5) options.cli_test_timeout;
      Alcotest.(check int) "jobs" 8 options.cli_test_jobs;
      Alcotest.(check int) "repeat" 3 options.cli_test_repeat;
      Alcotest.(check bool) "cache" false options.cli_test_cache;
      Alcotest.(check (option string))
        "std dir" (Some "custom-std") options.cli_test_std_dir;
      Alcotest.(check (list string)) "paths" [ "tests" ] options.cli_test_paths;
      Alcotest.(check bool)
        "sanitizer"
        true
        (options.cli_test_sanitizer
        = Some Blorp.Compiler_blorp_bridge.CliFrontendSanitizeUndefined);
      Alcotest.(check bool)
        "mode"
        true
        (options.cli_test_mode
        = Blorp.Compiler_blorp_bridge.CliFrontendTestDocOnly)
  | Ok _ -> Alcotest.fail "expected decoded CLI test options"
  | Error (_, message) -> Alcotest.fail message

let frontend_origin_json ?package kind =
  let fields =
    [ ("kind", Lsp_json.String kind) ]
    @
    match package with
    | Some value -> [ ("package", Lsp_json.String value) ]
    | None -> []
  in
  Lsp_json.Object fields

let frontend_graph_source ?(ast_phase = "typecheck_source")
    ?(origin = frontend_origin_json "user") ?(include_module_surface = true)
    path module_name text =
  let module_surface =
    if include_module_surface then Some (module_surface_json module_name)
    else None
  in
  Lsp_json.Object
    [
      ("path", Lsp_json.String path);
      ("module", Lsp_json.String module_name);
      ("source_text", Lsp_json.String text);
      ( "parsed_source",
        parsed_ast_artifact ~ast_phase ?module_surface (parsed_program_json [])
      );
      ("origin", origin);
    ]

let frontend_source_package_json ?(alias = "sample") ?(name = "sample")
    ?(root = "vendor/sample") ?(source_dir = "vendor/sample/src")
    ?(exports = [ "sample" ]) () =
  Lsp_json.Object
    [
      ("alias", Lsp_json.String alias);
      ("name", Lsp_json.String name);
      ("root", Lsp_json.String root);
      ("source_dir", Lsp_json.String source_dir);
      ("exports", string_array exports);
    ]

let frontend_graph_context_json ?std_dir ?(source_packages = [])
    ?(package_roots = []) () =
  Lsp_json.Object
    [
      ( "std_dir",
        match std_dir with
        | Some path -> Lsp_json.String path
        | None -> Lsp_json.Null );
      ("source_packages", Lsp_json.Array source_packages);
      ("package_roots", string_array package_roots);
    ]

let frontend_import_edge ?resolved_path ?resolved_module ?resolved_origin
    ~from_path ~from_module ~import_path () =
  Lsp_json.Object
    [
      ("from_path", Lsp_json.String from_path);
      ("from_module", Lsp_json.String from_module);
      ("import_path", Lsp_json.String import_path);
      ( "resolved_path",
        match resolved_path with
        | Some path -> Lsp_json.String path
        | None -> Lsp_json.Null );
      ( "resolved_module",
        match resolved_module with
        | Some module_name -> Lsp_json.String module_name
        | None -> Lsp_json.Null );
      ( "resolved_origin",
        match resolved_origin with
        | Some origin -> origin
        | None -> Lsp_json.Null );
    ]

let test_cli_run_response_decodes_frontend_module_graph () =
  let response =
    bridge_success_json
      (Lsp_json.Object
         [
           ("kind", Lsp_json.String "frontend_module_graph");
           ("command", Lsp_json.String "compile");
           ("args", string_array [ "compile"; "--no-format"; "src/main.brp" ]);
           ("options", compile_options_json [ "src/main.brp" ]);
           ( "context",
             frontend_graph_context_json ~std_dir:"custom-std"
               ~source_packages:[ frontend_source_package_json () ]
               ~package_roots:[ "pkg" ] () );
           ( "roots",
             Lsp_json.Array
               [
                 frontend_graph_source "src/main.brp" "main"
                   "import:\n\t./dep";
               ] );
           ( "modules",
             Lsp_json.Array
               [
                 frontend_graph_source "src/dep.brp" "./dep" "func dep(): 1";
               ] );
           ( "imports",
             Lsp_json.Array
               [
                 frontend_import_edge ~from_path:"src/main.brp"
                   ~from_module:"main" ~import_path:"./dep"
                   ~resolved_path:"src/dep.brp" ~resolved_module:"./dep"
                   ~resolved_origin:(frontend_origin_json "user") ();
               ] );
           ("diagnostics", Lsp_json.Array []);
         ])
  in
  match Blorp.Compiler_blorp_bridge.cli_run_response_json response with
  | Ok
      (Blorp.Compiler_blorp_bridge.CliRunFrontendModuleGraph
        {
          cli_frontend_graph_command = Blorp.Compiler_blorp_bridge.CliFrontendCompile;
          cli_frontend_graph_args = [ "compile"; "--no-format"; "src/main.brp" ];
          cli_frontend_graph_options =
            Blorp.Compiler_blorp_bridge.CliFrontendCompileOptions
              { cli_compile_files = [ "src/main.brp" ]; _ };
          cli_frontend_graph_context =
            {
              cli_frontend_context_std_dir = Some "custom-std";
              cli_frontend_context_source_packages =
                [
                  {
                    cli_frontend_source_package_alias = "sample";
                    cli_frontend_source_package_name = "sample";
                    cli_frontend_source_package_root = "vendor/sample";
                    cli_frontend_source_package_source_dir =
                      "vendor/sample/src";
                    cli_frontend_source_package_exports = [ "sample" ];
                  };
                ];
              cli_frontend_context_package_roots = [ "pkg" ];
            };
          cli_frontend_graph_roots =
            [
              {
                cli_frontend_graph_path = "src/main.brp";
                cli_frontend_graph_module_name = "main";
                cli_frontend_graph_origin =
                  Blorp.Compiler_blorp_bridge.CliFrontendUserModule;
                _;
              };
            ];
          cli_frontend_graph_modules =
            [
              {
                cli_frontend_graph_path = "src/dep.brp";
                cli_frontend_graph_module_name = "./dep";
                cli_frontend_graph_origin =
                  Blorp.Compiler_blorp_bridge.CliFrontendUserModule;
                _;
              };
            ];
          cli_frontend_graph_imports =
            [
              {
                cli_frontend_import_from_module = "main";
                cli_frontend_import_path = "./dep";
                cli_frontend_import_resolved_path = Some "src/dep.brp";
                cli_frontend_import_resolved_module = Some "./dep";
                _;
              };
            ];
          cli_frontend_graph_diagnostics = [];
        }) ->
      ()
  | Ok _ -> Alcotest.fail "expected decoded frontend module graph"
  | Error (_, message) -> Alcotest.fail message

let test_cli_run_response_rejects_frontend_graph_missing_resolved_target () =
  let response =
    bridge_success_json
      (Lsp_json.Object
         [
           ("kind", Lsp_json.String "frontend_module_graph");
           ("command", Lsp_json.String "compile");
           ("args", string_array [ "compile"; "--no-format"; "src/main.brp" ]);
           ("options", compile_options_json [ "src/main.brp" ]);
           ("context", frontend_graph_context_json ());
           ( "roots",
             Lsp_json.Array
               [ frontend_graph_source "src/main.brp" "main" "import:\n\t./dep" ]
           );
           ("modules", Lsp_json.Array []);
           ( "imports",
             Lsp_json.Array
               [
                 frontend_import_edge ~from_path:"src/main.brp"
                   ~from_module:"main" ~import_path:"./dep"
                   ~resolved_path:"src/dep.brp" ~resolved_module:"./dep"
                   ~resolved_origin:(frontend_origin_json "user") ();
               ] );
           ("diagnostics", Lsp_json.Array []);
         ])
  in
  Blorp.Compiler_blorp_bridge.cli_run_response_json response
  |> expect_invalid_response_contains "absent from the graph"

let test_cli_run_response_rejects_raw_frontend_graph_source () =
  let response =
    bridge_success_json
      (Lsp_json.Object
         [
           ("kind", Lsp_json.String "frontend_module_graph");
           ("command", Lsp_json.String "compile");
           ("args", string_array [ "compile"; "--no-format"; "src/main.brp" ]);
           ("options", compile_options_json [ "src/main.brp" ]);
           ("context", frontend_graph_context_json ());
           ( "roots",
             Lsp_json.Array
               [
                 frontend_graph_source ~ast_phase:"raw_parse" "src/main.brp"
                   "main" "func main(args: List[String]) -> Int: 0";
               ] );
           ("modules", Lsp_json.Array []);
           ("imports", Lsp_json.Array []);
           ("diagnostics", Lsp_json.Array []);
         ])
  in
  Blorp.Compiler_blorp_bridge.cli_run_response_json response
  |> expect_invalid_response_contains "frontend module graph source must be typecheck_source"

let test_cli_run_response_rejects_frontend_graph_missing_module_surface () =
  let response =
    bridge_success_json
      (Lsp_json.Object
         [
           ("kind", Lsp_json.String "frontend_module_graph");
           ("command", Lsp_json.String "compile");
           ("args", string_array [ "compile"; "--no-format"; "src/main.brp" ]);
           ("options", compile_options_json [ "src/main.brp" ]);
           ("context", frontend_graph_context_json ());
           ( "roots",
             Lsp_json.Array
               [
                 frontend_graph_source ~include_module_surface:false
                   "src/main.brp" "main"
                   "func main(args: List[String]) -> Int: 0";
               ] );
           ("modules", Lsp_json.Array []);
           ("imports", Lsp_json.Array []);
           ("diagnostics", Lsp_json.Array []);
         ])
  in
  Blorp.Compiler_blorp_bridge.cli_run_response_json response
  |> expect_invalid_response_contains
       "frontend module graph source must include module_surface"

let test_cli_run_response_rejects_legacy_parsed_source_artifact () =
  let response =
    bridge_success_json
      (Lsp_json.Object
         [
           ("kind", Lsp_json.String "parsed_source_batch");
         ])
  in
  Blorp.Compiler_blorp_bridge.cli_run_response_json response
  |> expect_invalid_response_contains
       "unsupported CLI run artifact kind `parsed_source_batch`"

let test_cli_run_response_rejects_legacy_frontend_options_artifact () =
  let response =
    bridge_success_json
      (Lsp_json.Object
         [
           ("kind", Lsp_json.String "frontend_options");
           ("command", Lsp_json.String "compile");
           ( "args",
             string_array [ "compile"; "--no-format"; "a.brp" ] );
           ("options", compile_options_json [ "a.brp" ]);
         ])
  in
  Blorp.Compiler_blorp_bridge.cli_run_response_json response
  |> expect_invalid_response_contains
       "unsupported CLI run artifact kind `frontend_options`"

let test_cli_run_response_decodes_purify_options () =
  let response =
    bridge_success_json
      (Lsp_json.Object
         [
           ("kind", Lsp_json.String "purify");
           ( "args",
             string_array [ "purify"; "--dry-run"; "--verbose"; "src" ] );
           ("options", purify_options_json [ "src" ]);
         ])
  in
  match Blorp.Compiler_blorp_bridge.cli_run_response_json response with
  | Ok
      (Blorp.Compiler_blorp_bridge.CliRunPurifyOptions
        {
          cli_purify_raw_args = [ "purify"; "--dry-run"; "--verbose"; "src" ];
          cli_purify_dry_run = true;
          cli_purify_verbose = true;
          cli_purify_paths = [ "src" ];
        }) ->
      ()
  | Ok _ -> Alcotest.fail "expected decoded CLI purify options"
  | Error (_, message) -> Alcotest.fail message

let test_cli_run_response_decodes_repl_options () =
  let response =
    bridge_success_json
      (Lsp_json.Object
         [
           ("kind", Lsp_json.String "repl");
           ("args", string_array [ "repl"; "--debug" ]);
           ("debug", Lsp_json.Bool true);
         ])
  in
  match Blorp.Compiler_blorp_bridge.cli_run_response_json response with
  | Ok
      (Blorp.Compiler_blorp_bridge.CliRunReplOptions
        { cli_repl_raw_args = [ "repl"; "--debug" ]; cli_repl_debug = true }) ->
      ()
  | Ok _ -> Alcotest.fail "expected decoded CLI repl options"
  | Error (_, message) -> Alcotest.fail message

let test_cli_run_response_decodes_lsp_options () =
  let response =
    bridge_success_json
      (Lsp_json.Object
         [ ("kind", Lsp_json.String "lsp"); ("args", string_array [ "lsp" ]) ])
  in
  match Blorp.Compiler_blorp_bridge.cli_run_response_json response with
  | Ok
      (Blorp.Compiler_blorp_bridge.CliRunLspOptions
        { cli_lsp_raw_args = [ "lsp" ] }) ->
      ()
  | Ok _ -> Alcotest.fail "expected decoded CLI lsp options"
  | Error (_, message) -> Alcotest.fail message

let test_cli_run_response_decodes_package_pack_options () =
  let response =
    bridge_success_json
      (Lsp_json.Object
         [
           ("kind", Lsp_json.String "package");
           ("args", string_array [ "package"; "pack"; "pkg"; "-o"; "pkg.blp" ]);
           ( "command",
             Lsp_json.Object
               [
                 ("kind", Lsp_json.String "pack");
                 ("path", Lsp_json.String "pkg");
                 ("output", Lsp_json.String "pkg.blp");
               ] );
         ])
  in
  match Blorp.Compiler_blorp_bridge.cli_run_response_json response with
  | Ok
      (Blorp.Compiler_blorp_bridge.CliRunPackageOptions
        {
          cli_package_raw_args = [ "package"; "pack"; "pkg"; "-o"; "pkg.blp" ];
          cli_package_command =
            Blorp.Compiler_blorp_bridge.CliPackagePack
              { path = "pkg"; output = "pkg.blp" };
        }) ->
      ()
  | Ok _ -> Alcotest.fail "expected decoded CLI package pack options"
  | Error (_, message) -> Alcotest.fail message

let test_cli_run_response_decodes_package_vendor_options () =
  let response =
    bridge_success_json
      (Lsp_json.Object
         [
           ("kind", Lsp_json.String "package");
           ("args", string_array [ "package"; "vendor"; "hash" ]);
           ( "command",
             Lsp_json.Object
               [
                 ("kind", Lsp_json.String "vendor_target");
                 ("target", Lsp_json.String "hash");
                 ("dest", Lsp_json.Null);
               ] );
         ])
  in
  match Blorp.Compiler_blorp_bridge.cli_run_response_json response with
  | Ok
      (Blorp.Compiler_blorp_bridge.CliRunPackageOptions
        {
          cli_package_raw_args = [ "package"; "vendor"; "hash" ];
          cli_package_command =
            Blorp.Compiler_blorp_bridge.CliPackageVendorTarget
              { target = "hash"; dest = None };
        }) ->
      ()
  | Ok _ -> Alcotest.fail "expected decoded CLI package vendor options"
  | Error (_, message) -> Alcotest.fail message

let test_cli_run_response_rejects_mismatched_frontend_args () =
  let response =
    bridge_success_json
      (Lsp_json.Object
         [
           ("kind", Lsp_json.String "frontend_module_graph");
           ("command", Lsp_json.String "compile");
           ("args", string_array [ "run"; "a.brp" ]);
           ("options", compile_options_json [ "a.brp" ]);
           ("context", frontend_graph_context_json ());
           ( "roots",
             Lsp_json.Array
               [
                 frontend_graph_source "a.brp" "a"
                   "func main(args: List[String]) -> Int: 0";
               ] );
           ("modules", Lsp_json.Array []);
           ("imports", Lsp_json.Array []);
           ("diagnostics", Lsp_json.Array []);
         ])
  in
  Blorp.Compiler_blorp_bridge.cli_run_response_json response
  |> expect_invalid_response_contains "expected `compile`"

let test_cli_run_response_rejects_mismatched_repl_args () =
  let response =
    bridge_success_json
      (Lsp_json.Object
         [
           ("kind", Lsp_json.String "repl");
           ("args", string_array [ "lsp" ]);
           ("debug", Lsp_json.Bool false);
         ])
  in
  Blorp.Compiler_blorp_bridge.cli_run_response_json response
  |> expect_invalid_response_contains "expected `repl`"

let test_cli_run_response_rejects_mismatched_package_args () =
  let response =
    bridge_success_json
      (Lsp_json.Object
         [
           ("kind", Lsp_json.String "package");
           ("args", string_array [ "package"; "vendor"; "hash" ]);
           ( "command",
             Lsp_json.Object
               [
                 ("kind", Lsp_json.String "pack");
                 ("path", Lsp_json.String "pkg");
                 ("output", Lsp_json.String "pkg.blp");
               ] );
         ])
  in
  Blorp.Compiler_blorp_bridge.cli_run_response_json response
  |> expect_invalid_response_contains "expected `pack`"

let write_file path contents =
  let channel = open_out_bin path in
  Fun.protect
    ~finally:(fun () -> close_out channel)
    (fun () -> output_string channel contents)

let mkdir path = try Unix.mkdir path 0o700 with Unix.Unix_error _ -> ()

let with_temp_dir f =
  let root = Filename.temp_file "blorp-bridge-test-" "" in
  Sys.remove root;
  Unix.mkdir root 0o700;
  Fun.protect
    ~finally:(fun () ->
      let rec remove path =
        match (Unix.lstat path).Unix.st_kind with
        | Unix.S_DIR ->
            Sys.readdir path
            |> Array.iter (fun name -> remove (Filename.concat path name));
            Unix.rmdir path
        | _ -> Sys.remove path
      in
      remove root)
    (fun () -> f root)

let test_bridge_helper_compiler_finds_pinned_bootstrap () =
  with_temp_dir (fun root ->
      let scripts_dir = Filename.concat root "scripts" in
      let nested_dir = Filename.concat root "nested" in
      let deeper_dir = Filename.concat nested_dir "deeper" in
      let bootstrap =
        Filename.concat scripts_dir "blorp-compiler-bootstrap"
      in
      mkdir scripts_dir;
      mkdir nested_dir;
      mkdir deeper_dir;
      write_file bootstrap "#!/usr/bin/env bash\n";
      match
        Blorp.Compiler_blorp_bridge.locate_bridge_helper_compiler
          ~bridge_bin:None [ deeper_dir ]
      with
      | Ok compiler ->
          Alcotest.(check string)
            "bootstrap path" bootstrap compiler.Bridge.helper_compiler_path
      | Error message -> Alcotest.fail message)

let test_bridge_helper_compiler_respects_explicit_override () =
  match
    Blorp.Compiler_blorp_bridge.locate_bridge_helper_compiler
      ~bridge_bin:(Some "/tmp/custom-blorp") [ "/does/not/exist" ]
  with
  | Ok compiler ->
      Alcotest.(check string)
        "explicit bridge binary" "/tmp/custom-blorp"
        compiler.Bridge.helper_compiler_path
  | Error message -> Alcotest.fail message

let test_bridge_helper_compiler_rejects_current_executable_override () =
  match
    Blorp.Compiler_blorp_bridge.locate_bridge_helper_compiler
      ~bridge_bin:(Some Sys.executable_name) [ "/does/not/exist" ]
  with
  | Ok compiler ->
      Alcotest.fail
        ("expected current executable override to be rejected, got "
       ^ compiler.Blorp.Compiler_blorp_bridge.helper_compiler_path)
  | Error message ->
      Alcotest.(check bool)
        "mentions current executable" true
        (contains message "current compiler executable")

let test_bridge_cache_key_includes_helper_entrypoint () =
  with_temp_dir (fun root ->
      let compiler_dir = Filename.concat root "compiler" in
      let blorp_dir = Filename.concat compiler_dir "blorp" in
      let src_dir = Filename.concat blorp_dir "src" in
      let cli_dir = Filename.concat src_dir "stage_12_cli" in
      let program = Filename.concat root "blorp" in
      let backend_source = Filename.concat cli_dir "compiler_bridge_cli.brp" in
      let parser_source =
        Filename.concat cli_dir "compiler_parser_bridge_cli.brp"
      in
      let typecheck_source =
        Filename.concat cli_dir "compiler_typecheck_bridge_cli.brp"
      in
      mkdir compiler_dir;
      mkdir blorp_dir;
      mkdir src_dir;
      mkdir cli_dir;
      write_file program "#!/usr/bin/env bash\n";
      write_file backend_source "func main(args: List[String]) -> Int: 0\n";
      write_file parser_source "func main(args: List[String]) -> Int: 0\n";
      write_file typecheck_source "func main(args: List[String]) -> Int: 0\n";
      let backend =
        Bridge.renderer_bridge_cache_parts ~program ~source_path:backend_source
      in
      let parser =
        Bridge.renderer_bridge_cache_parts ~program ~source_path:parser_source
      in
      let typecheck =
        Bridge.renderer_bridge_cache_parts ~program ~source_path:typecheck_source
      in
      Alcotest.(check bool)
        "backend and parser helpers use distinct cache keys" true
        (backend.bridge_key <> parser.bridge_key);
      Alcotest.(check bool)
        "parser and typecheck helpers use distinct cache keys" true
        (parser.bridge_key <> typecheck.bridge_key))

let test_bridge_cache_key_includes_std_sources () =
  with_temp_dir (fun root ->
      let compiler_dir = Filename.concat root "compiler" in
      let blorp_dir = Filename.concat compiler_dir "blorp" in
      let src_dir = Filename.concat blorp_dir "src" in
      let cli_dir = Filename.concat src_dir "stage_12_cli" in
      let std_dir = Filename.concat root "std" in
      let program = Filename.concat root "blorp" in
      let backend_source = Filename.concat cli_dir "compiler_bridge_cli.brp" in
      let std_source = Filename.concat std_dir "prelude.brp" in
      mkdir compiler_dir;
      mkdir blorp_dir;
      mkdir src_dir;
      mkdir cli_dir;
      mkdir std_dir;
      write_file program "#!/usr/bin/env bash\n";
      write_file backend_source "func main(args: List[String]) -> Int: 0\n";
      write_file std_source "pure func helper() -> Int: 1\n";
      let before =
        Bridge.renderer_bridge_cache_parts ~program ~source_path:backend_source
      in
      write_file std_source "pure func helper() -> Int: 2\n";
      let after =
        Bridge.renderer_bridge_cache_parts ~program ~source_path:backend_source
      in
      Alcotest.(check bool)
        "std source edits invalidate helper cache" true
        (before.bridge_key <> after.bridge_key))

let test_bridge_cache_key_includes_all_compiler_stages () =
  with_temp_dir (fun root ->
      let compiler_dir = Filename.concat root "compiler" in
      let blorp_dir = Filename.concat compiler_dir "blorp" in
      let src_dir = Filename.concat blorp_dir "src" in
      let cli_dir = Filename.concat src_dir "stage_12_cli" in
      let lex_dir = Filename.concat src_dir "stage_02_lex" in
      let program = Filename.concat root "blorp" in
      let backend_source = Filename.concat cli_dir "compiler_bridge_cli.brp" in
      let lex_source = Filename.concat lex_dir "compiler_token.brp" in
      mkdir compiler_dir;
      mkdir blorp_dir;
      mkdir src_dir;
      mkdir cli_dir;
      mkdir lex_dir;
      write_file program "#!/usr/bin/env bash\n";
      write_file backend_source "func main(args: List[String]) -> Int: 0\n";
      write_file lex_source "enum TokenA: One\n";
      let before =
        Bridge.renderer_bridge_cache_parts ~program ~source_path:backend_source
      in
      write_file lex_source "enum TokenA: One, Two\n";
      let after =
        Bridge.renderer_bridge_cache_parts ~program ~source_path:backend_source
      in
      Alcotest.(check bool)
        "non-entrypoint compiler stage edits invalidate helper cache" true
        (before.bridge_key <> after.bridge_key))

let test_prepared_bridge_binary_env_accepts_existing_file () =
  with_temp_dir (fun root ->
      let bin = Filename.concat root "prepared-bridge.bin" in
      write_file bin "#!/usr/bin/env bash\n";
      with_env Bridge.prepared_renderer_bridge_bin_env bin (fun () ->
          match
            Bridge.prepared_bridge_binary_from_env
              Bridge.prepared_renderer_bridge_bin_env
          with
          | Some (Ok path) ->
              Alcotest.(check string) "prepared bridge path" bin path
          | Some (Error message) ->
              Alcotest.fail ("unexpected prepared bridge error: " ^ message)
          | None -> Alcotest.fail "expected prepared bridge env to be used"))

let test_prepared_bridge_binary_env_rejects_missing_file () =
  let missing = "/tmp/blorp-prepared-bridge-does-not-exist" in
  with_env Bridge.prepared_renderer_bridge_bin_env missing (fun () ->
      match
        Bridge.prepared_bridge_binary_from_env
          Bridge.prepared_renderer_bridge_bin_env
      with
      | Some (Error message) ->
          Alcotest.(check bool)
            "mentions missing prepared bridge" true
            (contains message "missing Blorp bridge helper binary")
      | Some (Ok path) ->
          Alcotest.fail ("unexpected prepared bridge path: " ^ path)
      | None -> Alcotest.fail "expected prepared bridge env to be checked")

let test_renderer_bridge_binary_prefers_prepared_env () =
  with_temp_dir (fun root ->
      let bin = Filename.concat root "prepared-renderer.bin" in
      write_file bin "#!/usr/bin/env bash\n";
      with_env Bridge.prepared_renderer_bridge_bin_env bin (fun () ->
          match Bridge.renderer_bridge_binary () with
          | Ok path -> Alcotest.(check string) "prepared renderer path" bin path
          | Error message ->
              Alcotest.fail ("unexpected prepared renderer error: " ^ message)))

let test_renderer_bridge_binary_requires_prepared_env () =
  with_env Bridge.require_prepared_bridge_env "1" (fun () ->
      with_env Bridge.prepared_renderer_bridge_bin_env "" (fun () ->
          match Bridge.renderer_bridge_binary () with
          | Error message ->
              Alcotest.(check bool)
                "reports missing required prepared renderer" true
                (contains message Bridge.prepared_renderer_bridge_bin_env)
          | Ok path ->
              Alcotest.fail
                ("unexpected fallback renderer helper path: " ^ path)))

let test_generated_c_bootstrap_compatibility_adds_forward_typedefs () =
  let source =
    String.concat "\n"
      [
        "typedef struct compiler_parsed_ast__ParsedMatchCase {";
        "  compiler_parsed_ast__ParsedExpr* body;";
        "} compiler_parsed_ast__ParsedMatchCase;";
        "typedef struct compiler_parsed_ast__ParsedExpr {";
        "  long tag;";
        "} compiler_parsed_ast__ParsedExpr;";
        "";
      ]
  in
  let rewritten = Bridge.generated_c_with_bootstrap_compatibility source in
  Alcotest.(check bool)
    "adds forward typedef for referenced generated type" true
    (contains rewritten
       "typedef struct compiler_parsed_ast__ParsedExpr \
        compiler_parsed_ast__ParsedExpr;");
  Alcotest.(check bool)
    "preserves original struct definition" true
    (contains rewritten "typedef struct compiler_parsed_ast__ParsedExpr {")

let test_generated_c_bootstrap_compatibility_rewrites_enum_payload_tag_checks ()
    =
  let source =
    String.concat "\n"
      [
        "#define __def_527932_CompilerResolvedLoopProducerIndices 7L";
        "bool check(void* call) {";
        "  return (((compiler_infer__CompilerResolvedLoopProducer*)call)->tag == TAG_compiler_infer__CompilerResolvedLoopProducer_CompilerResolvedLoopProducerIndices);";
        "}";
        "";
      ]
  in
  let rewritten = Bridge.generated_c_with_bootstrap_compatibility source in
  Alcotest.(check bool)
    "removes old pointer tag check" false
    (contains rewritten
       "TAG_compiler_infer__CompilerResolvedLoopProducer_CompilerResolvedLoopProducerIndices");
  Alcotest.(check bool)
    "compares stack enum payload value" true
    (contains rewritten
       "((long)(long)call == \
        __def_527932_CompilerResolvedLoopProducerIndices)")

let test_generated_c_bootstrap_compatibility_preserves_union_tag_checks () =
  let source =
    String.concat "\n"
      [
        "#define __def_527932_SomeCase 7L";
        "typedef struct compiler_model__Payload compiler_model__Payload;";
        "bool check(compiler_model__Payload* value) {";
        "  return (((compiler_model__Payload*)value)->tag == TAG_compiler_model__Payload_SomeCase);";
        "}";
        "";
      ]
  in
  let rewritten = Bridge.generated_c_with_bootstrap_compatibility source in
  Alcotest.(check bool)
    "preserves boxed union tag check" true
    (contains rewritten "TAG_compiler_model__Payload_SomeCase")

let suite =
  [
    ( "renderer_bridge_build",
      [
        Alcotest.test_case "renames generated main" `Quick
          test_renderer_bridge_compile_renames_generated_main;
        Alcotest.test_case "links wrapper main" `Quick
          test_renderer_bridge_link_uses_wrapper_main;
        Alcotest.test_case "wrapper sets explicit stack" `Quick
          test_renderer_bridge_wrapper_sets_explicit_stack;
        Alcotest.test_case "helper compile env supports pinned bootstrap" `Quick
          test_bridge_helper_compile_env_supports_pinned_bootstrap;
        Alcotest.test_case "parser helper env supports pinned bootstrap" `Quick
          test_parser_bridge_compile_env_supports_pinned_bootstrap;
        Alcotest.test_case "typecheck helper env supports pinned bootstrap"
          `Quick test_typecheck_bridge_compile_env_supports_pinned_bootstrap;
        Alcotest.test_case "parse_source request uses bridge envelope" `Quick
          test_parse_source_request_uses_bridge_envelope;
        Alcotest.test_case "parse_source file request omits source text" `Quick
          test_parse_source_file_request_omits_source_text;
        Alcotest.test_case "parse_source request can use typecheck phase" `Quick
          test_parse_source_request_can_use_typecheck_phase;
        Alcotest.test_case
          "parse_source file request can use typecheck phase" `Quick
          test_parse_source_file_request_can_use_typecheck_phase;
        Alcotest.test_case "parse_sources request uses bridge envelope" `Quick
          test_parse_sources_request_uses_bridge_envelope;
        Alcotest.test_case "parse_sources request can use typecheck phase"
          `Quick test_parse_sources_request_can_use_typecheck_phase;
        Alcotest.test_case "typecheck_graph request uses one envelope" `Quick
          test_typecheck_graph_request_uses_single_graph_envelope;
        Alcotest.test_case "CLI run request uses bridge envelope" `Quick
          test_cli_run_request_uses_bridge_envelope;
        Alcotest.test_case "CLI run request can include version context" `Quick
          test_cli_run_request_can_include_version_context;
        Alcotest.test_case "parse_source response decodes parsed AST artifact"
          `Quick test_parse_source_response_decodes_parsed_ast_artifact;
        Alcotest.test_case "parse_source response decodes comments" `Quick
          test_parse_source_response_decodes_comments;
        Alcotest.test_case "parse_source response decodes module surface"
          `Quick test_parse_source_response_decodes_module_surface;
        Alcotest.test_case
          "parse_source response rejects invalid module surface kind" `Quick
          test_parse_source_response_rejects_invalid_module_surface_kind;
        Alcotest.test_case "parse_source response returns diagnostics" `Quick
          test_parse_source_response_returns_diagnostics;
        Alcotest.test_case
          "typecheck_graph response rejects invalid CTFE status" `Quick
          test_typecheck_graph_response_rejects_invalid_ctfe_status;
        Alcotest.test_case
          "typecheck_graph response preserves errors for invalid typed tree"
          `Quick
          test_typecheck_graph_response_preserves_errors_for_invalid_typed_tree;
        Alcotest.test_case "typecheck_graph response rejects raw phase" `Quick
          test_typecheck_graph_response_rejects_raw_phase;
        Alcotest.test_case "typecheck_graph stream decodes all artifacts" `Quick
          test_typecheck_graph_stream_response_decodes_all_artifacts;
        Alcotest.test_case "typecheck_graph stream requires target" `Quick
          test_typecheck_graph_stream_response_requires_target;
        Alcotest.test_case "parse_sources response decodes items" `Quick
          test_parse_sources_response_decodes_items;
        Alcotest.test_case "CLI run response decodes handled" `Quick
          test_cli_run_response_decodes_handled;
        Alcotest.test_case "CLI run response decodes delegate" `Quick
          test_cli_run_response_decodes_delegate;
        Alcotest.test_case "CLI run response decodes test options" `Quick
          test_cli_run_response_decodes_test_options;
        Alcotest.test_case "CLI run response decodes frontend module graph"
          `Quick test_cli_run_response_decodes_frontend_module_graph;
        Alcotest.test_case
          "CLI run response rejects frontend graph missing resolved target" `Quick
          test_cli_run_response_rejects_frontend_graph_missing_resolved_target;
        Alcotest.test_case
          "CLI run response rejects raw frontend graph source" `Quick
          test_cli_run_response_rejects_raw_frontend_graph_source;
        Alcotest.test_case
          "CLI run response rejects frontend graph missing module surface"
          `Quick
          test_cli_run_response_rejects_frontend_graph_missing_module_surface;
        Alcotest.test_case
          "CLI run response rejects legacy parsed source artifact" `Quick
          test_cli_run_response_rejects_legacy_parsed_source_artifact;
        Alcotest.test_case
          "CLI run response rejects legacy frontend options artifact" `Quick
          test_cli_run_response_rejects_legacy_frontend_options_artifact;
        Alcotest.test_case "CLI run response decodes purify options" `Quick
          test_cli_run_response_decodes_purify_options;
        Alcotest.test_case "CLI run response decodes repl options" `Quick
          test_cli_run_response_decodes_repl_options;
        Alcotest.test_case "CLI run response decodes lsp options" `Quick
          test_cli_run_response_decodes_lsp_options;
        Alcotest.test_case "CLI run response decodes package pack options" `Quick
          test_cli_run_response_decodes_package_pack_options;
        Alcotest.test_case "CLI run response decodes package vendor options"
          `Quick test_cli_run_response_decodes_package_vendor_options;
        Alcotest.test_case "CLI run response rejects mismatched frontend args"
          `Quick test_cli_run_response_rejects_mismatched_frontend_args;
        Alcotest.test_case "CLI run response rejects mismatched repl args"
          `Quick test_cli_run_response_rejects_mismatched_repl_args;
        Alcotest.test_case "CLI run response rejects mismatched package args"
          `Quick test_cli_run_response_rejects_mismatched_package_args;
        Alcotest.test_case "helper compiler finds pinned bootstrap" `Quick
          test_bridge_helper_compiler_finds_pinned_bootstrap;
        Alcotest.test_case "helper compiler respects explicit override" `Quick
          test_bridge_helper_compiler_respects_explicit_override;
        Alcotest.test_case "helper compiler rejects current executable override"
          `Quick test_bridge_helper_compiler_rejects_current_executable_override;
        Alcotest.test_case "cache key includes helper entrypoint" `Quick
          test_bridge_cache_key_includes_helper_entrypoint;
        Alcotest.test_case "cache key includes std sources" `Quick
          test_bridge_cache_key_includes_std_sources;
        Alcotest.test_case "cache key includes all compiler stages" `Quick
          test_bridge_cache_key_includes_all_compiler_stages;
        Alcotest.test_case "prepared env accepts existing helper" `Quick
          test_prepared_bridge_binary_env_accepts_existing_file;
        Alcotest.test_case "prepared env rejects missing helper" `Quick
          test_prepared_bridge_binary_env_rejects_missing_file;
        Alcotest.test_case "renderer helper prefers prepared env" `Quick
          test_renderer_bridge_binary_prefers_prepared_env;
        Alcotest.test_case "renderer helper requires prepared env" `Quick
          test_renderer_bridge_binary_requires_prepared_env;
        Alcotest.test_case "bootstrap compatibility adds forward typedefs"
          `Quick test_generated_c_bootstrap_compatibility_adds_forward_typedefs;
        Alcotest.test_case "bootstrap compatibility rewrites enum payload checks"
          `Quick
          test_generated_c_bootstrap_compatibility_rewrites_enum_payload_tag_checks;
        Alcotest.test_case "bootstrap compatibility preserves union tag checks"
          `Quick
          test_generated_c_bootstrap_compatibility_preserves_union_tag_checks;
      ] );
  ]
