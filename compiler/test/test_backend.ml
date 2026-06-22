(** Unit tests for [Backend.S] and default C emission selection.

    The default C path can route through Blorp-owned emission for supported
    final-Core subsets, while explicit backend injection still bypasses that
    selection. These tests keep those ownership boundaries visible. *)

let typed_program_from_source source =
  Blorp.Lexer.reset_state ();
  let lexbuf = Lexing.from_string source in
  let program = Blorp.Parser.program Blorp.Lexer.next_token lexbuf in
  let program = Blorp.Interp_parser.transform_program program in
  match Blorp.Typecheck.typecheck_typed program with
  | Ok typed -> typed
  | Error errors ->
      Alcotest.failf "expected no type errors, got: %s"
        (String.concat "; "
           (List.map (fun (e : Blorp.Ast.compiler_error) -> e.message) errors))

let final_core_from_typed ?(embed_runtime = false) typed =
  let final_core = ref None in
  let on_stage stage prog =
    if stage = Blorp.Core_stage.Final then final_core := Some prog
  in
  let _ = Blorp.Core_pipeline.compile_typed ~embed_runtime ~on_stage typed in
  match !final_core with
  | Some prog -> prog
  | None -> Alcotest.fail "expected final Core snapshot"

let assert_blorp_accepts_final_core ?(embed_runtime = false) final_core =
  let cfg =
    Blorp.Core_emit_blorp_c.Backend.config_with_embed ~embed_runtime ()
  in
  match Blorp.Core_emit_blorp_c.try_emit_program_string cfg final_core with
  | Ok _ -> ()
  | Error message -> Alcotest.fail message

let assert_contains label output expected =
  Alcotest.(check bool) label true (Blorp.Modules.contains output expected)

let compile_supported_blorp_source source =
  let typed = typed_program_from_source source in
  typed |> final_core_from_typed |> assert_blorp_accepts_final_core;
  let output = Blorp.Core_pipeline.compile_typed typed in
  assert_contains "pipeline used Blorp C artifact path" output
    "/* Blorp final Core C artifact */";
  output

let compile_module_source_with_final_core source =
  let final_core = ref None in
  let on_stage stage prog =
    if stage = Blorp.Core_stage.Final then final_core := Some prog
  in
  let compiled =
    match
      Blorp.Pipeline.compile ~embed_runtime:true ~on_stage ~filename:"<test>"
        ~source ()
    with
    | Ok (Blorp.Pipeline.Compiled compiled) -> compiled
    | Ok (Blorp.Pipeline.Stopped_at stage) ->
        Alcotest.failf "unexpected stop after %s"
          (Blorp.Core_stage.to_string stage)
    | Error errors ->
        Alcotest.failf "expected no compile errors, got: %s"
          (String.concat "; "
             (List.map (fun (e : Blorp.Ast.compiler_error) -> e.message) errors))
  in
  let final_core =
    match !final_core with
    | Some prog -> prog
    | None -> Alcotest.fail "expected final Core snapshot"
  in
  (compiled, final_core)

(** Compile a minimal program through the default C backend via the
    full [Backend.S] flow: create_ctx → emit_program → finalize. *)
let test_c_backend_matches_contract () =
  (* Build a trivial program that goes through every Core pass. *)
  let source = "func main(args: List[String]) -> Int:\n  42\n" in
  let typed = typed_program_from_source source in
  let output = Blorp.Core_pipeline.compile_typed typed in
  (* The emitted output is C code; we don't assert exact contents
     (compile-version drift would make that flaky) — just that it's
     non-empty and contains the expected main entry point. *)
  Alcotest.(check bool) "output non-empty" true (String.length output > 0);
  assert_contains "contains main" output "int main("

(** Passing an explicit backend with [?backend] bypasses the default backend
    selection. The default path attempts the Blorp C artifact first; an explicit
    [Core_emit_c.Backend] request should still emit through the OCaml backend. *)
let test_explicit_backend_param_bypasses_default_selection () =
  let source =
    "pure func double(x: Int) -> Int:\n\
    \  x * 2\n\n\n\
     func main(args: List[String]) -> Int:\n\
    \  double(21)\n"
  in
  let typed = typed_program_from_source source in
  let default_out = Blorp.Core_pipeline.compile_typed typed in
  let explicit_out =
    Blorp.Core_pipeline.compile_typed
      ~backend:(module Blorp.Core_emit_c.Backend : Blorp.Backend.S)
      typed
  in
  Alcotest.(check bool) "default non-empty" true (String.length default_out > 0);
  Alcotest.(check bool)
    "explicit non-empty" true
    (String.length explicit_out > 0);
  assert_contains "default uses Blorp backend" default_out
    "/* Blorp final Core C artifact */";
  assert_contains "explicit backend uses OCaml C emitter" explicit_out
    "#include <stdbool.h>";
  Alcotest.(check bool)
    "explicit backend bypasses Blorp marker" true
    (not
       (Blorp.Modules.contains explicit_out "/* Blorp final Core C artifact */"))

let test_blorp_backend_emits_scalar_core_subset () =
  let ty_int = Blorp.Ast.TyNamed ("Int", []) in
  let loc = Blorp.Ast.dummy_loc in
  let main_body =
    {
      Blorp.Core.desc =
        CBin
          ( Blorp.Ast.Mod,
            { Blorp.Core.desc = CLit (Blorp.Ast.LitInt 7L); ty = ty_int; loc },
            { Blorp.Core.desc = CLit (Blorp.Ast.LitInt 3L); ty = ty_int; loc }
          );
      ty = ty_int;
      loc;
    }
  in
  let main_func =
    {
      Blorp.Core.cf_name = "main";
      cf_module = None;
      cf_type_params = [];
      cf_params = [];
      cf_return_ty = ty_int;
      cf_body = Some main_body;
      cf_is_pure = false;
      cf_kind = CFUser;
      cf_def_id = 1;
    }
  in
  let program =
    [ { Blorp.Core.cd_desc = CDFunc main_func; cd_loc = loc; cd_doc = None } ]
  in
  let ctx =
    Blorp.Core_emit_blorp_c.Backend.create_ctx
      ~reg:(Blorp.Codegen_types.create_registry ())
      Blorp.Core_emit_blorp_c.Backend.default_config
  in
  Blorp.Core_emit_blorp_c.Backend.emit_program ctx program;
  let output = Blorp.Core_emit_blorp_c.Backend.finalize ctx in
  Alcotest.(check bool)
    "Blorp backend emits main" true
    (Blorp.Modules.contains output "int main(void)");
  Alcotest.(check bool)
    "Blorp backend emits return value" true
    (Blorp.Modules.contains output "return ((3) == 0 ? 0 : (7 % 3));")

let test_blorp_backend_emits_cast_core_subset () =
  let ty_int = Blorp.Ast.TyNamed ("Int", []) in
  let ty_float = Blorp.Ast.TyNamed ("Float", []) in
  let loc = Blorp.Ast.dummy_loc in
  let cast_body =
    {
      Blorp.Core.desc =
        CCast
          ( { Blorp.Core.desc = CLit (Blorp.Ast.LitInt 7L); ty = ty_int; loc },
            ty_float );
      ty = ty_float;
      loc;
    }
  in
  let cast_func =
    {
      Blorp.Core.cf_name = "cast_value";
      cf_module = None;
      cf_type_params = [];
      cf_params = [];
      cf_return_ty = ty_float;
      cf_body = Some cast_body;
      cf_is_pure = true;
      cf_kind = CFUser;
      cf_def_id = 10;
    }
  in
  let program =
    [ { Blorp.Core.cd_desc = CDFunc cast_func; cd_loc = loc; cd_doc = None } ]
  in
  let ctx =
    Blorp.Core_emit_blorp_c.Backend.create_ctx
      ~reg:(Blorp.Codegen_types.create_registry ())
      Blorp.Core_emit_blorp_c.Backend.default_config
  in
  Blorp.Core_emit_blorp_c.Backend.emit_program ctx program;
  let output = Blorp.Core_emit_blorp_c.Backend.finalize ctx in
  assert_contains "Blorp backend emits Float return type" output
    "double cast_value(void)";
  assert_contains "Blorp backend emits C cast" output "return ((double)7);"

let test_pipeline_uses_blorp_backend_for_scalar_subset () =
  let source = "func main(args: List[String]) -> Int:\n  7\n" in
  let output = compile_supported_blorp_source source in
  assert_contains "pipeline emitted C entrypoint args" output
    "int main(int argc, char** argv)"

let test_pipeline_uses_blorp_backend_for_helper_call () =
  let source =
    "pure func add_one(x: Int) -> Int:\n\
    \  x + 1\n\n\
     func main(args: List[String]) -> Int:\n\
    \  add_one(6)\n"
  in
  let output = compile_supported_blorp_source source in
  assert_contains "pipeline emitted helper function" output
    "long add_one(long x)";
  assert_contains "pipeline emitted helper call" output "return add_one(6);"

let test_pipeline_uses_blorp_backend_for_while_loop () =
  let source =
    "func main(args: List[String]) -> Int:\n\
    \  var counter: Int = 0\n\
    \  while counter < 3:\n\
    \    counter = counter + 1\n\
    \  counter\n"
  in
  let output = compile_supported_blorp_source source in
  assert_contains "pipeline emitted while loop" output "while ((counter < 3))";
  assert_contains "pipeline returned loop result" output "return counter;"

let test_pipeline_uses_blorp_backend_for_loop_break_continue () =
  let source =
    "func main(args: List[String]) -> Int:\n\
    \  var counter: Int = 0\n\
    \  while counter < 5:\n\
    \    counter = counter + 1\n\
    \    if counter == 3:\n\
    \      continue\n\
    \    if counter == 4:\n\
    \      break\n\
    \  counter\n"
  in
  let output = compile_supported_blorp_source source in
  assert_contains "pipeline emitted continue" output "continue;";
  assert_contains "pipeline emitted break" output "break;";
  Alcotest.(check bool)
    "pipeline did not emit void if result temp" true
    (not (Blorp.Modules.contains output "__if_result"))

let test_pipeline_uses_blorp_backend_for_cast () =
  let source =
    "pure func int_to_float(x: Int) -> Float:\n\
    \  to_float(x)\n\n\
     func main(args: List[String]) -> Int:\n\
    \  to_int(int_to_float(7))\n"
  in
  let output = compile_supported_blorp_source source in
  assert_contains "pipeline emitted cast helper" output "int_to_float(long x)"

let test_pipeline_uses_blorp_backend_with_embedded_runtime () =
  let source = "func main(args: List[String]) -> Int:\n  7\n" in
  let typed = typed_program_from_source source in
  let output = Blorp.Core_pipeline.compile_typed ~embed_runtime:true typed in
  assert_contains "pipeline used Blorp C artifact path" output
    "/* Blorp final Core C artifact */";
  assert_contains "pipeline embedded runtime" output
    "blorp Runtime - Embedded Version"

let test_module_pipeline_uses_blorp_backend_by_default () =
  let source = "func main(args: List[String]) -> Int:\n  7\n" in
  let compiled, final_core = compile_module_source_with_final_core source in
  assert_blorp_accepts_final_core ~embed_runtime:true final_core;
  assert_contains "module pipeline used Blorp C artifact path" compiled.c_code
    "/* Blorp final Core C artifact */"

let suite =
  [
    ( "contract",
      [
        Alcotest.test_case "C backend satisfies Backend.S" `Quick
          test_c_backend_matches_contract;
        Alcotest.test_case "explicit backend bypasses default selection" `Quick
          test_explicit_backend_param_bypasses_default_selection;
        Alcotest.test_case "Blorp backend emits scalar Core subset" `Quick
          test_blorp_backend_emits_scalar_core_subset;
        Alcotest.test_case "Blorp backend emits cast Core subset" `Quick
          test_blorp_backend_emits_cast_core_subset;
        Alcotest.test_case "pipeline uses Blorp backend for scalar subset"
          `Quick test_pipeline_uses_blorp_backend_for_scalar_subset;
        Alcotest.test_case "pipeline uses Blorp backend for helper call" `Quick
          test_pipeline_uses_blorp_backend_for_helper_call;
        Alcotest.test_case "pipeline uses Blorp backend for while loop" `Quick
          test_pipeline_uses_blorp_backend_for_while_loop;
        Alcotest.test_case "pipeline uses Blorp backend for loop break/continue"
          `Quick test_pipeline_uses_blorp_backend_for_loop_break_continue;
        Alcotest.test_case "pipeline uses Blorp backend for cast" `Quick
          test_pipeline_uses_blorp_backend_for_cast;
        Alcotest.test_case "pipeline uses Blorp backend with embedded runtime"
          `Quick test_pipeline_uses_blorp_backend_with_embedded_runtime;
        Alcotest.test_case "module pipeline uses Blorp backend by default"
          `Quick test_module_pipeline_uses_blorp_backend_by_default;
      ] );
  ]
