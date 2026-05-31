(** Tests for Core_perceus_check — the refcount-balance simulator.

    Two groups of tests:
    1. Self-tests of the simulator (hand-written Core with explicit
       dup/drop nodes, asserting the simulator reports Balanced or
       catches specific errors).
    2. Integration tests that run [insert_drops_expr_for_test]
       on a let expression, then check that the result is balanced.
       This is the key validation that Perceus transforms are correct. *)

open Blorp.Ast
open Blorp.Core
open Blorp.Core_perceus_check

let loc =
  { line = 1; column = 1; end_line = 1; end_column = 1; loc_file = None }

let ty_int = TyNamed ("Int", [])
let ty_bool = TyNamed ("Bool", [])
let ty_string = TyNamed ("String", [])
let ty_void = TyNamed ("Void", [])
let ty_list_int = TyNamed ("List", [ ty_int ])
let ty_opt_int = TyNamed ("Option", [ ty_int ])
let str_flags = { sf_multiline = false; sf_raw = false }
let mk d t = { desc = d; ty = t; loc }
let cint n = mk (CLit (LitInt (Int64.of_int n))) ty_int
let cbool b = mk (CLit (LitBool b)) ty_bool
let cstr s = mk (CLit (LitString (s, str_flags))) ty_string
let cvoid = mk CVoid ty_void
let cvar n t = mk (CVar (Var.named n)) t
let intrinsic name args ty = mk (CCall (CKIntrinsic name, cvoid, args)) ty

let clist elems =
  CList { ll_layout = list_pointer_storage (); ll_elems = elems }

let bind_named ?(mut = false) name ty rhs : binding =
  { bind_var = Var.named name; bind_mut = mut; bind_ty = ty; bind_rhs = rhs }

let insert_drops_expr_for_test e =
  Blorp.Core_perceus.insert_drops_expr_with_env
    (Blorp.Core_perceus.empty_env ())
    e

(** Run perceus on a [CLet] expression and check the result balances. *)
let check_perceus_result (e : core) : result =
  let transformed = insert_drops_expr_for_test e in
  check_let_balance transformed

(** Wrap [check_perceus_result] as an Alcotest assertion. *)
let assert_balanced label e =
  match check_perceus_result e with
  | Balanced -> ()
  | Unbalanced { final_rc; errors } ->
      Alcotest.failf
        "%s: unbalanced final_rc=%d errors=[%s]\nAfter perceus:\n%s" label
        final_rc
        (String.concat "; " errors)
        (pp_to_string_indented (insert_drops_expr_for_test e))

(* ============================================================================
   Simulator self-tests — exercise the simulator on hand-built Core
   ============================================================================ *)

(** A let with no uses and an explicit CDrop balances. *)
let test_sim_unused_with_drop () =
  let body = mk (CDrop (Var.named "s", ty_string, cint 42)) ty_int in
  Alcotest.(check bool) "balanced" true (check_balance "s" body = Balanced)

(** A let with no uses and NO drop is unbalanced (refcount stays at 1). *)
let test_sim_unused_no_drop () =
  let body = cint 42 in
  match check_balance "s" body with
  | Unbalanced { final_rc = 1; _ } -> ()
  | _ -> Alcotest.fail "expected unbalanced rc=1"

(** A let with 1 use balances (the use consumes the ref). *)
let test_sim_one_use () =
  let body = cvar "s" ty_string in
  Alcotest.(check bool) "balanced" true (check_balance "s" body = Balanced)

(** 2 uses without a dup → underflow error. *)
let test_sim_two_uses_no_dup () =
  let fty =
    TyFunc
      { params = [ ty_string; ty_string ]; return = ty_int; is_pure = true }
  in
  let body =
    mk
      (CCall
         (CKUnknown, cvar "f" fty, [ cvar "s" ty_string; cvar "s" ty_string ]))
      ty_int
  in
  match check_balance "s" body with
  | Unbalanced { errors; _ } when List.exists (fun m -> m <> "") errors -> ()
  | _ -> Alcotest.fail "expected underflow"

(** 2 uses with 1 explicit dup balances. *)
let test_sim_two_uses_with_dup () =
  let fty =
    TyFunc
      { params = [ ty_string; ty_string ]; return = ty_int; is_pure = true }
  in
  let call =
    mk
      (CCall
         (CKUnknown, cvar "f" fty, [ cvar "s" ty_string; cvar "s" ty_string ]))
      ty_int
  in
  let body = mk (CDup (Var.named "s", ty_string, call)) ty_int in
  Alcotest.(check bool) "balanced" true (check_balance "s" body = Balanced)

(** Branches with matching exit counts balance. *)
let test_sim_balanced_branches () =
  let body =
    mk (CIf (cbool true, cvar "s" ty_string, cvar "s" ty_string)) ty_string
  in
  Alcotest.(check bool) "balanced" true (check_balance "s" body = Balanced)

(** Branches with mismatched exit counts are unbalanced. *)
let test_sim_branch_imbalance () =
  (* if c then s else 0 — then consumes 1 ref, else doesn't *)
  let body = mk (CIf (cbool true, cvar "s" ty_string, cint 0)) ty_int in
  match check_balance "s" body with
  | Unbalanced _ -> ()
  | Balanced -> Alcotest.fail "expected imbalance"

(** Branch with excess drop on one side balances. *)
let test_sim_branch_with_excess_drop () =
  let drop_s = mk (CDrop (Var.named "s", ty_string, cint 0)) ty_int in
  let body = mk (CIf (cbool true, cvar "s" ty_string, drop_s)) ty_int in
  Alcotest.(check bool) "balanced" true (check_balance "s" body = Balanced)

(** Shadow: inner let with same name doesn't consume outer's ref. *)
let test_sim_shadow_binding () =
  (* let s = 0 in s — the inner s shadows; outer s is still at refcount 1 *)
  let inner =
    mk (CLet (bind_named "s" ty_int (cint 0), cvar "s" ty_int)) ty_int
  in
  match check_balance "s" inner with
  | Unbalanced { final_rc = 1; _ } -> ()
  | _ -> Alcotest.fail "expected rc=1 from shadowed outer"

(** Ownership contracts: list_len borrows its list argument, so the original
    reference is still live after the call. *)
let test_sim_intrinsic_borrow_arg () =
  let body =
    mk
      (CCall
         ( CKIntrinsic "list_len",
           mk CVoid (TyNamed ("Void", [])),
           [ cvar "xs" ty_list_int ] ))
      ty_int
  in
  match check_balance "xs" body with
  | Unbalanced { final_rc = 1; _ } -> ()
  | _ -> Alcotest.fail "expected borrowed arg to leave xs live"

(** Ownership contracts: list_ensure_unique COW-consumes its list argument. *)
let test_sim_intrinsic_cow_consume_arg () =
  let body =
    mk
      (CCall
         ( CKIntrinsic "list_ensure_unique",
           mk CVoid (TyNamed ("Void", [])),
           [ cvar "xs" ty_list_int ] ))
      ty_list_int
  in
  Alcotest.(check bool) "balanced" true (check_balance "xs" body = Balanced)

(* ============================================================================
   Integration tests — run perceus on a let expression, check balance
   ============================================================================ *)

let test_int_unused_let () =
  (* let s = "hi" in 42 — unused, should get a drop and balance *)
  let e = mk (CLet (bind_named "s" ty_string (cstr "hi"), cint 42)) ty_int in
  assert_balanced "unused let" e

let test_int_single_use () =
  (* let s = "hi" in s — one use consumes, balances *)
  let e =
    mk
      (CLet (bind_named "s" ty_string (cstr "hi"), cvar "s" ty_string))
      ty_string
  in
  assert_balanced "single use" e

let test_int_intrinsic_borrow_arg () =
  let e =
    mk
      (CLet
         ( bind_named "xs" ty_list_int (mk (clist []) ty_list_int),
           intrinsic "list_len" [ cvar "xs" ty_list_int ] ty_int ))
      ty_int
  in
  assert_balanced "intrinsic borrow arg" e

let test_int_intrinsic_consume_then_borrow () =
  let consume =
    intrinsic "list_ensure_unique" [ cvar "xs" ty_list_int ] ty_list_int
  in
  let borrow = intrinsic "list_len" [ cvar "xs" ty_list_int ] ty_int in
  let body = mk (CSeq (consume, borrow)) ty_int in
  let e =
    mk
      (CLet (bind_named "xs" ty_list_int (mk (clist []) ty_list_int), body))
      ty_int
  in
  assert_balanced "intrinsic consume then borrow" e

let test_int_two_uses () =
  let fty =
    TyFunc
      { params = [ ty_string; ty_string ]; return = ty_int; is_pure = true }
  in
  let body =
    mk
      (CCall
         (CKUnknown, cvar "f" fty, [ cvar "s" ty_string; cvar "s" ty_string ]))
      ty_int
  in
  let e = mk (CLet (bind_named "s" ty_string (cstr "hi"), body)) ty_int in
  assert_balanced "two uses" e

let test_int_three_uses () =
  let fty =
    TyFunc
      {
        params = [ ty_string; ty_string; ty_string ];
        return = ty_int;
        is_pure = true;
      }
  in
  let body =
    mk
      (CCall
         ( CKUnknown,
           cvar "f" fty,
           [ cvar "s" ty_string; cvar "s" ty_string; cvar "s" ty_string ] ))
      ty_int
  in
  let e = mk (CLet (bind_named "s" ty_string (cstr "hi"), body)) ty_int in
  assert_balanced "three uses" e

let test_int_if_both_unused () =
  let body = mk (CIf (cbool true, cint 1, cint 0)) ty_int in
  let e = mk (CLet (bind_named "s" ty_string (cstr "hi"), body)) ty_int in
  assert_balanced "if both unused" e

let test_int_if_asymmetric () =
  let fty =
    TyFunc { params = [ ty_string ]; return = ty_int; is_pure = true }
  in
  let f_call =
    mk (CCall (CKUnknown, cvar "f" fty, [ cvar "s" ty_string ])) ty_int
  in
  let body = mk (CIf (cbool true, f_call, cint 0)) ty_int in
  let e = mk (CLet (bind_named "s" ty_string (cstr "hi"), body)) ty_int in
  assert_balanced "if asymmetric" e

let test_int_if_intrinsic_borrowed_branch () =
  let borrowed = intrinsic "list_len" [ cvar "xs" ty_list_int ] ty_int in
  let body = mk (CIf (cbool true, borrowed, cint 0)) ty_int in
  let e =
    mk
      (CLet (bind_named "xs" ty_list_int (mk (clist []) ty_list_int), body))
      ty_int
  in
  assert_balanced "if borrowed branch" e

let test_int_if_symmetric_multi () =
  let fty2 =
    TyFunc
      { params = [ ty_string; ty_string ]; return = ty_int; is_pure = true }
  in
  let fty1 =
    TyFunc { params = [ ty_string ]; return = ty_int; is_pure = true }
  in
  let then_call =
    mk
      (CCall
         (CKUnknown, cvar "f" fty2, [ cvar "s" ty_string; cvar "s" ty_string ]))
      ty_int
  in
  let else_call =
    mk (CCall (CKUnknown, cvar "f" fty1, [ cvar "s" ty_string ])) ty_int
  in
  let body = mk (CIf (cbool true, then_call, else_call)) ty_int in
  let e = mk (CLet (bind_named "s" ty_string (cstr "hi"), body)) ty_int in
  assert_balanced "if asymmetric multi" e

let test_int_match_asymmetric () =
  let fty =
    TyFunc { params = [ ty_string ]; return = ty_int; is_pure = true }
  in
  let f_call =
    mk (CCall (CKUnknown, cvar "f" fty, [ cvar "s" ty_string ])) ty_int
  in
  let arms =
    [ (PatConstructor ("A", []), f_call); (PatConstructor ("B", []), cint 0) ]
  in
  let body = mk (CMatchArms (cvar "x" ty_int, arms)) ty_int in
  let e = mk (CLet (bind_named "s" ty_string (cstr "hi"), body)) ty_int in
  assert_balanced "match asymmetric" e

let test_int_match_all_unused () =
  let arms =
    [ (PatConstructor ("A", []), cint 0); (PatConstructor ("B", []), cint 1) ]
  in
  let body = mk (CMatchArms (cvar "x" ty_int, arms)) ty_int in
  let e = mk (CLet (bind_named "s" ty_string (cstr "hi"), body)) ty_int in
  assert_balanced "match all unused" e

let test_int_match_intrinsic_borrowed_arm () =
  let borrowed = intrinsic "list_len" [ cvar "xs" ty_list_int ] ty_int in
  let arms =
    [ (PatConstructor ("A", []), borrowed); (PatConstructor ("B", []), cint 0) ]
  in
  let body = mk (CMatchArms (cvar "tag" ty_int, arms)) ty_int in
  let e =
    mk
      (CLet (bind_named "xs" ty_list_int (mk (clist []) ty_list_int), body))
      ty_int
  in
  assert_balanced "match borrowed arm" e

let test_int_match_tree_asymmetric () =
  let fty =
    TyFunc { params = [ ty_string ]; return = ty_int; is_pure = true }
  in
  let f_call =
    mk (CCall (CKUnknown, cvar "f" fty, [ cvar "s" ty_string ])) ty_int
  in
  let leaf_a = CTLeaf { ct_bindings = []; ct_body = f_call } in
  let leaf_b = CTLeaf { ct_bindings = []; ct_body = cint 0 } in
  let tree =
    CTSwitchTag
      {
        cts_scrut = AccRoot;
        cts_cases = [ ("A", leaf_a); ("B", leaf_b) ];
        cts_default = None;
      }
  in
  let body = mk (CMatch (cvar "x" ty_int, tree)) ty_int in
  let e = mk (CLet (bind_named "s" ty_string (cstr "hi"), body)) ty_int in
  assert_balanced "match (decision tree) asymmetric" e

let test_int_match_tree_intrinsic_borrowed_leaf () =
  let leaf_a =
    CTLeaf
      {
        ct_bindings = [];
        ct_body = intrinsic "list_len" [ cvar "xs" ty_list_int ] ty_int;
      }
  in
  let leaf_b = CTLeaf { ct_bindings = []; ct_body = cint 0 } in
  let tree =
    CTSwitchTag
      {
        cts_scrut = AccRoot;
        cts_cases = [ ("A", leaf_a); ("B", leaf_b) ];
        cts_default = None;
      }
  in
  let body = mk (CMatch (cvar "tag" ty_int, tree)) ty_int in
  let e =
    mk
      (CLet (bind_named "xs" ty_list_int (mk (clist []) ty_list_int), body))
      ty_int
  in
  assert_balanced "match tree borrowed leaf" e

let test_int_pattern_shadow_in_match () =
  (* let s = "hi" in match opt { Some(s) -> s | None -> 0 }
     — the inner s shadows; the outer s has 0 uses; should get a drop *)
  let arms =
    [
      (PatConstructor ("Some", [ PatVar "s" ]), cvar "s" ty_int);
      (PatConstructor ("None", []), cint 0);
    ]
  in
  let body = mk (CMatchArms (cvar "opt" ty_opt_int, arms)) ty_int in
  let e = mk (CLet (bind_named "s" ty_string (cstr "hi"), body)) ty_int in
  assert_balanced "pattern shadow in match" e

(* ============================================================================
   Test suite
   ============================================================================ *)

let suite =
  [
    ( "simulator",
      [
        Alcotest.test_case "unused_with_drop" `Quick test_sim_unused_with_drop;
        Alcotest.test_case "unused_no_drop_unbalanced" `Quick
          test_sim_unused_no_drop;
        Alcotest.test_case "one_use" `Quick test_sim_one_use;
        Alcotest.test_case "two_uses_no_dup_fails" `Quick
          test_sim_two_uses_no_dup;
        Alcotest.test_case "two_uses_with_dup" `Quick test_sim_two_uses_with_dup;
        Alcotest.test_case "balanced_branches" `Quick test_sim_balanced_branches;
        Alcotest.test_case "branch_imbalance_fails" `Quick
          test_sim_branch_imbalance;
        Alcotest.test_case "branch_excess_drop" `Quick
          test_sim_branch_with_excess_drop;
        Alcotest.test_case "shadow_binding" `Quick test_sim_shadow_binding;
        Alcotest.test_case "intrinsic_borrow_arg" `Quick
          test_sim_intrinsic_borrow_arg;
        Alcotest.test_case "intrinsic_cow_consume_arg" `Quick
          test_sim_intrinsic_cow_consume_arg;
      ] );
    ( "integration",
      [
        Alcotest.test_case "unused_let" `Quick test_int_unused_let;
        Alcotest.test_case "single_use" `Quick test_int_single_use;
        Alcotest.test_case "intrinsic_borrow_arg" `Quick
          test_int_intrinsic_borrow_arg;
        Alcotest.test_case "intrinsic_consume_then_borrow" `Quick
          test_int_intrinsic_consume_then_borrow;
        Alcotest.test_case "two_uses" `Quick test_int_two_uses;
        Alcotest.test_case "three_uses" `Quick test_int_three_uses;
        Alcotest.test_case "if_both_unused" `Quick test_int_if_both_unused;
        Alcotest.test_case "if_asymmetric" `Quick test_int_if_asymmetric;
        Alcotest.test_case "if_intrinsic_borrowed" `Quick
          test_int_if_intrinsic_borrowed_branch;
        Alcotest.test_case "if_symmetric_multi" `Quick
          test_int_if_symmetric_multi;
        Alcotest.test_case "match_asymmetric" `Quick test_int_match_asymmetric;
        Alcotest.test_case "match_all_unused" `Quick test_int_match_all_unused;
        Alcotest.test_case "match_intrinsic_borrowed" `Quick
          test_int_match_intrinsic_borrowed_arm;
        Alcotest.test_case "match_tree_asymmetric" `Quick
          test_int_match_tree_asymmetric;
        Alcotest.test_case "match_tree_intrinsic_borrowed" `Quick
          test_int_match_tree_intrinsic_borrowed_leaf;
        Alcotest.test_case "pattern_shadow" `Quick
          test_int_pattern_shadow_in_match;
      ] );
  ]
