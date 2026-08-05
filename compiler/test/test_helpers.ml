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

let typed_decl_of_ast decl =
  match Blorp.Typed_ast.of_ast_program [ decl ] with
  | Error error -> Error error
  | Ok program -> (
      match Blorp.Typed_ast.program_decls program with
      | [ typed_decl ] -> Ok typed_decl
      | _ -> assert false)

let rec typed_decl_func decl =
  match Blorp.Typed_ast.decl_view decl with
  | Blorp.Typed_ast.DeclFunction func -> Some func
  | Blorp.Typed_ast.DeclPrivate inner -> typed_decl_func inner
  | Blorp.Typed_ast.DeclVar _
  | Blorp.Typed_ast.DeclRecord _
  | Blorp.Typed_ast.DeclTypeAlias _
  | Blorp.Typed_ast.DeclImpl _
  | Blorp.Typed_ast.DeclOther ->
      None

let typed_expr_of_ast expr =
  let var : Blorp.Ast.var_decl =
    {
      var_name = Some "__typed_ast_test_value";
      var_pattern = None;
      var_type = None;
      var_value = expr;
      var_is_mutable = false;
      var_is_const = false;
    }
  in
  let decl : Blorp.Ast.decl =
    {
      decl_desc = DVar var;
      decl_loc = expr.expr_loc;
      decl_doc = None;
    }
  in
  match typed_decl_of_ast decl with
  | Error error -> Error error
  | Ok typed_decl -> (
      match Blorp.Typed_ast.decl_view typed_decl with
      | Blorp.Typed_ast.DeclVar typed_var ->
          Blorp.Typed_ast.var_value_expr typed_var
      | _ -> assert false)

let typed_expr_with_type_info ?source_ty ?(origin = Inferred) ?resolved_call
    ?(proofs = Blorp.Type_proof_metadata.unproven_expr) ~semantic_ty ~value_ty
    ~widening expr =
  let info : Blorp.Ast.expr_type_info =
    {
      source_ty;
      semantic_ty;
      value_ty;
      origin;
      widening;
      proofs;
      resolved_call;
    }
  in
  typed_expr_of_ast (Blorp.Ast.with_expr_type_info expr info)

let parse_and_typecheck source =
  match
    Blorp.Pipeline.typecheck_module_only_typed ~filename:"test_input.brp"
      ~source
  with
  | Ok (state, typed_program) ->
      ( Blorp.Typed_ast.program_ast typed_program,
        List.rev state.Blorp.Typecheck.errors )
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

(** Assert a hand-built AST program satisfies the typed boundary. *)
let expect_valid_typed_program program =
  match Blorp.Typed_ast.of_ast_program program with
  | Ok typed -> typed
  | Error _ -> Alcotest.fail "expected test program to satisfy Typed_ast"

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
