(** In-process runner for compiler surface tests.

    Parser, inference, and typecheck tests run in-process. Formatter and purify
    tests intentionally exercise the public CLI surface, while the codegen audit
    keeps its shell runner because it validates generated C with the host C
    compiler. *)

open Blorp

type opts = {
  verbose : bool;
  timeout : int option;
  blorp_bin : string;
  run_codegen_audit : bool;
  case_selection : case_selection;
  gate_name : string;
  jobs : int;
}

and case_selection = AllCases | SurfaceCases | ToolCasesOnly

type expectations = {
  exact : string list;
  contains : string list;
  not_contains : string list;
}

type expectation_groups = {
  generic : expectations;
  blorp_frontend : expectations;
}

type expectation_acc = {
  exact_acc : string list ref;
  contains_acc : string list ref;
  not_contains_acc : string list ref;
}

type case_kind =
  | ParserShouldPass
  | ParserShouldFail
  | TypecheckShouldPass of string
  | TypecheckShouldFail of string
  | FormatShouldPass
  | FormatShouldFail
  | FormatShouldError
  | PurifyShouldPurify
  | PurifyShouldNotPurify
  | PurifyShouldRewrite

type test_case = { kind : case_kind; file : string }
type command_result = { code : int; output : string }

type run_context = { typecheck_session : Session.t }

type codegen_audit_summary = {
  codegen_passed : int;
  codegen_failed : int;
  codegen_total : int;
  codegen_detail_lines : string list;
  codegen_runner_failure : string list option;
}

let starts_with s prefix =
  let s_len = String.length s in
  let p_len = String.length prefix in
  s_len >= p_len && String.sub s 0 p_len = prefix

let drop_prefix s prefix =
  if starts_with s prefix then
    Some
      (String.sub s (String.length prefix)
         (String.length s - String.length prefix))
  else None

let find_substring s needle =
  let s_len = String.length s in
  let needle_len = String.length needle in
  let rec loop i =
    if i + needle_len > s_len then None
    else if String.sub s i needle_len = needle then Some i
    else loop (i + 1)
  in
  loop 0

let diagnostic_after_marker line marker =
  match find_substring line marker with
  | None -> None
  | Some index ->
      let start = index + String.length marker in
      Some
        (String.sub line start (String.length line - start))

let split_lines s = String.split_on_char '\n' s

let expectations_have_checks expectations =
  expectations.exact <> []
  || expectations.contains <> []
  || expectations.not_contains <> []

let make_expectation_acc () =
  { exact_acc = ref []; contains_acc = ref []; not_contains_acc = ref [] }

let finish_expectation_acc acc =
  {
    exact = List.rev !(acc.exact_acc);
    contains = List.rev !(acc.contains_acc);
    not_contains = List.rev !(acc.not_contains_acc);
  }

let select_expectation_acc ~generic ~blorp_frontend = function
  | `Generic -> generic
  | `BlorpFrontend -> blorp_frontend

let summarize_codegen_audit_output ~exit_code output =
  let passed = ref 0 in
  let failed = ref 0 in
  let total = ref 0 in
  let cases = ref 0 in
  let detail_lines = ref [] in
  output |> split_lines
  |> List.iter (fun line ->
         match drop_prefix line "PASS: " with
         | Some _name ->
             incr passed;
             incr total;
             incr cases
         | None -> (
             match drop_prefix line "FAIL: " with
             | Some _name ->
                 incr failed;
                 incr total;
                 incr cases
             | None ->
                 if line = "" || starts_with line "Results:" then ()
                 else detail_lines := line :: !detail_lines));
  let runner_failure =
    if exit_code = 0 then None
    else begin
      incr failed;
      incr total;
      if !cases = 0 then
        Some
          ("runner failed before reporting test results"
          :: (output |> split_lines
             |> List.filter (( <> ) "")
             |> List.filteri (fun i _ -> i < 10)))
      else
        Some
          [
            Printf.sprintf
              "runner exited with status %d after reporting %d test result(s)"
              exit_code !cases;
          ]
    end
  in
  {
    codegen_passed = !passed;
    codegen_failed = !failed;
    codegen_total = !total;
    codegen_detail_lines = List.rev !detail_lines;
    codegen_runner_failure = runner_failure;
  }

let read_file = Modules.read_file

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
      try Unix.rmdir path with _ -> ()
    end
    else try Unix.unlink path with _ -> ()

let make_temp_dir prefix =
  let base = Filename.get_temp_dir_name () in
  let rec loop attempt =
    let suffix =
      Printf.sprintf "%d-%d" (Unix.getpid ()) (Random.bits () land 0x3fffffff)
    in
    let path = Filename.concat base (prefix ^ suffix) in
    try
      Unix.mkdir path 0o700;
      path
    with Unix.Unix_error (Unix.EEXIST, _, _) when attempt < 100 ->
      loop (attempt + 1)
  in
  loop 0

let with_temp_dir prefix f =
  let dir = make_temp_dir prefix in
  Fun.protect ~finally:(fun () -> remove_tree dir) (fun () -> f dir)

let sorted_brp_files dir =
  if Sys.file_exists dir && Sys.is_directory dir then
    Sys.readdir dir |> Array.to_list
    |> List.filter (fun name -> Filename.check_suffix name ".brp")
    |> List.sort String.compare
    |> List.map (fun name -> Filename.concat dir name)
  else []

let collect_cases selection =
  let parser_pass =
    sorted_brp_files "tests/test_compiler/parser/should_pass"
    |> List.map (fun file -> { kind = ParserShouldPass; file })
  in
  let parser_fail =
    sorted_brp_files "tests/test_compiler/parser/should_fail"
    |> List.map (fun file -> { kind = ParserShouldFail; file })
  in
  let checked category =
    let root = Filename.concat "tests/test_compiler" category in
    let pass =
      sorted_brp_files (Filename.concat root "should_pass")
      |> List.map (fun file -> { kind = TypecheckShouldPass category; file })
    in
    let fail =
      sorted_brp_files (Filename.concat root "should_fail")
      |> List.map (fun file -> { kind = TypecheckShouldFail category; file })
    in
    pass @ fail
  in
  let format_cases =
    (sorted_brp_files "tests/test_compiler/format/should_pass"
    |> List.map (fun file -> { kind = FormatShouldPass; file }))
    @ (sorted_brp_files "tests/test_compiler/format/should_fail"
      |> List.map (fun file -> { kind = FormatShouldFail; file }))
    @ (sorted_brp_files "tests/test_compiler/format/should_error"
      |> List.map (fun file -> { kind = FormatShouldError; file }))
  in
  let purify_cases =
    (sorted_brp_files "tests/test_compiler/purify/should_purify"
    |> List.map (fun file -> { kind = PurifyShouldPurify; file }))
    @ (sorted_brp_files "tests/test_compiler/purify/should_not_purify"
      |> List.map (fun file -> { kind = PurifyShouldNotPurify; file }))
    @ (sorted_brp_files "tests/test_compiler/purify/should_rewrite"
      |> List.map (fun file -> { kind = PurifyShouldRewrite; file }))
  in
  let surface_cases =
    parser_pass @ parser_fail @ checked "typecheck" @ checked "infer"
  in
  let tool_cases = format_cases @ purify_cases in
  match selection with
  | AllCases -> surface_cases @ tool_cases
  | SurfaceCases -> surface_cases
  | ToolCasesOnly -> tool_cases

let parse_expectation_line line =
  let prefixes =
    [
      ("-- EXPECT: ", `Generic, `Exact, false);
      ("-- EXPECT-CONTAINS:", `Generic, `Contains, true);
      ("-- EXPECT-NOT-CONTAINS:", `Generic, `NotContains, true);
      ("-- EXPECT-BLORP: ", `BlorpFrontend, `Exact, false);
      ("-- EXPECT-BLORP-CONTAINS:", `BlorpFrontend, `Contains, true);
      ("-- EXPECT-BLORP-NOT-CONTAINS:", `BlorpFrontend, `NotContains, true);
    ]
  in
  prefixes
  |> List.find_map (fun (prefix, scope, kind, trim) ->
         match drop_prefix line prefix with
         | None -> None
         | Some expected ->
             let expected = if trim then String.trim expected else expected in
             Some (scope, kind, expected))

let parse_expectation_groups source =
  let generic = make_expectation_acc () in
  let blorp_frontend = make_expectation_acc () in
  source |> split_lines
  |> List.iter (fun line ->
         match parse_expectation_line line with
         | None -> ()
         | Some (scope, kind, expected) ->
             let acc =
               select_expectation_acc ~generic ~blorp_frontend scope
             in
             begin
               match kind with
               | `Exact -> acc.exact_acc := expected :: !(acc.exact_acc)
               | `Contains ->
                   acc.contains_acc := expected :: !(acc.contains_acc)
               | `NotContains ->
                   acc.not_contains_acc := expected :: !(acc.not_contains_acc)
             end);
  {
    generic = finish_expectation_acc generic;
    blorp_frontend = finish_expectation_acc blorp_frontend;
  }

let expectations_for_blorp_frontend groups =
  let frontend_expectations = groups.blorp_frontend in
  if expectations_have_checks frontend_expectations then frontend_expectations
  else groups.generic

let load_expectations file =
  read_file file |> parse_expectation_groups |> expectations_for_blorp_frontend

let normalized_diagnostic_lines test output =
  let file_prefix = test ^ ": " in
  output |> split_lines
  |> List.filter_map (fun line ->
      match drop_prefix line file_prefix with
      | Some rest -> Some rest
      | None when starts_with line "error: " || starts_with line "warning: " ->
          Some line
      | None -> (
          let trimmed = String.trim line in
          match diagnostic_after_marker trimmed ": error: " with
          | Some rest -> Some ("error: " ^ rest)
          | None -> (
              match diagnostic_after_marker trimmed ": warning: " with
              | Some rest -> Some ("warning: " ^ rest)
              | None ->
                  if starts_with trimmed "expected: "
                     || starts_with trimmed "found: "
                     || starts_with trimmed "help: "
                     || starts_with trimmed "note: "
                  then Some trimmed
                  else
                    match drop_prefix trimmed "= help: " with
                    | Some rest -> Some ("help: " ^ rest)
                    | None -> (
                        match drop_prefix trimmed "= note: " with
                        | Some rest -> Some ("note: " ^ rest)
                        | None -> None))))

let check_error_expectations file output mismatch_detail =
  let expectations = load_expectations file in
  let diagnostics = normalized_diagnostic_lines file output in
  let details = ref [] in
  let add detail = details := detail :: !details in
  List.iter
    (fun expected ->
      if expected <> "" && not (List.exists (( = ) expected) diagnostics) then
        add (Printf.sprintf "Missing exact diagnostic line: \"%s\"" expected))
    expectations.exact;
  List.iter
    (fun expected ->
      if expected <> "" && not (Modules.contains output expected) then
        add (Printf.sprintf "Missing output substring: \"%s\"" expected))
    expectations.contains;
  match List.rev !details with
  | [] -> None
  | missing ->
      let diagnostic_details =
        match diagnostics with
        | [] -> [ "Normalized diagnostic lines:"; "  (none)" ]
        | lines ->
            "Normalized diagnostic lines:" :: List.map (fun s -> "  " ^ s) lines
      in
      let actual_output =
        "Actual output:"
        :: (output |> split_lines
           |> List.filter (( <> ) "")
           |> List.filteri (fun i _ -> i < 10)
           |> List.map (fun s -> "  " ^ s))
      in
      Some ((mismatch_detail :: missing) @ diagnostic_details @ actual_output)

let run_safely f =
  try f ()
  with exn ->
    {
      code = 2;
      output =
        Printf.sprintf
          "Internal compiler error: %s\nThis is a bug in the blorp compiler.\n"
          (Printexc.to_string exn);
    }

let run_parse file =
  run_safely (fun () ->
      let source = read_file file in
      let sess = Session.create () in
      Session.with_current sess (fun () ->
          Modules.init_module_paths (Modules.extract_directory file);
          match Modules.parse_raw_source ~filename:file source with
          | Ok _ -> { code = 0; output = "" }
          | Error err ->
              { code = 1; output = Diagnostics.format_error ~file err }))

let format_pipeline_errors ~file errors = Diagnostics.format_errors ~file errors

let create_run_context () = { typecheck_session = Session.create () }

let blorp_check_marker = "-- RUN-BLORP-CHECK"

let run_with_blorp_check opts file =
  let code, output =
    Test_runner.run_process_capture_timeout ~timeout:opts.timeout opts.blorp_bin
      [ "check"; "--no-format"; file ]
  in
  { code; output }

let requires_blorp_check file =
  read_file file |> split_lines
  |> List.exists (fun line -> String.trim line = blorp_check_marker)

let run_typecheck opts context file =
  run_safely (fun () ->
      if requires_blorp_check file then run_with_blorp_check opts file
      else
        let source = read_file file in
        match
          Pipeline.typecheck_only_typed_reusing_session
            ~sess:context.typecheck_session ~filename:file ~source
            ~debug:false ()
        with
        | Ok _ -> { code = 0; output = "Type checking succeeded.\n" }
        | Error errors ->
            { code = 1; output = format_pipeline_errors ~file errors })

let run_format opts args =
  let code, output =
    Test_runner.run_process_capture_timeout ~timeout:opts.timeout opts.blorp_bin
      args
  in
  { code; output }

let run_format_check opts file =
  run_safely (fun () ->
      run_format opts [ "format"; "--check"; file ])

let run_purify opts args =
  let code, output =
    Test_runner.run_process_capture_timeout ~timeout:opts.timeout opts.blorp_bin
      args
  in
  { code; output }

let uncomment_expectation_lines source =
  source |> split_lines
  |> List.filter (fun line -> not (starts_with line "-- EXPECT-"))
  |> String.concat "\n"

let body_contains_expectations original_file rewritten_source =
  let expectations = load_expectations original_file in
  let body = uncomment_expectation_lines rewritten_source in
  let details = ref [] in
  List.iter
    (fun expected ->
      if expected <> "" && not (Modules.contains body expected) then
        details :=
          Printf.sprintf "Missing rewritten text: %s" expected :: !details)
    expectations.contains;
  List.iter
    (fun forbidden ->
      if forbidden <> "" && Modules.contains body forbidden then
        details :=
          Printf.sprintf "Forbidden rewritten text present: %s" forbidden
          :: !details)
    expectations.not_contains;
  List.rev !details

let copy_file source target = write_file target (read_file source)

let emit_pass opts suite testname =
  if opts.verbose then Printf.printf "PASS: [%s] %s\n%!" suite testname

let emit_fail suite testname details =
  Printf.printf "FAIL: [%s] %s\n%!" suite testname;
  List.iter (fun detail -> Printf.printf "DETAIL %s\n%!" detail) details

let fail suite testname details = `Fail (suite, testname, details)
let pass suite testname = `Pass (suite, testname)
let testname file = Filename.basename file

let run_case opts context { kind; file } =
  let name = testname file in
  match kind with
  | ParserShouldPass ->
      let result = run_parse file in
      if result.code = 0 then pass "should_pass/parser" name
      else
        fail "should_pass/parser" name
          ([ "Expected: parse success"; "Got: parse failed" ]
          @ (result.output |> split_lines
            |> List.filter (( <> ) "")
            |> List.filteri (fun i _ -> i < 5)))
  | ParserShouldFail -> (
      let result = run_parse file in
      if result.code = 0 then
        fail "should_fail/parser" name
          [ "Expected: parse failure"; "Got: parse succeeded" ]
      else
        match
          check_error_expectations file result.output
            "Parse failed, but error message mismatch:"
        with
        | None -> pass "should_fail/parser" name
        | Some details -> fail "should_fail/parser" name details)
  | TypecheckShouldPass category ->
      let result = run_typecheck opts context file in
      if result.code = 0 then pass ("should_pass/" ^ category) name
      else
        fail
          ("should_pass/" ^ category)
          name
          ([ "Expected: compilation success"; "Got: compilation failed" ]
          @ (result.output |> split_lines
            |> List.filter (( <> ) "")
            |> List.filteri (fun i _ -> i < 5)))
  | TypecheckShouldFail category -> (
      let result = run_typecheck opts context file in
      if result.code = 0 then
        fail
          ("should_fail/" ^ category)
          name
          [ "Expected: compilation failure"; "Got: compilation succeeded" ]
      else
        match
          check_error_expectations file result.output
            "Compilation failed, but error message mismatch:"
        with
        | None -> pass ("should_fail/" ^ category) name
        | Some details -> fail ("should_fail/" ^ category) name details)
  | FormatShouldPass ->
      let result = run_format_check opts file in
      if result.code = 0 then pass "format/should_pass" name
      else
        fail "format/should_pass" name
          ([
             "Expected: already formatted";
             "Got: needs formatting or formatter error";
           ]
          @ (result.output |> split_lines
            |> List.filter (( <> ) "")
            |> List.filteri (fun i _ -> i < 5)))
  | FormatShouldFail ->
      let result = run_format_check opts file in
      if result.code <> 0 then pass "format/should_fail" name
      else
        fail "format/should_fail" name
          [ "Expected: needs formatting"; "Got: already formatted" ]
  | FormatShouldError -> (
      let result = run_format_check opts file in
      if result.code = 0 then
        fail "format/should_error" name
          [ "Expected: formatter error"; "Got: format succeeded" ]
      else
        match
          check_error_expectations file result.output
            "Formatter rejected, but error message mismatch:"
        with
        | None -> pass "format/should_error" name
        | Some details -> fail "format/should_error" name details)
  | PurifyShouldPurify ->
      let result = run_purify opts [ "purify"; "--dry-run"; file ] in
      if result.code = 124 then
        fail "purify/should_purify" name [ "Purify timed out" ]
      else if result.code <> 0 then
        fail "purify/should_purify" name
          ("Purify failed"
          :: (result.output |> split_lines |> List.filter (( <> ) "")))
      else if String.trim result.output <> "" then
        pass "purify/should_purify" name
      else
        fail "purify/should_purify" name
          [ "Expected: functions to purify"; "Got: nothing purifiable" ]
  | PurifyShouldNotPurify ->
      let result = run_purify opts [ "purify"; "--dry-run"; file ] in
      if result.code = 124 then
        fail "purify/should_not_purify" name [ "Purify timed out" ]
      else if result.code <> 0 then
        fail "purify/should_not_purify" name
          ("Purify failed"
          :: (result.output |> split_lines |> List.filter (( <> ) "")))
      else if String.trim result.output = "" then
        pass "purify/should_not_purify" name
      else
        fail "purify/should_not_purify" name
          ("Expected: nothing purifiable"
          :: (result.output |> split_lines |> List.filter (( <> ) "")))
  | PurifyShouldRewrite ->
      with_temp_dir "blorp-purify-test-" (fun dir ->
          let tmpfile = Filename.concat dir name in
          copy_file file tmpfile;
          let result = run_purify opts [ "purify"; tmpfile ] in
          if result.code = 124 then
            fail "purify/should_rewrite" name [ "Purify timed out" ]
          else if result.code <> 0 then
            fail "purify/should_rewrite" name
              ("Purify failed"
              :: (result.output |> split_lines |> List.filter (( <> ) "")))
          else
            let check = run_typecheck opts context tmpfile in
            if check.code <> 0 then
              fail "purify/should_rewrite" name
                ("Rewritten file did not typecheck"
                :: (check.output |> split_lines |> List.filter (( <> ) "")))
            else
              match body_contains_expectations file (read_file tmpfile) with
              | [] -> pass "purify/should_rewrite" name
              | details -> fail "purify/should_rewrite" name details)
let prewarm_formatter_renderer opts =
  with_temp_dir "blorp-formatter-warmup-" (fun dir ->
      let file = Filename.concat dir "warmup.brp" in
      write_file file "func main(args: List[String]) -> Int:\n\t0\n";
      let result = run_format_check opts file in
      if result.code = 0 then Ok ()
      else if result.code = 124 then Error "Format warmup timed out"
      else Error (String.trim result.output))

let case_uses_formatter = function
  | { kind = FormatShouldPass | FormatShouldFail | FormatShouldError; _ } -> true
  | _ -> false

let run_case_list opts cases =
  let context = create_run_context () in
  let passed = ref 0 in
  let failed = ref 0 in
  let total = ref 0 in
  List.iter
    (fun case ->
      incr total;
      match run_case opts context case with
      | `Pass (suite, name) ->
          incr passed;
          emit_pass opts suite name
      | `Fail (suite, name, details) ->
          incr failed;
          emit_fail suite name details)
    cases;
  (!passed, !failed, !total)

let run_codegen_audit opts passed failed total =
  let script = "tests/test_compiler/codegen_audit/run_codegen_audit.sh" in
  if not (Sys.file_exists script) then begin
    emit_fail "codegen_audit" "runner" [ "missing runner: " ^ script ];
    incr failed;
    incr total
  end
  else begin
    Printf.printf "\nCodegen Audit\n%!";
    let code, output =
      Test_runner.run_process_capture_timeout ~timeout:None script
        [ opts.blorp_bin ]
    in
    let summary = summarize_codegen_audit_output ~exit_code:code output in
    passed := !passed + summary.codegen_passed;
    failed := !failed + summary.codegen_failed;
    total := !total + summary.codegen_total;
    output |> split_lines
    |> List.iter (fun line ->
        match drop_prefix line "PASS: " with
        | Some name ->
            if opts.verbose then
              Printf.printf "PASS: [codegen_audit] %s\n%!" name
        | None -> (
            match drop_prefix line "FAIL: " with
            | Some name ->
                Printf.printf "FAIL: [codegen_audit] %s\n%!" name
            | None ->
                if line = "" || starts_with line "Results:" then ()
                else Printf.printf "DETAIL %s\n%!" line));
    match summary.codegen_runner_failure with
    | None -> ()
    | Some details -> emit_fail "codegen_audit" "runner" details
  end

let rec collect_should_fail_files dir =
  if Sys.file_exists dir && Sys.is_directory dir then
    let children =
      Sys.readdir dir |> Array.to_list |> List.sort String.compare
      |> List.map (Filename.concat dir)
    in
    let here =
      if
        Filename.basename dir = "should_fail"
        && not (Modules.contains dir "/format/")
      then sorted_brp_files dir
      else []
    in
    here @ List.concat_map collect_should_fail_files children
  else []

let missing_expectation_count () =
  collect_should_fail_files "tests/test_compiler"
  |> List.fold_left
       (fun count file ->
         let expectations = load_expectations file in
         if expectations.exact = [] && expectations.contains = [] then begin
           Printf.printf "WARN Missing EXPECT annotation: %s\n%!"
             (Filename.basename file);
           count + 1
         end
         else count)
       0

let result_field line key =
  line |> String.split_on_char ' '
  |> List.find_map (fun part ->
      match String.split_on_char '=' part with
      | [ found_key; value ] when found_key = key -> int_of_string_opt value
      | _ -> None)

let parse_worker_result output =
  output |> split_lines
  |> List.find_map (fun line ->
      match drop_prefix line "BLORP_WORKER_RESULT " with
      | None -> None
      | Some rest -> (
          match
            ( result_field rest "passed",
              result_field rest "failed",
              result_field rest "tests" )
          with
          | Some passed, Some failed, Some total -> Some (passed, failed, total)
          | _ -> None))

let exit_code_of_status = function
  | Unix.WEXITED code -> code
  | Unix.WSIGNALED signal -> 128 + signal
  | Unix.WSTOPPED _ -> 128

let terminate_worker_pids pids =
  List.iter
    (fun pid -> try Unix.kill pid Sys.sigterm with _ -> ())
    pids

let install_worker_signal_cleanup active_worker_pids =
  let terminate_workers () = terminate_worker_pids !active_worker_pids in
  let handle signal =
    terminate_workers ();
    exit (128 + signal)
  in
  let previous_int =
    Sys.signal Sys.sigint (Sys.Signal_handle (fun _ -> handle Sys.sigint))
  in
  let previous_term =
    Sys.signal Sys.sigterm (Sys.Signal_handle (fun _ -> handle Sys.sigterm))
  in
  fun () ->
    ignore (Sys.signal Sys.sigint previous_int);
    ignore (Sys.signal Sys.sigterm previous_term)

let split_cases jobs cases =
  let case_count = List.length cases in
  let jobs = max 1 (min jobs case_count) in
  let chunks = Array.make jobs [] in
  List.iteri
    (fun index case ->
      let chunk_index = index mod jobs in
      chunks.(chunk_index) <- case :: chunks.(chunk_index))
    cases;
  Array.to_list chunks |> List.map List.rev

let run_cases_parallel opts cases =
  if opts.jobs <= 1 || List.length cases <= 1 then run_case_list opts cases
  else
    with_temp_dir "blorp-compiler-workers-" (fun dir ->
        let chunks = split_cases opts.jobs cases in
        flush stdout;
        flush stderr;
        let workers =
          chunks
          |> List.mapi (fun index chunk ->
              let output_file =
                Filename.concat dir (Printf.sprintf "worker_%03d.out" index)
              in
              match Unix.fork () with
              | 0 ->
                  let fd =
                    Unix.openfile output_file
                      [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC ]
                      0o600
                  in
                  Unix.dup2 fd Unix.stdout;
                  Unix.dup2 fd Unix.stderr;
                  Unix.close fd;
                  let passed, failed, total = run_case_list opts chunk in
                  Printf.printf
                    "BLORP_WORKER_RESULT passed=%d failed=%d tests=%d\n%!"
                    passed failed total;
                  exit (if failed = 0 then 0 else 1)
              | pid -> (pid, output_file))
        in
        let active_worker_pids = ref (List.map fst workers) in
        let restore_worker_signal_handlers =
          install_worker_signal_cleanup active_worker_pids
        in
        let passed = ref 0 in
        let failed = ref 0 in
        let total = ref 0 in
        try
          List.iter
            (fun (pid, output_file) ->
              let _, status = Unix.waitpid [] pid in
              active_worker_pids :=
                List.filter
                  (fun active_pid -> active_pid <> pid)
                  !active_worker_pids;
              let output =
                if Sys.file_exists output_file then read_file output_file
                else ""
              in
              output |> split_lines
              |> List.iter (fun line ->
                     if
                       line <> ""
                       && not (starts_with line "BLORP_WORKER_RESULT ")
                     then Printf.printf "%s\n%!" line);
              match parse_worker_result output with
              | Some (worker_passed, worker_failed, worker_total) ->
                  passed := !passed + worker_passed;
                  failed := !failed + worker_failed;
                  total := !total + worker_total
              | None ->
                  let code = exit_code_of_status status in
                  emit_fail "runner"
                    (Printf.sprintf "worker-%d" pid)
                    [
                      Printf.sprintf "worker exited without summary (exit %d)"
                        code;
                    ];
                  incr failed;
                  incr total)
            workers;
          restore_worker_signal_handlers ();
          (!passed, !failed, !total)
        with exn ->
          terminate_worker_pids !active_worker_pids;
          restore_worker_signal_handlers ();
          raise exn)

let run opts =
  Random.self_init ();
  let timeout_text =
    match opts.timeout with
    | Some 0 -> "child timeout disabled"
    | Some seconds -> Printf.sprintf "%ds child timeout" seconds
    | None -> "child timeout disabled"
  in
  Printf.printf "Compiler Tests (in-process, %d workers, %s)\n\n%!" opts.jobs
    timeout_text;
  let cases = collect_cases opts.case_selection in
  let formatter_warmup =
    if List.exists case_uses_formatter cases then prewarm_formatter_renderer opts
    else Ok ()
  in
  match formatter_warmup with
  | Error msg ->
      Printf.printf "FAIL: [format/warmup] renderer\nDETAIL %s\n" msg;
      Printf.printf
        "\n\
         BLORP_GATE_RESULT gate=%s status=FAIL passed=0 failed=1 tests=1\n"
        opts.gate_name;
      Printf.printf "1/1 compiler tests failed\n";
      1
  | Ok () ->
      let case_passed, case_failed, case_total =
        run_cases_parallel opts cases
      in
      let passed = ref case_passed in
      let failed = ref case_failed in
      let total = ref case_total in
      if opts.run_codegen_audit then run_codegen_audit opts passed failed total;
      let missing = missing_expectation_count () in
      if missing > 0 then
        Printf.printf
          "\n\
           WARN %d should_fail test(s) without -- EXPECT: annotations (format \
           tests excluded)\n"
          missing;
      Printf.printf "\n%!";
      if !failed = 0 then begin
        Printf.printf
          "BLORP_GATE_RESULT gate=%s status=PASS passed=%d failed=0 \
           tests=%d\n"
          opts.gate_name !passed !total;
        Printf.printf "All %d compiler tests passed\n" !total;
        0
      end
      else begin
        Printf.printf
          "BLORP_GATE_RESULT gate=%s status=FAIL passed=%d failed=%d \
           tests=%d\n"
          opts.gate_name !passed !failed !total;
        Printf.printf "%d/%d compiler tests passed (%d failed)\n" !passed !total
          !failed;
        1
      end

let timeout_from_env () =
  let parse name =
    match Sys.getenv_opt name with
    | Some value -> (
        match int_of_string_opt value with
        | Some timeout when timeout >= 0 -> Ok (Some timeout)
        | _ ->
            Error
              (Printf.sprintf "Error: %s must be a non-negative integer." name))
    | None -> Ok None
  in
  match parse "BLORP_COMPILER_TEST_TIMEOUT" with
  | Error _ as error -> error
  | Ok (Some timeout) -> Ok (Some timeout)
  | Ok None -> (
      match parse "BLORP_TEST_TIMEOUT" with
      | Error _ as error -> error
      | Ok (Some timeout) -> Ok (Some timeout)
      | Ok None -> Ok (Some 30))

let default_jobs () =
  let sysctl_code, sysctl_output =
    Test_runner.run_process_capture_timeout ~timeout:(Some 2) "sysctl"
      [ "-n"; "hw.ncpu" ]
  in
  if sysctl_code = 0 then
    match int_of_string_opt (String.trim sysctl_output) with
    | Some n when n > 0 -> n
    | _ -> 4
  else
    let nproc_code, nproc_output =
      Test_runner.run_process_capture_timeout ~timeout:(Some 2) "nproc" []
    in
    if nproc_code = 0 then
      match int_of_string_opt (String.trim nproc_output) with
      | Some n when n > 0 -> n
      | _ -> 4
    else 4

let usage () =
  print_endline
    "Usage: compiler_fixture_runner [--quiet|--verbose] [--timeout N] [-j N] \
     [--blorp-bin PATH] [--gate-name NAME] [--no-codegen-audit] \
     [--no-tool-fixtures|--only-tool-fixtures]"

let run_cli args =
  let rec loop opts = function
    | [] -> run opts
    | "--quiet" :: rest -> loop { opts with verbose = false } rest
    | "--verbose" :: rest -> loop { opts with verbose = true } rest
    | "--timeout" :: value :: rest -> (
        match int_of_string_opt value with
        | Some n when n >= 0 -> loop { opts with timeout = Some n } rest
        | _ ->
            prerr_endline "Error: --timeout requires a non-negative integer";
            1)
    | "-j" :: value :: rest -> (
        match int_of_string_opt value with
        | Some n when n > 0 -> loop { opts with jobs = n } rest
        | _ ->
            prerr_endline "Error: -j requires a positive integer";
            1)
    | "--blorp-bin" :: path :: rest -> loop { opts with blorp_bin = path } rest
    | "--gate-name" :: name :: rest -> loop { opts with gate_name = name } rest
    | "--no-codegen-audit" :: rest ->
        loop { opts with run_codegen_audit = false } rest
    | "--no-tool-fixtures" :: rest ->
        loop { opts with case_selection = SurfaceCases } rest
    | "--only-tool-fixtures" :: rest ->
        loop { opts with case_selection = ToolCasesOnly } rest
    | ("--help" | "-h") :: _ ->
        usage ();
        0
    | arg :: _ ->
        prerr_endline ("Error: unknown compiler fixture runner option: " ^ arg);
        usage ();
        1
  in
  match timeout_from_env () with
  | Error msg ->
      prerr_endline msg;
      1
  | Ok timeout ->
      let opts =
        {
          verbose = false;
          timeout;
          blorp_bin = Sys.executable_name;
          run_codegen_audit = true;
          case_selection = AllCases;
          gate_name = "compiler";
          jobs = default_jobs ();
        }
      in
      loop opts args
