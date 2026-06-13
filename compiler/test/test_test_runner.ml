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

let test_sanitizer_mode_cc_args () =
  let open Blorp.Test_runner in
  let has arg args = List.exists (( = ) arg) args in
  let off_args = sanitizer_cc_args SanitizerOff in
  let address_args = sanitizer_cc_args SanitizerAddressUndefined in
  let undefined_args = sanitizer_cc_args SanitizerUndefinedOnly in
  Alcotest.(check (list string)) "off args" [] off_args;
  Alcotest.(check bool)
    "address mode includes ASan and UBSan" true
    (has "-fsanitize=address,undefined" address_args);
  Alcotest.(check bool)
    "undefined mode includes UBSan" true
    (has "-fsanitize=undefined" undefined_args);
  Alcotest.(check bool)
    "undefined mode excludes ASan" false
    (has "-fsanitize=address,undefined" undefined_args)

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
      let root = Blorp.Test_runner.current_run_artifact_root () in
      let first =
        Blorp.Test_runner.run_artifact_path ~kind:"bins" ~prefix:"sample"
          ~suffix:".bin"
      in
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
      let root = Blorp.Test_runner.current_run_artifact_root () in
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
        Blorp.Test_runner.current_run_artifact_root ())
  in
  let second =
    Blorp.Test_runner.with_run_artifacts (fun () ->
        Blorp.Test_runner.current_run_artifact_root ())
  in
  Alcotest.(check bool) "separate runs use separate roots" true (first <> second)

let test_compilation_dirs_are_run_scoped () =
  Blorp.Test_runner.with_run_artifacts (fun () ->
      let root = Blorp.Test_runner.current_run_artifact_root () in
      let first = Blorp.Test_runner.run_compilation_dir () in
      let second = Blorp.Test_runner.run_compilation_dir () in
      let parent = Filename.concat root "compilations" in
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
      let root = Blorp.Test_runner.current_run_artifact_root () in
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
        match snd (Unix.waitpid [] pid) with
        | Unix.WEXITED code -> (code, dir)
        | Unix.WSIGNALED signal -> (128 + signal, dir)
        | Unix.WSTOPPED signal -> (128 + signal, dir)
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

let test_collect_test_files_preserves_multi_root_order () =
  with_temp_dir "blorp-test-roots-" (fun dir ->
      let std_dir = Filename.concat dir "test_std" in
      let pkg_dir = Filename.concat dir "test_pkg" in
      Unix.mkdir std_dir 0o700;
      Unix.mkdir pkg_dir 0o700;
      let std_a_file = Filename.concat std_dir "test_a.brp" in
      let std_z_file = Filename.concat std_dir "test_z.brp" in
      let pkg_file = Filename.concat pkg_dir "test_crypto.brp" in
      let ignored_file = Filename.concat std_dir "helper.brp" in
      let write_suite file description test_name =
        write_file file
          (Printf.sprintf
             {|
import:
    test: TestSuite

func %s() -> Bool:
    True

tests: TestSuite = {
    description = "%s",
    tests = [("%s", %s)]
}
|}
             test_name description description test_name)
      in
      write_suite std_z_file "std z" "test_std_z";
      write_suite std_a_file "std a" "test_std_a";
      write_file pkg_file {|
func main(args: List[String]) -> Int:
    0
|};
      write_file ignored_file {|
pure func helper() -> Int:
    1
|};
      Alcotest.(check (list string))
        "valid test files from each root"
        [ std_a_file; std_z_file; pkg_file ]
        (Blorp.Test_runner.collect_test_files [ std_dir; pkg_dir ]))

let with_env name value f =
  let old = Sys.getenv_opt name in
  Unix.putenv name value;
  Fun.protect
    ~finally:(fun () ->
      match old with
      | Some v -> Unix.putenv name v
      | None -> Unix.putenv name "")
    f

let shell_quote s =
  "'" ^ String.concat "'\\''" (String.split_on_char '\'' s) ^ "'"

let test_precompile_runtime_writes_verified_manifest () =
  Blorp.Test_runner.with_run_artifacts (fun () ->
      match Blorp.Test_runner.precompile_runtime ~opt:"O0" () with
      | None -> Alcotest.fail "runtime precompile failed"
      | Some precompiled ->
          let dir = Filename.dirname precompiled.runtime_obj in
          let manifest_path = Filename.concat dir "MANIFEST" in
          let ready_path = Filename.concat dir "READY" in
          let manifest = read_whole_file manifest_path in
          let manifest_lines = String.split_on_char '\n' manifest in
          Alcotest.(check bool)
            "ready marker exists" true
            (Sys.file_exists ready_path);
          Alcotest.(check bool)
            "manifest version" true
            (String.contains manifest '\n'
            && String.starts_with ~prefix:"runtime-cache-manifest-v1\n" manifest
            );
          Alcotest.(check bool)
            "manifest records runtime.o digest" true
            (List.exists
               (( = )
                  ("runtime.o="
                  ^ Digest.to_hex (Digest.file precompiled.runtime_obj)))
               manifest_lines);
          Alcotest.(check bool)
            "manifest records runtime.h digest" true
            (List.exists
               (( = )
                  ("runtime.h="
                  ^ Digest.to_hex (Digest.file precompiled.header_file)))
               manifest_lines);
          Alcotest.(check bool)
            "manifest records TLS backend" true
            (List.exists
               (( = )
                  ("tls_backend="
                  ^ Blorp.Test_runner.tls_backend_profile_to_string
                      precompiled.tls_backend))
               manifest_lines))

let test_tls_backend_profile_env_parsing () =
  let check_profile label expected value =
    with_env "BLORP_TLS_BACKEND" value (fun () ->
        match Blorp.Test_runner.configured_tls_backend_profile () with
        | Ok actual -> Alcotest.(check bool) label true (actual = expected)
        | Error msg -> Alcotest.fail msg)
  in
  check_profile "default profile" Blorp.Test_runner.TlsUnsupported "unsupported";
  check_profile "openssl profile" Blorp.Test_runner.TlsOpenSsl "openssl";
  with_env "BLORP_TLS_BACKEND" "bogus" (fun () ->
      match Blorp.Test_runner.configured_tls_backend_profile () with
      | Ok _ -> Alcotest.fail "invalid TLS backend profile accepted"
      | Error msg ->
          Alcotest.(check bool)
            "mentions env var" true
            (contains_substring msg "BLORP_TLS_BACKEND"))

let test_tls_backend_openssl_args_use_named_configuration () =
  with_env "BLORP_OPENSSL_CFLAGS" "-I/tmp/blorp-openssl/include -DTEST_TLS"
    (fun () ->
      Alcotest.(check (list string))
        "openssl runtime args include define and configured cflags"
        [
          "-DBLORP_TLS_BACKEND_PROFILE_OPENSSL=1";
          "-I/tmp/blorp-openssl/include";
          "-DTEST_TLS";
        ]
        (Blorp.Test_runner.tls_backend_runtime_cc_args
           Blorp.Test_runner.TlsOpenSsl));
  with_env "BLORP_OPENSSL_LIBS" "-L/tmp/blorp-openssl/lib -lssl -lcrypto"
    (fun () ->
      Alcotest.(check (list string))
        "openssl link args use configured libs"
        [ "-L/tmp/blorp-openssl/lib"; "-lssl"; "-lcrypto" ]
        (Blorp.Test_runner.tls_backend_link_cc_args Blorp.Test_runner.TlsOpenSsl))

let test_precompile_runtime_reuses_verified_cache () =
  let real_cc =
    let code, output =
      Blorp.Test_runner.run_process_capture_timeout ~timeout:None "sh"
        [ "-c"; "command -v cc" ]
    in
    if code <> 0 then Alcotest.fail "could not find cc";
    String.trim output
  in
  with_temp_dir "blorp-runtime-cache-" (fun dir ->
      let home = Filename.concat dir "home" in
      let fake_bin = Filename.concat dir "bin" in
      let log_path = Filename.concat dir "cc.log" in
      Unix.mkdir home 0o700;
      Unix.mkdir fake_bin 0o700;
      let fake_cc = Filename.concat fake_bin "cc" in
      write_file fake_cc
        (Printf.sprintf
           {|#!/bin/sh
for arg in "$@"; do
    if [ "$arg" = "-c" ]; then
        echo compile >> "$BLORP_FAKE_CC_LOG"
        break
    fi
done
exec %s "$@"
|}
           (shell_quote real_cc));
      Unix.chmod fake_cc 0o755;
      let old_path = Option.value (Sys.getenv_opt "PATH") ~default:"" in
      with_env "HOME" home (fun () ->
          with_env "BLORP_FAKE_CC_LOG" log_path (fun () ->
              with_env "PATH"
                (fake_bin ^ ":" ^ old_path)
                (fun () ->
                  Blorp.Test_runner.with_run_artifacts (fun () ->
                      let first =
                        Blorp.Test_runner.precompile_runtime ~opt:"O0" ()
                      in
                      let second =
                        Blorp.Test_runner.precompile_runtime ~opt:"O0" ()
                      in
                      let compile_count =
                        if Sys.file_exists log_path then
                          read_whole_file log_path |> String.split_on_char '\n'
                          |> List.filter (fun line -> String.trim line <> "")
                          |> List.length
                        else 0
                      in
                      match (first, second) with
                      | Some a, Some b ->
                          Alcotest.(check string)
                            "same runtime object" a.runtime_obj b.runtime_obj;
                          Alcotest.(check int)
                            "runtime compiled once" 1 compile_count
                      | _ -> Alcotest.fail "runtime precompile failed")))))

let test_precompile_runtime_repairs_incomplete_cache () =
  let real_cc =
    let code, output =
      Blorp.Test_runner.run_process_capture_timeout ~timeout:None "sh"
        [ "-c"; "command -v cc" ]
    in
    if code <> 0 then Alcotest.fail "could not find cc";
    String.trim output
  in
  with_temp_dir "blorp-runtime-cache-repair-" (fun dir ->
      let home = Filename.concat dir "home" in
      let fake_bin = Filename.concat dir "bin" in
      let log_path = Filename.concat dir "cc.log" in
      Unix.mkdir home 0o700;
      Unix.mkdir fake_bin 0o700;
      let fake_cc = Filename.concat fake_bin "cc" in
      write_file fake_cc
        (Printf.sprintf
           {|#!/bin/sh
for arg in "$@"; do
    if [ "$arg" = "-c" ]; then
        echo compile >> "$BLORP_FAKE_CC_LOG"
        break
    fi
done
exec %s "$@"
|}
           (shell_quote real_cc));
      Unix.chmod fake_cc 0o755;
      let old_path = Option.value (Sys.getenv_opt "PATH") ~default:"" in
      with_env "HOME" home (fun () ->
          with_env "BLORP_FAKE_CC_LOG" log_path (fun () ->
              with_env "PATH"
                (fake_bin ^ ":" ^ old_path)
                (fun () ->
                  Blorp.Test_runner.with_run_artifacts (fun () ->
                      let first =
                        Blorp.Test_runner.precompile_runtime ~opt:"O0" ()
                      in
                      let first_dir =
                        match first with
                        | Some p -> Filename.dirname p.runtime_obj
                        | None -> Alcotest.fail "initial precompile failed"
                      in
                      Sys.remove (Filename.concat first_dir "READY");
                      let repaired =
                        Blorp.Test_runner.precompile_runtime ~opt:"O0" ()
                      in
                      let compile_count =
                        if Sys.file_exists log_path then
                          read_whole_file log_path |> String.split_on_char '\n'
                          |> List.filter (fun line -> String.trim line <> "")
                          |> List.length
                        else 0
                      in
                      match repaired with
                      | Some p ->
                          Alcotest.(check bool)
                            "repaired ready marker" true
                            (Sys.file_exists
                               (Filename.concat
                                  (Filename.dirname p.runtime_obj)
                                  "READY"));
                          Alcotest.(check int)
                            "runtime recompiled after stale cache" 2
                            compile_count
                      | None -> Alcotest.fail "repair precompile failed")))))

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

let test_suite_run_all_batch_timeout_scales_by_suite_count () =
  let suite_count = 64 in
  let per_suite_timeout_seconds = 30 in
  let expected_batch_timeout_seconds =
    suite_count * per_suite_timeout_seconds
  in
  Alcotest.(check (option int))
    "disabled timeout remains disabled" None
    (Blorp.Test_runner.timeout_for_suite_run_all_batch ~suite_count None);
  Alcotest.(check (option int))
    "zero timeout remains disabled" (Some 0)
    (Blorp.Test_runner.timeout_for_suite_run_all_batch ~suite_count (Some 0));
  Alcotest.(check (option int))
    "single suite timeout is unchanged" (Some per_suite_timeout_seconds)
    (Blorp.Test_runner.timeout_for_suite_run_all_batch ~suite_count:1
       (Some per_suite_timeout_seconds));
  Alcotest.(check (option int))
    "batch timeout scales by suite count" (Some expected_batch_timeout_seconds)
    (Blorp.Test_runner.timeout_for_suite_run_all_batch ~suite_count
       (Some per_suite_timeout_seconds))

let test_memory_suite_paths_require_filesystem_isolation () =
  let cwd = Sys.getcwd () in
  Alcotest.(check bool)
    "memory directory is isolated" true
    (Blorp.Test_runner.requires_filesystem_isolation
       "tests/test_blorp/memory/test_memstats_observability.brp");
  Alcotest.(check bool)
    "absolute memory directory path is isolated" true
    (Blorp.Test_runner.requires_filesystem_isolation
       (Filename.concat cwd
          "tests/test_blorp/memory/test_builtin_borrowed_arg_ownership.brp"));
  Alcotest.(check bool)
    "ordinary type suite is not filesystem isolated" false
    (Blorp.Test_runner.requires_filesystem_isolation
       "tests/test_blorp/types/test_bool.brp")

let test_runtime_sensitive_suite_paths_require_process_isolation () =
  Alcotest.(check bool)
    "memory directory is process isolated" true
    (Blorp.Test_runner.requires_process_isolation
       "tests/test_blorp/memory/test_memstats_observability.brp");
  Alcotest.(check bool)
    "concurrency suites are process isolated" true
    (Blorp.Test_runner.requires_process_isolation
       "tests/test_blorp/concurrency/test_list_concurrent.brp");
  Alcotest.(check bool)
    "system resource suites are process isolated" true
    (Blorp.Test_runner.requires_process_isolation
       "tests/test_blorp/sys/test_file_resource.brp");
  Alcotest.(check bool)
    "ordinary type suite is not process isolated" false
    (Blorp.Test_runner.requires_process_isolation
       "tests/test_blorp/types/test_bool.brp")

let test_suite_harness_runs_combined_without_result_cache () =
  with_temp_dir "blorp-suite-selector-" (fun dir ->
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
      let old_cwd = Sys.getcwd () in
      Fun.protect
        ~finally:(fun () -> Sys.chdir old_cwd)
        (fun () ->
          Sys.chdir dir;
          with_env "HOME" home (fun () ->
              let code =
                Blorp.Test_runner.run_tests ~timeout:(Some 10) ~jobs:1
                  ~cache:true "."
              in
              let test_results_dir =
                Filename.concat home ".cache/blorp/cas/test-results"
              in
              Alcotest.(check int) "combined suite run" 0 code;
              Alcotest.(check bool)
                "run-all skips per-file result cache" false
                (Sys.file_exists test_results_dir))))

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
          with_env "HOME" home (fun () ->
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
      ] );
    ( "timeouts",
      [
        Alcotest.test_case "capture_timeout_inherited_pipe" `Quick
          test_capture_timeout_does_not_wait_for_inherited_pipe;
        Alcotest.test_case "capture_timeout_sigterm_before_sigkill" `Quick
          test_capture_timeout_sends_sigterm_before_sigkill;
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
        Alcotest.test_case "mode_cc_args" `Quick test_sanitizer_mode_cc_args;
      ] );
    ( "precompiled_runtime",
      [
        Alcotest.test_case "writes_verified_manifest" `Quick
          test_precompile_runtime_writes_verified_manifest;
        Alcotest.test_case "tls_backend_env_parsing" `Quick
          test_tls_backend_profile_env_parsing;
        Alcotest.test_case "tls_backend_openssl_args" `Quick
          test_tls_backend_openssl_args_use_named_configuration;
        Alcotest.test_case "reuses_verified_cache" `Quick
          test_precompile_runtime_reuses_verified_cache;
        Alcotest.test_case "repairs_incomplete_cache" `Quick
          test_precompile_runtime_repairs_incomplete_cache;
      ] );
    ( "suite_selector_harness",
      [
        Alcotest.test_case "collects_multi_root_files" `Quick
          test_collect_test_files_preserves_multi_root_order;
        Alcotest.test_case "dispatches_by_index" `Quick
          test_suite_selector_harness_dispatches_by_index;
        Alcotest.test_case "run_all_generated_functions" `Quick
          test_suite_run_all_harness_calls_generated_functions;
        Alcotest.test_case "run_all_batch_timeout" `Quick
          test_suite_run_all_batch_timeout_scales_by_suite_count;
        Alcotest.test_case "memory_filesystem_isolation_policy" `Quick
          test_memory_suite_paths_require_filesystem_isolation;
        Alcotest.test_case "runtime_sensitive_process_isolation_policy" `Quick
          test_runtime_sensitive_suite_paths_require_process_isolation;
        Alcotest.test_case "combined_harness_skips_result_cache" `Quick
          test_suite_harness_runs_combined_without_result_cache;
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
