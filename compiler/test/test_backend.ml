(** Unit tests for [Backend.S] + the default C backend.

    Phase 5.6: the backend abstraction ships without a second
    concrete implementation, so the main value of these tests is
    proving that (a) the type contract is enforceable and (b) the C
    backend is a valid instance of it. A mechanical compile here
    catches any silent drift between [Backend.S] and
    [Core_emit_c.Backend]. *)

(** Compile a minimal program through the default C backend via the
    full [Backend.S] flow: create_ctx → emit_program → finalize. *)
let test_c_backend_matches_contract () =
  (* Build a trivial program that goes through every Core pass. *)
  let source = "func main(args: List[String]) -> Int:\n  42\n" in
  Blorp.Lexer.reset_state ();
  let lexbuf = Lexing.from_string source in
  let program = Blorp.Parser.program Blorp.Lexer.next_token lexbuf in
  let program = Blorp.Interp_parser.transform_program program in
  let typed =
    match Blorp.Typecheck.typecheck_typed program with
    | Ok typed -> typed
    | Error errors ->
        Alcotest.failf "expected no type errors, got: %s"
          (String.concat "; "
             (List.map (fun (e : Blorp.Ast.compiler_error) -> e.message) errors))
  in
  let output = Blorp.Core_pipeline.compile_typed typed in
  (* The emitted output is C code; we don't assert exact contents
     (compile-version drift would make that flaky) — just that it's
     non-empty and contains the expected main entry point. *)
  Alcotest.(check bool) "output non-empty" true (String.length output > 0);
  Alcotest.(check bool)
    "contains main" true
    (Blorp.Modules.contains output "int main(")

(** Passing an explicit backend with [?backend] should round-trip
    identically to the default. The default is [Core_emit_c.Backend];
    packing it as a first-class module and feeding it back in should
    produce the same output. *)
let test_explicit_backend_param_roundtrip () =
  let source =
    "pure func double(x: Int) -> Int:\n\
    \  x * 2\n\n\n\
     func main(args: List[String]) -> Int:\n\
    \  double(21)\n"
  in
  Blorp.Lexer.reset_state ();
  let lexbuf = Lexing.from_string source in
  let program = Blorp.Parser.program Blorp.Lexer.next_token lexbuf in
  let program = Blorp.Interp_parser.transform_program program in
  let typed =
    match Blorp.Typecheck.typecheck_typed program with
    | Ok typed -> typed
    | Error errors ->
        Alcotest.failf "expected no type errors, got: %s"
          (String.concat "; "
             (List.map (fun (e : Blorp.Ast.compiler_error) -> e.message) errors))
  in
  let default_out = Blorp.Core_pipeline.compile_typed typed in
  (* Explicit backend via first-class module — [Core_emit_c.Backend]
     matches [Backend.S], so packing it works. The explicit path
     uses [default_config] (embed_runtime=false), same as the
     default parameter — output should match exactly. *)
  let explicit_out =
    Blorp.Core_pipeline.compile_typed
      ~backend:(module Blorp.Core_emit_c.Backend : Blorp.Backend.S)
      typed
  in
  Alcotest.(check bool) "default non-empty" true (String.length default_out > 0);
  Alcotest.(check bool)
    "explicit non-empty" true
    (String.length explicit_out > 0);
  Alcotest.(check bool)
    "outputs match" true
    (String.equal default_out explicit_out)

let suite =
  [
    ( "contract",
      [
        Alcotest.test_case "C backend satisfies Backend.S" `Quick
          test_c_backend_matches_contract;
        Alcotest.test_case "explicit backend roundtrips default" `Quick
          test_explicit_backend_param_roundtrip;
      ] );
  ]
