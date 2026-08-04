let test_top_level_main_detects_real_main () =
  let source =
    {|
import:
    test: TestSuite

func main(args: List[String]) -> Int:
    0
|}
  in
  Alcotest.(check bool)
    "real main detected" true
    (Blorp.Test_runner.has_top_level_main_source source)

let test_top_level_main_ignores_string_literal () =
  let source =
    {|
import:
    test: TestSuite

src: String = "func main(args: List[String]) -> Int:\n    0\n"

tests: TestSuite = {
    description = "generated programs",
    tests = []
}
|}
  in
  Alcotest.(check bool)
    "string literal main ignored" false
    (Blorp.Test_runner.has_top_level_main_source source)

let test_top_level_main_ignores_comment () =
  let source =
    {|
-- func main(args: List[String]) -> Int:

tests: TestSuite = {
    description = "comment only",
    tests = []
}
|}
  in
  Alcotest.(check bool)
    "comment main ignored" false
    (Blorp.Test_runner.has_top_level_main_source source)

let test_doctest_detection_requires_a_docstring_block () =
  let actual_doctest =
    {|
---
Examples.

doctests:
    :: returns true
    True
---
pure func documented() -> Bool: True
|}
  in
  let parser_fixture =
    {|program_source: String = "---\nExamples.\n\ndoctests:\n    :: true\n    True\n---"|}
  in
  Alcotest.(check bool)
    "docstring doctests detected" true
    (Blorp.Test_runner.source_mentions_doctests actual_doctest);
  Alcotest.(check bool)
    "escaped parser fixture is not a doctest" false
    (Blorp.Test_runner.source_mentions_doctests parser_fixture)

let test_sanitizer_mode_parsing () =
  let open Blorp.Test_runner in
  let check label input expected =
    Alcotest.(check bool)
      label true
      (sanitizer_mode_of_string input = Some expected)
  in
  check "off" "off" SanitizerOff;
  check "enabled bool spelling" "1" SanitizerAddressUndefined;
  check "asan alias" "asan" SanitizerAddressUndefined;
  check "undefined alias" "ubsan" SanitizerUndefinedOnly;
  Alcotest.(check bool)
    "rejects unknown sanitizer mode" true
    (sanitizer_mode_of_string "thread" = None)

let test_sanitizer_mode_cli_values () =
  let open Blorp.Test_runner in
  Alcotest.(check string)
    "off" "off" (sanitizer_mode_to_cli_value SanitizerOff);
  Alcotest.(check string)
    "address and undefined" "address"
    (sanitizer_mode_to_cli_value SanitizerAddressUndefined);
  Alcotest.(check string)
    "undefined only" "undefined"
    (sanitizer_mode_to_cli_value SanitizerUndefinedOnly)

let test_capture_timeout_does_not_wait_for_inherited_pipe () =
  let start = Unix.gettimeofday () in
  let code, _ =
    Blorp.Test_runner.run_process_capture_timeout ~timeout:(Some 1) "/bin/sh"
      [ "-c"; "sleep 3 & wait" ]
  in
  let elapsed = Unix.gettimeofday () -. start in
  Alcotest.(check int) "timeout exit code" 124 code;
  Alcotest.(check bool) "returns near timeout" true (elapsed < 2.0)

let test_capture_timeout_sends_sigterm_before_sigkill () =
  let code, output =
    Blorp.Test_runner.run_process_capture_timeout ~timeout:(Some 1) "/bin/sh"
      [ "-c"; "trap 'echo TERM; exit 0' TERM; while true; do sleep 1; done" ]
  in
  Alcotest.(check int) "timeout exit code" 124 code;
  let saw_term_line =
    output |> String.split_on_char '\n'
    |> List.exists (fun line -> String.trim line = "TERM")
  in
  Alcotest.(check bool) "SIGTERM handler output" true saw_term_line

let test_capture_signal_uses_shell_exit_code () =
  Alcotest.(check int)
    "normal exit code" 7
    (Blorp.Process_status.exit_code (Unix.WEXITED 7));
  Alcotest.(check int)
    "stopped SIGTERM exit code" 143
    (Blorp.Process_status.exit_code (Unix.WSTOPPED Sys.sigterm));
  Alcotest.(check int)
    "SIGINT exit code" 130
    (Blorp.Process_status.exit_code_of_signal Sys.sigint);
  let code, _ =
    Blorp.Test_runner.run_process_capture_timeout ~timeout:None "/bin/sh"
      [ "-c"; "kill -SEGV $$" ]
  in
  Alcotest.(check int) "SIGSEGV exit code" 139 code

let test_capture_timeout_progress_marker_resets_deadline () =
  let code, output =
    Blorp.Test_runner.run_process_capture_timeout
      ~progress_marker:"__BLORP_TEST_PROGRESS__" ~timeout:(Some 1) "/bin/sh"
      [
        "-c";
        "printf '__BLORP_TEST_' >&2; sleep 0.4; "
        ^ "printf 'PROGRESS__ 0 BEGIN first\\n' >&2; sleep 0.4; "
        ^ "printf '__BLORP_TEST_PROGRESS__ 0 END first\\n' >&2; sleep 0.4";
      ]
  in
  Alcotest.(check int) "progressing process exits normally" 0 code;
  let saw_progress_marker =
    output |> String.split_on_char '\n'
    |> List.exists (fun line ->
           String.trim line = "__BLORP_TEST_PROGRESS__ 0 BEGIN first")
  in
  Alcotest.(check bool)
    "captures progress markers" true saw_progress_marker

let test_capture_timeout_ignores_unrecognized_output () =
  let code, _ =
    Blorp.Test_runner.run_process_capture_timeout
      ~progress_marker:"__BLORP_TEST_PROGRESS__" ~timeout:(Some 1) "/bin/sh"
      [
        "-c";
        "for delay in 0.4 0.4 0.4; do printf 'ordinary output\\n' >&2; "
        ^ "sleep $delay; done";
      ]
  in
  Alcotest.(check int) "ordinary output does not extend timeout" 124 code

let test_capture_timeout_ignores_malformed_progress_records () =
  let code, _ =
    Blorp.Test_runner.run_process_capture_timeout
      ~progress_marker:"__BLORP_TEST_PROGRESS__" ~timeout:(Some 1) "/bin/sh"
      [
        "-c";
        "for line in '__BLORP_TEST_PROGRESS__' "
        ^ "'__BLORP_TEST_PROGRESS__ nope BEGIN test' "
        ^ "'prefix __BLORP_TEST_PROGRESS__ 0 END test'; do "
        ^ "printf '%s\\n' \"$line\" >&2; sleep 0.4; done";
      ]
  in
  Alcotest.(check int) "malformed records do not extend timeout" 124 code

let test_capture_timeout_ignores_replayed_progress_records () =
  let code, _ =
    Blorp.Test_runner.run_process_capture_timeout
      ~progress_marker:"__BLORP_TEST_PROGRESS__" ~progress_count:1
      ~timeout:(Some 1) "/bin/sh"
      [
        "-c";
        "for delay in 0.4 0.4 0.4; do "
        ^ "printf '__BLORP_TEST_PROGRESS__ 0 BEGIN test\\n' >&2; "
        ^ "sleep $delay; done";
      ]
  in
  Alcotest.(check int) "replayed BEGIN records do not extend timeout" 124 code

let test_capture_timeout_ignores_progress_marker_on_stdout () =
  let code, _ =
    Blorp.Test_runner.run_process_capture_timeout
      ~progress_marker:"__BLORP_TEST_PROGRESS__" ~timeout:(Some 1) "/bin/sh"
      [
        "-c";
        "for delay in 0.4 0.4 0.4; do "
        ^ "printf '__BLORP_TEST_PROGRESS__ 0 BEGIN test\\n'; sleep $delay; done";
      ]
  in
  Alcotest.(check int) "stdout cannot extend timeout" 124 code

let test_capture_timeout_keeps_progress_separate_from_stdout () =
  let check_capture label timeout =
    let code, output =
      Blorp.Test_runner.run_process_capture_timeout
        ~progress_marker:"__BLORP_TEST_PROGRESS__" ~timeout "/bin/sh"
        [
          "-c";
          "printf 'stdout-before'; "
          ^ "printf '__BLORP_TEST_PROGRESS__ 0 BEGIN test\\n' >&2; "
          ^ "printf '%s\\n' '-after'";
        ]
    in
    Alcotest.(check int) (label ^ " exits normally") 0 code;
    let lines = String.split_on_char '\n' output in
    Alcotest.(check bool)
      (label ^ " keeps stderr out of stdout framing") true
      (List.mem "stdout-before-after" lines
      && List.mem "__BLORP_TEST_PROGRESS__ 0 BEGIN test" lines)
  in
  check_capture "bounded timeout" (Some 2);
  check_capture "disabled timeout" None;
  check_capture "zero timeout" (Some 0)

let process_exists pid =
  try
    Unix.kill pid 0;
    true
  with
  | Unix.Unix_error (Unix.ESRCH, _, _) -> false
  | Unix.Unix_error (Unix.EPERM, _, _) -> true

let wait_until_process_exits pid timeout =
  let deadline = Unix.gettimeofday () +. timeout in
  let rec loop () =
    if not (process_exists pid) then true
    else if Unix.gettimeofday () >= deadline then false
    else begin
      ignore (Unix.select [] [] [] 0.05);
      loop ()
    end
  in
  loop ()

let first_int_line output =
  output |> String.split_on_char '\n'
  |> List.find_map (fun line ->
      let line = String.trim line in
      if line = "" then None else int_of_string_opt line)

let test_capture_timeout_kills_descendant_processes () =
  let code, output =
    Blorp.Test_runner.run_process_capture_timeout ~timeout:(Some 1) "/bin/sh"
      [ "-c"; "sleep 30 & echo $!; wait" ]
  in
  Alcotest.(check int) "timeout exit code" 124 code;
  match first_int_line output with
  | None -> Alcotest.fail ("missing child pid in output: " ^ output)
  | Some child_pid ->
      let child_exited = wait_until_process_exits child_pid 1.0 in
      (if not child_exited then
         try Unix.kill child_pid Sys.sigkill with _ -> ());
      Alcotest.(check bool) "descendant process was killed" true child_exited

let test_inherited_timeout_does_not_block_waitpid () =
  let start = Unix.gettimeofday () in
  let code =
    Blorp.Test_runner.run_process_timeout ~timeout:(Some 1) "/bin/sh"
      [ "-c"; "sleep 3" ]
  in
  let elapsed = Unix.gettimeofday () -. start in
  Alcotest.(check int) "timeout exit code" 124 code;
  Alcotest.(check bool) "returns near timeout" true (elapsed < 2.0)

let test_inherited_timeout_kills_descendant_processes () =
  let pid_file = Filename.temp_file "blorp-timeout-child-" ".pid" in
  let read_pid_file () =
    let ic = open_in pid_file in
    Fun.protect
      ~finally:(fun () -> close_in ic)
      (fun () -> really_input_string ic (in_channel_length ic))
  in
  Fun.protect
    ~finally:(fun () -> try Sys.remove pid_file with _ -> ())
    (fun () ->
      let code =
        Blorp.Test_runner.run_process_timeout ~timeout:(Some 1) "/bin/sh"
          [ "-c"; "sleep 30 & echo $! > \"$1\"; wait"; "sh"; pid_file ]
      in
      Alcotest.(check int) "timeout exit code" 124 code;
      let child_pid = read_pid_file () |> String.trim |> int_of_string_opt in
      match child_pid with
      | None -> Alcotest.fail "child pid file was not written"
      | Some pid ->
          let child_exited = wait_until_process_exits pid 1.0 in
          (if not child_exited then try Unix.kill pid Sys.sigkill with _ -> ());
          Alcotest.(check bool)
            "descendant process was killed" true child_exited)

let test_inherited_timeout_sends_sigterm_before_sigkill () =
  let marker_file = Filename.temp_file "blorp-timeout-term-" ".txt" in
  Fun.protect
    ~finally:(fun () -> try Sys.remove marker_file with _ -> ())
    (fun () ->
      let code =
        Blorp.Test_runner.run_process_timeout ~timeout:(Some 1) "/bin/sh"
          [
            "-c";
            "trap 'echo TERM > \"$1\"; exit 0' TERM; while true; do sleep 1; \
             done";
            "sh";
            marker_file;
          ]
      in
      Alcotest.(check int) "timeout exit code" 124 code;
      let marker =
        if Sys.file_exists marker_file then
          let ic = open_in marker_file in
          Fun.protect
            ~finally:(fun () -> close_in ic)
            (fun () -> really_input_string ic (in_channel_length ic))
        else ""
      in
      Alcotest.(check string) "SIGTERM marker" "TERM\n" marker)

let test_run_artifact_paths_are_scoped_to_one_run_root () =
  Blorp.Test_runner.with_run_artifacts (fun () ->
      let first =
        Blorp.Test_runner.run_artifact_path ~kind:"bins" ~prefix:"sample"
          ~suffix:".bin"
      in
      let root = Filename.dirname (Filename.dirname first) in
      let second =
        Blorp.Test_runner.run_artifact_path ~kind:"bins" ~prefix:"sample"
          ~suffix:".bin"
      in
      Alcotest.(check bool) "root exists" true (Sys.file_exists root);
      Alcotest.(check bool)
        "first under root" true
        (String.starts_with ~prefix:root first);
      Alcotest.(check bool)
        "second under root" true
        (String.starts_with ~prefix:root second);
      Alcotest.(check bool) "paths unique" true (first <> second))

let is_uuid_like s =
  String.length s = 36
  && List.for_all (fun i -> s.[i] = '-') [ 8; 13; 18; 23 ]
  && List.for_all
       (fun i ->
         List.mem i [ 8; 13; 18; 23 ]
         || match s.[i] with '0' .. '9' | 'a' .. 'f' -> true | _ -> false)
       (List.init 36 Fun.id)

let test_run_artifact_root_uses_uuid () =
  Blorp.Test_runner.with_run_artifacts (fun () ->
      let artifact =
        Blorp.Test_runner.run_artifact_path ~kind:"bins" ~prefix:"sample"
          ~suffix:".bin"
      in
      let root = Filename.dirname (Filename.dirname artifact) in
      let name = Filename.basename root in
      let prefix = "run-" in
      Alcotest.(check bool)
        "run root has run- prefix" true
        (String.starts_with ~prefix name);
      let uuid =
        String.sub name (String.length prefix)
          (String.length name - String.length prefix)
      in
      Alcotest.(check bool) "run root suffix is uuid" true (is_uuid_like uuid))

let test_run_artifact_roots_do_not_overlap () =
  let first =
    Blorp.Test_runner.with_run_artifacts (fun () ->
        Blorp.Test_runner.run_artifact_path ~kind:"bins" ~prefix:"sample"
          ~suffix:".bin"
        |> Filename.dirname |> Filename.dirname)
  in
  let second =
    Blorp.Test_runner.with_run_artifacts (fun () ->
        Blorp.Test_runner.run_artifact_path ~kind:"bins" ~prefix:"sample"
          ~suffix:".bin"
        |> Filename.dirname |> Filename.dirname)
  in
  Alcotest.(check bool) "separate runs use separate roots" true (first <> second)

let test_compilation_dirs_are_run_scoped () =
  Blorp.Test_runner.with_run_artifacts (fun () ->
      let first = Blorp.Test_runner.run_compilation_dir () in
      let second = Blorp.Test_runner.run_compilation_dir () in
      let parent = Filename.dirname first in
      let first_name = Filename.basename first in
      let second_name = Filename.basename second in
      Alcotest.(check bool)
        "first under compilation root" true
        (String.starts_with ~prefix:parent first);
      Alcotest.(check bool)
        "second under compilation root" true
        (String.starts_with ~prefix:parent second);
      Alcotest.(check bool) "dirs unique" true (first <> second);
      Alcotest.(check string) "first compile dir" "compile-000001" first_name;
      Alcotest.(check string) "second compile dir" "compile-000002" second_name)

let test_compilation_dirs_are_fork_safe () =
  Blorp.Test_runner.with_run_artifacts (fun () ->
      let artifact =
        Blorp.Test_runner.run_artifact_path ~kind:"bins" ~prefix:"sample"
          ~suffix:".bin"
      in
      let root = Filename.dirname (Filename.dirname artifact) in
      let spawn_child () =
        let read_fd, write_fd = Unix.pipe () in
        match Unix.fork () with
        | 0 ->
            Unix.close read_fd;
            let code =
              try
                let dir = Blorp.Test_runner.run_compilation_dir () in
                let oc = Unix.out_channel_of_descr write_fd in
                output_string oc (dir ^ "\n");
                close_out oc;
                0
              with _ ->
                (try Unix.close write_fd with _ -> ());
                42
            in
            exit code
        | pid ->
            Unix.close write_fd;
            (pid, read_fd)
      in
      let first = spawn_child () in
      let second = spawn_child () in
      let read_dir read_fd =
        let ic = Unix.in_channel_of_descr read_fd in
        Fun.protect ~finally:(fun () -> close_in ic) (fun () -> input_line ic)
      in
      let child_status (pid, read_fd) =
        let dir = read_dir read_fd in
        (Blorp.Process_status.exit_code (snd (Unix.waitpid [] pid)), dir)
      in
      let first_code, first_dir = child_status first in
      let second_code, second_dir = child_status second in
      let parent = Filename.concat root "compilations" in
      Alcotest.(check int) "first child" 0 first_code;
      Alcotest.(check int) "second child" 0 second_code;
      Alcotest.(check bool)
        "first under compilation root" true
        (String.starts_with ~prefix:parent first_dir);
      Alcotest.(check bool)
        "second under compilation root" true
        (String.starts_with ~prefix:parent second_dir);
      Alcotest.(check bool)
        "forked compile dirs are distinct" true (first_dir <> second_dir))

let read_whole_file path =
  let ic = open_in path in
  Fun.protect
    ~finally:(fun () -> close_in ic)
    (fun () -> really_input_string ic (in_channel_length ic))

let contains_substring s needle =
  let len = String.length s in
  let needle_len = String.length needle in
  let rec loop i =
    i + needle_len <= len && (String.sub s i needle_len = needle || loop (i + 1))
  in
  needle_len = 0 || loop 0

let write_file path content =
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out oc)
    (fun () -> output_string oc content)

let rec remove_tree path =
  if Sys.file_exists path then
    if Sys.is_directory path then begin
      Array.iter
        (fun name -> remove_tree (Filename.concat path name))
        (Sys.readdir path);
      Unix.rmdir path
    end
    else Sys.remove path

let with_temp_dir prefix f =
  let dir = Filename.temp_file prefix "" in
  Sys.remove dir;
  Unix.mkdir dir 0o700;
  Fun.protect ~finally:(fun () -> remove_tree dir) (fun () -> f dir)

let test_capture_process_uses_supplied_cwd_and_env () =
  with_temp_dir "blorp-process-env-" (fun dir ->
      let marker = Filename.concat dir "marker.txt" in
      let code, _ =
        Blorp.Test_runner.run_process_capture_timeout ~cwd:dir
          ~env:[ ("TMPDIR", "isolated-tmp") ]
          ~timeout:(Some 1) "/bin/sh"
          [ "-c"; "printf '%s' \"$TMPDIR\" > marker.txt" ]
      in
      Alcotest.(check int) "process exit" 0 code;
      Alcotest.(check bool)
        "marker written under cwd" true (Sys.file_exists marker);
      Alcotest.(check string)
        "env propagated" "isolated-tmp" (read_whole_file marker))

let test_main_only_file_is_not_runnable_test () =
  with_temp_dir "blorp-main-only-test-" (fun dir ->
      let file = Filename.concat dir "main_only.brp" in
      write_file file
        {|
func main(args: List[String]) -> Int:
    0
|};
      Blorp.Test_runner.with_run_artifacts (fun () ->
          let code =
            Blorp.Test_runner.run_tests ~timeout:(Some 10) ~jobs:1
              ~cache:false file
          in
          Alcotest.(check int) "main-only file is not a test" 1 code))

let test_testsuite_file_remains_runnable_test () =
  with_temp_dir "blorp-suite-test-" (fun dir ->
      let file = Filename.concat dir "suite.brp" in
      write_file file
        {|
import:
    test: TestSuite

func passes() -> Bool:
    True

tests: TestSuite = {
    description = "suite",
    tests = [("passes", passes)]
}
|};
      Blorp.Test_runner.with_run_artifacts (fun () ->
          let code =
            Blorp.Test_runner.run_tests ~timeout:(Some 10) ~jobs:1
              ~cache:false file
          in
          Alcotest.(check int) "suite file runs" 0 code))

let test_testsuite_file_with_main_is_invalid_test () =
  with_temp_dir "blorp-suite-with-main-test-" (fun dir ->
      let file = Filename.concat dir "suite_with_main.brp" in
      write_file file
        {|
import:
    test: TestSuite

func passes() -> Bool:
    True

tests: TestSuite = {
    description = "suite",
    tests = [("passes", passes)]
}

func main(args: List[String]) -> Int:
    0
|};
      Blorp.Test_runner.with_run_artifacts (fun () ->
          let code =
            Blorp.Test_runner.run_tests ~timeout:(Some 10) ~jobs:1
              ~cache:false file
          in
          Alcotest.(check int) "suite file main is not used" 1 code))

let with_env name value f =
  let old = Sys.getenv_opt name in
  Unix.putenv name value;
  Fun.protect
    ~finally:(fun () ->
      match old with
      | Some v -> Unix.putenv name v
      | None -> Unix.putenv name "")
    f

let default_bridge_cache_dir () =
  match
    Sys.getenv_opt Blorp.Compiler_blorp_bridge.bridge_worker_cache_dir_env
  with
  | Some path when path <> "" -> path
  | _ ->
      let cache_base =
        match Sys.getenv_opt "XDG_CACHE_HOME" with
        | Some path when path <> "" -> path
        | _ -> (
            match Sys.getenv_opt "HOME" with
            | Some path when path <> "" -> Filename.concat path ".cache"
            | _ -> Filename.concat (Filename.get_temp_dir_name ()) ".cache")
      in
      Filename.concat (Filename.concat cache_base "blorp") "compiler-bridge"

let with_isolated_home_preserving_bridge_cache home f =
  let bridge_cache = default_bridge_cache_dir () in
  with_env Blorp.Compiler_blorp_bridge.bridge_worker_cache_dir_env bridge_cache
    (fun () -> with_env "HOME" home f)

let test_suite_selector_harness_dispatches_by_index () =
  let source =
    Blorp.Test_runner.generate_suite_selector_harness
      [ "tests/test_blorp/a.brp"; "tests/test_blorp/b.brp" ]
  in
  Alcotest.(check bool)
    "imports test module 0" true
    (contains_substring source "    ./tests/test_blorp/a as T0");
  Alcotest.(check bool)
    "imports test module 1" true
    (contains_substring source "    ./tests/test_blorp/b as T1");
  Alcotest.(check bool)
    "uses run_suite" true
    (contains_substring source "std/test: run_suite");
  Alcotest.(check bool)
    "parses selector argument" true
    (contains_substring source "match get(args, 1):"
    && contains_substring source "match parse_int(selector):");
  Alcotest.(check bool)
    "dispatches with match instead of expression if chain" true
    (contains_substring source
       "func __run_selected(index: Int) -> Bool:\n    match index:"
    && not (contains_substring source "else if index =="));
  Alcotest.(check bool)
    "dispatches first suite" true
    (contains_substring source "        0:\n            run_suite(T0.tests)");
  Alcotest.(check bool)
    "has invalid selector fallback" true
    (contains_substring source "        _:\n            False")

let test_suite_run_all_harness_calls_generated_functions () =
  let source =
    Blorp.Test_runner.generate_suite_run_all_harness
      [ "tests/test_blorp/a.brp"; "tests/test_blorp/b.brp" ]
  in
  Alcotest.(check bool)
    "imports test module 0" true
    (contains_substring source "    ./tests/test_blorp/a as T0");
  Alcotest.(check bool)
    "imports test module 1" true
    (contains_substring source "    ./tests/test_blorp/b as T1");
  Alcotest.(check bool)
    "imports suite type for local copy" true
    (contains_substring source "std/test: TestSuite, run_suite");
  Alcotest.(check bool)
    "wraps each suite with markers" true
    (contains_substring source
       "__BLORP_SUITE_RUN_ALL_BEGIN__ 0 tests/test_blorp/a.brp"
    && contains_substring source
         "__BLORP_SUITE_RUN_ALL_END__ 1 FAIL tests/test_blorp/b.brp");
  Alcotest.(check bool)
    "keeps result framing ordered on stdout" true
    (contains_substring source
       "print(\"__BLORP_SUITE_RUN_ALL_BEGIN__ 0 tests/test_blorp/a.brp\")"
    && contains_substring source
         "print(\"__BLORP_SUITE_RUN_ALL_END__ 1 FAIL tests/test_blorp/b.brp\")"
    && not
         (contains_substring source
            "print_error(\"__BLORP_SUITE_RUN_ALL_BEGIN__ 0 tests/test_blorp/a.brp\")"));
  Alcotest.(check bool)
    "writes separate progress heartbeats to unbuffered stderr" true
    (contains_substring source
       "print_error(\"__BLORP_SUITE_RUN_ALL_PROGRESS__ 0 BEGIN tests/test_blorp/a.brp\")"
    && contains_substring source
         "print_error(\"__BLORP_SUITE_RUN_ALL_PROGRESS__ 1 END tests/test_blorp/b.brp\")");
  let nonce_source =
    Blorp.Test_runner.generate_suite_run_all_harness
      ~progress_marker:"__BLORP_SUITE_RUN_ALL_PROGRESS__nonce"
      [ "tests/test_blorp/a.brp" ]
  in
  Alcotest.(check bool)
    "embeds the run-specific progress marker" true
    (contains_substring nonce_source
       "print_error(\"__BLORP_SUITE_RUN_ALL_PROGRESS__nonce 0 BEGIN tests/test_blorp/a.brp\")");
  Alcotest.(check bool)
    "copies suite before run_suite" true
    (contains_substring source "suite: TestSuite = T0.tests"
    && contains_substring source "passed: Bool = run_suite(suite)"
    && not (contains_substring source "run_suite(T0.tests)"));
  Alcotest.(check bool)
    "calls generated suite functions" true
    (contains_substring source "    if not __run_suite_0():"
    && contains_substring source "    if not __run_suite_1():");
  Alcotest.(check bool)
    "does not parse selector arguments" false
    (contains_substring source "match parse_int(selector):")

let test_suite_run_all_streams_preserve_stderr_diagnostics () =
  let files = [ "tests/a.brp"; "tests/b.brp" ] in
  let stdout_output =
    "__BLORP_SUITE_RUN_ALL_BEGIN__ 0 tests/a.brp\n"
    ^ "first stdout\n"
    ^ "__BLORP_SUITE_RUN_ALL_END__ 0 FAIL tests/a.brp\n"
    ^ "__BLORP_SUITE_RUN_ALL_BEGIN__ 1 tests/b.brp\n"
    ^ "second stdout\n"
    ^ "__BLORP_SUITE_RUN_ALL_END__ 1 PASS tests/b.brp\n"
  in
  let stderr_output =
    "__BLORP_SUITE_RUN_ALL_PROGRESS__ 0 BEGIN tests/a.brp\n"
    ^ "first diagnostic\n"
    ^ "__BLORP_SUITE_RUN_ALL_PROGRESS__ 0 END tests/a.brp\n"
    ^ "__BLORP_SUITE_RUN_ALL_PROGRESS__ 1 BEGIN tests/b.brp\n"
    ^ "second diagnostic\n"
    ^ "__BLORP_SUITE_RUN_ALL_PROGRESS__ 1 END tests/b.brp\n"
  in
  match
    Blorp.Test_runner.suite_run_all_results_from_streams ~elapsed:0.25 files
      ~stdout_output ~stderr_output
  with
  | Some [ first; second ] ->
      Alcotest.(check bool) "first suite failed" false first.passed;
      Alcotest.(check bool)
        "first stderr stays with first suite" true
        (contains_substring first.output "first diagnostic"
        && not (contains_substring first.output "second diagnostic"));
      Alcotest.(check bool) "second suite passed" true second.passed;
      Alcotest.(check bool)
        "second stderr stays with second suite" true
        (contains_substring second.output "second diagnostic"
        && not (contains_substring second.output "first diagnostic"))
  | Some results ->
      Alcotest.failf "expected two parsed suite results, got %d"
        (List.length results)
  | None -> Alcotest.fail "expected valid split-stream suite output"

let test_timing_event_has_stable_machine_readable_format () =
  let event : Blorp.Test_runner.timing_event =
    {
      timing_phase = HarnessPipeline;
      timing_group = "run_all_0";
      timing_suite_count = 4;
      timing_source_count = 4;
      timing_duration_ms = 1234;
    }
  in
  Alcotest.(check string)
    "timing record"
    "BLORP_TEST_TIMING phase=pipeline group=run_all_0 suites=4 sources=4 \
     duration_ms=1234"
    (Blorp.Test_runner.format_timing_event event)

let test_compilation_groups_follow_source_budget_not_suite_count () =
  let five_small_suites = [ "a"; "b"; "c"; "d"; "e" ] in
  Alcotest.(check (list (list string)))
    "five small suites remain one group" [ five_small_suites ]
    (Blorp.Test_runner.group_by_source_size_budget ~max_source_bytes:5
       ~source_size:(fun _ -> 1) five_small_suites);
  Alcotest.(check (list (list string)))
    "groups preserve order and respect accumulated source size"
    [ [ "a" ]; [ "b"; "c" ] ]
    (Blorp.Test_runner.group_by_source_size_budget ~max_source_bytes:100
       ~source_size:(function "a" -> 40 | "b" -> 70 | _ -> 20)
       [ "a"; "b"; "c" ]);
  Alcotest.(check (list (list string)))
    "one oversized suite forms its own group" [ [ "large" ]; [ "small" ] ]
    (Blorp.Test_runner.group_by_source_size_budget ~max_source_bytes:100
       ~source_size:(function "large" -> 150 | _ -> 10)
       [ "large"; "small" ])

let test_sanitized_harnesses_use_smaller_source_budget () =
  let ordinary =
    Blorp.Test_runner.combined_harness_source_budget_bytes ~sanitize:false
  in
  let sanitized =
    Blorp.Test_runner.combined_harness_source_budget_bytes ~sanitize:true
  in
  Alcotest.(check bool)
    "sanitizer instrumentation lowers the aggregate source budget" true
    (sanitized < ordinary)

let test_suite_harness_combines_globals_and_reports_failures () =
  with_temp_dir "blorp-suite-selector-" (fun dir ->
      let home = Filename.concat dir "home" in
      Unix.mkdir home 0o700;
      let suite_source name test_result =
        Printf.sprintf
          {|
import:
    test: TestSuite

func test_%s() -> Bool:
    %s

tests: TestSuite = {
    description = "%s",
    tests = [("%s", test_%s)]
}

unused_tests: TestSuite = {
    description = "Unused %s",
    tests = []
}
|}
          name test_result (String.uppercase_ascii name) name name name
      in
      List.iter
        (fun name ->
          write_file
            (Filename.concat dir (name ^ ".brp"))
            (suite_source name "True"))
        [ "a"; "b"; "c"; "d"; "e" ];
      let old_cwd = Sys.getcwd () in
      Fun.protect
        ~finally:(fun () -> Sys.chdir old_cwd)
        (fun () ->
          Sys.chdir dir;
          with_isolated_home_preserving_bridge_cache home (fun () ->
              let code =
                Blorp.Test_runner.run_tests ~timeout:(Some 10) ~jobs:1
                  ~cache:true "."
              in
              Alcotest.(check int) "combined suite run" 0 code;
              write_file
                (Filename.concat dir "e.brp")
                (suite_source "e" "False");
              let failing_code =
                Blorp.Test_runner.run_tests ~timeout:(Some 10) ~jobs:1
                  ~cache:false "."
              in
              Alcotest.(check int)
                "combined suite reports a normal test failure" 1 failing_code;
              write_file
                (Filename.concat dir "e.brp")
                (suite_source "e" "True");
              let leak_check_environment_before =
                Sys.getenv_opt "BLORP_LEAK_CHECK"
              in
              let leak_check_code =
                Blorp.Test_runner.run_tests ~leak_check:true
                  ~timeout:(Some 10) ~jobs:1 ~cache:false "."
              in
              Alcotest.(check int)
                "combined globals pass leak checking" 0 leak_check_code;
              Alcotest.(check (option string))
                "leak checking does not mutate the host environment"
                leak_check_environment_before
                (Sys.getenv_opt "BLORP_LEAK_CHECK"))))

let test_suite_harness_uses_blorp_frontend () =
  with_temp_dir "blorp-suite-frontend-" (fun dir ->
      let home = Filename.concat dir "home" in
      Unix.mkdir home 0o700;
      write_file
        (Filename.concat dir "qualified_process.brp")
        {|
import:
    process as Process
    test: TestSuite

private pure func exit_code(exit: Process.ProcessExit) -> Int:
    match exit:
        Process.Exited(code):
            code
        Process.Signaled(_):
            -1
        Process.TimedOut:
            -1

func test_qualified_process_constructor() -> Bool:
    exit_code(Process.Exited(7)) == 7

tests: TestSuite = {
    description = "Qualified process",
    tests = [("qualified process constructor", test_qualified_process_constructor)]
}
|};
      write_file
        (Filename.concat dir "ordinary.brp")
        {|
import:
    test: TestSuite

func test_ordinary() -> Bool:
    True

tests: TestSuite = {
    description = "Ordinary",
    tests = [("ordinary", test_ordinary)]
}
|};
      let old_cwd = Sys.getcwd () in
      Fun.protect
        ~finally:(fun () -> Sys.chdir old_cwd)
        (fun () ->
          Sys.chdir dir;
          with_isolated_home_preserving_bridge_cache home (fun () ->
              let code =
                Blorp.Test_runner.run_tests ~timeout:(Some 10) ~jobs:1
                  ~cache:false "."
              in
              Alcotest.(check int) "Blorp frontend suite run" 0 code)))

let test_suite_selector_compile_failure_is_hard_failure () =
  with_temp_dir "blorp-suite-selector-fail-" (fun dir ->
      let home = Filename.concat dir "home" in
      Unix.mkdir home 0o700;
      write_file
        (Filename.concat dir "a.brp")
        {|
import:
    test: TestSuite

func test_a() -> Bool:
    True

tests: TestSuite = {
    description = "A",
    tests = [("a", test_a)]
}
|};
      write_file
        (Filename.concat dir "b.brp")
        {|
import:
    test: TestSuite

func test_b() -> Bool:
    True

tests: TestSuite = {
    description = "B",
    tests = [("b", test_b)]
}
|};
      let parent = Filename.dirname dir in
      let basename = Filename.basename dir in
      let old_cwd = Sys.getcwd () in
      Fun.protect
        ~finally:(fun () -> Sys.chdir old_cwd)
        (fun () ->
          Sys.chdir parent;
          with_isolated_home_preserving_bridge_cache home (fun () ->
              let code =
                Blorp.Test_runner.run_tests ~timeout:(Some 10) ~jobs:1
                  ~cache:false basename
              in
              Alcotest.(check int)
                "selector compile failure is hard failure" 1 code)))

let test_suite_selector_harness_uses_leak_check_runner () =
  let source =
    Blorp.Test_runner.generate_suite_selector_harness ~leak_check:true
      [ "tests/test_blorp/a.brp" ]
  in
  Alcotest.(check bool)
    "uses leak-check runner" true
    (contains_substring source "std/test: run_suite_leak_check"
    && contains_substring source "run_suite_leak_check(T0.tests)")

let test_doctest_harness_allows_module_and_local_imports () =
  with_temp_dir "blorp-doctest-imports-" (fun dir ->
      write_file
        (Filename.concat dir "sample.brp")
        {|
import:
    option: Option(Some, None)
    string: length

---
Doctests can use imports from the documented module and add local imports.

doctests:
    :: uses module imports
    maybe: Option[Int] = Some(41)
    match maybe:
        Some(n): n == 41
        None: False

    :: uses doctest import
    import:
        result: Result(Ok, Err)
    r: Result[Int, String] = Ok(1)
    match r:
        Ok(n): n == 1
        Err(_): False
---
private pure func hidden(s: String) -> Option[Int]:
    Some(length(s))
|};
      let old_cwd = Sys.getcwd () in
      Fun.protect
        ~finally:(fun () -> Sys.chdir old_cwd)
        (fun () ->
          Sys.chdir dir;
          Blorp.Test_runner.with_run_artifacts (fun () ->
              let code =
                Blorp.Test_runner.run_tests ~mode:Blorp.Test_runner.DocOnly
                  ~timeout:(Some 10) ~jobs:1 ~cache:false "sample.brp"
              in
              Alcotest.(check int) "doctest imports pass" 0 code)))

let suite =
  [
    ( "main_detection",
      [
        Alcotest.test_case "real_main" `Quick
          test_top_level_main_detects_real_main;
        Alcotest.test_case "string_literal" `Quick
          test_top_level_main_ignores_string_literal;
        Alcotest.test_case "comment" `Quick test_top_level_main_ignores_comment;
        Alcotest.test_case "doctest_block" `Quick
          test_doctest_detection_requires_a_docstring_block;
      ] );
    ( "timeouts",
      [
        Alcotest.test_case "capture_timeout_inherited_pipe" `Quick
          test_capture_timeout_does_not_wait_for_inherited_pipe;
        Alcotest.test_case "capture_timeout_sigterm_before_sigkill" `Quick
          test_capture_timeout_sends_sigterm_before_sigkill;
        Alcotest.test_case "capture_signal_shell_exit_code" `Quick
          test_capture_signal_uses_shell_exit_code;
        Alcotest.test_case "capture_timeout_progress_marker" `Quick
          test_capture_timeout_progress_marker_resets_deadline;
        Alcotest.test_case "capture_timeout_ignores_other_output" `Quick
          test_capture_timeout_ignores_unrecognized_output;
        Alcotest.test_case "capture_timeout_ignores_malformed_progress" `Quick
          test_capture_timeout_ignores_malformed_progress_records;
        Alcotest.test_case "capture_timeout_ignores_replayed_progress" `Quick
          test_capture_timeout_ignores_replayed_progress_records;
        Alcotest.test_case "capture_timeout_ignores_stdout_marker" `Quick
          test_capture_timeout_ignores_progress_marker_on_stdout;
        Alcotest.test_case "capture_timeout_separates_progress_stream" `Quick
          test_capture_timeout_keeps_progress_separate_from_stdout;
        Alcotest.test_case "capture_timeout_kills_descendants" `Quick
          test_capture_timeout_kills_descendant_processes;
        Alcotest.test_case "capture_process_cwd_env" `Quick
          test_capture_process_uses_supplied_cwd_and_env;
        Alcotest.test_case "inherited_timeout_does_not_block_waitpid" `Quick
          test_inherited_timeout_does_not_block_waitpid;
        Alcotest.test_case "inherited_timeout_kills_descendants" `Quick
          test_inherited_timeout_kills_descendant_processes;
        Alcotest.test_case "inherited_timeout_sigterm_before_sigkill" `Quick
          test_inherited_timeout_sends_sigterm_before_sigkill;
      ] );
    ( "artifacts",
      [
        Alcotest.test_case "run_artifact_paths_are_scoped_to_one_run_root"
          `Quick test_run_artifact_paths_are_scoped_to_one_run_root;
        Alcotest.test_case "run_artifact_root_uses_uuid" `Quick
          test_run_artifact_root_uses_uuid;
        Alcotest.test_case "run_artifact_roots_do_not_overlap" `Quick
          test_run_artifact_roots_do_not_overlap;
        Alcotest.test_case "compilation_dirs_are_run_scoped" `Quick
          test_compilation_dirs_are_run_scoped;
        Alcotest.test_case "compilation_dirs_are_fork_safe" `Quick
          test_compilation_dirs_are_fork_safe;
      ] );
    ( "sanitizers",
      [
        Alcotest.test_case "mode_parsing" `Quick test_sanitizer_mode_parsing;
        Alcotest.test_case "mode_cli_values" `Quick
          test_sanitizer_mode_cli_values;
      ] );
    ( "suite_selector_harness",
      [
        Alcotest.test_case "main_only_not_runnable" `Quick
          test_main_only_file_is_not_runnable_test;
        Alcotest.test_case "testsuite_file_runnable" `Quick
          test_testsuite_file_remains_runnable_test;
        Alcotest.test_case "testsuite_with_main_invalid" `Quick
          test_testsuite_file_with_main_is_invalid_test;
        Alcotest.test_case "dispatches_by_index" `Quick
          test_suite_selector_harness_dispatches_by_index;
        Alcotest.test_case "run_all_generated_functions" `Quick
          test_suite_run_all_harness_calls_generated_functions;
        Alcotest.test_case "run_all_preserves_stderr_diagnostics" `Quick
          test_suite_run_all_streams_preserve_stderr_diagnostics;
        Alcotest.test_case "timing_record_format" `Quick
          test_timing_event_has_stable_machine_readable_format;
        Alcotest.test_case "source_budget_compilation_groups" `Quick
          test_compilation_groups_follow_source_budget_not_suite_count;
        Alcotest.test_case "sanitized_harness_source_budget" `Quick
          test_sanitized_harnesses_use_smaller_source_budget;
        Alcotest.test_case "combined_harness_globals_and_failures" `Quick
          test_suite_harness_combines_globals_and_reports_failures;
        Alcotest.test_case "uses_blorp_frontend" `Quick
          test_suite_harness_uses_blorp_frontend;
        Alcotest.test_case "compile_failure_is_hard_failure" `Quick
          test_suite_selector_compile_failure_is_hard_failure;
        Alcotest.test_case "uses_leak_check_runner" `Quick
          test_suite_selector_harness_uses_leak_check_runner;
      ] );
    ( "doctests",
      [
        Alcotest.test_case "module_and_local_imports" `Quick
          test_doctest_harness_allows_module_and_local_imports;
      ] );
  ]
