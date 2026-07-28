(** Integration tests for --dump-core / --stop-after infrastructure.

    These tests drive [Core_pipeline.compile_typed] with stage hooks, confirming:
      - [dump_after] captures the expected stage's program
      - [stop_after] short-circuits via [Core_pipeline.Stopped_after]
      - default invocation (no hooks) still returns the full C string

    The tests avoid module loading: a single typed program is enough to prove
    the compatibility pipeline's hook plumbing. *)

open Blorp

let small_source =
  {|
func inc(x: Int) -> Int:
    x + 1

func main(args: List[String]) -> Int:
    inc(41)
|}

let expected_program_stage_order =
  [
    Core_stage.Lower;
    Core_stage.Debug;
    Core_stage.Desugar;
    Core_stage.Mono;
    Core_stage.Synth;
    Core_stage.Match;
    Core_stage.TraitResolve;
    Core_stage.Resolve;
    Core_stage.StdInline;
    Core_stage.Tailrec;
    Core_stage.Fusion;
    Core_stage.Specialize;
  ]

let expected_program_free_stage_event_order =
  expected_program_stage_order @ [ Core_stage.Dce; Core_stage.Final ]

let lower_source src =
  let program = Test_helpers.parse_program src in
  match Blorp.Typecheck.typecheck_typed program with
  | Ok typed_program -> typed_program
  | Error errors ->
      Alcotest.failf "expected no type errors, got: %s"
        (String.concat "; "
           (List.map (fun (e : Blorp.Ast.compiler_error) -> e.message) errors))

let test_compile_default_unchanged () =
  (* Sanity: compile with no hooks returns a non-empty C string. Proves the
     hook threading doesn't change default behavior. *)
  let prog = lower_source small_source in
  let c_code = Core_pipeline.compile_typed prog in
  Alcotest.(check bool) "non-empty C output" true (String.length c_code > 0);
  Alcotest.(check bool)
    "C output mentions inc" true
    (Modules.contains c_code "inc")

let test_dump_after_captures_stage_output () =
  let prog = lower_source small_source in
  let captures = ref [] in
  let on_stage stage program =
    let text = Core.pp_program_indented program in
    captures := (Core_stage.to_string stage, text) :: !captures
  in
  let _c_code = Core_pipeline.compile_typed ~on_stage prog in
  let captured = List.rev !captures in
  (* Every OCaml-owned program stage should fire exactly once. *)
  let names = List.map fst captured in
  Alcotest.(check int)
    "every OCaml-owned program stage fired"
    (List.length expected_program_stage_order)
    (List.length names);
  Alcotest.(check (list string))
    "stages in order"
    (List.map Core_stage.to_string expected_program_stage_order)
    names;
  (* Each capture should mention `inc` (a user-defined function) *)
  List.iter
    (fun (stage, text) ->
      Alcotest.(check bool)
        (Printf.sprintf "%s output mentions inc" stage)
        true
        (Modules.contains text "inc"))
    captured

let test_stage_events_capture_stage_order_without_programs () =
  let prog = lower_source small_source in
  let stages = ref [] in
  let _c_code =
    Core_pipeline.compile_typed
      ~on_stage_event:(fun stage -> stages := stage :: !stages)
      prog
  in
  Alcotest.(check (list string))
    "stages in order"
    (List.map Core_stage.to_string expected_program_free_stage_event_order)
    (List.rev !stages |> List.map Core_stage.to_string)

let test_blorp_tail_json_observation_captures_late_stages () =
  let prog = lower_source small_source in
  let captures = ref [] in
  let _c_code =
    Core_pipeline.compile_typed
      ~tail_observation_stages:[ Core_stage.Reuse; Core_stage.Final ]
      ~on_stage_json:(fun stage json -> captures := (stage, json) :: !captures)
      prog
  in
  let captured = List.rev !captures in
  Alcotest.(check (list string))
    "tail JSON stages in order"
    [ "reuse"; "final" ]
    (List.map (fun (stage, _) -> Core_stage.to_string stage) captured);
  List.iter
    (fun (stage, json) ->
      Alcotest.(check bool)
        (Printf.sprintf "%s JSON is Core program" (Core_stage.to_string stage))
        true
        (Modules.contains json "\"kind\":\"program\""))
    captured

let test_blorp_tail_json_observation_records_stage_events () =
  let prog = lower_source small_source in
  let stages = ref [] in
  let requested_tail_stages =
    [ Core_stage.Reuse; Core_stage.Closure; Core_stage.Final ]
  in
  let _c_code =
    Core_pipeline.compile_typed
      ~tail_observation_stages:requested_tail_stages
      ~on_stage_event:(fun stage -> stages := stage :: !stages)
      ~on_stage_json:(fun _stage _json -> ())
      prog
  in
  Alcotest.(check (list string))
    "tail JSON stage events in order"
    (List.map Core_stage.to_string
       (expected_program_stage_order @ (Core_stage.Dce :: requested_tail_stages)))
    (List.rev !stages |> List.map Core_stage.to_string)

let test_stop_after_short_circuits () =
  let prog = lower_source small_source in
  let stages_seen = ref [] in
  let on_stage stage program =
    stages_seen := stage :: !stages_seen;
    if stage = Core_stage.Mono then (
      (* Do some work with program to confirm we have access to it *)
      let text = Core.pp_program_indented program in
      Alcotest.(check bool)
        "program non-empty at stop" true
        (String.length text > 0);
      raise (Core_pipeline.Stopped_after Core_stage.Mono))
  in
  match Core_pipeline.compile_typed ~on_stage prog with
  | exception Core_pipeline.Stopped_after s ->
      Alcotest.(check string) "stopped at mono" "mono" (Core_stage.to_string s);
      let seen = List.rev !stages_seen in
      (* Should have seen stages through mono — but no later stages. *)
      let expected =
        [
          Core_stage.Lower;
          Core_stage.Debug;
          Core_stage.Desugar;
          Core_stage.Mono;
        ]
      in
      Alcotest.(check (list string))
        "only pre-stop stages fired"
        (List.map Core_stage.to_string expected)
        (List.map Core_stage.to_string seen)
  | _ -> Alcotest.fail "expected Stopped_after exception"

let suite =
  [
    ( "compile",
      [
        Alcotest.test_case "default unchanged" `Quick
          test_compile_default_unchanged;
        Alcotest.test_case "dump_after captures" `Quick
          test_dump_after_captures_stage_output;
        Alcotest.test_case "stage events capture order" `Quick
          test_stage_events_capture_stage_order_without_programs;
        Alcotest.test_case "Blorp tail JSON observation captures late stages"
          `Quick test_blorp_tail_json_observation_captures_late_stages;
        Alcotest.test_case "Blorp tail JSON observation records stage events"
          `Quick test_blorp_tail_json_observation_records_stage_events;
        Alcotest.test_case "stop_after short circuits" `Quick
          test_stop_after_short_circuits;
      ] );
  ]
