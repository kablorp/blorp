(** Unit tests for Infer module and related type-inference primitives.

    These are regression guards for the CURRENT behavior of the primitives
    that the upcoming [TyMeta] + zonking refactor will touch. They cover:

    - Fresh type-variable generation (name format, uniqueness, reset).
    - Substitution building via [unify] with [~type_params], exercising the
      same shapes that [Infer.build_subst] walks (TyVar, TyNamed type param,
      parameterized, nested, tuple, func, range).
    - End-to-end [infer_expr] on tiny source programs, asserting the typed
      AST has [expr_type] populated and generic call-site substitutions
      produce concrete [Some Int]-style types (no lingering [TyVar]).

    Note: [Infer.build_subst] is not exposed in [infer.mli], so the direct
    primitive tests use [Types.unify ~type_params:...] as a faithful proxy
    for the same structural walk. The end-to-end tests then pin down the
    substitution outcome at actual call sites. *)

open Blorp.Ast
open Blorp.Types

(* ============================================================================
   Helpers (match test_types.ml style)
   ============================================================================ *)

let check_true msg b = Alcotest.(check bool) msg true b
let check_false msg b = Alcotest.(check bool) msg false b
let check_string msg = Alcotest.(check string) msg
let check_int msg = Alcotest.(check int) msg

(** Look up a var in a subst_map and assert it resolved to [expected]. *)
let check_binding msg (subst : subst_map) var expected =
  match lookup_subst var subst with
  | Some ty ->
      check_true
        (Printf.sprintf "%s: %s = %s (got %s)" msg var (type_to_string expected)
           (type_to_string ty))
        (types_equal ty expected)
  | None -> Alcotest.failf "%s: expected binding for %s, none found" msg var

(* ============================================================================
   build_subst shapes (tested via [unify ~type_params] — same structural walk)

   These mirror the test cases the future TyMeta refactor must preserve:
   for each (param, arg) pair, the walk extracts one binding per type param
   occurrence. [unify] exposes the same substitution map.
   ============================================================================ *)

let test_subst_tyvar_to_concrete () =
  (* param=TyVar "T", arg=ty_int -> [T -> Int] *)
  match unify (TyVar "T") ty_int with
  | Some s -> check_binding "T -> Int" s "T" ty_int
  | None -> Alcotest.fail "unify failed for TyVar T vs Int"

let test_subst_non_matching () =
  (* param=Int, arg=Int -> [] (no type vars to bind) *)
  match unify ty_int ty_int with
  | Some s -> check_int "no bindings" 0 (List.length s)
  | None -> Alcotest.fail "unify failed for Int vs Int"

let test_subst_named_with_args () =
  (* param=List[T], arg=List[String] -> [T -> String] *)
  match
    unify (TyNamed ("List", [ TyVar "T" ])) (TyNamed ("List", [ ty_string ]))
  with
  | Some s -> check_binding "T -> String" s "T" ty_string
  | None -> Alcotest.fail "unify failed for List[T] vs List[String]"

let test_subst_nested () =
  (* param=Option[List[T]], arg=Option[List[Int]] -> [T -> Int] *)
  let param = TyNamed ("Option", [ TyNamed ("List", [ TyVar "T" ]) ]) in
  let arg = TyNamed ("Option", [ TyNamed ("List", [ ty_int ]) ]) in
  match unify param arg with
  | Some s -> check_binding "T -> Int" s "T" ty_int
  | None -> Alcotest.fail "unify failed for nested Option[List[T]]"

let test_subst_two_params_tuple () =
  (* param=(T, U), arg=(Int, String) -> [T -> Int; U -> String] *)
  let param = TyTuple [ TyVar "T"; TyVar "U" ] in
  let arg = TyTuple [ ty_int; ty_string ] in
  match unify param arg with
  | Some s ->
      check_binding "T -> Int" s "T" ty_int;
      check_binding "U -> String" s "U" ty_string
  | None -> Alcotest.fail "unify failed for (T, U) vs (Int, String)"

let test_subst_func () =
  (* param=(T) -> U, arg=(Int) -> String -> [T -> Int; U -> String] *)
  let param =
    TyFunc { params = [ TyVar "T" ]; return = TyVar "U"; is_pure = false }
  in
  let arg =
    TyFunc { params = [ ty_int ]; return = ty_string; is_pure = false }
  in
  match unify param arg with
  | Some s ->
      check_binding "T -> Int" s "T" ty_int;
      check_binding "U -> String" s "U" ty_string
  | None -> Alcotest.fail "unify failed for (T) -> U vs (Int) -> String"

let test_subst_range_binds_inner () =
  (* param=..#N, arg=..#4 -> [N -> #4]
     Note: in blorp's type-param convention, dimension params use TyVar names
     like "N" (not "#N"). The walk strips the TyRange wrapper on both sides. *)
  match unify (TyRange (TyVar "N")) (TyRange (TyConstInt 4)) with
  | Some s -> check_binding "N -> #4" s "N" (TyConstInt 4)
  | None -> Alcotest.fail "unify failed for ..#N vs ..#4"

let test_subst_tynamed_as_param () =
  (* param=TyNamed ("T", []) (get_constructor path), arg=ty_int,
     type_params=["T"] -> [T -> Int] *)
  match unify ~type_params:[ "T" ] (TyNamed ("T", [])) ty_int with
  | Some s -> check_binding "TyNamed T -> Int" s "T" ty_int
  | None -> Alcotest.fail "unify failed for TyNamed T vs Int with type_params"

let test_subst_tyvar_always_binds () =
  (* Current behavior: a bare [TyVar "T"] on the param side binds unconditionally,
     regardless of whether "T" is listed in [type_params]. The upcoming [TyMeta]
     refactor must decide whether to preserve this or narrow it. *)
  match unify ~type_params:[ "U" ] (TyVar "T") ty_int with
  | Some s -> check_binding "T -> Int (despite type_params=[U])" s "T" ty_int
  | None -> Alcotest.fail "unify failed for TyVar T vs Int"

(* ============================================================================
   End-to-end infer_expr via [Typecheck.typecheck] on tiny source programs.

   Each test parses a short source string, runs the full type-checker, and
   asserts properties of the typed AST. These tests pin down the observable
   outcome of [Infer.build_subst] at actual call sites.

   Isolation: each test runs inside its own [Session.t] so the session-owned
   [impl_index] / [ufcs_methods] tables are fresh per test. Function overload
   sets are env-local lexical state.
   ============================================================================ *)

(** Run [f] inside a fresh session so env tables are isolated. *)
let with_isolated_env (f : unit -> 'a) : 'a =
  let sess = Blorp.Session.create () in
  Blorp.Session.with_current sess f

let parse_and_typecheck source =
  let program = Test_helpers.parse_program source in
  Blorp.Typecheck.typecheck program

let parse_and_typecheck_std_with_env source =
  let program = Test_helpers.parse_program source in
  Blorp.Typecheck.typecheck_with_env ~module_origin:Blorp.Session.Stdlib_module
    program

let parse_and_typecheck_module ?(filename = "test_input.brp") source =
  match Blorp.Pipeline.typecheck_module_only ~filename ~source with
  | Ok (state, typed_program) ->
      (typed_program, List.rev state.Blorp.Typecheck.errors)
  | Error errors -> ([], errors)

let format_errors errors =
  String.concat "\n"
    (List.map (fun (e : compiler_error) -> "  - " ^ e.message) errors)

let check_no_type_errors errors =
  if errors <> [] then
    Alcotest.failf "expected no type errors, got %d:\n%s" (List.length errors)
      (format_errors errors)

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

let assert_keep_payload label expected_ty (expr : expr) =
  match expr.expr_type_info with
  | Some info -> (
      check_true (label ^ " semantic type")
        (types_equal info.semantic_ty expected_ty);
      check_true (label ^ " value type") (types_equal info.value_ty expected_ty);
      match info.widening with
      | Keep ty ->
          check_true (label ^ " keep type") (types_equal ty expected_ty)
      | Widen _ -> Alcotest.failf "%s unexpectedly records widening" label)
  | None -> Alcotest.failf "%s expr_type_info is None" label

let find_first_expr pred (root : expr) : expr option =
  let rec go e =
    if pred e then Some e else List.find_map go (expr_children e)
  in
  go root

let require_call_payload ?expected_callee_ty typed func_name callee_name
    expected_return =
  match find_func_body typed func_name with
  | Some body -> (
      match
        find_first_expr
          (function
            | { expr_desc = ECall ({ expr_desc = EIdent name; _ }, _); _ }
              when name = callee_name ->
                true
            | _ -> false)
          body
      with
      | Some ({ expr_desc = ECall (callee, _); _ } as call) -> (
          assert_keep_payload (callee_name ^ " call") expected_return call;
          match callee.expr_type with
          | Some callee_ty ->
              let expected_callee_ty =
                Option.value expected_callee_ty ~default:callee_ty
              in
              assert_keep_payload (callee_name ^ " callee") expected_callee_ty
                callee
          | None -> Alcotest.failf "%s callee expr_type is None" callee_name)
      | Some _ -> Alcotest.failf "%s expression was not a call" callee_name
      | None -> Alcotest.failf "%s call not found" callee_name)
  | None -> Alcotest.failf "function %s not found" func_name

let require_resolved_call typed func_name callee_name =
  match find_func_body typed func_name with
  | Some body -> (
      match
        find_first_expr
          (function
            | { expr_desc = ECall ({ expr_desc = EIdent name; _ }, _); _ }
              when name = callee_name ->
                true
            | _ -> false)
          body
      with
      | Some call -> (
          match call.expr_type_info with
          | Some { resolved_call = Some resolved; _ } -> resolved
          | Some _ ->
              Alcotest.failf "%s call has no resolved-call metadata" callee_name
          | None -> Alcotest.failf "%s call has no type info" callee_name)
      | None -> Alcotest.failf "%s call not found" callee_name)
  | None -> Alcotest.failf "function %s not found" func_name

let require_resolved_call_matching typed func_name label pred =
  let describe_origin = function
    | CallableLocal -> "local"
    | CallableImported path -> "imported:" ^ path
    | CallableBuiltin -> "builtin"
    | CallableForeign -> "foreign"
    | CallableConstructor name -> "constructor:" ^ name
    | CallableImplMethod -> "impl-method"
  in
  let describe_target = function
    | CallDirect { source_name; origin; _ } ->
        Printf.sprintf "direct:%s:%s" source_name (describe_origin origin)
    | CallTraitMethod { trait_name; method_name; _ } ->
        Printf.sprintf "trait:%s.%s" trait_name method_name
    | CallClosure _ -> "closure"
  in
  let describe_syntax = function
    | CallBare -> "bare"
    | CallMethod -> "method"
    | CallQualified path -> "qualified:" ^ path
    | CallClosureSyntax -> "closure"
    | CallTraitDispatch -> "trait-dispatch"
    | CallMethodOnlyUfcs -> "method-only-ufcs"
  in
  let rec collect_resolved acc expr =
    let acc =
      match expr.expr_type_info with
      | Some { resolved_call = Some resolved; _ } ->
          Printf.sprintf "%s/%s"
            (describe_syntax resolved.call_syntax)
            (describe_target resolved.call_target)
          :: acc
      | _ -> acc
    in
    List.fold_left collect_resolved acc (expr_children expr)
  in
  match find_func_body typed func_name with
  | Some body -> (
      match
        find_first_expr
          (fun expr ->
            match expr.expr_type_info with
            | Some { resolved_call = Some resolved; _ } -> pred resolved
            | _ -> false)
          body
      with
      | Some { expr_type_info = Some { resolved_call = Some resolved; _ }; _ }
        ->
          resolved
      | Some _ ->
          Alcotest.failf "%s expression lost resolved-call metadata" label
      | None ->
          let available =
            collect_resolved [] body |> List.rev |> String.concat ", "
          in
          Alcotest.failf "%s resolved call not found; available: [%s]" label
            available)
  | None -> Alcotest.failf "function %s not found" func_name

let require_direct_resolved_call ?expected_origin ?(expected_pure = true) typed
    func_name callee_name =
  let call = require_resolved_call typed func_name callee_name in
  Alcotest.(check bool)
    (callee_name ^ " bare call syntax")
    true
    (call.call_syntax = CallBare);
  match call.call_target with
  | CallDirect { callable_id; source_name; call_pure; origin } ->
      check_string (callee_name ^ " target name") callee_name source_name;
      Alcotest.(check bool)
        (callee_name ^ " call purity")
        expected_pure call_pure;
      Alcotest.(check bool)
        (callee_name ^ " callable id minted")
        true (callable_id >= 0);
      Option.iter
        (fun expected ->
          Alcotest.(check bool)
            (callee_name ^ " origin") true (origin = expected))
        expected_origin;
      call
  | CallTraitMethod _ ->
      Alcotest.failf "%s resolved as trait dispatch" callee_name
  | CallClosure _ -> Alcotest.failf "%s resolved as closure call" callee_name

let test_infer_integer_literal () =
  with_isolated_env (fun () ->
      let src = {|
func f() -> Int:
    42
|} in
      let typed, errors = parse_and_typecheck src in
      check_int "no type errors" 0 (List.length errors);
      match find_func_body typed "f" with
      | Some body -> (
          match body.expr_type with
          | Some ty -> check_true "body is Int" (types_equal ty ty_int)
          | None -> Alcotest.fail "body expr_type is None")
      | None -> Alcotest.fail "function f not found")

let test_call_metadata_for_direct_local_call () =
  with_isolated_env (fun () ->
      let src =
        {|
func id(x: Int) -> Int:
    x

func use() -> Int:
    id(1)
|}
      in
      let typed, errors = parse_and_typecheck src in
      check_int "no type errors" 0 (List.length errors);
      let call = require_resolved_call typed "use" "id" in
      Alcotest.(check bool) "bare call syntax" true (call.call_syntax = CallBare);
      check_true "instantiated param"
        (match call.instantiated_params with
        | [ ty ] -> types_equal ty ty_int
        | _ -> false);
      check_true "instantiated return"
        (types_equal call.instantiated_return ty_int);
      match call.call_target with
      | CallDirect { callable_id; source_name; call_pure; origin } ->
          Alcotest.(check string) "target name" "id" source_name;
          Alcotest.(check bool) "default function is impure" false call_pure;
          Alcotest.(check bool) "local origin" true (origin = CallableLocal);
          Alcotest.(check bool) "callable id minted" true (callable_id >= 0)
      | CallTraitMethod _ | CallClosure _ ->
          Alcotest.fail "expected direct callable metadata")

let test_call_metadata_for_local_method_syntax () =
  with_isolated_env (fun () ->
      let src =
        {|
pure func add_to(self: Int, amount: Int) -> Int:
    self + amount

pure func use(x: Int) -> Int:
    x.add_to(2)
|}
      in
      let typed, errors = parse_and_typecheck src in
      check_int "no type errors" 0 (List.length errors);
      let call =
        require_resolved_call_matching typed "use" "local method syntax"
          (fun call ->
            match call.call_target with
            | CallDirect { source_name = "add_to"; origin = CallableLocal; _ }
              ->
                true
            | _ -> false)
      in
      Alcotest.(check bool)
        "method call syntax" true
        (call.call_syntax = CallMethod);
      check_true "instantiated receiver"
        (match call.instantiated_params with
        | [ self_ty; amount_ty ] ->
            types_equal self_ty ty_int && types_equal amount_ty ty_int
        | _ -> false);
      check_true "instantiated return"
        (types_equal call.instantiated_return ty_int);
      match call.call_target with
      | CallDirect { callable_id; call_pure; _ } ->
          Alcotest.(check bool) "local method purity" true call_pure;
          Alcotest.(check bool) "callable id minted" true (callable_id >= 0)
      | CallTraitMethod _ | CallClosure _ ->
          Alcotest.fail "expected direct method metadata")

let test_call_metadata_for_closure_call () =
  with_isolated_env (fun () ->
      let src = {|
func use(f: pure (Int) -> Int) -> Int:
    f(1)
|} in
      let typed, errors = parse_and_typecheck src in
      check_int "no type errors" 0 (List.length errors);
      let call = require_resolved_call typed "use" "f" in
      Alcotest.(check bool)
        "closure call syntax" true
        (call.call_syntax = CallClosureSyntax);
      check_true "instantiated param"
        (match call.instantiated_params with
        | [ ty ] -> types_equal ty ty_int
        | _ -> false);
      check_true "instantiated return"
        (types_equal call.instantiated_return ty_int);
      match call.call_target with
      | CallClosure { call_pure } ->
          Alcotest.(check bool) "closure purity" true call_pure
      | CallDirect _ | CallTraitMethod _ ->
          Alcotest.fail "expected closure-call metadata")

let test_call_metadata_for_constructor_call () =
  with_isolated_env (fun () ->
      let src = {|
func make(x: Int) -> Option[Int]:
    Some(x)
|} in
      let typed, errors = parse_and_typecheck src in
      check_int "no type errors" 0 (List.length errors);
      let call =
        require_direct_resolved_call
          ~expected_origin:(CallableConstructor "Option") typed "make" "Some"
      in
      check_true "instantiated constructor param"
        (match call.instantiated_params with
        | [ ty ] -> types_equal ty ty_int
        | _ -> false);
      check_true "instantiated constructor return"
        (types_equal call.instantiated_return (TyNamed ("Option", [ ty_int ]))))

let test_call_metadata_for_trait_dispatch () =
  with_isolated_env (fun () ->
      let src =
        {|
trait Weighted:
    pure func weight(self: Self) -> Int


func use[T: Weighted](x: T) -> Int:
    weight(x)
|}
      in
      let typed, errors = parse_and_typecheck src in
      check_int "no type errors" 0 (List.length errors);
      let call = require_resolved_call typed "use" "weight" in
      Alcotest.(check bool)
        "trait dispatch syntax" true
        (call.call_syntax = CallTraitDispatch);
      check_true "instantiated trait param"
        (match call.instantiated_params with
        | [ TyNamed ("T", []) ] | [ TyVar "T" ] -> true
        | _ -> false);
      check_true "instantiated trait return"
        (types_equal call.instantiated_return ty_int);
      match call.call_target with
      | CallTraitMethod { trait_name; method_name; call_pure; callable_id } ->
          check_string "trait name" "Weighted" trait_name;
          check_string "method name" "weight" method_name;
          Alcotest.(check (option int))
            "deferred trait has no concrete callable id" None callable_id;
          Alcotest.(check bool) "trait method purity" true call_pure
      | CallDirect _ | CallClosure _ ->
          Alcotest.fail "expected deferred trait dispatch metadata")

let test_call_metadata_for_module_qualified_function () =
  with_isolated_env (fun () ->
      let src =
        {|
import:
    list as L


pure func use(xs: List[Int]) -> List[Int]:
    L.reverse(xs)
|}
      in
      let typed, errors = parse_and_typecheck_module src in
      if errors <> [] then
        Alcotest.failf "expected no type errors, got %d:\n%s"
          (List.length errors)
          (String.concat "\n" (List.map (fun e -> "  - " ^ e.message) errors));
      let call =
        require_resolved_call_matching typed "use" "module-qualified function"
          (fun call ->
            match call.call_target with
            | CallDirect { source_name = "reverse"; origin; _ } ->
                origin = CallableImported "std/list"
            | _ -> false)
      in
      Alcotest.(check bool)
        "qualified call syntax" true
        (call.call_syntax = CallQualified "std/list");
      check_true "instantiated qualified param"
        (match call.instantiated_params with
        | [ TyNamed ("List", [ ty ]) ] -> types_equal ty ty_int
        | _ -> false);
      check_true "instantiated qualified return"
        (types_equal call.instantiated_return (TyNamed ("List", [ ty_int ])));
      match call.call_target with
      | CallDirect { callable_id; source_name; call_pure; origin } ->
          check_string "target name" "reverse" source_name;
          Alcotest.(check bool) "qualified function purity" true call_pure;
          Alcotest.(check bool) "callable id minted" true (callable_id >= 0);
          Alcotest.(check bool)
            "qualified function origin" true
            (origin = CallableImported "std/list")
      | CallTraitMethod _ | CallClosure _ ->
          Alcotest.fail "expected direct function metadata")

let test_call_metadata_for_annotated_module_qualified_function () =
  with_isolated_env (fun () ->
      let src =
        {|
import:
    fixed as F


func use() -> Fixed:
    price: Fixed = F.fixed(2.5, 2)
    price
|}
      in
      let typed, errors = parse_and_typecheck_module src in
      check_no_type_errors errors;
      let call =
        require_resolved_call_matching typed "use"
          "annotated module-qualified function" (fun call ->
            match call.call_target with
            | CallDirect { source_name = "fixed"; origin; _ } ->
                origin = CallableImported "std/fixed"
            | _ -> false)
      in
      Alcotest.(check bool)
        "annotated qualified call syntax" true
        (call.call_syntax = CallQualified "std/fixed");
      check_true "annotated qualified return"
        (types_equal call.instantiated_return (TyNamed ("Fixed", []))))

let test_call_metadata_for_imported_function_method_syntax () =
  with_isolated_env (fun () ->
      let src =
        {|
import:
    list: reverse


pure func use(xs: List[Int]) -> List[Int]:
    xs.reverse()
|}
      in
      let typed, errors = parse_and_typecheck_module src in
      check_no_type_errors errors;
      let call =
        require_resolved_call_matching typed "use"
          "imported function method syntax" (fun call ->
            match call.call_target with
            | CallDirect { source_name = "reverse"; origin; _ } ->
                origin = CallableImported "std/list"
            | _ -> false)
      in
      Alcotest.(check bool)
        "method call syntax" true
        (call.call_syntax = CallMethod);
      check_true "instantiated receiver"
        (match call.instantiated_params with
        | [ TyNamed ("List", [ ty ]) ] -> types_equal ty ty_int
        | _ -> false);
      check_true "instantiated return"
        (types_equal call.instantiated_return (TyNamed ("List", [ ty_int ])));
      match call.call_target with
      | CallDirect { callable_id; call_pure; _ } ->
          Alcotest.(check bool) "imported method purity" true call_pure;
          Alcotest.(check bool) "callable id minted" true (callable_id >= 0)
      | CallTraitMethod _ | CallClosure _ ->
          Alcotest.fail "expected imported direct method metadata")

let test_call_metadata_for_prelude_method_only_ufcs () =
  with_isolated_env (fun () ->
      let src =
        {|
pure func use(xs: List[Int]) -> List[Int]:
    xs.map(pure func(x: Int): x + 1)
|}
      in
      let typed, errors = parse_and_typecheck_module src in
      check_no_type_errors errors;
      let call =
        require_resolved_call_matching typed "use" "prelude method-only UFCS"
          (fun call ->
            match call.call_target with
            | CallDirect { origin; call_pure = true; _ } ->
                origin = CallableImported "std/list"
            | _ -> false)
      in
      Alcotest.(check bool)
        "method-only UFCS syntax" true
        (call.call_syntax = CallMethodOnlyUfcs);
      check_true "instantiated receiver"
        (match call.instantiated_params with
        | [
         TyNamed ("List", [ item_ty ]);
         TyFunc { params = [ lambda_param ]; return; is_pure = true };
        ] ->
            types_equal item_ty ty_int
            && types_equal lambda_param ty_int
            && types_equal return ty_int
        | _ -> false);
      check_true "instantiated return"
        (types_equal call.instantiated_return (TyNamed ("List", [ ty_int ])));
      match call.call_target with
      | CallDirect { callable_id; _ } ->
          Alcotest.(check bool) "callable id minted" true (callable_id >= 0)
      | CallTraitMethod _ | CallClosure _ ->
          Alcotest.fail "expected method-only direct metadata")

let test_call_metadata_for_imported_type_method_only_ufcs () =
  with_isolated_env (fun () ->
      let src =
        {|
import:
    option: Option(Some, None)


pure func use(opt: Option[Int]) -> Int:
    opt.get_or(0)
|}
      in
      let typed, errors = parse_and_typecheck_module src in
      check_no_type_errors errors;
      let call =
        require_resolved_call_matching typed "use"
          "imported type method-only UFCS" (fun call ->
            match call.call_target with
            | CallDirect { origin; call_pure = true; _ } ->
                origin = CallableImported "std/option"
            | _ -> false)
      in
      Alcotest.(check bool)
        "method-only UFCS syntax" true
        (call.call_syntax = CallMethodOnlyUfcs);
      check_true "instantiated receiver"
        (match call.instantiated_params with
        | [ TyNamed ("Option", [ item_ty ]); default_ty ] ->
            types_equal item_ty ty_int && types_equal default_ty ty_int
        | _ -> false);
      check_true "instantiated return"
        (types_equal call.instantiated_return ty_int);
      match call.call_target with
      | CallDirect { callable_id; _ } ->
          Alcotest.(check bool) "callable id minted" true (callable_id >= 0)
      | CallTraitMethod _ | CallClosure _ ->
          Alcotest.fail "expected method-only direct metadata")

let test_call_metadata_for_module_qualified_impl_method () =
  with_isolated_env (fun () ->
      let src =
        {|
import:
    bool as B


pure func use() -> String:
    B.to_string(True)
|}
      in
      let typed, errors = parse_and_typecheck_module src in
      if errors <> [] then
        Alcotest.failf "expected no type errors, got %d:\n%s"
          (List.length errors)
          (String.concat "\n" (List.map (fun e -> "  - " ^ e.message) errors));
      let call =
        require_resolved_call_matching typed "use"
          "module-qualified impl method" (fun call ->
            match call.call_target with
            | CallTraitMethod
                { trait_name = "Stringable"; method_name = "to_string"; _ } ->
                true
            | _ -> false)
      in
      Alcotest.(check bool)
        "qualified call syntax" true
        (match call.call_syntax with CallQualified _ -> true | _ -> false);
      check_true "instantiated impl param"
        (match call.instantiated_params with
        | [ TyNamed ("Bool", []) ] -> true
        | _ -> false);
      check_true "instantiated impl return"
        (types_equal call.instantiated_return ty_string);
      match call.call_target with
      | CallTraitMethod { trait_name; method_name; call_pure; callable_id } ->
          check_string "trait name" "Stringable" trait_name;
          check_string "method name" "to_string" method_name;
          (match callable_id with
          | Some id ->
              Alcotest.(check bool) "impl callable id minted" true (id >= 0)
          | None -> Alcotest.fail "expected concrete impl callable id");
          Alcotest.(check bool) "impl method purity" true call_pure
      | CallDirect _ | CallClosure _ ->
          Alcotest.fail "expected trait-method metadata")

let test_infer_integer_literal_carries_no_widening_payload () =
  with_isolated_env (fun () ->
      let src = {|
func f() -> Int:
    42
|} in
      let typed, errors = parse_and_typecheck src in
      check_int "no type errors" 0 (List.length errors);
      match find_func_body typed "f" with
      | Some body -> (
          match body.expr_type_info with
          | Some _ -> assert_keep_payload "integer body" ty_int body
          | None -> Alcotest.fail "body expr_type_info is None")
      | None -> Alcotest.fail "function f not found")

let test_infer_identifier_carries_no_widening_payload () =
  with_isolated_env (fun () ->
      let src = {|
func f(x: Int) -> Int:
    x
|} in
      let typed, errors = parse_and_typecheck src in
      check_int "no type errors" 0 (List.length errors);
      let rec find_ident name e =
        match e.expr_desc with
        | EIdent n when n = name -> Some e
        | _ -> List.find_map (find_ident name) (expr_children e)
      in
      match Option.bind (find_func_body typed "f") (find_ident "x") with
      | Some ident -> (
          match ident.expr_type_info with
          | Some _ -> assert_keep_payload "identifier" ty_int ident
          | None -> Alcotest.fail "identifier expr_type_info is None")
      | None -> Alcotest.fail "identifier x not found")

let test_infer_tuple_and_binary_carry_no_widening_payload () =
  with_isolated_env (fun () ->
      let src = {|
func f(x: Int) -> (Int, Int):
    (x + 1, 2)
|} in
      let typed, errors = parse_and_typecheck src in
      check_int "no type errors" 0 (List.length errors);
      let rec find_tuple e =
        match e.expr_desc with
        | ETuple _ -> Some e
        | _ -> List.find_map find_tuple (expr_children e)
      in
      let rec find_binary e =
        match e.expr_desc with
        | EBinary _ -> Some e
        | _ -> List.find_map find_binary (expr_children e)
      in
      match find_func_body typed "f" with
      | Some body -> (
          match (find_tuple body, find_binary body) with
          | Some tuple, Some binary ->
              assert_keep_payload "tuple" (TyTuple [ ty_int; ty_int ]) tuple;
              assert_keep_payload "binary" ty_int binary
          | None, _ -> Alcotest.fail "tuple not found"
          | _, None -> Alcotest.fail "binary expression not found")
      | None -> Alcotest.fail "function f not found")

let test_infer_void_carries_no_widening_payload () =
  with_isolated_env (fun () ->
      let src = {|
func main(args: List[String]):
    void
|} in
      let typed, errors = parse_and_typecheck src in
      check_int "no type errors" 0 (List.length errors);
      let rec find_void e =
        match e.expr_desc with
        | EVoid -> Some e
        | _ -> List.find_map find_void (expr_children e)
      in
      match Option.bind (find_func_body typed "main") find_void with
      | Some void_expr -> assert_keep_payload "void" ty_void void_expr
      | None -> Alcotest.fail "void expression not found")

let test_infer_statement_control_flow_carries_no_widening_payload () =
  with_isolated_env (fun () ->
      let src =
        {|
func f() -> Int:
    var total: Int = 0
    for i in 0..4:
        total = total + i
        if total > 2:
            break
        else:
            continue
    total
|}
      in
      let typed, errors = parse_and_typecheck src in
      check_int "no type errors" 0 (List.length errors);
      match find_func_body typed "f" with
      | Some body ->
          let require label pred expected_ty =
            match find_first_expr pred body with
            | Some expr -> assert_keep_payload label expected_ty expr
            | None -> Alcotest.failf "%s expression not found" label
          in
          require "range"
            (function { expr_desc = ERange _; _ } -> true | _ -> false)
            (TyNamed ("Range", []));
          require "var decl"
            (function
              | { expr_desc = EVarDecl ("total", _, _, _); _ } -> true
              | _ -> false)
            ty_void;
          require "assignment"
            (function
              | { expr_desc = EAssign ("total", _); _ } -> true | _ -> false)
            ty_void;
          require "break"
            (function { expr_desc = EBreak; _ } -> true | _ -> false)
            ty_void;
          require "continue"
            (function { expr_desc = EContinue; _ } -> true | _ -> false)
            ty_void
      | None -> Alcotest.fail "function f not found")

let test_infer_string_interp_and_question_bind_carry_no_widening_payload () =
  with_isolated_env (fun () ->
      let src =
        {|
import:
    option: Option(Some, None)


func maybe() -> Option[Int]:
    Some(1)


func describe(x: Int) -> String:
    "value ${x}"


func f() -> Option[Int]:
    x ?= maybe()
    Some(x + 1)
|}
      in
      let typed, errors = parse_and_typecheck_module src in
      check_int "no type errors" 0 (List.length errors);
      (match find_func_body typed "describe" with
      | Some body -> (
          match
            find_first_expr
              (function
                | { expr_desc = EStringInterp _; _ } -> true | _ -> false)
              body
          with
          | Some interp ->
              assert_keep_payload "string interpolation" ty_string interp
          | None -> Alcotest.fail "string interpolation not found")
      | None -> Alcotest.fail "function describe not found");
      match find_func_body typed "f" with
      | Some body ->
          let option_int = TyNamed ("Option", [ ty_int ]) in
          assert_keep_payload "question-bind block" option_int body;
          let require label pred expected_ty =
            match find_first_expr pred body with
            | Some expr -> assert_keep_payload label expected_ty expr
            | None -> Alcotest.failf "%s expression not found" label
          in
          require "question bind"
            (function
              | { expr_desc = EQuestionBind ("x", _, _); _ } -> true
              | _ -> false)
            ty_int
      | None -> Alcotest.fail "function f not found")

let test_infer_concurrent_carries_no_widening_payload () =
  with_isolated_env (fun () ->
      let src =
        {|
import:
    result: Result(Ok, Err)

dummy_result: Result[Int, String] = Ok(0)

func compute() -> Int:
    42


func main(args: List[String]) -> Int:
    concurrent:
        answer = compute()
    0
|}
      in
      let typed, errors = parse_and_typecheck_module src in
      check_int "no type errors" 0 (List.length errors);
      match find_func_body typed "main" with
      | Some body ->
          let result_int =
            TyNamed ("Result", [ ty_int; TyNamed ("ConcurrencyError", []) ])
          in
          let require label pred expected_ty =
            match find_first_expr pred body with
            | Some expr -> assert_keep_payload label expected_ty expr
            | None -> Alcotest.failf "%s expression not found" label
          in
          require "concurrent"
            (function { expr_desc = EConcurrent _; _ } -> true | _ -> false)
            ty_void;
          require "concurrent bind"
            (function
              | { expr_desc = EConcurrentBind ("answer", _, _); _ } -> true
              | _ -> false)
            result_int
      | None -> Alcotest.fail "function main not found")

let test_infer_collection_literals_carry_no_widening_payload () =
  with_isolated_env (fun () ->
      let src =
        {|
record Point {x: Int, y: Int}


func main(args: List[String]) -> Int:
    xs: List[Int] = [1, 2]
    empty: List[Int] = []
    values: Int[#2] = {1, 2}
    p: Point = {x = 1, y = 2}
    0
|}
      in
      let typed, errors = parse_and_typecheck src in
      check_int "no type errors" 0 (List.length errors);
      match find_func_body typed "main" with
      | Some body ->
          let require label pred expected_ty =
            match find_first_expr pred body with
            | Some expr -> assert_keep_payload label expected_ty expr
            | None -> Alcotest.failf "%s expression not found" label
          in
          require "list literal"
            (function { expr_desc = EList _; _ } -> true | _ -> false)
            (ty_list ty_int);
          require "tensor literal"
            (function { expr_desc = EVector _; _ } -> true | _ -> false)
            (ty_array ty_int [ TyConstInt 2 ]);
          require "record literal"
            (function
              | { expr_desc = ERecord [ ("x", _); ("y", _) ]; _ } -> true
              | _ -> false)
            (TyNamed ("Point", []))
      | None -> Alcotest.fail "function main not found")

let test_infer_access_and_branch_nodes_carry_no_widening_payload () =
  with_isolated_env (fun () ->
      let src =
        {|
record Point {x: Int, y: Int}


func choose(flag: Bool, p: Point) -> Int:
    q: Point = { p | x = 3 }
    if flag:
        q.x
    else:
        match flag:
            True: q.y
            False: 0
|}
      in
      let typed, errors = parse_and_typecheck src in
      check_int "no type errors" 0 (List.length errors);
      match find_func_body typed "choose" with
      | Some body ->
          let require label pred expected_ty =
            match find_first_expr pred body with
            | Some expr -> assert_keep_payload label expected_ty expr
            | None -> Alcotest.failf "%s expression not found" label
          in
          require "record update"
            (function { expr_desc = ERecordUpdate _; _ } -> true | _ -> false)
            (TyNamed ("Point", []));
          require "field access"
            (function
              | { expr_desc = EFieldAccess (_, "x"); _ } -> true | _ -> false)
            ty_int;
          require "if expression"
            (function { expr_desc = EIf _; _ } -> true | _ -> false)
            ty_int;
          require "match expression"
            (function { expr_desc = EMatch _; _ } -> true | _ -> false)
            ty_int
      | None -> Alcotest.fail "function choose not found")

let test_ambiguous_bare_record_field_reports_modules () =
  with_isolated_env (fun () ->
      let field name field_type =
        { field_name = name; field_type; field_loc = dummy_loc }
      in
      let record_decl name fields =
        {
          decl_desc =
            DRecord
              {
                record_name = name;
                record_type_params = [];
                record_fields = fields;
                record_is_value = false;
                record_is_builtin = false;
              };
          decl_loc = dummy_loc;
          decl_doc = None;
        }
      in
      let loaded_module name decls : Blorp.Session.loaded_module =
        {
          name;
          path = "<test>";
          origin = Blorp.Session.User_module;
          decls;
          exports = [];
          surface = None;
          typed_decls = None;
          typed_import_bindings = None;
        }
      in
      let sess = Blorp.Session.current () in
      Blorp.Session.register_module_types sess
        (loaded_module "./a" [ record_decl "Config" [ field "a" ty_int ] ]);
      Blorp.Session.register_module_types sess
        (loaded_module "./b" [ record_decl "Config" [ field "b" ty_int ] ]);
      let env =
        Blorp.Env.add_var (Blorp.Env.empty ()) "config"
          (TyNamed ("Config", []))
          ()
      in
      let expr desc =
        {
          expr_desc = desc;
          expr_loc = dummy_loc;
          expr_type = None;
          expr_type_info = None;
          expr_rc = None;
        }
      in
      let access = expr (EFieldAccess (expr (EIdent "config"), "a")) in
      let ctx = Blorp.Infer.make_ctx env in
      match Blorp.Infer.infer_expr ctx access with
      | Ok _ ->
          Alcotest.fail
            "ambiguous bare record field access should not pick a loaded module"
      | Error err ->
          check_true "reports ambiguous record type"
            (Test_helpers.contains_substring err.message
               "Ambiguous record type 'Config'");
          check_true "names first module"
            (Test_helpers.contains_substring err.message "./a");
          check_true "names second module"
            (Test_helpers.contains_substring err.message "./b"))

let test_infer_bitwise_call_carries_no_widening_payload () =
  with_isolated_env (fun () ->
      let src = {|
func f() -> Int:
    bit_and(1, 3)
|} in
      let typed, errors = parse_and_typecheck src in
      check_int "no type errors" 0 (List.length errors);
      require_call_payload typed "f" "bit_and" ty_int
        ~expected_callee_ty:(ty_func [ ty_int; ty_int ] ty_int ~pure:true);
      ignore
        (require_direct_resolved_call ~expected_origin:CallableBuiltin typed "f"
           "bit_and"))

let test_infer_reflection_calls_carry_no_widening_payload () =
  with_isolated_env (fun () ->
      let src =
        {|
import:
    debug: is_heap, type_name


func inspect[T](x: T):
    debug:
        type_name(x)
        is_heap(x)
    void
|}
      in
      let typed, errors = parse_and_typecheck_module src in
      check_int "no type errors" 0 (List.length errors);
      require_call_payload typed "inspect" "type_name" ty_string;
      ignore (require_direct_resolved_call typed "inspect" "type_name");
      require_call_payload typed "inspect" "is_heap" ty_bool;
      ignore (require_direct_resolved_call typed "inspect" "is_heap"))

let test_infer_checked_tensor_calls_carry_no_widening_payload () =
  with_isolated_env (fun () ->
      let src =
        {|
func checked_nodes(vdyn: Int[#Ds...]) -> Bool:
    v: Int[#5] = {10, 20, 30, 40, 50}
    m: Int[#2, #3] = {
        {1, 2, 3},
        {4, 5, 6},
    }
    a: Int = checked_get(v, 0)
    b: Int[#5] = checked_set(v, 0, 99)
    c: Int[#2] = checked_slice(v, 1, 3)
    d: Int = matrix_checked_get(m, 0, 1)
    match assert_shape(vdyn, 5):
        Some(validated):
            checked_get(validated, 0) == a + d
        None:
            False
|}
      in
      let typed, errors = parse_and_typecheck_module src in
      check_int "no type errors" 0 (List.length errors);
      require_call_payload typed "checked_nodes" "checked_get" ty_int;
      ignore (require_direct_resolved_call typed "checked_nodes" "checked_get");
      require_call_payload typed "checked_nodes" "checked_set"
        (ty_array ty_int [ TyConstInt 5 ]);
      ignore (require_direct_resolved_call typed "checked_nodes" "checked_set");
      require_call_payload typed "checked_nodes" "checked_slice"
        (ty_array ty_int [ TyConstInt 2 ]);
      ignore
        (require_direct_resolved_call typed "checked_nodes" "checked_slice");
      require_call_payload typed "checked_nodes" "matrix_checked_get" ty_int;
      ignore
        (require_direct_resolved_call typed "checked_nodes" "matrix_checked_get");
      require_call_payload typed "checked_nodes" "assert_shape"
        (TyNamed ("Option", [ ty_array ty_int [ TyConstInt 5 ] ]));
      ignore (require_direct_resolved_call typed "checked_nodes" "assert_shape"))

let test_infer_tensor_producer_calls_carry_no_widening_payload () =
  with_isolated_env (fun () ->
      let src =
        {|
func tensor_producers(v: Float[#4]) -> Bool:
    n: #4 = length(v)
    made: Float[#4] = vector(0.0, length(v))
    grid: Int[#2, #3] = matrix(0, 2, 3)
    cube: Int[#2, #3, #4] = tensor3(1, 2, 3, 4)
    True
|}
      in
      let typed, errors = parse_and_typecheck_module src in
      check_int "no type errors" 0 (List.length errors);
      require_call_payload typed "tensor_producers" "length" (TyConstInt 4);
      ignore (require_direct_resolved_call typed "tensor_producers" "length");
      require_call_payload typed "tensor_producers" "vector"
        (ty_array ty_float [ TyConstInt 4 ]);
      ignore (require_direct_resolved_call typed "tensor_producers" "vector");
      require_call_payload typed "tensor_producers" "matrix"
        (ty_array ty_int [ TyConstInt 2; TyConstInt 3 ]);
      ignore (require_direct_resolved_call typed "tensor_producers" "matrix");
      require_call_payload typed "tensor_producers" "tensor3"
        (ty_array ty_int [ TyConstInt 2; TyConstInt 3; TyConstInt 4 ]);
      ignore (require_direct_resolved_call typed "tensor_producers" "tensor3"))

let test_infer_generic_call_concrete () =
  (* func id[T](x: T) -> T: x ; id(42) must type to Int (no lingering TyVar). *)
  with_isolated_env (fun () ->
      let src =
        {|
func id[T](x: T) -> T:
    x

func main(args: List[String]):
    y = id(42)
    void
|}
      in
      let typed, errors = parse_and_typecheck src in
      check_int "no type errors" 0 (List.length errors);
      match find_func_body typed "main" with
      | Some body -> (
          (* Find the ECall to "id" inside main's body and check its expr_type. *)
          let rec find_id_call (e : expr) : expr option =
            match e.expr_desc with
            | ECall ({ expr_desc = EIdent "id"; _ }, _) -> Some e
            | _ -> List.find_map find_id_call (expr_children e)
          in
          match find_id_call body with
          | Some call -> (
              match call.expr_type with
              | Some ty ->
                  check_true
                    (Printf.sprintf "id(42) : Int (got %s)" (type_to_string ty))
                    (types_equal ty ty_int);
                  let vars = collect_type_vars ty in
                  check_int "no residual type vars" 0 (List.length vars)
              | None -> Alcotest.fail "call expr_type is None")
          | None -> Alcotest.fail "id(42) call not found")
      | None -> Alcotest.fail "function main not found")

let test_infer_generic_pair_constrains () =
  (* func mkpair[A](x: A) -> (A, A): (x, x) ; p = mkpair(7).
     p's type must be (Int, Int). *)
  with_isolated_env (fun () ->
      let src =
        {|
func mkpair[A](x: A) -> (A, A):
    (x, x)

func main(args: List[String]):
    p = mkpair(7)
    void
|}
      in
      let typed, errors = parse_and_typecheck src in
      check_int "no type errors" 0 (List.length errors);
      let expected = TyTuple [ ty_int; ty_int ] in
      match find_func_body typed "main" with
      | Some body -> (
          let rec find_p (e : expr) : expr option =
            match e.expr_desc with
            | EVarDecl ("p", _, init, _) -> Some init
            | _ -> List.find_map find_p (expr_children e)
          in
          match find_p body with
          | Some init -> (
              match init.expr_type with
              | Some ty ->
                  check_true
                    (Printf.sprintf "mkpair(7) : (Int, Int) (got %s)"
                       (type_to_string ty))
                    (types_equal ty expected)
              | None -> Alcotest.fail "p init expr_type is None")
          | None -> Alcotest.fail "p binding not found")
      | None -> Alcotest.fail "function main not found")

let test_infer_all_exprs_typed () =
  (* Every reachable expr_desc in a typechecked function body must have
     [expr_type = Some _]. A single [None] indicates infer.ml dropped an
     annotation along the way — exactly the kind of bug the zonking pass
     will guard against. *)
  with_isolated_env (fun () ->
      let src =
        {|
func inc(x: Int) -> Int:
    x + 1

func main(args: List[String]):
    y = inc(41)
    void
|}
      in
      let typed, errors = parse_and_typecheck src in
      check_int "no type errors" 0 (List.length errors);
      match find_func_body typed "main" with
      | Some body ->
          let untyped = collect_untyped body in
          if untyped <> [] then
            Alcotest.failf
              "expected every expr_desc to be typed, found %d untyped node(s)"
              (List.length untyped)
      | None -> Alcotest.fail "function main not found")

let test_zonk_does_not_synthesize_missing_type_info () =
  let expr =
    {
      expr_desc = ELiteral (LitInt 1L);
      expr_loc = dummy_loc;
      expr_type = Some (TyConstInt 1);
      expr_type_info = None;
      expr_rc = None;
    }
  in
  let zonked = Blorp.Infer.zonk_expr expr in
  match zonked.expr_type_info with
  | None -> ()
  | Some _ -> Alcotest.fail "zonk_expr must not repair missing expr_type_info"

let test_infer_tensor_enumerate2_for_loop_rewrites_to_loop_view () =
  with_isolated_env (fun () ->
      let src =
        {|
import:
    tensor: enumerate2


func sum_matrix(m: Int[#2, #3]) -> Int:
    var total: Int = 0
    for (i, j, value) in enumerate2(m):
        total = total + value
    total
|}
      in
      let typed, errors = parse_and_typecheck_module src in
      check_int "no type errors" 0 (List.length errors);
      let rec find_for_iter (e : expr) : expr option =
        match e.expr_desc with
        | EForTuple (_, iter, _) -> Some iter
        | _ -> List.find_map find_for_iter (expr_children e)
      in
      let iter_opt =
        match find_func_body typed "sum_matrix" with
        | Some body -> find_for_iter body
        | None -> None
      in
      match iter_opt with
      | Some { expr_desc = ELoopView view; expr_type = Some iter_ty; _ } ->
          Alcotest.(check bool)
            "loop view kind" true
            (match view.loop_view_kind with
            | LoopEnumerate2 -> true
            | _ -> false);
          check_true "loop view elem type"
            (types_equal view.loop_view_elem_type
               (TyTuple
                  [ TyRange (TyConstInt 2); TyRange (TyConstInt 3); ty_int ]));
          check_true "loop iterator has internal Loop type"
            (types_equal iter_ty
               (TyNamed ("Loop", [ view.loop_view_elem_type ])))
      | Some other ->
          Alcotest.failf "expected ELoopView iterator, got different node: %s"
            (match other.expr_desc with
            | ECall (callee, _) ->
                Printf.sprintf "ECall callee=%s callee_ty=%s iter_ty=%s"
                  (match callee.expr_desc with
                  | EIdent name -> "EIdent " ^ name
                  | EFieldAccess (_, name) -> "EFieldAccess ." ^ name
                  | _ -> "other")
                  (match callee.expr_type with
                  | Some ty -> type_to_string ty
                  | None -> "<none>")
                  (match other.expr_type with
                  | Some ty -> type_to_string ty
                  | None -> "<none>")
            | EIdent name -> "EIdent " ^ name
            | _ -> "other")
      | None -> Alcotest.fail "for-loop iterator not found")

let test_resource_type_registers_explicit_kind () =
  with_isolated_env (fun () ->
      let _typed, errors, env =
        parse_and_typecheck_std_with_env
          {|
resource type TestResource = builtin
|}
      in
      check_int "no errors" 0 (List.length errors);
      check_true "resource kind"
        (Blorp.Env.get_type_kind env "TestResource"
        = Some Blorp.Env.TypeResource))

let test_resource_rejects_record_field_declaration () =
  with_isolated_env (fun () ->
      let _typed, errors, _env =
        parse_and_typecheck_std_with_env
          {|
resource type TestResource = builtin

record Holder {handle: TestResource}
|}
      in
      check_true "resource record field declaration error"
        (List.exists
           (fun (err : compiler_error) ->
             Blorp.Modules.contains err.message
               "Record 'Holder' field 'handle' cannot contain a resource type")
           errors))

let test_resource_rejects_union_payload_declaration () =
  with_isolated_env (fun () ->
      let _typed, errors, _env =
        parse_and_typecheck_std_with_env
          {|
resource type TestResource = builtin

union HandleBox:
	Box(TestResource)
	Empty
|}
      in
      check_true "resource union payload declaration error"
        (List.exists
           (fun (err : compiler_error) ->
             Blorp.Modules.contains err.message
               "Union variant 'Box' cannot contain a resource type")
           errors))

let test_with_resource_typechecks_body_and_binding () =
  with_isolated_env (fun () ->
      let typed, errors, _env =
        parse_and_typecheck_std_with_env
          {|
resource type TestResource = builtin

func open_resource() -> TestResource:
	builtin

func main(args: List[String]) -> Int:
	with handle = open_resource():
		0
|}
      in
      if errors <> [] then
        Alcotest.failf "expected no errors, got:\n%s" (format_errors errors);
      match find_func_body typed "main" with
      | Some
          {
            expr_desc =
              EBlock
                [
                  {
                    expr_desc =
                      EWith
                        ( {
                            with_name = "handle";
                            with_type = Some binding_ty;
                            _;
                          },
                          body );
                    _;
                  };
                ];
            _;
          } ->
          check_true "binding type is resource"
            (types_equal binding_ty (TyNamed ("TestResource", [])));
          check_true "body type is Int"
            (match body.expr_type with
            | Some ty -> types_equal ty ty_int
            | None -> false)
      | Some other ->
          Alcotest.failf "expected main body with EWith, got %s"
            (match other.expr_desc with
            | EBlock _ -> "other block"
            | _ -> "other")
      | None -> Alcotest.fail "expected main function")

let test_with_resource_rejects_direct_resource_escape () =
  with_isolated_env (fun () ->
      let _typed, errors, _env =
        parse_and_typecheck_std_with_env
          {|
resource type TestResource = builtin

func open_resource() -> TestResource:
	builtin

func main(args: List[String]) -> TestResource:
	with handle = open_resource():
		handle
|}
      in
      check_true "resource escape error"
        (List.exists
           (fun (err : compiler_error) ->
             Blorp.Modules.contains err.message
               "scoped resource values cannot escape a with block")
           errors))

let test_with_resource_rejects_direct_resource_escape_after_statement () =
  with_isolated_env (fun () ->
      let _typed, errors, _env =
        parse_and_typecheck_std_with_env
          {|
resource type TestResource = builtin

func open_resource() -> TestResource:
	builtin

func leak_handle() -> TestResource:
	with handle = open_resource():
		marker = 1
		handle

func main(args: List[String]) -> Int:
	0
|}
      in
      check_true "direct resource escape error"
        (List.exists
           (fun (err : compiler_error) ->
             Blorp.Modules.contains err.message
               "scoped resource values cannot escape a with block")
           errors);
      check_false "not reported as derived escape"
        (List.exists
           (fun (err : compiler_error) ->
             Blorp.Modules.contains err.message
               "scoped resource-derived values cannot escape a with block")
           errors))

let test_with_try_resource_typechecks_carrier_body () =
  with_isolated_env (fun () ->
      let typed, errors, _env =
        parse_and_typecheck_std_with_env
          {|
resource type TestResource = builtin

func open_resource() -> Option[TestResource]:
	builtin

func maybe_count() -> Option[Int]:
	with handle ?= open_resource():
		Some(1)

func main(args: List[String]) -> Int:
	0
|}
      in
      if errors <> [] then
        Alcotest.failf "expected no errors, got:\n%s" (format_errors errors);
      match find_func_body typed "maybe_count" with
      | Some
          {
            expr_desc =
              EBlock
                [
                  {
                    expr_desc =
                      EWith
                        ( {
                            with_name = "handle";
                            with_type = Some binding_ty;
                            with_kind = WithTry;
                            _;
                          },
                          body );
                    _;
                  };
                ];
            _;
          } ->
          check_true "binding type is resource"
            (types_equal binding_ty (TyNamed ("TestResource", [])));
          check_true "body type is Option[Int]"
            (match body.expr_type with
            | Some ty -> types_equal ty (TyNamed ("Option", [ ty_int ]))
            | None -> false)
      | Some _ -> Alcotest.fail "expected maybe_count body with fallible EWith"
      | None -> Alcotest.fail "expected maybe_count function")

let test_with_resource_rejects_ordinary_local_copy () =
  with_isolated_env (fun () ->
      let _typed, errors, _env =
        parse_and_typecheck_std_with_env
          {|
resource type TestResource = builtin

func open_resource() -> TestResource:
	builtin

func main(args: List[String]) -> Int:
	with handle = open_resource():
		copy = handle
		0
|}
      in
      check_true "ordinary resource binding error"
        (List.exists
           (fun (err : compiler_error) ->
             Blorp.Modules.contains err.message
               "resource value 'copy' cannot be bound to an ordinary variable")
           errors))

let test_with_resource_rejects_tuple_destructure_copy () =
  with_isolated_env (fun () ->
      let _typed, errors, _env =
        parse_and_typecheck_std_with_env
          {|
resource type TestResource = builtin

func open_pair() -> (TestResource, Int):
	builtin

func main(args: List[String]) -> Int:
	(copy, n) = open_pair()
	0
|}
      in
      check_true "tuple resource binding error"
        (List.exists
           (fun (err : compiler_error) ->
             Blorp.Modules.contains err.message
               "resource value cannot be bound to an ordinary variable")
           errors))

let test_with_resource_rejects_tuple_literal_storage () =
  with_isolated_env (fun () ->
      let _typed, errors, _env =
        parse_and_typecheck_std_with_env
          {|
resource type TestResource = builtin

func open_resource() -> TestResource:
	builtin

func main(args: List[String]) -> Int:
	with handle = open_resource():
		(handle, 1)
		0
|}
      in
      check_true "tuple literal resource storage error"
        (List.exists
           (fun (err : compiler_error) ->
             Blorp.Modules.contains err.message
               "resource values cannot be stored in tuple literals")
           errors))

let test_with_resource_rejects_derived_tuple_literal_storage () =
  with_isolated_env (fun () ->
      let _typed, errors, _env =
        parse_and_typecheck_std_with_env
          {|
resource type TestResource = builtin

record Cursor {id: Int}

func open_resource() -> TestResource:
	builtin

func cursor_from(handle: TestResource) -> Cursor:
	builtin

func main(args: List[String]) -> Int:
	with handle = open_resource():
		cursor = cursor_from(handle)
		(cursor, 1)
		0
|}
      in
      check_true "tuple literal derived storage error"
        (List.exists
           (fun (err : compiler_error) ->
             Blorp.Modules.contains err.message
               "scoped resource-derived values cannot be stored in tuple \
                literals")
           errors))

let test_with_resource_rejects_closure_capture () =
  with_isolated_env (fun () ->
      let _typed, errors, _env =
        parse_and_typecheck_std_with_env
          {|
resource type TestResource = builtin

func open_resource() -> TestResource:
	builtin

func apply(f: () -> Int) -> Int:
	builtin

func main(args: List[String]) -> Int:
	with handle = open_resource():
		apply(func() -> Int:
			handle
			1
		)
|}
      in
      check_true "closure scoped resource capture error"
        (List.exists
           (fun (err : compiler_error) ->
             Blorp.Modules.contains err.message
               "Closure cannot capture scoped resource")
           errors))

let test_with_resource_rejects_detach_capture () =
  with_isolated_env (fun () ->
      let _typed, errors, _env =
        parse_and_typecheck_std_with_env
          {|
resource type TestResource = builtin

func open_resource() -> TestResource:
	builtin

func main(args: List[String]) -> Int:
	with handle = open_resource():
		detach handle
		0
|}
      in
      check_true "detach scoped resource capture error"
        (List.exists
           (fun (err : compiler_error) ->
             Blorp.Modules.contains err.message
               "detach cannot capture scoped resource")
           errors))

let test_with_resource_rejects_ordinary_call_arg_copy () =
  with_isolated_env (fun () ->
      let _typed, errors, _env =
        parse_and_typecheck_std_with_env
          {|
resource type TestResource = builtin

func open_resource() -> TestResource:
	builtin

func consume(handle: TestResource) -> Int:
	1

func main(args: List[String]) -> Int:
	with handle = open_resource():
		consume(handle)
|}
      in
      check_true "ordinary call resource arg error"
        (List.exists
           (fun (err : compiler_error) ->
             Blorp.Modules.contains err.message
               "scoped resource value cannot be passed to ordinary call \
                'consume'")
           errors))

let test_with_resource_rejects_derived_ordinary_call_arg_copy () =
  with_isolated_env (fun () ->
      let _typed, errors, _env =
        parse_and_typecheck_std_with_env
          {|
resource type TestResource = builtin

record Cursor {id: Int}

func open_resource() -> TestResource:
	builtin

func cursor_from(handle: TestResource) -> Cursor:
	builtin

func consume(cursor: Cursor) -> Int:
	1

func main(args: List[String]) -> Int:
	with handle = open_resource():
		cursor = cursor_from(handle)
		consume(cursor)
		0
|}
      in
      check_true "derived ordinary call arg error"
        (List.exists
           (fun (err : compiler_error) ->
             Blorp.Modules.contains err.message
               "scoped resource-derived value cannot be passed to ordinary \
                call 'consume'")
           errors))

let test_with_resource_rejects_inline_derived_ordinary_call_arg_copy () =
  with_isolated_env (fun () ->
      let _typed, errors, _env =
        parse_and_typecheck_std_with_env
          {|
resource type TestResource = builtin

record Cursor {id: Int}

func open_resource() -> TestResource:
	builtin

func cursor_from(handle: TestResource) -> Cursor:
	builtin

func consume(cursor: Cursor) -> Int:
	1

func main(args: List[String]) -> Int:
	with handle = open_resource():
		consume(cursor_from(handle))
		0
|}
      in
      check_true "inline derived ordinary call arg error"
        (List.exists
           (fun (err : compiler_error) ->
             Blorp.Modules.contains err.message
               "scoped resource-derived value cannot be passed to ordinary \
                call 'consume'")
           errors))

let test_resource_ordinary_result_can_escape_with_block () =
  with_isolated_env (fun () ->
      let _typed, errors, _env =
        parse_and_typecheck_std_with_env
          {|
resource type TestResource = builtin

func open_resource() -> TestResource:
	builtin

@resource_result_ordinary
func read_count(handle: TestResource) -> Int:
	builtin

func read_count_scoped() -> Option[Int]:
	with handle = open_resource():
		count = read_count(handle)
		Some(count)

func main(args: List[String]) -> Int:
	0
|}
      in
      if errors <> [] then
        Alcotest.failf "expected no errors, got:\n%s" (format_errors errors))

let test_resource_ordinary_inline_result_can_enter_ordinary_call () =
  with_isolated_env (fun () ->
      let _typed, errors, _env =
        parse_and_typecheck_std_with_env
          {|
resource type TestResource = builtin

func open_resource() -> TestResource:
	builtin

@resource_result_ordinary
func read_count(handle: TestResource) -> Int:
	builtin

func read_count_scoped() -> Option[Int]:
	with handle = open_resource():
		Some(read_count(handle))

func main(args: List[String]) -> Int:
	0
|}
      in
      if errors <> [] then
        Alcotest.failf "expected no errors, got:\n%s" (format_errors errors))

let test_resource_ordinary_ufcs_result_can_enter_ordinary_call () =
  with_isolated_env (fun () ->
      let _typed, errors, _env =
        parse_and_typecheck_std_with_env
          {|
resource type TestResource = builtin

func open_resource() -> TestResource:
	builtin

@resource_result_ordinary
func read_count(handle: TestResource) -> Int:
	builtin

func read_count_scoped() -> Option[Int]:
	with handle = open_resource():
		Some(handle.read_count())

func main(args: List[String]) -> Int:
	0
|}
      in
      if errors <> [] then
        Alcotest.failf "expected no errors, got:\n%s" (format_errors errors))

let test_resource_dependent_result_still_cannot_escape_with_block () =
  with_isolated_env (fun () ->
      let _typed, errors, _env =
        parse_and_typecheck_std_with_env
          {|
resource type TestResource = builtin

record Cursor {id: Int}

func open_resource() -> TestResource:
	builtin

func cursor_from(handle: TestResource) -> Cursor:
	builtin

func leak_cursor() -> Cursor:
	with handle = open_resource():
		cursor = cursor_from(handle)
		cursor

func main(args: List[String]) -> Int:
	0
|}
      in
      check_true "dependent result still rejected"
        (List.exists
           (fun (err : compiler_error) ->
             Blorp.Modules.contains err.message
               "scoped resource-derived values cannot escape a with block")
           errors))

let test_resource_dependent_single_expr_result_cannot_escape_with_block () =
  with_isolated_env (fun () ->
      let _typed, errors, _env =
        parse_and_typecheck_std_with_env
          {|
resource type TestResource = builtin

record Cursor {id: Int}

func open_resource() -> TestResource:
	builtin

func cursor_from(handle: TestResource) -> Cursor:
	builtin

func leak_cursor() -> Cursor:
	with handle = open_resource():
		cursor_from(handle)

func main(args: List[String]) -> Int:
	0
|}
      in
      check_true "dependent single-expression result rejected"
        (List.exists
           (fun (err : compiler_error) ->
             Blorp.Modules.contains err.message
               "scoped resource-derived values cannot escape a with block")
           errors))

let test_resource_result_ordinary_requires_builtin_body () =
  with_isolated_env (fun () ->
      let _typed, errors, _env =
        parse_and_typecheck_std_with_env
          {|
@resource_result_ordinary
func ordinary_source(value: Int) -> Int:
	value

func main(args: List[String]) -> Int:
	0
|}
      in
      check_true "ordinary result annotation rejected on source function"
        (List.exists
           (fun (err : compiler_error) ->
             Blorp.Modules.contains err.message
               "@resource_result_ordinary can only be used on builtin resource \
                operation declarations")
           errors))

let test_resource_result_ordinary_requires_resource_parameter () =
  with_isolated_env (fun () ->
      let _typed, errors, _env =
        parse_and_typecheck_std_with_env
          {|
@resource_result_ordinary
func ordinary_builtin(value: Int) -> Int:
	builtin

func main(args: List[String]) -> Int:
	0
|}
      in
      check_true "ordinary result annotation requires resource parameter"
        (List.exists
           (fun (err : compiler_error) ->
             Blorp.Modules.contains err.message
               "@resource_result_ordinary requires a builtin operation with a \
                direct resource parameter")
           errors))

let test_resource_result_ordinary_allows_forward_resource_parameter () =
  with_isolated_env (fun () ->
      let _typed, errors, _env =
        parse_and_typecheck_std_with_env
          {|
@resource_result_ordinary
func read_count(handle: TestResource) -> Int:
	builtin

resource type TestResource = builtin

func open_resource() -> TestResource:
	builtin

func main(args: List[String]) -> Int:
	0
|}
      in
      if errors <> [] then
        Alcotest.failf "expected no errors, got:\n%s" (format_errors errors))

let test_resource_result_ordinary_rejects_resource_container_parameter () =
  with_isolated_env (fun () ->
      let _typed, errors, _env =
        parse_and_typecheck_std_with_env
          {|
resource type TestResource = builtin

@resource_result_ordinary
func read_count(handle: Option[TestResource]) -> Int:
	builtin

func main(args: List[String]) -> Int:
	0
|}
      in
      check_true "ordinary result annotation requires direct resource parameter"
        (List.exists
           (fun (err : compiler_error) ->
             Blorp.Modules.contains err.message
               "@resource_result_ordinary requires a builtin operation with a \
                direct resource parameter")
           errors))

let test_resource_result_ordinary_rejects_resource_return () =
  with_isolated_env (fun () ->
      let _typed, errors, _env =
        parse_and_typecheck_std_with_env
          {|
resource type TestResource = builtin

@resource_result_ordinary
func bad(handle: TestResource) -> TestResource:
	builtin

func main(args: List[String]) -> Int:
	0
|}
      in
      check_true "ordinary result annotation rejects resource return"
        (List.exists
           (fun (err : compiler_error) ->
             Blorp.Modules.contains err.message
               "@resource_result_ordinary cannot be used on a builtin that \
                returns a resource-dependent value")
           errors))

let test_resource_result_ordinary_rejects_stream_carrier_return () =
  with_isolated_env (fun () ->
      let _typed, errors, _env =
        parse_and_typecheck_std_with_env
          {|
resource type TestResource = builtin
type FallibleStream[T, E] = builtin

@resource_result_ordinary
func bad(handle: TestResource) -> Result[FallibleStream[Int, Int], Int]:
	builtin

func main(args: List[String]) -> Int:
	0
|}
      in
      check_true "ordinary result annotation rejects stream carrier return"
        (List.exists
           (fun (err : compiler_error) ->
             Blorp.Modules.contains err.message
               "@resource_result_ordinary cannot be used on a builtin that \
                returns a resource-dependent value")
           errors))

let test_resource_result_ordinary_rejects_aliased_stream_carrier_return () =
  with_isolated_env (fun () ->
      let _typed, errors, _env =
        parse_and_typecheck_std_with_env
          {|
resource type TestResource = builtin
type FallibleStream[T, E] = builtin
type alias BadStream = FallibleStream[Int, Int]

@resource_result_ordinary
func bad(handle: TestResource) -> Result[BadStream, Int]:
	builtin

func main(args: List[String]) -> Int:
	0
|}
      in
      check_true "ordinary result annotation rejects aliased stream carrier"
        (List.exists
           (fun (err : compiler_error) ->
             Blorp.Modules.contains err.message
               "@resource_result_ordinary cannot be used on a builtin that \
                returns a resource-dependent value")
           errors))

let test_resource_rejects_unscoped_resource_operation_arg () =
  with_isolated_env (fun () ->
      let _typed, errors, _env =
        parse_and_typecheck_std_with_env
          {|
resource type TestResource = builtin

record Cursor {id: Int}

func open_resource() -> TestResource:
	builtin

func cursor_from(handle: TestResource) -> Cursor:
	builtin

func main(args: List[String]) -> Int:
	cursor = cursor_from(open_resource())
	0
|}
      in
      check_true "unscoped resource operation arg error"
        (List.exists
           (fun (err : compiler_error) ->
             Blorp.Modules.contains err.message
               "resource argument to compiler-owned resource operation must be \
                a scoped with binding")
           errors))

let test_with_resource_rejects_constructor_payload_copy () =
  with_isolated_env (fun () ->
      let _typed, errors, _env =
        parse_and_typecheck_std_with_env
          {|
resource type TestResource = builtin

func open_resource() -> TestResource:
	builtin

func main(args: List[String]) -> Int:
	with handle = open_resource():
		Some(handle)
		0
|}
      in
      check_true "constructor resource payload error"
        (List.exists
           (fun (err : compiler_error) ->
             Blorp.Modules.contains err.message
               "scoped resource value cannot be passed to ordinary call 'Some'")
           errors))

let test_with_resource_rejects_derived_constructor_payload_copy () =
  with_isolated_env (fun () ->
      let _typed, errors, _env =
        parse_and_typecheck_std_with_env
          {|
resource type TestResource = builtin

record Cursor {id: Int}

func open_resource() -> TestResource:
	builtin

func cursor_from(handle: TestResource) -> Cursor:
	builtin

func main(args: List[String]) -> Int:
	with handle = open_resource():
		cursor = cursor_from(handle)
		Some(cursor)
		0
|}
      in
      check_true "derived constructor payload error"
        (List.exists
           (fun (err : compiler_error) ->
             Blorp.Modules.contains err.message
               "scoped resource-derived value cannot be passed to ordinary \
                call 'Some'")
           errors))

let test_with_resource_rejects_derived_local_escape () =
  with_isolated_env (fun () ->
      let _typed, errors, _env =
        parse_and_typecheck_std_with_env
          {|
resource type TestResource = builtin

record Cursor {id: Int}

func open_resource() -> TestResource:
	builtin

func cursor_from(handle: TestResource) -> Cursor:
	builtin

func leak_cursor() -> Cursor:
	with handle = open_resource():
		cursor = cursor_from(handle)
		cursor

func main(args: List[String]) -> Int:
	0
|}
      in
      check_true "derived local escape error"
        (List.exists
           (fun (err : compiler_error) ->
             Blorp.Modules.contains err.message
               "scoped resource-derived values cannot escape a with block")
           errors))

let test_with_resource_rejects_derived_mutable_assignment () =
  with_isolated_env (fun () ->
      let _typed, errors, _env =
        parse_and_typecheck_std_with_env
          {|
resource type TestResource = builtin

record Cursor {id: Int}

func open_resource() -> TestResource:
	builtin

func cursor_from(handle: TestResource) -> Cursor:
	builtin

func leak_cursor() -> Cursor:
	var cursor: Cursor = {id = 0}
	with handle = open_resource():
		cursor = cursor_from(handle)
		0
	cursor

func main(args: List[String]) -> Int:
	0
|}
      in
      check_true "derived mutable assignment error"
        (List.exists
           (fun (err : compiler_error) ->
             Blorp.Modules.contains err.message
               "scoped resource-derived value cannot be assigned to mutable \
                variable")
           errors))

let test_with_resource_rejects_derived_detach_capture () =
  with_isolated_env (fun () ->
      let _typed, errors, _env =
        parse_and_typecheck_std_with_env
          {|
resource type TestResource = builtin

record Cursor {id: Int}

func open_resource() -> TestResource:
	builtin

func cursor_from(handle: TestResource) -> Cursor:
	builtin

func main(args: List[String]) -> Int:
	with handle = open_resource():
		cursor = cursor_from(handle)
		detach cursor
		0
|}
      in
      check_true "derived detach capture error"
        (List.exists
           (fun (err : compiler_error) ->
             Blorp.Modules.contains err.message
               "detach cannot capture scoped resource-derived value")
           errors))

let test_with_resource_rejects_concurrent_capture () =
  with_isolated_env (fun () ->
      let _typed, errors, _env =
        parse_and_typecheck_std_with_env
          {|
resource type TestResource = builtin

func open_resource() -> TestResource:
	builtin

func main(args: List[String]) -> Int:
	with handle = open_resource():
		concurrent:
			value = handle
		0
|}
      in
      check_true "concurrent scoped resource capture error"
        (List.exists
           (fun (err : compiler_error) ->
             Blorp.Modules.contains err.message
               "concurrent task cannot capture scoped resource")
           errors))

let test_with_resource_rejects_derived_concurrent_capture () =
  with_isolated_env (fun () ->
      let _typed, errors, _env =
        parse_and_typecheck_std_with_env
          {|
resource type TestResource = builtin

record Cursor {id: Int}

func open_resource() -> TestResource:
	builtin

func cursor_from(handle: TestResource) -> Cursor:
	builtin

func main(args: List[String]) -> Int:
	with handle = open_resource():
		cursor = cursor_from(handle)
		concurrent:
			value = cursor
		0
|}
      in
      check_true "concurrent scoped resource-derived capture error"
        (List.exists
           (fun (err : compiler_error) ->
             Blorp.Modules.contains err.message
               "concurrent task cannot capture scoped resource-derived value")
           errors))

let test_with_resource_rejects_concurrently_loop_capture () =
  with_isolated_env (fun () ->
      let _typed, errors, _env =
        parse_and_typecheck_std_with_env
          {|
resource type TestResource = builtin

func open_resource() -> TestResource:
	builtin

func touch_resource(handle: TestResource) -> Void:
	builtin

func main(args: List[String]) -> Int:
	nums = [1, 2]
	with handle = open_resource():
		for n in nums concurrently(limit: 2):
			touch_resource(handle)
		0
|}
      in
      check_true "for ... concurrently scoped resource capture error"
        (List.exists
           (fun (err : compiler_error) ->
             Blorp.Modules.contains err.message
               "concurrent task cannot capture scoped resource")
           errors))

let test_resource_rejects_concurrent_resource_result () =
  with_isolated_env (fun () ->
      let _typed, errors, _env =
        parse_and_typecheck_std_with_env
          {|
resource type TestResource = builtin

func open_resource() -> TestResource:
	builtin

func main(args: List[String]) -> Int:
	concurrent:
		value = open_resource()
	0
|}
      in
      check_true "concurrent resource result error"
        (List.exists
           (fun (err : compiler_error) ->
             Blorp.Modules.contains err.message
               "concurrent task result cannot contain resource values")
           errors))

let test_with_resource_rejects_derived_closure_capture () =
  with_isolated_env (fun () ->
      let _typed, errors, _env =
        parse_and_typecheck_std_with_env
          {|
resource type TestResource = builtin

record Cursor {id: Int}

func open_resource() -> TestResource:
	builtin

func cursor_from(handle: TestResource) -> Cursor:
	builtin

func apply(f: () -> Int) -> Int:
	1

func main(args: List[String]) -> Int:
	with handle = open_resource():
		cursor = cursor_from(handle)
		apply(func() -> Int:
			cursor.id
		)
		0
|}
      in
      check_true "derived closure capture error"
        (List.exists
           (fun (err : compiler_error) ->
             Blorp.Modules.contains err.message
               "Closure cannot capture scoped resource-derived value")
           errors))

let test_with_resource_rejects_list_literal_storage () =
  with_isolated_env (fun () ->
      let _typed, errors, _env =
        parse_and_typecheck_std_with_env
          {|
resource type TestResource = builtin

func open_resource() -> TestResource:
	builtin

func main(args: List[String]) -> Int:
	with handle = open_resource():
		[handle]
		0
|}
      in
      check_true "list literal resource storage error"
        (List.exists
           (fun (err : compiler_error) ->
             Blorp.Modules.contains err.message
               "resource values cannot be stored in list literals")
           errors))

let test_with_resource_rejects_derived_list_literal_storage () =
  with_isolated_env (fun () ->
      let _typed, errors, _env =
        parse_and_typecheck_std_with_env
          {|
resource type TestResource = builtin

record Cursor {id: Int}

func open_resource() -> TestResource:
	builtin

func cursor_from(handle: TestResource) -> Cursor:
	builtin

func main(args: List[String]) -> Int:
	with handle = open_resource():
		cursor = cursor_from(handle)
		[cursor]
		0
|}
      in
      check_true "list literal derived storage error"
        (List.exists
           (fun (err : compiler_error) ->
             Blorp.Modules.contains err.message
               "scoped resource-derived values cannot be stored in list \
                literals")
           errors))

let test_with_resource_rejects_record_literal_storage () =
  with_isolated_env (fun () ->
      let _typed, errors, _env =
        parse_and_typecheck_std_with_env
          {|
resource type TestResource = builtin

record Holder {handle: TestResource}

func open_resource() -> TestResource:
	builtin

func main(args: List[String]) -> Int:
	with handle = open_resource():
		{handle = handle}
		0
|}
      in
      check_true "record literal resource storage error"
        (List.exists
           (fun (err : compiler_error) ->
             Blorp.Modules.contains err.message
               "resource values cannot be stored in record fields")
           errors))

let test_with_resource_rejects_derived_record_literal_storage () =
  with_isolated_env (fun () ->
      let _typed, errors, _env =
        parse_and_typecheck_std_with_env
          {|
resource type TestResource = builtin

record Cursor {id: Int}
record Holder {cursor: Cursor}

func open_resource() -> TestResource:
	builtin

func cursor_from(handle: TestResource) -> Cursor:
	builtin

func main(args: List[String]) -> Int:
	with handle = open_resource():
		cursor = cursor_from(handle)
		holder: Holder = {cursor = cursor}
		0
|}
      in
      check_true "record literal derived storage error"
        (List.exists
           (fun (err : compiler_error) ->
             Blorp.Modules.contains err.message
               "scoped resource-derived values cannot be stored in record \
                fields")
           errors))

let test_with_resource_rejects_derived_record_update_storage () =
  with_isolated_env (fun () ->
      let _typed, errors, _env =
        parse_and_typecheck_std_with_env
          {|
resource type TestResource = builtin

record Cursor {id: Int}
record Holder {cursor: Cursor}

func open_resource() -> TestResource:
	builtin

func cursor_from(handle: TestResource) -> Cursor:
	builtin

func main(args: List[String]) -> Int:
	base: Holder = {cursor = {id = 0}}
	with handle = open_resource():
		cursor = cursor_from(handle)
		{base | cursor = cursor}
		0
|}
      in
      check_true "record update derived storage error"
        (List.exists
           (fun (err : compiler_error) ->
             Blorp.Modules.contains err.message
               "scoped resource-derived values cannot be stored in record \
                fields")
           errors))

let test_with_resource_rejects_derived_record_update_base_storage () =
  with_isolated_env (fun () ->
      let _typed, errors, _env =
        parse_and_typecheck_std_with_env
          {|
resource type TestResource = builtin

record Cursor {id: Int}

func open_resource() -> TestResource:
	builtin

func cursor_from(handle: TestResource) -> Cursor:
	builtin

func main(args: List[String]) -> Int:
	with handle = open_resource():
		cursor = cursor_from(handle)
		{cursor | id = 1}
		0
|}
      in
      check_true "record update derived base storage error"
        (List.exists
           (fun (err : compiler_error) ->
             Blorp.Modules.contains err.message
               "scoped resource-derived values cannot be stored in record \
                updates")
           errors))

let test_resource_rejects_global_binding () =
  with_isolated_env (fun () ->
      let _typed, errors, _env =
        parse_and_typecheck_std_with_env
          {|
resource type TestResource = builtin

func open_resource() -> TestResource:
	builtin

global_handle = open_resource()

func main(args: List[String]) -> Int:
	0
|}
      in
      check_true "global resource binding error"
        (List.exists
           (fun (err : compiler_error) ->
             Blorp.Modules.contains err.message
               "resource value 'global_handle' cannot be bound to a global")
           errors))

let test_resource_rejects_record_containing_resource_local_binding () =
  with_isolated_env (fun () ->
      let _typed, errors, _env =
        parse_and_typecheck_std_with_env
          {|
resource type TestResource = builtin

record Holder {handle: TestResource}

func open_holder() -> Holder:
	builtin

func main(args: List[String]) -> Int:
	holder = open_holder()
	0
|}
      in
      check_true "resource-containing record binding error"
        (List.exists
           (fun (err : compiler_error) ->
             Blorp.Modules.contains err.message
               "resource value 'holder' cannot be bound to an ordinary variable")
           errors))

let test_resource_rejects_union_containing_resource_local_binding () =
  with_isolated_env (fun () ->
      let _typed, errors, _env =
        parse_and_typecheck_std_with_env
          {|
resource type TestResource = builtin

union HandleBox:
	Box(TestResource)
	Empty

func open_box() -> HandleBox:
	builtin

func main(args: List[String]) -> Int:
	box = open_box()
	0
|}
      in
      check_true "resource-containing union binding error"
        (List.exists
           (fun (err : compiler_error) ->
             Blorp.Modules.contains err.message
               "resource value 'box' cannot be bound to an ordinary variable")
           errors))

let test_resource_rejects_discarded_resource_value () =
  with_isolated_env (fun () ->
      let _typed, errors, _env =
        parse_and_typecheck_std_with_env
          {|
resource type TestResource = builtin

func open_resource() -> TestResource:
	builtin

func main(args: List[String]) -> Int:
	open_resource()
	0
|}
      in
      check_true "discarded resource value error"
        (List.exists
           (fun (err : compiler_error) ->
             Blorp.Modules.contains err.message
               "resource-containing value cannot be discarded")
           errors))

let test_resource_rejects_explicitly_discarded_fallible_resource_value () =
  with_isolated_env (fun () ->
      let _typed, errors, _env =
        parse_and_typecheck_std_with_env
          {|
resource type TestResource = builtin

func maybe_open_resource() -> Option[TestResource]:
	builtin

func main(args: List[String]) -> Int:
	_ = maybe_open_resource()
	0
|}
      in
      check_true "explicitly discarded fallible resource value error"
        (List.exists
           (fun (err : compiler_error) ->
             Blorp.Modules.contains err.message
               "resource-containing value cannot be discarded")
           errors))

(* ============================================================================
   Test suite
   ============================================================================ *)

let suite =
  [
    ( "build_subst shapes",
      [
        Alcotest.test_case "TyVar -> concrete" `Quick
          test_subst_tyvar_to_concrete;
        Alcotest.test_case "no-op (concrete = concrete)" `Quick
          test_subst_non_matching;
        Alcotest.test_case "named with args" `Quick test_subst_named_with_args;
        Alcotest.test_case "nested" `Quick test_subst_nested;
        Alcotest.test_case "two params in tuple" `Quick
          test_subst_two_params_tuple;
        Alcotest.test_case "function type" `Quick test_subst_func;
        Alcotest.test_case "range binds inner" `Quick
          test_subst_range_binds_inner;
        Alcotest.test_case "TyNamed as type param" `Quick
          test_subst_tynamed_as_param;
        Alcotest.test_case "TyVar binds unconditionally" `Quick
          test_subst_tyvar_always_binds;
      ] );
    ( "infer_expr end-to-end",
      [
        Alcotest.test_case "integer literal body" `Quick
          test_infer_integer_literal;
        Alcotest.test_case "direct local call records target" `Quick
          test_call_metadata_for_direct_local_call;
        Alcotest.test_case "local method syntax records target" `Quick
          test_call_metadata_for_local_method_syntax;
        Alcotest.test_case "closure call records target" `Quick
          test_call_metadata_for_closure_call;
        Alcotest.test_case "constructor call records target" `Quick
          test_call_metadata_for_constructor_call;
        Alcotest.test_case "trait dispatch records target" `Quick
          test_call_metadata_for_trait_dispatch;
        Alcotest.test_case "module-qualified function records target" `Quick
          test_call_metadata_for_module_qualified_function;
        Alcotest.test_case "annotated module-qualified function records target"
          `Quick test_call_metadata_for_annotated_module_qualified_function;
        Alcotest.test_case "imported function method records target" `Quick
          test_call_metadata_for_imported_function_method_syntax;
        Alcotest.test_case "prelude method-only UFCS records target" `Quick
          test_call_metadata_for_prelude_method_only_ufcs;
        Alcotest.test_case "imported type method-only UFCS records target"
          `Quick test_call_metadata_for_imported_type_method_only_ufcs;
        Alcotest.test_case "module-qualified impl method records target" `Quick
          test_call_metadata_for_module_qualified_impl_method;
        Alcotest.test_case "integer literal carries no-widening payload" `Quick
          test_infer_integer_literal_carries_no_widening_payload;
        Alcotest.test_case "identifier carries no-widening payload" `Quick
          test_infer_identifier_carries_no_widening_payload;
        Alcotest.test_case "tuple and binary carry no-widening payload" `Quick
          test_infer_tuple_and_binary_carry_no_widening_payload;
        Alcotest.test_case "void carries no-widening payload" `Quick
          test_infer_void_carries_no_widening_payload;
        Alcotest.test_case "statement control-flow carries no-widening payload"
          `Quick test_infer_statement_control_flow_carries_no_widening_payload;
        Alcotest.test_case
          "string interp and question-bind carry no-widening payload" `Quick
          test_infer_string_interp_and_question_bind_carry_no_widening_payload;
        Alcotest.test_case "concurrent carries no-widening payload" `Quick
          test_infer_concurrent_carries_no_widening_payload;
        Alcotest.test_case "collection literals carry no-widening payload"
          `Quick test_infer_collection_literals_carry_no_widening_payload;
        Alcotest.test_case "access and branch nodes carry no-widening payload"
          `Quick test_infer_access_and_branch_nodes_carry_no_widening_payload;
        Alcotest.test_case "ambiguous bare record field reports modules" `Quick
          test_ambiguous_bare_record_field_reports_modules;
        Alcotest.test_case "bitwise call carries no-widening payload" `Quick
          test_infer_bitwise_call_carries_no_widening_payload;
        Alcotest.test_case "reflection calls carry no-widening payload" `Quick
          test_infer_reflection_calls_carry_no_widening_payload;
        Alcotest.test_case "checked tensor calls carry no-widening payload"
          `Quick test_infer_checked_tensor_calls_carry_no_widening_payload;
        Alcotest.test_case "tensor producer calls carry no-widening payload"
          `Quick test_infer_tensor_producer_calls_carry_no_widening_payload;
        Alcotest.test_case "generic call resolves to concrete" `Quick
          test_infer_generic_call_concrete;
        Alcotest.test_case "generic pair constrains both slots" `Quick
          test_infer_generic_pair_constrains;
        Alcotest.test_case "every expr is typed" `Quick
          test_infer_all_exprs_typed;
        Alcotest.test_case "zonk does not synthesize missing type info" `Quick
          test_zonk_does_not_synthesize_missing_type_info;
        Alcotest.test_case "tensor enumerate2 loop view" `Quick
          test_infer_tensor_enumerate2_for_loop_rewrites_to_loop_view;
        Alcotest.test_case "resource type registers explicit kind" `Quick
          test_resource_type_registers_explicit_kind;
        Alcotest.test_case "resource rejects record field declaration" `Quick
          test_resource_rejects_record_field_declaration;
        Alcotest.test_case "resource rejects union payload declaration" `Quick
          test_resource_rejects_union_payload_declaration;
        Alcotest.test_case "resource with typechecks binding" `Quick
          test_with_resource_typechecks_body_and_binding;
        Alcotest.test_case "resource with rejects direct escape" `Quick
          test_with_resource_rejects_direct_resource_escape;
        Alcotest.test_case "resource with rejects direct escape after statement"
          `Quick
          test_with_resource_rejects_direct_resource_escape_after_statement;
        Alcotest.test_case "resource with try typechecks carrier" `Quick
          test_with_try_resource_typechecks_carrier_body;
        Alcotest.test_case "resource with rejects ordinary local copy" `Quick
          test_with_resource_rejects_ordinary_local_copy;
        Alcotest.test_case "resource with rejects tuple destructure copy" `Quick
          test_with_resource_rejects_tuple_destructure_copy;
        Alcotest.test_case "resource with rejects tuple literal storage" `Quick
          test_with_resource_rejects_tuple_literal_storage;
        Alcotest.test_case "resource with rejects derived tuple literal storage"
          `Quick test_with_resource_rejects_derived_tuple_literal_storage;
        Alcotest.test_case "resource with rejects closure capture" `Quick
          test_with_resource_rejects_closure_capture;
        Alcotest.test_case "resource with rejects detach capture" `Quick
          test_with_resource_rejects_detach_capture;
        Alcotest.test_case "resource with rejects ordinary call arg" `Quick
          test_with_resource_rejects_ordinary_call_arg_copy;
        Alcotest.test_case "resource with rejects derived ordinary call arg"
          `Quick test_with_resource_rejects_derived_ordinary_call_arg_copy;
        Alcotest.test_case
          "resource with rejects inline derived ordinary call arg" `Quick
          test_with_resource_rejects_inline_derived_ordinary_call_arg_copy;
        Alcotest.test_case "resource ordinary result can escape block" `Quick
          test_resource_ordinary_result_can_escape_with_block;
        Alcotest.test_case "resource ordinary inline result enters call" `Quick
          test_resource_ordinary_inline_result_can_enter_ordinary_call;
        Alcotest.test_case "resource ordinary UFCS result enters call" `Quick
          test_resource_ordinary_ufcs_result_can_enter_ordinary_call;
        Alcotest.test_case "resource dependent result still cannot escape"
          `Quick test_resource_dependent_result_still_cannot_escape_with_block;
        Alcotest.test_case "resource single expr dependent result cannot escape"
          `Quick
          test_resource_dependent_single_expr_result_cannot_escape_with_block;
        Alcotest.test_case "resource ordinary result annotation boundary" `Quick
          test_resource_result_ordinary_requires_builtin_body;
        Alcotest.test_case
          "resource ordinary result annotation requires resource param" `Quick
          test_resource_result_ordinary_requires_resource_parameter;
        Alcotest.test_case
          "resource ordinary result annotation allows forward resource param"
          `Quick test_resource_result_ordinary_allows_forward_resource_parameter;
        Alcotest.test_case
          "resource ordinary result annotation rejects resource container param"
          `Quick
          test_resource_result_ordinary_rejects_resource_container_parameter;
        Alcotest.test_case
          "resource ordinary result annotation rejects resource return" `Quick
          test_resource_result_ordinary_rejects_resource_return;
        Alcotest.test_case
          "resource ordinary result annotation rejects stream carrier return"
          `Quick test_resource_result_ordinary_rejects_stream_carrier_return;
        Alcotest.test_case
          "resource ordinary result annotation rejects aliased stream carrier"
          `Quick
          test_resource_result_ordinary_rejects_aliased_stream_carrier_return;
        Alcotest.test_case "resource rejects unscoped operation arg" `Quick
          test_resource_rejects_unscoped_resource_operation_arg;
        Alcotest.test_case "resource with rejects constructor payload" `Quick
          test_with_resource_rejects_constructor_payload_copy;
        Alcotest.test_case "resource with rejects derived constructor payload"
          `Quick test_with_resource_rejects_derived_constructor_payload_copy;
        Alcotest.test_case "resource with rejects derived escape" `Quick
          test_with_resource_rejects_derived_local_escape;
        Alcotest.test_case "resource with rejects derived mutable assignment"
          `Quick test_with_resource_rejects_derived_mutable_assignment;
        Alcotest.test_case "resource with rejects derived detach capture" `Quick
          test_with_resource_rejects_derived_detach_capture;
        Alcotest.test_case "resource with rejects concurrent capture" `Quick
          test_with_resource_rejects_concurrent_capture;
        Alcotest.test_case "resource with rejects derived concurrent capture"
          `Quick test_with_resource_rejects_derived_concurrent_capture;
        Alcotest.test_case "resource with rejects for ... concurrently capture"
          `Quick test_with_resource_rejects_concurrently_loop_capture;
        Alcotest.test_case "resource rejects concurrent resource result" `Quick
          test_resource_rejects_concurrent_resource_result;
        Alcotest.test_case "resource with rejects derived closure capture"
          `Quick test_with_resource_rejects_derived_closure_capture;
        Alcotest.test_case "resource with rejects list literal storage" `Quick
          test_with_resource_rejects_list_literal_storage;
        Alcotest.test_case "resource with rejects derived list literal storage"
          `Quick test_with_resource_rejects_derived_list_literal_storage;
        Alcotest.test_case "resource with rejects record literal storage" `Quick
          test_with_resource_rejects_record_literal_storage;
        Alcotest.test_case
          "resource with rejects derived record literal storage" `Quick
          test_with_resource_rejects_derived_record_literal_storage;
        Alcotest.test_case "resource with rejects derived record update storage"
          `Quick test_with_resource_rejects_derived_record_update_storage;
        Alcotest.test_case
          "resource with rejects derived record update base storage" `Quick
          test_with_resource_rejects_derived_record_update_base_storage;
        Alcotest.test_case "resource rejects global binding" `Quick
          test_resource_rejects_global_binding;
        Alcotest.test_case "resource rejects resource-containing record binding"
          `Quick test_resource_rejects_record_containing_resource_local_binding;
        Alcotest.test_case "resource rejects resource-containing union binding"
          `Quick test_resource_rejects_union_containing_resource_local_binding;
        Alcotest.test_case "resource rejects discarded resource value" `Quick
          test_resource_rejects_discarded_resource_value;
        Alcotest.test_case "resource rejects discarded fallible value" `Quick
          test_resource_rejects_explicitly_discarded_fallible_resource_value;
      ] );
  ]
