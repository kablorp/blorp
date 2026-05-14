(** Mutable-variable SSA-like renaming pass.

    Converts [var x = e1; x = e2; use(x)] into
    [let x__v0 = e1 in let x__v1 = e2[x→x__v0] in use(x__v1)].

    Each reassignment creates a new immutable version. This turns the
    mutation problem into the immutable-binding problem that Perceus
    Phase 2.1 already solves: each version has a clear last-use point,
    and unused versions get CDrop inserted automatically.

    Blorp's value semantics make this sound: var just means "rebindable
    name", not "mutable container". No two bindings share mutable state.

    {1 Scope}

    This pass handles ONLY straight-line reassignment. Loop-carried
    vars (where the var is reassigned INSIDE a loop body and read
    across iterations) keep their [CAssign] form. Later ownership
    passes stay conservative around those mutable bindings until a
    dedicated loop/control-flow lowering exists.

    This pass runs immediately after [Core_desugar] under the Desugar
    stage hook. [Core_invariants.check_no_desugarable_mutation] enforces
    that no-assignment and straight-line mutable locals are gone at that
    boundary, while control-flow mutation remains explicitly allowed. *)

open Core

(** Version counter migrated to [Session.t] (T1.4 — 2026-04-21).
    Previously module-level [ref 0] reset at [desugar_mut_program]
    entry. *)
let fresh_version base =
  let s = Session.current () in
  let n = s.ssa_mut_counter in
  s.ssa_mut_counter <- n + 1;
  Printf.sprintf "%s__v%d" base n

(** Does a pattern bind a given name? Used by [subst_var] to respect
    pattern-introduced shadowing in match arms. *)
let rec pat_binds (name : string) (pat : Ast.pattern) : bool =
  match pat with
  | PatWildcard | PatLiteral _ -> false
  | PatVar n -> n = name
  | PatConstructor (_, args)
  | PatQualified (_, _, args)
  | PatTuple args
  | PatOr args ->
      List.exists (pat_binds name) args
  | PatList (ps, spread) -> (
      List.exists (pat_binds name) ps
      || match spread with Some p -> pat_binds name p | None -> false)

type assignment_shape = No_assign | Straight_line_assign | Control_flow_assign

let combine_assignment_shape a b =
  match (a, b) with
  | Control_flow_assign, _ | _, Control_flow_assign -> Control_flow_assign
  | Straight_line_assign, _ | _, Straight_line_assign -> Straight_line_assign
  | No_assign, No_assign -> No_assign

let combine_assignment_shapes shapes =
  List.fold_left combine_assignment_shape No_assign shapes

(** Classify assignments to [name] within [e].

    Only direct [CAssign] nodes flowing through [CSeq]/[CLet] are
    straight-line and safe to lower into versioned immutable lets.
    Assignments under control-flow or expression subtrees are deliberately
    classified as [Control_flow_assign] so this pass leaves them alone.

    The classifier is scope-aware: a [CLet], [CFor] binder, lambda param,
    match pattern, or decision-tree binding named [name] shadows the outer
    variable for that body's traversal. *)
let rec classify_assignment_shape (name : string) (e : core) : assignment_shape
    =
  match e.desc with
  | CAssign (v, rhs) ->
      combine_assignment_shape
        (if v.vname = name then Straight_line_assign else No_assign)
        (classify_control_boundary name rhs)
  | CSeq (a, b) ->
      combine_assignment_shape
        (classify_assignment_shape name a)
        (classify_assignment_shape name b)
  | CLet (b, body) ->
      let rhs_shape = classify_assignment_shape name b.bind_rhs in
      if b.bind_var.vname = name then rhs_shape
      else
        combine_assignment_shape rhs_shape (classify_assignment_shape name body)
  | CBorrowLet (b, body) ->
      let rhs_shape = classify_assignment_shape name b.borrow_rhs in
      if b.borrow_var.vname = name then rhs_shape
      else
        combine_assignment_shape rhs_shape (classify_assignment_shape name body)
  | CFor (binder, iter, body) ->
      combine_assignment_shape
        (classify_control_boundary name iter)
        (if binder.loop_var.vname = name then No_assign
         else classify_control_boundary name body)
  | CLambda lam ->
      if List.exists (fun (p, _) -> p.vname = name) lam.lam_params then
        No_assign
      else classify_control_boundary name lam.lam_body
  | CMatchArms (scrut, arms) ->
      let arm_shapes =
        List.map
          (fun (pat, body) ->
            if pat_binds name pat then No_assign
            else classify_control_boundary name body)
          arms
      in
      combine_assignment_shapes
        (classify_control_boundary name scrut :: arm_shapes)
  | CMatch (scrut, tree) ->
      combine_assignment_shape
        (classify_control_boundary name scrut)
        (classify_ctree_control_boundary name tree)
  | CIf (c, t, el) ->
      combine_assignment_shapes
        [
          classify_control_boundary name c;
          classify_control_boundary name t;
          classify_control_boundary name el;
        ]
  | CWhile (cond, body) ->
      combine_assignment_shape
        (classify_control_boundary name cond)
        (classify_control_boundary name body)
  | CConcurrent block ->
      let binding_shapes =
        List.map
          (fun (b : conc_binding) -> classify_control_boundary name b.cb_rhs)
          block.conc_bindings
      in
      let timeout_shapes =
        Option.to_list
          (Option.map (classify_control_boundary name) block.conc_timeout)
      in
      let body_shape =
        if
          List.exists
            (fun (b : conc_binding) -> b.cb_var.vname = name)
            block.conc_bindings
        then No_assign
        else classify_control_boundary name block.conc_body
      in
      combine_assignment_shapes ((body_shape :: timeout_shapes) @ binding_shapes)
  | CConcurrentFor cf ->
      combine_assignment_shapes
        [
          classify_control_boundary name cf.cf_iter;
          (if cf.cf_var.vname = name then No_assign
           else classify_control_boundary name cf.cf_body);
          Option.value
            (Option.map (classify_control_boundary name) cf.cf_timeout)
            ~default:No_assign;
        ]
  | CDetach detach -> classify_control_boundary name detach.detach_body
  | CTry body ->
      combine_assignment_shapes (List.map (classify_control_boundary name) body)
  | CTryBind (_, v, _, rhs) ->
      if v.vname = name then No_assign else classify_control_boundary name rhs
  | _ ->
      Core.fold_immediate_children
        (fun acc child ->
          combine_assignment_shape acc (classify_control_boundary name child))
        No_assign e

and classify_control_boundary (name : string) (e : core) : assignment_shape =
  match classify_assignment_shape name e with
  | No_assign -> No_assign
  | Straight_line_assign | Control_flow_assign -> Control_flow_assign

and classify_ctree_control_boundary (name : string) (tree : ctree) :
    assignment_shape =
  match tree with
  | CTLeaf { ct_bindings; ct_body } ->
      if List.exists (fun (v, _) -> v.vname = name) ct_bindings then No_assign
      else classify_control_boundary name ct_body
  | CTFail -> No_assign
  | CTSwitchTag { cts_cases; cts_default; _ } ->
      combine_assignment_shapes
        (List.map
           (fun (_, sub) -> classify_ctree_control_boundary name sub)
           cts_cases
        @ Option.to_list
            (Option.map (classify_ctree_control_boundary name) cts_default))
  | CTSwitchLit { ctl_cases; ctl_default; _ } ->
      combine_assignment_shapes
        (classify_ctree_control_boundary name ctl_default
        :: List.map
             (fun (_, sub) -> classify_ctree_control_boundary name sub)
             ctl_cases)
  | CTSwitchLen { ctl_len_cases; ctl_len_geq; ctl_len_default; _ } ->
      combine_assignment_shapes
        (List.map
           (fun (_, sub) -> classify_ctree_control_boundary name sub)
           ctl_len_cases
        @ Option.to_list
            (Option.map
               (fun (_, sub) -> classify_ctree_control_boundary name sub)
               ctl_len_geq)
        @ Option.to_list
            (Option.map (classify_ctree_control_boundary name) ctl_len_default)
        )

(** Substitute all [CVar name] references with [CVar new_name] in [e].
    Respects shadowing: stops renaming in scopes where [name] is
    rebound by a CLet, CFor, CLambda param, or match-arm pattern.

    Deliberately hand-rolled (not [transform_with_env]): the semantics
    needs per-variant shadowing rules (CLet shadows body but not rhs,
    match arms shadow when the pattern binds), which don't map cleanly
    onto a single "env threading" helper. Conversion would either
    duplicate variant-specific logic or lose precision. *)
let rec subst_var (old_name : string) (new_var : var) (e : core) : core =
  match e.desc with
  | CVar v when v.vname = old_name -> { e with desc = CVar new_var }
  | CLet (b, body) when b.bind_var.vname = old_name ->
      (* Inner binding shadows — don't rename in body, but DO rename in RHS *)
      {
        e with
        desc =
          CLet
            ({ b with bind_rhs = subst_var old_name new_var b.bind_rhs }, body);
      }
  | CBorrowLet (b, body) when b.borrow_var.vname = old_name ->
      {
        e with
        desc =
          CBorrowLet
            ( { b with borrow_rhs = subst_var old_name new_var b.borrow_rhs },
              body );
      }
  | CFor (binder, iter, body) when binder.loop_var.vname = old_name ->
      { e with desc = CFor (binder, subst_var old_name new_var iter, body) }
  | CLambda lam
    when List.exists (fun (p, _) -> p.vname = old_name) lam.lam_params ->
      e (* lambda param shadows *)
  | CMatchArms (scrut, arms) ->
      let scrut' = subst_var old_name new_var scrut in
      let arms' =
        List.map
          (fun (pat, body) ->
            if pat_binds old_name pat then (pat, body) (* pattern shadows *)
            else (pat, subst_var old_name new_var body))
          arms
      in
      { e with desc = CMatchArms (scrut', arms') }
  | CMatch (scrut, tree) ->
      (* Decision trees: bindings are in CTLeaf.ct_bindings. The
         existing tree structure doesn't use pattern names directly —
         bindings are (var, accessor) pairs. Substitute in scrut and
         let map_children handle the tree bodies. *)
      let scrut' = subst_var old_name new_var scrut in
      let tree' = subst_var_ctree old_name new_var tree in
      { e with desc = CMatch (scrut', tree') }
  | _ -> Core.map_children (subst_var old_name new_var) e

and subst_var_ctree (old_name : string) (new_var : var) (tree : ctree) : ctree =
  match tree with
  | CTLeaf { ct_bindings; ct_body } ->
      if List.exists (fun (v, _) -> v.vname = old_name) ct_bindings then tree
        (* binding shadows *)
      else CTLeaf { ct_bindings; ct_body = subst_var old_name new_var ct_body }
  | CTFail -> CTFail
  | CTSwitchTag { cts_scrut; cts_cases; cts_default } ->
      CTSwitchTag
        {
          cts_scrut;
          cts_cases =
            List.map
              (fun (n, sub) -> (n, subst_var_ctree old_name new_var sub))
              cts_cases;
          cts_default =
            Option.map (subst_var_ctree old_name new_var) cts_default;
        }
  | CTSwitchLit { ctl_scrut; ctl_cases; ctl_default } ->
      CTSwitchLit
        {
          ctl_scrut;
          ctl_cases =
            List.map
              (fun (l, sub) -> (l, subst_var_ctree old_name new_var sub))
              ctl_cases;
          ctl_default = subst_var_ctree old_name new_var ctl_default;
        }
  | CTSwitchLen { ctl_len_scrut; ctl_len_cases; ctl_len_geq; ctl_len_default }
    ->
      CTSwitchLen
        {
          ctl_len_scrut;
          ctl_len_cases =
            List.map
              (fun (n, sub) -> (n, subst_var_ctree old_name new_var sub))
              ctl_len_cases;
          ctl_len_geq =
            Option.map
              (fun (n, sub) -> (n, subst_var_ctree old_name new_var sub))
              ctl_len_geq;
          ctl_len_default =
            Option.map (subst_var_ctree old_name new_var) ctl_len_default;
        }

(** Desugar straight-line reassignments of [var_name].
    Only handles [CSeq(CAssign(var, rhs), rest)] at the top level.
    Does NOT descend into control flow (CWhile, CFor, CIf, CMatchArms/CMatch) —
    reassignments inside branches/loops keep their CAssign form.
    For those cases, just substitutes references to [current_ver]. *)
let rec desugar_mut_body (var_name : string) (current_ver : var)
    (ty : Ast.type_expr) (e : core) : core =
  match e.desc with
  | CSeq (a, b) -> (
      match a.desc with
      | CAssign (v, rhs) when v.vname = var_name ->
          (* x = rhs; rest → let x_N = rhs[x→x_prev] in rest
              Don't subst_var the entire rest — the recursive call
              handles renaming with the new version as current. *)
          let rhs' = subst_var var_name current_ver rhs in
          let new_name = fresh_version var_name in
          let new_var = Core.Var.named new_name in
          let b'' = desugar_mut_body var_name new_var ty b in
          let bind =
            {
              Core.bind_var = new_var;
              bind_mut = false;
              bind_ty = ty;
              bind_rhs = rhs';
            }
          in
          { e with desc = CLet (bind, b'') }
      | _ ->
          (* Non-assignment head: just substitute and continue *)
          let a' = subst_var var_name current_ver a in
          let b' = desugar_mut_body var_name current_ver ty b in
          { e with desc = CSeq (a', b') })
  | CLet (b, body) when b.bind_var.vname = var_name ->
      let rhs' = subst_var var_name current_ver b.bind_rhs in
      { e with desc = CLet ({ b with bind_rhs = rhs' }, body) }
  | CBorrowLet (b, body) when b.borrow_var.vname = var_name ->
      let rhs' = subst_var var_name current_ver b.borrow_rhs in
      { e with desc = CBorrowLet ({ b with borrow_rhs = rhs' }, body) }
  | CLet (b, body) ->
      let rhs' = subst_var var_name current_ver b.bind_rhs in
      let body' = desugar_mut_body var_name current_ver ty body in
      { e with desc = CLet ({ b with bind_rhs = rhs' }, body') }
  | CBorrowLet (b, body) ->
      let rhs' = subst_var var_name current_ver b.borrow_rhs in
      let body' = desugar_mut_body var_name current_ver ty body in
      { e with desc = CBorrowLet ({ b with borrow_rhs = rhs' }, body') }
  | _ ->
      (* Control flow, terminals, etc.: just substitute references *)
      subst_var var_name current_ver e

(** Top-level mutable var desugaring.

    For each [CLet({bind_mut = true}, body)]:
    - If the body has no CAssign to this var: just flip bind_mut to false.
    - If the body has CAssign(s): desugar into SSA-like let-chain.

    Only handles straight-line reassignment for now. Loop-carried vars
    (where the var is reassigned INSIDE a loop body and read across
    iterations) keep their CAssign form — Perceus will need separate
    handling for those. *)
let desugar_mut_vars (e : core) : core =
  Core.transform_bottom_up
    (fun node ->
      match node.desc with
      | CLet (b, body) when b.bind_mut -> (
          match classify_assignment_shape b.bind_var.vname body with
          | No_assign ->
              (* No reassignment — just mark as immutable *)
              { node with desc = CLet ({ b with bind_mut = false }, body) }
          | Control_flow_assign ->
              (* Assignments inside control flow — can't desugar safely *)
              node
          | Straight_line_assign ->
              (* All assignments in straight-line — SSA rename *)
              let init_name = fresh_version b.bind_var.vname in
              let init_var = Core.Var.named init_name in
              let body' =
                desugar_mut_body b.bind_var.vname init_var b.bind_ty body
              in
              let new_bind = { b with bind_var = init_var; bind_mut = false } in
              { node with desc = CLet (new_bind, body') })
      | _ -> node)
    e

(** Desugar mutable vars in a function body. *)
let desugar_mut_func (f : core_func) : core_func =
  match f.cf_body with
  | None -> f
  | Some body -> { f with cf_body = Some (desugar_mut_vars body) }

(** Desugar mutable vars in a single declaration. *)
let rec desugar_mut_decl (d : core_decl) : core_decl =
  let desc' =
    match d.cd_desc with
    | CDFunc f -> CDFunc (desugar_mut_func f)
    | CDVar v -> CDVar { v with cv_init = desugar_mut_vars v.cv_init }
    | CDImpl i ->
        CDImpl { i with ci_methods = List.map desugar_mut_func i.ci_methods }
    | CDTrait _ as other -> other (* no expressions; defaults live on AST *)
    | CDPrivate inner -> CDPrivate (desugar_mut_decl inner)
    | (CDType _ | CDRecord _ | CDImport _ | CDTypeAlias _) as other -> other
  in
  { d with cd_desc = desc' }

(** Desugar mutable vars in a whole program. Counter reset moved to
    [Core_pipeline] — see [Session.reset_core_counters]. *)
let desugar_mut_program (prog : core_program) : core_program =
  List.map desugar_mut_decl prog
