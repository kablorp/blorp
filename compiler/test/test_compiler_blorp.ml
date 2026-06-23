let compiler_blorp_rel file =
  Filename.concat (Filename.concat "compiler" "blorp") file

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
    ( "compiler_blorp_tests",
      [
        Alcotest.test_case "compiler/blorp TestSuites pass" `Slow
          test_compiler_blorp_test_suites;
      ] );
  ]
