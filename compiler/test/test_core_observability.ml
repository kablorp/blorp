(** Integration tests for --dump-core / --stop-after infrastructure.

    These tests drive [Core_pipeline.compile_typed] with stage hooks, confirming:
      - [dump_after] captures the expected stage's program
      - [stop_after] short-circuits via [Core_pipeline.Stopped_after]
      - default invocation (no hooks) still returns the full C string

    The tests avoid module loading — a single-file program exercised through
    [Core_pipeline.compile_typed] is enough to prove hook plumbing works.
    [Pipeline.compile]-level tests that exercise module loading belong in
    [test_pipeline.ml] when it exists. *)

open Blorp

let small_source =
  {|
func inc(x: Int) -> Int:
    x + 1

func main(args: List[String]) -> Int:
    inc(41)
|}

let list_filter_map_collect_source =
  {|
import:
    list: filter, length, map

func main(args: List[String]) -> Int:
    xs: List[Int] = [1, 2, 3, 4, 5, 6]
    ys: List[Int] = xs.filter(func(x: Int): x % 2 == 0).map(func(x: Int): x * 10)
    ys.length()
|}

let list_float_filter_map_collect_source =
  {|
import:
    list: filter, length, map

func main(args: List[String]) -> Int:
    xs: List[Float] = [1.0, 2.0, 3.0, 4.0]
    ys: List[Float] = xs.filter(func(x: Float): x > 1.5).map(func(x: Float): x * 0.5)
    ys.length()
|}

let list_string_filter_map_collect_source =
  {|
import:
    list: filter, length, map

func main(args: List[String]) -> Int:
    xs: List[String] = ["ant", "bear", "cat", "dolphin"]
    ys: List[String] = xs.filter(func(s: String): s.length() > 3).map(func(s: String): s + "!")
    ys.length()
|}

let debug_block_source =
  {|
import:
    debug as dbg

func main(args: List[String]) -> Int:
    debug:
        dbg.log("hidden debug marker")
    0
|}

let lower_source src =
  Blorp.Lexer.reset_state ();
  let lexbuf = Lexing.from_string src in
  let program = Blorp.Parser.program Blorp.Lexer.next_token lexbuf in
  let program = Blorp.Interp_parser.transform_program program in
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
  (* Every pipeline stage should fire exactly once. *)
  let names = List.map fst captured in
  Alcotest.(check int)
    "every stage fired"
    (List.length Core_stage.all)
    (List.length names);
  Alcotest.(check (list string))
    "stages in order"
    (List.map Core_stage.to_string Core_stage.all)
    names;
  (* Each capture should mention `inc` (a user-defined function) *)
  List.iter
    (fun (stage, text) ->
      Alcotest.(check bool)
        (Printf.sprintf "%s output mentions inc" stage)
        true
        (Modules.contains text "inc"))
    captured

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

let test_compile_with_modules_uses_same_stage_order () =
  let prog = lower_source small_source in
  let core_stages = ref [] in
  let _c_code =
    Core_pipeline.compile_typed
      ~on_stage:(fun stage _ -> core_stages := stage :: !core_stages)
      prog
  in
  Blorp.Modules.reset ();
  Blorp.Modules.init_module_paths ".";
  let module_stages = ref [] in
  match
    Pipeline.compile ~embed_runtime:false
      ~on_stage:(fun stage _ -> module_stages := stage :: !module_stages)
      ~filename:"<test>" ~source:small_source ()
  with
  | Ok (Pipeline.Compiled _) ->
      let core_names = List.rev !core_stages |> List.map Core_stage.to_string in
      let module_names =
        List.rev !module_stages |> List.map Core_stage.to_string
      in
      Alcotest.(check (list string)) "same stage order" core_names module_names
  | Ok (Pipeline.Stopped_at s) ->
      Alcotest.failf "unexpected stop at %s" (Core_stage.to_string s)
  | Error errs ->
      Alcotest.failf "compile_with_modules failed: %d errors" (List.length errs)

let test_pipeline_stopped_returns_tagged_outcome () =
  (* Phase 0.5.2: Pipeline.compile returns Ok (Stopped_at s) instead of
     re-raising Stopped_after. The exception stays inside Core_pipeline
     as an internal short-circuit but is converted at the Pipeline
     boundary so callers pattern-match a normal sum type. *)
  let source = small_source in
  (* Prime module loading so Pipeline.compile doesn't fail to find std. *)
  Blorp.Modules.reset ();
  Blorp.Modules.init_module_paths ".";
  let on_stage stage _prog =
    if stage = Core_stage.Mono then
      raise (Core_pipeline.Stopped_after Core_stage.Mono)
  in
  match Pipeline.compile ~on_stage ~filename:"<test>" ~source () with
  | Ok (Pipeline.Stopped_at s) ->
      Alcotest.(check string) "stopped at mono" "mono" (Core_stage.to_string s)
  | Ok (Pipeline.Compiled _) ->
      Alcotest.fail "expected Stopped_at, got Compiled"
  | Error errs ->
      Alcotest.failf "expected Stopped_at, got %d errors" (List.length errs)

let test_pipeline_no_stop_returns_compiled () =
  (* Regression: without on_stage, the outcome is Compiled. *)
  let source = small_source in
  Blorp.Modules.reset ();
  Blorp.Modules.init_module_paths ".";
  match Pipeline.compile ~filename:"<test>" ~source () with
  | Ok (Pipeline.Compiled r) ->
      Alcotest.(check bool) "c_code non-empty" true (String.length r.c_code > 0)
  | Ok (Pipeline.Stopped_at _) ->
      Alcotest.fail "expected Compiled, got Stopped_at"
  | Error errs -> Alcotest.failf "compile failed: %d errors" (List.length errs)

let test_pipeline_frontend_phases_fire_before_core () =
  let source = small_source in
  Blorp.Modules.reset ();
  Blorp.Modules.init_module_paths ".";
  let frontend_phases = ref [] in
  let core_stages = ref [] in
  let on_frontend_phase phase =
    frontend_phases :=
      Pipeline.frontend_phase_to_string phase :: !frontend_phases
  in
  let on_stage stage _program =
    core_stages := Core_stage.to_string stage :: !core_stages
  in
  match
    Pipeline.compile ~embed_runtime:false ~on_frontend_phase ~on_stage
      ~filename:"<test>" ~source ()
  with
  | Ok (Pipeline.Compiled _) ->
      Alcotest.(check (list string))
        "frontend phase order"
        [ "parse"; "module_load"; "module_typecheck"; "main_typecheck" ]
        (List.rev !frontend_phases);
      Alcotest.(check bool)
        "core stages still fire" true
        (List.rev !core_stages <> [])
  | Ok (Pipeline.Stopped_at s) ->
      Alcotest.failf "unexpected stop at %s" (Core_stage.to_string s)
  | Error errs -> Alcotest.failf "compile failed: %d errors" (List.length errs)

let test_normal_build_removes_debug_block () =
  Blorp.Modules.reset ();
  Blorp.Modules.init_module_paths ".";
  match
    Pipeline.compile ~embed_runtime:false ~filename:"<test>"
      ~source:debug_block_source ()
  with
  | Ok (Pipeline.Compiled r) ->
      Alcotest.(check bool)
        "debug marker not emitted in normal build" false
        (Modules.contains r.c_code "hidden debug marker")
  | Ok (Pipeline.Stopped_at s) ->
      Alcotest.failf "unexpected stop at %s" (Core_stage.to_string s)
  | Error errs -> Alcotest.failf "compile failed: %d errors" (List.length errs)

let test_debug_build_keeps_debug_block () =
  Blorp.Modules.reset ();
  Blorp.Modules.init_module_paths ".";
  match
    Pipeline.compile ~debug:true ~embed_runtime:false ~filename:"<test>"
      ~source:debug_block_source ()
  with
  | Ok (Pipeline.Compiled r) ->
      Alcotest.(check bool)
        "debug marker emitted in debug build" true
        (Modules.contains r.c_code "hidden debug marker")
  | Ok (Pipeline.Stopped_at s) ->
      Alcotest.failf "unexpected stop at %s" (Core_stage.to_string s)
  | Error errs -> Alcotest.failf "compile failed: %d errors" (List.length errs)

let test_retain_debug_blocks_keeps_debug_block () =
  Blorp.Modules.reset ();
  Blorp.Modules.init_module_paths ".";
  match
    Pipeline.compile ~retain_debug_blocks:true ~embed_runtime:false
      ~filename:"<test>" ~source:debug_block_source ()
  with
  | Ok (Pipeline.Compiled r) ->
      Alcotest.(check bool)
        "debug marker emitted when debug blocks are retained" true
        (Modules.contains r.c_code "hidden debug marker")
  | Ok (Pipeline.Stopped_at s) ->
      Alcotest.failf "unexpected stop at %s" (Core_stage.to_string s)
  | Error errs -> Alcotest.failf "compile failed: %d errors" (List.length errs)

let test_pipeline_filter_map_collect_handoff_reuse () =
  (* Source-level regression for producer handoff: fusion first emits a
     borrow-fresh list handoff, then Perceus + reuse should turn the
     source-owner drop into a consuming handoff. *)
  Blorp.Modules.reset ();
  Blorp.Modules.init_module_paths ".";
  let fusion_text = ref None in
  let reuse_text = ref None in
  let on_stage stage program =
    let text = Core.pp_program_indented program in
    if stage = Core_stage.Fusion then fusion_text := Some text
    else if stage = Core_stage.Reuse then reuse_text := Some text
  in
  match
    Pipeline.compile ~embed_runtime:false ~on_stage ~filename:"<test>"
      ~source:list_filter_map_collect_source ()
  with
  | Ok (Pipeline.Compiled r) ->
      let fusion = Option.value ~default:"" !fusion_text in
      let reuse = Option.value ~default:"" !reuse_text in
      Alcotest.(check bool)
        "fusion emits borrow-fresh handoff" true
        (Modules.contains fusion "list-handoff[borrow-fresh");
      Alcotest.(check bool)
        "reuse upgrades to consume-reuse handoff" true
        (Modules.contains reuse "list-handoff[consume-reuse");
      Alcotest.(check bool)
        "emitted C delegates runtime reuse decision" true
        (Modules.contains r.c_code "blorp_list_handoff_begin_reuse");
      Alcotest.(check bool)
        "emitted C does not inline handoff reuse guard" false
        (Modules.contains r.c_code "== NULL && blorp_is_unique")
  | Ok (Pipeline.Stopped_at s) ->
      Alcotest.failf "unexpected stop at %s" (Core_stage.to_string s)
  | Error errs -> Alcotest.failf "compile failed: %d errors" (List.length errs)

let test_pipeline_float_filter_map_collect_handoff_reuse () =
  (* Generated-C shape coverage for the first non-Int scalar fusion slice.
     Float elements are unboxed from list slots and bit-boxed back into the
     handoff result without managed element release callbacks. *)
  Blorp.Modules.reset ();
  Blorp.Modules.init_module_paths ".";
  let fusion_text = ref None in
  let reuse_text = ref None in
  let on_stage stage program =
    let text = Core.pp_program_indented program in
    if stage = Core_stage.Fusion then fusion_text := Some text
    else if stage = Core_stage.Reuse then reuse_text := Some text
  in
  match
    Pipeline.compile ~embed_runtime:false ~on_stage ~filename:"<test>"
      ~source:list_float_filter_map_collect_source ()
  with
  | Ok (Pipeline.Compiled r) ->
      let fusion = Option.value ~default:"" !fusion_text in
      let reuse = Option.value ~default:"" !reuse_text in
      Alcotest.(check bool)
        "fusion emits borrow-fresh handoff" true
        (Modules.contains fusion "list-handoff[borrow-fresh");
      Alcotest.(check bool)
        "reuse upgrades to consume-reuse handoff" true
        (Modules.contains reuse "list-handoff[consume-reuse");
      Alcotest.(check bool)
        "emitted C unboxes float list elements" true
        (Modules.contains r.c_code "blorp_unbox_float");
      Alcotest.(check bool)
        "emitted C delegates runtime reuse decision" true
        (Modules.contains r.c_code "blorp_list_handoff_begin_reuse");
      Alcotest.(check bool)
        "emitted C uses typed inline scalar handoff store" true
        (Modules.contains r.c_code "double __list_store_value_inline_set"
        && Modules.contains r.c_code
             "memcpy((char*)__list_store_inline_set->data");
      Alcotest.(check bool)
        "emitted C does not use pointer handoff store for floats" false
        (Modules.contains r.c_code "blorp_list_handoff_set_owned")
  | Ok (Pipeline.Stopped_at s) ->
      Alcotest.failf "unexpected stop at %s" (Core_stage.to_string s)
  | Error errs -> Alcotest.failf "compile failed: %d errors" (List.length errs)

let test_pipeline_string_filter_map_collect_handoff_reuse () =
  (* Generated-C shape coverage for the first managed fusion slice.
     Source elements stay borrowed aliases; mapped String results are owned
     values transferred into the overwrite-aware handoff store. *)
  Blorp.Modules.reset ();
  Blorp.Modules.init_module_paths ".";
  let fusion_text = ref None in
  let reuse_text = ref None in
  let on_stage stage program =
    let text = Core.pp_program_indented program in
    if stage = Core_stage.Fusion then fusion_text := Some text
    else if stage = Core_stage.Reuse then reuse_text := Some text
  in
  match
    Pipeline.compile ~embed_runtime:false ~on_stage ~filename:"<test>"
      ~source:list_string_filter_map_collect_source ()
  with
  | Ok (Pipeline.Compiled r) ->
      let fusion = Option.value ~default:"" !fusion_text in
      let reuse = Option.value ~default:"" !reuse_text in
      Alcotest.(check bool)
        "fusion emits borrow-fresh handoff" true
        (Modules.contains fusion "list-handoff[borrow-fresh");
      Alcotest.(check bool)
        "reuse upgrades to consume-reuse handoff" true
        (Modules.contains reuse "list-handoff[consume-reuse");
      Alcotest.(check bool)
        "source string element is not bound as owned local" false
        (Modules.contains fusion "let __pipe_elem_");
      Alcotest.(check bool)
        "emitted C uses handoff transfer store" true
        (Modules.contains r.c_code "blorp_list_handoff_set_owned");
      Alcotest.(check bool)
        "emitted C installs managed element release" true
        (Modules.contains r.c_code "blorp_elem_release_fn")
  | Ok (Pipeline.Stopped_at s) ->
      Alcotest.failf "unexpected stop at %s" (Core_stage.to_string s)
  | Error errs -> Alcotest.failf "compile failed: %d errors" (List.length errs)

let suite =
  [
    ( "compile",
      [
        Alcotest.test_case "default unchanged" `Quick
          test_compile_default_unchanged;
        Alcotest.test_case "dump_after captures" `Quick
          test_dump_after_captures_stage_output;
        Alcotest.test_case "stop_after short circuits" `Quick
          test_stop_after_short_circuits;
        Alcotest.test_case "compile_with_modules uses same stage order" `Quick
          test_compile_with_modules_uses_same_stage_order;
      ] );
    ( "outcome",
      [
        Alcotest.test_case "stopped returns tagged" `Quick
          test_pipeline_stopped_returns_tagged_outcome;
        Alcotest.test_case "no stop returns compiled" `Quick
          test_pipeline_no_stop_returns_compiled;
        Alcotest.test_case "frontend phases fire before core" `Quick
          test_pipeline_frontend_phases_fire_before_core;
        Alcotest.test_case "normal build removes debug block" `Quick
          test_normal_build_removes_debug_block;
        Alcotest.test_case "debug build keeps debug block" `Quick
          test_debug_build_keeps_debug_block;
        Alcotest.test_case "retain_debug_blocks keeps debug block" `Quick
          test_retain_debug_blocks_keeps_debug_block;
      ] );
    ( "handoff",
      [
        Alcotest.test_case "filter_map_collect upgrades to consuming handoff"
          `Quick test_pipeline_filter_map_collect_handoff_reuse;
        Alcotest.test_case
          "float_filter_map_collect upgrades to consuming handoff" `Quick
          test_pipeline_float_filter_map_collect_handoff_reuse;
        Alcotest.test_case
          "string_filter_map_collect upgrades to consuming handoff" `Quick
          test_pipeline_string_filter_map_collect_handoff_reuse;
      ] );
  ]
