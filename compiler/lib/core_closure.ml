(** Closure conversion: hoist [CLambda] bodies to top-level functions,
    replace use sites with [CClosureCreate] nodes.

    Runs after Perceus (which needs [CLambda] structure for capture
    use counting) and before Core_emit.

    Each [CLambda] is transformed into:
    1. A hoisted [CDFunc] with [cf_closure_abi = Some _] and a void*
       calling convention (emitter generates the unboxing preamble).
    2. A [CClosureCreate] node at the original site that references
       the hoisted function and lists captured variables.

    [CConcurrent], [CDetach], and [CConcurrentFor] task bodies are also
    hoisted here so the task ABI, captures, and DefIds are visible in Core
    before emission. Bare top-level function references are adapted into
    explicit eta closure adapters before Perceus so ownership-sensitive
    arguments are visible in Core and emitters only lower declared closure
    ABI shapes. *)

open Core

(** Drop declarations that are compile-time templates after mono.

    The emitter already skips generic functions and generic impls. Closure
    conversion must do the same before hoisting lambdas; otherwise lambdas
    inside skipped generic templates become fresh non-generic closure-body
    functions and leak TyVar/TyMeta metadata into runtime ownership/codegen.
    Specialized concrete copies remain in the program and are converted
    normally. *)
let rec prune_non_runtime_templates_decl (d : core_decl) : core_decl option =
  match d.cd_desc with
  | CDFunc f when f.cf_type_params <> [] -> None
  | CDImpl i when Codegen_types.has_type_vars i.ci_for_type -> None
  | CDImpl i ->
      let methods =
        List.filter (fun (m : core_func) -> m.cf_type_params = []) i.ci_methods
      in
      if methods = [] then None
      else Some { d with cd_desc = CDImpl { i with ci_methods = methods } }
  | CDPrivate inner -> (
      match prune_non_runtime_templates_decl inner with
      | Some inner' -> Some { d with cd_desc = CDPrivate inner' }
      | None -> None)
  | CDType _ | CDRecord _ | CDImport _ | CDTypeAlias _ | CDTrait _ | CDFunc _
  | CDVar _ ->
      Some d

let prune_non_runtime_templates (prog : core_program) : core_program =
  List.filter_map prune_non_runtime_templates_decl prog

type state = {
  mutable counter : int;
  mutable task_counter : int;
  mutable hoisted : core_decl list;
  mutable current_module : string option;
  constructor_names : (string, unit) Hashtbl.t;
  global_function_refs : (string, function_ref_target) Hashtbl.t;
  wrap_function_refs : bool;
}

and function_ref_target =
  | FunctionRefUser of core_func
  | FunctionRefBuiltin of string
  | FunctionRefForeign of foreign_call

(** Mutable state for the conversion pass. *)

module StringSet = Set.Make (String)

let add_bound_var (bound : StringSet.t) (v : var) : StringSet.t =
  StringSet.add v.vname bound

let add_bound_names (bound : StringSet.t) (names : string list) : StringSet.t =
  List.fold_left (fun acc name -> StringSet.add name acc) bound names

let add_bound_typed_vars (bound : StringSet.t)
    (vars : (var * Ast.type_expr) list) : StringSet.t =
  List.fold_left (fun acc (v, _) -> add_bound_var acc v) bound vars

let function_ref_target_by_name (state : state) (name : string) :
    function_ref_target option =
  if Hashtbl.mem state.constructor_names name then None
  else
    match Hashtbl.find_opt state.global_function_refs name with
    | Some _ as hit -> hit
    | None -> (
        (* C-passthrough builtins like [sqrt] may remain as bare imported
           names after resolve/specialize because their C symbol is also the
           source name. Treat the builtin registry as the explicit identity
           source rather than capturing those names as runtime values. *)
        match Codegen_builtins.lookup_prefixed name with
        | Some c_name -> Some (FunctionRefBuiltin c_name)
        | None -> (
            match Codegen_builtins.lookup "" name with
            | Some c_name -> Some (FunctionRefBuiltin c_name)
            | None -> None))

let function_ref_target (state : state) (v : var) : function_ref_target option =
  function_ref_target_by_name state v.vname

(** Collect free variables in a Core expression, filtering out
    constructor names and global function names. Returns a sorted
    list of (name, type) pairs.

    This is the same logic as [Core_emit.collect_free_vars_filtered]
    but operates on [core] directly without emission context. *)
let collect_free_vars_filtered (state : state) (body : core)
    (params : (var * Ast.type_expr) list) : (string * Ast.type_expr) list =
  let module SS = Set.Make (String) in
  let module SM = Map.Make (String) in
  let rec go_ctree bound = function
    | CTLeaf { ct_bindings; ct_body } ->
        let inner =
          List.fold_left (fun s (v, _) -> SS.add v.vname s) bound ct_bindings
        in
        go inner ct_body
    | CTFail -> SM.empty
    | CTSwitchTag { cts_cases; cts_default; _ } ->
        let cases =
          List.fold_left
            (fun acc (_, sub) ->
              SM.union (fun _ a _ -> Some a) acc (go_ctree bound sub))
            SM.empty cts_cases
        in
        let default =
          match cts_default with Some d -> go_ctree bound d | None -> SM.empty
        in
        SM.union (fun _ a _ -> Some a) cases default
    | CTSwitchLit { ctl_cases; ctl_default; _ } ->
        let cases =
          List.fold_left
            (fun acc (_, sub) ->
              SM.union (fun _ a _ -> Some a) acc (go_ctree bound sub))
            SM.empty ctl_cases
        in
        SM.union (fun _ a _ -> Some a) cases (go_ctree bound ctl_default)
    | CTSwitchLen { ctl_len_cases; ctl_len_geq; ctl_len_default; _ } ->
        let cases =
          List.fold_left
            (fun acc (_, sub) ->
              SM.union (fun _ a _ -> Some a) acc (go_ctree bound sub))
            SM.empty ctl_len_cases
        in
        let geq =
          match ctl_len_geq with
          | Some (_, sub) -> go_ctree bound sub
          | None -> SM.empty
        in
        let default =
          match ctl_len_default with
          | Some d -> go_ctree bound d
          | None -> SM.empty
        in
        SM.union
          (fun _ a _ -> Some a)
          cases
          (SM.union (fun _ a _ -> Some a) geq default)
  and go bound e =
    match e.desc with
    | CVar v ->
        if SS.mem v.vname bound then SM.empty
        else if Hashtbl.mem state.constructor_names v.vname then SM.empty
        else if Option.is_some (function_ref_target state v) then SM.empty
        else SM.singleton v.vname e.ty
    | CLit _ | CVoid | CBreak | CContinue -> SM.empty
    | CLambda lam ->
        let inner =
          List.fold_left (fun s (v, _) -> SS.add v.vname s) bound lam.lam_params
        in
        go inner lam.lam_body
    | CClosureCreate cc ->
        List.fold_left
          (fun acc (n, ty) -> if SS.mem n bound then acc else SM.add n ty acc)
          SM.empty cc.cc_captures
    | CLet (b, body) ->
        let rhs = go bound b.bind_rhs in
        let body = go (SS.add b.bind_var.vname bound) body in
        SM.union (fun _ a _ -> Some a) rhs body
    | CBorrowLet (b, body) ->
        let rhs = go bound b.borrow_rhs in
        let body = go (SS.add b.borrow_var.vname bound) body in
        SM.union (fun _ a _ -> Some a) rhs body
    | CResourceScope s ->
        let acquire = go bound s.rs_acquire in
        let scoped_bound = SS.add s.rs_var.vname bound in
        let body = go scoped_bound s.rs_body in
        let cleanup = go scoped_bound s.rs_cleanup in
        SM.union
          (fun _ a _ -> Some a)
          acquire
          (SM.union (fun _ a _ -> Some a) body cleanup)
    | CCall (kind, callee, args) ->
        let callee_fv =
          match kind with
          | CKUnknown | CKClosure -> go bound callee
          | _ -> SM.empty
        in
        List.fold_left
          (fun acc a -> SM.union (fun _ a _ -> Some a) acc (go bound a))
          callee_fv args
    | CMatch (scrut, tree) ->
        SM.union (fun _ a _ -> Some a) (go bound scrut) (go_ctree bound tree)
    | CFor (binder, iter, body) ->
        let iter_fv = go bound iter in
        let body_fv = go (SS.add binder.loop_var.vname bound) body in
        SM.union (fun _ a _ -> Some a) iter_fv body_fv
    | CListHandoff h ->
        let source_fv = go bound h.lh_source in
        let capacity_fv = go bound h.lh_capacity in
        let inner =
          bound
          |> SS.add h.lh_source_var.vname
          |> SS.add h.lh_result_var.vname
          |> SS.add h.lh_len_var.vname |> SS.add h.lh_out_var.vname
        in
        let body_fv = go inner h.lh_body in
        SM.union
          (fun _ a _ -> Some a)
          source_fv
          (SM.union (fun _ a _ -> Some a) capacity_fv body_fv)
    | CConcurrent block ->
        let rhs_fv =
          List.fold_left
            (fun acc (b : conc_binding) ->
              SM.union (fun _ a _ -> Some a) acc (go bound b.cb_rhs))
            SM.empty block.conc_bindings
        in
        let body_bound =
          List.fold_left
            (fun acc (b : conc_binding) -> SS.add b.cb_var.vname acc)
            bound block.conc_bindings
        in
        let body_fv = go body_bound block.conc_body in
        let timeout_fv =
          match block.conc_timeout with
          | Some timeout -> go bound timeout
          | None -> SM.empty
        in
        SM.union
          (fun _ a _ -> Some a)
          rhs_fv
          (SM.union (fun _ a _ -> Some a) body_fv timeout_fv)
    | CConcurrentFor cf ->
        let iter_fv = go bound cf.cf_iter in
        let body_fv = go (SS.add cf.cf_var.vname bound) cf.cf_body in
        let timeout_fv =
          match cf.cf_timeout with
          | Some timeout -> go bound timeout
          | None -> SM.empty
        in
        SM.union
          (fun _ a _ -> Some a)
          iter_fv
          (SM.union (fun _ a _ -> Some a) body_fv timeout_fv)
    | CMatchArms (scrut, arms) ->
        let scrut_fv = go bound scrut in
        List.fold_left
          (fun acc (pat, body) ->
            let pat_vars = Ast.collect_pattern_vars pat in
            let inner = List.fold_left (fun s n -> SS.add n s) bound pat_vars in
            SM.union (fun _ a _ -> Some a) acc (go inner body))
          scrut_fv arms
    | CIf (cond, then_, else_) ->
        let c = go bound cond in
        let t = go bound then_ in
        let e = go bound else_ in
        SM.union (fun _ a _ -> Some a) c (SM.union (fun _ a _ -> Some a) t e)
    | CSeq (a, b) -> SM.union (fun _ a _ -> Some a) (go bound a) (go bound b)
    | CWhile (cond, body) ->
        SM.union (fun _ a _ -> Some a) (go bound cond) (go bound body)
    | _ ->
        (* For all other nodes, fold over children *)
        fold_immediate_children
          (fun acc child -> SM.union (fun _ a _ -> Some a) acc (go bound child))
          SM.empty e
  in
  let param_names =
    List.fold_left (fun s (v, _) -> SS.add v.vname s) SS.empty params
  in
  let fv_map = go param_names body in
  SM.bindings fv_map |> List.sort (fun (a, _) (b, _) -> String.compare a b)

(** [wrap_fn_ref_as_closure state arg] — if [arg] is a bare [CVar]
    referring to a top-level function (not a local binding or a
    constructor) and its type is [TyFunc], synthesize an eta-expansion
    adapter function with closure ABI and return a [CClosureCreate]
    node that references it.

    The adapter is needed because a bare user function has signature
    like [long add_one(long)] — not the closure ABI
    [void* _fn(void* env, void* arg)] that callbacks are invoked with.
    Passing the raw function pointer at the call site would have the
    callee interpret it as a closure struct pointer and crash.

    This mirrors the lambda-hoisting path, so all callbacks at emit
time flow through [CClosureCreate]. *)
let wrap_fn_ref_as_closure (state : state) ~(bound : StringSet.t) (arg : core) :
    core =
  match (arg.desc, arg.ty) with
  | CVar v, Ast.TyFunc { params; return; is_pure }
    when not (StringSet.mem v.vname bound) -> (
      match function_ref_target state v with
      | None -> arg
      | Some target ->
          let loc = arg.loc in
          let fresh_params =
            List.mapi
              (fun i pty -> (Var.named (Printf.sprintf "__eta_arg_%d" i), pty))
              params
          in
          let param_refs =
            List.map
              (fun (pv, pty) -> { desc = CVar pv; ty = pty; loc })
              fresh_params
          in
          let callee_node = { desc = CVar v; ty = arg.ty; loc } in
          let call_kind =
            match target with
            | FunctionRefUser f ->
                let def_id =
                  match v.vdef_id with
                  | Some _ as id -> id
                  | None -> Some f.cf_def_id
                in
                CKUser (v.vname, def_id)
            | FunctionRefBuiltin c_name -> CKBuiltin c_name
            | FunctionRefForeign foreign -> CKForeign foreign
          in
          let body =
            {
              (* A4.2: preserve [v.vdef_id] so the eta adapter's inner call
           hits the same mangled C symbol as the target function's
           decl site. [Core_closure] runs AFTER [Core_resolve] so v
           already carries the resolved def_id. *)
              desc = CCall (call_kind, callee_node, param_refs);
              ty = return;
              loc;
            }
          in
          let id = state.counter in
          state.counter <- id + 1;
          let name = Printf.sprintf "_blorp_eta_%d" id in
          let def_id = Session.mint_def_id (Session.current ()) in
          let cf_params =
            List.map
              (fun (cp_name, cp_ty) -> { cp_name; cp_ty; cp_loc = loc })
              fresh_params
          in
          let hoisted_func =
            {
              cf_name = name;
              cf_module = state.current_module;
              cf_type_params = [];
              cf_params;
              cf_return_ty = return;
              cf_body = Some body;
              cf_is_pure = is_pure;
              cf_kind =
                CFClosureBody
                  {
                    ca_params = fresh_params;
                    ca_captures = [];
                    ca_task_abi = false;
                  };
              cf_def_id = def_id;
            }
          in
          state.hoisted <-
            { cd_desc = CDFunc hoisted_func; cd_loc = loc; cd_doc = None }
            :: state.hoisted;
          {
            arg with
            desc =
              CClosureCreate
                { cc_func = name; cc_def_id = def_id; cc_captures = [] };
          })
  | _ -> arg

let hoist_task_closure (state : state) ~(loc : Ast.loc) ~(body : core)
    ~(return_ty : Ast.type_expr) : task_closure =
  let captures = collect_free_vars_filtered state body [] in
  let id = state.task_counter in
  state.task_counter <- id + 1;
  let name = Printf.sprintf "_blorp_task_%d" id in
  let def_id = Session.mint_def_id (Session.current ()) in
  let hoisted_func =
    {
      cf_name = name;
      cf_module = state.current_module;
      cf_type_params = [];
      cf_params = [];
      cf_return_ty = return_ty;
      cf_body = Some body;
      cf_is_pure = false;
      cf_kind =
        CFClosureBody
          { ca_params = []; ca_captures = captures; ca_task_abi = true };
      cf_def_id = def_id;
    }
  in
  state.hoisted <-
    { cd_desc = CDFunc hoisted_func; cd_loc = loc; cd_doc = None }
    :: state.hoisted;
  {
    tc_func = name;
    tc_def_id = def_id;
    tc_captures = captures;
    tc_return_ty = return_ty;
  }

let maybe_wrap_fn_ref_as_closure (state : state) ~(wrap_fn_refs : bool)
    ~(bound : StringSet.t) (arg : core) : core =
  if wrap_fn_refs && state.wrap_function_refs then
    wrap_fn_ref_as_closure state ~bound arg
  else arg

let rec adapt_function_refs_ctree (state : state) (bound : StringSet.t)
    (tree : ctree) : ctree =
  let adapt_value bound c =
    wrap_fn_ref_as_closure state ~bound (adapt_function_refs_expr state bound c)
  in
  match tree with
  | CTLeaf { ct_bindings; ct_body } ->
      let bound' =
        List.fold_left (fun acc (v, _) -> add_bound_var acc v) bound ct_bindings
      in
      CTLeaf { ct_bindings; ct_body = adapt_value bound' ct_body }
  | CTFail -> CTFail
  | CTSwitchTag ({ cts_cases; cts_default; _ } as s) ->
      CTSwitchTag
        {
          s with
          cts_cases =
            List.map
              (fun (name, sub) ->
                (name, adapt_function_refs_ctree state bound sub))
              cts_cases;
          cts_default =
            Option.map (adapt_function_refs_ctree state bound) cts_default;
        }
  | CTSwitchLit ({ ctl_cases; ctl_default; _ } as s) ->
      CTSwitchLit
        {
          s with
          ctl_cases =
            List.map
              (fun (lit, sub) ->
                (lit, adapt_function_refs_ctree state bound sub))
              ctl_cases;
          ctl_default = adapt_function_refs_ctree state bound ctl_default;
        }
  | CTSwitchLen ({ ctl_len_cases; ctl_len_geq; ctl_len_default; _ } as s) ->
      CTSwitchLen
        {
          s with
          ctl_len_cases =
            List.map
              (fun (len, sub) ->
                (len, adapt_function_refs_ctree state bound sub))
              ctl_len_cases;
          ctl_len_geq =
            Option.map
              (fun (len, sub) ->
                (len, adapt_function_refs_ctree state bound sub))
              ctl_len_geq;
          ctl_len_default =
            Option.map (adapt_function_refs_ctree state bound) ctl_len_default;
        }

and adapt_function_refs_expr (state : state) (bound : StringSet.t) (e : core) :
    core =
  let adapt_value bound c =
    wrap_fn_ref_as_closure state ~bound (adapt_function_refs_expr state bound c)
  in
  match e.desc with
  | CCall (kind, callee, args) ->
      let callee' =
        match kind with
        | CKClosure | CKUnknown -> adapt_value bound callee
        | CKUser _ | CKForeign _ | CKBuiltin _ | CKIntrinsic _ -> callee
      in
      let args' = List.map (adapt_value bound) args in
      { e with desc = CCall (kind, callee', args') }
  | CLet (b, body) ->
      let rhs' = adapt_value bound b.bind_rhs in
      let body_bound = add_bound_var bound b.bind_var in
      let body' = adapt_value body_bound body in
      { e with desc = CLet ({ b with bind_rhs = rhs' }, body') }
  | CBorrowLet (b, body) ->
      let rhs' = adapt_value bound b.borrow_rhs in
      let body_bound = add_bound_var bound b.borrow_var in
      let body' = adapt_value body_bound body in
      { e with desc = CBorrowLet ({ b with borrow_rhs = rhs' }, body') }
  | CResourceScope s ->
      let acquire' = adapt_value bound s.rs_acquire in
      let body_bound = add_bound_var bound s.rs_var in
      let body' = adapt_value body_bound s.rs_body in
      let cleanup' = adapt_value body_bound s.rs_cleanup in
      {
        e with
        desc =
          CResourceScope
            {
              s with
              rs_acquire = acquire';
              rs_body = body';
              rs_cleanup = cleanup';
            };
      }
  | CLambda lam ->
      let body_bound = add_bound_typed_vars bound lam.lam_params in
      {
        e with
        desc =
          CLambda { lam with lam_body = adapt_value body_bound lam.lam_body };
      }
  | CMatchArms (scrut, arms) ->
      let scrut' = adapt_value bound scrut in
      let arms' =
        List.map
          (fun (pat, body) ->
            let arm_bound =
              add_bound_names bound (Ast.collect_pattern_vars pat)
            in
            (pat, adapt_value arm_bound body))
          arms
      in
      { e with desc = CMatchArms (scrut', arms') }
  | CMatch (scrut, tree) ->
      let scrut' = adapt_value bound scrut in
      let tree' = adapt_function_refs_ctree state bound tree in
      { e with desc = CMatch (scrut', tree') }
  | CFor (binder, iter, body) ->
      let iter' = adapt_value bound iter in
      let body_bound = add_bound_var bound binder.loop_var in
      let body' = adapt_value body_bound body in
      { e with desc = CFor (binder, iter', body') }
  | CListHandoff h ->
      let source' = adapt_value bound h.lh_source in
      let capacity' = adapt_value bound h.lh_capacity in
      let body_bound =
        List.fold_left add_bound_var bound
          [ h.lh_source_var; h.lh_result_var; h.lh_len_var; h.lh_out_var ]
      in
      let body' = adapt_value body_bound h.lh_body in
      {
        e with
        desc =
          CListHandoff
            {
              h with
              lh_source = source';
              lh_capacity = capacity';
              lh_body = body';
            };
      }
  | CConcurrent block ->
      let bindings' =
        List.map
          (fun b -> { b with cb_rhs = adapt_value bound b.cb_rhs })
          block.conc_bindings
      in
      let body_bound =
        List.fold_left
          (fun acc b -> add_bound_var acc b.cb_var)
          bound block.conc_bindings
      in
      let body' = adapt_value body_bound block.conc_body in
      let timeout' = Option.map (adapt_value bound) block.conc_timeout in
      {
        e with
        desc =
          CConcurrent
            {
              block with
              conc_bindings = bindings';
              conc_body = body';
              conc_timeout = timeout';
            };
      }
  | CConcurrentFor cf ->
      let iter' = adapt_value bound cf.cf_iter in
      let body_bound = add_bound_var bound cf.cf_var in
      let body' = adapt_value body_bound cf.cf_body in
      let timeout' = Option.map (adapt_value bound) cf.cf_timeout in
      {
        e with
        desc =
          CConcurrentFor
            { cf with cf_iter = iter'; cf_body = body'; cf_timeout = timeout' };
      }
  | _ -> map_children (adapt_value bound) e

let adapt_function_refs_func (state : state) (f : core_func) : core_func =
  match f.cf_body with
  | None -> f
  | Some _ when f.cf_type_params <> [] -> f
  | Some body ->
      let prev_module = state.current_module in
      state.current_module <- f.cf_module;
      let body' =
        wrap_fn_ref_as_closure state ~bound:StringSet.empty
          (adapt_function_refs_expr state StringSet.empty body)
      in
      let result = { f with cf_body = Some body' } in
      state.current_module <- prev_module;
      result

let adapt_function_refs_var (state : state) (v : core_var) : core_var =
  let prev_module = state.current_module in
  state.current_module <- v.cv_module;
  let result =
    {
      v with
      cv_init =
        wrap_fn_ref_as_closure state ~bound:StringSet.empty
          (adapt_function_refs_expr state StringSet.empty v.cv_init);
    }
  in
  state.current_module <- prev_module;
  result

let adapt_function_refs_impl (state : state) (i : core_impl) : core_impl =
  if Codegen_types.has_type_vars i.ci_for_type then i
  else
    {
      i with
      ci_methods = List.map (adapt_function_refs_func state) i.ci_methods;
    }

let rec adapt_function_refs_decl (state : state) (d : core_decl) : core_decl =
  let desc' =
    match d.cd_desc with
    | CDFunc f -> CDFunc (adapt_function_refs_func state f)
    | CDVar v -> CDVar (adapt_function_refs_var state v)
    | CDImpl i -> CDImpl (adapt_function_refs_impl state i)
    | CDPrivate inner -> CDPrivate (adapt_function_refs_decl state inner)
    | (CDType _ | CDRecord _ | CDImport _ | CDTypeAlias _ | CDTrait _) as other
      ->
        other
  in
  { d with cd_desc = desc' }

(** Convert a single expression, hoisting any [CLambda] nodes. Bottom-up:
    nested lambdas are converted first. Standalone tests may enable
    function-reference wrapping here, but the main pipeline creates those
    adapters before Perceus via [adapt_function_refs_program]. *)
let rec convert_expr (state : state) ~(wrap_fn_refs : bool)
    ?(bound = StringSet.empty) (e : core) : core =
  (* Recurse into children with context-aware wrapping. When function-reference
     wrapping is enabled for standalone tests, direct-call callees stay bare
     while first-class value positions are adapted. *)
  let e =
    match e.desc with
    | CLambda lam ->
        let body_bound = add_bound_typed_vars bound lam.lam_params in
        let body' =
          maybe_wrap_fn_ref_as_closure state ~wrap_fn_refs ~bound:body_bound
            (convert_expr state ~wrap_fn_refs ~bound:body_bound lam.lam_body)
        in
        { e with desc = CLambda { lam with lam_body = body' } }
    | CCall (kind, callee, args) ->
        let callee' = convert_expr state ~wrap_fn_refs ~bound callee in
        let args' =
          List.map
            (fun a ->
              maybe_wrap_fn_ref_as_closure state ~wrap_fn_refs ~bound
                (convert_expr state ~wrap_fn_refs ~bound a))
            args
        in
        { e with desc = CCall (kind, callee', args') }
    | CConcurrent block ->
        let bindings' =
          List.map
            (fun (b : conc_binding) ->
              let rhs' =
                maybe_wrap_fn_ref_as_closure state ~wrap_fn_refs ~bound
                  (convert_expr state ~wrap_fn_refs ~bound b.cb_rhs)
              in
              let task' =
                match b.cb_task with
                | Some task -> Some task
                | None ->
                    Some
                      (hoist_task_closure state ~loc:b.cb_rhs.loc ~body:rhs'
                         ~return_ty:rhs'.ty)
              in
              { b with cb_rhs = rhs'; cb_task = task' })
            block.conc_bindings
        in
        let body_bound =
          List.fold_left
            (fun acc (b : conc_binding) -> add_bound_var acc b.cb_var)
            bound block.conc_bindings
        in
        let body' =
          maybe_wrap_fn_ref_as_closure state ~wrap_fn_refs ~bound:body_bound
            (convert_expr state ~wrap_fn_refs ~bound:body_bound block.conc_body)
        in
        let timeout' =
          Option.map
            (fun timeout ->
              maybe_wrap_fn_ref_as_closure state ~wrap_fn_refs ~bound
                (convert_expr state ~wrap_fn_refs ~bound timeout))
            block.conc_timeout
        in
        {
          e with
          desc =
            CConcurrent
              {
                block with
                conc_bindings = bindings';
                conc_body = body';
                conc_timeout = timeout';
              };
        }
    | CDetach detach ->
        let body' =
          maybe_wrap_fn_ref_as_closure state ~wrap_fn_refs ~bound
            (convert_expr state ~wrap_fn_refs ~bound detach.detach_body)
        in
        let task' =
          match detach.detach_task with
          | Some task -> Some task
          | None ->
              Some
                (hoist_task_closure state ~loc:detach.detach_body.loc
                   ~body:body'
                   ~return_ty:(Ast.TyNamed ("Void", [])))
        in
        { e with desc = CDetach { detach_body = body'; detach_task = task' } }
    | CConcurrentFor cf ->
        let iter' =
          maybe_wrap_fn_ref_as_closure state ~wrap_fn_refs ~bound
            (convert_expr state ~wrap_fn_refs ~bound cf.cf_iter)
        in
        let body_bound = add_bound_var bound cf.cf_var in
        let body' =
          maybe_wrap_fn_ref_as_closure state ~wrap_fn_refs ~bound:body_bound
            (convert_expr state ~wrap_fn_refs ~bound:body_bound cf.cf_body)
        in
        let timeout' =
          Option.map
            (fun timeout ->
              maybe_wrap_fn_ref_as_closure state ~wrap_fn_refs ~bound
                (convert_expr state ~wrap_fn_refs ~bound timeout))
            cf.cf_timeout
        in
        let task' =
          match cf.cf_task with
          | Some task -> Some task
          | None ->
              Some
                (hoist_task_closure state ~loc:cf.cf_body.loc ~body:body'
                   ~return_ty:body'.ty)
        in
        {
          e with
          desc =
            CConcurrentFor
              {
                cf with
                cf_iter = iter';
                cf_body = body';
                cf_timeout = timeout';
                cf_task = task';
              };
        }
    | CLet (b, body) ->
        let rhs' =
          maybe_wrap_fn_ref_as_closure state ~wrap_fn_refs ~bound
            (convert_expr state ~wrap_fn_refs ~bound b.bind_rhs)
        in
        let body_bound = add_bound_var bound b.bind_var in
        let body' =
          maybe_wrap_fn_ref_as_closure state ~wrap_fn_refs ~bound:body_bound
            (convert_expr state ~wrap_fn_refs ~bound:body_bound body)
        in
        { e with desc = CLet ({ b with bind_rhs = rhs' }, body') }
    | CBorrowLet (b, body) ->
        let rhs' =
          maybe_wrap_fn_ref_as_closure state ~wrap_fn_refs ~bound
            (convert_expr state ~wrap_fn_refs ~bound b.borrow_rhs)
        in
        let body_bound = add_bound_var bound b.borrow_var in
        let body' =
          maybe_wrap_fn_ref_as_closure state ~wrap_fn_refs ~bound:body_bound
            (convert_expr state ~wrap_fn_refs ~bound:body_bound body)
        in
        { e with desc = CBorrowLet ({ b with borrow_rhs = rhs' }, body') }
    | CResourceScope s ->
        let acquire' =
          maybe_wrap_fn_ref_as_closure state ~wrap_fn_refs ~bound
            (convert_expr state ~wrap_fn_refs ~bound s.rs_acquire)
        in
        let body_bound = add_bound_var bound s.rs_var in
        let body' =
          maybe_wrap_fn_ref_as_closure state ~wrap_fn_refs ~bound:body_bound
            (convert_expr state ~wrap_fn_refs ~bound:body_bound s.rs_body)
        in
        let cleanup' =
          maybe_wrap_fn_ref_as_closure state ~wrap_fn_refs ~bound:body_bound
            (convert_expr state ~wrap_fn_refs ~bound:body_bound s.rs_cleanup)
        in
        {
          e with
          desc =
            CResourceScope
              {
                s with
                rs_acquire = acquire';
                rs_body = body';
                rs_cleanup = cleanup';
              };
        }
    | CFor (binder, iter, body) ->
        let iter' =
          maybe_wrap_fn_ref_as_closure state ~wrap_fn_refs ~bound
            (convert_expr state ~wrap_fn_refs ~bound iter)
        in
        let body_bound = add_bound_var bound binder.loop_var in
        let body' =
          maybe_wrap_fn_ref_as_closure state ~wrap_fn_refs ~bound:body_bound
            (convert_expr state ~wrap_fn_refs ~bound:body_bound body)
        in
        { e with desc = CFor (binder, iter', body') }
    | CMatchArms (scrut, arms) ->
        let scrut' =
          maybe_wrap_fn_ref_as_closure state ~wrap_fn_refs ~bound
            (convert_expr state ~wrap_fn_refs ~bound scrut)
        in
        let arms' =
          List.map
            (fun (pat, body) ->
              let arm_bound =
                add_bound_names bound (Ast.collect_pattern_vars pat)
              in
              let body' =
                maybe_wrap_fn_ref_as_closure state ~wrap_fn_refs
                  ~bound:arm_bound
                  (convert_expr state ~wrap_fn_refs ~bound:arm_bound body)
              in
              (pat, body'))
            arms
        in
        { e with desc = CMatchArms (scrut', arms') }
    | _ ->
        map_children
          (fun c ->
            maybe_wrap_fn_ref_as_closure state ~wrap_fn_refs ~bound
              (convert_expr state ~wrap_fn_refs ~bound c))
          e
  in
  match e.desc with
  | CLambda lam ->
      let captures =
        collect_free_vars_filtered state lam.lam_body lam.lam_params
      in
      let id = state.counter in
      state.counter <- id + 1;
      let name = Printf.sprintf "_blorp_clambda_%d" id in
      let def_id = Session.mint_def_id (Session.current ()) in
      (* Hoist the function body as a CDFunc with closure ABI *)
      let hoisted_func =
        {
          cf_name = name;
          cf_module = state.current_module;
          cf_type_params = [];
          cf_params = [];
          cf_return_ty = lam.lam_return_ty;
          cf_body = Some lam.lam_body;
          cf_is_pure = lam.lam_is_pure;
          cf_kind =
            CFClosureBody
              {
                ca_params = lam.lam_params;
                ca_captures = captures;
                ca_task_abi = false;
              };
          cf_def_id = def_id;
        }
      in
      state.hoisted <-
        { cd_desc = CDFunc hoisted_func; cd_loc = e.loc; cd_doc = None }
        :: state.hoisted;
      {
        e with
        desc =
          CClosureCreate
            { cc_func = name; cc_def_id = def_id; cc_captures = captures };
      }
  | _ -> e

(** Convert lambdas in a function body. *)
let convert_func (state : state) ~(wrap_fn_refs : bool) (f : core_func) :
    core_func =
  match f.cf_body with
  | None -> f
  | Some body ->
      let prev_module = state.current_module in
      state.current_module <- f.cf_module;
      let body' =
        maybe_wrap_fn_ref_as_closure state ~wrap_fn_refs ~bound:StringSet.empty
          (convert_expr state ~wrap_fn_refs ~bound:StringSet.empty body)
      in
      let result = { f with cf_body = Some body' } in
      state.current_module <- prev_module;
      result

(** Convert lambdas in a variable initializer. *)
let convert_var (state : state) (v : core_var) : core_var =
  let prev_module = state.current_module in
  state.current_module <- v.cv_module;
  let result =
    {
      v with
      cv_init =
        maybe_wrap_fn_ref_as_closure state ~wrap_fn_refs:true
          ~bound:StringSet.empty
          (convert_expr state ~wrap_fn_refs:true ~bound:StringSet.empty
             v.cv_init);
    }
  in
  state.current_module <- prev_module;
  result

(** Convert lambdas in impl methods. *)
let convert_impl (state : state) (i : core_impl) : core_impl =
  {
    i with
    ci_methods = List.map (convert_func state ~wrap_fn_refs:true) i.ci_methods;
  }

(** Convert lambdas in all declarations. The main pipeline disables function-ref
    wrapping here because [adapt_function_refs_program] already created those
    adapters before Perceus. *)
let rec convert_decl (state : state) (d : core_decl) : core_decl =
  let desc' =
    match d.cd_desc with
    | CDFunc f -> CDFunc (convert_func state ~wrap_fn_refs:true f)
    | CDVar v -> CDVar (convert_var state v)
    | CDImpl i -> CDImpl (convert_impl state i)
    | CDPrivate inner -> CDPrivate (convert_decl state inner)
    | (CDType _ | CDRecord _ | CDImport _ | CDTypeAlias _ | CDTrait _) as other
      ->
        other
  in
  { d with cd_desc = desc' }

(** Scan program for constructor and global function names.
    Needed to filter free variables (constructors and globals
    are not captures). *)
let starts_with s prefix =
  let slen = String.length s in
  let plen = String.length prefix in
  slen >= plen && String.sub s 0 plen = prefix

let ends_with s suffix =
  let slen = String.length s in
  let suffix_len = String.length suffix in
  slen >= suffix_len && String.sub s (slen - suffix_len) suffix_len = suffix

let strip_mono_suffix name =
  let marker = "__mono_" in
  let marker_len = String.length marker in
  let rec find i =
    if i + marker_len > String.length name then name
    else if String.sub name i marker_len = marker then String.sub name 0 i
    else find (i + 1)
  in
  find 0

let source_name_for_builtin_lookup (f : core_func) : string =
  let source_name = strip_mono_suffix f.cf_name in
  let source_name =
    match f.cf_module with
    | None -> source_name
    | Some module_path ->
        let prefix = Codegen_names.sanitize_module_name module_path ^ "__" in
        if starts_with source_name prefix then
          String.sub source_name (String.length prefix)
            (String.length source_name - String.length prefix)
        else source_name
  in
  let pure_suffix = "__pure" in
  if ends_with source_name pure_suffix then
    String.sub source_name 0
      (String.length source_name - String.length pure_suffix)
  else source_name

let builtin_c_name_for_func (f : core_func) : string option =
  let source_name = source_name_for_builtin_lookup f in
  let module_path = Option.value f.cf_module ~default:"" in
  match Codegen_builtins.lookup module_path source_name with
  | Some _ as hit -> hit
  | None ->
      if module_path = "" then None else Codegen_builtins.lookup "" source_name

let scan_names (prog : core_program) :
    (string, unit) Hashtbl.t * (string, function_ref_target) Hashtbl.t =
  let ctors = Hashtbl.create 32 in
  let function_refs = Hashtbl.create 64 in
  let register_user_func (f : core_func) =
    Hashtbl.replace function_refs f.cf_name (FunctionRefUser f)
  in
  let register_builtin_func (f : core_func) =
    match builtin_c_name_for_func f with
    | Some c_name ->
        Hashtbl.replace function_refs f.cf_name (FunctionRefBuiltin c_name)
    | None -> ()
  in
  let register_foreign_func (f : core_func) c_name arg_passing =
    Hashtbl.replace function_refs f.cf_name
      (FunctionRefForeign { fc_c_name = c_name; fc_arg_passing = arg_passing })
  in
  (* Builtin constructors *)
  List.iter
    (fun n -> Hashtbl.replace ctors n ())
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
  List.iter
    (fun d ->
      let rec visit d =
        match d.cd_desc with
        | CDType t ->
            List.iter
              (fun (v : Ast.variant) -> Hashtbl.replace ctors v.variant_name ())
              t.type_variants
        | CDFunc f when f.cf_body <> None -> register_user_func f
        | CDFunc f -> (
            match f.cf_kind with
            | CFForeign { c_name; arg_passing; _ } ->
                register_foreign_func f c_name arg_passing
            | CFBuiltin -> register_builtin_func f
            | CFUser | CFClosureBody _ -> ())
        | CDImpl i ->
            List.iter (fun (m : core_func) -> register_user_func m) i.ci_methods
        | CDPrivate inner -> visit inner
        | _ -> ()
      in
      visit d)
    prog;
  (ctors, function_refs)

let make_state ?(wrap_function_refs = true) (prog : core_program) : state =
  let ctors, function_refs = scan_names prog in
  {
    counter = 0;
    task_counter = 0;
    hoisted = [];
    current_module = None;
    constructor_names = ctors;
    global_function_refs = function_refs;
    wrap_function_refs;
  }

(** Rewrite bare global function references into explicit closure eta adapters
    before Perceus. This keeps adapter bodies visible to ownership insertion
    instead of letting closure conversion synthesize post-Perceus [CDup] nodes. *)
let adapt_function_refs_program (prog : core_program) : core_program =
  let state = make_state prog in
  let adapted = List.map (adapt_function_refs_decl state) prog in
  adapted @ List.rev state.hoisted

(** Convert all [CLambda] nodes in a program to [CClosureCreate] + hoisted
    [CDFunc] declarations. Returns the program with hoisted functions
    prepended. *)
let convert_program ?(wrap_function_refs = true) (prog : core_program) :
    core_program =
  let prog = prune_non_runtime_templates prog in
  let state = make_state ~wrap_function_refs prog in
  let converted = List.map (convert_decl state) prog in
  (* Append hoisted lambda functions after the main program —
     they reference module functions that must be forward-declared first *)
  converted @ List.rev state.hoisted
