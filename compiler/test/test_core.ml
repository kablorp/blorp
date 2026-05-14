(** Unit tests for the Core IR.

    Phase 1.0 scope: construction, type invariants, traversal helpers,
    pretty-printing. No lowering or emission yet — those are later phases.

    These tests define the API contract for `Blorp.Core`. *)

open Blorp.Ast
open Blorp.Core

(* ============================================================================
   Test helpers
   ============================================================================ *)

let loc =
  { line = 1; column = 1; end_line = 1; end_column = 1; loc_file = None }

let ty_int = TyNamed ("Int", [])
let ty_bool = TyNamed ("Bool", [])
let ty_string = TyNamed ("String", [])
let ty_void = TyNamed ("Void", [])
let ty_list_int = TyNamed ("List", [ ty_int ])
let ty_opt_int = TyNamed ("Option", [ ty_int ])
let str_flags = { sf_triple = false; sf_raw = false }

(** Build a core node with the given desc and type. *)
let mk d t = { desc = d; ty = t; loc }

(* Convenience builders used throughout tests *)
let cint n = mk (CLit (LitInt (Int64.of_int n))) ty_int
let cbool b = mk (CLit (LitBool b)) ty_bool
let cstr s = mk (CLit (LitString (s, str_flags))) ty_string
let cvoid = mk CVoid ty_void
let cvar n t = mk (CVar (Var.named n)) t
let cadd a b = mk (CBin (Add, a, b)) a.ty
let cand a b = mk (CLog (And, a, b)) ty_bool

let clist elems =
  CList { ll_layout = list_pointer_storage (); ll_elems = elems }

(* ============================================================================
   Construction: can we build every variant?
   ============================================================================ *)

let test_construct_lit () =
  let e = cint 42 in
  Alcotest.(check bool)
    "desc" true
    (match e.desc with CLit (LitInt 42L) -> true | _ -> false);
  Alcotest.(check bool) "type is Int" true (e.ty = ty_int)

let test_construct_var () =
  let e = cvar "x" ty_int in
  Alcotest.(check bool)
    "desc" true
    (match e.desc with CVar { vname = "x"; _ } -> true | _ -> false);
  Alcotest.(check bool) "type is Int" true (e.ty = ty_int)

let test_construct_void () =
  let e = cvoid in
  Alcotest.(check bool)
    "desc" true
    (match e.desc with CVoid -> true | _ -> false);
  Alcotest.(check bool) "type is Void" true (e.ty = ty_void)

let test_construct_binary () =
  let e = cadd (cint 1) (cint 2) in
  match e.desc with
  | CBin (Add, l, r) ->
      Alcotest.(check bool) "lhs" true (l.desc = CLit (LitInt 1L));
      Alcotest.(check bool) "rhs" true (r.desc = CLit (LitInt 2L))
  | _ -> Alcotest.fail "expected CBin"

let test_construct_logical () =
  let e = cand (cbool true) (cbool false) in
  match e.desc with
  | CLog (And, _, _) -> ()
  | _ -> Alcotest.fail "expected CLog(And,_,_)"

let test_storage_policy_variants_are_coherent () =
  Alcotest.(check bool)
    "unmanaged bits do not retain" true
    (storage_policy_retain StoragePolicyUnmanagedBits = StorageNoRetain);
  Alcotest.(check bool)
    "unmanaged bits do not release" true
    (storage_policy_release StoragePolicyUnmanagedBits = StorageNoRelease);
  Alcotest.(check bool)
    "managed pointers retain" true
    (storage_policy_retain StoragePolicyManagedPointer = StorageArcRetain);
  Alcotest.(check bool)
    "managed pointers release" true
    (storage_policy_release StoragePolicyManagedPointer = StorageArcRelease);
  Alcotest.(check bool)
    "owned erased boxes release slots without retaining source values" true
    (storage_policy_retain StoragePolicyOwnedErasedBox = StorageNoRetain
    && storage_policy_release StoragePolicyOwnedErasedBox = StorageArcRelease)

let test_storage_policy_requires_release_and_retain () =
  let phase = Blorp.Core_error.Other "storage-policy-test" in
  Alcotest.(check bool)
    "unmanaged bits require no release" false
    (storage_policy_requires_release_or_error ~phase ~loc ~subject:"value"
       ~hint:"test hint" StoragePolicyUnmanagedBits);
  Alcotest.(check bool)
    "managed pointers require release" true
    (storage_policy_requires_release_or_error ~phase ~loc ~subject:"value"
       ~hint:"test hint" StoragePolicyManagedPointer);
  Alcotest.(check bool)
    "owned erased boxes require release" true
    (storage_policy_requires_release_or_error ~phase ~loc ~subject:"value"
       ~hint:"test hint" StoragePolicyOwnedErasedBox);
  Alcotest.(check bool)
    "unmanaged bits require no retain" false
    (storage_policy_requires_retain_or_error ~phase ~loc ~subject:"value"
       ~hint:"test hint" StoragePolicyUnmanagedBits);
  Alcotest.(check bool)
    "managed pointers require retain" true
    (storage_policy_requires_retain_or_error ~phase ~loc ~subject:"value"
       ~hint:"test hint" StoragePolicyManagedPointer);
  Alcotest.(check bool)
    "owned erased boxes do not retain source values" false
    (storage_policy_requires_retain_or_error ~phase ~loc ~subject:"value"
       ~hint:"test hint" StoragePolicyOwnedErasedBox)

let test_storage_policy_unknown_errors_are_centralized () =
  let phase = Blorp.Core_error.Other "storage-policy-test" in
  let unknown = StoragePolicyUnknown "missing descriptor" in
  let expect name expected f =
    match f () with
    | _ -> Alcotest.failf "%s: expected Core_error" name
    | exception Blorp.Core_error.Core_error err ->
        Alcotest.(check bool)
          (name ^ " message") true
          (String.equal err.Blorp.Core_error.msg expected);
        Alcotest.(check (option string))
          (name ^ " hint") (Some "test hint") err.hint
  in
  expect "release" "unknown value release policy: missing descriptor" (fun () ->
      storage_policy_requires_release_or_error ~phase ~loc ~subject:"value"
        ~hint:"test hint" unknown);
  expect "retain" "unknown value retain policy: missing descriptor" (fun () ->
      storage_policy_requires_retain_or_error ~phase ~loc ~subject:"value"
        ~hint:"test hint" unknown)

let test_construct_call () =
  let f =
    cvar "print"
      (TyFunc { params = [ ty_string ]; return = ty_void; is_pure = false })
  in
  let e = mk (CCall (CKUnknown, f, [ cstr "hi" ])) ty_void in
  match e.desc with
  | CCall (_, _, args) -> Alcotest.(check int) "arity" 1 (List.length args)
  | _ -> Alcotest.fail "expected CCall"

let test_construct_if () =
  let e = mk (CIf (cbool true, cint 1, cint 0)) ty_int in
  match e.desc with
  | CIf _ -> Alcotest.(check bool) "type" true (e.ty = ty_int)
  | _ -> Alcotest.fail "expected CIf"

let test_construct_let () =
  (* let x: Int = 10 in x + 1 *)
  let bind =
    {
      bind_var = Var.named "x";
      bind_mut = false;
      bind_ty = ty_int;
      bind_rhs = cint 10;
    }
  in
  let body = cadd (cvar "x" ty_int) (cint 1) in
  let e = mk (CLet (bind, body)) ty_int in
  match e.desc with
  | CLet (b, _) ->
      Alcotest.(check string) "var" "x" b.bind_var.vname;
      Alcotest.(check bool) "immutable" false b.bind_mut
  | _ -> Alcotest.fail "expected CLet"

let test_construct_let_mut () =
  let bind =
    {
      bind_var = Var.named "i";
      bind_mut = true;
      bind_ty = ty_int;
      bind_rhs = cint 0;
    }
  in
  let body = cvar "i" ty_int in
  let e = mk (CLet (bind, body)) ty_int in
  match e.desc with
  | CLet (b, _) -> Alcotest.(check bool) "mutable" true b.bind_mut
  | _ -> Alcotest.fail "expected CLet"

let test_construct_seq () =
  let e = mk (CSeq (cvoid, cint 42)) ty_int in
  match e.desc with
  | CSeq (_, r) ->
      Alcotest.(check bool) "result" true (r.desc = CLit (LitInt 42L))
  | _ -> Alcotest.fail "expected CSeq"

let test_construct_assign () =
  let e = mk (CAssign (Var.named "i", cint 5)) ty_void in
  match e.desc with
  | CAssign ({ vname = "i"; _ }, _) -> ()
  | _ -> Alcotest.fail "expected CAssign"

let test_construct_match_arms () =
  let scrut = cvar "opt" ty_opt_int in
  let arms =
    [
      (PatConstructor ("Some", [ PatVar "x" ]), cvar "x" ty_int);
      (PatConstructor ("None", []), cint 0);
    ]
  in
  let e = mk (CMatchArms (scrut, arms)) ty_int in
  match e.desc with
  | CMatchArms (_, arms') ->
      Alcotest.(check int) "arm count" 2 (List.length arms')
  | _ -> Alcotest.fail "expected CMatchArms"

let test_construct_match () =
  (* Post-match canonical form: CMatch carries a ctree, not pattern arms. *)
  let scrut = cvar "opt" ty_opt_int in
  let leaf = CTLeaf { ct_bindings = []; ct_body = cint 0 } in
  let e = mk (CMatch (scrut, leaf)) ty_int in
  match e.desc with
  | CMatch (_, CTLeaf _) -> ()
  | CMatch _ -> Alcotest.fail "expected CTLeaf tree"
  | _ -> Alcotest.fail "expected CMatch"

let test_construct_tuple () =
  let e =
    mk (CTuple [ cint 1; cint 2; cint 3 ]) (TyTuple [ ty_int; ty_int; ty_int ])
  in
  match e.desc with
  | CTuple xs -> Alcotest.(check int) "size" 3 (List.length xs)
  | _ -> Alcotest.fail "expected CTuple"

let test_construct_list () =
  let e = mk (clist [ cint 1; cint 2 ]) ty_list_int in
  match e.desc with
  | CList lit -> Alcotest.(check int) "size" 2 (List.length lit.ll_elems)
  | _ -> Alcotest.fail "expected CList"

let test_construct_record () =
  let e =
    mk (CRecord [ ("x", cint 1); ("y", cint 2) ]) (TyNamed ("Point", []))
  in
  match e.desc with
  | CRecord fs ->
      Alcotest.(check int) "field count" 2 (List.length fs);
      Alcotest.(check string) "first field" "x" (fst (List.hd fs))
  | _ -> Alcotest.fail "expected CRecord"

let test_construct_field () =
  let p = cvar "p" (TyNamed ("Point", [])) in
  let e = mk (CField (p, "x")) ty_int in
  match e.desc with
  | CField (_, "x") -> ()
  | _ -> Alcotest.fail "expected CField"

let test_construct_lambda () =
  let lam =
    {
      lam_params = [ (Var.named "x", ty_int) ];
      lam_body = cadd (cvar "x" ty_int) (cint 1);
      lam_return_ty = ty_int;
      lam_is_pure = true;
    }
  in
  let fty = TyFunc { params = [ ty_int ]; return = ty_int; is_pure = true } in
  let e = mk (CLambda lam) fty in
  match e.desc with
  | CLambda l ->
      Alcotest.(check int) "params" 1 (List.length l.lam_params);
      Alcotest.(check bool) "pure" true l.lam_is_pure
  | _ -> Alcotest.fail "expected CLambda"

let test_construct_while () =
  let cond = cbool true in
  let body = cvoid in
  let e = mk (CWhile (cond, body)) ty_void in
  match e.desc with CWhile _ -> () | _ -> Alcotest.fail "expected CWhile"

let test_construct_for () =
  let e =
    mk
      (CFor
         ( loop_binder_named "i" ty_int,
           mk (CRange (cint 0, cint 10)) ty_int,
           cvoid ))
      ty_void
  in
  match e.desc with
  | CFor ({ loop_var = { vname = "i"; _ }; loop_ty; _ }, _, _) ->
      Alcotest.(check bool) "binder type" true (loop_ty = ty_int)
  | _ -> Alcotest.fail "expected CFor"

let test_construct_break_continue () =
  let b = mk CBreak ty_void in
  let c = mk CContinue ty_void in
  Alcotest.(check bool) "break" true (b.desc = CBreak);
  Alcotest.(check bool) "continue" true (c.desc = CContinue)

let test_construct_concurrent () =
  (* conc_bindings carries the task specs; conc_body is the tail expression. *)
  let body = mk (CSeq (cint 1, cint 2)) ty_int in
  let blk =
    {
      conc_bindings = [];
      conc_body = body;
      conc_timeout = None;
      conc_max_threads = Some 4;
    }
  in
  let e = mk (CConcurrent blk) ty_void in
  match e.desc with
  | CConcurrent b ->
      Alcotest.(check (option int)) "max threads" (Some 4) b.conc_max_threads
  | _ -> Alcotest.fail "expected CConcurrent"

let test_construct_detach () =
  let e = mk (CDetach { detach_body = cvoid; detach_task = None }) ty_void in
  match e.desc with CDetach _ -> () | _ -> Alcotest.fail "expected CDetach"

let test_construct_record_update () =
  let pt_ty = TyNamed ("Point", []) in
  let base = cvar "p" pt_ty in
  let e = mk (CRecordUpdate (base, [ ("x", cint 10) ])) pt_ty in
  match e.desc with
  | CRecordUpdate (_, fs) -> Alcotest.(check int) "overrides" 1 (List.length fs)
  | _ -> Alcotest.fail "expected CRecordUpdate"

let test_construct_string_interp () =
  let parts = [ IPLit "hello "; IPExpr (cvar "name" ty_string); IPLit "!" ] in
  let e = mk (CStringInterp (parts, false)) ty_string in
  match e.desc with
  | CStringInterp (ps, false) -> Alcotest.(check int) "parts" 3 (List.length ps)
  | _ -> Alcotest.fail "expected CStringInterp"

let test_construct_try () =
  let e = mk (CTry [ cint 1; cint 2 ]) ty_int in
  match e.desc with
  | CTry xs -> Alcotest.(check int) "body len" 2 (List.length xs)
  | _ -> Alcotest.fail "expected CTry"

let test_construct_try_bind () =
  let e =
    mk
      (CTryBind (TKOption, Var.named "x", ty_int, cvar "opt" ty_opt_int))
      ty_int
  in
  match e.desc with
  | CTryBind (TKOption, { vname = "x"; _ }, _, _) -> ()
  | _ -> Alcotest.fail "expected CTryBind"

(* ============================================================================
   CBox: Phase 2.6.3 — carries an explicit source-type annotation so the
   box strategy doesn't depend on the child node's .ty staying correct.
   CUnbox has always had this; CBox is getting symmetric treatment.
   ============================================================================ *)

let ty_float = TyNamed ("Float", [])

let test_construct_cbox_stores_type () =
  (* Boxing a Float-typed value carries Float as its annotation, so a
     downstream pass can pick the correct blorp_box_float dispatch
     without re-deriving it from the child. *)
  let float_val = mk (CLit (LitFloat 3.14)) ty_float in
  let boxed = mk (CBox (float_val, ty_float)) ty_void in
  match boxed.desc with
  | CBox (inner, stored_ty) ->
      Alcotest.(check bool)
        "inner is the float literal" true
        (inner.desc = CLit (LitFloat 3.14));
      Alcotest.(check bool) "stored_ty is Float" true (stored_ty = ty_float)
  | _ -> Alcotest.fail "expected CBox"

let test_cbox_annotation_independent_of_child_ty () =
  (* The annotation is independent of the inner expression's [.ty]. If a
     pass needs to box an already-boxed value under a different source
     type (e.g., a late specialize rewrite), the annotation controls —
     not [.ty]. Covers the Phase 2.6.3 guarantee. *)
  let void_ty = TyNamed ("Void", []) in
  let inner = mk (CLit (LitInt 42L)) void_ty in
  (* weird .ty *)
  let boxed = mk (CBox (inner, ty_int)) void_ty in
  match boxed.desc with
  | CBox (_, stored_ty) ->
      Alcotest.(check bool)
        "stored_ty is Int, not Void" true (stored_ty = ty_int)
  | _ -> Alcotest.fail "expected CBox"

let test_cbox_map_children_preserves_annotation () =
  (* map_children must traverse inner but leave the annotation intact. *)
  let inner = mk (CLit (LitInt 1L)) ty_int in
  let boxed = mk (CBox (inner, ty_int)) (TyNamed ("Void", [])) in
  let mapped = map_children (fun c -> c) boxed in
  match mapped.desc with
  | CBox (_, stored_ty) ->
      Alcotest.(check bool)
        "annotation survives map_children" true (stored_ty = ty_int)
  | _ -> Alcotest.fail "expected CBox"

(* ============================================================================
   Type invariants: every Core node has a concrete type
   ============================================================================ *)

let test_type_is_required () =
  (* Core nodes always have a type. The field is non-optional. This test
     is trivially satisfied by construction — the compiler enforces it. *)
  let e = cint 42 in
  Alcotest.(check bool) "has type" true (e.ty <> TyVar "__nope__")

let test_let_preserves_body_type () =
  let bind =
    {
      bind_var = Var.named "x";
      bind_mut = false;
      bind_ty = ty_int;
      bind_rhs = cint 10;
    }
  in
  let body = cadd (cvar "x" ty_int) (cint 1) in
  let e = mk (CLet (bind, body)) body.ty in
  Alcotest.(check bool) "let type = body type" true (e.ty = body.ty)

(* ============================================================================
   map_children: every pass walks children; this is the traversal primitive
   ============================================================================ *)

let test_map_children_leaf () =
  (* Leaf nodes have no children, so map is identity *)
  let e = cint 42 in
  let e' = map_children (fun c -> mk (CLit (LitInt 999L)) c.ty) e in
  Alcotest.(check bool) "leaf unchanged" true (e'.desc = e.desc)

let test_map_children_binary () =
  let e = cadd (cint 1) (cint 2) in
  (* Replace every child with 99 *)
  let e' = map_children (fun c -> mk (CLit (LitInt 99L)) c.ty) e in
  match e'.desc with
  | CBin (Add, l, r) ->
      Alcotest.(check bool) "lhs replaced" true (l.desc = CLit (LitInt 99L));
      Alcotest.(check bool) "rhs replaced" true (r.desc = CLit (LitInt 99L))
  | _ -> Alcotest.fail "shape changed"

let test_map_children_let () =
  let bind =
    {
      bind_var = Var.named "x";
      bind_mut = false;
      bind_ty = ty_int;
      bind_rhs = cint 10;
    }
  in
  let body = cvar "x" ty_int in
  let e = mk (CLet (bind, body)) ty_int in
  (* Replace every child (rhs and body) *)
  let counter = ref 0 in
  let _ =
    map_children
      (fun c ->
        incr counter;
        c)
      e
  in
  Alcotest.(check int) "2 children (rhs, body)" 2 !counter

let test_map_children_call () =
  let f =
    cvar "f"
      (TyFunc { params = [ ty_int; ty_int ]; return = ty_int; is_pure = true })
  in
  let e = mk (CCall (CKUnknown, f, [ cint 1; cint 2 ])) ty_int in
  let counter = ref 0 in
  let _ =
    map_children
      (fun c ->
        incr counter;
        c)
      e
  in
  (* callee + 2 args *)
  Alcotest.(check int) "3 children (callee + 2 args)" 3 !counter

let test_map_children_match () =
  let scrut = cvar "opt" ty_opt_int in
  let arms =
    [
      (PatConstructor ("Some", [ PatVar "x" ]), cvar "x" ty_int);
      (PatConstructor ("None", []), cint 0);
    ]
  in
  let e = mk (CMatchArms (scrut, arms)) ty_int in
  let counter = ref 0 in
  let _ =
    map_children
      (fun c ->
        incr counter;
        c)
      e
  in
  (* scrutinee + 2 arm bodies *)
  Alcotest.(check int) "3 children (scrut + 2 arms)" 3 !counter

(* ============================================================================
   transform_bottom_up: recursive rewrite primitive for Phase 2 passes
   ============================================================================ *)

(** transform_bottom_up must recurse into grandchildren. *)
let test_transform_bottom_up_recursive () =
  (* ((1 + 2) + 3) — double every literal at any depth *)
  let inner = mk (CBin (Add, cint 1, cint 2)) ty_int in
  let outer = mk (CBin (Add, inner, cint 3)) ty_int in
  let doubled =
    transform_bottom_up
      (fun c ->
        match c.desc with
        | CLit (LitInt n) -> { c with desc = CLit (LitInt (Int64.mul n 2L)) }
        | _ -> c)
      outer
  in
  Alcotest.(check string)
    "recursive rewrite" "((2 + 4) + 6)" (pp_to_string doubled)

(** transform_bottom_up applies [f] AFTER rewriting children. *)
let test_transform_bottom_up_order () =
  (* (1 + 2) — replace each binary op with its literal left side *)
  let e = mk (CBin (Add, cint 99, cint 0)) ty_int in
  let simplified =
    transform_bottom_up
      (fun c -> match c.desc with CBin (_, l, _) -> l | _ -> c)
      e
  in
  Alcotest.(check string) "bottom-up rewrite" "99" (pp_to_string simplified)

(** fold_immediate_children visits only immediate children, not grandchildren. *)
let test_fold_immediate_children () =
  let inner = mk (CBin (Add, cint 1, cint 2)) ty_int in
  let outer = mk (CBin (Add, inner, cint 3)) ty_int in
  let count = fold_immediate_children (fun acc _ -> acc + 1) 0 outer in
  Alcotest.(check int) "2 immediate children" 2 count

(* ============================================================================
   fold_tree: whole-tree fold
   ============================================================================ *)

(** Visits every node including the root. Count test: n-node tree → n. *)
let test_fold_tree_counts_all_nodes () =
  (* ((1 + 2) + 3) — outer CBin + inner CBin + 3 literals = 5 nodes *)
  let inner = mk (CBin (Add, cint 1, cint 2)) ty_int in
  let outer = mk (CBin (Add, inner, cint 3)) ty_int in
  let count = fold_tree (fun acc _ -> acc + 1) 0 outer in
  Alcotest.(check int) "5 total nodes" 5 count

(** Accumulator collects from all depths, not just the root. Visit
    order across sibling children is unspecified (depends on OCaml
    tuple-eval order), so we check the set, not the sequence. *)
let test_fold_tree_collects_from_depth () =
  let inner = mk (CBin (Add, cint 1, cint 2)) ty_int in
  let outer = mk (CBin (Add, inner, cint 3)) ty_int in
  let lits =
    fold_tree
      (fun acc e ->
        match e.desc with CLit (LitInt n) -> Int64.to_int n :: acc | _ -> acc)
      [] outer
  in
  Alcotest.(check (list int))
    "literals from all depths" [ 1; 2; 3 ] (List.sort compare lits)

(** Visits inside CLet bindings AND bodies. *)
let test_fold_tree_visits_let () =
  let bind =
    {
      bind_var = Var.named "x";
      bind_mut = false;
      bind_ty = ty_int;
      bind_rhs = cint 10;
    }
  in
  let body = cadd (cvar "x" ty_int) (cint 1) in
  let e = mk (CLet (bind, body)) ty_int in
  (* root CLet + rhs CLit 10 + body CBin + body CVar + body CLit 1 = 5 *)
  let count = fold_tree (fun acc _ -> acc + 1) 0 e in
  Alcotest.(check int) "5 nodes in let" 5 count

(** fold_tree_bottom_up visits children before parent. *)
let test_fold_tree_bottom_up_order () =
  (* Collect node "kinds" (Lit / Bin) in visit order. Children first
     means both leaves appear before the CBin root. *)
  let e = mk (CBin (Add, cint 1, cint 2)) ty_int in
  let kinds =
    fold_tree_bottom_up
      (fun acc c ->
        let k = match c.desc with CLit _ -> "L" | CBin _ -> "B" | _ -> "?" in
        k :: acc)
      [] e
  in
  (* Reverse so we see the order visits happened *)
  let order = List.rev kinds in
  Alcotest.(check bool)
    "B is last" true
    (List.nth order (List.length order - 1) = "B");
  Alcotest.(check int) "3 visits" 3 (List.length order)

(* ============================================================================
   exists_tree: short-circuiting predicate search
   ============================================================================ *)

(** Returns [true] when the predicate matches somewhere in the tree. *)
let test_exists_tree_finds_match () =
  let inner = mk (CBin (Add, cint 1, cint 42)) ty_int in
  let outer = mk (CBin (Add, inner, cint 3)) ty_int in
  let has_42 =
    exists_tree
      (fun c ->
        match c.desc with CLit (LitInt n) -> Int64.to_int n = 42 | _ -> false)
      outer
  in
  Alcotest.(check bool) "finds 42 deep in tree" true has_42

(** Returns [false] when no node matches. *)
let test_exists_tree_no_match () =
  let e = mk (CBin (Add, cint 1, cint 2)) ty_int in
  let has_999 =
    exists_tree
      (fun c ->
        match c.desc with CLit (LitInt n) -> Int64.to_int n = 999 | _ -> false)
      e
  in
  Alcotest.(check bool) "no 999 in tree" false has_999

(** Short-circuits — stops visiting once the predicate returns true. *)
let test_exists_tree_short_circuits () =
  let e = mk (CBin (Add, cint 1, cint 2)) ty_int in
  let visits = ref 0 in
  let _ =
    exists_tree
      (fun c ->
        incr visits;
        match c.desc with
        | CLit _ -> true (* first Lit we see, return true *)
        | _ -> false)
      e
  in
  (* Root CBin visits once (returns false), then first child is CLit
     which returns true — that's 2 visits. A full walk would be 3. *)
  Alcotest.(check bool) "visits fewer than all nodes" true (!visits < 3)

(* ============================================================================
   transform_with_env: scope-aware transform
   ============================================================================ *)

(** The callback receives the current env and returns (rewritten node,
    env for descendants). Env updates propagate to the subtree. *)
let test_transform_with_env_updates_env () =
  (* A trivial "depth counter" env: increment on every node, write the
     depth onto a dummy field. We can't actually mutate the node, but
     we can count how many CLit nodes see a depth >= 2. *)
  let inner = mk (CBin (Add, cint 1, cint 2)) ty_int in
  let outer = mk (CBin (Add, inner, cint 3)) ty_int in
  let seen_depths = ref [] in
  let _ =
    transform_with_env
      (fun depth e ->
        (match e.desc with
        | CLit _ -> seen_depths := depth :: !seen_depths
        | _ -> ());
        (e, depth + 1))
      0 outer
  in
  (* cint 1, cint 2 are 2 deep; cint 3 is 1 deep *)
  let sorted = List.sort compare !seen_depths in
  Alcotest.(check (list int)) "literal depths" [ 1; 2; 2 ] sorted

(** Match arms get the same env from their parent match. An env
    extended in one arm's callback does not leak into siblings —
    the invariant for scope-tracking passes. *)
let test_transform_with_env_match_arms_independent () =
  let scrut = cint 42 in
  let arm1 = cint 100 in
  let arm2 = cint 200 in
  let arms =
    [ (PatLiteral (LitInt 1L), arm1); (PatLiteral (LitInt 2L), arm2) ]
  in
  let root = mk (CMatchArms (scrut, arms)) ty_int in
  let saw = ref [] in
  let _ =
    transform_with_env
      (fun env e ->
        (match e.desc with
        | CLit (LitInt n) -> saw := (env, Int64.to_int n) :: !saw
        | _ -> ());
        (* Bump env by the literal value we see, so arms would produce
       different envs if they weren't independent. *)
        let new_env =
          match e.desc with CLit (LitInt n) -> env + Int64.to_int n | _ -> env
        in
        (e, new_env))
      0 root
  in
  let pairs = List.sort compare !saw in
  (* Root match at env=0 (not literal). scrut=42 at env=0. arm bodies
     (100, 200) at env=0. Pattern literals aren't [core] nodes, so
     [map_children] doesn't descend into them. *)
  Alcotest.(check (list (pair int int)))
    "all body literals see env=0"
    [ (0, 42); (0, 100); (0, 200) ]
    pairs

(** Env from a CLet's rhs does NOT leak into the body. Each subtree
    starts from the env its parent returned. *)
let test_transform_with_env_branches_independently () =
  (* CBin (Add, left, right): both children get the same env from the
     parent. If `left` updates env, `right` still gets parent's env. *)
  let left = cint 100 in
  let right = cint 200 in
  let root = mk (CBin (Add, left, right)) ty_int in
  let saw = ref [] in
  let _ =
    transform_with_env
      (fun env e ->
        (match e.desc with
        | CLit (LitInt n) -> saw := (env, Int64.to_int n) :: !saw
        | _ -> ());
        (e, env + 1))
      0 root
  in
  (* Root at env=0. Each child gets env=1 (parent returned 1). *)
  let pairs = List.sort compare !saw in
  Alcotest.(check (list (pair int int)))
    "both children see env=1"
    [ (1, 100); (1, 200) ]
    pairs

(* ============================================================================
   Pretty-printer: stable, readable output for debugging and tests
   ============================================================================ *)

let pp_check label expected actual =
  Alcotest.(check string) label expected actual

let test_pp_lit () =
  pp_check "int" "42" (pp_to_string (cint 42));
  pp_check "bool" "true" (pp_to_string (cbool true));
  pp_check "void" "void" (pp_to_string cvoid)

let test_pp_var () = pp_check "simple var" "x" (pp_to_string (cvar "x" ty_int))

let test_pp_binary () =
  pp_check "add" "(1 + 2)" (pp_to_string (cadd (cint 1) (cint 2)))

let test_pp_let () =
  let bind =
    {
      bind_var = Var.named "x";
      bind_mut = false;
      bind_ty = ty_int;
      bind_rhs = cint 10;
    }
  in
  let body = cadd (cvar "x" ty_int) (cint 1) in
  let e = mk (CLet (bind, body)) ty_int in
  pp_check "let" "let x: Int = 10 in (x + 1)" (pp_to_string e)

let test_pp_let_mut () =
  let bind =
    {
      bind_var = Var.named "i";
      bind_mut = true;
      bind_ty = ty_int;
      bind_rhs = cint 0;
    }
  in
  let body = cvar "i" ty_int in
  let e = mk (CLet (bind, body)) ty_int in
  pp_check "var" "var i: Int = 0 in i" (pp_to_string e)

let test_pp_if () =
  let e = mk (CIf (cbool true, cint 1, cint 0)) ty_int in
  pp_check "if" "if true then 1 else 0" (pp_to_string e)

let test_pp_call () =
  let f =
    cvar "print"
      (TyFunc { params = [ ty_string ]; return = ty_void; is_pure = false })
  in
  let e = mk (CCall (CKUnknown, f, [ cstr "hi" ])) ty_void in
  pp_check "call" "print(\"hi\")" (pp_to_string e)

let test_pp_match () =
  let scrut = cvar "opt" ty_opt_int in
  let arms =
    [
      (PatConstructor ("Some", [ PatVar "x" ]), cvar "x" ty_int);
      (PatConstructor ("None", []), cint 0);
    ]
  in
  let e = mk (CMatchArms (scrut, arms)) ty_int in
  pp_check "match-arms" "match-arms opt { Some(x) -> x | None -> 0 }"
    (pp_to_string e)

(* ============================================================================
   Indented pretty-printer
   ============================================================================ *)

let test_pp_indented_leaves () =
  (* Leaves stay flat *)
  Alcotest.(check string) "int" "42" (pp_to_string_indented (cint 42));
  Alcotest.(check string) "var" "x" (pp_to_string_indented (cvar "x" ty_int))

let test_pp_indented_binary_inline () =
  (* Binary ops stay on one line *)
  let e = cadd (cint 1) (cint 2) in
  Alcotest.(check string) "binary inline" "(1 + 2)" (pp_to_string_indented e)

let test_pp_indented_let () =
  (* let x: Int = 10 in (x + 1) *)
  let bind =
    {
      bind_var = Var.named "x";
      bind_mut = false;
      bind_ty = ty_int;
      bind_rhs = cint 10;
    }
  in
  let body = cadd (cvar "x" ty_int) (cint 1) in
  let e = mk (CLet (bind, body)) ty_int in
  Alcotest.(check string)
    "let" "let x: Int = 10 in\n(x + 1)" (pp_to_string_indented e)

let test_pp_indented_nested_let () =
  (* let a: Int = 1 in let b: Int = 2 in (a + b) — two bindings on their own lines *)
  let inner_bind =
    {
      bind_var = Var.named "b";
      bind_mut = false;
      bind_ty = ty_int;
      bind_rhs = cint 2;
    }
  in
  let inner_body = cadd (cvar "a" ty_int) (cvar "b" ty_int) in
  let inner = mk (CLet (inner_bind, inner_body)) ty_int in
  let outer_bind =
    {
      bind_var = Var.named "a";
      bind_mut = false;
      bind_ty = ty_int;
      bind_rhs = cint 1;
    }
  in
  let e = mk (CLet (outer_bind, inner)) ty_int in
  Alcotest.(check string)
    "nested let" "let a: Int = 1 in\nlet b: Int = 2 in\n(a + b)"
    (pp_to_string_indented e)

let test_pp_indented_if () =
  let e = mk (CIf (cbool true, cint 1, cint 0)) ty_int in
  Alcotest.(check string)
    "if/else" "if true then\n  1\nelse\n  0" (pp_to_string_indented e)

let test_pp_indented_match () =
  let scrut = cvar "opt" ty_opt_int in
  let arms =
    [
      (PatConstructor ("Some", [ PatVar "x" ]), cvar "x" ty_int);
      (PatConstructor ("None", []), cint 0);
    ]
  in
  let e = mk (CMatchArms (scrut, arms)) ty_int in
  Alcotest.(check string)
    "match-arms: arms on separate lines"
    "match-arms opt {\n  Some(x) ->\n    x\n  None ->\n    0\n}"
    (pp_to_string_indented e)

let test_pp_indented_seq () =
  let e = mk (CSeq (cint 1, cint 2)) ty_int in
  Alcotest.(check string) "seq" "1\n2" (pp_to_string_indented e)

let test_pp_indented_let_with_if_body () =
  (* Realistic: let x = 10 in if x > 0 then 1 else 0 *)
  let bind =
    {
      bind_var = Var.named "x";
      bind_mut = false;
      bind_ty = ty_int;
      bind_rhs = cint 10;
    }
  in
  let cond = mk (CBin (Gt, cvar "x" ty_int, cint 0)) ty_bool in
  let if_body = mk (CIf (cond, cint 1, cint 0)) ty_int in
  let e = mk (CLet (bind, if_body)) ty_int in
  Alcotest.(check string)
    "let + nested if" "let x: Int = 10 in\nif (x > 0) then\n  1\nelse\n  0"
    (pp_to_string_indented e)

(* ============================================================================
   Build module: ergonomic construction with type/loc inference
   ============================================================================ *)

let test_build_lit_int () =
  let e = Build.lit_int ~loc 42 in
  Alcotest.(check string) "int literal" "42" (pp_to_string e);
  Alcotest.(check bool) "type is Int" true (e.ty = Build.ty_int)

let test_build_add_infers_type () =
  (* Build.add should inherit ty and loc from the lhs *)
  let l = Build.lit_int ~loc 1 in
  let r = Build.lit_int ~loc 2 in
  let e = Build.add l r in
  Alcotest.(check string) "pp" "(1 + 2)" (pp_to_string e);
  Alcotest.(check bool) "ty inherited from lhs" true (e.ty = l.ty);
  Alcotest.(check int) "loc inherited from lhs" l.loc.line e.loc.line

let test_build_cmp_returns_bool () =
  let l = Build.lit_int ~loc 1 in
  let r = Build.lit_int ~loc 2 in
  let e = Build.lt l r in
  Alcotest.(check bool) "lt returns Bool" true (e.ty = Build.ty_bool)

let test_build_let_composition () =
  (* let x: Int = 10 in x + 1 — using Build helpers for the whole chain *)
  let x = Build.var ~loc ~ty:Build.ty_int "x" in
  let rhs = Build.lit_int ~loc 10 in
  let body = Build.add x (Build.lit_int ~loc 1) in
  let e = Build.let_ "x" ~ty:Build.ty_int ~rhs ~body in
  Alcotest.(check string) "let" "let x: Int = 10 in (x + 1)" (pp_to_string e);
  Alcotest.(check bool) "ty inherited from body" true (e.ty = body.ty)

let test_build_if_composition () =
  let e =
    Build.if_ ~cond:(Build.lit_bool ~loc true) ~then_:(Build.lit_int ~loc 1)
      ~else_:(Build.lit_int ~loc 0)
  in
  Alcotest.(check string) "if ternary" "if true then 1 else 0" (pp_to_string e);
  Alcotest.(check bool) "ty inherited from then" true (e.ty = Build.ty_int)

let test_build_seq () =
  let e = Build.seq (Build.lit_int ~loc 1) (Build.lit_int ~loc 2) in
  Alcotest.(check string) "seq" "1; 2" (pp_to_string e)

let test_build_call () =
  let fty =
    TyFunc { params = [ Build.ty_int ]; return = Build.ty_int; is_pure = true }
  in
  let fn = Build.var ~loc ~ty:fty "inc" in
  let e = Build.call fn [ Build.lit_int ~loc 5 ] ~ty:Build.ty_int in
  Alcotest.(check string) "call" "inc(5)" (pp_to_string e)

(* ============================================================================
   Program-level pretty printer
   ============================================================================ *)

let mk_func ~name ~body =
  {
    cf_name = name;
    cf_module = None;
    cf_type_params = [];
    cf_params = [];
    cf_return_ty = ty_int;
    cf_body = Some body;
    cf_is_pure = false;
    cf_kind = CFUser;
    cf_def_id = 0;
  }

let mk_decl d = { cd_desc = d; cd_loc = loc; cd_doc = None }

let test_pp_program_empty () =
  Alcotest.(check string) "empty program" "" (pp_program_indented [])

let test_pp_program_one_func () =
  let body = cadd (cint 1) (cint 2) in
  let f = mk_func ~name:"main" ~body in
  let prog = [ mk_decl (CDFunc f) ] in
  let out = pp_program_indented prog in
  Alcotest.(check bool) "mentions main" true (Blorp.Modules.contains out "main");
  Alcotest.(check bool)
    "mentions body" true
    (Blorp.Modules.contains out "(1 + 2)");
  (* Terminating newline keeps concatenation clean *)
  Alcotest.(check bool)
    "ends with newline" true
    (String.length out > 0 && out.[String.length out - 1] = '\n')

let test_pp_program_mixed_decls () =
  let f = mk_func ~name:"inc" ~body:(cint 1) in
  let var =
    {
      cv_name = Blorp.Core.Var.named "x";
      cv_module = None;
      cv_ty = ty_int;
      cv_init = cint 42;
      cv_is_mutable = false;
      cv_is_const = true;
      cv_def_id = 0;
    }
  in
  let prog = [ mk_decl (CDFunc f); mk_decl (CDVar var) ] in
  let out = pp_program_indented prog in
  Alcotest.(check bool)
    "function present" true
    (Blorp.Modules.contains out "inc");
  Alcotest.(check bool) "global present" true (Blorp.Modules.contains out "x");
  Alcotest.(check bool) "init present" true (Blorp.Modules.contains out "42")

(* ============================================================================
   cf_kind: per-variant construction + pp round-trip (Phase 2.6.4)
   ============================================================================ *)

let mk_kind_func ~name ~kind =
  {
    cf_name = name;
    cf_module = None;
    cf_type_params = [];
    cf_params = [];
    cf_return_ty = ty_int;
    cf_body = Some (cint 0);
    cf_is_pure = true;
    cf_kind = kind;
    cf_def_id = 0;
  }

let test_cf_kind_user_noop_tag () =
  let f = mk_kind_func ~name:"u" ~kind:CFUser in
  let prog = [ mk_decl (CDFunc f) ] in
  let out = pp_program_indented prog in
  (* CFUser should produce no tag decoration *)
  Alcotest.(check bool)
    "no tag" true
    (Blorp.Modules.contains out "pure func u()");
  Alcotest.(check bool)
    "no builtin" false
    (Blorp.Modules.contains out "[builtin]");
  Alcotest.(check bool)
    "no foreign" false
    (Blorp.Modules.contains out "[foreign");
  Alcotest.(check bool)
    "no closure" false
    (Blorp.Modules.contains out "[closure]")

let test_cf_kind_builtin_tag () =
  let f = mk_kind_func ~name:"b" ~kind:CFBuiltin in
  let out = pp_program_indented [ mk_decl (CDFunc f) ] in
  Alcotest.(check bool)
    "builtin tag" true
    (Blorp.Modules.contains out "[builtin]")

let test_cf_kind_foreign_carries_c_name () =
  let k =
    CFForeign
      {
        c_name = "c_printf";
        includes = [ "stdio.h" ];
        link_flags = [ (None, "-lm") ];
        arg_passing = ForeignDefaultArgs [];
      }
  in
  let f = mk_kind_func ~name:"printf" ~kind:k in
  let out = pp_program_indented [ mk_decl (CDFunc f) ] in
  Alcotest.(check bool)
    "foreign tag + c_name" true
    (Blorp.Modules.contains out "[foreign=c_printf]");
  (* Structural: the stored record survived construction *)
  match f.cf_kind with
  | CFForeign { c_name; includes; link_flags; arg_passing } ->
      Alcotest.(check string) "c_name" "c_printf" c_name;
      Alcotest.(check (list string)) "includes" [ "stdio.h" ] includes;
      Alcotest.(check int) "link flags count" 1 (List.length link_flags);
      Alcotest.(check bool)
        "arg passing" true
        (arg_passing = ForeignDefaultArgs [])
  | _ -> Alcotest.fail "expected CFForeign"

let test_cf_kind_closure_body_tag () =
  let ca = { ca_params = []; ca_captures = []; ca_task_abi = false } in
  let f = mk_kind_func ~name:"c" ~kind:(CFClosureBody ca) in
  let out = pp_program_indented [ mk_decl (CDFunc f) ] in
  Alcotest.(check bool)
    "closure tag" true
    (Blorp.Modules.contains out "[closure]")

(* ============================================================================
   Test suite
   ============================================================================ *)

let suite =
  [
    ( "construct",
      [
        Alcotest.test_case "lit" `Quick test_construct_lit;
        Alcotest.test_case "var" `Quick test_construct_var;
        Alcotest.test_case "void" `Quick test_construct_void;
        Alcotest.test_case "binary" `Quick test_construct_binary;
        Alcotest.test_case "logical" `Quick test_construct_logical;
        Alcotest.test_case "storage_policy" `Quick
          test_storage_policy_variants_are_coherent;
        Alcotest.test_case "storage_policy requires" `Quick
          test_storage_policy_requires_release_and_retain;
        Alcotest.test_case "storage_policy unknown errors" `Quick
          test_storage_policy_unknown_errors_are_centralized;
        Alcotest.test_case "call" `Quick test_construct_call;
        Alcotest.test_case "if" `Quick test_construct_if;
        Alcotest.test_case "let" `Quick test_construct_let;
        Alcotest.test_case "let_mut" `Quick test_construct_let_mut;
        Alcotest.test_case "seq" `Quick test_construct_seq;
        Alcotest.test_case "assign" `Quick test_construct_assign;
        Alcotest.test_case "match_arms" `Quick test_construct_match_arms;
        Alcotest.test_case "match" `Quick test_construct_match;
        Alcotest.test_case "tuple" `Quick test_construct_tuple;
        Alcotest.test_case "list" `Quick test_construct_list;
        Alcotest.test_case "record" `Quick test_construct_record;
        Alcotest.test_case "field" `Quick test_construct_field;
        Alcotest.test_case "lambda" `Quick test_construct_lambda;
        Alcotest.test_case "while" `Quick test_construct_while;
        Alcotest.test_case "for" `Quick test_construct_for;
        Alcotest.test_case "break_continue" `Quick test_construct_break_continue;
        Alcotest.test_case "concurrent" `Quick test_construct_concurrent;
        Alcotest.test_case "detach" `Quick test_construct_detach;
        Alcotest.test_case "record_update" `Quick test_construct_record_update;
        Alcotest.test_case "string_interp" `Quick test_construct_string_interp;
        Alcotest.test_case "try" `Quick test_construct_try;
        Alcotest.test_case "try_bind" `Quick test_construct_try_bind;
      ] );
    ( "cbox",
      [
        Alcotest.test_case "stores type" `Quick test_construct_cbox_stores_type;
        Alcotest.test_case "annotation independent" `Quick
          test_cbox_annotation_independent_of_child_ty;
        Alcotest.test_case "map_children preserves" `Quick
          test_cbox_map_children_preserves_annotation;
      ] );
    ( "invariants",
      [
        Alcotest.test_case "type_required" `Quick test_type_is_required;
        Alcotest.test_case "let_body_type" `Quick test_let_preserves_body_type;
      ] );
    ( "map_children",
      [
        Alcotest.test_case "leaf" `Quick test_map_children_leaf;
        Alcotest.test_case "binary" `Quick test_map_children_binary;
        Alcotest.test_case "let" `Quick test_map_children_let;
        Alcotest.test_case "call" `Quick test_map_children_call;
        Alcotest.test_case "match" `Quick test_map_children_match;
      ] );
    ( "transform",
      [
        Alcotest.test_case "bottom_up_recurse" `Quick
          test_transform_bottom_up_recursive;
        Alcotest.test_case "bottom_up_order" `Quick
          test_transform_bottom_up_order;
        Alcotest.test_case "fold_immediate_children" `Quick
          test_fold_immediate_children;
      ] );
    ( "fold_tree",
      [
        Alcotest.test_case "counts all nodes" `Quick
          test_fold_tree_counts_all_nodes;
        Alcotest.test_case "collects from depth" `Quick
          test_fold_tree_collects_from_depth;
        Alcotest.test_case "visits let" `Quick test_fold_tree_visits_let;
        Alcotest.test_case "bottom_up_order" `Quick
          test_fold_tree_bottom_up_order;
      ] );
    ( "exists_tree",
      [
        Alcotest.test_case "finds match" `Quick test_exists_tree_finds_match;
        Alcotest.test_case "no match" `Quick test_exists_tree_no_match;
        Alcotest.test_case "short-circuits" `Quick
          test_exists_tree_short_circuits;
      ] );
    ( "transform_with_env",
      [
        Alcotest.test_case "updates env" `Quick
          test_transform_with_env_updates_env;
        Alcotest.test_case "match arms independent" `Quick
          test_transform_with_env_match_arms_independent;
        Alcotest.test_case "branches independently" `Quick
          test_transform_with_env_branches_independently;
      ] );
    ( "pp",
      [
        Alcotest.test_case "lit" `Quick test_pp_lit;
        Alcotest.test_case "var" `Quick test_pp_var;
        Alcotest.test_case "binary" `Quick test_pp_binary;
        Alcotest.test_case "let" `Quick test_pp_let;
        Alcotest.test_case "let_mut" `Quick test_pp_let_mut;
        Alcotest.test_case "if" `Quick test_pp_if;
        Alcotest.test_case "call" `Quick test_pp_call;
        Alcotest.test_case "match" `Quick test_pp_match;
      ] );
    ( "build",
      [
        Alcotest.test_case "lit_int" `Quick test_build_lit_int;
        Alcotest.test_case "add_infers" `Quick test_build_add_infers_type;
        Alcotest.test_case "cmp_bool" `Quick test_build_cmp_returns_bool;
        Alcotest.test_case "let_compose" `Quick test_build_let_composition;
        Alcotest.test_case "if_compose" `Quick test_build_if_composition;
        Alcotest.test_case "seq" `Quick test_build_seq;
        Alcotest.test_case "call" `Quick test_build_call;
      ] );
    ( "pp_indented",
      [
        Alcotest.test_case "leaves" `Quick test_pp_indented_leaves;
        Alcotest.test_case "binary" `Quick test_pp_indented_binary_inline;
        Alcotest.test_case "let" `Quick test_pp_indented_let;
        Alcotest.test_case "nested_let" `Quick test_pp_indented_nested_let;
        Alcotest.test_case "if" `Quick test_pp_indented_if;
        Alcotest.test_case "match" `Quick test_pp_indented_match;
        Alcotest.test_case "seq" `Quick test_pp_indented_seq;
        Alcotest.test_case "let_with_if" `Quick
          test_pp_indented_let_with_if_body;
      ] );
    ( "pp_program",
      [
        Alcotest.test_case "empty" `Quick test_pp_program_empty;
        Alcotest.test_case "one_func" `Quick test_pp_program_one_func;
        Alcotest.test_case "mixed_decls" `Quick test_pp_program_mixed_decls;
      ] );
    ( "cf_kind",
      [
        Alcotest.test_case "CFUser — no tag" `Quick test_cf_kind_user_noop_tag;
        Alcotest.test_case "CFBuiltin — [builtin]" `Quick
          test_cf_kind_builtin_tag;
        Alcotest.test_case "CFForeign — carries c_name" `Quick
          test_cf_kind_foreign_carries_c_name;
        Alcotest.test_case "CFClosureBody — [closure]" `Quick
          test_cf_kind_closure_body_tag;
      ] );
  ]
