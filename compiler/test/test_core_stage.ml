(** Unit tests for [Core_stage].

    The stage enum drives the `--dump-core-after=<stage>` and
    `--stop-after=<stage>` CLI flags. The parser has to accept the documented
    set of stages; unknown input has to fail loudly so users get a helpful
    diagnostic instead of silent no-op. *)

open Blorp

let check_ok stage s =
  let msg = Printf.sprintf "parse %S" s in
  Alcotest.(check (option string))
    msg (Some stage)
    (match Core_stage.of_string s with
    | Ok s -> Some (Core_stage.to_string s)
    | Error _ -> None)

let check_err s =
  let msg = Printf.sprintf "reject %S" s in
  match Core_stage.of_string s with
  | Ok _ -> Alcotest.failf "expected error for %S" s
  | Error err ->
      Alcotest.(check bool)
        (msg ^ " mentions valid stages")
        true
        (Blorp.Modules.contains err "lower"
        && Blorp.Modules.contains err "final")

let test_of_string_canonical () =
  check_ok "lower" "lower";
  check_ok "debug" "debug";
  check_ok "desugar" "desugar";
  check_ok "mono" "mono";
  check_ok "synth" "synth";
  check_ok "match" "match";
  check_ok "resolve" "resolve";
  check_ok "tailrec" "tailrec";
  check_ok "fusion" "fusion";
  check_ok "specialize" "specialize";
  check_ok "dce" "dce";
  check_ok "consume_specialize" "consume_specialize";
  check_ok "perceus" "perceus";
  check_ok "reuse" "reuse";
  check_ok "closure" "closure";
  check_ok "final" "final"

let test_of_string_case_insensitive () =
  check_ok "mono" "MONO";
  check_ok "specialize" "Specialize";
  check_ok "final" "FiNaL"

let test_of_string_rejects_unknown () =
  check_err "";
  check_err "emit";
  check_err "parsed";
  check_err "lowered"

let test_of_string_list_single () =
  (* Single stage parses to a one-element list. *)
  match Core_stage.of_string_list "mono" with
  | Ok [ s ] -> Alcotest.(check string) "stage" "mono" (Core_stage.to_string s)
  | Ok _ -> Alcotest.fail "expected one stage"
  | Error err -> Alcotest.failf "unexpected error: %s" err

let test_of_string_list_comma () =
  (* Comma-separated list parses to stages in order. *)
  match Core_stage.of_string_list "desugar,mono,match" with
  | Ok stages ->
      Alcotest.(check (list string))
        "stages"
        [ "desugar"; "mono"; "match" ]
        (List.map Core_stage.to_string stages)
  | Error err -> Alcotest.failf "unexpected error: %s" err

let test_of_string_list_whitespace_tolerant () =
  (* Whitespace around commas is OK (CLI convenience). *)
  match Core_stage.of_string_list " lower , mono " with
  | Ok stages ->
      Alcotest.(check (list string))
        "stages" [ "lower"; "mono" ]
        (List.map Core_stage.to_string stages)
  | Error err -> Alcotest.failf "unexpected error: %s" err

let test_of_string_list_reports_bad_element () =
  (* One bad element surfaces the error referring to that element. *)
  match Core_stage.of_string_list "mono,bogus,match" with
  | Ok _ -> Alcotest.fail "expected error"
  | Error err ->
      Alcotest.(check bool)
        "mentions bogus" true
        (Blorp.Modules.contains err "bogus")

let test_of_string_list_empty_element () =
  (* Trailing or embedded empty entries (`mono,,match`) currently surface
     an error referring to the empty string, not silently skipped. This
     pins the behavior so a future change doesn't drift accidentally. *)
  match Core_stage.of_string_list "mono,,match" with
  | Ok _ -> Alcotest.fail "expected error for empty element"
  | Error _ -> ()

let test_all_covers_every_stage () =
  let all = Core_stage.all in
  Alcotest.(check int) "stage count" 18 (List.length all);
  (* Round-trip every stage through to_string / of_string *)
  List.iter
    (fun s ->
      let name = Core_stage.to_string s in
      match Core_stage.of_string name with
      | Ok s' ->
          Alcotest.(check string)
            (Printf.sprintf "roundtrip %s" name)
            (Core_stage.to_string s) (Core_stage.to_string s')
      | Error err ->
          Alcotest.failf "round-trip parse failed for %s: %s" name err)
    all

let test_order_matches_pipeline () =
  (* The enum order is load-bearing: it defines the pipeline and the order
     users see in error messages. Guard it with a byte-exact comparison. *)
  let expected =
    [
      "lower";
      "debug";
      "desugar";
      "mono";
      "synth";
      "match";
      "trait_resolve";
      "resolve";
      "std_inline";
      "tailrec";
      "fusion";
      "specialize";
      "dce";
      "consume_specialize";
      "perceus";
      "reuse";
      "closure";
      "final";
    ]
  in
  let actual = List.map Core_stage.to_string Core_stage.all in
  Alcotest.(check (list string)) "stage order" expected actual

let suite =
  [
    ( "of_string",
      [
        Alcotest.test_case "canonical forms" `Quick test_of_string_canonical;
        Alcotest.test_case "case insensitive" `Quick
          test_of_string_case_insensitive;
        Alcotest.test_case "rejects unknown" `Quick
          test_of_string_rejects_unknown;
      ] );
    ( "of_string_list",
      [
        Alcotest.test_case "single" `Quick test_of_string_list_single;
        Alcotest.test_case "comma" `Quick test_of_string_list_comma;
        Alcotest.test_case "whitespace" `Quick
          test_of_string_list_whitespace_tolerant;
        Alcotest.test_case "bad element" `Quick
          test_of_string_list_reports_bad_element;
        Alcotest.test_case "empty element" `Quick
          test_of_string_list_empty_element;
      ] );
    ( "coverage",
      [
        Alcotest.test_case "all covers every stage" `Quick
          test_all_covers_every_stage;
        Alcotest.test_case "order matches pipeline" `Quick
          test_order_matches_pipeline;
      ] );
  ]
