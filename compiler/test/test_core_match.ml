(** Tests for Core_match: [CMatchArms] → decision-tree [CMatch]
    compilation.

    Covers the Phase 1 supported subset (catch-all, literal switch,
    single-layer constructor switch) plus verification that the
    unsupported cases fall through to [None] and leave the original
    [CMatchArms] in place. *)

open Blorp.Ast
open Blorp.Core

let loc =
  { line = 1; column = 1; end_line = 1; end_column = 1; loc_file = None }

let ty_int = TyNamed ("Int", [])
let ty_bool = TyNamed ("Bool", [])
let ty_void = TyNamed ("Void", [])
let ty_opt_int = TyNamed ("Option", [ ty_int ])
let mk d t = { desc = d; ty = t; loc }
let cint n = mk (CLit (LitInt (Int64.of_int n))) ty_int
let cvar n t = mk (CVar (Var.named n)) t

(** Build a [CMatchArms] expression for tests. *)
let mk_match scrut arms result_ty = mk (CMatchArms (scrut, arms)) result_ty

(** Extract the compiled ctree from a compiled match, or fail. *)
let get_ctree core_expr =
  match core_expr.desc with
  | CMatch (_, tree) -> tree
  | CMatchArms _ ->
      Alcotest.fail
        "expected decision-tree CMatch, got CMatchArms (compile returned None)"
  | _ -> Alcotest.fail "expected a match expression"

(** Confirm that compilation left the match unchanged (fallback). *)
let assert_not_compiled core_expr =
  match core_expr.desc with
  | CMatchArms _ -> ()
  | CMatch _ ->
      Alcotest.fail "expected CMatchArms (fallback), got decision-tree CMatch"
  | _ -> Alcotest.fail "expected a match expression"

(* ============================================================================
   Catch-all compilation
   ============================================================================ *)

let test_compile_single_wildcard () =
  (* match x: _ -> 42 *)
  let m = mk_match (cvar "x" ty_int) [ (PatWildcard, cint 42) ] ty_int in
  let compiled = Blorp.Core_match.try_compile_match m in
  match get_ctree compiled with
  | CTLeaf { ct_bindings = []; _ } -> ()
  | _ -> Alcotest.fail "expected empty-bindings CTLeaf"

let test_compile_single_var () =
  (* match x: y -> y + 1 *)
  let body = mk (CBin (Add, cvar "y" ty_int, cint 1)) ty_int in
  let m = mk_match (cvar "x" ty_int) [ (PatVar "y", body) ] ty_int in
  let compiled = Blorp.Core_match.try_compile_match m in
  match get_ctree compiled with
  | CTLeaf { ct_bindings = [ (v, AccRoot) ]; _ } ->
      Alcotest.(check string) "binds y" "y" v.vname
  | _ -> Alcotest.fail "expected CTLeaf with [(y, AccRoot)]"

(* ============================================================================
   Literal switch compilation
   ============================================================================ *)

let test_compile_literal_switch () =
  (* match x: 1 -> 100 | 2 -> 200 | _ -> 0 *)
  let arms =
    [
      (PatLiteral (LitInt 1L), cint 100);
      (PatLiteral (LitInt 2L), cint 200);
      (PatWildcard, cint 0);
    ]
  in
  let m = mk_match (cvar "x" ty_int) arms ty_int in
  let compiled = Blorp.Core_match.try_compile_match m in
  match get_ctree compiled with
  | CTSwitchLit { ctl_scrut = AccRoot; ctl_cases; ctl_default } -> (
      Alcotest.(check int) "2 cases" 2 (List.length ctl_cases);
      (* default should be the wildcard -> 0 leaf *)
      match ctl_default with
      | CTLeaf { ct_body = { desc = CLit (LitInt 0L); _ }; _ } -> ()
      | _ -> Alcotest.fail "default not CTLeaf(0)")
  | _ -> Alcotest.fail "expected CTSwitchLit"

let test_compile_literal_no_default () =
  (* match x: 1 -> 100 | 2 -> 200 — no default, falls to CTFail *)
  let arms =
    [ (PatLiteral (LitInt 1L), cint 100); (PatLiteral (LitInt 2L), cint 200) ]
  in
  let m = mk_match (cvar "x" ty_int) arms ty_int in
  let compiled = Blorp.Core_match.try_compile_match m in
  match get_ctree compiled with
  | CTSwitchLit { ctl_default = CTFail; _ } -> ()
  | CTSwitchLit _ -> Alcotest.fail "expected CTFail default"
  | _ -> Alcotest.fail "expected CTSwitchLit"

(* ============================================================================
   Constructor switch compilation
   ============================================================================ *)

let test_compile_option_match () =
  (* match opt: Some(v) -> v | None -> 0 *)
  let arms =
    [
      (PatConstructor ("Some", [ PatVar "v" ]), cvar "v" ty_int);
      (PatConstructor ("None", []), cint 0);
    ]
  in
  let m = mk_match (cvar "opt" ty_opt_int) arms ty_int in
  let compiled = Blorp.Core_match.try_compile_match m in
  match get_ctree compiled with
  | CTSwitchTag { cts_scrut = AccRoot; cts_cases; cts_default } -> (
      Alcotest.(check int) "2 cases" 2 (List.length cts_cases);
      Alcotest.(check bool) "no default" true (cts_default = None);
      (* Check Some case has the right binding *)
      let some_tree = List.assoc "Some" cts_cases in
      (match some_tree with
      | CTLeaf
          { ct_bindings = [ (v, AccVariantField (AccRoot, "Some", 0)) ]; _ } ->
          Alcotest.(check string) "binds v" "v" v.vname
      | _ -> Alcotest.fail "Some leaf wrong");
      (* None case has empty bindings *)
      let none_tree = List.assoc "None" cts_cases in
      match none_tree with
      | CTLeaf { ct_bindings = []; _ } -> ()
      | _ -> Alcotest.fail "None leaf wrong")
  | _ -> Alcotest.fail "expected CTSwitchTag"

let test_compile_constructor_with_wildcard_catchall () =
  (* match r: Ok(v) -> v | _ -> -1 *)
  let neg_one = mk (CUn (Neg, cint 1)) ty_int in
  let arms =
    [
      (PatConstructor ("Ok", [ PatVar "v" ]), cvar "v" ty_int);
      (PatWildcard, neg_one);
    ]
  in
  let m = mk_match (cvar "r" ty_int) arms ty_int in
  let compiled = Blorp.Core_match.try_compile_match m in
  match get_ctree compiled with
  | CTSwitchTag { cts_cases; cts_default = Some (CTLeaf _); _ } ->
      Alcotest.(check int) "1 case" 1 (List.length cts_cases)
  | _ -> Alcotest.fail "expected CTSwitchTag with default"

let test_compile_qualified_constructor () =
  (* match r: O.Some(v) -> v | O.None -> 0 *)
  let arms =
    [
      (PatQualified ("O", "Some", [ PatVar "v" ]), cvar "v" ty_int);
      (PatQualified ("O", "None", []), cint 0);
    ]
  in
  let m = mk_match (cvar "opt" ty_opt_int) arms ty_int in
  let compiled = Blorp.Core_match.try_compile_match m in
  match get_ctree compiled with
  | CTSwitchTag { cts_cases; _ } ->
      Alcotest.(check int) "2 cases" 2 (List.length cts_cases);
      Alcotest.(check bool) "has Some" true (List.mem_assoc "Some" cts_cases);
      Alcotest.(check bool) "has None" true (List.mem_assoc "None" cts_cases)
  | _ -> Alcotest.fail "expected CTSwitchTag"

(* ============================================================================
   Literal-inside-constructor
   ============================================================================ *)

let test_compile_ctor_with_char_literal () =
  (* match opt: Some('\n') -> true | Some(_) -> false | None -> false
     Should produce CTSwitchTag { Some -> CTSwitchLit { '\n' -> true,
       default -> false }, None -> false } *)
  let ty_opt_char = TyNamed ("Option", [ TyNamed ("Char", []) ]) in
  let arms =
    [
      ( PatConstructor ("Some", [ PatLiteral (LitChar 10) ]),
        mk (CLit (LitBool true)) ty_bool );
      ( PatConstructor ("Some", [ PatWildcard ]),
        mk (CLit (LitBool false)) ty_bool );
      (PatConstructor ("None", []), mk (CLit (LitBool false)) ty_bool);
    ]
  in
  let m = mk_match (cvar "opt" ty_opt_char) arms ty_bool in
  let compiled = Blorp.Core_match.try_compile_match m in
  match get_ctree compiled with
  | CTSwitchTag { cts_scrut = AccRoot; cts_cases; _ } -> (
      (* Some case should contain a nested literal switch *)
      let some_tree = List.assoc "Some" cts_cases in
      match some_tree with
      | CTSwitchLit
          {
            ctl_scrut = AccVariantField (AccRoot, "Some", 0);
            ctl_cases;
            ctl_default;
          } -> (
          Alcotest.(check int) "1 literal case" 1 (List.length ctl_cases);
          (* default is the Some(_) -> false arm *)
          match ctl_default with
          | CTLeaf { ct_bindings = []; _ } -> ()
          | _ -> Alcotest.fail "default not empty-binding CTLeaf")
      | _ -> Alcotest.fail "Some case not CTSwitchLit")
  | _ -> Alcotest.fail "expected CTSwitchTag"

let test_compile_ctor_with_int_literal () =
  (* match r: Ok(0) -> "zero" | Ok(1) -> "one" | Ok(_) -> "other" | Err(e) -> e
     Should produce CTSwitchTag { Ok -> CTSwitchLit { 0, 1, default },
       Err -> CTLeaf(e) } *)
  let ty_str = TyNamed ("String", []) in
  let ty_result = TyNamed ("Result", [ ty_int; ty_str ]) in
  let arms =
    [
      ( PatConstructor ("Ok", [ PatLiteral (LitInt 0L) ]),
        mk
          (CLit (LitString ("zero", { sf_triple = false; sf_raw = false })))
          ty_str );
      ( PatConstructor ("Ok", [ PatLiteral (LitInt 1L) ]),
        mk
          (CLit (LitString ("one", { sf_triple = false; sf_raw = false })))
          ty_str );
      ( PatConstructor ("Ok", [ PatWildcard ]),
        mk
          (CLit (LitString ("other", { sf_triple = false; sf_raw = false })))
          ty_str );
      (PatConstructor ("Err", [ PatVar "e" ]), cvar "e" ty_str);
    ]
  in
  let m = mk_match (cvar "r" ty_result) arms ty_str in
  let compiled = Blorp.Core_match.try_compile_match m in
  match get_ctree compiled with
  | CTSwitchTag { cts_cases; _ } -> (
      Alcotest.(check int) "2 ctors" 2 (List.length cts_cases);
      let ok_tree = List.assoc "Ok" cts_cases in
      match ok_tree with
      | CTSwitchLit { ctl_cases; _ } ->
          Alcotest.(check int) "2 literal cases" 2 (List.length ctl_cases)
      | _ -> Alcotest.fail "Ok case not CTSwitchLit")
  | _ -> Alcotest.fail "expected CTSwitchTag"

let test_compile_ctor_mixed_lit_and_var () =
  (* match opt: Some(42) -> "found" | Some(x) -> to_string(x) | None -> "none"
     The Some arms mix a literal and a variable — should still compile *)
  let ty_str = TyNamed ("String", []) in
  let arms =
    [
      ( PatConstructor ("Some", [ PatLiteral (LitInt 42L) ]),
        mk
          (CLit (LitString ("found", { sf_triple = false; sf_raw = false })))
          ty_str );
      (PatConstructor ("Some", [ PatVar "x" ]), cvar "x" ty_str);
      ( PatConstructor ("None", []),
        mk
          (CLit (LitString ("none", { sf_triple = false; sf_raw = false })))
          ty_str );
    ]
  in
  let m = mk_match (cvar "opt" ty_opt_int) arms ty_str in
  let compiled = Blorp.Core_match.try_compile_match m in
  match get_ctree compiled with
  | CTSwitchTag { cts_cases; _ } -> (
      let some_tree = List.assoc "Some" cts_cases in
      match some_tree with
      | CTSwitchLit { ctl_cases; ctl_default; _ } -> (
          Alcotest.(check int) "1 literal case" 1 (List.length ctl_cases);
          (* default is the Some(x) arm with a binding *)
          match ctl_default with
          | CTLeaf
              { ct_bindings = [ (v, AccVariantField (AccRoot, "Some", 0)) ]; _ }
            ->
              Alcotest.(check string) "binds x" "x" v.vname
          | _ -> Alcotest.fail "default not CTLeaf with x binding")
      | _ -> Alcotest.fail "Some case not CTSwitchLit")
  | _ -> Alcotest.fail "expected CTSwitchTag"

(* ============================================================================
   Fallback: unsupported patterns leave CMatchArms unchanged
   ============================================================================ *)

let test_compile_tuple_simple () =
  (* match p: (a, b) -> a + b — simple binding *)
  let body = mk (CBin (Add, cvar "a" ty_int, cvar "b" ty_int)) ty_int in
  let tup_ty = TyTuple [ ty_int; ty_int ] in
  let arms = [ (PatTuple [ PatVar "a"; PatVar "b" ], body) ] in
  let m = mk_match (cvar "p" tup_ty) arms ty_int in
  let compiled = Blorp.Core_match.try_compile_match m in
  match get_ctree compiled with
  | CTLeaf { ct_bindings; _ } -> (
      Alcotest.(check int) "2 bindings" 2 (List.length ct_bindings);
      let va, aa = List.nth ct_bindings 0 in
      let vb, ab = List.nth ct_bindings 1 in
      Alcotest.(check string) "a" "a" va.vname;
      Alcotest.(check string) "b" "b" vb.vname;
      (match aa with
      | AccTupleField (AccRoot, 0) -> ()
      | _ -> Alcotest.fail "a not AccTupleField(0)");
      match ab with
      | AccTupleField (AccRoot, 1) -> ()
      | _ -> Alcotest.fail "b not AccTupleField(1)")
  | _ -> Alcotest.fail "expected CTLeaf"

let test_compile_tuple_with_literals () =
  (* match p: (0, 0) -> "origin" | (0, _) -> "y" | _ -> "other" *)
  let ty_str = TyNamed ("String", []) in
  let sf = { sf_triple = false; sf_raw = false } in
  let tup_ty = TyTuple [ ty_int; ty_int ] in
  let arms =
    [
      ( PatTuple [ PatLiteral (LitInt 0L); PatLiteral (LitInt 0L) ],
        mk (CLit (LitString ("origin", sf))) ty_str );
      ( PatTuple [ PatLiteral (LitInt 0L); PatWildcard ],
        mk (CLit (LitString ("y", sf))) ty_str );
      (PatWildcard, mk (CLit (LitString ("other", sf))) ty_str);
    ]
  in
  let m = mk_match (cvar "p" tup_ty) arms ty_str in
  let compiled = Blorp.Core_match.try_compile_match m in
  (* Should compile to some form of decision tree, not CMatchArms *)
  match get_ctree compiled with
  | CTFail -> Alcotest.fail "got CTFail"
  | _ -> ()

let test_compile_tuple_with_ctors () =
  (* match p: (Some(x), None) -> x | (None, Some(y)) -> y | _ -> 0 *)
  let tup_ty = TyTuple [ ty_opt_int; ty_opt_int ] in
  let arms =
    [
      ( PatTuple
          [
            PatConstructor ("Some", [ PatVar "x" ]); PatConstructor ("None", []);
          ],
        cvar "x" ty_int );
      ( PatTuple
          [
            PatConstructor ("None", []); PatConstructor ("Some", [ PatVar "y" ]);
          ],
        cvar "y" ty_int );
      (PatWildcard, cint 0);
    ]
  in
  let m = mk_match (cvar "p" tup_ty) arms ty_int in
  let compiled = Blorp.Core_match.try_compile_match m in
  match get_ctree compiled with CTFail -> Alcotest.fail "got CTFail" | _ -> ()

let test_compile_nested_some_some () =
  (* match o: Some(Some(x)) -> x | Some(None) -> 0 | None -> -1
     Should produce CTSwitchTag { Some -> CTSwitchTag {
       AccVariantField(AccRoot, "Some", 0),
       Some -> CTLeaf{[(x, AccVariantField(AccVariantField(...), "Some", 0))]},
       None -> CTLeaf{0}
     }, None -> CTLeaf{-1} } *)
  let ty_opt_opt = TyNamed ("Option", [ ty_opt_int ]) in
  let arms =
    [
      ( PatConstructor ("Some", [ PatConstructor ("Some", [ PatVar "x" ]) ]),
        cvar "x" ty_int );
      (PatConstructor ("Some", [ PatConstructor ("None", []) ]), cint 0);
      (PatConstructor ("None", []), mk (CUn (Neg, cint 1)) ty_int);
    ]
  in
  let m = mk_match (cvar "o" ty_opt_opt) arms ty_int in
  let compiled = Blorp.Core_match.try_compile_match m in
  match get_ctree compiled with
  | CTSwitchTag { cts_scrut = AccRoot; cts_cases; _ } -> (
      Alcotest.(check int) "2 top-level ctors" 2 (List.length cts_cases);
      let some_tree = List.assoc "Some" cts_cases in
      (* The Some branch should contain a nested CTSwitchTag on field0 *)
      match some_tree with
      | CTSwitchTag
          {
            cts_scrut = AccVariantField (AccRoot, "Some", 0);
            cts_cases = inner_cases;
            _;
          } -> (
          Alcotest.(check int) "2 inner ctors" 2 (List.length inner_cases);
          (* Inner Some should bind x *)
          let inner_some = List.assoc "Some" inner_cases in
          match inner_some with
          | CTLeaf { ct_bindings = [ (v, _) ]; _ } ->
              Alcotest.(check string) "binds x" "x" v.vname
          | _ -> Alcotest.fail "inner Some not CTLeaf with binding")
      | _ -> Alcotest.fail "Some branch not nested CTSwitchTag")
  | _ -> Alcotest.fail "expected CTSwitchTag"

let test_compile_nested_ok_some_none () =
  (* match r: Ok(Some(v)) -> v | Ok(None) -> 0 | Err(e) -> -1
     Tests nested constructors across different union types *)
  let ty_result = TyNamed ("Result", [ ty_opt_int; TyNamed ("String", []) ]) in
  let arms =
    [
      ( PatConstructor ("Ok", [ PatConstructor ("Some", [ PatVar "v" ]) ]),
        cvar "v" ty_int );
      (PatConstructor ("Ok", [ PatConstructor ("None", []) ]), cint 0);
      (PatConstructor ("Err", [ PatVar "e" ]), mk (CUn (Neg, cint 1)) ty_int);
    ]
  in
  let m = mk_match (cvar "r" ty_result) arms ty_int in
  let compiled = Blorp.Core_match.try_compile_match m in
  match get_ctree compiled with
  | CTSwitchTag { cts_cases; _ } -> (
      Alcotest.(check int) "2 top-level ctors" 2 (List.length cts_cases);
      let ok_tree = List.assoc "Ok" cts_cases in
      match ok_tree with
      | CTSwitchTag { cts_scrut = AccVariantField (AccRoot, "Ok", 0); _ } -> ()
      | _ -> Alcotest.fail "Ok branch not nested CTSwitchTag")
  | _ -> Alcotest.fail "expected CTSwitchTag"

(* ============================================================================
   List pattern compilation
   ============================================================================ *)

let ty_list_int = TyNamed ("List", [ ty_int ])

let resource_scope ?(acquire = cint 0) name ty body =
  mk
    (CResourceScope
       {
         rs_var = Var.named name;
         rs_ty = ty;
         rs_acquire = acquire;
         rs_body = body;
         rs_cleanup = mk CVoid ty_void;
       })
    body.ty

let test_compile_list_empty_nonempty () =
  (* match xs: [] -> 0 | [x, ...rest] -> x
     Should produce CTSwitchLen with cases for len=0 and len>=1 *)
  let arms =
    [
      (PatList ([], None), cint 0);
      (PatList ([ PatVar "x" ], Some (PatVar "rest")), cvar "x" ty_int);
    ]
  in
  let m = mk_match (cvar "xs" ty_list_int) arms ty_int in
  let compiled = Blorp.Core_match.try_compile_match m in
  match get_ctree compiled with
  | CTSwitchLen _ -> () (* just verify it compiles *)
  | _ -> Alcotest.fail "expected CTSwitchLen"

let test_compile_list_exact_length () =
  (* match xs: [] -> 0 | [a] -> 1 | [a, b] -> 2 | _ -> 3
     Produces an ordered CTSwitchLen chain so later changes cannot
     accidentally reintroduce length grouping that breaks source order. *)
  let arms =
    [
      (PatList ([], None), cint 0);
      (PatList ([ PatVar "a" ], None), cint 1);
      (PatList ([ PatVar "a"; PatVar "b" ], None), cint 2);
      (PatWildcard, cint 3);
    ]
  in
  let m = mk_match (cvar "xs" ty_list_int) arms ty_int in
  let compiled = Blorp.Core_match.try_compile_match m in
  let rec count_exact_chain = function
    | CTSwitchLen
        {
          ctl_len_cases = [ _ ];
          ctl_len_geq = None;
          ctl_len_default = Some next;
          _;
        } ->
        1 + count_exact_chain next
    | CTLeaf _ -> 0
    | _ -> Alcotest.fail "expected ordered exact-length CTSwitchLen chain"
  in
  Alcotest.(check int)
    "3 ordered exact cases" 3
    (count_exact_chain (get_ctree compiled))

let test_compile_list_spread_before_exact_order () =
  (* match xs: [x, ...rest] -> 1 | [x] -> 2 | _ -> 3
     The first decision must be >=1, not ==1, otherwise the later exact arm
     would incorrectly win for singleton lists. *)
  let arms =
    [
      (PatList ([ PatVar "x" ], Some (PatVar "rest")), cint 1);
      (PatList ([ PatVar "x" ], None), cint 2);
      (PatWildcard, cint 3);
    ]
  in
  let m = mk_match (cvar "xs" ty_list_int) arms ty_int in
  let compiled = Blorp.Core_match.try_compile_match m in
  match get_ctree compiled with
  | CTSwitchLen { ctl_len_cases = []; ctl_len_geq = Some (1, CTLeaf _); _ } ->
      ()
  | _ -> Alcotest.fail "expected first list decision to be >=1 spread arm"

let has_spread_binding bindings =
  List.exists
    (fun (_, acc) -> match acc with AccListSpread _ -> true | _ -> false)
    bindings

let has_elem_binding bindings =
  List.exists
    (fun (_, acc) -> match acc with AccListElem _ -> true | _ -> false)
    bindings

let test_compile_list_unused_spread () =
  (* match xs: [x, ...rest] -> x | [] -> 0
     The unused spread must not be materialized: AccListSpread lowers to
     blorp_list_drop, which allocates a tail list. *)
  let arms =
    [
      (PatList ([ PatVar "x" ], Some (PatVar "rest")), cvar "x" ty_int);
      (PatList ([], None), cint 0);
    ]
  in
  let m = mk_match (cvar "xs" ty_list_int) arms ty_int in
  let compiled = Blorp.Core_match.try_compile_match m in
  match get_ctree compiled with
  | CTSwitchLen { ctl_len_geq; _ } -> (
      (* The >=1 case should bind x but not unused rest. *)
      match ctl_len_geq with
      | Some (n, CTLeaf { ct_bindings; _ }) ->
          Alcotest.(check int) "geq threshold" 1 n;
          Alcotest.(check bool)
            "omits unused spread binding" false
            (has_spread_binding ct_bindings);
          Alcotest.(check bool)
            "has elem binding" true
            (has_elem_binding ct_bindings)
      | _ -> Alcotest.fail "expected geq case with CTLeaf")
  | _ -> Alcotest.fail "expected CTSwitchLen"

let test_compile_list_used_spread () =
  (* match xs: [x, ...rest] -> rest; x | [] -> 0
     A spread used by the arm body must still be bound. *)
  let body = mk (CSeq (cvar "rest" ty_list_int, cvar "x" ty_int)) ty_int in
  let arms =
    [
      (PatList ([ PatVar "x" ], Some (PatVar "rest")), body);
      (PatList ([], None), cint 0);
    ]
  in
  let m = mk_match (cvar "xs" ty_list_int) arms ty_int in
  let compiled = Blorp.Core_match.try_compile_match m in
  match get_ctree compiled with
  | CTSwitchLen { ctl_len_geq; _ } -> (
      match ctl_len_geq with
      | Some (n, CTLeaf { ct_bindings; _ }) ->
          Alcotest.(check int) "geq threshold" 1 n;
          Alcotest.(check bool)
            "has spread binding" true
            (has_spread_binding ct_bindings);
          Alcotest.(check bool)
            "has elem binding" true
            (has_elem_binding ct_bindings)
      | _ -> Alcotest.fail "expected geq case with CTLeaf")
  | _ -> Alcotest.fail "expected CTSwitchLen"

let test_compile_list_spread_shadowed_by_resource_scope_body () =
  (* match xs: [x, ...rest] -> with rest = acquire(): rest | [] -> 0
     The scoped resource binding shadows the spread name in the body, so the
     spread tail is unused and must not be materialized. *)
  let body = resource_scope "rest" ty_int (cvar "rest" ty_int) in
  let arms =
    [
      (PatList ([ PatVar "x" ], Some (PatVar "rest")), body);
      (PatList ([], None), cint 0);
    ]
  in
  let m = mk_match (cvar "xs" ty_list_int) arms ty_int in
  let compiled = Blorp.Core_match.try_compile_match m in
  match get_ctree compiled with
  | CTSwitchLen { ctl_len_geq; _ } -> (
      match ctl_len_geq with
      | Some (n, CTLeaf { ct_bindings; _ }) ->
          Alcotest.(check int) "geq threshold" 1 n;
          Alcotest.(check bool)
            "resource-shadowed spread is not materialized" false
            (has_spread_binding ct_bindings)
      | _ -> Alcotest.fail "expected geq case with CTLeaf")
  | _ -> Alcotest.fail "expected CTSwitchLen"

let test_compile_list_spread_used_by_resource_scope_acquire () =
  (* The acquisition expression is evaluated outside the new resource binding,
     so a spread read there is still a use of the outer pattern binding. *)
  let body =
    resource_scope ~acquire:(cvar "rest" ty_list_int) "rest" ty_list_int
      (cvar "x" ty_int)
  in
  let arms =
    [
      (PatList ([ PatVar "x" ], Some (PatVar "rest")), body);
      (PatList ([], None), cint 0);
    ]
  in
  let m = mk_match (cvar "xs" ty_list_int) arms ty_int in
  let compiled = Blorp.Core_match.try_compile_match m in
  match get_ctree compiled with
  | CTSwitchLen { ctl_len_geq; _ } -> (
      match ctl_len_geq with
      | Some (n, CTLeaf { ct_bindings; _ }) ->
          Alcotest.(check int) "geq threshold" 1 n;
          Alcotest.(check bool)
            "acquire still uses outer spread binding" true
            (has_spread_binding ct_bindings)
      | _ -> Alcotest.fail "expected geq case with CTLeaf")
  | _ -> Alcotest.fail "expected CTSwitchLen"

(* ============================================================================
   Phase 2.5 — fall-through gaps in the classifier.
   These are documented as "still falls through to raw CMatchArms" cases.
   When fixed, classify_arms should accept the shape and compile_arms
   should produce a decision-tree CMatch.
   ============================================================================ *)

let ty_opt_list_int = TyNamed ("Option", [ ty_list_int ])

(** GAP: constructor wrapping a list pattern, with a trailing wildcard
    catchall. Without the catchall this would typecheck-fail as non-
    exhaustive; with the catchall, the classifier used to bail because
    [is_compilable_subpattern (PatList _)] returned false. Phase 2.5
    extends the classifier to recognize PatList at sub-positions. *)
let test_ctor_wrapping_list_with_catchall () =
  (* match opt:
       Some([x, ...rest]) -> x
       Some([]) -> 0
       None -> -1
       _ -> -99 *)
  let arms =
    [
      ( PatConstructor
          ("Some", [ PatList ([ PatVar "x" ], Some (PatVar "rest")) ]),
        cvar "x" ty_int );
      (PatConstructor ("Some", [ PatList ([], None) ]), cint 0);
      (PatConstructor ("None", []), mk (CLit (LitInt (-1L))) ty_int);
      (PatWildcard, mk (CLit (LitInt (-99L))) ty_int);
    ]
  in
  let m = mk_match (cvar "opt" ty_opt_list_int) arms ty_int in
  let compiled = Blorp.Core_match.try_compile_match m in
  match get_ctree compiled with
  | CTSwitchTag _ -> () (* outer should switch on Some/None tag *)
  | _ -> Alcotest.fail "expected CTSwitchTag — Phase 2.5 should compile this"

let test_compile_tuple_ctor_elements () =
  (* match p: (Some(x), None) -> x | (None, Some(y)) -> y | _ -> 0 *)
  let tup_ty = TyTuple [ ty_opt_int; ty_opt_int ] in
  let arms =
    [
      ( PatTuple
          [
            PatConstructor ("Some", [ PatVar "x" ]); PatConstructor ("None", []);
          ],
        cvar "x" ty_int );
      ( PatTuple
          [
            PatConstructor ("None", []); PatConstructor ("Some", [ PatVar "y" ]);
          ],
        cvar "y" ty_int );
      (PatWildcard, cint 0);
    ]
  in
  let m = mk_match (cvar "p" tup_ty) arms ty_int in
  let compiled = Blorp.Core_match.try_compile_match m in
  (* Should compile — not fall through to CMatchArms *)
  match get_ctree compiled with
  | CTFail -> Alcotest.fail "got CTFail"
  | _ -> ()

let test_compile_tuple_lit_elements () =
  (* match p: (0, 0) -> "origin" | (0, _) -> "y" | (_, 0) -> "x" | _ -> "other" *)
  let ty_str = TyNamed ("String", []) in
  let sf = { sf_triple = false; sf_raw = false } in
  let tup_ty = TyTuple [ ty_int; ty_int ] in
  let arms =
    [
      ( PatTuple [ PatLiteral (LitInt 0L); PatLiteral (LitInt 0L) ],
        mk (CLit (LitString ("origin", sf))) ty_str );
      ( PatTuple [ PatLiteral (LitInt 0L); PatWildcard ],
        mk (CLit (LitString ("y", sf))) ty_str );
      ( PatTuple [ PatWildcard; PatLiteral (LitInt 0L) ],
        mk (CLit (LitString ("x", sf))) ty_str );
      (PatWildcard, mk (CLit (LitString ("other", sf))) ty_str);
    ]
  in
  let m = mk_match (cvar "p" tup_ty) arms ty_str in
  let compiled = Blorp.Core_match.try_compile_match m in
  match get_ctree compiled with CTFail -> Alcotest.fail "got CTFail" | _ -> ()

let test_fallback_mixed_patterns () =
  (* match x: 1 -> a | Some(v) -> v — literals mixed with constructors *)
  let arms =
    [
      (PatLiteral (LitInt 1L), cvar "a" ty_int);
      (PatConstructor ("Some", [ PatVar "v" ]), cvar "v" ty_int);
    ]
  in
  let m = mk_match (cvar "x" ty_int) arms ty_int in
  let compiled = Blorp.Core_match.try_compile_match m in
  assert_not_compiled compiled

let test_non_constructor_call_with_constructor_arm_not_fused () =
  (* match parse(0): Parsed(value) -> true | _ -> false

     [parse] is a normal function returning a union, not a constructor. The
     direct-constructor fusion must not treat the callee name as a constructor
     and choose the wildcard arm at compile time. *)
  let ty_outcome = TyNamed ("Outcome", []) in
  let parse_ty =
    TyFunc { params = [ ty_int ]; return = ty_outcome; is_pure = true }
  in
  let scrut =
    mk (CCall (CKUnknown, cvar "parse" parse_ty, [ cint 0 ])) ty_outcome
  in
  let arms =
    [
      ( PatConstructor ("Parsed", [ PatVar "value" ]),
        mk (CLit (LitBool true)) ty_bool );
      (PatWildcard, mk (CLit (LitBool false)) ty_bool);
    ]
  in
  let m = mk_match scrut arms ty_bool in
  let ctors = Hashtbl.create 4 in
  Hashtbl.replace ctors "Parsed" ();
  Hashtbl.replace ctors "Failed" ();
  let compiled = Blorp.Core_match.compile_expr ~ctors m in
  match compiled.desc with
  | CMatch
      ( { desc = CCall (_, { desc = CVar callee; _ }, _); _ },
        CTSwitchTag { cts_cases; cts_default = Some _; _ } ) ->
      Alcotest.(check string) "scrutinee call preserved" "parse" callee.vname;
      Alcotest.(check bool)
        "has Parsed case" true
        (List.mem_assoc "Parsed" cts_cases)
  | CLit (LitBool false) ->
      Alcotest.fail "normal function call was fused to wildcard body"
  | _ -> Alcotest.fail "expected CMatch with preserved parse(...) scrutinee"

let test_fuse_direct_constructor_var_payload () =
  (* match Some(x): Some(v) -> v | None -> 0
     The constructor is known at compile time, so no Option allocation is
     needed; bind the payload directly to the selected arm. *)
  let some_ty =
    TyFunc { params = [ ty_int ]; return = ty_opt_int; is_pure = true }
  in
  let scrut =
    mk (CCall (CKUnknown, cvar "Some" some_ty, [ cvar "x" ty_int ])) ty_opt_int
  in
  let arms =
    [
      (PatConstructor ("Some", [ PatVar "v" ]), cvar "v" ty_int);
      (PatConstructor ("None", []), cint 0);
    ]
  in
  let m = mk_match scrut arms ty_int in
  let compiled = Blorp.Core_match.try_compile_match m in
  match compiled.desc with
  | CLet (b, body) -> (
      Alcotest.(check string) "binds payload" "v" b.bind_var.vname;
      match (b.bind_rhs.desc, body.desc) with
      | CVar x, CVar v ->
          Alcotest.(check string) "rhs" "x" x.vname;
          Alcotest.(check string) "body" "v" v.vname
      | _ -> Alcotest.fail "expected let v = x in v")
  | _ -> Alcotest.fail "expected direct constructor match fusion"

let test_fuse_direct_constructor_wildcard_payload () =
  (* Wildcard payloads still evaluate their argument, but do not allocate the
     wrapping Option. *)
  let next_ty = TyFunc { params = []; return = ty_int; is_pure = false } in
  let some_ty =
    TyFunc { params = [ ty_int ]; return = ty_opt_int; is_pure = true }
  in
  let arg = mk (CCall (CKUnknown, cvar "next" next_ty, [])) ty_int in
  let scrut = mk (CCall (CKUnknown, cvar "Some" some_ty, [ arg ])) ty_opt_int in
  let arms =
    [
      (PatConstructor ("Some", [ PatWildcard ]), cint 1);
      (PatConstructor ("None", []), cint 0);
    ]
  in
  let m = mk_match scrut arms ty_int in
  let compiled = Blorp.Core_match.try_compile_match m in
  match compiled.desc with
  | CSeq (eval_arg, body) -> (
      match (eval_arg.desc, body.desc) with
      | CCall (_, { desc = CVar f; _ }, []), CLit (LitInt 1L) ->
          Alcotest.(check string) "evaluates payload" "next" f.vname
      | _ -> Alcotest.fail "expected payload evaluation before selected body")
  | _ -> Alcotest.fail "expected direct constructor wildcard fusion"

let test_compile_or_pattern_literals () =
  (* match x: 1 | 2 -> 99 | _ -> 0 — expands to 1 -> 99 | 2 -> 99 | _ -> 0 *)
  let arms =
    [
      (PatOr [ PatLiteral (LitInt 1L); PatLiteral (LitInt 2L) ], cint 99);
      (PatWildcard, cint 0);
    ]
  in
  let m = mk_match (cvar "x" ty_int) arms ty_int in
  let compiled = Blorp.Core_match.try_compile_match m in
  match get_ctree compiled with
  | CTSwitchLit { ctl_cases; ctl_default; _ } -> (
      Alcotest.(check int) "2 literal cases" 2 (List.length ctl_cases);
      match ctl_default with
      | CTLeaf { ct_body = { desc = CLit (LitInt 0L); _ }; _ } -> ()
      | _ -> Alcotest.fail "default not CTLeaf(0)")
  | _ -> Alcotest.fail "expected CTSwitchLit"

let test_compile_or_pattern_constructors () =
  (* match c: Red | Blue -> 1 | Green -> 2 *)
  let arms =
    [
      (PatOr [ PatConstructor ("Red", []); PatConstructor ("Blue", []) ], cint 1);
      (PatConstructor ("Green", []), cint 2);
    ]
  in
  let m = mk_match (cvar "c" ty_int) arms ty_int in
  let compiled = Blorp.Core_match.try_compile_match m in
  match get_ctree compiled with
  | CTSwitchTag { cts_cases; _ } ->
      Alcotest.(check int) "3 constructor cases" 3 (List.length cts_cases);
      Alcotest.(check bool) "has Red" true (List.mem_assoc "Red" cts_cases);
      Alcotest.(check bool) "has Blue" true (List.mem_assoc "Blue" cts_cases);
      Alcotest.(check bool) "has Green" true (List.mem_assoc "Green" cts_cases)
  | _ -> Alcotest.fail "expected CTSwitchTag with 3 cases"

(* ============================================================================
   Program-level compilation
   ============================================================================ *)

let test_compile_program_walks_into_funcs () =
  (* func f(x: Int) -> Int: match x: 1 -> 10 | _ -> 0 *)
  let body =
    mk_match (cvar "x" ty_int)
      [ (PatLiteral (LitInt 1L), cint 10); (PatWildcard, cint 0) ]
      ty_int
  in
  let func : core_func =
    {
      cf_name = "f";
      cf_type_params = [];
      cf_module = None;
      cf_params = [ { cp_name = Var.named "x"; cp_ty = ty_int; cp_loc = loc } ];
      cf_return_ty = ty_int;
      cf_body = Some body;
      cf_is_pure = true;
      cf_kind = CFUser;
      cf_def_id = 0;
    }
  in
  let prog = [ { cd_desc = CDFunc func; cd_loc = loc; cd_doc = None } ] in
  let compiled = Blorp.Core_match.compile_program prog in
  match compiled with
  | [ { cd_desc = CDFunc { cf_body = Some b; _ }; _ } ] -> (
      match b.desc with
      | CMatch (_, CTSwitchLit _) -> ()
      | _ -> Alcotest.fail "function body not compiled to decision-tree CMatch")
  | _ -> Alcotest.fail "expected single function"

let test_compile_program_recurses () =
  (* A match inside an if inside a function body — compile should reach it *)
  let inner =
    mk_match (cvar "y" ty_int)
      [ (PatLiteral (LitInt 0L), cint 1); (PatWildcard, cint 2) ]
      ty_int
  in
  let outer = mk (CIf (cvar "cond" ty_bool, inner, cint 3)) ty_int in
  let func : core_func =
    {
      cf_name = "g";
      cf_type_params = [];
      cf_module = None;
      cf_params = [];
      cf_return_ty = ty_int;
      cf_body = Some outer;
      cf_is_pure = true;
      cf_kind = CFUser;
      cf_def_id = 0;
    }
  in
  let prog = [ { cd_desc = CDFunc func; cd_loc = loc; cd_doc = None } ] in
  let compiled = Blorp.Core_match.compile_program prog in
  match compiled with
  | [ { cd_desc = CDFunc { cf_body = Some b; _ }; _ } ] -> (
      match b.desc with
      | CIf (_, then_e, _) -> (
          match then_e.desc with
          | CMatch _ -> ()
          | _ -> Alcotest.fail "nested match not compiled")
      | _ -> Alcotest.fail "expected CIf at root")
  | _ -> Alcotest.fail "expected single function"

(* ============================================================================
   Test suite
   ============================================================================ *)

let suite =
  [
    ( "catchall",
      [
        Alcotest.test_case "wildcard" `Quick test_compile_single_wildcard;
        Alcotest.test_case "var" `Quick test_compile_single_var;
      ] );
    ( "literal_switch",
      [
        Alcotest.test_case "with_default" `Quick test_compile_literal_switch;
        Alcotest.test_case "no_default_fail" `Quick
          test_compile_literal_no_default;
      ] );
    ( "constructor_switch",
      [
        Alcotest.test_case "option" `Quick test_compile_option_match;
        Alcotest.test_case "with_wildcard" `Quick
          test_compile_constructor_with_wildcard_catchall;
        Alcotest.test_case "qualified" `Quick test_compile_qualified_constructor;
      ] );
    ( "or_patterns",
      [
        Alcotest.test_case "literals" `Quick test_compile_or_pattern_literals;
        Alcotest.test_case "constructors" `Quick
          test_compile_or_pattern_constructors;
      ] );
    ( "literal_in_ctor",
      [
        Alcotest.test_case "char_literal" `Quick
          test_compile_ctor_with_char_literal;
        Alcotest.test_case "int_literal" `Quick
          test_compile_ctor_with_int_literal;
        Alcotest.test_case "mixed_lit_var" `Quick
          test_compile_ctor_mixed_lit_and_var;
      ] );
    ( "nested_ctor",
      [
        Alcotest.test_case "some_some" `Quick test_compile_nested_some_some;
        Alcotest.test_case "ok_some_none" `Quick
          test_compile_nested_ok_some_none;
      ] );
    ( "tuple",
      [
        Alcotest.test_case "simple_bind" `Quick test_compile_tuple_simple;
        Alcotest.test_case "with_literals" `Quick
          test_compile_tuple_with_literals;
        Alcotest.test_case "with_ctors" `Quick test_compile_tuple_with_ctors;
      ] );
    ( "list_pattern",
      [
        Alcotest.test_case "empty_nonempty" `Quick
          test_compile_list_empty_nonempty;
        Alcotest.test_case "exact_length" `Quick test_compile_list_exact_length;
        Alcotest.test_case "spread_before_exact_order" `Quick
          test_compile_list_spread_before_exact_order;
        Alcotest.test_case "unused_spread_binding" `Quick
          test_compile_list_unused_spread;
        Alcotest.test_case "used_spread_binding" `Quick
          test_compile_list_used_spread;
        Alcotest.test_case "resource_scope_shadowed_spread_binding" `Quick
          test_compile_list_spread_shadowed_by_resource_scope_body;
        Alcotest.test_case "resource_scope_acquire_uses_outer_spread" `Quick
          test_compile_list_spread_used_by_resource_scope_acquire;
      ] );
    ( "phase_2_5_gaps",
      [
        Alcotest.test_case "ctor wrapping list with catchall" `Quick
          test_ctor_wrapping_list_with_catchall;
      ] );
    ( "complex_tuple",
      [
        Alcotest.test_case "ctor_elements" `Quick
          test_compile_tuple_ctor_elements;
        Alcotest.test_case "lit_elements" `Quick test_compile_tuple_lit_elements;
      ] );
    ( "fallback",
      [ Alcotest.test_case "mixed" `Quick test_fallback_mixed_patterns ] );
    ( "direct_constructor",
      [
        Alcotest.test_case "does_not_fuse_normal_call" `Quick
          test_non_constructor_call_with_constructor_arm_not_fused;
        Alcotest.test_case "var_payload" `Quick
          test_fuse_direct_constructor_var_payload;
        Alcotest.test_case "wildcard_payload" `Quick
          test_fuse_direct_constructor_wildcard_payload;
      ] );
    ( "program",
      [
        Alcotest.test_case "walks_into_funcs" `Quick
          test_compile_program_walks_into_funcs;
        Alcotest.test_case "recurses_nested" `Quick
          test_compile_program_recurses;
      ] );
  ]
