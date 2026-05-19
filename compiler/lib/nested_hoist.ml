(** Nested function declaration hoisting.

    Post-parse, pre-infer pass that lifts [EFuncDecl] nodes out of function
    bodies into top-level [DFunc] declarations. By the time typecheck runs,
    every function is top-level; no downstream pass needs to know nested
    functions exist.

    {1 Semantics}

    A nested [func name[T](params) -> ret: body] inside a parent function
    is:

    - Scoped to the enclosing block: references to [name] after the
      declaration in the same body resolve to the nested function.
    - Hoisted with a mangled, globally-unique name
      [__nested_<parent>_<name>_<N>] so multiple nesting sites can use the
      same local name without collision.
    - Forbidden from capturing parent locals or parameters. Enforced
      naturally: the hoisted top-level function's body is type-checked
      against the module scope only; any reference to a parent binding
      fails with the standard "undefined identifier" diagnostic.
    - Generic-parameter-friendly: [[T]] on a nested function is
      independent of the parent's type parameters.

    {1 Algorithm}

    For each top-level [DFunc] [parent]:

    1. Walk [parent.func_body]. For each [EFuncDecl nested] encountered:
       - Assign a fresh mangled name [m = "__nested_" ^ parent ^ "_" ^
         nested.func_name ^ "_" ^ fresh()].
       - Record the rewrite [nested.func_name → m] in a substitution
         scope that covers the remainder of the current block.
       - Recursively process [nested.func_body] so nested-inside-nested
         also hoists (currently deferred — see [hoist_body]'s early-return
         when scanning children).
       - Replace the [EFuncDecl] node in place with [EVoid] (no-op; keeps
         block structure so downstream passes don't see a gap).
    2. Rewrite every [EIdent name] in the remainder of the block where
       [name] is in the current substitution scope to use the mangled
       name.
    3. Emit the collected nested functions as additional top-level
       [DFunc]s alongside the original parent.

    {1 Non-goals (v1)}

    - Nested inside nested. A nested function's body may itself contain
      [EFuncDecl]s; those are left as-is (and will fail later with
      "EFuncDecl survived" if hit). Handled in a follow-up by making the
      hoist pass recursive.
    - Mutual recursion between two nested functions declared in the same
      block. Works if declared in order (later defs see earlier via
      substitution scope), but not if [f1] forward-references [f2]. *)

open Ast

(** Fresh-name counter; module-local state, reset per program. *)
let counter = ref 0

let fresh_id () =
  let n = !counter in
  incr counter;
  n

let mangle parent_name nested_name =
  Printf.sprintf "__nested_%s_%s_%d" parent_name nested_name (fresh_id ())

(** Rewrite every [EIdent name] matching [old_name] to [EIdent new_name]
    throughout an expression subtree, without descending into nested
    [ELambda] or [EFuncDecl] (which introduce their own scopes and should
    not be touched by the caller's rewrite).

    A proper implementation would also respect shadowing by [EVarDecl]s
    that rebind [old_name]; for v1 we rely on users not shadowing nested
    function names — the mangled target name is unique enough that a
    mis-rewrite would surface immediately at typecheck. *)
let rec rewrite_ident (old_name : string) (new_name : string) (e : expr) : expr
    =
  let desc' =
    match e.expr_desc with
    | EIdent name when name = old_name -> EIdent new_name
    | ELambda _ | EFuncDecl _ ->
        e.expr_desc (* don't descend into inner scopes *)
    | _ -> (expr_map_children (rewrite_ident old_name new_name) e).expr_desc
  in
  { e with expr_desc = desc' }

(** Collect every identifier appearing free in [e], excluding those that
    are bound by a let/var/param/for inside [e] itself. Returns a list of
    [(name, loc)] pairs so error messages can cite the capturing
    reference. Does not descend into inner [ELambda] / [EFuncDecl] —
    those introduce their own scopes. *)
let free_idents_of (e : expr) : (string * loc) list =
  let found = ref [] in
  let rec go bound e =
    match e.expr_desc with
    | EIdent name ->
        if not (List.mem name bound) then found := (name, e.expr_loc) :: !found
    | ELambda _ | EFuncDecl _ -> ()
    | EVarDecl (name, _, init, _) ->
        go bound init
        (* Note: the new binding only scopes over LATER siblings in a block.
           This function is called on a nested func's body which may be an
           EBlock — the walk through EBlock statements handles scoping below. *);
        ignore name
    | EBlock stmts ->
        let rec walk_stmts b = function
          | [] -> ()
          | stmt :: rest -> (
              match stmt.expr_desc with
              | EVarDecl (name, _, init, _) ->
                  go b init;
                  walk_stmts (name :: b) rest
              | ETupleDestruct (names, init) ->
                  go b init;
                  walk_stmts (names @ b) rest
              | EConcurrentBind (name, _, init) ->
                  go b init;
                  walk_stmts (name :: b) rest
              | _ ->
                  go b stmt;
                  walk_stmts b rest)
        in
        walk_stmts bound stmts
    | EWith (binding, body) ->
        go bound binding.with_value;
        go (binding.with_name :: bound) body
    | EFor (var, iter, body) ->
        go bound iter;
        go (var :: bound) body
    | EForTuple (vars, iter, body) ->
        go bound iter;
        go (vars @ bound) body
    | EQuestionBind (name, _, e1) ->
        go bound e1;
        ignore name
    | EMatch (scrut, cases) ->
        go bound scrut;
        List.iter
          (fun c ->
            let pat_vars = collect_pattern_vars c.case_pattern in
            go (pat_vars @ bound) c.case_body)
          cases
    | _ -> List.iter (go bound) (expr_children e)
  in
  go [] e;
  List.rev !found

(** Check a nested function body for captures of [parent_locals] (names
    bound in the parent's scope at the point of the nested decl).
    Returns [None] if no captures; [Some (name, loc)] for the first
    captured identifier so the caller can emit a targeted error. *)
let find_capture (parent_locals : string list) (nested_body : expr) :
    (string * loc) option =
  let frees = free_idents_of nested_body in
  List.find_opt (fun (n, _) -> List.mem n parent_locals) frees

(** Build a user-facing error for a captured identifier. *)
let capture_error (nested_name : string) (parent_name : string)
    (captured : string) (loc : loc) : compiler_error =
  {
    message =
      Printf.sprintf
        "Nested function '%s' cannot capture parent-scope identifier '%s'"
        nested_name captured;
    loc;
    phase = TypeCheck;
    kind = OtherError;
    notes =
      [
        Printf.sprintf "'%s' is a local binding in the enclosing function '%s'"
          captured parent_name;
        "Nested functions are hoisted to top-level and do not form closures.";
      ];
    help =
      Some
        (Printf.sprintf
           "Pass '%s' as a parameter to '%s', or use a lambda (func(...): ...) \
            instead — lambdas can capture by value"
           captured nested_name);
  }

exception Capture_error of compiler_error
(** Raised from the hoist pass when a capture is detected. Caught at the
    [hoist_program] boundary and rendered via the standard diagnostic
    path. *)

(** Walk an expression body looking for [EFuncDecl] nodes. For each one
    found at [EBlock] level:
    - Mangle its name relative to [parent_name].
    - Check for captures of parent-scope bindings, raise [Capture_error]
      if any are found.
    - Replace the [EFuncDecl] with [EVoid] in the block.
    - Rewrite identifiers in the block's suffix to use the mangled name.
    - Collect the hoisted [func_decl] (with its new name).

    [parent_locals] accumulates names bound in the parent's scope as the
    walk proceeds: params at entry, each [EVarDecl] / destructure / for-
    var / match-pattern binding as we walk past it. Captures are checked
    against this accumulated set.

    Returns [(transformed_body, hoisted_funcs)]. *)
let rec hoist_body (parent_name : string) (parent_locals : string list)
    (body : expr) : expr * func_decl list =
  let hoisted = ref [] in
  (* [name_map] accumulates (orig_name, mangled_name) rewrites within a
     block as we walk left to right. Each subsequent nested function sees
     earlier siblings' mangled names in its body, enabling mutual-reference
     in declaration order. *)
  let rewrite_block locals stmts =
    let apply_map nm e =
      List.fold_left (fun acc (o, n) -> rewrite_ident o n acc) e nm
    in
    let rec go acc name_map cur_locals = function
      | [] -> List.rev acc
      | ({ expr_desc = EFuncDecl fd; _ } as stmt) :: rest ->
          let orig_name =
            match fd.func_name with Some n -> n | None -> "anon"
          in
          let new_name = mangle parent_name orig_name in
          (* Capture check: collect free identifiers in the nested body
             (pre-rewrite). If any match a name in [cur_locals] (parent
             scope at this point), raise a targeted error. *)
          (match Ast.func_body_expr_opt fd.func_body with
          | Some b -> (
              (* Subtract the nested func's own params from the scope so
                  [identity(x)] isn't flagged as capturing [x] when [x]
                  is declared in the outer scope but shadowed. *)
              let own_params =
                List.filter_map (fun (p : param) -> p.param_name) fd.func_params
              in
              let external_locals =
                List.filter (fun n -> not (List.mem n own_params)) cur_locals
              in
              (* Exclude earlier siblings' ORIGINAL names from the
                  parent-locals set; those are valid callees. The
                  name_map carries (orig → mangled) pairs. *)
              let sibling_names = List.map fst name_map in
              let external_locals =
                List.filter
                  (fun n -> not (List.mem n sibling_names))
                  external_locals
              in
              match find_capture external_locals b with
              | Some (captured, loc) ->
                  raise
                    (Capture_error
                       (capture_error orig_name parent_name captured loc))
              | None -> ())
          | None -> ());
          (* Rewrite the nested body with:
             (a) prior siblings' mangles (so quadruple can call double),
             (b) its own orig_name → new_name (for self-recursion),
             then recursively hoist any deeper nested funcs inside it.
             Nested funcs don't inherit parent locals; their [parent_locals]
             starts with only their own params. *)
          let new_body =
            match fd.func_body with
            | FuncBodyExpr b ->
                let b = apply_map name_map b in
                let b = rewrite_ident orig_name new_name b in
                let own_params =
                  List.filter_map
                    (fun (p : param) -> p.param_name)
                    fd.func_params
                in
                let b', inner_hoisted = hoist_body new_name own_params b in
                hoisted := inner_hoisted @ !hoisted;
                FuncBodyExpr b'
            | FuncBuiltinBody _ | FuncForeign _ | FuncNoBody -> fd.func_body
          in
          let fd' =
            { fd with func_name = Some new_name; func_body = new_body }
          in
          hoisted := fd' :: !hoisted;
          let rest' = List.map (rewrite_ident orig_name new_name) rest in
          let placeholder = { stmt with expr_desc = EVoid } in
          go (placeholder :: acc)
            ((orig_name, new_name) :: name_map)
            cur_locals rest'
      | ({ expr_desc = EVarDecl (name, _, _, _); _ } as stmt) :: rest ->
          go (stmt :: acc) name_map (name :: cur_locals) rest
      | ({ expr_desc = ETupleDestruct (names, _); _ } as stmt) :: rest ->
          go (stmt :: acc) name_map (names @ cur_locals) rest
      | ({ expr_desc = EConcurrentBind (name, _, _); _ } as stmt) :: rest ->
          go (stmt :: acc) name_map (name :: cur_locals) rest
      | stmt :: rest ->
          go
            (hoist_in_expr parent_name hoisted stmt :: acc)
            name_map cur_locals rest
    in
    go [] [] locals stmts
  in
  let rec walk e =
    match e.expr_desc with
    | EBlock stmts ->
        { e with expr_desc = EBlock (rewrite_block parent_locals stmts) }
    | ELambda _ | EFuncDecl _ -> e (* inner scope; leave for its own pass *)
    | _ -> expr_map_children walk e
  in
  let body' = walk body in
  (body', List.rev !hoisted)

(** Walk an expression looking for [EFuncDecl] in non-block positions
    (edge cases: a match arm whose body is directly an [EFuncDecl], or
    an [if] branch). Pushes hoisted funcs into the shared ref. Used by
    [rewrite_block] when descending into non-block stmts.

    Normally [EFuncDecl] only appears as a block statement (produced by
    the parser's [stmt] rule). This function is defensive — if a future
    grammar change allows [EFuncDecl] elsewhere, this catches it. *)
and hoist_in_expr _parent_name _hoisted_ref e =
  (* v1: leave non-block EFuncDecl alone; downstream "survived" error
     catches it. *)
  e

(** Hoist a single top-level function's body, returning the transformed
    [func_decl] and any hoisted children. *)
let hoist_func (fd : func_decl) : func_decl * func_decl list =
  let parent_name = match fd.func_name with Some n -> n | None -> "anon" in
  match fd.func_body with
  | FuncBodyExpr body ->
      let params =
        List.filter_map (fun (p : param) -> p.param_name) fd.func_params
      in
      let body', hoisted = hoist_body parent_name params body in
      ({ fd with func_body = FuncBodyExpr body' }, hoisted)
  | FuncBuiltinBody _ | FuncForeign _ | FuncNoBody -> (fd, [])

(** Hoist all nested functions in an impl method. *)
let hoist_impl_method (fd : func_decl) : func_decl * func_decl list =
  hoist_func fd

(** Top-level entry: walk a program, hoisting nested funcs in every
    [DFunc] / [DImpl] / [DVar] body. Returns the rewritten program. *)
let hoist_program (prog : program) : program =
  counter := 0;
  let out = ref [] in
  let process_decl (d : decl) =
    match d.decl_desc with
    | DFunc fd ->
        let fd', hoisted = hoist_func fd in
        (* Hoisted functions are emitted BEFORE the parent so the parent's
           body can reference them by their mangled name without forward-
           declaration concerns. Typecheck does two-pass signature
           registration, so ordering is really a codegen-friendliness
           choice, not a correctness one. *)
        List.iter
          (fun h -> out := { d with decl_desc = DFunc h } :: !out)
          hoisted;
        out := { d with decl_desc = DFunc fd' } :: !out
    | DImpl impl ->
        let methods', all_hoisted =
          List.fold_left
            (fun (accm, acch) m ->
              let m', h = hoist_impl_method m in
              (m' :: accm, h @ acch))
            ([], []) impl.impl_methods
        in
        (* Impl method's hoisted children become top-level funcs (not
           impl methods themselves — they're free-standing helpers that
           happen to have been defined inside a method body). *)
        List.iter
          (fun h -> out := { d with decl_desc = DFunc h } :: !out)
          all_hoisted;
        out :=
          {
            d with
            decl_desc = DImpl { impl with impl_methods = List.rev methods' };
          }
          :: !out
    | DPrivate ({ decl_desc = DFunc fd; _ } as inner) ->
        let inner =
          match (inner.decl_doc, d.decl_doc) with
          | None, Some doc -> { inner with decl_doc = Some doc }
          | _ -> inner
        in
        let fd', hoisted = hoist_func fd in
        (* A private function's nested children are NOT private — they're
           hidden already by their mangled names. Emit as top-level. *)
        List.iter
          (fun h -> out := { d with decl_desc = DFunc h } :: !out)
          hoisted;
        out :=
          { d with decl_desc = DPrivate { inner with decl_desc = DFunc fd' } }
          :: !out
    | _ -> out := d :: !out
  in
  List.iter process_decl prog;
  List.rev !out
