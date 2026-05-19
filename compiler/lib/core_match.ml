(** Match compilation: rewrite [CMatchArms] into [CMatch] (decision
    tree) using Maranget-style construction.

    This is the Phase 2 prerequisite compiler-expert flagged as C3:
    every Perceus-style RC pass needs to walk pattern matches, and
    doing that on raw [Ast.pattern] forces each pass to re-implement
    constructor-shape logic. By compiling to a decision tree first,
    subsequent passes see a clean [ctree] with explicit:
    - runtime tests ([CTSwitchTag], [CTSwitchLit])
    - explicit variable bindings via [accessor] paths
    - a single leaf per matched row

    The compiler handles the pattern forms exposed by the source
    language today:

    - A single catch-all arm ([PatVar] or [PatWildcard]) → [CTLeaf].
    - All arms are [PatLiteral] (optionally followed by one catch-all)
      → [CTSwitchLit].
    - [PatConstructor] / [PatQualified] arms, including nested
      constructor, tuple, literal, and list sub-patterns → [CTSwitchTag].
    - [PatTuple] arms → column-split decision trees.
    - [PatList] arms → ordered length/payload-test chains.

    [PatOr] arms are expanded before classification: [PatOr [p1; p2], body]
    becomes [(p1, body); (p2, body)] so the expanded arms classify normally.

    A source-level shape that reaches [AKUnsupported] leaves the original
    [CMatchArms] in the Core program. There is no raw-match emitter:
    [Core_invariants.check_no_cmatcharms] fires at the Match stage and
    [Core_emit] raises [Core_error.Emit] if a [CMatchArms] reaches it. A
    fallthrough means [classify_arms]/[compile_arms] needs the missing arm
    shape.

    {1 Non-goals (current)}

    - Full column-matrix Maranget with heuristics.
    - Exhaustiveness check (assumed verified upstream). *)

open Ast
open Core

(* ============================================================================
   Constructor name normalization
   ============================================================================ *)

(** Collect all constructor names from a program's type declarations. *)
let collect_constructor_names (prog : core_program) : (string, unit) Hashtbl.t =
  let names = Hashtbl.create 32 in
  (* Builtin constructors not in CDType declarations *)
  List.iter
    (fun n -> Hashtbl.replace names n ())
    [
      "Some";
      "None";
      "Ok";
      "Err";
      "True";
      "False";
      "Timeout";
      "TaskFailed";
      "Cancelled";
    ];
  let rec visit d =
    match d.cd_desc with
    | CDType t ->
        List.iter
          (fun (v : variant) -> Hashtbl.replace names v.variant_name ())
          t.type_variants
    | CDPrivate inner -> visit inner
    | _ -> ()
  in
  List.iter visit prog;
  names

(** Normalize [PatVar "CtorName"] → [PatConstructor("CtorName", [])] for
    nullary constructors. The parser produces [PatVar] for bare names in
    pattern position; this pass resolves them before match compilation. *)
let normalize_pat ~(ctors : (string, unit) Hashtbl.t) (pat : pattern) : pattern
    =
  let rec go = function
    | PatVar name when Hashtbl.mem ctors name -> PatConstructor (name, [])
    | PatConstructor (c, subs) -> PatConstructor (c, List.map go subs)
    | PatQualified (m, c, subs) -> PatQualified (m, c, List.map go subs)
    | PatTuple ps -> PatTuple (List.map go ps)
    | PatList (ps, spread) -> PatList (List.map go ps, Option.map go spread)
    | PatOr ps -> PatOr (List.map go ps)
    | p -> p
  in
  go pat

(** Normalize all patterns in a Core expression. *)
let normalize_pats_in_expr ~ctors (e : core) : core =
  transform_bottom_up
    (fun node ->
      match node.desc with
      | CMatchArms (scrut, arms) ->
          let arms' =
            List.map (fun (p, body) -> (normalize_pat ~ctors p, body)) arms
          in
          { node with desc = CMatchArms (scrut, arms') }
      | _ -> node)
    e

(* ============================================================================
   Classification helpers
   ============================================================================ *)

(** Is this pattern a "match anything" pattern — a wildcard or a
    plain variable binding? Catch-alls absorb all remaining rows. *)
let is_catchall = function PatWildcard | PatVar _ -> true | _ -> false

(** Extract the variable name if a pattern is a catch-all that binds. *)
let catchall_var = function
  | PatVar name -> Some name
  | PatWildcard -> None
  | _ -> None

(** Is accessor [acc] at-or-under [prefix] in the accessor tree?
    Used to drop bindings that lie inside a sub-position the caller
    is about to recompute (e.g., a list at a constructor field). *)
let rec acc_starts_with prefix acc =
  if prefix = acc then true
  else
    match acc with
    | AccVariantField (parent, _, _)
    | AccTupleField (parent, _)
    | AccListElem (parent, _)
    | AccListSpread (parent, _) ->
        acc_starts_with prefix parent
    | AccRoot -> false

(** Can we compile this sub-pattern? Handles catch-all, literals,
    nested constructors, tuples, and lists (recursively).

    Phase 2.5 adds [PatList]: a list at a sub-position requires
    dispatching on length at that position. Outer dispatch (typically
    a tag-switch on the enclosing constructor) descends into the
    list-bearing position via [compile_subpats_at]. *)
let rec is_compilable_subpattern = function
  | PatVar _ | PatWildcard | PatLiteral _ -> true
  | PatConstructor (_, args) | PatQualified (_, _, args) ->
      List.for_all is_compilable_subpattern args
  | PatTuple ps -> List.for_all is_compilable_subpattern ps
  | PatList (ps, spread) -> (
      List.for_all is_compilable_subpattern ps
      && match spread with Some s -> is_compilable_subpattern s | None -> true)
  | _ -> false

(** Are all sub-patterns of a constructor compilable? *)
let all_compilable_subpatterns pats = List.for_all is_compilable_subpattern pats

(* ============================================================================
   Or-pattern expansion
   ============================================================================ *)

(** Expand [PatOr] arms: [PatOr [p1; p2], body] becomes
    [(p1, body); (p2, body)].  Runs before classification so the
    expanded arms classify normally as literals or constructors. *)
let expand_or_patterns (arms : (pattern * core) list) : (pattern * core) list =
  List.concat_map
    (fun (pat, body) ->
      match pat with
      | PatOr pats -> List.map (fun p -> (p, body)) pats
      | _ -> [ (pat, body) ])
    arms

(* ============================================================================
   Direct constructor scrutinee fusion
   ============================================================================ *)

let constructor_name_of_callee ~(ctors : (string, unit) Hashtbl.t)
    (callee : core) : string option =
  match callee.desc with
  | CVar v when Hashtbl.mem ctors v.vname -> Some v.vname
  | CField (_, field) when Hashtbl.mem ctors field -> Some field
  | _ -> None

let direct_constructor_scrutinee ~(ctors : (string, unit) Hashtbl.t)
    (scrut : core) : (string * core list) option =
  match scrut.desc with
  | CCall (_, callee, args) ->
      Option.map
        (fun name -> (name, args))
        (constructor_name_of_callee ~ctors callee)
  | _ -> None

let simple_payload_pattern = function
  | PatVar "_" | PatWildcard -> Some `Discard
  | PatVar name -> Some (`Bind name)
  | _ -> None

let simple_constructor_payloads ctor args pat =
  match pat with
  | (PatConstructor (name, subs) | PatQualified (_, name, subs))
    when name = ctor && List.length subs = List.length args ->
      let rec collect acc = function
        | [] -> Some (List.rev acc)
        | sub :: rest -> (
            match simple_payload_pattern sub with
            | Some payload -> collect (payload :: acc) rest
            | None -> None)
      in
      collect [] subs
  | _ -> None

let sequence_constructor_args args body =
  List.fold_right (fun arg acc -> { acc with desc = CSeq (arg, acc) }) args body

let bind_constructor_payloads payloads args body =
  List.fold_right2
    (fun payload arg acc ->
      match payload with
      | `Discard -> { acc with desc = CSeq (arg, acc) }
      | `Bind name ->
          let bind =
            {
              bind_var = Var.named name;
              bind_mut = false;
              bind_ty = arg.ty;
              bind_rhs = arg;
            }
          in
          { acc with desc = CLet (bind, acc) })
    payloads args body

let try_fuse_direct_constructor_match ~(ctors : (string, unit) Hashtbl.t) scrut
    arms : core option =
  match direct_constructor_scrutinee ~ctors scrut with
  | None -> None
  | Some (ctor, args) ->
      let rec find = function
        | [] -> None
        | (pat, body) :: rest -> (
            match simple_constructor_payloads ctor args pat with
            | Some payloads ->
                Some (bind_constructor_payloads payloads args body)
            | None -> (
                match pat with
                | (PatConstructor (name, _) | PatQualified (_, name, _))
                  when name = ctor ->
                    None
                | PatWildcard -> Some (sequence_constructor_args args body)
                | _ -> find rest))
      in
      find (expand_or_patterns arms)

(* ============================================================================
   Arm classification — peek at the shape of an arm list
   ============================================================================ *)

type arm_kind =
  | AKCatchall (* a single catch-all — compile to CTLeaf *)
  | AKLiterals (* all PatLiteral, maybe trailing catch-all *)
  | AKConstructors
    (* all PatConstructor/PatQualified, maybe trailing catch-all *)
  | AKTuples (* all PatTuple, maybe trailing catch-all *)
  | AKLists (* all PatList, maybe trailing catch-all *)
  | AKUnsupported (* fall back to raw CMatchArms *)

type list_sequence_arm =
  | ListExact of pattern list * (var * accessor) list * core
  | ListSpread of pattern list * (var * accessor) list * core
  | ListCatchall of (var * accessor) list * core

(** Classify an arm list. Splits off any trailing catch-all from the
    classification but keeps it in the arms list. *)
let classify_arms (arms : (pattern * core) list) : arm_kind =
  match arms with
  | [] -> AKUnsupported
  | [ (p, _) ] when is_catchall p -> AKCatchall
  | _ ->
      (* Drop a trailing catch-all if present; classify the rest. *)
      let rest =
        match List.rev arms with
        | (p, _) :: _ when is_catchall p -> List.rev (List.tl (List.rev arms))
        | _ -> arms
      in
      let all_lit =
        List.for_all
          (fun (p, _) -> match p with PatLiteral _ -> true | _ -> false)
          rest
      in
      if all_lit && rest <> [] then AKLiterals
      else
        let all_ctor =
          List.for_all
            (fun (p, _) ->
              match p with
              | (PatConstructor (_, args) | PatQualified (_, _, args))
                when all_compilable_subpatterns args ->
                  true
              | _ -> false)
            rest
        in
        if all_ctor && rest <> [] then AKConstructors
        else
          let all_tup =
            List.for_all
              (fun (p, _) ->
                match p with
                | PatTuple ps when List.for_all is_compilable_subpattern ps ->
                    true
                | _ -> false)
              rest
          in
          if all_tup && rest <> [] then AKTuples
          else
            let all_list =
              List.for_all
                (fun (p, _) -> match p with PatList _ -> true | _ -> false)
                rest
            in
            if all_list && rest <> [] then AKLists else AKUnsupported

(* ============================================================================
   Pattern binding collection
   ============================================================================ *)

(** Recursively collect bindings from a pattern at a given accessor. *)
let rec collect_pattern_bindings (acc : accessor) (pat : pattern) :
    (var * accessor) list =
  match pat with
  | PatVar name -> [ (Var.named name, acc) ]
  | PatWildcard | PatLiteral _ -> []
  | PatConstructor (ctor, subs) | PatQualified (_, ctor, subs) ->
      List.concat
        (List.mapi
           (fun i sub ->
             collect_pattern_bindings (AccVariantField (acc, ctor, i)) sub)
           subs)
  | PatTuple ps ->
      List.concat
        (List.mapi
           (fun i sub -> collect_pattern_bindings (AccTupleField (acc, i)) sub)
           ps)
  | PatList (pats, spread) ->
      (* Phase 2.5: list patterns at a sub-position bind elements via
         AccListElem and (if a spread var is present) the rest via
         AccListSpread. The list-shape *check* (length dispatch) is
         emitted by [compile_subpats_at]; binding paths are recorded
         here so [simple_bindings] surfaces them. *)
      let elem_bindings =
        List.concat
          (List.mapi
             (fun i sub -> collect_pattern_bindings (AccListElem (acc, i)) sub)
             pats)
      in
      let spread_bindings =
        match spread with
        | Some (PatVar name) ->
            [ (Var.named name, AccListSpread (acc, List.length pats)) ]
        | _ -> []
      in
      elem_bindings @ spread_bindings
  | _ -> []

(** Collect bindings for all tuple element patterns. *)
let tuple_bindings (base : accessor) (pats : pattern list) :
    (var * accessor) list =
  List.concat
    (List.mapi
       (fun i p -> collect_pattern_bindings (AccTupleField (base, i)) p)
       pats)

(** Collect bindings for list-element patterns at a fixed length. Used
    when compiling several same-length [PatList] arms into a nested
    column-split decision tree via [compile_list_elem_arms]. *)
let list_elem_bindings (base : accessor) (pats : pattern list) :
    (var * accessor) list =
  List.concat
    (List.mapi
       (fun i p -> collect_pattern_bindings (AccListElem (base, i)) p)
       pats)

(* ============================================================================
   Leaf construction
   ============================================================================ *)

module MatchStringSet = Set.Make (String)

let add_bound_var bound (v : var) = MatchStringSet.add v.vname bound
let add_bound_name bound name = MatchStringSet.add name bound
let add_bound_names bound names = List.fold_left add_bound_name bound names

let add_bound_typed_vars bound vars =
  List.fold_left (fun acc (v, _) -> add_bound_var acc v) bound vars

let rec var_occurs_free_in_ctree (name : string) bound = function
  | CTLeaf { ct_bindings; ct_body } ->
      let body_bound =
        List.fold_left (fun acc (v, _) -> add_bound_var acc v) bound ct_bindings
      in
      var_occurs_free_in_body name body_bound ct_body
  | CTFail -> false
  | CTSwitchTag { cts_cases; cts_default; _ } ->
      List.exists
        (fun (_, sub) -> var_occurs_free_in_ctree name bound sub)
        cts_cases
      || Option.fold ~none:false
           ~some:(var_occurs_free_in_ctree name bound)
           cts_default
  | CTSwitchLit { ctl_cases; ctl_default; _ } ->
      List.exists
        (fun (_, sub) -> var_occurs_free_in_ctree name bound sub)
        ctl_cases
      || var_occurs_free_in_ctree name bound ctl_default
  | CTSwitchLen { ctl_len_cases; ctl_len_geq; ctl_len_default; _ } ->
      List.exists
        (fun (_, sub) -> var_occurs_free_in_ctree name bound sub)
        ctl_len_cases
      || Option.fold ~none:false
           ~some:(fun (_, sub) -> var_occurs_free_in_ctree name bound sub)
           ctl_len_geq
      || Option.fold ~none:false
           ~some:(var_occurs_free_in_ctree name bound)
           ctl_len_default

and var_occurs_free_in_body (name : string) bound (body : core) : bool =
  let is_target_var v =
    v.vname = name && not (MatchStringSet.mem v.vname bound)
  in
  match body.desc with
  | CVar v -> is_target_var v
  | CAssign (v, rhs) ->
      is_target_var v || var_occurs_free_in_body name bound rhs
  | CDup (v, _, inner) | CDrop (v, _, inner) ->
      is_target_var v || var_occurs_free_in_body name bound inner
  | CLet (b, body') ->
      var_occurs_free_in_body name bound b.bind_rhs
      || var_occurs_free_in_body name (add_bound_var bound b.bind_var) body'
  | CBorrowLet (b, body') ->
      var_occurs_free_in_body name bound b.borrow_rhs
      || var_occurs_free_in_body name (add_bound_var bound b.borrow_var) body'
  | CLambda lam ->
      var_occurs_free_in_body name
        (add_bound_typed_vars bound lam.lam_params)
        lam.lam_body
  | CClosureCreate cc ->
      List.exists
        (fun (capture, _) ->
          capture = name && not (MatchStringSet.mem capture bound))
        cc.cc_captures
  | CFor (binder, iter, loop_body) ->
      var_occurs_free_in_body name bound iter
      || var_occurs_free_in_body name
           (add_bound_var bound binder.loop_var)
           loop_body
  | CConcurrent block ->
      List.exists
        (fun b -> var_occurs_free_in_body name bound b.cb_rhs)
        block.conc_bindings
      ||
      let body_bound =
        List.fold_left
          (fun acc b -> add_bound_var acc b.cb_var)
          bound block.conc_bindings
      in
      var_occurs_free_in_body name body_bound block.conc_body
      || Option.fold ~none:false
           ~some:(var_occurs_free_in_body name bound)
           block.conc_timeout
  | CConcurrentFor cf ->
      var_occurs_free_in_body name bound cf.cf_iter
      || var_occurs_free_in_body name (add_bound_var bound cf.cf_var) cf.cf_body
      || Option.fold ~none:false
           ~some:(var_occurs_free_in_body name bound)
           cf.cf_timeout
  | CListHandoff h ->
      var_occurs_free_in_body name bound h.lh_source
      || var_occurs_free_in_body name bound h.lh_capacity
      ||
      let body_bound =
        List.fold_left add_bound_var bound
          [ h.lh_source_var; h.lh_result_var; h.lh_len_var; h.lh_out_var ]
      in
      var_occurs_free_in_body name body_bound h.lh_body
  | CResourceScope scope ->
      var_occurs_free_in_body name bound scope.rs_acquire
      ||
      let scope_bound = add_bound_var bound scope.rs_var in
      var_occurs_free_in_body name scope_bound scope.rs_body
      || var_occurs_free_in_body name scope_bound scope.rs_cleanup
  | CMatchArms (scrut, arms) ->
      var_occurs_free_in_body name bound scrut
      || List.exists
           (fun (pat, arm_body) ->
             let arm_bound =
               add_bound_names bound (Ast.collect_pattern_vars pat)
             in
             var_occurs_free_in_body name arm_bound arm_body)
           arms
  | CMatch (scrut, tree) ->
      var_occurs_free_in_body name bound scrut
      || var_occurs_free_in_ctree name bound tree
  | _ ->
      fold_immediate_children
        (fun found child -> found || var_occurs_free_in_body name bound child)
        false body

let var_occurs_in_body (name : string) (body : core) : bool =
  var_occurs_free_in_body name MatchStringSet.empty body

let drop_unused_spread_bindings body bindings =
  List.filter
    (fun (v, acc) ->
      match acc with
      | AccListSpread _ -> var_occurs_in_body v.vname body
      | _ -> true)
    bindings

let ct_leaf bindings body =
  CTLeaf
    { ct_bindings = drop_unused_spread_bindings body bindings; ct_body = body }

(** Build a [CTLeaf] from a catch-all pattern. If the pattern is
    [PatVar x], bind [x] to the root scrutinee. If it's [PatWildcard],
    no binding. *)
let leaf_from_catchall (pat : pattern) (body : core) : ctree =
  let bindings =
    match catchall_var pat with
    | Some name -> [ (Var.named name, AccRoot) ]
    | None -> []
  in
  ct_leaf bindings body

(** Collect bindings from constructor sub-patterns recursively.
    Handles PatVar, PatTuple, and nested constructors at any depth. *)
let simple_bindings (base : accessor) (ctor : string) (sub_pats : pattern list)
    : (var * accessor) list =
  List.concat
    (List.mapi
       (fun i p -> collect_pattern_bindings (AccVariantField (base, ctor, i)) p)
       sub_pats)

(** Compile sub-patterns at a given field position of a constructor group.

    [base] is the accessor to the constructor value (e.g. [AccRoot]).
    [ctor] is the constructor name.
    [pos] is the field index being compiled.
    [arms] are the group's arms (sub-pattern list * body).
    [fallback] is used when no arm matches.

    Dispatches based on what kind of sub-pattern appears at [pos]:
    - All catch-all → [CTLeaf] with binding
    - Literals → [CTSwitchLit] with literal cases + catch-all default
    - Constructors → [CTSwitchTag] with constructor cases, recursively
    - Lists (Phase 2.5) → [CTSwitchLen] dispatch on length, with
      element bindings via [AccListElem (acc_field, i)] and spread
      bindings via [AccListSpread (acc_field, n)] *)
let rec compile_subpats_at ~(base : accessor) ~(ctor : string) ~(pos : int)
    ~(fallback : ctree) (arms : (pattern list * core) list) : ctree =
  (* Classify what's at this position *)
  let pats_at_pos = List.map (fun (subs, _) -> List.nth subs pos) arms in
  let has_lit =
    List.exists (function PatLiteral _ -> true | _ -> false) pats_at_pos
  in
  let has_ctor =
    List.exists
      (function PatConstructor _ | PatQualified _ -> true | _ -> false)
      pats_at_pos
  in
  let has_list =
    List.exists (function PatList _ -> true | _ -> false) pats_at_pos
  in
  let acc_field = AccVariantField (base, ctor, pos) in
  if has_list then
    (* List dispatch at this position. Preserve source order by
       compiling each arm into an ordered length/payload-test chain. *)
    let sequence_arms =
      List.map
        (fun (subs, body) ->
          let p = List.nth subs pos in
          let outer_bindings = simple_bindings base ctor subs in
          (* Drop bindings under the list-position itself; we re-add the
         list-specific element/spread bindings below. Uses the shared
         [acc_starts_with] helper. *)
          let outer_bindings =
            List.filter
              (fun (_, acc) -> not (acc_starts_with acc_field acc))
              outer_bindings
          in
          match p with
          | PatList (pats, None) -> ListExact (pats, outer_bindings, body)
          | PatList (pats, Some spread) ->
              let n = List.length pats in
              let spread_bindings =
                match spread with
                | PatVar name when var_occurs_in_body name body ->
                    [ (Var.named name, AccListSpread (acc_field, n)) ]
                | _ -> []
              in
              ListSpread (pats, outer_bindings @ spread_bindings, body)
          | PatVar _ | PatWildcard ->
              ListCatchall
                (outer_bindings @ collect_pattern_bindings acc_field p, body)
          | _ ->
              failwith
                "Core_match: expected list or catch-all pattern in list split")
        arms
    in
    compile_list_pattern_sequence acc_field sequence_arms fallback
  else if has_lit then
    (* Literal dispatch at this position *)
    let lit_cases =
      List.filter_map
        (fun (subs, body) ->
          match List.nth subs pos with
          | PatLiteral lit ->
              let bindings = simple_bindings base ctor subs in
              (* Remove binding for the literal position itself *)
              let bindings =
                List.filter
                  (fun (_, acc) -> acc <> AccVariantField (base, ctor, pos))
                  bindings
              in
              Some (lit, ct_leaf bindings body)
          | _ -> None)
        arms
    in
    let default_arm =
      List.find_opt (fun (subs, _) -> is_catchall (List.nth subs pos)) arms
    in
    let default =
      match default_arm with
      | Some (subs, body) -> ct_leaf (simple_bindings base ctor subs) body
      | None -> fallback
    in
    CTSwitchLit
      { ctl_scrut = acc_field; ctl_cases = lit_cases; ctl_default = default }
  else if has_ctor then (
    (* Constructor dispatch at this position — recurse *)
    let ctor_arms =
      List.filter_map
        (fun (subs, body) ->
          match List.nth subs pos with
          | PatConstructor (c, inner) | PatQualified (_, c, inner) ->
              Some (c, inner, subs, body)
          | _ -> None)
        arms
    in
    (* Group by inner constructor. [acc_starts_with] is the shared
       helper at module scope (see the definition above
       [is_compilable_subpattern]). *)
    let groups = ref [] in
    let split_acc = AccVariantField (base, ctor, pos) in
    List.iter
      (fun (c, inner, subs, body) ->
        let other_bindings = simple_bindings base ctor subs in
        (* Filter out ALL bindings under the split position *)
        let other_bindings =
          List.filter
            (fun (_, acc) -> not (acc_starts_with split_acc acc))
            other_bindings
        in
        let entry = (inner, other_bindings, body) in
        match List.assoc_opt c !groups with
        | Some _ ->
            groups :=
              List.map
                (fun (gc, entries) ->
                  if gc = c then (gc, entries @ [ entry ]) else (gc, entries))
                !groups
        | None -> groups := !groups @ [ (c, [ entry ]) ])
      ctor_arms;
    (* Compile each inner constructor group by recursing into
       compile_ctor_group with the inner accessor as base *)
    let inner_cases =
      List.map
        (fun (inner_ctor, entries) ->
          let inner_arms =
            List.map
              (fun (inner_subs, _other_bindings, body) -> (inner_subs, body))
              entries
          in
          (* Collect outer bindings (same for all entries in this group) *)
          let outer_bindings =
            match entries with (_, ob, _) :: _ -> ob | [] -> []
          in
          let inner_tree =
            compile_ctor_group ~base:acc_field inner_ctor
              ~outer_default:(Some fallback) inner_arms
          in
          (* Prepend outer bindings to every leaf in the inner tree *)
          let rec prepend_bindings tree =
            match tree with
            | CTLeaf l -> ct_leaf (outer_bindings @ l.ct_bindings) l.ct_body
            | CTSwitchTag s ->
                CTSwitchTag
                  {
                    s with
                    cts_cases =
                      List.map
                        (fun (c, t) -> (c, prepend_bindings t))
                        s.cts_cases;
                    cts_default = Option.map prepend_bindings s.cts_default;
                  }
            | CTSwitchLit s ->
                CTSwitchLit
                  {
                    s with
                    ctl_cases =
                      List.map
                        (fun (l, t) -> (l, prepend_bindings t))
                        s.ctl_cases;
                    ctl_default = prepend_bindings s.ctl_default;
                  }
            | CTSwitchLen s ->
                CTSwitchLen
                  {
                    s with
                    ctl_len_cases =
                      List.map
                        (fun (n, t) -> (n, prepend_bindings t))
                        s.ctl_len_cases;
                    ctl_len_geq =
                      Option.map
                        (fun (n, t) -> (n, prepend_bindings t))
                        s.ctl_len_geq;
                    ctl_len_default =
                      Option.map prepend_bindings s.ctl_len_default;
                  }
            | CTFail -> CTFail
          in
          (inner_ctor, prepend_bindings inner_tree))
        !groups
    in
    (* Default: catch-all arm or fallback *)
    let default_arm =
      List.find_opt (fun (subs, _) -> is_catchall (List.nth subs pos)) arms
    in
    let inner_default =
      match default_arm with
      | Some (subs, body) ->
          Some (ct_leaf (simple_bindings base ctor subs) body)
      | None -> if fallback = CTFail then None else Some fallback
    in
    CTSwitchTag
      {
        cts_scrut = acc_field;
        cts_cases = inner_cases;
        cts_default = inner_default;
      })
  else
    (* All catch-all — take first arm *)
    let subs, body = List.hd arms in
    ct_leaf (simple_bindings base ctor subs) body

(** Compile a group of arms that share the same constructor.
    [base] is the accessor to reach the constructor's parent.
    Recursively handles literal and constructor sub-patterns. *)
and compile_ctor_group ?(base = AccRoot) (ctor : string)
    ~(outer_default : ctree option) (arms : (pattern list * core) list) : ctree
    =
  let fallback = match outer_default with Some d -> d | None -> CTFail in
  match arms with
  | [] -> CTFail
  | [ (sub_pats, body) ] when List.for_all is_catchall sub_pats ->
      ct_leaf (simple_bindings base ctor sub_pats) body
  | [ (sub_pats, body) ] ->
      let pos = ref 0 in
      List.iteri
        (fun i p -> if (not (is_catchall p)) && !pos = 0 then pos := i)
        sub_pats;
      compile_subpats_at ~base ~ctor ~pos:!pos ~fallback [ (sub_pats, body) ]
  | _ ->
      let nfields = List.length (fst (List.hd arms)) in
      if nfields = 0 then
        let _, body = List.hd arms in
        ct_leaf [] body
      else
        let pos = ref (-1) in
        for i = 0 to nfields - 1 do
          if !pos < 0 then
            let non_trivial =
              List.exists
                (fun (subs, _) -> not (is_catchall (List.nth subs i)))
                arms
            in
            if non_trivial then pos := i
        done;
        if !pos < 0 then
          let sub_pats, body = List.hd arms in
          ct_leaf (simple_bindings base ctor sub_pats) body
        else compile_subpats_at ~base ~ctor ~pos:!pos ~fallback arms

(* ============================================================================
   Tuple compilation
   ============================================================================ *)

(** Compile a matrix of tuple arms using Maranget column decomposition.

    Each arm carries: element patterns, accumulated extra bindings
    (from constructor fields matched in earlier columns), and the body.
    When all remaining columns are catch-all, emits a [CTLeaf] with
    all bindings merged. Otherwise, picks the leftmost non-trivial
    column, splits on it, and recurses with filtered/residual rows. *)
and compile_tuple_arms (base : accessor)
    (arms : (pattern list * (var * accessor) list * core) list)
    (fallback : ctree) : ctree =
  match arms with
  | [] -> fallback
  | _ ->
      let ncols =
        List.length
          (let ps, _, _ = List.hd arms in
           ps)
      in
      (* Find first column with non-trivial patterns *)
      let split_col = ref (-1) in
      for i = 0 to ncols - 1 do
        if !split_col < 0 then
          let non_trivial =
            List.exists
              (fun (ps, _, _) -> not (is_catchall (List.nth ps i)))
              arms
          in
          if non_trivial then split_col := i
      done;
      if !split_col < 0 then
        (* All columns trivial — take first arm, collect all bindings *)
        let pats, extra, body = List.hd arms in
        ct_leaf (extra @ tuple_bindings base pats) body
      else
        let col = !split_col in
        let col_acc = AccTupleField (base, col) in
        let col_pats = List.map (fun (ps, _, _) -> List.nth ps col) arms in
        let has_lit =
          List.exists (function PatLiteral _ -> true | _ -> false) col_pats
        in
        let has_ctor =
          List.exists
            (function PatConstructor _ | PatQualified _ -> true | _ -> false)
            col_pats
        in
        if has_lit then compile_tuple_lit_split base arms col col_acc fallback
        else if has_ctor then
          compile_tuple_ctor_split base arms col col_acc fallback
        else
          let pats, extra, body = List.hd arms in
          ct_leaf (extra @ tuple_bindings base pats) body

(** Literal column split for tuple matching. *)
and compile_tuple_lit_split base arms col col_acc fallback =
  (* Group arms by literal value at this column; wildcards go to default *)
  let lit_groups = Hashtbl.create 8 in
  let lit_order = ref [] in
  let default_arms = ref [] in
  List.iter
    (fun (ps, extra, body) ->
      match List.nth ps col with
      | PatLiteral lit ->
          let ps' =
            List.mapi (fun i p -> if i = col then PatWildcard else p) ps
          in
          if not (Hashtbl.mem lit_groups lit) then
            lit_order := !lit_order @ [ lit ];
          let prev = try Hashtbl.find lit_groups lit with Not_found -> [] in
          Hashtbl.replace lit_groups lit (prev @ [ (ps', extra, body) ])
      | _ -> default_arms := !default_arms @ [ (ps, extra, body) ])
    arms;
  let lit_cases =
    List.map
      (fun lit ->
        let group = Hashtbl.find lit_groups lit in
        (* Combine with default arms for recursive compilation *)
        let combined = group @ !default_arms in
        (lit, compile_tuple_arms base combined fallback))
      !lit_order
  in
  let default =
    match !default_arms with
    | [] -> fallback
    | _ -> compile_tuple_arms base !default_arms fallback
  in
  CTSwitchLit
    { ctl_scrut = col_acc; ctl_cases = lit_cases; ctl_default = default }

(** Compile several list arms that share a fixed length. Mirrors
    [compile_tuple_arms] but indexes via [AccListElem] so nested
    literals/constructors inside the list get a proper column-split
    decision tree. Without this, two arms like [_, "help"] and
    [_, "version"] would both produce length-2 leaves and only the
    first would ever match. *)
and compile_list_elem_arms (base : accessor)
    (arms : (pattern list * (var * accessor) list * core) list)
    (fallback : ctree) : ctree =
  match arms with
  | [] -> fallback
  | _ ->
      let ncols =
        List.length
          (let ps, _, _ = List.hd arms in
           ps)
      in
      let split_col = ref (-1) in
      for i = 0 to ncols - 1 do
        if !split_col < 0 then
          let non_trivial =
            List.exists
              (fun (ps, _, _) -> not (is_catchall (List.nth ps i)))
              arms
          in
          if non_trivial then split_col := i
      done;
      if !split_col < 0 then
        let pats, extra, body = List.hd arms in
        ct_leaf (extra @ list_elem_bindings base pats) body
      else
        let col = !split_col in
        let col_acc = AccListElem (base, col) in
        let col_pats = List.map (fun (ps, _, _) -> List.nth ps col) arms in
        let has_lit =
          List.exists (function PatLiteral _ -> true | _ -> false) col_pats
        in
        let has_ctor =
          List.exists
            (function PatConstructor _ | PatQualified _ -> true | _ -> false)
            col_pats
        in
        if has_lit then
          compile_list_elem_lit_split base arms col col_acc fallback
        else if has_ctor then
          compile_list_elem_ctor_split base arms col col_acc fallback
        else
          let pats, extra, body = List.hd arms in
          ct_leaf (extra @ list_elem_bindings base pats) body

and compile_list_elem_lit_split base arms col col_acc fallback =
  let lit_groups = Hashtbl.create 8 in
  let lit_order = ref [] in
  let default_arms = ref [] in
  List.iter
    (fun (ps, extra, body) ->
      match List.nth ps col with
      | PatLiteral lit ->
          let ps' =
            List.mapi (fun i p -> if i = col then PatWildcard else p) ps
          in
          if not (Hashtbl.mem lit_groups lit) then
            lit_order := !lit_order @ [ lit ];
          let prev = try Hashtbl.find lit_groups lit with Not_found -> [] in
          Hashtbl.replace lit_groups lit (prev @ [ (ps', extra, body) ])
      | _ -> default_arms := !default_arms @ [ (ps, extra, body) ])
    arms;
  let lit_cases =
    List.map
      (fun lit ->
        let group = Hashtbl.find lit_groups lit in
        let combined = group @ !default_arms in
        (lit, compile_list_elem_arms base combined fallback))
      !lit_order
  in
  let default =
    match !default_arms with
    | [] -> fallback
    | _ -> compile_list_elem_arms base !default_arms fallback
  in
  CTSwitchLit
    { ctl_scrut = col_acc; ctl_cases = lit_cases; ctl_default = default }

and compile_list_elem_ctor_split base arms col col_acc fallback =
  let ctor_groups = Hashtbl.create 8 in
  let ctor_order = ref [] in
  let default_arms = ref [] in
  List.iter
    (fun (ps, extra, body) ->
      match List.nth ps col with
      | PatConstructor (c, subs) | PatQualified (_, c, subs) ->
          let ps' =
            List.mapi (fun i p -> if i = col then PatWildcard else p) ps
          in
          let ctor_bindings =
            List.concat
              (List.mapi
                 (fun i sub ->
                   collect_pattern_bindings
                     (AccVariantField (col_acc, c, i))
                     sub)
                 subs)
          in
          if not (Hashtbl.mem ctor_groups c) then
            ctor_order := !ctor_order @ [ c ];
          let prev = try Hashtbl.find ctor_groups c with Not_found -> [] in
          Hashtbl.replace ctor_groups c
            (prev @ [ (ps', extra @ ctor_bindings, body) ])
      | _ -> default_arms := !default_arms @ [ (ps, extra, body) ])
    arms;
  let cases =
    List.map
      (fun ctor ->
        let group = Hashtbl.find ctor_groups ctor in
        let combined = group @ !default_arms in
        (ctor, compile_list_elem_arms base combined fallback))
      !ctor_order
  in
  let ctor_default =
    match !default_arms with
    | [] -> Some fallback
    | _ -> Some (compile_list_elem_arms base !default_arms fallback)
  in
  CTSwitchTag
    { cts_scrut = col_acc; cts_cases = cases; cts_default = ctor_default }

and compile_list_pattern_sequence base arms fallback =
  match arms with
  | [] -> fallback
  | ListCatchall (bindings, body) :: _ -> ct_leaf bindings body
  | ListExact (pats, extra, body) :: rest ->
      let next = compile_list_pattern_sequence base rest fallback in
      let len = List.length pats in
      let subtree = compile_list_elem_arms base [ (pats, extra, body) ] next in
      CTSwitchLen
        {
          ctl_len_scrut = base;
          ctl_len_cases = [ (len, subtree) ];
          ctl_len_geq = None;
          ctl_len_default = Some next;
        }
  | ListSpread (pats, extra, body) :: rest ->
      let next = compile_list_pattern_sequence base rest fallback in
      let len = List.length pats in
      let subtree = compile_list_elem_arms base [ (pats, extra, body) ] next in
      CTSwitchLen
        {
          ctl_len_scrut = base;
          ctl_len_cases = [];
          ctl_len_geq = Some (len, subtree);
          ctl_len_default = Some next;
        }

(** Constructor column split for tuple matching. *)
and compile_tuple_ctor_split base arms col col_acc fallback =
  let ctor_groups = Hashtbl.create 8 in
  let ctor_order = ref [] in
  let default_arms = ref [] in
  List.iter
    (fun (ps, extra, body) ->
      match List.nth ps col with
      | PatConstructor (c, subs) | PatQualified (_, c, subs) ->
          let ps' =
            List.mapi (fun i p -> if i = col then PatWildcard else p) ps
          in
          let ctor_bindings =
            List.concat
              (List.mapi
                 (fun i sub ->
                   collect_pattern_bindings
                     (AccVariantField (col_acc, c, i))
                     sub)
                 subs)
          in
          if not (Hashtbl.mem ctor_groups c) then
            ctor_order := !ctor_order @ [ c ];
          let prev = try Hashtbl.find ctor_groups c with Not_found -> [] in
          Hashtbl.replace ctor_groups c
            (prev @ [ (ps', extra @ ctor_bindings, body) ])
      | _ -> default_arms := !default_arms @ [ (ps, extra, body) ])
    arms;
  let cases =
    List.map
      (fun ctor ->
        let group = Hashtbl.find ctor_groups ctor in
        let combined = group @ !default_arms in
        (ctor, compile_tuple_arms base combined fallback))
      !ctor_order
  in
  let ctor_default =
    match !default_arms with
    | [] -> Some fallback
    | _ -> Some (compile_tuple_arms base !default_arms fallback)
  in
  CTSwitchTag
    { cts_scrut = col_acc; cts_cases = cases; cts_default = ctor_default }

(* ============================================================================
   Compilation
   ============================================================================ *)

(** Compile a list of arms into a decision tree. Returns [None] if
    the patterns fall outside the supported subset.

    Or-patterns are expanded first: [PatOr [p1; p2], body] becomes
    [(p1, body); (p2, body)] so they classify normally. *)
let compile_arms (arms : (pattern * core) list) : ctree option =
  let arms = expand_or_patterns arms in
  match classify_arms arms with
  | AKCatchall -> (
      match arms with
      | [ (p, body) ] -> Some (leaf_from_catchall p body)
      | _ -> None)
  | AKLiterals ->
      let tested, default =
        match List.rev arms with
        | (p, body) :: rest when is_catchall p ->
            (List.rev rest, leaf_from_catchall p body)
        | _ -> (arms, CTFail)
      in
      let cases =
        List.map
          (fun (p, body) ->
            match p with
            | PatLiteral lit ->
                let leaf = ct_leaf [] body in
                (lit, leaf)
            | _ -> assert false (* classifier guarantees literal *))
          tested
      in
      Some
        (CTSwitchLit
           { ctl_scrut = AccRoot; ctl_cases = cases; ctl_default = default })
  | AKConstructors ->
      let tested, default =
        match List.rev arms with
        | (p, body) :: rest when is_catchall p ->
            (List.rev rest, Some (leaf_from_catchall p body))
        | _ -> (arms, None)
      in
      (* Group arms by constructor name, preserving order *)
      let groups : (string * (pattern list * core) list) list =
        let acc = ref [] in
        List.iter
          (fun (p, body) ->
            let ctor, sub_pats =
              match p with
              | PatConstructor (c, s) | PatQualified (_, c, s) -> (c, s)
              | _ -> assert false
            in
            match List.assoc_opt ctor !acc with
            | Some _ ->
                acc :=
                  List.map
                    (fun (c, arms) ->
                      if c = ctor then (c, arms @ [ (sub_pats, body) ])
                      else (c, arms))
                    !acc
            | None -> acc := !acc @ [ (ctor, [ (sub_pats, body) ]) ])
          tested;
        !acc
      in
      let cases =
        List.map
          (fun (ctor, group_arms) ->
            (ctor, compile_ctor_group ctor ~outer_default:default group_arms))
          groups
      in
      Some
        (CTSwitchTag
           { cts_scrut = AccRoot; cts_cases = cases; cts_default = default })
  | AKTuples ->
      let tested, default =
        match List.rev arms with
        | (p, body) :: rest when is_catchall p ->
            (List.rev rest, Some (leaf_from_catchall p body))
        | _ -> (arms, None)
      in
      let tuple_arms =
        List.map
          (fun (p, body) ->
            match p with PatTuple ps -> (ps, [], body) | _ -> assert false)
          tested
      in
      let fallback = match default with Some d -> d | None -> CTFail in
      Some (compile_tuple_arms AccRoot tuple_arms fallback)
  | AKLists ->
      let tested, default =
        match List.rev arms with
        | (p, body) :: rest when is_catchall p ->
            (List.rev rest, Some (leaf_from_catchall p body))
        | _ -> (arms, None)
      in
      let fallback = match default with Some d -> d | None -> CTFail in
      (* Preserve source order. Exact and spread list arms can overlap:
         an earlier [x, ...rest] must win over a later [x], and spread
         arms at different fixed-head lengths must fall through in the
         order the user wrote them. *)
      let list_arms =
        List.map
          (fun (p, body) ->
            match p with
            | PatList (pats, None) -> ListExact (pats, [], body)
            | PatList (pats, Some spread) ->
                let n = List.length pats in
                let spread_bindings =
                  match spread with
                  | PatVar name when var_occurs_in_body name body ->
                      [ (Var.named name, AccListSpread (AccRoot, n)) ]
                  | _ -> []
                in
                ListSpread (pats, spread_bindings, body)
            | _ -> assert false)
          tested
      in
      Some (compile_list_pattern_sequence AccRoot list_arms fallback)
  | AKUnsupported -> None

(** Try to rewrite a [CMatchArms] expression into [CMatch] (decision
    tree). Returns the original expression unchanged if compilation
    isn't possible. *)
let try_compile_match ?ctors (e : core) : core =
  let ctors =
    match ctors with
    | Some ctors -> ctors
    | None -> collect_constructor_names []
  in
  match e.desc with
  | CMatchArms (scrut, arms) -> (
      match try_fuse_direct_constructor_match ~ctors scrut arms with
      | Some fused -> fused
      | None -> (
          match compile_arms arms with
          | Some tree -> { e with desc = CMatch (scrut, tree) }
          | None -> e))
  | _ -> e

(* ============================================================================
   Program-level pass
   ============================================================================ *)

(** Walk a Core expression: normalize constructor patterns, then
    compile every reachable [CMatchArms] to [CMatch] (decision tree).
    Uses [transform_bottom_up] so nested matches are compiled from
    inside out. *)
let compile_expr ~ctors (e : core) : core =
  let normalized = normalize_pats_in_expr ~ctors e in
  transform_bottom_up (try_compile_match ~ctors) normalized

(** Compile matches inside a function body. *)
let compile_func ~ctors (f : core_func) : core_func =
  match f.cf_body with
  | None -> f
  | Some body -> { f with cf_body = Some (compile_expr ~ctors body) }

(** Compile matches inside a global variable's initializer. *)
let compile_var ~ctors (v : core_var) : core_var =
  { v with cv_init = compile_expr ~ctors v.cv_init }

(** Compile matches inside an impl's methods. *)
let compile_impl ~ctors (i : core_impl) : core_impl =
  { i with ci_methods = List.map (compile_func ~ctors) i.ci_methods }

(** Compile matches in a single declaration. *)
let rec compile_decl ~ctors (d : core_decl) : core_decl =
  let desc' =
    match d.cd_desc with
    | CDFunc f -> CDFunc (compile_func ~ctors f)
    | CDVar v -> CDVar (compile_var ~ctors v)
    | CDImpl i -> CDImpl (compile_impl ~ctors i)
    | CDTrait _ as other -> other (* no expressions; defaults live on AST *)
    | CDPrivate inner -> CDPrivate (compile_decl ~ctors inner)
    | (CDType _ | CDRecord _ | CDImport _ | CDTypeAlias _) as other -> other
  in
  { d with cd_desc = desc' }

(** Walk a program: collect constructor names, normalize patterns,
    then compile every compilable [CMatchArms] to [CMatch] (decision
    tree). *)
let compile_program (prog : core_program) : core_program =
  let ctors = collect_constructor_names prog in
  List.map (compile_decl ~ctors) prog
