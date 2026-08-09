module Runner = Blorp_compiler_fixture_runner.Compiler_test_runner

let test_codegen_audit_nonzero_after_passes_counts_runner_failure () =
  let summary =
    Runner.summarize_codegen_audit_output ~exit_code:1
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
    Runner.summarize_codegen_audit_output ~exit_code:0
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
    Runner.summarize_codegen_audit_output ~exit_code:118
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

let test_only_exit_one_is_an_expected_rejection () =
  let result code = { Runner.code = code; output = "" } in
  Alcotest.(check bool) "language rejection" true
    (Runner.is_expected_rejection (result 1));
  List.iter
    (fun code ->
      Alcotest.(check bool)
        (Printf.sprintf "status %d is infrastructure" code)
        false
        (Runner.is_expected_rejection (result code)))
    [ 2; 124; 125; 127; 137 ]

let expectations_for source =
  Runner.parse_expectation_groups source
  |> Runner.expectations_for_blorp_frontend

let check_expectations label expected actual =
  Alcotest.(check (list string)) (label ^ " exact") expected.Runner.exact
    actual.Runner.exact;
  Alcotest.(check (list string)) (label ^ " contains") expected.contains
    actual.contains;
  Alcotest.(check (list string)) (label ^ " not_contains")
    expected.not_contains actual.not_contains

let expectation ~exact ~contains ~not_contains =
  { Runner.exact; contains; not_contains }

let test_expectations_use_generic_when_frontend_has_no_override () =
  let source =
    "-- EXPECT: error: generic\n\
     -- EXPECT-CONTAINS: shared substring\n\
     -- EXPECT-NOT-CONTAINS: forbidden substring\n"
  in
  let expected =
    expectation ~exact:[ "error: generic" ]
      ~contains:[ "shared substring" ]
      ~not_contains:[ "forbidden substring" ]
  in
  check_expectations "blorp fallback" expected
    (expectations_for source)

let test_expectations_use_blorp_override_when_present () =
  let source =
    "-- EXPECT: error: generic\n\
     -- EXPECT-BLORP: error: blorp-specific\n\
     -- EXPECT-BLORP-CONTAINS: blorp substring\n\
     -- EXPECT-BLORP-NOT-CONTAINS: blorp forbidden\n"
  in
  let expected =
    expectation ~exact:[ "error: blorp-specific" ]
      ~contains:[ "blorp substring" ]
      ~not_contains:[ "blorp forbidden" ]
  in
  check_expectations "blorp override" expected
    (expectations_for source)

let suite =
  [
    ( "expectations",
      [
        Alcotest.test_case "generic fallback" `Quick
          test_expectations_use_generic_when_frontend_has_no_override;
        Alcotest.test_case "blorp override" `Quick
          test_expectations_use_blorp_override_when_present;
      ] );
    ( "codegen_audit",
      [
        Alcotest.test_case "nonzero after passes" `Quick
          test_codegen_audit_nonzero_after_passes_counts_runner_failure;
        Alcotest.test_case "zero after passes" `Quick
          test_codegen_audit_zero_exit_after_passes_has_no_runner_failure;
        Alcotest.test_case "nonzero before cases" `Quick
          test_codegen_audit_nonzero_before_cases_counts_runner_failure;
      ] );
    ( "process_status",
      [
        Alcotest.test_case "only exit one is a rejection" `Quick
          test_only_exit_one_is_an_expected_rejection;
      ] );
  ]
