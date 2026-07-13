(** Shared helpers for type-checker and inference unit tests.

    Provides [parse_and_typecheck] for running the full frontend on a source
    string, isolation wrappers for mutable global state, and concise assertion
    helpers ([expect_ok], [expect_error], [expect_body_type], etc.) that reduce
    per-test ceremony to 3-6 lines. *)

open Blorp.Ast
open Blorp.Types

(* ============================================================================
   Substring utility
   ============================================================================ *)

let contains_substring haystack needle = Blorp.Modules.contains haystack needle

let expr_type_info_from_type ty : expr_type_info =
  {
    source_ty = None;
    semantic_ty = ty;
    value_ty = ty;
    origin = Inferred;
    widening = Keep ty;
    proofs = Blorp.Type_proof_metadata.unproven_expr;
    resolved_call = None;
  }

let check_core_error_raises ~(phase : Blorp.Core_error.phase_tag) ~msg_contains
    f =
  match f () with
  | exception Blorp.Core_error.Core_error e ->
      if e.phase <> phase then
        Alcotest.failf "Core_error phase mismatch: expected %S, got %S (msg=%S)"
          (Blorp.Core_error.phase_tag_to_string phase)
          (Blorp.Core_error.phase_tag_to_string e.phase)
          e.msg;
      if not (contains_substring e.msg msg_contains) then
        Alcotest.failf "Core_error msg %S does not contain %S" e.msg
          msg_contains
  | _ ->
      Alcotest.failf "expected Core_error %s containing %S; no exception raised"
        (Blorp.Core_error.phase_tag_to_string phase)
        msg_contains

(* ============================================================================
   Env isolation — run the test inside its own [Session.t]

   [Env.empty ()] reads [Session.current ()] for its [impl_index] /
   [ufcs_methods] tables. Function overload sets are env-local lexical
   state. Wrapping a test in a fresh session gives session-owned tables
   isolation; when the session goes out of scope, its state goes with it.
   Replaces the old snapshot/restore hack that operated on the
   process-global default session.
   ============================================================================ *)

let with_isolated_env (f : unit -> 'a) : 'a =
  let sess = Blorp.Session.create () in
  Blorp.Session.with_current sess f

(* ============================================================================
   Parse + typecheck entry point
   ============================================================================ *)

let parse_program ?(filename = "test_input.brp") source =
  match Blorp.Modules.parse_typecheck_source ~filename source with
  | Ok program -> program
  | Error err ->
      Alcotest.failf "expected source to parse, got: %s" err.Blorp.Ast.message

let parse_and_typecheck source =
  match
    Blorp.Pipeline.typecheck_module_only ~filename:"test_input.brp" ~source
  with
  | Ok (state, typed_program) ->
      (typed_program, List.rev state.Blorp.Typecheck.errors)
  | Error errors -> ([], errors)

(** Parse, typecheck, and isolate env state in one call. *)
let typecheck_src src = with_isolated_env (fun () -> parse_and_typecheck src)

(* ============================================================================
   AST query helpers
   ============================================================================ *)

(** Find the body of a top-level function by name. *)
let find_func_body (prog : program) (name : string) : expr option =
  List.find_map
    (fun d ->
      match d.decl_desc with
      | DFunc f when f.func_name = Some name -> func_body_expr_opt f.func_body
      | _ -> None)
    prog

(** Walk the typed AST and collect every expr that has [expr_type = None]. *)
let collect_untyped (root : expr) : expr list =
  let out = ref [] in
  let rec go (e : expr) =
    (match e.expr_type with None -> out := e :: !out | Some _ -> ());
    List.iter go (expr_children e)
  in
  go root;
  List.rev !out

(* ============================================================================
   Assertion helpers — error tests
   ============================================================================ *)

let format_errors errors =
  String.concat "\n"
    (List.map (fun (e : compiler_error) -> "  - " ^ e.message) errors)

(** Assert source typechecks with zero errors. *)
let expect_ok src =
  let _typed, errors = typecheck_src src in
  if errors <> [] then
    Alcotest.failf "expected no errors, got %d:\n%s" (List.length errors)
      (format_errors errors)

(** Assert source typechecks with zero errors and return the typed AST. *)
let expect_ok_typed src =
  let typed, errors = typecheck_src src in
  if errors <> [] then
    Alcotest.failf "expected no errors, got %d:\n%s" (List.length errors)
      (format_errors errors);
  typed

(** Assert a hand-built AST expression satisfies the typed boundary. Use this
    in Core tests that need custom AST shapes but should still exercise typed
    entrypoints instead of transitional compatibility wrappers. *)
let expect_valid_typed_expr expr =
  match Blorp.Typed_ast.of_ast_expr expr with
  | Ok typed -> typed
  | Error _ -> Alcotest.fail "expected test expression to satisfy Typed_ast"

(** Assert a hand-built AST declaration satisfies the typed boundary. *)
let expect_valid_typed_decl decl =
  match Blorp.Typed_ast.of_ast_decl decl with
  | Ok typed -> typed
  | Error _ -> Alcotest.fail "expected test declaration to satisfy Typed_ast"

(** Assert a hand-built AST program satisfies the typed boundary. *)
let expect_valid_typed_program program =
  match Blorp.Typed_ast.of_ast_program program with
  | Ok typed -> typed
  | Error _ -> Alcotest.fail "expected test program to satisfy Typed_ast"

let expect_typed_expr_error expr check =
  match Blorp.Typed_ast.of_ast_expr expr with
  | Ok _ -> Alcotest.fail "expected test expression to fail Typed_ast"
  | Error err -> check err

let expect_typed_decl_error decl check =
  match Blorp.Typed_ast.of_ast_decl decl with
  | Ok _ -> Alcotest.fail "expected test declaration to fail Typed_ast"
  | Error err -> check err

let lower_valid_expr expr =
  Blorp.Core_lower.lower_typed_expr (expect_valid_typed_expr expr)

let lower_valid_decl decl =
  Blorp.Core_lower.lower_typed_decl (expect_valid_typed_decl decl)

let lower_valid_program program =
  Blorp.Core_lower.lower_typed_program (expect_valid_typed_program program)

let compile_valid_program ?embed_runtime ?profile ?debug ?on_stage
    ?check_invariants program =
  Blorp.Core_pipeline.compile_typed ?embed_runtime ?profile ?debug ?on_stage
    ?check_invariants
    (expect_valid_typed_program program)

(** Assert source produces at least one error whose message contains [message]. *)
let expect_error src ~message =
  let _typed, errors = typecheck_src src in
  if errors = [] then
    Alcotest.failf
      "expected an error containing %S, but typechecked successfully" message;
  let found =
    List.exists
      (fun (e : compiler_error) -> contains_substring e.message message)
      errors
  in
  if not found then
    Alcotest.failf "no error contains %S\nActual errors:\n%s" message
      (format_errors errors)

(* ============================================================================
   Assertion helpers — typed AST
   ============================================================================ *)

(** Assert the inferred return type of a function's body matches [ty]. *)
let expect_body_type src ~func ~ty =
  let typed = expect_ok_typed src in
  match find_func_body typed func with
  | Some body -> (
      match body.expr_type with
      | Some actual ->
          if not (types_equal actual ty) then
            Alcotest.failf "function '%s' body: expected %s, got %s" func
              (type_to_string ty) (type_to_string actual)
      | None -> Alcotest.failf "function '%s' body has no inferred type" func)
  | None -> Alcotest.failf "function '%s' not found in typed AST" func
