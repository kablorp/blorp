(** First-class function value normalization.

    Bare top-level function references are adapted into explicit eta closure
    adapters before Perceus so ownership-sensitive arguments are visible in
    Core and emitters only lower declared closure ABI shapes. Blorp owns
    lambda/task closure conversion in the backend tail. *)

open Core

type state = {
  mutable counter : int;
  mutable hoisted : core_decl list;
  mutable current_module : string option;
  constructor_names : (string, unit) Hashtbl.t;
  global_function_refs : (string, function_ref_target) Hashtbl.t;
  global_function_refs_by_identity :
    (string * int, function_ref_target) Hashtbl.t;
  global_function_refs_by_unambiguous_def_id :
    (int, function_ref_target option) Hashtbl.t;
}

and function_ref_target =
  | FunctionRefUser of core_func
  | FunctionRefBuiltin of string
  | FunctionRefForeign of foreign_call

(** Mutable state for eta-adapter synthesis. *)

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
  match v.vdef_id with
  | Some def_id -> (
      match
        Hashtbl.find_opt state.global_function_refs_by_identity
          (v.vname, def_id)
      with
      | Some _ as hit -> hit
      | None -> (
          (* DefIds are not globally unique across modules in current Core.
             Exact [name, id] identity is authoritative; raw-id fallback is
             only valid while the scanned program proves that id unambiguous. *)
          match
            Hashtbl.find_opt state.global_function_refs_by_unambiguous_def_id
              def_id
          with
          | Some (Some target) -> Some target
          | Some None | None -> function_ref_target_by_name state v.vname))
  | None -> function_ref_target_by_name state v.vname

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

    This keeps callbacks flowing through [CClosureCreate] before backend
    handoff. *)
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
            | FunctionRefUser f -> CKUser (f.cf_name, Some f.cf_def_id)
            | FunctionRefBuiltin c_name -> CKBuiltin c_name
            | FunctionRefForeign foreign -> CKForeign foreign
          in
          let body =
            {
              (* Use the resolved target name and def-id together. A bare
                 function reference may keep source spelling like [sqrt] while
                 [v.vdef_id] points at [std_float__sqrt]; mixing that source
                 spelling with the selected id would emit an undeclared
                 def-id-mangled symbol. *)
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
                    ca_moved_captures = [];
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

let rec adapt_function_refs_ctree (state : state) (bound : StringSet.t)
    (tree : ctree) : ctree =
  let adapt_value bound c =
    wrap_fn_ref_as_closure state ~bound (adapt_function_refs_expr state bound c)
  in
  match tree with
  | CTLeaf { ct_bindings; ct_body } ->
      let bound' =
        List.fold_left
          (fun acc binding -> add_bound_var acc binding.mb_var)
          bound ct_bindings
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
        | CKSelectedDirect _ | CKUser _ | CKForeign _ | CKBuiltin _
        | CKIntrinsic _ ->
            callee
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
  | CConcurrentlyLoop cf ->
      let iter' = adapt_value bound cf.cf_iter in
      let body_bound = add_bound_var bound cf.cf_var in
      let body' = adapt_value body_bound cf.cf_body in
      let timeout' = Option.map (adapt_value bound) cf.cf_timeout in
      let width' = Core.map_loop_width (adapt_value bound) cf.cf_width in
      {
        e with
        desc =
          CConcurrentlyLoop
            {
              cf with
              cf_iter = iter';
              cf_body = body';
              cf_timeout = timeout';
              cf_width = width';
            };
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

(** Scan program for constructor and global function names. *)
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
    (string, unit) Hashtbl.t
    * (string, function_ref_target) Hashtbl.t
    * ((string * int), function_ref_target) Hashtbl.t
    * (int, function_ref_target option) Hashtbl.t =
  let ctors = Hashtbl.create 32 in
  let function_refs = Hashtbl.create 64 in
  let function_refs_by_identity = Hashtbl.create 64 in
  let function_refs_by_unambiguous_def_id = Hashtbl.create 64 in
  let target_same_identity a b =
    match (a, b) with
    | FunctionRefUser fa, FunctionRefUser fb ->
        fa.cf_name = fb.cf_name && fa.cf_def_id = fb.cf_def_id
    | FunctionRefBuiltin ca, FunctionRefBuiltin cb -> ca = cb
    | FunctionRefForeign fa, FunctionRefForeign fb ->
        fa.fc_c_name = fb.fc_c_name && fa.fc_arg_passing = fb.fc_arg_passing
    | _ -> false
  in
  let register_target (f : core_func) target =
    Hashtbl.replace function_refs f.cf_name target;
    Hashtbl.replace function_refs_by_identity (f.cf_name, f.cf_def_id) target;
    match Hashtbl.find_opt function_refs_by_unambiguous_def_id f.cf_def_id with
    | None ->
        Hashtbl.replace function_refs_by_unambiguous_def_id f.cf_def_id
          (Some target)
    | Some (Some existing) when target_same_identity existing target -> ()
    | Some (Some _) ->
        Hashtbl.replace function_refs_by_unambiguous_def_id f.cf_def_id None
    | Some None -> ()
  in
  let register_user_func (f : core_func) =
    register_target f (FunctionRefUser f)
  in
  let register_builtin_func (f : core_func) =
    match builtin_c_name_for_func f with
    | Some c_name -> register_target f (FunctionRefBuiltin c_name)
    | None -> ()
  in
  let register_foreign_func (f : core_func) c_name arg_passing =
    register_target f
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
  ( ctors,
    function_refs,
    function_refs_by_identity,
    function_refs_by_unambiguous_def_id )

let make_state (prog : core_program) : state =
  let ( ctors,
        function_refs,
        function_refs_by_identity,
        function_refs_by_unambiguous_def_id ) =
    scan_names prog
  in
  {
    counter = 0;
    hoisted = [];
    current_module = None;
    constructor_names = ctors;
    global_function_refs = function_refs;
    global_function_refs_by_identity = function_refs_by_identity;
    global_function_refs_by_unambiguous_def_id =
      function_refs_by_unambiguous_def_id;
  }

(** Rewrite bare global function references into explicit closure eta adapters
    before Perceus. This keeps adapter bodies visible to ownership insertion
    instead of letting closure conversion synthesize post-Perceus [CDup] nodes. *)
let adapt_function_refs_program (prog : core_program) : core_program =
  let state = make_state prog in
  let adapted = List.map (adapt_function_refs_decl state) prog in
  adapted @ List.rev state.hoisted
