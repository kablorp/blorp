let compiler_blorp_rel file =
  Filename.concat (Filename.concat "compiler" "blorp") file

let compiler_lib_dir_rel = Filename.concat "compiler" "lib"
let compiler_tool_tests_dir_rel = compiler_blorp_rel "tests"

let find_project_file rel =
  let rec search dir depth =
    let candidate = Filename.concat dir rel in
    if Sys.file_exists candidate then candidate
    else if depth = 0 then
      Alcotest.failf "Cannot locate %s from CWD=%s" rel (Sys.getcwd ())
    else
      let parent = Filename.dirname dir in
      if parent = dir then
        Alcotest.failf "Cannot locate %s from CWD=%s" rel (Sys.getcwd ())
      else search parent (depth - 1)
  in
  search (Sys.getcwd ()) 12

let read_file path =
  let channel = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr channel)
    (fun () ->
      let len = in_channel_length channel in
      really_input_string channel len)

let contains_sub haystack needle =
  let needle_len = String.length needle in
  let haystack_len = String.length haystack in
  let rec loop index =
    if index + needle_len > haystack_len then false
    else if String.sub haystack index needle_len = needle then true
    else loop (index + 1)
  in
  needle_len = 0 || loop 0

let rec collect_ml_files dir =
  Sys.readdir dir |> Array.to_list
  |> List.concat_map (fun entry ->
         let path = Filename.concat dir entry in
         if Sys.is_directory path then collect_ml_files path
         else if Filename.check_suffix path ".ml" then [ path ]
         else [])

let test_template_substitution_supports_multi_digit_placeholders () =
  let manifest =
    Blorp.Core_emit_blorp_template.create ~label:"test template"
      "multi\t11\t@10@:@0@:@9@\n"
  in
  let args =
    [
      "arg0";
      "arg1";
      "arg2";
      "arg3";
      "arg4";
      "arg5";
      "arg6";
      "arg7";
      "arg8";
      "arg9";
      "arg10";
    ]
  in
  let rendered =
    Blorp.Core_emit_blorp_template.render_exn manifest "multi" args
  in
  Alcotest.(check string)
    "multi-digit placeholder output" "arg10:arg0:arg9" rendered

let test_json_bridge_renders_static_constant () =
  let request =
    Blorp.Compiler_blorp_bridge.request_json ~action:"render"
      ~renderer:"static_constant" ~op:"static_string_global_pointer"
      ~args:[ "GREETING"; "__blorp_static_string_GREETING" ] ()
  in
  let response =
    Blorp.Compiler_blorp_bridge.render_request_json request |> Blorp.Lsp_json.parse
  in
  Alcotest.(check (option string))
    "rendered text"
    (Some
       "static blorp_String* GREETING = \
        (blorp_String*)&__blorp_static_string_GREETING;")
    (Blorp.Lsp_json.get_string "text" response)

let test_json_bridge_reports_errors_as_json () =
  let request =
    Blorp.Compiler_blorp_bridge.request_json ~action:"render"
      ~renderer:"missing" ~op:"anything" ()
  in
  let response =
    Blorp.Compiler_blorp_bridge.render_request_json request |> Blorp.Lsp_json.parse
  in
  let message =
    match Blorp.Lsp_json.get "error" response with
    | Some error -> Blorp.Lsp_json.get_string "message" error
    | None -> None
  in
  Alcotest.(check (option string))
    "error message" (Some "unsupported Blorp renderer: missing") message

let test_json_bridge_renders_core_fairness_policy () =
  let request =
    Blorp.Compiler_blorp_bridge.request_json ~action:"render"
      ~renderer:Blorp.Compiler_blorp_bridge.core_fairness_renderer
      ~op:"fairness_body_other" ()
  in
  let response =
    Blorp.Compiler_blorp_bridge.render_request_json request |> Blorp.Lsp_json.parse
  in
  Alcotest.(check (option string))
    "rendered policy" (Some "false")
    (Blorp.Lsp_json.get_string "text" response)

let test_json_bridge_renders_language_surface_table () =
  let request =
    Blorp.Compiler_blorp_bridge.request_json ~action:"render"
      ~renderer:Blorp.Compiler_blorp_bridge.language_surface_renderer
      ~op:"language_lsp_completion_keywords" ()
  in
  let response =
    Blorp.Compiler_blorp_bridge.render_request_json request |> Blorp.Lsp_json.parse
  in
  Alcotest.(check (option string))
    "rendered table"
    (Some
       "func;pure;var;union;record;void;while;for;in;if;else;and;or;not;match;True;False;break;continue;debug;struct;enum;with;resource;foreign;private;builtin;concurrent;concurrently;detach;select;into;from;after;sealed;import;as;trait;implements;Self;type;alias;where")
    (Blorp.Lsp_json.get_string "text" response)

let test_json_bridge_renders_language_surface_batch () =
  let rendered =
    Blorp.Compiler_blorp_bridge.render_many_exn
      ~renderer:Blorp.Compiler_blorp_bridge.language_surface_renderer
      [
        ("language_lsp_completion_keywords", []);
        ("language_prelude_method_type_imports", []);
      ]
  in
  Alcotest.(check (option string))
    "keywords"
    (Some
       "func;pure;var;union;record;void;while;for;in;if;else;and;or;not;match;True;False;break;continue;debug;struct;enum;with;resource;foreign;private;builtin;concurrent;concurrently;detach;select;into;from;after;sealed;import;as;trait;implements;Self;type;alias;where")
    (List.assoc_opt "language_lsp_completion_keywords" rendered);
  Alcotest.(check (option string))
    "prelude imports"
    (Some
       "option:Option;result:Result;bool:Bool;char:Char;bytes:Bytes;string:String;list:List;list:ParallelList;parallel_list:ParallelList;vector:ParallelVector;parallel_vector:ParallelVector;matrix:ParallelMatrix;parallel_matrix:ParallelMatrix;range:Range;dict:Dict;set:Set;file:FileReader;file:FileWriter;file:FileAppender;file:FileReadWriter;file:FileReadAppender")
    (List.assoc_opt "language_prelude_method_type_imports" rendered)

let test_compiler_bridge_command_renders_batch () =
  let repo_root = Filename.dirname (find_project_file "Makefile") in
  let blorp = Filename.concat repo_root "blorp" in
  let request =
    Blorp.Compiler_blorp_bridge.render_many_request_json
      ~renderer:Blorp.Compiler_blorp_bridge.language_surface_renderer
      [
        ("language_lsp_completion_keywords", []);
        ("language_prelude_method_type_imports", []);
      ]
  in
  let response =
    Blorp.Compiler_blorp_bridge.run_request_via_command ~program:blorp request
    |> Blorp.Lsp_json.parse
  in
  let ok =
    match Blorp.Lsp_json.get "ok" response with
    | Some (Blorp.Lsp_json.Bool value) -> value
    | _ -> false
  in
  Alcotest.(check bool) "command response ok" true ok;
  let rendered =
    match Blorp.Compiler_blorp_bridge.render_many_response_field response with
    | Ok items -> items
    | Error (_, message) -> Alcotest.fail message
  in
  Alcotest.(check (option string))
    "command keywords"
    (Some
       "func;pure;var;union;record;void;while;for;in;if;else;and;or;not;match;True;False;break;continue;debug;struct;enum;with;resource;foreign;private;builtin;concurrent;concurrently;detach;select;into;from;after;sealed;import;as;trait;implements;Self;type;alias;where")
    (List.assoc_opt "language_lsp_completion_keywords" rendered)

let test_compiler_bridge_command_compiles_source () =
  let repo_root = Filename.dirname (find_project_file "Makefile") in
  let blorp = Filename.concat repo_root "blorp" in
  let source =
    "func main(args: List[String]) -> Int:\n\t0\n"
  in
  match
    Blorp.Compiler_blorp_bridge.compile_source_via_command ~program:blorp
      ~filename:"compiler_bridge_compile_source.brp" ~source ~debug:false
      ~embed_runtime:false ~require_main:true ~profile:false
      ~check_invariants:false ()
  with
  | Error (_, message) -> Alcotest.fail message
  | Ok result ->
      Alcotest.(check bool)
        "generated C includes main" true
        (contains_sub result.Blorp.Compiler_blorp_bridge.command_c_code "int main");
      Alcotest.(check (list string))
        "link flags" [] result.command_link_flags;
      Alcotest.(check (list string))
        "include dirs" [] result.command_include_dirs

let test_language_surface_uses_command_handoff () =
  Alcotest.(check bool)
    "keywords loaded" true
    (List.mem "func" (Blorp.Language_surface.lsp_completion_keywords ()));
  Alcotest.(check (list string))
    "prelude modules"
    [
      "option";
      "result";
      "bool";
      "char";
      "bytes";
      "string";
      "list";
      "parallel_list";
      "vector";
      "parallel_vector";
      "matrix";
      "parallel_matrix";
      "range";
      "dict";
      "set";
      "file";
    ]
    (Blorp.Language_surface.prelude_ufcs_modules ())

let test_blorp_template_manifest_access_stays_in_bridge () =
  let lib_dir = find_project_file compiler_lib_dir_rel in
  let allowed =
    [ "compiler_blorp_bridge.ml"; "core_emit_blorp_template.ml" ]
  in
  let forbidden_patterns =
    [
      "Core_emit_blorp_template.create";
      "Core_emit_blorp_template.render_exn";
      "Core_emit_blorp_template.emit";
      "Core_emit_blorp_template.find";
      "Core_emit_blorp_template.names";
      "Core_emit_blorp_intrinsic_templates.tsv";
      "Core_emit_blorp_static_constant_templates.tsv";
      "Core_emit_blorp_prepared_backend_templates.tsv";
      "Core_emit_blorp_prepared_list_templates.tsv";
      "Core_emit_blorp_prepared_tensor_templates.tsv";
      "Core_emit_blorp_prepared_constructor_templates.tsv";
      "Core_emit_blorp_prepared_tuple_templates.tsv";
      "Core_fairness_blorp_policy_templates.tsv";
      "Language_surface_blorp_templates.tsv";
    ]
  in
  let offenders =
    collect_ml_files lib_dir
    |> List.filter_map (fun path ->
           let basename = Filename.basename path in
           if List.mem basename allowed then None
           else
             let source = read_file path in
             match List.find_opt (contains_sub source) forbidden_patterns with
             | None -> None
             | Some pattern ->
                 Some
                   (Filename.concat (Filename.basename lib_dir) basename ^ ":"
                  ^ pattern))
    |> List.sort String.compare
  in
  Alcotest.(check (list string)) "direct template access" [] offenders

let test_compiler_blorp_test_suites () =
  let suite_path = find_project_file compiler_tool_tests_dir_rel in
  let test_files = Blorp.Test_runner.collect_test_files [ suite_path ] in
  Alcotest.(check bool)
    "discovers compiler/blorp TestSuite files" true (test_files <> []);
  let exit_code =
    Blorp.Test_runner.run_tests ~mode:Blorp.Test_runner.SuiteOnly
      ~timeout:(Some 30) ~jobs:1 ~cache:false suite_path
  in
  Alcotest.(check int) "compiler/blorp TestSuite exit code" 0 exit_code

let suite =
  [
    ( "core_emit_blorp_template",
      [
        Alcotest.test_case "substitutes multi-digit placeholders" `Quick
          test_template_substitution_supports_multi_digit_placeholders;
      ] );
    ( "compiler_blorp_bridge",
      [
        Alcotest.test_case "renders static constants through JSON" `Quick
          test_json_bridge_renders_static_constant;
        Alcotest.test_case "reports bridge errors as JSON" `Quick
          test_json_bridge_reports_errors_as_json;
        Alcotest.test_case "renders Core fairness policy through JSON" `Quick
          test_json_bridge_renders_core_fairness_policy;
        Alcotest.test_case "renders language surface table through JSON" `Quick
          test_json_bridge_renders_language_surface_table;
        Alcotest.test_case "renders language surface table as one JSON batch"
          `Quick test_json_bridge_renders_language_surface_batch;
        Alcotest.test_case "renders batch through compiler bridge command"
          `Quick test_compiler_bridge_command_renders_batch;
        Alcotest.test_case "compiles source through compiler bridge command"
          `Quick test_compiler_bridge_command_compiles_source;
        Alcotest.test_case "language surface uses command handoff" `Quick
          test_language_surface_uses_command_handoff;
        Alcotest.test_case "manifest access stays in bridge" `Quick
          test_blorp_template_manifest_access_stays_in_bridge;
      ] );
    ( "compiler_blorp_tests",
      [
        Alcotest.test_case "compiler/blorp TestSuites pass" `Slow
          test_compiler_blorp_test_suites;
      ] );
  ]
