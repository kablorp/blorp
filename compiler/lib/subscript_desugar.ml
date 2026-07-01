(** Pre-typecheck rewrite: subscript-read syntax → bounds-checked call.

    Runs AFTER parse and string interpolation lowering
    and BEFORE [Typecheck]. Rewrites:

    - [x[i]]              → [checked_get(x, i)]
    - [x[s..e]]           → [checked_slice(x, s, e)]
    - [m[i, j]]           → [matrix_checked_get(m, i, j)]
    - [t[i, j, k]]        → [tensor3_checked_get(t, i, j, k)] (4-D, 5-D likewise)

    [ESubscriptAssign] ([x[...] = v]) is {b deliberately left in
    infer.ml]. The syntactic form carries a "this is an assignment"
    intent that can't be recovered from a plain call: direct uses of
    [checked_set(v, i, x)] are legitimate pure value-semantic calls
    (COW → new tensor) and must not trigger the "can't assign to
    immutable variable" error. Moving the write rewrite would require
    either a separate builtin name for assignment or a per-call flag
    — neither was judged worth the churn in Phase 2.3's audit.

    {1 Why this pass exists (Phase 2.3)}

    Previously this rewrite lived in [infer.ml:1965-2000]. That
    violated Stage 7 of the compiler pipeline: syntactic desugaring
    belongs before type-checking, not inside it. Moving it here makes
    the AST fed into type-checking reflect the user's syntax literally
    for a brief moment longer, and lets downstream error messages
    refer to [x[i]] rather than [checked_get(x, i)].

    {1 Why arity alone is sufficient}

    The 1-D / 2-D / 3-D / ... dispatch is {b arity-based}, not
    type-based: [matrix_checked_get] accepts exactly two indices,
    [tensor3_checked_get] exactly three. The index-count is a
    syntactic property of [ESubscriptMulti]/[ESubscriptAssign],
    available before type-checking.

    The inferred collection type is consulted inside
    [Infer.infer_checked_get] to refine the callee name further
    ([checked_get] vs [tensor_peel] for single-index access on N-D
    tensors). That decision still happens at type-check time — this
    pass only emits [checked_get] and [Infer.infer_call] then routes
    to [infer_checked_get], which does the peel-vs-scalar dispatch.

    {1 What stays in Infer}

    - [validate_index] and the proven-bounds / symbolic-ranges
      machinery. After this pass, the literal index survives as the
      second argument to [checked_get]; [validate_index] sees the
      same [ELiteral]/[EIdent] it used to.
    - [infer_checked_get]'s choice between [checked_get] and
      [tensor_peel] when the collection has leftover dims.
    - Mutability checks on subscript assignment — moved into
      [infer_checked_set] / [infer_nd_checked_set_call] so they fire
      regardless of how the call was produced.

    The pass is pure syntax-to-syntax: no types are inspected, no env
    is threaded. *)

open Ast

(** Build a no-type call expression. Types are populated by
    [Infer.infer_call] when it encounters the emitted [ECall]. *)
let mk_call ~loc ~name ~args : expr =
  let callee = untyped_expr ~loc (EIdent name) in
  untyped_expr ~loc (ECall (callee, args))

(** Arity → N-D getter builtin name. 1-D falls through to
    [checked_get] so the downstream [infer_checked_get] can make the
    peel-vs-scalar decision. For N > 5 we emit a synthetic
    [tensorN_checked_get] name that will fail identifier resolution
    at typecheck — the user gets a clean "undefined identifier" at
    the subscript site rather than a misleading "wrong arg count"
    from a fall-through. *)
let nd_get_name (arity : int) : string =
  match arity with
  | 1 -> "checked_get"
  | 2 -> "matrix_checked_get"
  | 3 -> "tensor3_checked_get"
  | 4 -> "tensor4_checked_get"
  | 5 -> "tensor5_checked_get"
  | n -> Printf.sprintf "tensor%d_checked_get" n

(** Rewrite a single expression's {b own} node (not its children —
    that's [expr_map_children]'s job). Returns the transformed node
    if it's a subscript form, or the original node otherwise.

    Note: [ESubscriptAssign] is deliberately NOT rewritten — see the
    header docstring. *)
let rewrite_node (e : expr) : expr =
  let loc = e.expr_loc in
  match e.expr_desc with
  | ESubscript (coll, { expr_desc = ERange (start_e, end_e); _ }) ->
      (* Range slice: v[s..e] → checked_slice(v, s, e).
         Must precede the generic ESubscript case. *)
      mk_call ~loc ~name:"checked_slice" ~args:[ coll; start_e; end_e ]
  | ESubscript (coll, idx) ->
      mk_call ~loc ~name:"checked_get" ~args:[ coll; idx ]
  | ESubscriptMulti (coll, indices) ->
      let name = nd_get_name (List.length indices) in
      mk_call ~loc ~name ~args:(coll :: indices)
  | _ -> e

(** Bottom-up traversal: rewrite children first, then the current node. *)
let rec transform_expr (e : expr) : expr =
  let e = expr_map_children transform_expr e in
  rewrite_node e

and transform_func (func : func_decl) : func_decl =
  { func with func_body = map_func_body_expr transform_expr func.func_body }

and transform_trait_method (method_ : trait_method) : trait_method =
  {
    method_ with
    method_default_body = Option.map transform_expr method_.method_default_body;
  }

and transform_impl (impl : impl_decl) : impl_decl =
  { impl with impl_methods = List.map transform_func impl.impl_methods }

and transform_trait (trait : trait_decl) : trait_decl =
  {
    trait with
    trait_methods = List.map transform_trait_method trait.trait_methods;
  }

(** Transform a single declaration. *)
let rec transform_decl (decl : decl) : decl =
  match decl.decl_desc with
  | DFunc func -> { decl with decl_desc = DFunc (transform_func func) }
  | DVar var ->
      {
        decl with
        decl_desc = DVar { var with var_value = transform_expr var.var_value };
      }
  | DPrivate inner -> { decl with decl_desc = DPrivate (transform_decl inner) }
  | DImpl impl -> { decl with decl_desc = DImpl (transform_impl impl) }
  | DTrait trait -> { decl with decl_desc = DTrait (transform_trait trait) }
  | DType _ | DRecord _ | DImport _ | DTypeAlias _ -> decl

(** Transform a full program. Must be called {b after}
    string interpolation lowering and {b before} [Typecheck]. *)
let transform_program (program : program) : program =
  List.map transform_decl program
