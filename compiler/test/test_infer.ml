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

   Pattern cribbed from test_core_lower.ml:test_lower_real_source.
   Each test parses a short source string, runs the full type-checker, and
   asserts properties of the typed AST. These tests pin down the observable
   outcome of [Infer.build_subst] at actual call sites.

   Isolation: each test runs inside its own [Session.t] so the
   [impl_index] / [overloads] / [ufcs_methods] tables (which are
   session-owned, aliased into [Env.empty ()]) are fresh per test.
   ============================================================================ *)

(** Run [f] inside a fresh session so env tables are isolated. *)
let with_isolated_env (f : unit -> 'a) : 'a =
  let sess = Blorp.Session.create () in
  Blorp.Session.with_current sess f

let parse_and_typecheck source =
  Blorp.Lexer.reset_state ();
  let lexbuf = Lexing.from_string source in
  let program = Blorp.Parser.program Blorp.Lexer.next_token lexbuf in
  let program = Blorp.Interp_parser.transform_program program in
  Blorp.Typecheck.typecheck program

let parse_and_typecheck_module source =
  match
    Blorp.Pipeline.typecheck_module_only ~filename:"test_input.brp" ~source
  with
  | Ok (state, typed_program) ->
      (typed_program, List.rev state.Blorp.Typecheck.errors)
  | Error errors -> ([], errors)

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

let test_infer_string_interp_and_try_carry_no_widening_payload () =
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
    try:
        x ?= maybe()
        x + 1
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
          let require label pred expected_ty =
            match find_first_expr pred body with
            | Some expr -> assert_keep_payload label expected_ty expr
            | None -> Alcotest.failf "%s expression not found" label
          in
          require "try"
            (function { expr_desc = ETry _; _ } -> true | _ -> false)
            option_int;
          require "try bind"
            (function
              | { expr_desc = ETryBind ("x", _, _); _ } -> true | _ -> false)
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

let test_infer_bitwise_call_carries_no_widening_payload () =
  with_isolated_env (fun () ->
      let src = {|
func f() -> Int:
    bit_and(1, 3)
|} in
      let typed, errors = parse_and_typecheck src in
      check_int "no type errors" 0 (List.length errors);
      require_call_payload typed "f" "bit_and" ty_int
        ~expected_callee_ty:(ty_func [ ty_int; ty_int ] ty_int ~pure:true))

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
      require_call_payload typed "inspect" "is_heap" ty_bool)

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
      require_call_payload typed "checked_nodes" "checked_set"
        (ty_array ty_int [ TyConstInt 5 ]);
      require_call_payload typed "checked_nodes" "checked_slice"
        (ty_array ty_int [ TyConstInt 2 ]);
      require_call_payload typed "checked_nodes" "matrix_checked_get" ty_int;
      require_call_payload typed "checked_nodes" "assert_shape"
        (TyNamed ("Option", [ ty_array ty_int [ TyConstInt 5 ] ])))

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
      require_call_payload typed "tensor_producers" "vector"
        (ty_array ty_float [ TyConstInt 4 ]);
      require_call_payload typed "tensor_producers" "matrix"
        (ty_array ty_int [ TyConstInt 2; TyConstInt 3 ]);
      require_call_payload typed "tensor_producers" "tensor3"
        (ty_array ty_int [ TyConstInt 2; TyConstInt 3; TyConstInt 4 ]))

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
        Alcotest.test_case "string interp and try carry no-widening payload"
          `Quick test_infer_string_interp_and_try_carry_no_widening_payload;
        Alcotest.test_case "concurrent carries no-widening payload" `Quick
          test_infer_concurrent_carries_no_widening_payload;
        Alcotest.test_case "collection literals carry no-widening payload"
          `Quick test_infer_collection_literals_carry_no_widening_payload;
        Alcotest.test_case "access and branch nodes carry no-widening payload"
          `Quick test_infer_access_and_branch_nodes_carry_no_widening_payload;
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
      ] );
  ]
