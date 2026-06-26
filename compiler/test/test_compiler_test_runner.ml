let test_codegen_audit_nonzero_after_passes_counts_runner_failure () =
  let summary =
    Blorp.Compiler_test_runner.summarize_codegen_audit_output ~exit_code:1
      "PASS: generated_ok.brp\nResults: 1 passed, 0 failed\n"
  in
  Alcotest.(check int) "case pass count" 1 summary.codegen_passed;
  Alcotest.(check int) "runner failure count" 1 summary.codegen_failed;
  Alcotest.(check int) "case plus runner total" 2 summary.codegen_total;
  match summary.codegen_runner_failure with
  | Some [ message ] ->
      Alcotest.(check string)
        "failure explains status mismatch"
        "runner exited with status 1 after reporting 1 test result(s)"
        message
  | Some details ->
      Alcotest.failf "unexpected runner failure details: %s"
        (String.concat "; " details)
  | None -> Alcotest.fail "expected runner failure details"

let test_codegen_audit_zero_exit_after_passes_has_no_runner_failure () =
  let summary =
    Blorp.Compiler_test_runner.summarize_codegen_audit_output ~exit_code:0
      "PASS: generated_ok.brp\nResults: 1 passed, 0 failed\n"
  in
  Alcotest.(check int) "case pass count" 1 summary.codegen_passed;
  Alcotest.(check int) "no failure count" 0 summary.codegen_failed;
  Alcotest.(check int) "case total" 1 summary.codegen_total;
  Alcotest.(check bool)
    "no runner failure" true
    (Option.is_none summary.codegen_runner_failure)

let test_codegen_audit_nonzero_before_cases_counts_runner_failure () =
  let summary =
    Blorp.Compiler_test_runner.summarize_codegen_audit_output ~exit_code:118
      "internal compiler error\n"
  in
  Alcotest.(check int) "no case pass count" 0 summary.codegen_passed;
  Alcotest.(check int) "runner failure count" 1 summary.codegen_failed;
  Alcotest.(check int) "runner failure total" 1 summary.codegen_total;
  match summary.codegen_runner_failure with
  | Some ("runner failed before reporting test results" :: _) -> ()
  | Some details ->
      Alcotest.failf "unexpected runner failure details: %s"
        (String.concat "; " details)
  | None -> Alcotest.fail "expected runner failure details"

let suite =
  [
    ( "codegen_audit",
      [
        Alcotest.test_case "nonzero after passes" `Quick
          test_codegen_audit_nonzero_after_passes_counts_runner_failure;
        Alcotest.test_case "zero after passes" `Quick
          test_codegen_audit_zero_exit_after_passes_has_no_runner_failure;
        Alcotest.test_case "nonzero before cases" `Quick
          test_codegen_audit_nonzero_before_cases_counts_runner_failure;
      ] );
  ]
