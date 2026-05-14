(** Unit tests for [Core_error] phase_tag unification (Phase 0.5.1).

    Previously [Core_error.t.phase] was a free-form [string] with no
    connection to [Core_stage]. The unification introduces a typed
    [phase_tag] variant that covers every stage plus the pre-pipeline
    (Frontend) and post-pipeline (Emit) positions.

    These tests pin the new API contract before any call site migrates. *)

open Blorp

let test_phase_tag_to_string () =
  (* Every phase_tag variant renders to a stable string. *)
  Alcotest.(check string)
    "stage lower" "lower"
    (Core_error.phase_tag_to_string (Core_error.Stage Core_stage.Lower));
  Alcotest.(check string)
    "stage mono" "mono"
    (Core_error.phase_tag_to_string (Core_error.Stage Core_stage.Mono));
  Alcotest.(check string)
    "stage closure" "closure"
    (Core_error.phase_tag_to_string (Core_error.Stage Core_stage.Closure));
  Alcotest.(check string)
    "frontend" "frontend"
    (Core_error.phase_tag_to_string Core_error.Frontend);
  Alcotest.(check string)
    "emit" "emit"
    (Core_error.phase_tag_to_string Core_error.Emit);
  Alcotest.(check string)
    "other" "perceus_check"
    (Core_error.phase_tag_to_string (Core_error.Other "perceus_check"))

let loc =
  { Ast.line = 7; column = 3; end_line = 7; end_column = 10; loc_file = None }

let test_errorf_stage_phase () =
  (* errorf with a Stage tag preserves the tag verbatim in the raised
     [Core_error] record. *)
  match
    try Core_error.errorf (Core_error.Stage Core_stage.Lower) loc "test %d" 42
    with Core_error.Core_error err -> err
  with
  | err ->
      (match err.phase with
      | Core_error.Stage s ->
          Alcotest.(check string)
            "stage preserved" "lower" (Core_stage.to_string s)
      | _ -> Alcotest.fail "expected Stage tag");
      Alcotest.(check string) "msg formatted" "test 42" err.msg

let test_errorf_frontend_phase () =
  match
    try Core_error.errorf Core_error.Frontend loc "frontend error"
    with Core_error.Core_error err -> err
  with
  | err ->
      Alcotest.(check bool)
        "frontend preserved" true
        (err.phase = Core_error.Frontend)

let test_to_string_renders_tag () =
  let err =
    {
      Core_error.phase = Core_error.Stage Core_stage.Mono;
      msg = "something broke";
      loc;
      hint = None;
    }
  in
  let rendered = Core_error.to_string err in
  Alcotest.(check bool)
    "renders phase name" true
    (Modules.contains rendered "mono");
  Alcotest.(check bool)
    "renders msg" true
    (Modules.contains rendered "something broke")

let test_check_raises_accepts_stage () =
  (* [check_raises] now takes a phase_tag, not a string. *)
  Core_error.check_raises ~phase:(Core_error.Stage Core_stage.Lower)
    ~msg_contains:"bad stuff" (fun () ->
      Core_error.errorf (Core_error.Stage Core_stage.Lower) loc "bad stuff here")

let suite =
  [
    ( "phase_tag",
      [
        Alcotest.test_case "to_string" `Quick test_phase_tag_to_string;
        Alcotest.test_case "errorf stage" `Quick test_errorf_stage_phase;
        Alcotest.test_case "errorf frontend" `Quick test_errorf_frontend_phase;
        Alcotest.test_case "to_string renders tag" `Quick
          test_to_string_renders_tag;
        Alcotest.test_case "check_raises stage" `Quick
          test_check_raises_accepts_stage;
      ] );
  ]
