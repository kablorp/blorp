let compiler_tool_rel =
  Filename.concat
    (Filename.concat "tools" "compiler")
    "codegen_intrinsic_renderer.brp"

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

let assert_tool_failure_contains bin label args expected_fragment =
  let code, output = run_tool bin args in
  Alcotest.(check int) (label ^ " exit code") 1 code;
  Alcotest.(check bool)
    (label ^ " error contains expected text")
    true
    (Blorp.Modules.contains output expected_fragment)

let assert_source_contains source label fragment =
  Alcotest.(check bool) label true (Blorp.Modules.contains source fragment)

let assert_source_not_contains source label fragment =
  Alcotest.(check bool) label false (Blorp.Modules.contains source fragment)

let test_codegen_intrinsic_renderer_source_contract () =
  let compiler_tool_path = find_project_file compiler_tool_rel in
  Alcotest.(check bool)
    "compiler-blorp tool source exists" true
    (Sys.file_exists compiler_tool_path);
  let source = read_file compiler_tool_path in
  assert_source_contains source "source exposes render_intrinsic"
    "pure func render_intrinsic(name: String, args: List[String]) -> \
     Result[String, RenderError]";
  assert_source_contains source "source exposes intrinsic enum"
    "enum Intrinsic:";
  assert_source_contains source "source exposes manifest command"
    "RenderManifestCommand";
  assert_source_contains source "source parses lookup as option"
    "pure func parse_intrinsic(name: String) -> Option[Intrinsic]";
  assert_source_contains source "source uses intrinsic lookup table"
    "private INTRINSICS_DICT: Dict[String, Intrinsic]";
  assert_source_contains source "source parses with dict get" ".get(name)";
  assert_source_contains source "source converts lookup miss at render boundary"
    "None: Err(UnsupportedIntrinsic(name))";
  assert_source_not_contains source
    "source lookup does not allocate result error"
    ".to_result(UnsupportedIntrinsic(name))";
  assert_source_contains source "source dispatches parsed intrinsics"
    "pure func render_parsed_intrinsic(";
  assert_source_contains source "source renders template manifest"
    "pure func render_manifest_lines() -> Result[List[String], RenderError]";
  assert_source_contains source "source uses typed arity errors"
    "WrongArity(Intrinsic, Int, Int)";
  assert_source_not_contains source "source does not use stringly render errors"
    "Result[String, String]";
  assert_source_not_contains source "source does not use intrinsic families"
    "enum IntrinsicFamily:";
  assert_source_not_contains source "source does not use prefix-family dispatch"
    "starts_with(\"math_\")";
  assert_source_not_contains source "source does not match intrinsic strings"
    "match name:";
  assert_source_not_contains source "source does not wildcard enum arities"
    "\t\t_: 1";
  assert_source_not_contains source "source does not use math string renderer"
    "render_math_intrinsic"

let test_codegen_intrinsic_renderer_renders_initial_slice () =
  Blorp.Test_runner.with_run_artifacts (fun () ->
      let bin = compile_codegen_intrinsic_renderer () in
      assert_tool_success bin "math sqrt"
        [ "intrinsic"; "math_sqrt"; "__x" ]
        "sqrt(__x)";
      assert_tool_success bin "math pow"
        [ "intrinsic"; "math_pow"; "__base"; "__exp" ]
        "pow(__base, __exp)";
      assert_tool_success bin "math constant"
        [ "intrinsic"; "math_nan" ]
        "(0.0/0.0)";
      assert_tool_success bin "bit and"
        [ "intrinsic"; "bit_and"; "lhs"; "rhs" ]
        "(lhs & rhs)";
      assert_tool_success bin "bit xor"
        [ "intrinsic"; "bit_xor"; "lhs"; "rhs" ]
        "(lhs ^ rhs)";
      assert_tool_success bin "bit not"
        [ "intrinsic"; "bit_not"; "value" ]
        "(~value)";
      assert_tool_success bin "shift left"
        [ "intrinsic"; "shift_left"; "value"; "amount" ]
        "((long)(value << (amount & 63)))";
      assert_tool_success bin "shift right"
        [ "intrinsic"; "shift_right"; "value"; "amount" ]
        "((long)(value >> (amount & 63)))";
      assert_tool_success bin "list length"
        [ "intrinsic"; "list_len"; "xs" ]
        "((blorp_List*)xs)->len";
      assert_tool_success bin "dict length"
        [ "intrinsic"; "dict_len"; "d" ]
        "((blorp_Dict*)d)->size";
      assert_tool_success bin "set bucket"
        [ "intrinsic"; "set_bucket"; "s"; "slot" ]
        "((void*)((blorp_Set*)s)->buckets[slot])";
      assert_tool_success bin "dict meta get"
        [ "intrinsic"; "dict_meta_get"; "d"; "slot" ]
        "((long)((blorp_Dict*)d)->meta[slot])";
      assert_tool_success bin "slice source"
        [ "intrinsic"; "slice_source"; "slice" ]
        "((void*)((blorp_StringSlice*)slice)->source)";
      assert_tool_success bin "tensor capacity"
        [ "intrinsic"; "tensor_capacity"; "vec" ]
        "((blorp_Vector*)vec)->capacity";
      assert_tool_success bin "fixed scale"
        [ "intrinsic"; "fixed_scale"; "fx" ]
        "(long)((blorp_Fixed*)fx)->scale";
      assert_tool_success bin "fixed precision"
        [ "intrinsic"; "fixed_precision"; "fx" ]
        "(long)((blorp_Fixed*)fx)->precision")

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
        (String.trim Blorp.Core_emit_blorp_intrinsic_templates.tsv);
      assert_source_contains output "manifest includes math sqrt"
        "math_sqrt\t1\tsqrt(@0@)";
      assert_source_contains output "manifest includes shift left"
        "shift_left\t2\t((long)(@0@ << (@1@ & 63)))";
      assert_source_contains output "manifest includes dict meta get"
        "dict_meta_get\t2\t((long)((blorp_Dict*)@0@)->meta[@1@])";
      assert_source_contains output "manifest includes slice source"
        "slice_source\t1\t((void*)((blorp_StringSlice*)@0@)->source)";
      assert_source_contains output "manifest includes fixed scale"
        "fixed_scale\t1\t(long)((blorp_Fixed*)@0@)->scale")

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
      "| \"list_len\"";
      "| \"list_capacity\"";
      "| \"string_len\"";
      "| \"bytes_len\"";
      "| \"bit_and\"";
      "| \"bit_or\"";
      "| \"bit_xor\"";
      "| \"bit_not\"";
      "| \"shift_left\"";
      "| \"shift_right\"";
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
      "| \"slice_source\"";
      "| \"slice_start\"";
      "| \"slice_len\"";
      "| \"tensor_len\"";
      "| \"tensor_capacity\"";
      "| \"fixed_value\"";
      "| \"fixed_scale\"";
      "| \"fixed_precision\"";
      "String.sub name 5";
      "math_sqrt";
    ]

let test_codegen_intrinsic_renderer_rejects_bad_requests () =
  Blorp.Test_runner.with_run_artifacts (fun () ->
      let bin = compile_codegen_intrinsic_renderer () in
      assert_tool_failure_contains bin "unknown intrinsic"
        [ "intrinsic"; "list_set"; "xs"; "0"; "value" ]
        "unsupported intrinsic: list_set";
      assert_tool_failure_contains bin "bad arity"
        [ "intrinsic"; "math_sqrt"; "x"; "extra" ]
        "intrinsic math_sqrt expected 1 arg(s), got 2";
      assert_tool_failure_contains bin "unknown command" [ "bogus" ] "Usage:")

let suite =
  [
    ( "codegen_intrinsic_renderer",
      [
        Alcotest.test_case "source contract" `Quick
          test_codegen_intrinsic_renderer_source_contract;
        Alcotest.test_case "renders initial intrinsic slice" `Slow
          test_codegen_intrinsic_renderer_renders_initial_slice;
        Alcotest.test_case "manifest matches checked-in templates" `Slow
          test_codegen_intrinsic_renderer_manifest_matches_checked_in_templates;
        Alcotest.test_case "production emitter delegates initial slice" `Quick
          test_core_emit_delegates_initial_slice_to_blorp_manifest;
        Alcotest.test_case "rejects unsupported requests" `Slow
          test_codegen_intrinsic_renderer_rejects_bad_requests;
      ] );
  ]
