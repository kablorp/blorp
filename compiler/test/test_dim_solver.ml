(** Unit tests for Dim_solver module *)

open Blorp.Ast
open Blorp.Dim_solver

let check_true msg b = Alcotest.(check bool) msg true b
let check_false msg b = Alcotest.(check bool) msg false b

(* Helper: no meta bindings *)
let no_meta _ = None

(* ============================================================================
   Canonical form normalization tests
   ============================================================================ *)

let test_const_canonical () =
  let c = to_canonical ~lookup_meta:no_meta (TyConstInt 5) in
  check_true "const=5" (c.const = 5);
  check_true "no terms" (c.terms = [])

let test_var_canonical () =
  let c = to_canonical ~lookup_meta:no_meta (TyVar "#N") in
  check_true "const=0" (c.const = 0);
  check_true "one term" (List.length c.terms = 1);
  check_true "coeff=1" ((List.hd c.terms).coeff = 1);
  check_true "var=#N" ((List.hd c.terms).vars = [ "#N" ])

let test_add_canonical () =
  let expr = TyDimOp (DimAdd, TyVar "#N", TyConstInt 3) in
  let c = to_canonical ~lookup_meta:no_meta expr in
  check_true "const=3" (c.const = 3);
  check_true "one term" (List.length c.terms = 1);
  check_true "coeff=1" ((List.hd c.terms).coeff = 1);
  check_true "var=#N" ((List.hd c.terms).vars = [ "#N" ])

let test_commutativity () =
  let expr1 = TyDimOp (DimAdd, TyVar "#N", TyVar "#M") in
  let expr2 = TyDimOp (DimAdd, TyVar "#M", TyVar "#N") in
  let c1 = to_canonical ~lookup_meta:no_meta expr1 in
  let c2 = to_canonical ~lookup_meta:no_meta expr2 in
  check_true "commutative add" (equal c1 c2)

let test_associativity () =
  (* (#A + #B) + #C = #A + (#B + #C) *)
  let expr1 =
    TyDimOp (DimAdd, TyDimOp (DimAdd, TyVar "#A", TyVar "#B"), TyVar "#C")
  in
  let expr2 =
    TyDimOp (DimAdd, TyVar "#A", TyDimOp (DimAdd, TyVar "#B", TyVar "#C"))
  in
  let c1 = to_canonical ~lookup_meta:no_meta expr1 in
  let c2 = to_canonical ~lookup_meta:no_meta expr2 in
  check_true "associative add" (equal c1 c2)

let test_distributivity () =
  (* 2 * #N = #N + #N *)
  let expr1 = TyDimOp (DimMul, TyConstInt 2, TyVar "#N") in
  let expr2 = TyDimOp (DimAdd, TyVar "#N", TyVar "#N") in
  let c1 = to_canonical ~lookup_meta:no_meta expr1 in
  let c2 = to_canonical ~lookup_meta:no_meta expr2 in
  check_true "2*N = N+N" (equal c1 c2)

let test_mul_commutativity () =
  (* #M * #N = #N * #M *)
  let expr1 = TyDimOp (DimMul, TyVar "#M", TyVar "#N") in
  let expr2 = TyDimOp (DimMul, TyVar "#N", TyVar "#M") in
  let c1 = to_canonical ~lookup_meta:no_meta expr1 in
  let c2 = to_canonical ~lookup_meta:no_meta expr2 in
  check_true "commutative mul" (equal c1 c2)

let test_identity_add () =
  (* #N + 0 = #N *)
  let expr1 = TyDimOp (DimAdd, TyVar "#N", TyConstInt 0) in
  let c1 = to_canonical ~lookup_meta:no_meta expr1 in
  let c2 = to_canonical ~lookup_meta:no_meta (TyVar "#N") in
  check_true "N + 0 = N" (equal c1 c2)

let test_identity_mul () =
  (* #N * 1 = #N *)
  let expr1 = TyDimOp (DimMul, TyVar "#N", TyConstInt 1) in
  let c1 = to_canonical ~lookup_meta:no_meta expr1 in
  let c2 = to_canonical ~lookup_meta:no_meta (TyVar "#N") in
  check_true "N * 1 = N" (equal c1 c2)

let test_zero_mul () =
  (* #N * 0 = 0 *)
  let expr = TyDimOp (DimMul, TyVar "#N", TyConstInt 0) in
  let c = to_canonical ~lookup_meta:no_meta expr in
  check_true "N * 0: const=0" (c.const = 0);
  check_true "N * 0: no terms" (c.terms = [])

let test_constant_folding () =
  (* (#N + 3) - 1 = #N + 2 *)
  let expr1 =
    TyDimOp (DimSub, TyDimOp (DimAdd, TyVar "#N", TyConstInt 3), TyConstInt 1)
  in
  let expr2 = TyDimOp (DimAdd, TyVar "#N", TyConstInt 2) in
  let c1 = to_canonical ~lookup_meta:no_meta expr1 in
  let c2 = to_canonical ~lookup_meta:no_meta expr2 in
  check_true "(N+3)-1 = N+2" (equal c1 c2)

let test_full_distribution () =
  (* (#N + 1) * 2 = 2*#N + 2 *)
  let expr1 =
    TyDimOp (DimMul, TyDimOp (DimAdd, TyVar "#N", TyConstInt 1), TyConstInt 2)
  in
  let expr2 =
    TyDimOp (DimAdd, TyDimOp (DimMul, TyConstInt 2, TyVar "#N"), TyConstInt 2)
  in
  let c1 = to_canonical ~lookup_meta:no_meta expr1 in
  let c2 = to_canonical ~lookup_meta:no_meta expr2 in
  check_true "(N+1)*2 = 2*N+2" (equal c1 c2)

let test_sub_self () =
  (* #N - #N = 0 *)
  let expr = TyDimOp (DimSub, TyVar "#N", TyVar "#N") in
  let c = to_canonical ~lookup_meta:no_meta expr in
  check_true "N-N: const=0" (c.const = 0);
  check_true "N-N: no terms" (c.terms = [])

(* ============================================================================
   Solving tests
   ============================================================================ *)

let test_solve_equal () =
  let result = solve ~lookup_meta:no_meta (TyConstInt 5) (TyConstInt 5) in
  check_true "5 = 5" (result = Solved)

let test_solve_contradiction () =
  let result = solve ~lookup_meta:no_meta (TyConstInt 3) (TyConstInt 5) in
  check_true "3 != 5" (result = Contradiction)

let test_solve_var_eq_const () =
  (* #N = 5 *)
  let result = solve ~lookup_meta:no_meta (TyVar "#N") (TyConstInt 5) in
  match result with
  | BindVar ("#N", TyConstInt 5) -> check_true "solved #N=5" true
  | _ -> Alcotest.fail "expected BindVar(#N, 5)"

let test_solve_add () =
  (* #N + 1 = 5 → #N = 4 *)
  let result =
    solve ~lookup_meta:no_meta
      (TyDimOp (DimAdd, TyVar "#N", TyConstInt 1))
      (TyConstInt 5)
  in
  match result with
  | BindVar ("#N", TyConstInt 4) -> check_true "solved #N=4" true
  | _ -> Alcotest.fail "expected BindVar(#N, 4)"

let test_solve_mul () =
  (* #N * 3 = 12 → #N = 4 *)
  let result =
    solve ~lookup_meta:no_meta
      (TyDimOp (DimMul, TyVar "#N", TyConstInt 3))
      (TyConstInt 12)
  in
  match result with
  | BindVar ("#N", TyConstInt 4) -> check_true "solved #N=4" true
  | _ -> Alcotest.fail "expected BindVar(#N, 4)"

let test_solve_mul_no_solution () =
  (* #N * 3 = 7 → no integer solution *)
  let result =
    solve ~lookup_meta:no_meta
      (TyDimOp (DimMul, TyVar "#N", TyConstInt 3))
      (TyConstInt 7)
  in
  check_true "#N*3=7 is stuck" (result = Stuck)

let test_solve_negative_reject () =
  (* #N + 5 = 3 → #N = -2, rejected *)
  let result =
    solve ~lookup_meta:no_meta
      (TyDimOp (DimAdd, TyVar "#N", TyConstInt 5))
      (TyConstInt 3)
  in
  check_true "#N+5=3 is stuck (negative)" (result = Stuck)

let test_solve_symmetric_sub () =
  (* 10 - #N = 3 → #N = 7 *)
  let result =
    solve ~lookup_meta:no_meta
      (TyDimOp (DimSub, TyConstInt 10, TyVar "#N"))
      (TyConstInt 3)
  in
  match result with
  | BindVar ("#N", TyConstInt 7) -> check_true "solved #N=7" true
  | _ -> Alcotest.fail "expected BindVar(#N, 7)"

let test_solve_symmetric_div () =
  (* 12 / #N = 3 → #N = 4 *)
  let result =
    solve ~lookup_meta:no_meta
      (TyDimOp (DimDiv, TyConstInt 12, TyVar "#N"))
      (TyConstInt 3)
  in
  match result with
  | BindVar ("#N", TyConstInt 4) -> check_true "solved #N=4" true
  | _ -> Alcotest.fail "expected BindVar(#N, 4)"

let test_solve_dividend_var () =
  (* #N / 3 = 4 → #N = 12 (var / constant = n) *)
  let result =
    solve ~lookup_meta:no_meta
      (TyDimOp (DimDiv, TyVar "#N", TyConstInt 3))
      (TyConstInt 4)
  in
  match result with
  | BindVar ("#N", TyConstInt 12) -> check_true "solved #N=12" true
  | _ -> Alcotest.fail "expected BindVar(#N, 12)"

let test_solve_dividend_meta () =
  (* ?m0 / 5 = 3 → ?m0 = 15 (meta / constant = n) *)
  let result =
    solve ~lookup_meta:no_meta
      (TyDimOp (DimDiv, TyMeta 0, TyConstInt 5))
      (TyConstInt 3)
  in
  match result with
  | BindMeta (0, TyConstInt 15) -> check_true "solved ?m0=15" true
  | _ -> Alcotest.fail "expected BindMeta(0, 15)"

let test_solve_symbolic () =
  (* ?m0 + 1 = #M + 2 → ?m0 = #M + 1 (meta = unknown, #M = rigid) *)
  let result =
    solve ~lookup_meta:no_meta
      (TyDimOp (DimAdd, TyMeta 0, TyConstInt 1))
      (TyDimOp (DimAdd, TyVar "#M", TyConstInt 2))
  in
  match result with
  | BindMeta (0, ty) ->
      (* Result should be #M + 1 in some form *)
      let c = to_canonical ~lookup_meta:no_meta ty in
      check_true "symbolic: const=1" (c.const = 1);
      check_true "symbolic: one term" (List.length c.terms = 1);
      check_true "symbolic: var=#M" ((List.hd c.terms).vars = [ "#M" ])
  | _ -> Alcotest.fail "expected BindMeta(0, #M+1)"

let test_solve_commutativity () =
  (* #N + #M = #M + #N → Solved (equal after normalization) *)
  let result =
    solve ~lookup_meta:no_meta
      (TyDimOp (DimAdd, TyVar "#N", TyVar "#M"))
      (TyDimOp (DimAdd, TyVar "#M", TyVar "#N"))
  in
  check_true "commutative equality" (result = Solved)

let test_solve_two_unknowns_isolate () =
  (* #N + #M = 10 → isolate one variable: #M = 10 - #N
     (underdetermined system, but solver isolates a single-variable term) *)
  let result =
    solve ~lookup_meta:no_meta
      (TyDimOp (DimAdd, TyVar "#N", TyVar "#M"))
      (TyConstInt 10)
  in
  match result with
  | BindVar (_, _) -> check_true "isolated one var" true
  | _ -> Alcotest.fail "expected BindVar for one of the variables"

let test_solve_compound () =
  (* #N * 2 + 1 = 7 → #N = 3 *)
  let lhs =
    TyDimOp (DimAdd, TyDimOp (DimMul, TyVar "#N", TyConstInt 2), TyConstInt 1)
  in
  let result = solve ~lookup_meta:no_meta lhs (TyConstInt 7) in
  match result with
  | BindVar ("#N", TyConstInt 3) -> check_true "solved #N=3" true
  | _ -> Alcotest.fail "expected BindVar(#N, 3)"

(* ============================================================================
   Additional tests from soundness review
   ============================================================================ *)

let test_quadratic_stuck () =
  (* #N * #N = 9 → Stuck (nonlinear, can't solve with linear solver) *)
  let result =
    solve ~lookup_meta:no_meta
      (TyDimOp (DimMul, TyVar "#N", TyVar "#N"))
      (TyConstInt 9)
  in
  check_true "#N*#N=9 is stuck" (result = Stuck)

let test_quadratic_canonical () =
  (* #N * #N should NOT equal #N in canonical form *)
  let nn =
    to_canonical ~lookup_meta:no_meta (TyDimOp (DimMul, TyVar "#N", TyVar "#N"))
  in
  let n = to_canonical ~lookup_meta:no_meta (TyVar "#N") in
  check_false "#N*#N != #N" (equal nn n)

let test_sub_as_negative_coeff () =
  (* 5 - #N = 2 → #N = 3 *)
  let result =
    solve ~lookup_meta:no_meta
      (TyDimOp (DimSub, TyConstInt 5, TyVar "#N"))
      (TyConstInt 2)
  in
  match result with
  | BindVar ("#N", TyConstInt 3) -> check_true "solved #N=3" true
  | _ -> Alcotest.fail "expected BindVar(#N, 3)"

let test_bound_meta_lookup () =
  (* ?m0 + 1 = 8, where ?m0 is bound to 7 → Solved *)
  let lookup m = if m = 0 then Some (TyConstInt 7) else None in
  let result =
    solve ~lookup_meta:lookup
      (TyDimOp (DimAdd, TyMeta 0, TyConstInt 1))
      (TyConstInt 8)
  in
  check_true "bound meta solved" (result = Solved)

let test_bound_meta_contradiction () =
  (* ?m0 + 1 = 5, where ?m0 is bound to 7 → Contradiction (8 != 5) *)
  let lookup m = if m = 0 then Some (TyConstInt 7) else None in
  let result =
    solve ~lookup_meta:lookup
      (TyDimOp (DimAdd, TyMeta 0, TyConstInt 1))
      (TyConstInt 5)
  in
  check_true "bound meta contradiction" (result = Contradiction)

let test_zero_equals_zero () =
  let result = solve ~lookup_meta:no_meta (TyConstInt 0) (TyConstInt 0) in
  check_true "0 = 0" (result = Solved)

let test_n_times_zero_equals_zero () =
  (* #N * 0 = 0 → Solved *)
  let result =
    solve ~lookup_meta:no_meta
      (TyDimOp (DimMul, TyVar "#N", TyConstInt 0))
      (TyConstInt 0)
  in
  check_true "#N*0=0 solved" (result = Solved)

let test_multiple_metas_isolate () =
  (* ?m0 + ?m1 = 5 → isolate one meta: ?m0 = 5 - ?m1
     (solver picks first meta to isolate) *)
  let result =
    solve ~lookup_meta:no_meta
      (TyDimOp (DimAdd, TyMeta 0, TyMeta 1))
      (TyConstInt 5)
  in
  match result with
  | BindMeta (_, _) -> check_true "isolated one meta" true
  | _ -> Alcotest.fail "expected BindMeta for one of the metas"

let test_factoring_equivalence () =
  (* #N * #M + #N * #K should equal #N * (#M + #K) after normalization *)
  let expr1 =
    TyDimOp
      ( DimAdd,
        TyDimOp (DimMul, TyVar "#N", TyVar "#M"),
        TyDimOp (DimMul, TyVar "#N", TyVar "#K") )
  in
  let expr2 =
    TyDimOp (DimMul, TyVar "#N", TyDimOp (DimAdd, TyVar "#M", TyVar "#K"))
  in
  let c1 = to_canonical ~lookup_meta:no_meta expr1 in
  let c2 = to_canonical ~lookup_meta:no_meta expr2 in
  check_true "#N*#M + #N*#K = #N*(#M+#K)" (equal c1 c2)

(* ============================================================================
   Test suite
   ============================================================================ *)

let suite =
  [
    ( "normalization",
      [
        Alcotest.test_case "constant" `Quick test_const_canonical;
        Alcotest.test_case "variable" `Quick test_var_canonical;
        Alcotest.test_case "add" `Quick test_add_canonical;
        Alcotest.test_case "commutativity" `Quick test_commutativity;
        Alcotest.test_case "associativity" `Quick test_associativity;
        Alcotest.test_case "distributivity" `Quick test_distributivity;
        Alcotest.test_case "mul commutativity" `Quick test_mul_commutativity;
        Alcotest.test_case "identity add" `Quick test_identity_add;
        Alcotest.test_case "identity mul" `Quick test_identity_mul;
        Alcotest.test_case "zero mul" `Quick test_zero_mul;
        Alcotest.test_case "constant folding" `Quick test_constant_folding;
        Alcotest.test_case "full distribution" `Quick test_full_distribution;
        Alcotest.test_case "sub self" `Quick test_sub_self;
      ] );
    ( "solving",
      [
        Alcotest.test_case "equal constants" `Quick test_solve_equal;
        Alcotest.test_case "contradiction" `Quick test_solve_contradiction;
        Alcotest.test_case "var = const" `Quick test_solve_var_eq_const;
        Alcotest.test_case "add solving" `Quick test_solve_add;
        Alcotest.test_case "mul solving" `Quick test_solve_mul;
        Alcotest.test_case "mul no solution" `Quick test_solve_mul_no_solution;
        Alcotest.test_case "negative reject" `Quick test_solve_negative_reject;
        Alcotest.test_case "symmetric sub" `Quick test_solve_symmetric_sub;
        Alcotest.test_case "symmetric div" `Quick test_solve_symmetric_div;
        Alcotest.test_case "dividend var div" `Quick test_solve_dividend_var;
        Alcotest.test_case "dividend meta div" `Quick test_solve_dividend_meta;
        Alcotest.test_case "symbolic solving" `Quick test_solve_symbolic;
        Alcotest.test_case "commutativity equality" `Quick
          test_solve_commutativity;
        Alcotest.test_case "two unknowns isolate" `Quick
          test_solve_two_unknowns_isolate;
        Alcotest.test_case "compound expression" `Quick test_solve_compound;
        Alcotest.test_case "quadratic stuck" `Quick test_quadratic_stuck;
        Alcotest.test_case "quadratic != linear" `Quick test_quadratic_canonical;
        Alcotest.test_case "sub as neg coeff" `Quick test_sub_as_negative_coeff;
        Alcotest.test_case "bound meta" `Quick test_bound_meta_lookup;
        Alcotest.test_case "bound meta contradiction" `Quick
          test_bound_meta_contradiction;
        Alcotest.test_case "zero = zero" `Quick test_zero_equals_zero;
        Alcotest.test_case "N*0 = 0" `Quick test_n_times_zero_equals_zero;
        Alcotest.test_case "multiple metas isolate" `Quick
          test_multiple_metas_isolate;
        Alcotest.test_case "factoring equivalence" `Quick
          test_factoring_equivalence;
      ] );
  ]
