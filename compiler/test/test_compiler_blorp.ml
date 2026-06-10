let compiler_tool_rel =
  Filename.concat
    (Filename.concat "compiler" "blorp")
    "codegen_intrinsic_renderer.brp"

let compiler_tool_tests_dir_rel =
  Filename.concat (Filename.concat "compiler" "blorp") "tests"

let compiler_intrinsic_template_manifest_rel =
  Filename.concat
    (Filename.concat "compiler" "lib")
    "core_emit_blorp_intrinsic_templates.tsv"

let core_emit_intrinsic_rel =
  Filename.concat (Filename.concat "compiler" "lib") "core_emit_intrinsic.ml"

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
  let ic = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in ic)
    (fun () -> really_input_string ic (in_channel_length ic))

let cc_args include_dirs link_flags =
  [ "-O0"; "-fwrapv"; "-w" ]
  @ List.concat_map (fun dir -> [ "-I"; dir ]) include_dirs
  @ [ "-lm"; "-lpthread" ]
  @ List.concat_map
      (fun flag -> String.split_on_char ' ' (String.trim flag))
      link_flags

let compile_codegen_intrinsic_renderer () =
  let compiler_tool_path = find_project_file compiler_tool_rel in
  let source = read_file compiler_tool_path in
  match
    Blorp.Pipeline.compile ~embed_runtime:true ~filename:compiler_tool_path
      ~source ()
  with
  | Error errors ->
      Alcotest.fail
        (Blorp.Diagnostics.format_errors ~file:compiler_tool_path errors)
  | Ok (Blorp.Pipeline.Stopped_at _) ->
      Alcotest.fail "compiler-blorp tool compilation stopped unexpectedly"
  | Ok (Blorp.Pipeline.Compiled { c_code; include_dirs; link_flags; _ }) ->
      let bin_file =
        Blorp.Test_runner.run_artifact_path ~kind:"compiler-blorp"
          ~prefix:"codegen-intrinsic-renderer" ~suffix:".bin"
      in
      let cc_result, cc_output =
        Blorp.Test_runner.compile_c_from_stdin c_code bin_file
          (cc_args include_dirs link_flags)
      in
      if cc_result <> 0 then
        Alcotest.fail
          ("failed to compile compiler-blorp tool C output\n"
         ^ String.trim cc_output)
      else bin_file

let run_tool bin args =
  Blorp.Test_runner.run_process_capture_timeout ~timeout:(Some 10) bin args

let assert_tool_success bin label args expected =
  let code, output = run_tool bin args in
  Alcotest.(check int) (label ^ " exit code") 0 code;
  Alcotest.(check string) (label ^ " output") expected (String.trim output)

let assert_source_contains source label fragment =
  Alcotest.(check bool) label true (Blorp.Modules.contains source fragment)

let assert_source_not_contains source label fragment =
  Alcotest.(check bool) label false (Blorp.Modules.contains source fragment)

let test_codegen_intrinsic_renderer_compiles_and_runs_smoke () =
  Blorp.Test_runner.with_run_artifacts (fun () ->
      let bin = compile_codegen_intrinsic_renderer () in
      assert_tool_success bin "zero-arg intrinsic"
        [ "intrinsic"; "math_nan" ]
        "(0.0/0.0)";
      assert_tool_success bin "one-arg intrinsic"
        [ "intrinsic"; "math_sqrt"; "__x" ]
        "sqrt(__x)";
      assert_tool_success bin "two-arg intrinsic"
        [ "intrinsic"; "math_pow"; "__base"; "__exp" ]
        "pow(__base, __exp)";
      assert_tool_success bin "three-arg intrinsic"
        [ "intrinsic"; "math_fma"; "a"; "b"; "c" ]
        "fma(a, b, c)")

let test_codegen_intrinsic_renderer_manifest_matches_checked_in_templates () =
  Blorp.Test_runner.with_run_artifacts (fun () ->
      let bin = compile_codegen_intrinsic_renderer () in
      let code, output = run_tool bin [ "manifest" ] in
      Alcotest.(check int) "manifest exit code" 0 code;
      let manifest_path =
        find_project_file compiler_intrinsic_template_manifest_rel
      in
      let manifest = read_file manifest_path in
      Alcotest.(check string)
        "generated manifest matches checked-in compiler template manifest"
        (String.trim manifest) (String.trim output);
      Alcotest.(check string)
        "embedded template module matches checked-in manifest"
        (String.trim manifest)
        (String.trim Blorp.Core_emit_blorp_intrinsic_templates.tsv))

let test_core_emit_delegates_initial_slice_to_blorp_manifest () =
  let core_emit_intrinsic_path = find_project_file core_emit_intrinsic_rel in
  let source = read_file core_emit_intrinsic_path in
  assert_source_contains source "production emitter calls Blorp manifest bridge"
    "Core_emit_blorp_intrinsic.emit";
  List.iter
    (fun fragment ->
      assert_source_not_contains source
        ("production emitter removed old OCaml arm: " ^ fragment)
        fragment)
    [
      "| \"bit_and\"";
      "| \"bit_or\"";
      "| \"bit_xor\"";
      "| \"bit_not\"";
      "| \"shift_left\"";
      "| \"shift_right\"";
      "| \"elem_release_fn\"";
      "| \"list_get\"";
      "| \"list_len\"";
      "| \"list_capacity\"";
      "| \"list_set_len\"";
      "| \"list_reverse_owned\"";
      "| \"list_release_elem\"";
      "| \"list_set_elem_release\"";
      "| \"string_get_byte\"";
      "| \"string_len\"";
      "| \"string_alloc\"";
      "| \"string_set_byte\"";
      "| \"string_ensure_unique\"";
      "| \"string_ensure_capacity\"";
      "| \"bytes_get\"";
      "| \"bytes_len\"";
      "| \"bytes_set\"";
      "| \"bytes_alloc\"";
      "| \"bytes_set_len\"";
      "| \"bytes_cow\"";
      "| \"dict_len\"";
      "| \"set_len\"";
      "| \"set_capacity\"";
      "| \"set_mask\"";
      "| \"set_bucket\"";
      "| \"set_first\"";
      "| \"set_last\"";
      "| \"set_entry_key\"";
      "| \"set_entry_next\"";
      "| \"set_entry_prev_order\"";
      "| \"set_entry_next_order\"";
      "| \"set_set_len\"";
      "| \"set_set_bucket\"";
      "| \"set_set_first\"";
      "| \"set_set_last\"";
      "| \"set_entry_set_next\"";
      "| \"set_entry_set_prev_order\"";
      "| \"set_entry_set_next_order\"";
      "| \"set_hash\"";
      "| \"set_eq\"";
      "| \"set_hash_immediate\"";
      "| \"set_eq_immediate\"";
      "| \"set_alloc\"";
      "| \"set_alloc_entry\"";
      "| \"set_free_entry\"";
      "| \"set_cow\"";
      "| \"set_reuse_alloc\"";
      "| \"set_resize\"";
      "| \"set_reserve_for_len\"";
      "| \"dict_capacity\"";
      "| \"dict_mask\"";
      "| \"dict_grow_at\"";
      "| \"dict_key_at\"";
      "| \"dict_value_at\"";
      "| \"dict_meta_get\"";
      "| \"dict_order_get\"";
      "| \"dict_order_len\"";
      "| \"dict_order_index_get\"";
      "| \"dict_key_release_fn\"";
      "| \"dict_value_release_fn\"";
      "| \"dict_set_len\"";
      "| \"dict_set_key_at\"";
      "| \"dict_set_value_at\"";
      "| \"dict_meta_set\"";
      "| \"dict_order_set\"";
      "| \"dict_set_order_len\"";
      "| \"dict_order_index_set\"";
      "| \"dict_hash\"";
      "| \"dict_eq\"";
      "| \"dict_hash_immediate\"";
      "| \"dict_eq_immediate\"";
      "| \"dict_alloc\"";
      "| \"dict_cow\"";
      "| \"dict_reuse_alloc\"";
      "| \"dict_resize\"";
      "| \"slice_source\"";
      "| \"slice_start\"";
      "| \"slice_len\"";
      "| \"slice_alloc\"";
      "| \"tensor_is_unique\"";
      "| \"tensor_len\"";
      "| \"tensor_capacity\"";
      "| \"tensor_get_i64_word_unchecked\"";
      "| \"tensor_get_i64_raw_unchecked\"";
      "| \"tensor_get_f64\"";
      "| \"tensor_get_f32\"";
      "| \"tensor_get_f16\"";
      "| \"tensor_set_f64\"";
      "| \"tensor_set_f32\"";
      "| \"tensor_set_f16\"";
      "| \"tensor_get_i64\"";
      "| \"tensor_set_i64\"";
      "| \"fixed_alloc\"";
      "| \"fixed_value\"";
      "| \"fixed_scale\"";
      "| \"fixed_precision\"";
      "| \"fixed_pow10\"";
      "String.sub name 5";
      "math_sqrt";
    ]

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
    ( "codegen_intrinsic_renderer",
      [
        Alcotest.test_case "compiles and runs smoke" `Slow
          test_codegen_intrinsic_renderer_compiles_and_runs_smoke;
        Alcotest.test_case "manifest matches checked-in templates" `Slow
          test_codegen_intrinsic_renderer_manifest_matches_checked_in_templates;
        Alcotest.test_case "production emitter delegates initial slice" `Quick
          test_core_emit_delegates_initial_slice_to_blorp_manifest;
        Alcotest.test_case "compiler/blorp TestSuites pass" `Slow
          test_compiler_blorp_test_suites;
      ] );
  ]
