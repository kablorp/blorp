(** Refcount-balance simulator for Perceus-generated Core IR.

    Structural tests ([test_core_perceus.ml]) assert the shape of the
    output ([CLet(_, CDrop(s, ...))], etc.). They do NOT verify that
    the refcounts actually balance — a shape-correct transformation
    can still produce wrong RC if the drops/dups are at the wrong
    points or the count is off by one.

    This module provides a symbolic simulator: walk a Core expression
    tracking the refcount of a {b single target variable}, and report
    whether the refcount returns to 0 (balanced) or not. It handles:

    - [CDup]: increment
    - [CDrop]: decrement (must not go negative)
    - [CVar target]: one consume
    - [CLet]: recurse into body with the binding in scope; the
      binding shadows if its name matches the target (skip body)
    - Branches ([CIf], [CMatchArms], [CMatch]): both / all paths
      must end at the same refcount; otherwise the program is
      unbalanced
    - [CLambda]: capture counts as 1 consume at closure construction
      (matches [count_uses] semantics)

    The simulator only tracks ONE variable at a time — it's for
    verifying a specific let-bound name balances. To check a whole
    program, run it per binding in a loop.

    {1 Limitations}

    - Doesn't model [CAssign] semantics beyond skipping the LHS.
    - Treats every [CVar target] as a consume (matching Perceus's
      "every use consumes" assumption).
    - Doesn't simulate side effects for concurrency/detach forms; those fall
      through conservatively.
    - Doesn't validate that the scrutinee type of a match is
      actually a union / that the patterns exhaustive-match — those
      are upstream concerns. *)

open Core

type state = { mutable rc : int; mutable errors : string list }
(** A single-variable refcount state. *)

let make_state () = { rc = 1; errors = [] }
let fail_msg state msg = state.errors <- msg :: state.errors

(** Simulate running [e] with [target] having its current refcount.
    Updates [state.rc] in place. Accumulates errors on drops going
    negative, branch imbalance, etc.

    Linear simulation: [CLet] descends into rhs and body; shadowing
    is respected. Branches fork and require matching exit rc. *)
let rec simulate (target : string) (state : state) (e : core) : unit =
  match e.desc with
  (* ---- Leaves / non-references ---- *)
  | CLit _ | CVoid | CBreak | CContinue -> ()
  (* ---- Variable reference: if it's our target, consume one ref ---- *)
  | CVar v ->
      if v.vname = target then
        begin if state.rc < 1 then
          fail_msg state
            (Printf.sprintf "use of %s with refcount %d (underflow)" target
               state.rc)
        else state.rc <- state.rc - 1
        end
  (* ---- RC ops ---- *)
  | CDup (v, _, body) ->
      if v.vname = target then state.rc <- state.rc + 1;
      simulate target state body
  | CDrop (v, _, body) ->
      if v.vname = target then begin
        if state.rc < 1 then
          fail_msg state
            (Printf.sprintf "drop of %s with refcount %d (underflow)" target
               state.rc);
        state.rc <- state.rc - 1
      end;
      simulate target state body
  (* ---- Operators: visit children in order ---- *)
  | CBin (_, l, r) | CLog (_, l, r) | CRange (l, r) | CSeq (l, r) ->
      simulate target state l;
      simulate target state r
  | CUn (_, x) -> simulate target state x
  | CCall (kind, fn, args) -> simulate_call target state kind fn args
  | CTensorRawRead r -> simulate target state r.trr_index
  | CTensorRawWrite w ->
      simulate target state w.trw_index;
      simulate target state w.trw_value
  | CField (o, _) -> simulate target state o
  (* ---- Data construction ---- *)
  | CTuple xs | CVector xs -> List.iter (simulate target state) xs
  | CTupleConstruct tc ->
      List.iter (simulate_boxed_storage target state) tc.tc_elems
  | CList lit -> List.iter (simulate target state) lit.ll_elems
  | CListConstruct lc ->
      List.iter (simulate_boxed_storage target state) lc.lc_elems
  | CListAlloc alloc -> simulate target state alloc.la_capacity
  | CListGet get ->
      simulate_borrow target state get.lg_list;
      simulate target state get.lg_index
  | CStringByteRead r ->
      simulate_borrow target state r.sbr_source;
      simulate target state r.sbr_index
  | CStringByteWrite w ->
      simulate_borrow target state w.sbw_target;
      simulate target state w.sbw_index;
      simulate target state w.sbw_byte
  | CStringByteCopy c ->
      simulate_borrow target state c.sbc_dst;
      simulate target state c.sbc_dst_pos;
      simulate_borrow target state c.sbc_src;
      simulate target state c.sbc_src_pos;
      simulate target state c.sbc_len
  | CStringSetLen s ->
      simulate_borrow target state s.ssl_target;
      simulate target state s.ssl_len
  | CDict kvs ->
      List.iter
        (fun (k, v) ->
          simulate target state k;
          simulate target state v)
        kvs
  | CDictConstruct dc ->
      List.iter
        (fun (k, v) ->
          simulate_boxed_storage target state k;
          simulate_boxed_storage target state v)
        dc.dc_entries
  | CSetAlloc _ -> ()
  | CRecord fs -> List.iter (fun (_, v) -> simulate target state v) fs
  | CRecordConstruct rc ->
      List.iter
        (function
          | RecordRawField (_, v) -> simulate target state v
          | RecordErasedField (_, v) -> simulate_boxed_storage target state v)
        rc.rc_fields
  | CTensorLiteral tl -> (
      match tl.tl_payload with
      | TensorRawElements (_, elems) -> List.iter (simulate target state) elems
      | TensorWordElements elems -> List.iter (simulate target state) elems
      | TensorPackedElements (_, elems) ->
          List.iter (simulate target state) elems
      | TensorInlineStructElements (_, elems) ->
          List.iter (simulate target state) elems
      | TensorBoxedElements elems ->
          List.iter (simulate_boxed_storage target state) elems)
  | CUnionConstruct uc ->
      List.iter (simulate_boxed_storage target state) uc.uc_args
  | CRecordUpdate (b, fs) ->
      simulate target state b;
      List.iter (fun (_, v) -> simulate target state v) fs
  | CStringInterp (parts, _) ->
      List.iter
        (function IPLit _ -> () | IPExpr e -> simulate target state e)
        parts
  (* ---- Let binding: shadow if name matches, otherwise descend ---- *)
  | CLet (b, body) ->
      simulate target state b.bind_rhs;
      if b.bind_var.vname = target then
        (* Shadow — body can't see outer target *)
        ()
      else simulate target state body
  | CBorrowLet (b, body) ->
      simulate target state b.borrow_rhs;
      if b.borrow_var.vname <> target then simulate target state body
  | CTensorRawViewLet (b, body) ->
      simulate_borrow target state b.trv_source;
      if b.trv_var.vname <> target then simulate target state body
  (* ---- Branches: run both / all paths from the same starting rc,
         require matching exit rc ---- *)
  | CIf (c, t, el) ->
      simulate target state c;
      simulate_branches target state [ t; el ]
  | CMatchArms (scrut, arms) ->
      simulate target state scrut;
      let bodies =
        List.filter_map
          (fun (pat, body) ->
            (* Arms whose pattern binds target are shadowed — skip them *)
            if pattern_binds_ target pat then None else Some body)
          arms
      in
      simulate_branches target state bodies
  | CMatch (scrut, tree) ->
      simulate target state scrut;
      let leaves = collect_tree_leaves target tree in
      simulate_branches target state leaves
  (* ---- Loops: conservatively skip — loops are per-iteration RC
         and don't fit the simple one-variable model well. *)
  | CWhile _ | CFor _ | CTailrecLoop _ -> ()
  | CTailrecRecur (TailrecRecur r) ->
      List.iter (simulate target state) r.tr_args
  | CTailrecRecur (TailrecListSpreadRecur r) ->
      List.iter (fun (_, arg) -> simulate target state arg) r.tr_rebinds
  (* ---- Assignment: rhs runs, target LHS is a write (not counted) ---- *)
  | CAssign (_, rhs) -> simulate target state rhs
  (* ---- Lambda: free capture of target = one consume at construction ---- *)
  | CLambda lam ->
      if List.exists (fun (v, _) -> v.vname = target) lam.lam_params then ()
      else if uses_free target lam.lam_body then
        begin if state.rc < 1 then
          fail_msg state
            (Printf.sprintf "lambda capture of %s with refcount %d" target
               state.rc)
        else state.rc <- state.rc - 1
        end
  (* ---- Concurrency / closures: conservative pass-through ---- *)
  | CClosureCreate cc ->
      (* Each capture consumes 1 ref *)
      if List.exists (fun (n, _) -> n = target) cc.cc_captures then
        begin if state.rc < 1 then
          fail_msg state
            (Printf.sprintf "closure capture of %s with refcount %d" target
               state.rc)
        else state.rc <- state.rc - 1
        end
  | CConcurrent _ | CConcurrentFor _ | CDetach _ -> ()
  | CDebugBlock body -> simulate target state body
  | CListHandoff h ->
      (match h.lh_mode with
      | BorrowFresh -> simulate_borrow target state h.lh_source
      | ConsumeReuse -> simulate target state h.lh_source);
      simulate target state h.lh_capacity;
      if
        h.lh_source_var.vname <> target
        && h.lh_result_var.vname <> target
        && h.lh_len_var.vname <> target
        && h.lh_out_var.vname <> target
      then simulate target state h.lh_body
  (* Representation wrappers read their source without consuming the caller's
     ownership. CBox may create/retain a raw storage value, but that owned raw
     result is distinct from the source variable modeled here. *)
  | CCast (x, _) | CUnbox (x, _) | CBox (x, _) -> simulate_borrow target state x
  | CUnboxTyped u -> simulate_borrow target state u.unbox_value
  | CBoxTyped b -> simulate_borrow target state b.box_value

and simulate_boxed_storage target state value =
  simulate target state value.bsv_box.box_value

(** Simulate a call. Known intrinsic / builtin calls use the explicit
    ownership ABI from [Core_ownership]. Unknown calls keep the historical
    conservative behavior: evaluate the callee and every argument as a
    consuming expression. *)
and simulate_call (target : string) (state : state) (kind : call_kind)
    (fn : core) (args : core list) : unit =
  match
    Core_ownership.contract_for_call_kind kind ~arg_count:(List.length args)
  with
  | None ->
      simulate target state fn;
      List.iter (simulate target state) args
  | Some contract -> List.iter2 (simulate_arg target state) contract.args args

(** Simulate an argument according to the callee's ownership demand. A borrowed
    direct variable or field read does not consume the owner; retained
    arguments are also caller-owned. Consumed, COW-consumed, and transferred
    arguments do consume the owner. *)
and simulate_arg (target : string) (state : state)
    (mode : Core_ownership.arg_mode) (arg : core) : unit =
  if Core_ownership.arg_consumes_caller mode then simulate target state arg
  else simulate_borrow target state arg

(** Borrowed expression evaluation. This is deliberately narrow: it models the
    common and important cases for ownership contracts (direct variable and
    field reads) while preserving normal simulation for compound expressions. *)
and simulate_borrow (target : string) (state : state) (e : core) : unit =
  match e.desc with
  | CVar v when v.vname = target -> ()
  | CField (owner, _) -> simulate_borrow target state owner
  | CCast (inner, _) | CUnbox (inner, _) | CBox (inner, _) ->
      simulate_borrow target state inner
  | _ -> simulate target state e

(** Run a set of branches from the current rc; require all branches to
    end at the same rc. Mutates [state] to the common exit rc. *)
and simulate_branches (target : string) (state : state) (branches : core list) :
    unit =
  match branches with
  | [] -> ()
  | [ single ] -> simulate target state single
  | first :: rest ->
      let start_rc = state.rc in
      simulate target state first;
      let exit_rc = state.rc in
      List.iter
        (fun branch ->
          state.rc <- start_rc;
          simulate target state branch;
          if state.rc <> exit_rc then
            fail_msg state
              (Printf.sprintf "branch imbalance for %s: %d vs %d" target
                 state.rc exit_rc))
        rest;
      state.rc <- exit_rc

(** Does [pat] introduce a binding with [name]? (Duplicated locally
    to avoid a cross-module dependency.) *)
and pattern_binds_ (name : string) (pat : Ast.pattern) : bool =
  match pat with
  | PatWildcard | PatLiteral _ -> false
  | PatVar n -> n = name
  | PatConstructor (_, args) | PatQualified (_, _, args) ->
      List.exists (pattern_binds_ name) args
  | PatTuple ps | PatOr ps -> List.exists (pattern_binds_ name) ps
  | PatList (ps, spread) -> (
      List.exists (pattern_binds_ name) ps
      || match spread with Some p -> pattern_binds_ name p | None -> false)

(** Collect all leaf bodies from a [ctree], skipping leaves that
    shadow [target] via [ct_bindings]. *)
and collect_tree_leaves (target : string) (tree : ctree) : core list =
  match tree with
  | CTLeaf { ct_bindings; ct_body } ->
      if List.exists (fun (v, _) -> v.vname = target) ct_bindings then []
      else [ ct_body ]
  | CTFail -> []
  | CTSwitchTag { cts_cases; cts_default; _ } ->
      let cases =
        List.concat_map
          (fun (_, sub) -> collect_tree_leaves target sub)
          cts_cases
      in
      let default =
        match cts_default with
        | Some d -> collect_tree_leaves target d
        | None -> []
      in
      cases @ default
  | CTSwitchLit { ctl_cases; ctl_default; _ } ->
      let cases =
        List.concat_map
          (fun (_, sub) -> collect_tree_leaves target sub)
          ctl_cases
      in
      cases @ collect_tree_leaves target ctl_default
  | CTSwitchLen { ctl_len_cases; ctl_len_geq; ctl_len_default; _ } ->
      let cases =
        List.concat_map
          (fun (_, sub) -> collect_tree_leaves target sub)
          ctl_len_cases
      in
      let geq =
        match ctl_len_geq with
        | Some (_, sub) -> collect_tree_leaves target sub
        | None -> []
      in
      let default =
        match ctl_len_default with
        | Some d -> collect_tree_leaves target d
        | None -> []
      in
      cases @ geq @ default

(** Does any free occurrence of [name] appear in [e]? Used only by
    the [CLambda] case of [simulate] to decide whether a capture
    happens. *)
and uses_free (name : string) (e : core) : bool =
  match e.desc with
  | CVar v -> v.vname = name
  | CLit _ | CVoid | CBreak | CContinue -> false
  | CLet (b, body) ->
      uses_free name b.bind_rhs
      || (b.bind_var.vname <> name && uses_free name body)
  | CBorrowLet (b, body) ->
      uses_free name b.borrow_rhs
      || (b.borrow_var.vname <> name && uses_free name body)
  | CLambda lam ->
      (not (List.exists (fun (v, _) -> v.vname = name) lam.lam_params))
      && uses_free name lam.lam_body
  | _ ->
      let found = ref false in
      let _ =
        map_children
          (fun c ->
            if uses_free name c then found := true;
            c)
          e
      in
      !found

(* ============================================================================
   Public API
   ============================================================================ *)

type result =
  | Balanced
  | Unbalanced of { final_rc : int; errors : string list }

(** Check that a given [target] variable's refcount balances over
    [e]. Assumes the target starts at refcount 1 (just after its
    [CLet] binding). Returns [Balanced] if the refcount returns to
    exactly 0 with no intermediate errors. *)
let check_balance (target : string) (e : core) : result =
  let state = make_state () in
  simulate target state e;
  if state.rc = 0 && state.errors = [] then Balanced
  else Unbalanced { final_rc = state.rc; errors = List.rev state.errors }

(** Check that a [CLet]'s body produces a balanced refcount for the
    bound name. This is the common test invocation:

    {[
      let transformed =
        Core_perceus.insert_drops_expr_with_env
          (Core_perceus.empty_env ())
          expr
      in
      match Core_perceus_check.check_let_balance transformed with
      | Balanced -> () (* pass *)
      | Unbalanced { final_rc; errors } -> ... (* fail test *)
    ]} *)
let check_let_balance (e : core) : result =
  match e.desc with
  | CLet (b, body) -> check_balance b.bind_var.vname body
  | _ -> Unbalanced { final_rc = -1; errors = [ "expected CLet at root" ] }
