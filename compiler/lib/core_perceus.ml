(** Perceus-style explicit reference counting insertion.

    Walks a Core expression and inserts explicit [CDup] / [CDrop]
    nodes at the points where a managed (heap-allocated) value's
    refcount must be adjusted. The long-term goal is Koka-style
    garbage-free precise reference counting: every managed value is
    dropped at its exact last use, not at scope exit.

    {1 Current scope}

    - Classifies built-in and user-declared managed types.
    - Inserts drops for unused managed [CLet] bindings.
    - Inserts dups for multi-use managed [CLet] bindings in linear bodies.
    - Handles [CIf], raw [CMatchArms], and compiled [CMatch] by taking
      max-use counts across mutually exclusive paths and dropping excess
      refs on shorter paths.
    - Retains aliases created by [let y = x] and [let y = obj.field] so COW
      operations can detect sharing instead of mutating through a false
      unique refcount.
    - Normalizes direct managed field aliases passed to consuming / COW-consuming
      calls through temporary bindings so the alias-retain rule applies before
      mutation.
    - Honors known intrinsic / builtin ownership contracts in linear bodies
      and supported branch forms, distinguishing borrowed arguments from
      consuming / COW-consuming ones.
    - Infers conservative user-function ownership contracts from function
      bodies so read-only direct calls can borrow while passthrough / mutating
      calls still consume.
    - Normalizes managed aliases returned from lambdas before closure conversion
      hoists those bodies into top-level functions.
    - Treats direct foreign calls as borrowed at the Perceus layer; any FFI
      copying / conversion remains an emit/runtime boundary concern.
    - Handles [CConcurrent] binding lifetimes conservatively.
    - Handles [CConcurrent], [CConcurrentFor], and [CDetach] captures as
      borrowed/captured spawn-site uses so the original owner is dropped after
      the task closure has retained it.

    {1 What's NOT handled yet}

    - {b Complete formal call ownership}: known runtime contracts, direct user
      calls, foreign calls, and closure calls are contract-backed. Closure
      calls borrow the closure object and arguments; managed callback returns
      are owned by the callee before crossing the call boundary.
    - {b Function parameter ownership}: direct user-call contracts are inferred
      from bodies, but this is still an internal ABI rather than source-level
      ownership syntax.
    - {b Loop liveness}: [CFor] and borrowed-only [CWhile] bodies are modeled
      precisely enough to drop owners after the loop.
    - {b Drop specialization}: C emission specializes stack Result drops and
      ARC-only source values, but known-shape nested field destructors still
      use runtime destructor dispatch.
    - {b Reuse analysis / FBIP}: drops are not yet matched with compatible
      allocations to drive allocation reuse.
    - {b COW strategy selection}: runtime COW remains the safety guard; the
      compiler does not yet choose between borrow, consume/reuse, view, and
      allocate strategies for high-level operations such as list combinators. *)

open Core
module StringSet = Set.Make (String)

(* ============================================================================
   Managed-type predicate with program-level type registry
   ============================================================================ *)

type type_env = {
  type_registry : Codegen_types.registry;
  global_function_names : (string, unit) Hashtbl.t;
  global_function_ids : (int, unit) Hashtbl.t;
  constructor_call_contracts_by_name :
    (string, Core_ownership.call_contract) Hashtbl.t;
  constructor_call_contracts_by_id :
    (int, Core_ownership.call_contract) Hashtbl.t;
  user_call_contracts_by_name :
    (string, Core_ownership.call_contract) Hashtbl.t;
  user_call_contracts_by_id : (int, Core_ownership.call_contract) Hashtbl.t;
  active_type_params : string list;
}
(** Program-level environment built once per [insert_drops_program]
    call by walking the program's top-level declarations.

    [type_registry] is the shared per-program type registry used by codegen
    and Core type-layout classification. Perceus intentionally consumes this
    richer registry instead of a reduced "managed type name" table so every
    source-declared managed type carries its kind and destructor policy before
    RC insertion consults its layout.

    [global_function_names] / [global_function_ids] contain top-level
    function symbols. They are not runtime heap values before closure
    conversion, so Perceus must not emit [CDup] / [CDrop] against the
    symbol itself.

    [active_type_params] records the current generic function's type
    parameters while analyzing that function body and contract. Parser and
    inference paths can leave multi-character params such as [Acc] as
    [TyNamed ("Acc", [])] in Core, so this context is required to distinguish
    them from genuinely unknown named runtime types.

    Built-in managed and unmanaged runtime types are recognized by name
    in [Core_type_layout], not via this table. *)

let empty_env () : type_env =
  {
    type_registry = Codegen_types.create_registry ();
    global_function_names = Hashtbl.create 64;
    global_function_ids = Hashtbl.create 64;
    constructor_call_contracts_by_name = Hashtbl.create 64;
    constructor_call_contracts_by_id = Hashtbl.create 64;
    user_call_contracts_by_name = Hashtbl.create 64;
    user_call_contracts_by_id = Hashtbl.create 64;
    active_type_params = [];
  }

let normalize_type_param_name name = Env.type_param_name name

let with_type_params (env : type_env) (type_params : Ast.type_param_decl list) :
    type_env =
  let active_type_params =
    List.map normalize_type_param_name (Ast.type_param_names type_params)
    @ env.active_type_params
  in
  { env with active_type_params }

let is_active_type_param (env : type_env) name =
  let name = normalize_type_param_name name in
  List.exists (( = ) name) env.active_type_params

let constructor_contract_for_variant (v : Ast.variant) :
    Core_ownership.call_contract =
  {
    Core_ownership.args =
      List.map (fun _ -> Core_ownership.Transfer) v.variant_fields;
    result = Core_ownership.ReturnOwned;
  }

let install_constructor_contract (env : type_env) (v : Ast.variant) : unit =
  match v.variant_fields with
  | [] -> ()
  | _ -> (
      let contract = constructor_contract_for_variant v in
      Hashtbl.replace env.constructor_call_contracts_by_name v.variant_name
        contract;
      Hashtbl.replace env.global_function_names v.variant_name ();
      match v.variant_def_id with
      | Some id ->
          Hashtbl.replace env.constructor_call_contracts_by_id id contract;
          Hashtbl.replace env.global_function_ids id ()
      | None -> ())

(** Walk a [core_program] and collect Perceus classification metadata:
    managed user-defined types and top-level function symbols. *)
let build_type_env (prog : core_program) : type_env =
  let env = empty_env () in
  Core_flatten.register_types env.type_registry prog;
  let rec visit (d : core_decl) =
    match d.cd_desc with
    | CDType t when (not t.type_is_enum) && not t.type_is_builtin ->
        List.iter (install_constructor_contract env) t.type_variants
    | CDFunc f ->
        Hashtbl.replace env.global_function_names f.cf_name ();
        Hashtbl.replace env.global_function_ids f.cf_def_id ()
    | CDImpl i ->
        List.iter
          (fun f ->
            Hashtbl.replace env.global_function_names f.cf_name ();
            Hashtbl.replace env.global_function_ids f.cf_def_id ())
          i.ci_methods
    | CDPrivate inner -> visit inner
    | _ -> ()
  in
  List.iter visit prog;
  env

let managed_type_info (env : type_env) name =
  Codegen_types.managed_type_info env.type_registry name

let type_layout_metadata (env : type_env) =
  Core_type_layout.metadata
    ~is_managed_name:(fun name ->
      is_active_type_param env name
      || Codegen_types.is_managed_type env.type_registry name)
    ~is_value_record_name:(fun name ->
      Hashtbl.mem env.type_registry.value_records name)
    ~is_enum_name:(fun name -> Hashtbl.mem env.type_registry.enum_types name)
    ~lookup_alias:(fun name ->
      Hashtbl.find_opt env.type_registry.type_aliases name)
    ()

(** Is this type managed (refcounted) and therefore subject to
    dup/drop insertion?

    Delegates to [Core_layout_type], which has explicit managed and
    unmanaged cases plus the program metadata collected above. Unknown
    named types raise a Core error instead of defaulting to unmanaged. *)
let is_managed_type (env : type_env) (ty : Ast.type_expr) : bool =
  Core_layout_type.source_value_layout_of_metadata
    ~phase:(Core_error.Stage Core_stage.Perceus) (type_layout_metadata env) ty
  |> Core_layout_type.source_value_requires_release

let result_mode_for_type (env : type_env) (ty : Ast.type_expr) :
    Core_ownership.result_mode =
  match ty with
  | Ast.TyNamed ("Void", []) -> Core_ownership.ReturnVoid
  | _ when is_managed_type env ty -> Core_ownership.ReturnOwned
  | _ -> Core_ownership.ReturnPrimitive

let borrow_contract_for_signature (env : type_env) ~(arg_count : int)
    ~(return_ty : Ast.type_expr) : Core_ownership.call_contract =
  {
    Core_ownership.args = Core_ownership.borrow_all arg_count;
    result = result_mode_for_type env return_ty;
  }

let contract_matches_arity (contract : Core_ownership.call_contract) arg_count =
  List.length contract.args = arg_count

let lookup_constructor_call_contract (env : type_env) name def_id arg_count =
  let found =
    match def_id with
    | Some id -> Hashtbl.find_opt env.constructor_call_contracts_by_id id
    | None -> None
  in
  let found =
    match found with
    | Some _ -> found
    | None -> Hashtbl.find_opt env.constructor_call_contracts_by_name name
  in
  match found with
  | Some contract when contract_matches_arity contract arg_count ->
      Some contract
  | _ -> None

let lookup_user_call_contract (env : type_env) name def_id arg_count =
  let found = lookup_constructor_call_contract env name def_id arg_count in
  let found =
    match found with
    | Some c -> Some c
    | None -> (
        let found =
          match def_id with
          | Some id -> Hashtbl.find_opt env.user_call_contracts_by_id id
          | None -> None
        in
        match found with
        | Some _ -> found
        | None -> Hashtbl.find_opt env.user_call_contracts_by_name name)
  in
  match found with
  | Some contract when contract_matches_arity contract arg_count ->
      Some contract
  | _ -> None

let is_constructor_call (env : type_env) (kind : call_kind) arg_count =
  match kind with
  | CKUser (name, def_id) -> (
      match lookup_constructor_call_contract env name def_id arg_count with
      | Some _ -> true
      | None -> false)
  | _ -> false

let contract_for_call (env : type_env) (kind : call_kind) ~(arg_count : int)
    ~(return_ty : Ast.type_expr) : Core_ownership.call_contract option =
  match Core_ownership.contract_for_call_kind kind ~arg_count with
  | Some contract -> Some contract
  | None -> (
      match kind with
      | CKUser (name, def_id) ->
          lookup_user_call_contract env name def_id arg_count
      | CKForeign _ ->
          Some (borrow_contract_for_signature env ~arg_count ~return_ty)
      | CKClosure ->
          Some (borrow_contract_for_signature env ~arg_count ~return_ty)
      | CKUnknown | CKSelectedDirect _ | CKBuiltin _ | CKIntrinsic _ -> None)

(* ============================================================================
   Use counting
   ============================================================================ *)

(** Does this pattern introduce a binding with the given name?
    Recurses into nested sub-patterns. Used by [count_uses] to stop
    descending into match arms whose pattern shadows the search name. *)
let rec pattern_binds (name : string) (pat : Ast.pattern) : bool =
  match pat with
  | PatWildcard | PatLiteral _ -> false
  | PatVar n -> n = name
  | PatConstructor (_, args) | PatQualified (_, _, args) ->
      List.exists (pattern_binds name) args
  | PatTuple ps | PatOr ps -> List.exists (pattern_binds name) ps
  | PatList (ps, spread) -> (
      List.exists (pattern_binds name) ps
      || match spread with Some p -> pattern_binds name p | None -> false)

(** Count uses of [CVar name] in [e], treating mutually-exclusive
    branches as MAX (not sum), and respecting pattern-introduced
    shadow bindings in match arms.

    This is the legacy conservative use counter: every [CVar name]
    occurrence is treated as an owned use, including known borrowed
    intrinsic / builtin arguments. Linear [CLet] transformation uses
    [summarize_linear_ownership_uses] below for precise borrowed-vs-
    consuming call semantics; branch transforms use that summary directly
    for supported branch forms and keep this counter only for explicitly
    conservative paths such as repeated-loop contexts, task-capture
    detection, and direct [count_uses] unit coverage.

    Deliberately hand-rolled (not [fold_tree]): the semantics requires
    taking MAX across [CIf] / [CMatchArms] / [CMatch] branches rather than summing,
    and suppressing descent when a pattern binds the search name. A
    blanket tree fold would SUM contributions and ignore shadowing,
    giving the wrong RC balance. *)
let rec count_uses (name : string) (e : core) : int =
  match e.desc with
  | CVar v when v.vname = name -> 1
  | CLit _ | CVar _ | CVoid | CBreak | CContinue -> 0
  | CResourceCleanupExit exit ->
      List.fold_left
        (fun acc cleanup -> acc + count_uses name cleanup)
        0 exit.rce_cleanups
  | CBin (_, l, r) | CLog (_, l, r) | CRange (l, r) | CSeq (l, r) ->
      count_uses name l + count_uses name r
  | CUn (_, x) | CCast (x, _) | CUnbox (x, _) | CBox (x, _) -> count_uses name x
  | CUnboxTyped u -> count_uses name u.unbox_value
  | CBoxTyped b -> count_uses name b.box_value
  | CCall (_, fn, args) ->
      count_uses name fn
      + List.fold_left (fun a c -> a + count_uses name c) 0 args
  | CTensorRawRead r -> count_uses name r.trr_index
  | CTensorRawWrite w ->
      count_uses name w.trw_index + count_uses name w.trw_value
  | CField (obj, _) -> count_uses name obj
  | CTuple xs | CVector xs ->
      List.fold_left (fun a c -> a + count_uses name c) 0 xs
  | CTupleConstruct tc ->
      List.fold_left
        (fun a c -> a + count_boxed_storage_uses name c)
        0 tc.tc_elems
  | CList lit ->
      List.fold_left (fun a c -> a + count_uses name c) 0 lit.ll_elems
  | CListConstruct lc ->
      List.fold_left
        (fun a c -> a + count_boxed_storage_uses name c)
        0 lc.lc_elems
  | CListAlloc alloc -> count_uses name alloc.la_capacity
  | CListGet get -> count_uses name get.lg_list + count_uses name get.lg_index
  | CStringByteRead r ->
      count_uses name r.sbr_source + count_uses name r.sbr_index
  | CStringByteWrite w ->
      count_uses name w.sbw_target
      + count_uses name w.sbw_index
      + count_uses name w.sbw_byte
  | CStringByteCopy c ->
      count_uses name c.sbc_dst
      + count_uses name c.sbc_dst_pos
      + count_uses name c.sbc_src
      + count_uses name c.sbc_src_pos
      + count_uses name c.sbc_len
  | CStringSetLen s -> count_uses name s.ssl_target + count_uses name s.ssl_len
  | CDict kvs ->
      List.fold_left
        (fun a (k, v) -> a + count_uses name k + count_uses name v)
        0 kvs
  | CDictConstruct dc ->
      List.fold_left
        (fun a (k, v) ->
          a + count_boxed_storage_uses name k + count_boxed_storage_uses name v)
        0 dc.dc_entries
  | CSetAlloc _ -> 0
  | CRecord fs -> List.fold_left (fun a (_, v) -> a + count_uses name v) 0 fs
  | CRecordConstruct rc ->
      List.fold_left
        (fun a field ->
          a
          +
          match field with
          | RecordRawField (_, v) -> count_uses name v
          | RecordErasedField (_, v) -> count_boxed_storage_uses name v)
        0 rc.rc_fields
  | CTensorLiteral tl -> (
      match tl.tl_payload with
      | TensorRawElements (_, elems) ->
          List.fold_left (fun a c -> a + count_uses name c) 0 elems
      | TensorWordElements elems ->
          List.fold_left (fun a c -> a + count_uses name c) 0 elems
      | TensorPackedElements (_, elems) ->
          List.fold_left (fun a c -> a + count_uses name c) 0 elems
      | TensorInlineStructElements (_, elems) ->
          List.fold_left (fun a c -> a + count_uses name c) 0 elems
      | TensorBoxedElements elems ->
          List.fold_left
            (fun a c -> a + count_boxed_storage_uses name c)
            0 elems)
  | CUnionConstruct uc ->
      List.fold_left
        (fun a c -> a + count_boxed_storage_uses name c)
        0 uc.uc_args
  | CRecordUpdate (b, fs) ->
      count_uses name b
      + List.fold_left (fun a (_, v) -> a + count_uses name v) 0 fs
  | CStringInterp (parts, _) ->
      List.fold_left
        (fun a p ->
          a + match p with IPLit _ -> 0 | IPExpr e -> count_uses name e)
        0 parts
  | CLet (b, body) ->
      let rhs_count = count_uses name b.bind_rhs in
      let body_count =
        if b.bind_var.vname = name then 0 else count_uses name body
      in
      rhs_count + body_count
  | CBorrowLet (b, body) ->
      let rhs_count = count_uses name b.borrow_rhs in
      let body_count =
        if b.borrow_var.vname = name then 0 else count_uses name body
      in
      rhs_count + body_count
  | CTensorRawViewLet (b, body) ->
      let source_count = count_uses name b.trv_source in
      let body_count =
        if b.trv_var.vname = name then 0 else count_uses name body
      in
      source_count + body_count
  | CResourceScope s ->
      let scoped_count =
        if s.rs_var.vname = name then 0
        else count_uses name s.rs_body + count_uses name s.rs_cleanup
      in
      count_uses name s.rs_acquire + scoped_count
  | CIf (c, t, el) ->
      (* Only ONE branch runs — take max, not sum. *)
      count_uses name c + max (count_uses name t) (count_uses name el)
  | CMatchArms (scrut, arms) ->
      (* Only one arm runs — take max. Pattern bindings shadow the
         outer name, so we don't descend into arms where the pattern
         binds [name]. *)
      let arm_max =
        List.fold_left
          (fun acc (pat, body) ->
            if pattern_binds name pat then acc
            else max acc (count_uses name body))
          0 arms
      in
      count_uses name scrut + arm_max
  | CMatch (scrut, tree) ->
      (* Max across all paths through the decision tree. *)
      count_uses name scrut + max_uses_ctree_inner name tree
  | CWhile (c, b) -> count_uses name c + count_uses name b
  | CFor (binder, iter, body) ->
      count_uses name iter
      + if binder.loop_var.vname = name then 0 else count_uses name body
  | CAssign (_, rhs) ->
      (* LHS is a write, not a read — don't count the target. The
         assignment itself rebinds the variable; Perceus shouldn't
         touch mutable bindings anyway (see [transform_let]). *)
      count_uses name rhs
  | CTailrecLoop (TailrecUnmanagedLoop l) -> count_uses name l.tul_body
  | CTailrecLoop (TailrecListSpreadLoop l) -> count_uses name l.tls_body
  | CTailrecRecur (TailrecRecur r) ->
      List.fold_left (fun a c -> a + count_uses name c) 0 r.tr_args
  | CTailrecRecur (TailrecListSpreadRecur r) ->
      List.fold_left (fun a (_, arg) -> a + count_uses name arg) 0 r.tr_rebinds
  | CLambda lam ->
      (* A free capture is retained ONCE at closure construction,
         regardless of how many times the body references it. *)
      if List.exists (fun (v, _) -> v.vname = name) lam.lam_params then 0
      else if count_uses name lam.lam_body > 0 then 1
      else 0
  | CClosureCreate cc ->
      (* Each capture is retained once *)
      if List.exists (fun (n, _) -> n = name) cc.cc_captures then 1 else 0
  | CConcurrent cb ->
      (* Task RHSs: always counted (they evaluate unconditionally).
         Tail body: counted ONLY if [name] isn't shadowed by a concurrent
         binding. Timeout: a plain expression, always counted. *)
      let rhs_uses =
        List.fold_left
          (fun acc (b : conc_binding) -> acc + count_uses name b.cb_rhs)
          0 cb.conc_bindings
      in
      let shadowed =
        List.exists
          (fun (b : conc_binding) -> b.cb_var.vname = name)
          cb.conc_bindings
      in
      let body_uses = if shadowed then 0 else count_uses name cb.conc_body in
      let timeout_uses =
        match cb.conc_timeout with Some t -> count_uses name t | None -> 0
      in
      rhs_uses + body_uses + timeout_uses
  | CConcurrentFor cf -> (
      count_uses name cf.cf_iter
      + (if cf.cf_var.vname = name then 0 else count_uses name cf.cf_body)
      + match cf.cf_timeout with Some t -> count_uses name t | None -> 0)
  | CDetach d -> count_uses name d.detach_body
  | CListHandoff h ->
      let body_uses =
        if
          h.lh_source_var.vname = name
          || h.lh_result_var.vname = name
          || h.lh_len_var.vname = name || h.lh_out_var.vname = name
        then 0
        else count_uses name h.lh_body
      in
      count_uses name h.lh_source + count_uses name h.lh_capacity + body_uses
  | CDebugBlock body -> count_uses name body
  | CDup (_, _, body) | CDrop (_, _, body) -> count_uses name body

and count_boxed_storage_uses name value =
  count_uses name value.bsv_box.box_value

(** Max uses of [name] across all PATHS through a [ctree]. Each
    switch selects exactly one case, so we take max (not sum).
    [CTLeaf] stops descending if the leaf's [ct_bindings] shadow
    [name]. *)
and max_uses_ctree_inner (name : string) (tree : ctree) : int =
  match tree with
  | CTLeaf { ct_bindings; ct_body } ->
      if List.exists (fun (v, _) -> v.vname = name) ct_bindings then 0
      else count_uses name ct_body
  | CTFail -> 0
  | CTSwitchTag { cts_cases; cts_default; _ } ->
      let case_maxes =
        List.map (fun (_, sub) -> max_uses_ctree_inner name sub) cts_cases
      in
      let default_max =
        match cts_default with
        | Some d -> max_uses_ctree_inner name d
        | None -> 0
      in
      List.fold_left max default_max case_maxes
  | CTSwitchLit { ctl_cases; ctl_default; _ } ->
      let case_maxes =
        List.map (fun (_, sub) -> max_uses_ctree_inner name sub) ctl_cases
      in
      List.fold_left max (max_uses_ctree_inner name ctl_default) case_maxes
  | CTSwitchLen { ctl_len_cases; ctl_len_geq; ctl_len_default; _ } ->
      let case_maxes =
        List.map (fun (_, sub) -> max_uses_ctree_inner name sub) ctl_len_cases
      in
      let geq_max =
        match ctl_len_geq with
        | Some (_, sub) -> max_uses_ctree_inner name sub
        | None -> 0
      in
      let default_max =
        match ctl_len_default with
        | Some d -> max_uses_ctree_inner name d
        | None -> 0
      in
      List.fold_left max (max geq_max default_max) case_maxes

(** Public alias — the "max uses across all paths" variant, used
    by [transform_let_match_tree_body] for the outer dup calculation. *)
let max_uses_ctree = max_uses_ctree_inner

(* ============================================================================
   Linear ownership-use summary
   ============================================================================ *)

type ownership_uses = {
  required_refs : int;
  consumed_refs : int;
  touched : bool;
  returns_alias : bool;
}
(** Sequential ownership demand for one variable in an expression.

    [consumed_refs] is how many owned references are consumed by the body.
    [required_refs] is the minimum number of refs that must be live at body
    entry so every consuming use and borrowed read is valid in evaluation order.
    [touched] distinguishes "no mention at all" from "borrowed only": both have
    [consumed_refs = 0], but borrowed-only bodies need a post-body drop rather
    than the unused-binding pre-drop. [returns_alias] is true when the
    expression result may alias [name]'s storage, so the owner cannot be
    dropped immediately after producing the result. *)

let no_ownership_uses =
  {
    required_refs = 0;
    consumed_refs = 0;
    touched = false;
    returns_alias = false;
  }

let consume_ownership_use =
  {
    required_refs = 1;
    consumed_refs = 1;
    touched = true;
    returns_alias = false;
  }

let borrow_ownership_use =
  {
    required_refs = 1;
    consumed_refs = 0;
    touched = true;
    returns_alias = false;
  }

let seq_ownership_uses (a : ownership_uses) (b : ownership_uses) :
    ownership_uses =
  {
    required_refs = max a.required_refs (a.consumed_refs + b.required_refs);
    consumed_refs = a.consumed_refs + b.consumed_refs;
    touched = a.touched || b.touched;
    returns_alias = b.returns_alias;
  }

let sum_ownership_uses (xs : ownership_uses list) : ownership_uses =
  List.fold_left seq_ownership_uses no_ownership_uses xs

let aggregate_ownership_uses (xs : ownership_uses list) : ownership_uses =
  let seq = sum_ownership_uses xs in
  { seq with returns_alias = List.exists (fun u -> u.returns_alias) xs }

let ownership_uses_from_legacy_count (count : int) : ownership_uses =
  if count <= 0 then no_ownership_uses
  else
    {
      required_refs = count;
      consumed_refs = count;
      touched = true;
      returns_alias = false;
    }

(** True when [e] is a direct alias of [name]'s storage. Alias bindings are
    source-level copies: [let y = x] and [let y = x.field] borrow [x] and retain
    as needed; they do not transfer ownership from [x]. *)
let rec direct_aliases_name (name : string) (e : core) : bool =
  match e.desc with
  | CVar v -> v.vname = name
  | CField (owner, _) -> direct_aliases_name name owner
  | CUnbox (inner, _) | CCast (inner, _) -> direct_aliases_name name inner
  | CUnboxTyped u -> direct_aliases_name name u.unbox_value
  | _ -> false

(** Summarize ownership demands using known call contracts. Unknown calls
    preserve the historical conservative behavior: evaluating a matching [CVar]
    argument consumes one ref. *)
let branch_ownership_uses (xs : ownership_uses list) : ownership_uses =
  {
    required_refs = List.fold_left (fun acc u -> max acc u.required_refs) 0 xs;
    consumed_refs = List.fold_left (fun acc u -> max acc u.consumed_refs) 0 xs;
    touched = List.exists (fun u -> u.touched) xs;
    returns_alias = List.exists (fun u -> u.returns_alias) xs;
  }

let task_capture_ownership_use (name : string) (body : core) : ownership_uses =
  if count_uses name body > 0 then borrow_ownership_use else no_ownership_uses

let rec summarize_linear_ownership_uses (env : type_env) (name : string)
    (e : core) : ownership_uses =
  match e.desc with
  | CVar v when v.vname = name -> consume_ownership_use
  | CLit _ | CVar _ | CVoid | CBreak | CContinue -> no_ownership_uses
  | CResourceCleanupExit exit ->
      List.fold_left
        (fun acc cleanup ->
          seq_ownership_uses acc
            (summarize_linear_ownership_uses env name cleanup))
        no_ownership_uses exit.rce_cleanups
  | CBin (_, l, r) | CLog (_, l, r) | CRange (l, r) | CSeq (l, r) ->
      seq_ownership_uses
        (summarize_linear_ownership_uses env name l)
        (summarize_linear_ownership_uses env name r)
  | CUn (_, x) -> summarize_linear_ownership_uses env name x
  | CCast (x, _) | CUnbox (x, _) | CBox (x, _) ->
      summarize_linear_borrow env name x
  | CUnboxTyped u -> summarize_linear_borrow env name u.unbox_value
  | CBoxTyped b -> summarize_linear_borrow env name b.box_value
  | CCall (kind, fn, args) -> summarize_linear_call env name e.ty kind fn args
  | CTensorRawRead r -> summarize_linear_ownership_uses env name r.trr_index
  | CTensorRawWrite w ->
      seq_ownership_uses
        (summarize_linear_ownership_uses env name w.trw_index)
        (summarize_linear_ownership_uses env name w.trw_value)
  | CField (obj, _) ->
      let uses = summarize_linear_borrow env name obj in
      if uses.touched && is_managed_type env e.ty then
        { uses with returns_alias = true }
      else uses
  | CTuple xs | CVector xs ->
      aggregate_ownership_uses
        (List.map (summarize_linear_ownership_uses env name) xs)
  | CTupleConstruct tc ->
      aggregate_ownership_uses
        (List.map (summarize_boxed_storage_uses env name) tc.tc_elems)
  | CList lit ->
      aggregate_ownership_uses
        (List.map (summarize_linear_ownership_uses env name) lit.ll_elems)
  | CListConstruct lc ->
      aggregate_ownership_uses
        (List.map (summarize_boxed_storage_uses env name) lc.lc_elems)
  | CListAlloc alloc ->
      summarize_linear_ownership_uses env name alloc.la_capacity
  | CListGet get ->
      aggregate_ownership_uses
        [
          summarize_linear_borrow env name get.lg_list;
          summarize_linear_ownership_uses env name get.lg_index;
        ]
  | CStringByteRead r ->
      aggregate_ownership_uses
        [
          summarize_linear_borrow env name r.sbr_source;
          summarize_linear_ownership_uses env name r.sbr_index;
        ]
  | CStringByteWrite w ->
      aggregate_ownership_uses
        [
          summarize_linear_borrow env name w.sbw_target;
          summarize_linear_ownership_uses env name w.sbw_index;
          summarize_linear_ownership_uses env name w.sbw_byte;
        ]
  | CStringByteCopy c ->
      aggregate_ownership_uses
        [
          summarize_linear_borrow env name c.sbc_dst;
          summarize_linear_ownership_uses env name c.sbc_dst_pos;
          summarize_linear_borrow env name c.sbc_src;
          summarize_linear_ownership_uses env name c.sbc_src_pos;
          summarize_linear_ownership_uses env name c.sbc_len;
        ]
  | CStringSetLen s ->
      aggregate_ownership_uses
        [
          summarize_linear_borrow env name s.ssl_target;
          summarize_linear_ownership_uses env name s.ssl_len;
        ]
  | CDict kvs ->
      aggregate_ownership_uses
        (List.map
           (fun (k, v) ->
             aggregate_ownership_uses
               [
                 summarize_linear_ownership_uses env name k;
                 summarize_linear_ownership_uses env name v;
               ])
           kvs)
  | CDictConstruct dc ->
      aggregate_ownership_uses
        (List.map
           (fun (k, v) ->
             aggregate_ownership_uses
               [
                 summarize_boxed_storage_uses env name k;
                 summarize_boxed_storage_uses env name v;
               ])
           dc.dc_entries)
  | CSetAlloc _ -> no_ownership_uses
  | CRecord fs ->
      aggregate_ownership_uses
        (List.map (fun (_, v) -> summarize_linear_ownership_uses env name v) fs)
  | CRecordConstruct rc ->
      aggregate_ownership_uses
        (List.map
           (function
             | RecordRawField (_, v) ->
                 summarize_linear_ownership_uses env name v
             | RecordErasedField (_, v) ->
                 summarize_boxed_storage_uses env name v)
           rc.rc_fields)
  | CTensorLiteral tl -> (
      match tl.tl_payload with
      | TensorRawElements (_, elems) ->
          aggregate_ownership_uses
            (List.map (summarize_linear_ownership_uses env name) elems)
      | TensorWordElements elems ->
          aggregate_ownership_uses
            (List.map (summarize_linear_ownership_uses env name) elems)
      | TensorPackedElements (_, elems) ->
          aggregate_ownership_uses
            (List.map (summarize_linear_ownership_uses env name) elems)
      | TensorInlineStructElements (_, elems) ->
          aggregate_ownership_uses
            (List.map (summarize_linear_ownership_uses env name) elems)
      | TensorBoxedElements elems ->
          aggregate_ownership_uses
            (List.map (summarize_boxed_storage_uses env name) elems))
  | CUnionConstruct uc ->
      aggregate_ownership_uses
        (List.map (summarize_boxed_storage_uses env name) uc.uc_args)
  | CRecordUpdate (b, fs) ->
      aggregate_ownership_uses
        [
          summarize_linear_ownership_uses env name b;
          aggregate_ownership_uses
            (List.map
               (fun (_, v) -> summarize_linear_ownership_uses env name v)
               fs);
        ]
  | CStringInterp (parts, _) ->
      sum_ownership_uses
        (List.map
           (function
             | IPLit _ -> no_ownership_uses
             | IPExpr e -> summarize_linear_ownership_uses env name e)
           parts)
  | CLet (b, body) ->
      let rhs_uses =
        if is_managed_type env b.bind_ty && direct_aliases_name name b.bind_rhs
        then summarize_linear_borrow env name b.bind_rhs
        else summarize_linear_ownership_uses env name b.bind_rhs
      in
      let body_uses =
        if b.bind_var.vname = name then no_ownership_uses
        else summarize_linear_ownership_uses env name body
      in
      seq_ownership_uses rhs_uses body_uses
  | CBorrowLet (b, body) ->
      let rhs_uses = summarize_linear_borrow env name b.borrow_rhs in
      let body_uses =
        if b.borrow_var.vname = name then no_ownership_uses
        else summarize_linear_ownership_uses env name body
      in
      seq_ownership_uses rhs_uses body_uses
  | CTensorRawViewLet (b, body) ->
      let source_uses = summarize_linear_borrow env name b.trv_source in
      let body_uses =
        if b.trv_var.vname = name then no_ownership_uses
        else summarize_linear_ownership_uses env name body
      in
      seq_ownership_uses source_uses body_uses
  | CResourceScope s ->
      let acquire_uses =
        summarize_linear_ownership_uses env name s.rs_acquire
      in
      let scoped_uses =
        if s.rs_var.vname = name then no_ownership_uses
        else
          seq_ownership_uses
            (summarize_linear_ownership_uses env name s.rs_body)
            (summarize_linear_ownership_uses env name s.rs_cleanup)
      in
      seq_ownership_uses acquire_uses scoped_uses
  | CLambda lam ->
      if List.exists (fun (v, _) -> v.vname = name) lam.lam_params then
        no_ownership_uses
      else if count_uses name lam.lam_body > 0 then
        (* Closure conversion/emission retains captured managed values into
           the environment; constructing the closure borrows the local owner. *)
        borrow_ownership_use
      else no_ownership_uses
  | CClosureCreate cc ->
      if List.exists (fun (n, _) -> n = name) cc.cc_captures then
        (* CClosureCreate stores retained captures, so the source binding still
           owns its local reference and needs normal scope cleanup. *)
        borrow_ownership_use
      else no_ownership_uses
  | CAssign (v, _) when v.vname = name ->
      (* Self-assignment RHS uses consume the old value as part of replacing
         the mutable slot. They do not transfer the slot's final value out of
         scope, so they must not suppress the final scope-exit drop. *)
      no_ownership_uses
  | CAssign (_, rhs) -> summarize_linear_ownership_uses env name rhs
  | CDup (v, _, body) when v.vname = name ->
      let uses = summarize_linear_ownership_uses env name body in
      {
        uses with
        required_refs = max 1 (uses.required_refs - 1);
        consumed_refs = max 0 (uses.consumed_refs - 1);
        touched = true;
      }
  | CDup (_, _, body) | CDrop (_, _, body) ->
      summarize_linear_ownership_uses env name body
  | CIf (c, t, el) ->
      seq_ownership_uses
        (summarize_linear_ownership_uses env name c)
        (branch_ownership_uses
           [
             summarize_linear_ownership_uses env name t;
             summarize_linear_ownership_uses env name el;
           ])
  | CMatchArms (scrut, arms) ->
      let scrut_aliases_owner = borrow_expr_aliases_target env name scrut in
      let scrut_uses =
        if scrut_aliases_owner then summarize_linear_borrow env name scrut
        else summarize_linear_ownership_uses env name scrut
      in
      let arm_uses =
        List.map
          (fun (pat, body) ->
            if pattern_binds name pat then no_ownership_uses
            else summarize_linear_ownership_uses env name body)
          arms
      in
      let branch_uses = branch_ownership_uses arm_uses in
      let branch_uses =
        if scrut_aliases_owner then
          seq_ownership_uses borrow_ownership_use branch_uses
        else branch_uses
      in
      seq_ownership_uses scrut_uses branch_uses
  | CMatch (scrut, tree) ->
      let scrut_aliases_owner = borrow_expr_aliases_target env name scrut in
      let scrut_uses =
        if scrut_aliases_owner then summarize_linear_borrow env name scrut
        else summarize_linear_ownership_uses env name scrut
      in
      let tree_uses = summarize_ctree_ownership_uses env name tree in
      let tree_uses =
        if scrut_aliases_owner then
          seq_ownership_uses borrow_ownership_use tree_uses
        else tree_uses
      in
      seq_ownership_uses scrut_uses tree_uses
  | CDetach d -> task_capture_ownership_use name d.detach_body
  | CListHandoff h ->
      let source_uses =
        match h.lh_mode with
        | BorrowFresh -> summarize_linear_borrow env name h.lh_source
        | ConsumeReuse -> summarize_linear_ownership_uses env name h.lh_source
      in
      let capacity_uses =
        summarize_linear_ownership_uses env name h.lh_capacity
      in
      let body_uses =
        if
          h.lh_source_var.vname = name
          || h.lh_result_var.vname = name
          || h.lh_len_var.vname = name || h.lh_out_var.vname = name
        then no_ownership_uses
        else summarize_linear_ownership_uses env name h.lh_body
      in
      seq_ownership_uses source_uses
        (seq_ownership_uses capacity_uses body_uses)
  | CFor (binder, iter, body) ->
      let iter_uses = summarize_linear_borrow env name iter in
      let body_uses =
        if binder.loop_var.vname = name then no_ownership_uses
        else summarize_linear_ownership_uses env name body
      in
      if body_uses.consumed_refs > 0 then
        ownership_uses_from_legacy_count (count_uses name e)
      else seq_ownership_uses iter_uses { body_uses with returns_alias = false }
  | CWhile (cond, body) ->
      let cond_uses = summarize_linear_ownership_uses env name cond in
      let body_uses = summarize_linear_ownership_uses env name body in
      if cond_uses.consumed_refs > 0 || body_uses.consumed_refs > 0 then
        ownership_uses_from_legacy_count (count_uses name e)
      else seq_ownership_uses cond_uses { body_uses with returns_alias = false }
  | CTailrecLoop _ | CTailrecRecur _ ->
      ownership_uses_from_legacy_count (count_uses name e)
  | CDebugBlock body -> summarize_linear_ownership_uses env name body
  | CConcurrent cb ->
      let timeout_uses =
        match cb.conc_timeout with
        | Some t -> summarize_linear_ownership_uses env name t
        | None -> no_ownership_uses
      in
      let task_uses =
        sum_ownership_uses
          (List.map
             (fun (b : conc_binding) ->
               task_capture_ownership_use name b.cb_rhs)
             cb.conc_bindings)
      in
      let shadowed =
        List.exists
          (fun (b : conc_binding) -> b.cb_var.vname = name)
          cb.conc_bindings
      in
      let body_uses =
        if shadowed then no_ownership_uses
        else summarize_linear_ownership_uses env name cb.conc_body
      in
      seq_ownership_uses timeout_uses (seq_ownership_uses task_uses body_uses)
  | CConcurrentFor cf ->
      let iter_uses = summarize_linear_ownership_uses env name cf.cf_iter in
      let task_uses =
        if cf.cf_var.vname = name then no_ownership_uses
        else task_capture_ownership_use name cf.cf_body
      in
      let timeout_uses =
        match cf.cf_timeout with
        | Some t -> summarize_linear_ownership_uses env name t
        | None -> no_ownership_uses
      in
      seq_ownership_uses timeout_uses (seq_ownership_uses iter_uses task_uses)

and summarize_boxed_storage_uses env name value =
  summarize_linear_ownership_uses env name value.bsv_box.box_value

and summarize_ctree_ownership_uses (env : type_env) (name : string)
    (tree : ctree) : ownership_uses =
  match tree with
  | CTLeaf { ct_bindings; ct_body } ->
      if List.exists (fun (v, _) -> v.vname = name) ct_bindings then
        no_ownership_uses
      else summarize_linear_ownership_uses env name ct_body
  | CTFail -> no_ownership_uses
  | CTSwitchTag { cts_cases; cts_default; _ } ->
      let case_uses =
        List.map
          (fun (_, sub) -> summarize_ctree_ownership_uses env name sub)
          cts_cases
      in
      let default_uses =
        match cts_default with
        | Some d -> [ summarize_ctree_ownership_uses env name d ]
        | None -> [ no_ownership_uses ]
      in
      branch_ownership_uses (case_uses @ default_uses)
  | CTSwitchLit { ctl_cases; ctl_default; _ } ->
      branch_ownership_uses
        (List.map
           (fun (_, sub) -> summarize_ctree_ownership_uses env name sub)
           ctl_cases
        @ [ summarize_ctree_ownership_uses env name ctl_default ])
  | CTSwitchLen { ctl_len_cases; ctl_len_geq; ctl_len_default; _ } ->
      let case_uses =
        List.map
          (fun (_, sub) -> summarize_ctree_ownership_uses env name sub)
          ctl_len_cases
      in
      let geq_uses =
        match ctl_len_geq with
        | Some (_, sub) -> [ summarize_ctree_ownership_uses env name sub ]
        | None -> [ no_ownership_uses ]
      in
      let default_uses =
        match ctl_len_default with
        | Some d -> [ summarize_ctree_ownership_uses env name d ]
        | None -> [ no_ownership_uses ]
      in
      branch_ownership_uses (case_uses @ geq_uses @ default_uses)

and summarize_linear_call (env : type_env) (name : string)
    (return_ty : Ast.type_expr) (kind : call_kind) (fn : core)
    (args : core list) : ownership_uses =
  match contract_for_call env kind ~arg_count:(List.length args) ~return_ty with
  | None ->
      sum_ownership_uses
        (summarize_linear_ownership_uses env name fn
        :: List.map (summarize_linear_ownership_uses env name) args)
  | Some contract when List.length contract.args = List.length args ->
      let fn_uses =
        if kind = CKClosure then [ summarize_linear_borrow env name fn ] else []
      in
      let arg_uses =
        List.map2 (summarize_linear_call_arg env name) contract.args args
      in
      let uses = sum_ownership_uses (fn_uses @ arg_uses) in
      {
        uses with
        returns_alias =
          call_result_aliases_target env name contract args arg_uses;
      }
  | Some _ ->
      (* Defensive fallback if a future contract is registered with an
         inconsistent arity. *)
      ownership_uses_from_legacy_count
        (count_uses name
           { desc = CCall (kind, fn, args); ty = fn.ty; loc = fn.loc })

and summarize_linear_call_arg (env : type_env) (name : string)
    (mode : Core_ownership.arg_mode) (arg : core) : ownership_uses =
  if Core_ownership.arg_consumes_caller mode then
    summarize_linear_ownership_uses env name arg
  else summarize_linear_borrow env name arg

and summarize_linear_borrow (env : type_env) (name : string) (e : core) :
    ownership_uses =
  match e.desc with
  | CVar v when v.vname = name -> borrow_ownership_use
  | CField (owner, _) -> summarize_linear_borrow env name owner
  | CBox (inner, _) | CCast (inner, _) | CUnbox (inner, _) ->
      summarize_linear_borrow env name inner
  | _ -> summarize_linear_ownership_uses env name e

and borrow_expr_aliases_target (env : type_env) (name : string) (e : core) :
    bool =
  match e.desc with
  | CVar v when v.vname = name -> true
  | CField (owner, _) -> borrow_expr_aliases_target env name owner
  | _ -> (summarize_linear_ownership_uses env name e).returns_alias

and call_result_aliases_target (env : type_env) (name : string)
    (contract : Core_ownership.call_contract) (args : core list)
    (arg_uses : ownership_uses list) : bool =
  match contract.result with
  | Core_ownership.ReturnAliasOfArg idx -> (
      match (List.nth_opt args idx, List.nth_opt arg_uses idx) with
      | Some arg, Some uses ->
          uses.returns_alias || borrow_expr_aliases_target env name arg
      | _ -> false)
  | Core_ownership.ReturnBorrowed ->
      List.exists2
        (fun mode arg ->
          Core_ownership.arg_allows_borrowed_result_alias mode
          && borrow_expr_aliases_target env name arg)
        contract.args args
  | Core_ownership.ReturnVoid | Core_ownership.ReturnPrimitive
  | Core_ownership.ReturnOwned ->
      false

let rec list_exists2_safe f xs ys =
  match (xs, ys) with
  | x :: xs, y :: ys -> f x y || list_exists2_safe f xs ys
  | [], [] -> false
  | _ -> false

let rec expr_result_aliases_name (env : type_env) (name : string) (e : core) :
    bool =
  match e.desc with
  | CVar v -> v.vname = name
  | CField (owner, _) -> expr_result_aliases_name env name owner
  | CUnbox (inner, _) | CCast (inner, _) ->
      expr_result_aliases_name env name inner
  | CLet (b, body) ->
      b.bind_var.vname <> name
      && (expr_result_aliases_name env name body
         || expr_result_aliases_name env b.bind_var.vname body
            && expr_result_aliases_name env name b.bind_rhs)
  | CBorrowLet (b, body) ->
      b.borrow_var.vname <> name
      && (expr_result_aliases_name env name body
         || expr_result_aliases_name env b.borrow_var.vname body
            && expr_result_aliases_name env name b.borrow_rhs)
  | CCall (kind, _, args) -> (
      match
        contract_for_call env kind ~arg_count:(List.length args) ~return_ty:e.ty
      with
      | Some { Core_ownership.result = Core_ownership.ReturnAliasOfArg idx; _ }
        -> (
          match List.nth_opt args idx with
          | Some arg -> expr_result_aliases_name env name arg
          | None -> false)
      | Some
          {
            Core_ownership.args = modes;
            result = Core_ownership.ReturnBorrowed;
          } ->
          list_exists2_safe
            (fun mode arg ->
              Core_ownership.arg_allows_borrowed_result_alias mode
              && expr_result_aliases_name env name arg)
            modes args
      | _ -> false)
  | _ -> false

let rec summarize_alias_return_ownership_uses (env : type_env) (name : string)
    (e : core) : ownership_uses =
  match e.desc with
  | CVar v when v.vname = name -> borrow_ownership_use
  | CField (owner, _) -> summarize_linear_borrow env name owner
  | (CUnbox (inner, _) | CCast (inner, _))
    when expr_result_aliases_name env name inner ->
      summarize_alias_return_ownership_uses env name inner
  | _ ->
      {
        (summarize_linear_ownership_uses env name e) with
        returns_alias = false;
      }

let rec summarize_function_return_ownership_uses (env : type_env)
    (name : string) (return_ty : Ast.type_expr) (e : core) : ownership_uses =
  let managed_return = is_managed_type env return_ty in
  match e.desc with
  | CIf (cond, then_e, else_e) ->
      seq_ownership_uses
        (summarize_linear_ownership_uses env name cond)
        (branch_ownership_uses
           [
             summarize_function_return_ownership_uses env name return_ty then_e;
             summarize_function_return_ownership_uses env name return_ty else_e;
           ])
  | CMatchArms (scrut, arms) ->
      let arm_uses =
        List.map
          (fun (pat, body) ->
            if pattern_binds name pat then no_ownership_uses
            else
              summarize_function_return_ownership_uses env name return_ty body)
          arms
      in
      seq_ownership_uses
        (summarize_linear_ownership_uses env name scrut)
        (branch_ownership_uses arm_uses)
  | CLet (b, body) ->
      let rhs_uses =
        if is_managed_type env b.bind_ty && direct_aliases_name name b.bind_rhs
        then summarize_linear_borrow env name b.bind_rhs
        else summarize_linear_ownership_uses env name b.bind_rhs
      in
      let body_uses =
        if b.bind_var.vname = name then no_ownership_uses
        else summarize_function_return_ownership_uses env name return_ty body
      in
      seq_ownership_uses rhs_uses body_uses
  | CBorrowLet (b, body) ->
      let rhs_uses = summarize_linear_borrow env name b.borrow_rhs in
      let body_uses =
        if b.borrow_var.vname = name then no_ownership_uses
        else summarize_function_return_ownership_uses env name return_ty body
      in
      seq_ownership_uses rhs_uses body_uses
  | CSeq (head, tail) ->
      seq_ownership_uses
        (summarize_linear_ownership_uses env name head)
        (summarize_function_return_ownership_uses env name return_ty tail)
  | CDup (_, _, body) | CDrop (_, _, body) ->
      summarize_function_return_ownership_uses env name return_ty body
  | _ when managed_return && expr_result_aliases_name env name e ->
      summarize_alias_return_ownership_uses env name e
  | _ -> summarize_linear_ownership_uses env name e

let collect_user_funcs (prog : core_program) : core_func list =
  let rec visit_decl acc (d : core_decl) =
    match d.cd_desc with
    | CDFunc f when f.cf_body <> None -> f :: acc
    | CDImpl i ->
        List.fold_left
          (fun acc f -> if f.cf_body <> None then f :: acc else acc)
          acc i.ci_methods
    | CDPrivate inner -> visit_decl acc inner
    | _ -> acc
  in
  List.rev (List.fold_left visit_decl [] prog)

let initial_user_contract_in_env (env : type_env) (f : core_func) :
    Core_ownership.call_contract =
  let result = result_mode_for_type env f.cf_return_ty in
  match f.cf_kind with
  | CFClosureBody _ ->
      {
        Core_ownership.args =
          Core_ownership.borrow_all (List.length f.cf_params);
        result;
      }
  | _ ->
      let arg_mode (p : core_param) =
        if is_managed_type env p.cp_ty then Core_ownership.Consume
        else Core_ownership.Borrow
      in
      { Core_ownership.args = List.map arg_mode f.cf_params; result }

let initial_user_contract (env : type_env) (f : core_func) :
    Core_ownership.call_contract =
  initial_user_contract_in_env (with_type_params env f.cf_type_params) f

let install_user_contract (env : type_env) (f : core_func)
    (contract : Core_ownership.call_contract) : unit =
  Hashtbl.replace env.user_call_contracts_by_name f.cf_name contract;
  Hashtbl.replace env.user_call_contracts_by_id f.cf_def_id contract

let infer_user_contract (env : type_env) (f : core_func) :
    Core_ownership.call_contract =
  let env = with_type_params env f.cf_type_params in
  match f.cf_body with
  | _ when match f.cf_kind with CFClosureBody _ -> true | _ -> false ->
      initial_user_contract_in_env env f
  | None -> initial_user_contract_in_env env f
  | Some body ->
      let param_uses =
        List.map
          (fun (p : core_param) ->
            if is_managed_type env p.cp_ty then
              summarize_function_return_ownership_uses env p.cp_name.vname
                f.cf_return_ty body
            else no_ownership_uses)
          f.cf_params
      in
      let arg_modes =
        List.map2
          (fun (p : core_param) uses ->
            if not (is_managed_type env p.cp_ty) then Core_ownership.Borrow
            else if uses.consumed_refs > 0 then Core_ownership.Consume
            else Core_ownership.Borrow)
          f.cf_params param_uses
      in
      let result =
        match result_mode_for_type env f.cf_return_ty with
        | Core_ownership.ReturnOwned ->
            (* Source-level functions have value semantics and no borrow
               lifetime in the ABI. A body may internally read a field or
               alias-returning intrinsic, but any managed result crossing the
               function return boundary must be owned. *)
            Core_ownership.ReturnOwned
        | other -> other
      in
      { Core_ownership.args = arg_modes; result }

let populate_user_call_contracts (env : type_env) (prog : core_program) : unit =
  let funcs = collect_user_funcs prog in
  List.iter
    (fun f -> install_user_contract env f (initial_user_contract env f))
    funcs;
  let rec iterate remaining =
    if remaining <= 0 then ()
    else
      let changed = ref false in
      List.iter
        (fun f ->
          let inferred = infer_user_contract env f in
          let existing =
            Hashtbl.find_opt env.user_call_contracts_by_id f.cf_def_id
          in
          if existing <> Some inferred then begin
            install_user_contract env f inferred;
            changed := true
          end)
        funcs;
      if !changed then iterate (remaining - 1)
  in
  iterate 8

(* ============================================================================
   Branch detection
   ============================================================================ *)

(** Is this expression "linear" — no conditional control flow?

    We only transform let-bindings whose body is linear, because
    branch-aware analysis is deferred to Phase 2.2. Loops also count
    as branches for this phase (the body may execute 0+ times). *)
let rec is_linear (e : core) : bool =
  match e.desc with
  | CIf _ | CMatchArms _ | CMatch _ | CWhile _ | CFor _ | CConcurrent _
  | CConcurrentFor _ ->
      false
  (* Lambda/closure bodies and detached task bodies are evaluated later. At
     this site, only closure construction/spawn happens, so treat them as
     linear for binding-lifetime insertion. *)
  | CLambda _ | CClosureCreate _ | CDetach _ -> true
  (* Leaves: linear *)
  | CLit _ | CVar _ | CVoid | CBreak | CContinue -> true
  (* Compound: linear iff every child is linear *)
  | _ -> fold_immediate_children (fun acc c -> acc && is_linear c) true e

(* ============================================================================
   Insertion pass
   ============================================================================ *)

(** Prepend [n] nested [CDup v] wrappers onto [body], each bumping
    [v]'s refcount by one. The [ty] is [v]'s static type, stamped
    onto every inserted [CDup] node so emission has it directly.
    [n = 0] returns [body] unchanged. *)
let rec prepend_dups (n : int) (v : var) (ty : Ast.type_expr) (body : core) :
    core =
  if n <= 0 then body
  else
    let inner = prepend_dups (n - 1) v ty body in
    { body with desc = CDup (v, ty, inner) }

(** Prepend [n] nested [CDrop v] wrappers onto [body]. Drop-BEFORE
    semantics: each [CDrop] decrements [v]'s refcount then evaluates
    its body. The [ty] is stamped onto every inserted node so
    emission and Phase 2.6 drop-specialization can pick the right
    release/free sequence. *)
let rec prepend_drops (n : int) (v : var) (ty : Ast.type_expr) (body : core) :
    core =
  if n <= 0 then body
  else
    let inner = prepend_drops (n - 1) v ty body in
    { body with desc = CDrop (v, ty, inner) }

let is_void_type (t : Ast.type_expr) : bool = t = Ast.TyNamed ("Void", [])

(** Evaluate [body], then drop [v] [n] times, preserving [body]'s value.
    This is required for borrowed-only linear uses: dropping before the body
    would invalidate the borrow. *)
let drop_after_body (n : int) (v : var) (ty : Ast.type_expr) (body : core) :
    core =
  if n <= 0 then body
  else if is_void_type body.ty then
    let void_node = { desc = CVoid; ty = body.ty; loc = body.loc } in
    let drop = prepend_drops n v ty void_node in
    { body with desc = CSeq (body, drop) }
  else
    let tmp_name = Printf.sprintf "__cdrop_%s" v.vname in
    let tmp_var = Core.Var.named tmp_name in
    let tmp_ty = body.ty in
    let tmp_ref = { desc = CVar tmp_var; ty = tmp_ty; loc = body.loc } in
    let drop_then_ret = prepend_drops n v ty tmp_ref in
    let bind =
      {
        bind_var = tmp_var;
        bind_mut = false;
        bind_ty = tmp_ty;
        bind_rhs = body;
      }
    in
    { body with desc = CLet (bind, drop_then_ret) }

let is_global_function_symbol (env : type_env) (v : var) : bool =
  match v.vdef_id with
  | Some id when Hashtbl.mem env.global_function_ids id -> true
  | _ -> Hashtbl.mem env.global_function_names v.vname

let rec expr_result_is_alias (env : type_env) (e : core) : bool =
  match e.desc with
  | CField _ -> true
  | CUnbox (inner, _) | CCast (inner, _) -> expr_result_is_alias env inner
  | CCall (kind, _, args) -> (
      match
        contract_for_call env kind ~arg_count:(List.length args) ~return_ty:e.ty
      with
      | Some { Core_ownership.result = Core_ownership.ReturnAliasOfArg _; _ }
      | Some { Core_ownership.result = Core_ownership.ReturnBorrowed; _ } ->
          true
      | _ -> false)
  | _ -> false

let result_starts_with_dup_of (name : string) (body : core) : bool =
  match body.desc with
  | CDup (v, _, _) -> v.vname = name
  | CSeq ({ desc = CDup (v, _, _); _ }, _) -> v.vname = name
  | _ -> false

(** A binding initialized from a borrowed managed value creates a second
    logical owner. Retain before the binding body can mutate either alias,
    otherwise COW sees a false "unique" refcount and mutates shared data.

    This is intentionally narrower than general borrow inference: fresh
    allocation RHSs already own their result, while [CVar] and [CField] RHSs
    are aliases. Bare top-level function references are not runtime heap
    values yet; [Core_closure] later turns them into owned [CClosureCreate]
    values at the binding RHS. *)
type alias_source = AliasVar of var | AliasBinding

let rec alias_source_of_rhs (env : type_env) (b : binding) (rhs : core) :
    alias_source option =
  if not (is_managed_type env b.bind_ty) then None
  else
    match rhs.desc with
    | CVar source when source.vname <> b.bind_var.vname ->
        if is_global_function_symbol env source then None
        else Some (AliasVar source)
    | CField _ -> Some AliasBinding
    | CSeq (_, tail)
    | CUnbox (tail, _)
    | CCast (tail, _)
    | CDup (_, _, tail)
    | CDrop (_, _, tail) ->
        alias_source_of_rhs env b tail
    | _ when expr_result_is_alias env rhs -> Some AliasBinding
    | _ -> None

let retain_alias_source (env : type_env) (b : binding) (body : core) : core =
  match alias_source_of_rhs env b b.bind_rhs with
  | Some (AliasVar source) ->
      { body with desc = CDup (source, b.bind_ty, body) }
  | Some AliasBinding ->
      if result_starts_with_dup_of b.bind_var.vname body then body
      else { body with desc = CDup (b.bind_var, b.bind_ty, body) }
  | None -> body

let rec is_direct_field_alias (e : core) : bool =
  match e.desc with
  | CField ({ desc = CVar _; _ }, _) -> true
  | CField (owner, _) -> is_direct_field_alias owner
  | _ -> false

let consuming_mode_needs_owned_alias mode =
  Core_ownership.arg_consumes_caller mode

(** Field access returns an alias into its owner. Passing that alias directly to
    a consuming/COW-consuming/transferring call gives the callee something that
    looks uniquely owned even when the parent object is still live. Bind it
    first:

      cow(obj.field)  ==>  let __cow_arg_N = obj.field in cow(__cow_arg_N)

    The normal [retain_alias_source] rule then retains [__cow_arg_N], so runtime
    COW sees the shared refcount and copies instead of mutating the parent. *)
let protect_consuming_field_args (env : type_env) (e : core) : core =
  let counter = ref 0 in
  let next_tmp () =
    let n = !counter in
    incr counter;
    Var.named (Printf.sprintf "__cow_arg_%d" n)
  in
  let rewrite_call node =
    match node.desc with
    | CCall (kind, fn, args) -> (
        match
          contract_for_call env kind ~arg_count:(List.length args)
            ~return_ty:node.ty
        with
        | Some contract when List.length contract.args = List.length args ->
            let bindings = ref [] in
            let args' =
              List.map2
                (fun mode arg ->
                  if
                    consuming_mode_needs_owned_alias mode
                    && is_managed_type env arg.ty && is_direct_field_alias arg
                  then (
                    let tmp = next_tmp () in
                    bindings := !bindings @ [ (tmp, arg.ty, arg) ];
                    { arg with desc = CVar tmp })
                  else arg)
                contract.args args
            in
            let call = { node with desc = CCall (kind, fn, args') } in
            List.fold_right
              (fun (tmp, ty, rhs) body ->
                let bind =
                  {
                    bind_var = tmp;
                    bind_mut = false;
                    bind_ty = ty;
                    bind_rhs = rhs;
                  }
                in
                { body with desc = CLet (bind, body) })
              !bindings call
        | _ -> node)
    | _ -> node
  in
  transform_bottom_up rewrite_call e

let call_result_is_owned (env : type_env) (kind : call_kind) ~(arg_count : int)
    ~(return_ty : Ast.type_expr) : bool =
  match contract_for_call env kind ~arg_count ~return_ty with
  | Some { Core_ownership.result = Core_ownership.ReturnOwned; _ } -> true
  | Some _ -> false
  | None -> is_managed_type env return_ty

let lambda_has_runtime_captures (env : type_env) (lam : lambda) : bool =
  let module SS = Set.Make (String) in
  let is_global_name name = Hashtbl.mem env.global_function_names name in
  let is_free_name bound name =
    (not (SS.mem name bound)) && not (is_global_name name)
  in
  let add_var bound (v, _) = SS.add v.vname bound in
  let add_ctree_binding bound (v, _) = SS.add v.vname bound in
  let add_names bound names =
    List.fold_left (fun acc name -> SS.add name acc) bound names
  in
  let rec has_core bound e =
    match e.desc with
    | CVar v -> is_free_name bound v.vname
    | CLit _ | CVoid | CBreak | CContinue -> false
    | CLambda nested ->
        let inner_bound = List.fold_left add_var bound nested.lam_params in
        has_core inner_bound nested.lam_body
    | CClosureCreate cc ->
        List.exists (fun (name, _) -> is_free_name bound name) cc.cc_captures
    | CLet (b, body) ->
        has_core bound b.bind_rhs
        || has_core (SS.add b.bind_var.vname bound) body
    | CBorrowLet (b, body) ->
        has_core bound b.borrow_rhs
        || has_core (SS.add b.borrow_var.vname bound) body
    | CAssign (v, rhs) -> is_free_name bound v.vname || has_core bound rhs
    | CMatchArms (scrut, arms) ->
        has_core bound scrut
        || List.exists
             (fun (pat, arm) ->
               let arm_bound = add_names bound (Ast.collect_pattern_vars pat) in
               has_core arm_bound arm)
             arms
    | CMatch (scrut, tree) -> has_core bound scrut || has_ctree bound tree
    | CFor (binder, iter, body) ->
        has_core bound iter
        || has_core (SS.add binder.loop_var.vname bound) body
    | CConcurrent block ->
        let rhs_captures =
          List.exists
            (fun (b : conc_binding) -> has_core bound b.cb_rhs)
            block.conc_bindings
        in
        let body_bound =
          List.fold_left
            (fun acc (b : conc_binding) -> SS.add b.cb_var.vname acc)
            bound block.conc_bindings
        in
        rhs_captures
        || has_core body_bound block.conc_body
        || Option.fold ~none:false ~some:(has_core bound) block.conc_timeout
    | CConcurrentFor cf ->
        has_core bound cf.cf_iter
        || has_core (SS.add cf.cf_var.vname bound) cf.cf_body
        || Option.fold ~none:false ~some:(has_core bound) cf.cf_timeout
    | CDetach d -> (
        has_core bound d.detach_body
        ||
        match d.detach_task with
        | Some task ->
            List.exists
              (fun capture -> is_free_name bound capture.task_capture_name)
              task.tc_captures
        | None -> false)
    | _ ->
        fold_immediate_children
          (fun found child -> found || has_core bound child)
          false e
  and has_ctree bound = function
    | CTLeaf { ct_bindings; ct_body } ->
        let leaf_bound = List.fold_left add_ctree_binding bound ct_bindings in
        has_core leaf_bound ct_body
    | CTFail -> false
    | CTSwitchTag { cts_cases; cts_default; _ } ->
        List.exists (fun (_, sub) -> has_ctree bound sub) cts_cases
        || Option.fold ~none:false ~some:(has_ctree bound) cts_default
    | CTSwitchLit { ctl_cases; ctl_default; _ } ->
        List.exists (fun (_, sub) -> has_ctree bound sub) ctl_cases
        || has_ctree bound ctl_default
    | CTSwitchLen { ctl_len_cases; ctl_len_geq; ctl_len_default; _ } ->
        List.exists (fun (_, sub) -> has_ctree bound sub) ctl_len_cases
        || Option.fold ~none:false
             ~some:(fun (_, sub) -> has_ctree bound sub)
             ctl_len_geq
        || Option.fold ~none:false ~some:(has_ctree bound) ctl_len_default
  in
  let initial_bound = List.fold_left add_var SS.empty lam.lam_params in
  has_core initial_bound lam.lam_body

let is_owned_temporary_expr (env : type_env) (e : core) : bool =
  let module Owned = Set.Make (String) in
  let rec go owned (e : core) =
    if not (is_managed_type env e.ty) then false
    else
      match e.desc with
      | CVar v -> Owned.mem v.vname owned
      | CField _ -> false
      | CLit (Ast.LitString (_, _)) -> false
      | CCall (kind, _, args) ->
          call_result_is_owned env kind ~arg_count:(List.length args)
            ~return_ty:e.ty
      | CLet (b, body) ->
          let rhs_is_owned =
            (not b.bind_mut)
            && is_managed_type env b.bind_ty
            && go owned b.bind_rhs
          in
          let owned' =
            if rhs_is_owned then Owned.add b.bind_var.vname owned
            else Owned.remove b.bind_var.vname owned
          in
          go owned' body
      | CBorrowLet (b, body) -> go (Owned.remove b.borrow_var.vname owned) body
      | CSeq (_, body) -> go owned body
      | CIf (_, then_e, else_e) -> go owned then_e && go owned else_e
      | CDup (v, ty, body) ->
          let owned' =
            if is_managed_type env ty then Owned.add v.vname owned else owned
          in
          go owned' body
      | CDrop (v, _, body) -> go (Owned.remove v.vname owned) body
      | CList _ | CListAlloc _ | CDict _ | CTuple _ | CRecord _
      | CRecordUpdate _ | CVector _ | CStringInterp _ | CBox _ | CListHandoff _
        ->
          true
      | CClosureCreate cc -> cc.cc_captures <> []
      | CLambda lam -> lambda_has_runtime_captures env lam
      | _ -> false
  in
  go Owned.empty e

let borrowed_mode_needs_owned_temp_binding mode =
  Core_ownership.arg_preserves_caller mode

(** If an owned temporary flows into a borrowed call slot, the caller still
    owns that temporary after the call. Bind it to a synthetic [let] so the
    normal Perceus let-balancing path can insert the post-call drop:

      read(make_list())  ==>  let __borrow_arg_N = make_list() in read(__borrow_arg_N)

    This applies to borrowed arguments and to the callee object for closure
    calls. Direct variables and field projections are aliases of existing
    owners, so they must stay under the binding that already owns their
    lifetime. *)
let bind_borrowed_owned_temporary_args (env : type_env) (e : core) : core =
  let counter = ref 0 in
  let next_tmp prefix =
    let n = !counter in
    incr counter;
    Var.named (Printf.sprintf "__borrow_%s_%d" prefix n)
  in
  let bind_all bindings body =
    List.fold_right
      (fun (tmp, ty, rhs) body ->
        let bind =
          { bind_var = tmp; bind_mut = false; bind_ty = ty; bind_rhs = rhs }
        in
        { body with desc = CLet (bind, body) })
      bindings body
  in
  let rewrite_call node =
    match node.desc with
    | CBin (((Ast.Eq | Ast.Ne) as op), l, r) ->
        let bindings = ref [] in
        let bind_if_owned prefix arg =
          if is_owned_temporary_expr env arg then (
            let tmp = next_tmp prefix in
            bindings := !bindings @ [ (tmp, arg.ty, arg) ];
            { arg with desc = CVar tmp })
          else arg
        in
        let l' = bind_if_owned "bin_l" l in
        let r' = bind_if_owned "bin_r" r in
        bind_all !bindings { node with desc = CBin (op, l', r') }
    | CCall (kind, fn, args) -> (
        match
          contract_for_call env kind ~arg_count:(List.length args)
            ~return_ty:node.ty
        with
        | Some contract when List.length contract.args = List.length args ->
            let bindings = ref [] in
            let fn' =
              if kind = CKClosure && is_owned_temporary_expr env fn then (
                let tmp = next_tmp "callee" in
                bindings := !bindings @ [ (tmp, fn.ty, fn) ];
                { fn with desc = CVar tmp })
              else fn
            in
            let args' =
              List.map2
                (fun mode arg ->
                  if
                    borrowed_mode_needs_owned_temp_binding mode
                    && is_owned_temporary_expr env arg
                  then (
                    let tmp = next_tmp "arg" in
                    bindings := !bindings @ [ (tmp, arg.ty, arg) ];
                    { arg with desc = CVar tmp })
                  else arg)
                contract.args args
            in
            let call = { node with desc = CCall (kind, fn', args') } in
            bind_all !bindings call
        | _ -> node)
    | _ -> node
  in
  transform_bottom_up rewrite_call e

let borrowed_contains (name : string) (borrowed : string list) : bool =
  List.exists (( = ) name) borrowed

let borrowed_remove (name : string) (borrowed : string list) : string list =
  List.filter (fun n -> n <> name) borrowed

let rec pattern_bound_names (pat : Ast.pattern) : string list =
  match pat with
  | Ast.PatWildcard | Ast.PatLiteral _ -> []
  | Ast.PatVar n -> [ n ]
  | Ast.PatConstructor (_, args)
  | Ast.PatQualified (_, _, args)
  | Ast.PatTuple args
  | Ast.PatOr args ->
      List.concat_map pattern_bound_names args
  | Ast.PatList (args, spread) -> (
      List.concat_map pattern_bound_names args
      @ match spread with Some p -> pattern_bound_names p | None -> [])

let remove_bound_names (bound : string list) (borrowed : string list) :
    string list =
  List.filter (fun name -> not (List.exists (( = ) name) bound)) borrowed

let add_match_bindings (bindings : (var * accessor) list)
    (borrowed : string list) : string list =
  List.fold_left
    (fun acc (v, accessor) ->
      match accessor with
      | AccListSpread _ -> acc
      | _ -> if borrowed_contains v.vname acc then acc else v.vname :: acc)
    borrowed bindings

let rec expr_result_aliases_borrowed (env : type_env) (borrowed : string list)
    (e : core) : bool =
  match e.desc with
  | CVar v -> borrowed_contains v.vname borrowed
  | CField (owner, _) -> expr_result_aliases_borrowed env borrowed owner
  | CUnbox (inner, _) | CCast (inner, _) ->
      expr_result_aliases_borrowed env borrowed inner
  | CCall (kind, _, args) -> (
      match
        contract_for_call env kind ~arg_count:(List.length args) ~return_ty:e.ty
      with
      | Some { Core_ownership.result = Core_ownership.ReturnAliasOfArg idx; _ }
        -> (
          match List.nth_opt args idx with
          | Some arg -> expr_result_aliases_borrowed env borrowed arg
          | None -> false)
      | Some
          {
            Core_ownership.args = modes;
            result = Core_ownership.ReturnBorrowed;
          } ->
          list_exists2_safe
            (fun mode arg ->
              Core_ownership.arg_allows_borrowed_result_alias mode
              && expr_result_aliases_borrowed env borrowed arg)
            modes args
      | _ -> false)
  | _ -> false

let retain_borrowed_owned_arg_alias (env : type_env) (borrowed : string list)
    ~(next_tmp : unit -> var) (arg : core) : core * (core -> core) option =
  if
    (not (is_managed_type env arg.ty))
    || not (expr_result_aliases_borrowed env borrowed arg)
  then (arg, None)
  else
    match arg.desc with
    | CVar v when borrowed_contains v.vname borrowed ->
        let wrapper body = { body with desc = CDup (v, arg.ty, body) } in
        (arg, Some wrapper)
    | _ ->
        let tmp = next_tmp () in
        let tmp_ref = { arg with desc = CVar tmp } in
        let bind =
          { bind_var = tmp; bind_mut = false; bind_ty = arg.ty; bind_rhs = arg }
        in
        let wrapper body =
          let retained = { body with desc = CDup (tmp, arg.ty, body) } in
          { body with desc = CLet (bind, retained) }
        in
        (tmp_ref, Some wrapper)

let apply_wrappers (wrappers : (core -> core) list) (body : core) : core =
  List.fold_right (fun wrapper acc -> wrapper acc) wrappers body

let retain_borrowed_owned_call_arg_aliases (env : type_env)
    (borrowed : string list) (call_node : core) (kind : call_kind) (fn : core)
    (args : core list) : core =
  let counter = ref 0 in
  let next_tmp () =
    let n = !counter in
    incr counter;
    Var.named (Printf.sprintf "__borrowed_call_arg_%d" n)
  in
  match
    contract_for_call env kind ~arg_count:(List.length args)
      ~return_ty:call_node.ty
  with
  | Some contract when List.length contract.args = List.length args ->
      let args_and_wrappers =
        List.map2
          (fun mode arg ->
            if not (consuming_mode_needs_owned_alias mode) then (arg, None)
            else retain_borrowed_owned_arg_alias env borrowed ~next_tmp arg)
          contract.args args
      in
      let args' = List.map fst args_and_wrappers in
      let wrappers = List.filter_map snd args_and_wrappers in
      let call = { call_node with desc = CCall (kind, fn, args') } in
      apply_wrappers wrappers call
  | _ -> call_node

let is_collection_equality_type = function
  | Ast.TyNamed (("List" | "Dict" | "Set"), _) -> true
  | _ -> false

let binop_consumes_collection_args op l r =
  match op with
  | Ast.Eq | Ast.Ne ->
      is_collection_equality_type l.ty || is_collection_equality_type r.ty
  | _ -> false

let retain_borrowed_owned_binop_aliases (env : type_env)
    (borrowed : string list) (node : core) op l r : core =
  if not (binop_consumes_collection_args op l r) then
    { node with desc = CBin (op, l, r) }
  else
    let counter = ref 0 in
    let next_tmp () =
      let n = !counter in
      incr counter;
      Var.named (Printf.sprintf "__borrowed_binop_arg_%d" n)
    in
    let l', l_wrapper =
      retain_borrowed_owned_arg_alias env borrowed ~next_tmp l
    in
    let r', r_wrapper =
      retain_borrowed_owned_arg_alias env borrowed ~next_tmp r
    in
    let wrappers = List.filter_map (fun x -> x) [ l_wrapper; r_wrapper ] in
    apply_wrappers wrappers { node with desc = CBin (op, l', r') }

let rec retain_borrowed_owned_call_args_in_expr (env : type_env)
    ~(consumed_params : string list) (borrowed : string list) (e : core) : core
    =
  let recur consumed_params borrowed =
    retain_borrowed_owned_call_args_in_expr env ~consumed_params borrowed
  in
  match e.desc with
  | CBin (op, l, r) ->
      let l' = recur consumed_params borrowed l in
      let r' = recur consumed_params borrowed r in
      let call_borrowed = remove_bound_names consumed_params borrowed in
      retain_borrowed_owned_binop_aliases env call_borrowed e op l' r'
  | CCall (kind, fn, args) ->
      let fn' = recur consumed_params borrowed fn in
      let args' = List.map (recur consumed_params borrowed) args in
      let call_borrowed =
        if is_constructor_call env kind (List.length args') then borrowed
        else remove_bound_names consumed_params borrowed
      in
      retain_borrowed_owned_call_arg_aliases env call_borrowed
        { e with desc = CCall (kind, fn', args') }
        kind fn' args'
  | CLet (b, body) ->
      let rhs' = recur consumed_params borrowed b.bind_rhs in
      let consumed_params' = borrowed_remove b.bind_var.vname consumed_params in
      let body' =
        recur consumed_params' (borrowed_remove b.bind_var.vname borrowed) body
      in
      { e with desc = CLet ({ b with bind_rhs = rhs' }, body') }
  | CBorrowLet (b, body) ->
      let rhs' = recur consumed_params borrowed b.borrow_rhs in
      let consumed_params' =
        borrowed_remove b.borrow_var.vname consumed_params
      in
      let body' =
        recur consumed_params'
          (borrowed_remove b.borrow_var.vname borrowed)
          body
      in
      { e with desc = CBorrowLet ({ b with borrow_rhs = rhs' }, body') }
  | CLambda lam ->
      let param_names = List.map (fun (v, _) -> v.vname) lam.lam_params in
      let lambda_borrowed =
        param_names @ remove_bound_names param_names borrowed
      in
      let body' =
        recur
          (remove_bound_names param_names consumed_params)
          lambda_borrowed lam.lam_body
      in
      { e with desc = CLambda { lam with lam_body = body' } }
  | CFor (binder, iter, body) ->
      let iter' = recur consumed_params borrowed iter in
      let loop_borrowed =
        binder.loop_var.vname
        :: remove_bound_names [ binder.loop_var.vname ] borrowed
      in
      let body' =
        recur
          (remove_bound_names [ binder.loop_var.vname ] consumed_params)
          loop_borrowed body
      in
      { e with desc = CFor (binder, iter', body') }
  | CConcurrent cb ->
      let bindings' =
        List.map
          (fun b -> { b with cb_rhs = recur consumed_params borrowed b.cb_rhs })
          cb.conc_bindings
      in
      let bound = List.map (fun b -> b.cb_var.vname) cb.conc_bindings in
      let body' =
        recur
          (remove_bound_names bound consumed_params)
          (remove_bound_names bound borrowed)
          cb.conc_body
      in
      let timeout' =
        Option.map (recur consumed_params borrowed) cb.conc_timeout
      in
      {
        e with
        desc =
          CConcurrent
            {
              cb with
              conc_bindings = bindings';
              conc_body = body';
              conc_timeout = timeout';
            };
      }
  | CConcurrentFor cf ->
      let iter' = recur consumed_params borrowed cf.cf_iter in
      let loop_borrowed =
        cf.cf_var.vname :: remove_bound_names [ cf.cf_var.vname ] borrowed
      in
      let body' =
        recur
          (remove_bound_names [ cf.cf_var.vname ] consumed_params)
          loop_borrowed cf.cf_body
      in
      let timeout' =
        Option.map (recur consumed_params borrowed) cf.cf_timeout
      in
      {
        e with
        desc =
          CConcurrentFor
            { cf with cf_iter = iter'; cf_body = body'; cf_timeout = timeout' };
      }
  | CMatchArms (scrut, arms) ->
      let scrut' = recur consumed_params borrowed scrut in
      let arms' =
        List.map
          (fun (pat, body) ->
            let bound = pattern_bound_names pat in
            let arm_borrowed = bound @ remove_bound_names bound borrowed in
            ( pat,
              recur (remove_bound_names bound consumed_params) arm_borrowed body
            ))
          arms
      in
      { e with desc = CMatchArms (scrut', arms') }
  | CMatch (scrut, tree) ->
      let scrut' = recur consumed_params borrowed scrut in
      let tree' =
        retain_borrowed_owned_call_args_in_ctree env ~consumed_params borrowed
          tree
      in
      { e with desc = CMatch (scrut', tree') }
  | CDup (v, ty, body) ->
      {
        e with
        desc =
          CDup
            ( v,
              ty,
              recur
                (borrowed_remove v.vname consumed_params)
                (borrowed_remove v.vname borrowed)
                body );
      }
  | CDrop (v, ty, body) ->
      { e with desc = CDrop (v, ty, recur consumed_params borrowed body) }
  | CClosureCreate _ -> e
  | _ -> map_children (recur consumed_params borrowed) e

and retain_borrowed_owned_call_args_in_ctree (env : type_env)
    ~(consumed_params : string list) (borrowed : string list) (tree : ctree) :
    ctree =
  match tree with
  | CTLeaf { ct_bindings; ct_body } ->
      let leaf_borrowed = add_match_bindings ct_bindings borrowed in
      let bound = List.map (fun (v, _) -> v.vname) ct_bindings in
      CTLeaf
        {
          ct_bindings;
          ct_body =
            retain_borrowed_owned_call_args_in_expr env
              ~consumed_params:(remove_bound_names bound consumed_params)
              leaf_borrowed ct_body;
        }
  | CTFail -> CTFail
  | CTSwitchTag { cts_scrut; cts_cases; cts_default } ->
      CTSwitchTag
        {
          cts_scrut;
          cts_cases =
            List.map
              (fun (n, sub) ->
                ( n,
                  retain_borrowed_owned_call_args_in_ctree env ~consumed_params
                    borrowed sub ))
              cts_cases;
          cts_default =
            Option.map
              (retain_borrowed_owned_call_args_in_ctree env ~consumed_params
                 borrowed)
              cts_default;
        }
  | CTSwitchLit { ctl_scrut; ctl_cases; ctl_default } ->
      CTSwitchLit
        {
          ctl_scrut;
          ctl_cases =
            List.map
              (fun (lit, sub) ->
                ( lit,
                  retain_borrowed_owned_call_args_in_ctree env ~consumed_params
                    borrowed sub ))
              ctl_cases;
          ctl_default =
            retain_borrowed_owned_call_args_in_ctree env ~consumed_params
              borrowed ctl_default;
        }
  | CTSwitchLen { ctl_len_scrut; ctl_len_cases; ctl_len_geq; ctl_len_default }
    ->
      CTSwitchLen
        {
          ctl_len_scrut;
          ctl_len_cases =
            List.map
              (fun (n, sub) ->
                ( n,
                  retain_borrowed_owned_call_args_in_ctree env ~consumed_params
                    borrowed sub ))
              ctl_len_cases;
          ctl_len_geq =
            Option.map
              (fun (n, sub) ->
                ( n,
                  retain_borrowed_owned_call_args_in_ctree env ~consumed_params
                    borrowed sub ))
              ctl_len_geq;
          ctl_len_default =
            Option.map
              (retain_borrowed_owned_call_args_in_ctree env ~consumed_params
                 borrowed)
              ctl_len_default;
        }

let retain_borrowed_owned_call_args_in_matches (env : type_env) (e : core) :
    core =
  match e.desc with
  | CMatch (scrut, tree) ->
      {
        e with
        desc =
          CMatch
            ( scrut,
              retain_borrowed_owned_call_args_in_ctree env ~consumed_params:[]
                [] tree );
      }
  | CMatchArms (scrut, arms) ->
      let arms' =
        List.map
          (fun (pat, body) ->
            ( pat,
              retain_borrowed_owned_call_args_in_expr env ~consumed_params:[]
                (pattern_bound_names pat) body ))
          arms
      in
      { e with desc = CMatchArms (scrut, arms') }
  | _ -> e

let retain_then_return_var (loc : Ast.loc) (v : var) (ty : Ast.type_expr) : core
    =
  let void_node = { desc = CVoid; ty = Ast.TyNamed ("Void", []); loc } in
  let retain = { desc = CDup (v, ty, void_node); ty = void_node.ty; loc } in
  let tmp_ref = { desc = CVar v; ty; loc } in
  { desc = CSeq (retain, tmp_ref); ty; loc }

let retain_owned_result_expr (e : core) : core =
  let tmp = Var.named "__owned_result" in
  let bind =
    { bind_var = tmp; bind_mut = false; bind_ty = e.ty; bind_rhs = e }
  in
  { e with desc = CLet (bind, retain_then_return_var e.loc tmp e.ty) }

let assignment_rhs_is_alias (env : type_env) (rhs : core) : bool =
  let rec result_aliases local_aliases expr =
    match expr.desc with
    | CVar v -> (
        match List.assoc_opt v.vname local_aliases with
        | Some aliases -> aliases
        | None -> not (is_global_function_symbol env v))
    | CLet (b, body) ->
        let aliases =
          is_managed_type env b.bind_ty
          && result_aliases local_aliases b.bind_rhs
        in
        result_aliases ((b.bind_var.vname, aliases) :: local_aliases) body
    | CBorrowLet (b, body) ->
        let aliases = is_managed_type env b.borrow_ty in
        result_aliases ((b.borrow_var.vname, aliases) :: local_aliases) body
    | CSeq (_, tail) -> result_aliases local_aliases tail
    | CDup (_, _, body) | CDrop (_, _, body) ->
        result_aliases local_aliases body
    | CIf (_, then_e, else_e) ->
        result_aliases local_aliases then_e
        || result_aliases local_aliases else_e
    | _ -> expr_result_is_alias env expr
  in
  result_aliases [] rhs

let retain_assignment_alias_rhs (env : type_env) (e : core) : core =
  match e.desc with
  | CAssign ({ vname = "_"; _ }, _) -> e
  | CAssign (v, rhs)
    when is_managed_type env rhs.ty && assignment_rhs_is_alias env rhs ->
      { e with desc = CAssign (v, retain_owned_result_expr rhs) }
  | _ -> e

let rec expr_contains_var (name : string) (e : core) : bool =
  match e.desc with
  | CVar v -> v.vname = name
  | CLet (b, body) ->
      expr_contains_var name b.bind_rhs
      || (b.bind_var.vname <> name && expr_contains_var name body)
  | CBorrowLet (b, body) ->
      expr_contains_var name b.borrow_rhs
      || (b.borrow_var.vname <> name && expr_contains_var name body)
  | CMatchArms (scrut, arms) ->
      expr_contains_var name scrut
      || List.exists
           (fun (pat, body) ->
             (not (pattern_binds name pat)) && expr_contains_var name body)
           arms
  | CMatch (scrut, tree) ->
      expr_contains_var name scrut || ctree_contains_var name tree
  | CFor (binder, iter, body) ->
      expr_contains_var name iter
      || (binder.loop_var.vname <> name && expr_contains_var name body)
  | CLambda lam ->
      (not (List.exists (fun (v, _) -> v.vname = name) lam.lam_params))
      && expr_contains_var name lam.lam_body
  | CConcurrent cb ->
      let rhs_mentions =
        List.exists
          (fun (b : conc_binding) -> expr_contains_var name b.cb_rhs)
          cb.conc_bindings
      in
      let shadowed =
        List.exists
          (fun (b : conc_binding) -> b.cb_var.vname = name)
          cb.conc_bindings
      in
      rhs_mentions
      || ((not shadowed) && expr_contains_var name cb.conc_body)
      || Option.fold ~none:false ~some:(expr_contains_var name) cb.conc_timeout
  | CConcurrentFor cf ->
      expr_contains_var name cf.cf_iter
      || (cf.cf_var.vname <> name && expr_contains_var name cf.cf_body)
      || Option.fold ~none:false ~some:(expr_contains_var name) cf.cf_timeout
  | _ ->
      fold_immediate_children
        (fun found child -> found || expr_contains_var name child)
        false e

and ctree_contains_var (name : string) (tree : ctree) : bool =
  match tree with
  | CTLeaf { ct_bindings; ct_body } ->
      (not (List.exists (fun (v, _) -> v.vname = name) ct_bindings))
      && expr_contains_var name ct_body
  | CTFail -> false
  | CTSwitchTag { cts_cases; cts_default; _ } ->
      List.exists (fun (_, sub) -> ctree_contains_var name sub) cts_cases
      || Option.fold ~none:false ~some:(ctree_contains_var name) cts_default
  | CTSwitchLit { ctl_cases; ctl_default; _ } ->
      List.exists (fun (_, sub) -> ctree_contains_var name sub) ctl_cases
      || ctree_contains_var name ctl_default
  | CTSwitchLen { ctl_len_cases; ctl_len_geq; ctl_len_default; _ } ->
      List.exists (fun (_, sub) -> ctree_contains_var name sub) ctl_len_cases
      || Option.fold ~none:false
           ~some:(fun (_, sub) -> ctree_contains_var name sub)
           ctl_len_geq
      || Option.fold ~none:false ~some:(ctree_contains_var name) ctl_len_default

let rec expr_consumes_var_owner (env : type_env) (name : string) (e : core) :
    bool =
  let rec consuming_arg arg =
    match arg.desc with
    | CVar v -> v.vname = name
    | CUnbox (inner, _) | CCast (inner, _) | CBox (inner, _) ->
        consuming_arg inner
    | CLet (b, body) ->
        expr_consumes_var_owner env name b.bind_rhs
        || (b.bind_var.vname <> name && consuming_arg body)
    | CBorrowLet (b, body) ->
        expr_consumes_var_owner env name b.borrow_rhs
        || (b.borrow_var.vname <> name && consuming_arg body)
    | CSeq (head, tail) ->
        expr_consumes_var_owner env name head || consuming_arg tail
    | CIf (cond, then_e, else_e) ->
        expr_consumes_var_owner env name cond
        || consuming_arg then_e || consuming_arg else_e
    | CMatchArms (scrut, arms) ->
        expr_consumes_var_owner env name scrut
        || List.exists
             (fun (pat, body) ->
               (not (pattern_binds name pat)) && consuming_arg body)
             arms
    | CField (owner, _) -> expr_consumes_var_owner env name owner
    | _ -> expr_consumes_var_owner env name arg
  in
  match e.desc with
  | CVar _ | CLit _ | CVoid | CBreak | CContinue | CClosureCreate _ -> false
  | CBin (((Ast.Eq | Ast.Ne) as op), l, r)
    when binop_consumes_collection_args op l r ->
      consuming_arg l || consuming_arg r
  | CCall (kind, fn, args) ->
      let fn_consumes =
        match kind with
        | CKClosure -> expr_consumes_var_owner env name fn
        | _ -> false
      in
      let arg_consumes =
        match
          contract_for_call env kind ~arg_count:(List.length args)
            ~return_ty:e.ty
        with
        | Some { Core_ownership.args = modes; _ }
          when List.length modes = List.length args ->
            List.exists2
              (fun mode arg ->
                if Core_ownership.arg_consumes_caller mode then
                  consuming_arg arg
                else expr_consumes_var_owner env name arg)
              modes args
        | _ -> List.exists (expr_contains_var name) args
      in
      fn_consumes || arg_consumes
  | CLet (b, body) ->
      expr_consumes_var_owner env name b.bind_rhs
      || (b.bind_var.vname <> name && expr_consumes_var_owner env name body)
  | CBorrowLet (b, body) ->
      expr_consumes_var_owner env name b.borrow_rhs
      || (b.borrow_var.vname <> name && expr_consumes_var_owner env name body)
  | CSeq (head, tail) ->
      expr_consumes_var_owner env name head
      || expr_consumes_var_owner env name tail
  | CIf (cond, then_e, else_e) ->
      expr_consumes_var_owner env name cond
      || expr_consumes_var_owner env name then_e
      || expr_consumes_var_owner env name else_e
  | CMatchArms (scrut, arms) ->
      expr_consumes_var_owner env name scrut
      || List.exists
           (fun (pat, body) ->
             (not (pattern_binds name pat))
             && expr_consumes_var_owner env name body)
           arms
  | CMatch (scrut, tree) ->
      expr_consumes_var_owner env name scrut
      || ctree_consumes_var_owner env name tree
  | CFor (binder, iter, body) ->
      expr_consumes_var_owner env name iter
      || (binder.loop_var.vname <> name && expr_consumes_var_owner env name body)
  | CLambda lam ->
      (not (List.exists (fun (v, _) -> v.vname = name) lam.lam_params))
      && expr_consumes_var_owner env name lam.lam_body
  | CConcurrent cb ->
      let rhs_consumes =
        List.exists
          (fun (b : conc_binding) -> expr_consumes_var_owner env name b.cb_rhs)
          cb.conc_bindings
      in
      let shadowed =
        List.exists
          (fun (b : conc_binding) -> b.cb_var.vname = name)
          cb.conc_bindings
      in
      rhs_consumes
      || ((not shadowed) && expr_consumes_var_owner env name cb.conc_body)
      || Option.fold ~none:false
           ~some:(expr_consumes_var_owner env name)
           cb.conc_timeout
  | CConcurrentFor cf ->
      expr_consumes_var_owner env name cf.cf_iter
      || (cf.cf_var.vname <> name && expr_consumes_var_owner env name cf.cf_body)
      || Option.fold ~none:false
           ~some:(expr_consumes_var_owner env name)
           cf.cf_timeout
  | _ ->
      fold_immediate_children
        (fun found child -> found || expr_consumes_var_owner env name child)
        false e

and ctree_consumes_var_owner (env : type_env) (name : string) (tree : ctree) :
    bool =
  match tree with
  | CTLeaf { ct_bindings; ct_body } ->
      (not (List.exists (fun (v, _) -> v.vname = name) ct_bindings))
      && expr_consumes_var_owner env name ct_body
  | CTFail -> false
  | CTSwitchTag { cts_cases; cts_default; _ } ->
      List.exists
        (fun (_, sub) -> ctree_consumes_var_owner env name sub)
        cts_cases
      || Option.fold ~none:false
           ~some:(ctree_consumes_var_owner env name)
           cts_default
  | CTSwitchLit { ctl_cases; ctl_default; _ } ->
      List.exists
        (fun (_, sub) -> ctree_consumes_var_owner env name sub)
        ctl_cases
      || ctree_consumes_var_owner env name ctl_default
  | CTSwitchLen { ctl_len_cases; ctl_len_geq; ctl_len_default; _ } ->
      List.exists
        (fun (_, sub) -> ctree_consumes_var_owner env name sub)
        ctl_len_cases
      || Option.fold ~none:false
           ~some:(fun (_, sub) -> ctree_consumes_var_owner env name sub)
           ctl_len_geq
      || Option.fold ~none:false
           ~some:(ctree_consumes_var_owner env name)
           ctl_len_default

let rec expr_assigns_var (name : string) (e : core) : bool =
  match e.desc with
  | CAssign (v, _) when v.vname = name -> true
  | CLet (b, body) ->
      expr_assigns_var name b.bind_rhs
      || (b.bind_var.vname <> name && expr_assigns_var name body)
  | CBorrowLet (b, body) ->
      expr_assigns_var name b.borrow_rhs
      || (b.borrow_var.vname <> name && expr_assigns_var name body)
  | CMatchArms (scrut, arms) ->
      expr_assigns_var name scrut
      || List.exists
           (fun (pat, body) ->
             (not (pattern_binds name pat)) && expr_assigns_var name body)
           arms
  | CMatch (scrut, tree) ->
      expr_assigns_var name scrut || ctree_assigns_var name tree
  | CFor (binder, iter, body) ->
      expr_assigns_var name iter
      || (binder.loop_var.vname <> name && expr_assigns_var name body)
  | CLambda lam ->
      (not (List.exists (fun (v, _) -> v.vname = name) lam.lam_params))
      && expr_assigns_var name lam.lam_body
  | CConcurrent cb ->
      let rhs_assigns =
        List.exists
          (fun (b : conc_binding) -> expr_assigns_var name b.cb_rhs)
          cb.conc_bindings
      in
      let shadowed =
        List.exists
          (fun (b : conc_binding) -> b.cb_var.vname = name)
          cb.conc_bindings
      in
      rhs_assigns
      || ((not shadowed) && expr_assigns_var name cb.conc_body)
      || Option.fold ~none:false ~some:(expr_assigns_var name) cb.conc_timeout
  | CConcurrentFor cf ->
      expr_assigns_var name cf.cf_iter
      || (cf.cf_var.vname <> name && expr_assigns_var name cf.cf_body)
      || Option.fold ~none:false ~some:(expr_assigns_var name) cf.cf_timeout
  | _ ->
      fold_immediate_children
        (fun found child -> found || expr_assigns_var name child)
        false e

and ctree_assigns_var (name : string) (tree : ctree) : bool =
  match tree with
  | CTLeaf { ct_bindings; ct_body } ->
      (not (List.exists (fun (v, _) -> v.vname = name) ct_bindings))
      && expr_assigns_var name ct_body
  | CTFail -> false
  | CTSwitchTag { cts_cases; cts_default; _ } ->
      List.exists (fun (_, sub) -> ctree_assigns_var name sub) cts_cases
      || Option.fold ~none:false ~some:(ctree_assigns_var name) cts_default
  | CTSwitchLit { ctl_cases; ctl_default; _ } ->
      List.exists (fun (_, sub) -> ctree_assigns_var name sub) ctl_cases
      || ctree_assigns_var name ctl_default
  | CTSwitchLen { ctl_len_cases; ctl_len_geq; ctl_len_default; _ } ->
      List.exists (fun (_, sub) -> ctree_assigns_var name sub) ctl_len_cases
      || Option.fold ~none:false
           ~some:(fun (_, sub) -> ctree_assigns_var name sub)
           ctl_len_geq
      || Option.fold ~none:false ~some:(ctree_assigns_var name) ctl_len_default

let remove_names names set =
  List.fold_left (fun acc name -> StringSet.remove name acc) set names

let remove_var_names vars set =
  List.fold_left (fun acc (v, _) -> StringSet.remove v.vname acc) set vars

let rec expr_tail_alias_vars (e : core) : StringSet.t =
  match e.desc with
  | CVar v -> StringSet.singleton v.vname
  | CField (owner, _) -> expr_tail_alias_vars owner
  | CUnbox (inner, _) | CCast (inner, _) -> expr_tail_alias_vars inner
  | CLet (b, body) ->
      let body_aliases = expr_tail_alias_vars body in
      let aliases =
        if StringSet.mem b.bind_var.vname body_aliases then
          StringSet.union body_aliases (expr_tail_alias_vars b.bind_rhs)
        else body_aliases
      in
      StringSet.remove b.bind_var.vname aliases
  | CBorrowLet (b, body) ->
      let body_aliases = expr_tail_alias_vars body in
      let aliases =
        if StringSet.mem b.borrow_var.vname body_aliases then
          StringSet.union body_aliases (expr_tail_alias_vars b.borrow_rhs)
        else body_aliases
      in
      StringSet.remove b.borrow_var.vname aliases
  | CSeq (_, tail) -> expr_tail_alias_vars tail
  | CDup (_, _, body) | CDrop (_, _, body) -> expr_tail_alias_vars body
  | CIf (_, then_e, else_e) ->
      StringSet.union
        (expr_tail_alias_vars then_e)
        (expr_tail_alias_vars else_e)
  | CMatchArms (_, arms) ->
      List.fold_left
        (fun acc (pat, body) ->
          let aliases = expr_tail_alias_vars body in
          let aliases = remove_names (Ast.collect_pattern_vars pat) aliases in
          StringSet.union acc aliases)
        StringSet.empty arms
  | CMatch (_, tree) -> ctree_tail_alias_vars tree
  | _ -> StringSet.empty

and ctree_tail_alias_vars (tree : ctree) : StringSet.t =
  match tree with
  | CTLeaf { ct_bindings; ct_body } ->
      remove_var_names ct_bindings (expr_tail_alias_vars ct_body)
  | CTFail -> StringSet.empty
  | CTSwitchTag { cts_cases; cts_default; _ } ->
      List.fold_left
        (fun acc (_, sub) -> StringSet.union acc (ctree_tail_alias_vars sub))
        (Option.fold ~none:StringSet.empty ~some:ctree_tail_alias_vars
           cts_default)
        cts_cases
  | CTSwitchLit { ctl_cases; ctl_default; _ } ->
      List.fold_left
        (fun acc (_, sub) -> StringSet.union acc (ctree_tail_alias_vars sub))
        (ctree_tail_alias_vars ctl_default)
        ctl_cases
  | CTSwitchLen { ctl_len_cases; ctl_len_geq; ctl_len_default; _ } ->
      let aliases =
        List.fold_left
          (fun acc (_, sub) -> StringSet.union acc (ctree_tail_alias_vars sub))
          StringSet.empty ctl_len_cases
      in
      let aliases =
        Option.fold ~none:aliases
          ~some:(fun (_, sub) ->
            StringSet.union aliases (ctree_tail_alias_vars sub))
          ctl_len_geq
      in
      Option.fold ~none:aliases
        ~some:(fun sub -> StringSet.union aliases (ctree_tail_alias_vars sub))
        ctl_len_default

let expr_tail_aliases_var (name : string) (e : core) : bool =
  StringSet.mem name (expr_tail_alias_vars e)

let rec expr_final_consumes_var_owner (env : type_env) (name : string)
    (e : core) : bool =
  let expr_touches_current_owner e =
    expr_contains_var name e || expr_assigns_var name e
    || expr_consumes_var_owner env name e
  in
  match e.desc with
  | CAssign (v, _) when v.vname = name -> false
  | CLet (b, body) ->
      if b.bind_var.vname = name then false
      else if expr_touches_current_owner body then
        expr_final_consumes_var_owner env name body
      else expr_final_consumes_var_owner env name b.bind_rhs
  | CBorrowLet (b, body) ->
      if b.borrow_var.vname = name then false
      else if expr_touches_current_owner body then
        expr_final_consumes_var_owner env name body
      else expr_final_consumes_var_owner env name b.borrow_rhs
  | CSeq (head, tail) ->
      if expr_touches_current_owner tail then
        expr_final_consumes_var_owner env name tail
      else expr_final_consumes_var_owner env name head
  | CIf (cond, then_e, else_e) ->
      let then_touches = expr_touches_current_owner then_e in
      let else_touches = expr_touches_current_owner else_e in
      if then_touches || else_touches then
        then_touches && else_touches
        && expr_final_consumes_var_owner env name then_e
        && expr_final_consumes_var_owner env name else_e
      else expr_consumes_var_owner env name cond
  | CMatchArms (scrut, arms) ->
      let arm_states =
        List.map
          (fun (pat, body) ->
            if pattern_binds name pat then Some false
            else if expr_touches_current_owner body then
              Some (expr_final_consumes_var_owner env name body)
            else None)
          arms
      in
      if List.exists Option.is_some arm_states then
        List.for_all (function Some true -> true | _ -> false) arm_states
      else expr_consumes_var_owner env name scrut
  | CMatch (scrut, tree) ->
      let leaf_states = ctree_final_consumes_var_owner env name tree in
      if List.exists Option.is_some leaf_states then
        List.for_all (function Some true -> true | _ -> false) leaf_states
      else expr_consumes_var_owner env name scrut
  | _ -> expr_consumes_var_owner env name e && not (expr_assigns_var name e)

and ctree_final_consumes_var_owner (env : type_env) (name : string)
    (tree : ctree) : bool option list =
  let expr_touches_current_owner e =
    expr_contains_var name e || expr_assigns_var name e
    || expr_consumes_var_owner env name e
  in
  match tree with
  | CTLeaf { ct_bindings; ct_body } ->
      if List.exists (fun (v, _) -> v.vname = name) ct_bindings then
        [ Some false ]
      else if expr_touches_current_owner ct_body then
        [ Some (expr_final_consumes_var_owner env name ct_body) ]
      else [ None ]
  | CTFail -> [ None ]
  | CTSwitchTag { cts_cases; cts_default; _ } ->
      List.concat_map
        (fun (_, sub) -> ctree_final_consumes_var_owner env name sub)
        cts_cases
      @ Option.fold ~none:[ None ]
          ~some:(ctree_final_consumes_var_owner env name)
          cts_default
  | CTSwitchLit { ctl_cases; ctl_default; _ } ->
      List.concat_map
        (fun (_, sub) -> ctree_final_consumes_var_owner env name sub)
        ctl_cases
      @ ctree_final_consumes_var_owner env name ctl_default
  | CTSwitchLen { ctl_len_cases; ctl_len_geq; ctl_len_default; _ } ->
      List.concat_map
        (fun (_, sub) -> ctree_final_consumes_var_owner env name sub)
        ctl_len_cases
      @ Option.fold ~none:[ None ]
          ~some:(fun (_, sub) -> ctree_final_consumes_var_owner env name sub)
          ctl_len_geq
      @ Option.fold ~none:[ None ]
          ~some:(ctree_final_consumes_var_owner env name)
          ctl_len_default

let release_reassigned_mutable_var (env : type_env)
    ?(target_starts_as_alias = false) (target : var) (target_ty : Ast.type_expr)
    (body : core) : core =
  let counter = ref 0 in
  let next_tmp () =
    let n = !counter in
    incr counter;
    Var.named (Printf.sprintf "__assign_%s_%d" target.vname n)
  in
  let void_at loc = { desc = CVoid; ty = Ast.TyNamed ("Void", []); loc } in
  let rec rhs_aliases_borrowed_name borrowed rhs =
    match rhs.desc with
    | CVar v -> List.mem v.vname borrowed
    | CField (owner, _) -> rhs_aliases_borrowed_name borrowed owner
    | CLet (b, _) -> rhs_aliases_borrowed_name borrowed b.bind_rhs
    | CBorrowLet (b, _) -> rhs_aliases_borrowed_name borrowed b.borrow_rhs
    | CSeq (_, tail) -> rhs_aliases_borrowed_name borrowed tail
    | CDup (_, _, body) | CDrop (_, _, body) ->
        rhs_aliases_borrowed_name borrowed body
    | _ -> false
  in
  let rhs_result_is_nonborrowed_var_alias borrowed rhs =
    let rec result_aliases local_aliases expr =
      match expr.desc with
      | CVar v -> (
          match List.assoc_opt v.vname local_aliases with
          | Some aliases_nonborrowed -> aliases_nonborrowed
          | None ->
              (not (List.mem v.vname borrowed))
              && not (is_global_function_symbol env v))
      | CLet (b, body) ->
          let aliases_nonborrowed =
            is_managed_type env b.bind_ty
            && result_aliases local_aliases b.bind_rhs
          in
          result_aliases
            ((b.bind_var.vname, aliases_nonborrowed) :: local_aliases)
            body
      | CBorrowLet (b, body) ->
          result_aliases ((b.borrow_var.vname, false) :: local_aliases) body
      | CSeq (_, tail)
      | CDup (_, _, tail)
      | CDrop (_, _, tail)
      | CUnbox (tail, _)
      | CCast (tail, _) ->
          result_aliases local_aliases tail
      | _ -> false
    in
    result_aliases [] rhs
  in
  let rec rewrite ?(skip_old_release = false) ?(borrowed_aliases = []) e =
    match e.desc with
    | CAssign (v, rhs) when v.vname = target.vname ->
        let rhs = rewrite ~skip_old_release:false ~borrowed_aliases rhs in
        if skip_old_release || expr_consumes_var_owner env target.vname rhs then
          let assign = { e with desc = CAssign (v, rhs) } in
          (* If a prior COW-consuming expression already consumed the old
             alias owner, do not release it again. Alias RHS normalization may
             add an extra retain to survive match-scrutinee teardown; balance
             that retain after the assignment. *)
          if skip_old_release && assignment_rhs_is_alias env rhs then
            {
              e with
              desc =
                CSeq
                  ( assign,
                    {
                      desc = CDrop (v, target_ty, void_at e.loc);
                      ty = Ast.TyNamed ("Void", []);
                      loc = e.loc;
                    } );
            }
          else assign
        else
          let tmp = next_tmp () in
          let tmp_ref = { rhs with desc = CVar tmp } in
          let drop_old =
            {
              desc = CDrop (target, target_ty, void_at e.loc);
              ty = Ast.TyNamed ("Void", []);
              loc = e.loc;
            }
          in
          let assign_new =
            {
              e with
              desc = CAssign (v, tmp_ref);
              ty = Ast.TyNamed ("Void", []);
            }
          in
          let assign_tail =
            if rhs_result_is_nonborrowed_var_alias borrowed_aliases rhs then
              {
                e with
                desc =
                  CSeq
                    ( assign_new,
                      {
                        desc = CDrop (v, target_ty, void_at e.loc);
                        ty = Ast.TyNamed ("Void", []);
                        loc = e.loc;
                      } );
              }
            else assign_new
          in
          let seq = { e with desc = CSeq (drop_old, assign_tail) } in
          let bind =
            {
              bind_var = tmp;
              bind_mut = false;
              bind_ty = rhs.ty;
              bind_rhs = rhs;
            }
          in
          { e with desc = CLet (bind, seq) }
    | CLet (b, inner_body) ->
        let b' =
          {
            b with
            bind_rhs =
              rewrite ~skip_old_release:false ~borrowed_aliases b.bind_rhs;
          }
        in
        let body' =
          if b.bind_var.vname = target.vname then inner_body
          else
            let borrowed_aliases =
              if rhs_aliases_borrowed_name borrowed_aliases b.bind_rhs then
                b.bind_var.vname :: borrowed_aliases
              else borrowed_aliases
            in
            let skip_body =
              (skip_old_release
              || target_starts_as_alias
                 && expr_consumes_var_owner env target.vname b.bind_rhs)
              && not (expr_assigns_var target.vname b.bind_rhs)
            in
            rewrite ~skip_old_release:skip_body ~borrowed_aliases inner_body
        in
        { e with desc = CLet (b', body') }
    | CBorrowLet (b, inner_body) ->
        let b' =
          {
            b with
            borrow_rhs =
              rewrite ~skip_old_release:false ~borrowed_aliases b.borrow_rhs;
          }
        in
        let body' =
          if b.borrow_var.vname = target.vname then inner_body
          else
            let borrowed_aliases =
              if rhs_aliases_borrowed_name borrowed_aliases b.borrow_rhs then
                b.borrow_var.vname :: borrowed_aliases
              else borrowed_aliases
            in
            let skip_body =
              (skip_old_release
              || target_starts_as_alias
                 && expr_consumes_var_owner env target.vname b.borrow_rhs)
              && not (expr_assigns_var target.vname b.borrow_rhs)
            in
            rewrite ~skip_old_release:skip_body ~borrowed_aliases inner_body
        in
        { e with desc = CBorrowLet (b', body') }
    | CSeq (head, tail) ->
        let head' = rewrite ~skip_old_release ~borrowed_aliases head in
        let skip_tail =
          (skip_old_release && not (expr_assigns_var target.vname head))
          || expr_consumes_var_owner env target.vname head
             && not (expr_assigns_var target.vname head)
        in
        {
          e with
          desc =
            CSeq
              (head', rewrite ~skip_old_release:skip_tail ~borrowed_aliases tail);
        }
    | CMatchArms (scrut, arms) ->
        let scrut' = rewrite ~skip_old_release:false ~borrowed_aliases scrut in
        let arm_skip =
          skip_old_release || expr_consumes_var_owner env target.vname scrut
        in
        let arms' =
          List.map
            (fun (pat, arm) ->
              if pattern_binds target.vname pat then (pat, arm)
              else
                let borrowed_aliases =
                  pattern_bound_names pat @ borrowed_aliases
                in
                (pat, rewrite ~skip_old_release:arm_skip ~borrowed_aliases arm))
            arms
        in
        { e with desc = CMatchArms (scrut', arms') }
    | CMatch (scrut, tree) ->
        let tree_skip =
          skip_old_release || expr_consumes_var_owner env target.vname scrut
        in
        {
          e with
          desc =
            CMatch
              ( rewrite ~skip_old_release:false ~borrowed_aliases scrut,
                rewrite_ctree ~skip_old_release:tree_skip ~borrowed_aliases tree
              );
        }
    | CFor (binder, iter, loop_body) ->
        let loop_body' =
          if binder.loop_var.vname = target.vname then loop_body
          else rewrite ~skip_old_release ~borrowed_aliases loop_body
        in
        {
          e with
          desc =
            CFor
              ( binder,
                rewrite ~skip_old_release:false ~borrowed_aliases iter,
                loop_body' );
        }
    | CLambda lam ->
        if List.exists (fun (v, _) -> v.vname = target.vname) lam.lam_params
        then e
        else
          {
            e with
            desc =
              CLambda
                {
                  lam with
                  lam_body =
                    rewrite ~skip_old_release ~borrowed_aliases lam.lam_body;
                };
          }
    | CConcurrent cb ->
        let shadowed =
          List.exists
            (fun (b : conc_binding) -> b.cb_var.vname = target.vname)
            cb.conc_bindings
        in
        {
          e with
          desc =
            CConcurrent
              {
                cb with
                conc_bindings =
                  List.map
                    (fun b ->
                      {
                        b with
                        cb_rhs =
                          rewrite ~skip_old_release:false ~borrowed_aliases
                            b.cb_rhs;
                      })
                    cb.conc_bindings;
                conc_body =
                  (if shadowed then cb.conc_body
                   else rewrite ~skip_old_release ~borrowed_aliases cb.conc_body);
                conc_timeout =
                  Option.map
                    (rewrite ~skip_old_release ~borrowed_aliases)
                    cb.conc_timeout;
              };
        }
    | CConcurrentFor cf ->
        {
          e with
          desc =
            CConcurrentFor
              {
                cf with
                cf_iter =
                  rewrite ~skip_old_release:false ~borrowed_aliases cf.cf_iter;
                cf_body =
                  (if cf.cf_var.vname = target.vname then cf.cf_body
                   else rewrite ~skip_old_release ~borrowed_aliases cf.cf_body);
                cf_timeout =
                  Option.map
                    (rewrite ~skip_old_release ~borrowed_aliases)
                    cf.cf_timeout;
              };
        }
    | _ -> map_children (rewrite ~skip_old_release ~borrowed_aliases) e
  and rewrite_ctree ?(skip_old_release = false) ?(borrowed_aliases = []) tree =
    match tree with
    | CTLeaf { ct_bindings; ct_body } ->
        let ct_body =
          if List.exists (fun (v, _) -> v.vname = target.vname) ct_bindings then
            ct_body
          else
            let borrowed_aliases =
              List.map (fun (v, _) -> v.vname) ct_bindings @ borrowed_aliases
            in
            rewrite ~skip_old_release ~borrowed_aliases ct_body
        in
        CTLeaf { ct_bindings; ct_body }
    | CTFail -> CTFail
    | CTSwitchTag { cts_scrut; cts_cases; cts_default } ->
        CTSwitchTag
          {
            cts_scrut;
            cts_cases =
              List.map
                (fun (n, sub) ->
                  (n, rewrite_ctree ~skip_old_release ~borrowed_aliases sub))
                cts_cases;
            cts_default =
              Option.map
                (rewrite_ctree ~skip_old_release ~borrowed_aliases)
                cts_default;
          }
    | CTSwitchLit { ctl_scrut; ctl_cases; ctl_default } ->
        CTSwitchLit
          {
            ctl_scrut;
            ctl_cases =
              List.map
                (fun (lit, sub) ->
                  (lit, rewrite_ctree ~skip_old_release ~borrowed_aliases sub))
                ctl_cases;
            ctl_default =
              rewrite_ctree ~skip_old_release ~borrowed_aliases ctl_default;
          }
    | CTSwitchLen { ctl_len_scrut; ctl_len_cases; ctl_len_geq; ctl_len_default }
      ->
        CTSwitchLen
          {
            ctl_len_scrut;
            ctl_len_cases =
              List.map
                (fun (n, sub) ->
                  (n, rewrite_ctree ~skip_old_release ~borrowed_aliases sub))
                ctl_len_cases;
            ctl_len_geq =
              Option.map
                (fun (n, sub) ->
                  (n, rewrite_ctree ~skip_old_release ~borrowed_aliases sub))
                ctl_len_geq;
            ctl_len_default =
              Option.map
                (rewrite_ctree ~skip_old_release ~borrowed_aliases)
                ctl_len_default;
          }
  in
  rewrite body

let rec normalize_owned_result_aliases (env : type_env) (e : core) : core =
  match e.desc with
  | _ when is_managed_type env e.ty && expr_result_is_alias env e ->
      retain_owned_result_expr e
  | CIf (cond, then_e, else_e) ->
      {
        e with
        desc =
          CIf
            ( cond,
              normalize_owned_result_aliases env then_e,
              normalize_owned_result_aliases env else_e );
      }
  | CMatchArms (scrut, arms) ->
      {
        e with
        desc =
          CMatchArms
            ( scrut,
              List.map
                (fun (pat, body) ->
                  (pat, normalize_owned_result_aliases env body))
                arms );
      }
  | CMatch (scrut, tree) ->
      {
        e with
        desc = CMatch (scrut, normalize_owned_result_aliases_ctree env tree);
      }
  | CLet (b, body) ->
      { e with desc = CLet (b, normalize_owned_result_aliases env body) }
  | CBorrowLet (b, body) ->
      { e with desc = CBorrowLet (b, normalize_owned_result_aliases env body) }
  | CSeq (head, tail) ->
      { e with desc = CSeq (head, normalize_owned_result_aliases env tail) }
  | CDup (v, ty, body) ->
      { e with desc = CDup (v, ty, normalize_owned_result_aliases env body) }
  | CDrop (v, ty, body) ->
      { e with desc = CDrop (v, ty, normalize_owned_result_aliases env body) }
  | _ -> e

and normalize_owned_result_aliases_ctree (env : type_env) (tree : ctree) : ctree
    =
  match tree with
  | CTLeaf { ct_bindings; ct_body } ->
      CTLeaf
        { ct_bindings; ct_body = normalize_owned_result_aliases env ct_body }
  | CTFail -> CTFail
  | CTSwitchTag { cts_scrut; cts_cases; cts_default } ->
      CTSwitchTag
        {
          cts_scrut;
          cts_cases =
            List.map
              (fun (n, sub) ->
                (n, normalize_owned_result_aliases_ctree env sub))
              cts_cases;
          cts_default =
            Option.map (normalize_owned_result_aliases_ctree env) cts_default;
        }
  | CTSwitchLit { ctl_scrut; ctl_cases; ctl_default } ->
      CTSwitchLit
        {
          ctl_scrut;
          ctl_cases =
            List.map
              (fun (lit, sub) ->
                (lit, normalize_owned_result_aliases_ctree env sub))
              ctl_cases;
          ctl_default = normalize_owned_result_aliases_ctree env ctl_default;
        }
  | CTSwitchLen { ctl_len_scrut; ctl_len_cases; ctl_len_geq; ctl_len_default }
    ->
      CTSwitchLen
        {
          ctl_len_scrut;
          ctl_len_cases =
            List.map
              (fun (n, sub) ->
                (n, normalize_owned_result_aliases_ctree env sub))
              ctl_len_cases;
          ctl_len_geq =
            Option.map
              (fun (n, sub) ->
                (n, normalize_owned_result_aliases_ctree env sub))
              ctl_len_geq;
          ctl_len_default =
            Option.map
              (normalize_owned_result_aliases_ctree env)
              ctl_len_default;
        }

let rec dups_lead_to_owned_aggregate (e : core) : bool =
  match e.desc with
  | CRecord _ | CTuple _ -> true
  | CDup (_, _, body) -> dups_lead_to_owned_aggregate body
  | _ -> false

(** Pattern-bound values in a compiled [CMatch] are aliases into the match
    scrutinee. Local vars and field/call aliases can also be transferred into
    owning aggregates while the original owner is still scheduled for a later
    drop. In both cases the aggregate must get its own refcount for managed
    members. Fresh owned members still transfer without an extra retain. *)
let rec retain_borrowed_aggregate_members_in_expr (env : type_env)
    (borrowed : string list) (e : core) : core =
  let recur borrowed = retain_borrowed_aggregate_members_in_expr env borrowed in
  let e' =
    match e.desc with
    | CLet (b, body) ->
        let rhs' = recur borrowed b.bind_rhs in
        let body' = recur (borrowed_remove b.bind_var.vname borrowed) body in
        { e with desc = CLet ({ b with bind_rhs = rhs' }, body') }
    | CBorrowLet (b, body) ->
        let rhs' = recur borrowed b.borrow_rhs in
        let body_borrowed = borrowed_remove b.borrow_var.vname borrowed in
        let body' = recur body_borrowed body in
        { e with desc = CBorrowLet ({ b with borrow_rhs = rhs' }, body') }
    | CLambda lam ->
        let param_names = List.map (fun (v, _) -> v.vname) lam.lam_params in
        let lambda_borrowed =
          param_names @ remove_bound_names param_names borrowed
        in
        let body' = recur lambda_borrowed lam.lam_body in
        { e with desc = CLambda { lam with lam_body = body' } }
    | CFor (binder, iter, body) ->
        let iter' = recur borrowed iter in
        let loop_borrowed =
          binder.loop_var.vname
          :: remove_bound_names [ binder.loop_var.vname ] borrowed
        in
        let body' = recur loop_borrowed body in
        { e with desc = CFor (binder, iter', body') }
    | CConcurrent cb ->
        let bindings' =
          List.map
            (fun b -> { b with cb_rhs = recur borrowed b.cb_rhs })
            cb.conc_bindings
        in
        let bound = List.map (fun b -> b.cb_var.vname) cb.conc_bindings in
        let body' = recur (remove_bound_names bound borrowed) cb.conc_body in
        let timeout' = Option.map (recur borrowed) cb.conc_timeout in
        {
          e with
          desc =
            CConcurrent
              {
                cb with
                conc_bindings = bindings';
                conc_body = body';
                conc_timeout = timeout';
              };
        }
    | CConcurrentFor cf ->
        let iter' = recur borrowed cf.cf_iter in
        let loop_borrowed =
          cf.cf_var.vname :: remove_bound_names [ cf.cf_var.vname ] borrowed
        in
        let body' = recur loop_borrowed cf.cf_body in
        let timeout' = Option.map (recur borrowed) cf.cf_timeout in
        {
          e with
          desc =
            CConcurrentFor
              {
                cf with
                cf_iter = iter';
                cf_body = body';
                cf_timeout = timeout';
              };
        }
    | CMatchArms (scrut, arms) ->
        let scrut' = recur borrowed scrut in
        let arms' =
          List.map
            (fun (pat, body) ->
              let bound = pattern_bound_names pat in
              let arm_borrowed = bound @ remove_bound_names bound borrowed in
              (pat, recur arm_borrowed body))
            arms
        in
        { e with desc = CMatchArms (scrut', arms') }
    | CMatch (scrut, tree) ->
        let scrut' = recur borrowed scrut in
        let tree' =
          retain_borrowed_aggregate_members_in_ctree env borrowed tree
        in
        { e with desc = CMatch (scrut', tree') }
    | CDup _ when dups_lead_to_owned_aggregate e -> e
    | CDup (v, ty, body) ->
        let borrowed' =
          if
            borrowed_contains v.vname borrowed
            && dups_lead_to_owned_aggregate body
          then borrowed_remove v.vname borrowed
          else borrowed
        in
        { e with desc = CDup (v, ty, recur borrowed' body) }
    | CClosureCreate _ -> e
    | _ -> map_children (recur borrowed) e
  in
  match e'.desc with
  | CRecord fields ->
      retain_borrowed_record_field_aliases env borrowed e' fields
  | CTuple elems -> retain_borrowed_tuple_element_aliases env borrowed e' elems
  | _ -> e'

and retain_borrowed_aggregate_members_in_ctree (env : type_env)
    (borrowed : string list) (tree : ctree) : ctree =
  match tree with
  | CTLeaf { ct_bindings; ct_body } ->
      let leaf_borrowed = add_match_bindings ct_bindings borrowed in
      CTLeaf
        {
          ct_bindings;
          ct_body =
            retain_borrowed_aggregate_members_in_expr env leaf_borrowed ct_body;
        }
  | CTFail -> CTFail
  | CTSwitchTag { cts_scrut; cts_cases; cts_default } ->
      CTSwitchTag
        {
          cts_scrut;
          cts_cases =
            List.map
              (fun (n, sub) ->
                (n, retain_borrowed_aggregate_members_in_ctree env borrowed sub))
              cts_cases;
          cts_default =
            Option.map
              (retain_borrowed_aggregate_members_in_ctree env borrowed)
              cts_default;
        }
  | CTSwitchLit { ctl_scrut; ctl_cases; ctl_default } ->
      CTSwitchLit
        {
          ctl_scrut;
          ctl_cases =
            List.map
              (fun (lit, sub) ->
                ( lit,
                  retain_borrowed_aggregate_members_in_ctree env borrowed sub ))
              ctl_cases;
          ctl_default =
            retain_borrowed_aggregate_members_in_ctree env borrowed ctl_default;
        }
  | CTSwitchLen { ctl_len_scrut; ctl_len_cases; ctl_len_geq; ctl_len_default }
    ->
      CTSwitchLen
        {
          ctl_len_scrut;
          ctl_len_cases =
            List.map
              (fun (n, sub) ->
                (n, retain_borrowed_aggregate_members_in_ctree env borrowed sub))
              ctl_len_cases;
          ctl_len_geq =
            Option.map
              (fun (n, sub) ->
                (n, retain_borrowed_aggregate_members_in_ctree env borrowed sub))
              ctl_len_geq;
          ctl_len_default =
            Option.map
              (retain_borrowed_aggregate_members_in_ctree env borrowed)
              ctl_len_default;
        }

and retain_borrowed_record_field_aliases (env : type_env)
    (borrowed : string list) (record_node : core)
    (fields : (string * core) list) : core =
  let counter = ref 0 in
  let next_tmp () =
    let n = !counter in
    incr counter;
    Var.named (Printf.sprintf "__borrowed_record_field_%d" n)
  in
  let fields', wrappers =
    List.fold_left
      (fun (fields_acc, wrappers_acc) (name, field) ->
        if
          (not (is_managed_type env field.ty))
          || not (expr_aliases_existing_owner env borrowed field)
        then ((name, field) :: fields_acc, wrappers_acc)
        else
          match field.desc with
          | CVar v ->
              let wrapper body =
                { body with desc = CDup (v, field.ty, body) }
              in
              ((name, field) :: fields_acc, wrapper :: wrappers_acc)
          | _ ->
              let tmp = next_tmp () in
              let tmp_ref = { field with desc = CVar tmp } in
              let bind =
                {
                  bind_var = tmp;
                  bind_mut = false;
                  bind_ty = field.ty;
                  bind_rhs = field;
                }
              in
              let wrapper body =
                let retained =
                  { body with desc = CDup (tmp, field.ty, body) }
                in
                { body with desc = CLet (bind, retained) }
              in
              ((name, tmp_ref) :: fields_acc, wrapper :: wrappers_acc))
      ([], []) fields
  in
  let record = { record_node with desc = CRecord (List.rev fields') } in
  List.fold_right (fun wrapper body -> wrapper body) (List.rev wrappers) record

and retain_borrowed_tuple_element_aliases (env : type_env)
    (borrowed : string list) (tuple_node : core) (elems : core list) : core =
  let counter = ref 0 in
  let next_tmp () =
    let n = !counter in
    incr counter;
    Var.named (Printf.sprintf "__borrowed_tuple_elem_%d" n)
  in
  let elems', wrappers =
    List.fold_left
      (fun (elems_acc, wrappers_acc) elem ->
        if
          (not (is_managed_type env elem.ty))
          || not (expr_aliases_existing_owner env borrowed elem)
        then (elem :: elems_acc, wrappers_acc)
        else
          match elem.desc with
          | CVar v ->
              let wrapper body = { body with desc = CDup (v, elem.ty, body) } in
              (elem :: elems_acc, wrapper :: wrappers_acc)
          | _ ->
              let tmp = next_tmp () in
              let tmp_ref = { elem with desc = CVar tmp } in
              let bind =
                {
                  bind_var = tmp;
                  bind_mut = false;
                  bind_ty = elem.ty;
                  bind_rhs = elem;
                }
              in
              let wrapper body =
                let retained = { body with desc = CDup (tmp, elem.ty, body) } in
                { body with desc = CLet (bind, retained) }
              in
              (tmp_ref :: elems_acc, wrapper :: wrappers_acc))
      ([], []) elems
  in
  let tuple = { tuple_node with desc = CTuple (List.rev elems') } in
  List.fold_right (fun wrapper body -> wrapper body) (List.rev wrappers) tuple

and expr_aliases_existing_owner (env : type_env) (borrowed : string list)
    (expr : core) : bool =
  expr_result_aliases_borrowed env borrowed expr
  || assignment_rhs_is_alias env expr

let retain_borrowed_aggregate_members_in_matches (env : type_env) (e : core) :
    core =
  match e.desc with
  | CMatch (scrut, tree) ->
      {
        e with
        desc =
          CMatch (scrut, retain_borrowed_aggregate_members_in_ctree env [] tree);
      }
  | CMatchArms (scrut, arms) ->
      let arms' =
        List.map
          (fun (pat, body) ->
            ( pat,
              retain_borrowed_aggregate_members_in_expr env
                (pattern_bound_names pat) body ))
          arms
      in
      { e with desc = CMatchArms (scrut, arms') }
  | _ -> e

let retain_borrowed_result_expr (e : core) : core =
  let tmp = Var.named "__borrowed_match_result" in
  let bind =
    { bind_var = tmp; bind_mut = false; bind_ty = e.ty; bind_rhs = e }
  in
  { e with desc = CLet (bind, retain_then_return_var e.loc tmp e.ty) }

(** A match pattern binding is a borrowed view into the scrutinee. When a match
    branch returns that binding directly, the match expression result must be an
    owned value before it flows into the surrounding [CLet]. Retain inside the
    branch, not after the whole match, because sibling branches may return fresh
    owned values or immortal literals that must not get an extra ref. *)
let rec retain_borrowed_result_vars_in_expr (env : type_env)
    (borrowed : string list) (e : core) : core =
  let retain_direct_var v = { e with desc = CDup (v, e.ty, e) } in
  match e.desc with
  | CVar v when borrowed_contains v.vname borrowed && is_managed_type env e.ty
    ->
      retain_direct_var v
  | (CField _ | CCall _ | CUnbox _ | CCast _)
    when is_managed_type env e.ty && expr_result_aliases_borrowed env borrowed e
    ->
      retain_borrowed_result_expr e
  | CIf (cond, then_e, else_e) ->
      {
        e with
        desc =
          CIf
            ( cond,
              retain_borrowed_result_vars_in_expr env borrowed then_e,
              retain_borrowed_result_vars_in_expr env borrowed else_e );
      }
  | CMatchArms (scrut, arms) ->
      let arms' =
        List.map
          (fun (pat, body) ->
            let bound = pattern_bound_names pat in
            let arm_borrowed = bound @ remove_bound_names bound borrowed in
            (pat, retain_borrowed_result_vars_in_expr env arm_borrowed body))
          arms
      in
      { e with desc = CMatchArms (scrut, arms') }
  | CMatch (scrut, tree) ->
      {
        e with
        desc =
          CMatch (scrut, retain_borrowed_result_vars_in_ctree env borrowed tree);
      }
  | CLet (b, body) ->
      let body_borrowed = borrowed_remove b.bind_var.vname borrowed in
      {
        e with
        desc =
          CLet (b, retain_borrowed_result_vars_in_expr env body_borrowed body);
      }
  | CBorrowLet (b, body) ->
      let body_borrowed = borrowed_remove b.borrow_var.vname borrowed in
      {
        e with
        desc =
          CBorrowLet
            (b, retain_borrowed_result_vars_in_expr env body_borrowed body);
      }
  | CSeq (head, tail) ->
      {
        e with
        desc = CSeq (head, retain_borrowed_result_vars_in_expr env borrowed tail);
      }
  | CAssign (v, rhs) ->
      {
        e with
        desc = CAssign (v, retain_borrowed_result_vars_in_expr env borrowed rhs);
      }
  | CDup (v, ty, body) ->
      let body_borrowed = borrowed_remove v.vname borrowed in
      {
        e with
        desc =
          CDup
            (v, ty, retain_borrowed_result_vars_in_expr env body_borrowed body);
      }
  | CDrop (v, ty, body) ->
      {
        e with
        desc =
          CDrop (v, ty, retain_borrowed_result_vars_in_expr env borrowed body);
      }
  | CFor (binder, iter, body) ->
      let loop_borrowed =
        binder.loop_var.vname
        :: remove_bound_names [ binder.loop_var.vname ] borrowed
      in
      {
        e with
        desc =
          CFor
            ( binder,
              iter,
              retain_borrowed_result_vars_in_expr env loop_borrowed body );
      }
  | CConcurrentFor cf ->
      let loop_borrowed =
        cf.cf_var.vname :: remove_bound_names [ cf.cf_var.vname ] borrowed
      in
      {
        e with
        desc =
          CConcurrentFor
            {
              cf with
              cf_body =
                retain_borrowed_result_vars_in_expr env loop_borrowed cf.cf_body;
            };
      }
  | _ -> e

and retain_borrowed_result_vars_in_ctree (env : type_env)
    (borrowed : string list) (tree : ctree) : ctree =
  match tree with
  | CTLeaf { ct_bindings; ct_body } ->
      let leaf_borrowed = add_match_bindings ct_bindings borrowed in
      CTLeaf
        {
          ct_bindings;
          ct_body =
            retain_borrowed_result_vars_in_expr env leaf_borrowed ct_body;
        }
  | CTFail -> CTFail
  | CTSwitchTag { cts_scrut; cts_cases; cts_default } ->
      CTSwitchTag
        {
          cts_scrut;
          cts_cases =
            List.map
              (fun (n, sub) ->
                (n, retain_borrowed_result_vars_in_ctree env borrowed sub))
              cts_cases;
          cts_default =
            Option.map
              (retain_borrowed_result_vars_in_ctree env borrowed)
              cts_default;
        }
  | CTSwitchLit { ctl_scrut; ctl_cases; ctl_default } ->
      CTSwitchLit
        {
          ctl_scrut;
          ctl_cases =
            List.map
              (fun (lit, sub) ->
                (lit, retain_borrowed_result_vars_in_ctree env borrowed sub))
              ctl_cases;
          ctl_default =
            retain_borrowed_result_vars_in_ctree env borrowed ctl_default;
        }
  | CTSwitchLen { ctl_len_scrut; ctl_len_cases; ctl_len_geq; ctl_len_default }
    ->
      CTSwitchLen
        {
          ctl_len_scrut;
          ctl_len_cases =
            List.map
              (fun (n, sub) ->
                (n, retain_borrowed_result_vars_in_ctree env borrowed sub))
              ctl_len_cases;
          ctl_len_geq =
            Option.map
              (fun (n, sub) ->
                (n, retain_borrowed_result_vars_in_ctree env borrowed sub))
              ctl_len_geq;
          ctl_len_default =
            Option.map
              (retain_borrowed_result_vars_in_ctree env borrowed)
              ctl_len_default;
        }

let retain_borrowed_result_vars_in_matches (env : type_env) (e : core) : core =
  match e.desc with
  | CMatch (scrut, tree) ->
      {
        e with
        desc = CMatch (scrut, retain_borrowed_result_vars_in_ctree env [] tree);
      }
  | CMatchArms (scrut, arms) ->
      let arms' =
        List.map
          (fun (pat, body) ->
            ( pat,
              retain_borrowed_result_vars_in_expr env (pattern_bound_names pat)
                body ))
          arms
      in
      { e with desc = CMatchArms (scrut, arms') }
  | _ -> e

let rec normalize_lambda_result_aliases (env : type_env) (e : core) : core =
  match e.desc with
  | CLambda lam ->
      let body = normalize_lambda_result_aliases env lam.lam_body in
      let body =
        if is_managed_type env lam.lam_return_ty then
          let param_names = List.map (fun (v, _) -> v.vname) lam.lam_params in
          body
          |> retain_borrowed_aggregate_members_in_expr env param_names
          |> retain_borrowed_owned_call_args_in_expr env ~consumed_params:[]
               param_names
          |> retain_borrowed_result_vars_in_expr env param_names
          |> normalize_owned_result_aliases env
        else body
      in
      { e with desc = CLambda { lam with lam_body = body } }
  | CClosureCreate _ -> e
  | _ -> map_children (normalize_lambda_result_aliases env) e

let max_required_refs (uses : ownership_uses list) : int =
  List.fold_left (fun acc u -> max acc u.required_refs) 0 uses

(** Match pattern bindings can intentionally shadow an outer owner. Perceus may
    still need to drop that outer owner inside only the shadowed branch, so the
    shadow binding must get a fresh Core name before branch-local drops are
    inserted. *)
let fresh_shadow_var (v : var) : var =
  Var.named (Core_ssa.fresh_version ("__perceus_shadow_" ^ v.vname))

let rec rename_shadow_var_refs (old_name : string) (new_var : var) (e : core) :
    core =
  match e.desc with
  | CVar v when v.vname = old_name -> { e with desc = CVar new_var }
  | CAssign (v, rhs) when v.vname = old_name ->
      {
        e with
        desc = CAssign (new_var, rename_shadow_var_refs old_name new_var rhs);
      }
  | CDup (v, ty, body) ->
      let v' = if v.vname = old_name then new_var else v in
      {
        e with
        desc = CDup (v', ty, rename_shadow_var_refs old_name new_var body);
      }
  | CDrop (v, ty, body) ->
      let v' = if v.vname = old_name then new_var else v in
      {
        e with
        desc = CDrop (v', ty, rename_shadow_var_refs old_name new_var body);
      }
  | CLet (b, body) when b.bind_var.vname = old_name ->
      {
        e with
        desc =
          CLet
            ( {
                b with
                bind_rhs = rename_shadow_var_refs old_name new_var b.bind_rhs;
              },
              body );
      }
  | CBorrowLet (b, body) when b.borrow_var.vname = old_name ->
      {
        e with
        desc =
          CBorrowLet
            ( {
                b with
                borrow_rhs =
                  rename_shadow_var_refs old_name new_var b.borrow_rhs;
              },
              body );
      }
  | CResourceScope scope when scope.rs_var.vname = old_name ->
      {
        e with
        desc =
          CResourceScope
            {
              scope with
              rs_acquire =
                rename_shadow_var_refs old_name new_var scope.rs_acquire;
            };
      }
  | CResourceScope scope ->
      {
        e with
        desc =
          CResourceScope
            {
              scope with
              rs_acquire =
                rename_shadow_var_refs old_name new_var scope.rs_acquire;
              rs_body = rename_shadow_var_refs old_name new_var scope.rs_body;
              rs_cleanup =
                rename_shadow_var_refs old_name new_var scope.rs_cleanup;
            };
      }
  | CFor (binder, iter, body) when binder.loop_var.vname = old_name ->
      {
        e with
        desc = CFor (binder, rename_shadow_var_refs old_name new_var iter, body);
      }
  | CLambda lam
    when List.exists (fun (param, _) -> param.vname = old_name) lam.lam_params
    ->
      e
  | CMatchArms (scrut, arms) ->
      let scrut' = rename_shadow_var_refs old_name new_var scrut in
      let arms' =
        List.map
          (fun (pat, body) ->
            if pattern_binds old_name pat then (pat, body)
            else (pat, rename_shadow_var_refs old_name new_var body))
          arms
      in
      { e with desc = CMatchArms (scrut', arms') }
  | CMatch (scrut, tree) ->
      {
        e with
        desc =
          CMatch
            ( rename_shadow_var_refs old_name new_var scrut,
              rename_shadow_var_refs_ctree old_name new_var tree );
      }
  | _ -> Core.map_children (rename_shadow_var_refs old_name new_var) e

and rename_shadow_var_refs_ctree (old_name : string) (new_var : var)
    (tree : ctree) : ctree =
  match tree with
  | CTLeaf { ct_bindings; ct_body } ->
      if List.exists (fun (v, _) -> v.vname = old_name) ct_bindings then tree
      else
        CTLeaf
          {
            ct_bindings;
            ct_body = rename_shadow_var_refs old_name new_var ct_body;
          }
  | CTFail -> CTFail
  | CTSwitchTag { cts_scrut; cts_cases; cts_default } ->
      CTSwitchTag
        {
          cts_scrut;
          cts_cases =
            List.map
              (fun (n, sub) ->
                (n, rename_shadow_var_refs_ctree old_name new_var sub))
              cts_cases;
          cts_default =
            Option.map
              (rename_shadow_var_refs_ctree old_name new_var)
              cts_default;
        }
  | CTSwitchLit { ctl_scrut; ctl_cases; ctl_default } ->
      CTSwitchLit
        {
          ctl_scrut;
          ctl_cases =
            List.map
              (fun (lit, sub) ->
                (lit, rename_shadow_var_refs_ctree old_name new_var sub))
              ctl_cases;
          ctl_default =
            rename_shadow_var_refs_ctree old_name new_var ctl_default;
        }
  | CTSwitchLen { ctl_len_scrut; ctl_len_cases; ctl_len_geq; ctl_len_default }
    ->
      CTSwitchLen
        {
          ctl_len_scrut;
          ctl_len_cases =
            List.map
              (fun (n, sub) ->
                (n, rename_shadow_var_refs_ctree old_name new_var sub))
              ctl_len_cases;
          ctl_len_geq =
            Option.map
              (fun (n, sub) ->
                (n, rename_shadow_var_refs_ctree old_name new_var sub))
              ctl_len_geq;
          ctl_len_default =
            Option.map
              (rename_shadow_var_refs_ctree old_name new_var)
              ctl_len_default;
        }

let rec rename_pattern_binding (old_name : string) (new_name : string)
    (pat : Ast.pattern) : Ast.pattern =
  match pat with
  | Ast.PatVar name when name = old_name -> Ast.PatVar new_name
  | Ast.PatConstructor (ctor, args) ->
      Ast.PatConstructor
        (ctor, List.map (rename_pattern_binding old_name new_name) args)
  | Ast.PatQualified (module_name, ctor, args) ->
      Ast.PatQualified
        ( module_name,
          ctor,
          List.map (rename_pattern_binding old_name new_name) args )
  | Ast.PatTuple args ->
      Ast.PatTuple (List.map (rename_pattern_binding old_name new_name) args)
  | Ast.PatOr args ->
      Ast.PatOr (List.map (rename_pattern_binding old_name new_name) args)
  | Ast.PatList (args, spread) ->
      Ast.PatList
        ( List.map (rename_pattern_binding old_name new_name) args,
          Option.map (rename_pattern_binding old_name new_name) spread )
  | _ -> pat

let freshen_match_arm_shadow (v : var) (pat : Ast.pattern) (body : core) :
    Ast.pattern * core =
  if not (pattern_binds v.vname pat) then (pat, body)
  else
    let shadow = fresh_shadow_var v in
    let pat' = rename_pattern_binding v.vname shadow.vname pat in
    let body' = rename_shadow_var_refs v.vname shadow body in
    (pat', body')

let freshen_match_arm_shadows (v : var) (arms : (Ast.pattern * core) list) :
    (Ast.pattern * core) list =
  List.map (fun (pat, body) -> freshen_match_arm_shadow v pat body) arms

let rec freshen_ctree_shadow_bindings (v : var) (tree : ctree) : ctree =
  match tree with
  | CTLeaf { ct_bindings; ct_body } ->
      if not (List.exists (fun (bv, _) -> bv.vname = v.vname) ct_bindings) then
        tree
      else
        let shadow = fresh_shadow_var v in
        let ct_bindings' =
          List.map
            (fun (bv, acc) ->
              if bv.vname = v.vname then (shadow, acc) else (bv, acc))
            ct_bindings
        in
        let ct_body' = rename_shadow_var_refs v.vname shadow ct_body in
        CTLeaf { ct_bindings = ct_bindings'; ct_body = ct_body' }
  | CTFail -> CTFail
  | CTSwitchTag { cts_scrut; cts_cases; cts_default } ->
      CTSwitchTag
        {
          cts_scrut;
          cts_cases =
            List.map
              (fun (n, sub) -> (n, freshen_ctree_shadow_bindings v sub))
              cts_cases;
          cts_default = Option.map (freshen_ctree_shadow_bindings v) cts_default;
        }
  | CTSwitchLit { ctl_scrut; ctl_cases; ctl_default } ->
      CTSwitchLit
        {
          ctl_scrut;
          ctl_cases =
            List.map
              (fun (lit, sub) -> (lit, freshen_ctree_shadow_bindings v sub))
              ctl_cases;
          ctl_default = freshen_ctree_shadow_bindings v ctl_default;
        }
  | CTSwitchLen { ctl_len_scrut; ctl_len_cases; ctl_len_geq; ctl_len_default }
    ->
      CTSwitchLen
        {
          ctl_len_scrut;
          ctl_len_cases =
            List.map
              (fun (n, sub) -> (n, freshen_ctree_shadow_bindings v sub))
              ctl_len_cases;
          ctl_len_geq =
            Option.map
              (fun (n, sub) -> (n, freshen_ctree_shadow_bindings v sub))
              ctl_len_geq;
          ctl_len_default =
            Option.map (freshen_ctree_shadow_bindings v) ctl_len_default;
        }

(** Balance a single mutually-exclusive branch.

    [available_refs] is the number of owned refs live when the branch starts.
    Drop excess refs before the branch so COW sees the lowest safe refcount, then
    drop borrowed-only leftovers after the branch body has evaluated. Branches
    that return an alias into [v] keep the required ref live in the result and
    therefore skip the post-body drop. *)
let rec balance_branch_body (env : type_env) (v : var) (ty : Ast.type_expr)
    ~(available_refs : int) (uses : ownership_uses) (body : core) : core =
  let pre_drops = max 0 (available_refs - uses.required_refs) in
  let live_refs = max 0 (available_refs - pre_drops) in
  match balance_nested_branch_body env v ty ~available_refs:live_refs body with
  | Some balanced_body -> prepend_drops pre_drops v ty balanced_body
  | None ->
      if uses.returns_alias then prepend_drops pre_drops v ty body
      else
        let post_drops = max 0 (uses.required_refs - uses.consumed_refs) in
        let balanced_body = drop_after_body post_drops v ty body in
        prepend_drops pre_drops v ty balanced_body

and balance_nested_branch_body (env : type_env) (v : var) (ty : Ast.type_expr)
    ~(available_refs : int) (body : core) : core option =
  match body.desc with
  | CSeq (head, tail) ->
      let head_uses = summarize_linear_ownership_uses env v.vname head in
      let available_after_head =
        max 0 (available_refs - head_uses.consumed_refs)
      in
      Option.map
        (fun tail' -> { body with desc = CSeq (head, tail') })
        (balance_nested_branch_body env v ty
           ~available_refs:available_after_head tail)
  | CLet (b, inner) when b.bind_var.vname <> v.vname ->
      let rhs_uses = summarize_linear_ownership_uses env v.vname b.bind_rhs in
      let available_after_rhs =
        max 0 (available_refs - rhs_uses.consumed_refs)
      in
      Option.map
        (fun inner' -> { body with desc = CLet (b, inner') })
        (balance_nested_branch_body env v ty ~available_refs:available_after_rhs
           inner)
  | CBorrowLet (b, inner) when b.borrow_var.vname <> v.vname ->
      let rhs_uses = summarize_linear_ownership_uses env v.vname b.borrow_rhs in
      let available_after_rhs =
        max 0 (available_refs - rhs_uses.consumed_refs)
      in
      Option.map
        (fun inner' -> { body with desc = CBorrowLet (b, inner') })
        (balance_nested_branch_body env v ty ~available_refs:available_after_rhs
           inner)
  | CIf (cond, then_e, else_e) ->
      let cond_uses = summarize_linear_ownership_uses env v.vname cond in
      let then_uses = summarize_linear_ownership_uses env v.vname then_e in
      let else_uses = summarize_linear_ownership_uses env v.vname else_e in
      let available_after_cond =
        max 0 (available_refs - cond_uses.consumed_refs)
      in
      Some
        {
          body with
          desc =
            CIf
              ( cond,
                balance_branch_body env v ty
                  ~available_refs:available_after_cond then_uses then_e,
                balance_branch_body env v ty
                  ~available_refs:available_after_cond else_uses else_e );
        }
  | CMatchArms (scrut, arms) ->
      let arms = freshen_match_arm_shadows v arms in
      let scrut_uses = summarize_linear_ownership_uses env v.vname scrut in
      let scrut_aliases_owner = borrow_expr_aliases_target env v.vname scrut in
      let arm_uses =
        List.map
          (fun (pat, arm_body) ->
            if pattern_binds v.vname pat then no_ownership_uses
            else summarize_linear_ownership_uses env v.vname arm_body)
          arms
      in
      let arm_uses_for_balance =
        if scrut_aliases_owner then
          List.map (seq_ownership_uses borrow_ownership_use) arm_uses
        else arm_uses
      in
      let available_after_scrut =
        max 0 (available_refs - scrut_uses.consumed_refs)
      in
      let arms' =
        List.map2
          (fun (pat, arm_body) uses ->
            ( pat,
              balance_branch_body env v ty ~available_refs:available_after_scrut
                uses arm_body ))
          arms arm_uses_for_balance
      in
      Some { body with desc = CMatchArms (scrut, arms') }
  | CMatch (scrut, tree) ->
      let tree = freshen_ctree_shadow_bindings v tree in
      let scrut_uses = summarize_linear_ownership_uses env v.vname scrut in
      let scrut_aliases_owner = borrow_expr_aliases_target env v.vname scrut in
      let available_after_scrut =
        max 0 (available_refs - scrut_uses.consumed_refs)
      in
      let rec balance_tree tree =
        match tree with
        | CTLeaf { ct_bindings; ct_body } ->
            let uses =
              if List.exists (fun (bv, _) -> bv.vname = v.vname) ct_bindings
              then no_ownership_uses
              else summarize_linear_ownership_uses env v.vname ct_body
            in
            let uses =
              if scrut_aliases_owner then
                seq_ownership_uses borrow_ownership_use uses
              else uses
            in
            CTLeaf
              {
                ct_bindings;
                ct_body =
                  balance_branch_body env v ty
                    ~available_refs:available_after_scrut uses ct_body;
              }
        | CTFail -> CTFail
        | CTSwitchTag { cts_scrut; cts_cases; cts_default } ->
            CTSwitchTag
              {
                cts_scrut;
                cts_cases =
                  List.map (fun (n, sub) -> (n, balance_tree sub)) cts_cases;
                cts_default = Option.map balance_tree cts_default;
              }
        | CTSwitchLit { ctl_scrut; ctl_cases; ctl_default } ->
            CTSwitchLit
              {
                ctl_scrut;
                ctl_cases =
                  List.map (fun (lit, sub) -> (lit, balance_tree sub)) ctl_cases;
                ctl_default = balance_tree ctl_default;
              }
        | CTSwitchLen
            { ctl_len_scrut; ctl_len_cases; ctl_len_geq; ctl_len_default } ->
            CTSwitchLen
              {
                ctl_len_scrut;
                ctl_len_cases =
                  List.map (fun (n, sub) -> (n, balance_tree sub)) ctl_len_cases;
                ctl_len_geq =
                  Option.map (fun (n, sub) -> (n, balance_tree sub)) ctl_len_geq;
                ctl_len_default = Option.map balance_tree ctl_len_default;
              }
      in
      let tree' = balance_tree tree in
      Some { body with desc = CMatch (scrut, tree') }
  | _ -> None

(** Transform a [CLet] whose body is [CIf]. Branch-aware version:

    The condition runs first, then exactly one branch. We summarize the
    condition and each branch with ownership contracts, dup before the [CIf] to
    satisfy the max path requirement, then balance each branch independently. *)
let transform_let_if_body (env : type_env) (b : binding) (c : core) (t : core)
    (el : core) (if_node : core) (outer : core) : core =
  let v = b.bind_var in
  let cond_uses = summarize_linear_ownership_uses env v.vname c in
  let t_uses = summarize_linear_ownership_uses env v.vname t in
  let e_uses = summarize_linear_ownership_uses env v.vname el in
  let max_branch_required = max_required_refs [ t_uses; e_uses ] in
  let total_needed =
    max cond_uses.required_refs (cond_uses.consumed_refs + max_branch_required)
  in
  let ty = b.bind_ty in
  if total_needed = 0 then
    let dropped = { if_node with desc = CDrop (v, ty, if_node) } in
    { outer with desc = CLet (b, dropped) }
  else
    let dups_count = max 0 (total_needed - 1) in
    let available_after_cond = 1 + dups_count - cond_uses.consumed_refs in
    let t' =
      balance_branch_body env v ty ~available_refs:available_after_cond t_uses t
    in
    let el' =
      balance_branch_body env v ty ~available_refs:available_after_cond e_uses
        el
    in
    let new_if = { if_node with desc = CIf (c, t', el') } in
    let body = prepend_dups dups_count v ty new_if in
    { outer with desc = CLet (b, body) }

(** Transform a [CLet] whose body is [CMatchArms]. Same algorithm as
    [transform_let_if_body] but generalized to N arms. *)
let transform_let_match_body (env : type_env) (b : binding) (scrut : core)
    (arms : (Ast.pattern * core) list) (match_node : core) (outer : core) : core
    =
  let v = b.bind_var in
  let arms = freshen_match_arm_shadows v arms in
  let match_node = { match_node with desc = CMatchArms (scrut, arms) } in
  let scrut_uses = summarize_linear_ownership_uses env v.vname scrut in
  let scrut_aliases_owner = borrow_expr_aliases_target env v.vname scrut in
  let arm_uses =
    List.map
      (fun (pat, body) ->
        if pattern_binds v.vname pat then no_ownership_uses
        else summarize_linear_ownership_uses env v.vname body)
      arms
  in
  let arm_uses_for_balance =
    if scrut_aliases_owner then
      List.map (seq_ownership_uses borrow_ownership_use) arm_uses
    else arm_uses
  in
  if
    scrut_aliases_owner
    && List.for_all
         (fun uses -> uses.consumed_refs = 0 && not uses.returns_alias)
         arm_uses
  then { outer with desc = CLet (b, drop_after_body 1 v b.bind_ty match_node) }
  else
    let max_arm_required =
      max (if scrut_aliases_owner then 1 else 0) (max_required_refs arm_uses)
    in
    let total_needed =
      max scrut_uses.required_refs (scrut_uses.consumed_refs + max_arm_required)
    in
    let ty = b.bind_ty in
    if total_needed = 0 then
      let dropped = { match_node with desc = CDrop (v, ty, match_node) } in
      { outer with desc = CLet (b, dropped) }
    else
      let dups_count = max 0 (total_needed - 1) in
      let available_after_scrut = 1 + dups_count - scrut_uses.consumed_refs in
      let new_arms =
        List.map2
          (fun (pat, body) uses ->
            ( pat,
              balance_branch_body env v ty ~available_refs:available_after_scrut
                uses body ))
          arms arm_uses_for_balance
      in
      let new_match = { match_node with desc = CMatchArms (scrut, new_arms) } in
      let body = prepend_dups dups_count v ty new_match in
      { outer with desc = CLet (b, body) }

(** Summarize leaf ownership requirements across a compiled decision tree. *)
let rec collect_ctree_leaf_uses (env : type_env) (v : var) (tree : ctree) :
    ownership_uses list =
  match tree with
  | CTLeaf { ct_bindings; ct_body } ->
      if List.exists (fun (bv, _) -> bv.vname = v.vname) ct_bindings then
        [ no_ownership_uses ]
      else [ summarize_linear_ownership_uses env v.vname ct_body ]
  | CTFail -> [ no_ownership_uses ]
  | CTSwitchTag { cts_cases; cts_default; _ } ->
      let case_uses =
        List.concat_map
          (fun (_, sub) -> collect_ctree_leaf_uses env v sub)
          cts_cases
      in
      let default_uses =
        match cts_default with
        | Some d -> collect_ctree_leaf_uses env v d
        | None -> [ no_ownership_uses ]
      in
      case_uses @ default_uses
  | CTSwitchLit { ctl_cases; ctl_default; _ } ->
      List.concat_map
        (fun (_, sub) -> collect_ctree_leaf_uses env v sub)
        ctl_cases
      @ collect_ctree_leaf_uses env v ctl_default
  | CTSwitchLen { ctl_len_cases; ctl_len_geq; ctl_len_default; _ } ->
      let case_uses =
        List.concat_map
          (fun (_, sub) -> collect_ctree_leaf_uses env v sub)
          ctl_len_cases
      in
      let geq_uses =
        match ctl_len_geq with
        | Some (_, sub) -> collect_ctree_leaf_uses env v sub
        | None -> [ no_ownership_uses ]
      in
      let default_uses =
        match ctl_len_default with
        | Some d -> collect_ctree_leaf_uses env v d
        | None -> [ no_ownership_uses ]
      in
      case_uses @ geq_uses @ default_uses

(** Balance every decision-tree leaf using ownership summaries. *)
let rec balance_ctree_leaves (env : type_env) (v : var) (ty : Ast.type_expr)
    ~(available_refs : int) ~(scrut_aliases_owner : bool) (tree : ctree) : ctree
    =
  match tree with
  | CTLeaf { ct_bindings; ct_body } ->
      let uses =
        if List.exists (fun (bv, _) -> bv.vname = v.vname) ct_bindings then
          no_ownership_uses
        else summarize_linear_ownership_uses env v.vname ct_body
      in
      let uses =
        if scrut_aliases_owner then seq_ownership_uses borrow_ownership_use uses
        else uses
      in
      CTLeaf
        {
          ct_bindings;
          ct_body = balance_branch_body env v ty ~available_refs uses ct_body;
        }
  | CTFail -> CTFail
  | CTSwitchTag { cts_scrut; cts_cases; cts_default } ->
      CTSwitchTag
        {
          cts_scrut;
          cts_cases =
            List.map
              (fun (n, sub) ->
                ( n,
                  balance_ctree_leaves env v ty ~available_refs
                    ~scrut_aliases_owner sub ))
              cts_cases;
          cts_default =
            Option.map
              (balance_ctree_leaves env v ty ~available_refs
                 ~scrut_aliases_owner)
              cts_default;
        }
  | CTSwitchLit { ctl_scrut; ctl_cases; ctl_default } ->
      CTSwitchLit
        {
          ctl_scrut;
          ctl_cases =
            List.map
              (fun (l, sub) ->
                ( l,
                  balance_ctree_leaves env v ty ~available_refs
                    ~scrut_aliases_owner sub ))
              ctl_cases;
          ctl_default =
            balance_ctree_leaves env v ty ~available_refs ~scrut_aliases_owner
              ctl_default;
        }
  | CTSwitchLen { ctl_len_scrut; ctl_len_cases; ctl_len_geq; ctl_len_default }
    ->
      CTSwitchLen
        {
          ctl_len_scrut;
          ctl_len_cases =
            List.map
              (fun (n, sub) ->
                ( n,
                  balance_ctree_leaves env v ty ~available_refs
                    ~scrut_aliases_owner sub ))
              ctl_len_cases;
          ctl_len_geq =
            Option.map
              (fun (n, sub) ->
                ( n,
                  balance_ctree_leaves env v ty ~available_refs
                    ~scrut_aliases_owner sub ))
              ctl_len_geq;
          ctl_len_default =
            Option.map
              (balance_ctree_leaves env v ty ~available_refs
                 ~scrut_aliases_owner)
              ctl_len_default;
        }

let consuming_user_call_kind = function
  | CKUser _ | CKClosure -> true
  | CKUnknown | CKSelectedDirect _ | CKForeign _ | CKBuiltin _ | CKIntrinsic _
    ->
      false

let consumes_var_once_linearly (env : type_env) (v : var) (e : core) : bool =
  if not (is_linear e) then false
  else
    let uses = summarize_linear_ownership_uses env v.vname e in
    uses.consumed_refs = 1 && uses.required_refs = 1 && (not uses.returns_alias)
    && expr_consumes_var_owner env v.vname e

(** Protect consuming calls by retaining [v] first when the caller must keep
    its local owner alive. [allow_final_consume] preserves true tail moves, but
    mutable owners disable it because assignment temporaries can look final
    while the mutable slot still receives a scope-exit drop. *)
let rec protect_consuming_calls_for_var ?(user_calls_only = false)
    ?(repeated_context = false) ?(allow_final_consume = true) (env : type_env)
    (v : var) (ty : Ast.type_expr) (e : core) : core =
  let recur =
    protect_consuming_calls_for_var ~user_calls_only ~repeated_context
      ~allow_final_consume env v ty
  in
  match e.desc with
  | CCall (kind, fn, args) ->
      let fn' = recur fn in
      let args' = List.map recur args in
      let call = { e with desc = CCall (kind, fn', args') } in
      if user_calls_only && not (consuming_user_call_kind kind) then call
      else
        let uses = summarize_linear_call env v.vname call.ty kind fn' args' in
        prepend_dups uses.consumed_refs v ty call
  | CDup (dup_v, _, _) when dup_v.vname = v.vname -> e
  | CLet (b, body) ->
      let body_uses =
        if b.bind_var.vname = v.vname then no_ownership_uses
        else summarize_linear_ownership_uses env v.vname body
      in
      let rhs_is_final_consume =
        allow_final_consume && (not repeated_context) && (not body_uses.touched)
        && consumes_var_once_linearly env v b.bind_rhs
      in
      let rhs' =
        if rhs_is_final_consume then b.bind_rhs else recur b.bind_rhs
      in
      let body' = if b.bind_var.vname = v.vname then body else recur body in
      { e with desc = CLet ({ b with bind_rhs = rhs' }, body') }
  | CBorrowLet (b, body) ->
      let body_uses =
        if b.borrow_var.vname = v.vname then no_ownership_uses
        else summarize_linear_ownership_uses env v.vname body
      in
      let rhs_is_final_consume =
        allow_final_consume && (not repeated_context) && (not body_uses.touched)
        && consumes_var_once_linearly env v b.borrow_rhs
      in
      let rhs' =
        if rhs_is_final_consume then b.borrow_rhs else recur b.borrow_rhs
      in
      let body' = if b.borrow_var.vname = v.vname then body else recur body in
      { e with desc = CBorrowLet ({ b with borrow_rhs = rhs' }, body') }
  | CAssign (target, _) when target.vname = v.vname -> e
  | CAssign (target, rhs) -> { e with desc = CAssign (target, recur rhs) }
  | CWhile (cond, body) ->
      {
        e with
        desc =
          CWhile
            ( recur cond,
              protect_consuming_calls_for_var ~user_calls_only
                ~repeated_context:true ~allow_final_consume env v ty body );
      }
  | CFor (binder, iter, body) ->
      let iter' = recur iter in
      let body' =
        if binder.loop_var.vname = v.vname then body
        else
          protect_consuming_calls_for_var ~user_calls_only
            ~repeated_context:true ~allow_final_consume env v ty body
      in
      { e with desc = CFor (binder, iter', body') }
  | CMatchArms (scrut, arms) ->
      let scrut' = recur scrut in
      let arms' =
        List.map
          (fun (pat, body) ->
            if pattern_binds v.vname pat then (pat, body) else (pat, recur body))
          arms
      in
      { e with desc = CMatchArms (scrut', arms') }
  | CMatch (scrut, tree) ->
      {
        e with
        desc =
          CMatch
            ( recur scrut,
              protect_consuming_calls_in_ctree ~user_calls_only
                ~repeated_context ~allow_final_consume env v ty tree );
      }
  | _ -> map_children recur e

and protect_consuming_calls_in_ctree ?(user_calls_only = false)
    ?(repeated_context = false) ?(allow_final_consume = true) (env : type_env)
    (v : var) (ty : Ast.type_expr) (tree : ctree) : ctree =
  match tree with
  | CTLeaf { ct_bindings; ct_body } ->
      if List.exists (fun (bv, _) -> bv.vname = v.vname) ct_bindings then tree
      else
        CTLeaf
          {
            ct_bindings;
            ct_body =
              protect_consuming_calls_for_var ~user_calls_only ~repeated_context
                ~allow_final_consume env v ty ct_body;
          }
  | CTFail -> CTFail
  | CTSwitchTag { cts_scrut; cts_cases; cts_default } ->
      CTSwitchTag
        {
          cts_scrut;
          cts_cases =
            List.map
              (fun (n, sub) ->
                ( n,
                  protect_consuming_calls_in_ctree ~user_calls_only
                    ~repeated_context ~allow_final_consume env v ty sub ))
              cts_cases;
          cts_default =
            Option.map
              (protect_consuming_calls_in_ctree ~user_calls_only
                 ~repeated_context ~allow_final_consume env v ty)
              cts_default;
        }
  | CTSwitchLit { ctl_scrut; ctl_cases; ctl_default } ->
      CTSwitchLit
        {
          ctl_scrut;
          ctl_cases =
            List.map
              (fun (lit, sub) ->
                ( lit,
                  protect_consuming_calls_in_ctree ~user_calls_only
                    ~repeated_context ~allow_final_consume env v ty sub ))
              ctl_cases;
          ctl_default =
            protect_consuming_calls_in_ctree ~user_calls_only ~repeated_context
              ~allow_final_consume env v ty ctl_default;
        }
  | CTSwitchLen { ctl_len_scrut; ctl_len_cases; ctl_len_geq; ctl_len_default }
    ->
      CTSwitchLen
        {
          ctl_len_scrut;
          ctl_len_cases =
            List.map
              (fun (n, sub) ->
                ( n,
                  protect_consuming_calls_in_ctree ~user_calls_only
                    ~repeated_context ~allow_final_consume env v ty sub ))
              ctl_len_cases;
          ctl_len_geq =
            Option.map
              (fun (n, sub) ->
                ( n,
                  protect_consuming_calls_in_ctree ~user_calls_only
                    ~repeated_context ~allow_final_consume env v ty sub ))
              ctl_len_geq;
          ctl_len_default =
            Option.map
              (protect_consuming_calls_in_ctree ~user_calls_only
                 ~repeated_context ~allow_final_consume env v ty)
              ctl_len_default;
        }

let rec protect_loop_consumes_for_var (env : type_env) (v : var)
    (ty : Ast.type_expr) (e : core) : core =
  let recur = protect_loop_consumes_for_var env v ty in
  match e.desc with
  | CWhile (cond, body) ->
      {
        e with
        desc =
          CWhile
            ( protect_consuming_calls_for_var env v ty cond,
              protect_consuming_calls_for_var ~repeated_context:true env v ty
                body );
      }
  | CFor (binder, iter, body) ->
      let iter' = protect_consuming_calls_for_var env v ty iter in
      let body' =
        if binder.loop_var.vname = v.vname then body
        else
          protect_consuming_calls_for_var ~repeated_context:true env v ty body
      in
      { e with desc = CFor (binder, iter', body') }
  | CLet (b, body) ->
      let rhs' = recur b.bind_rhs in
      let body' = if b.bind_var.vname = v.vname then body else recur body in
      { e with desc = CLet ({ b with bind_rhs = rhs' }, body') }
  | CBorrowLet (b, body) ->
      let rhs' = recur b.borrow_rhs in
      let body' = if b.borrow_var.vname = v.vname then body else recur body in
      { e with desc = CBorrowLet ({ b with borrow_rhs = rhs' }, body') }
  | CMatchArms (scrut, arms) ->
      let scrut' = recur scrut in
      let arms' =
        List.map
          (fun (pat, body) ->
            if pattern_binds v.vname pat then (pat, body) else (pat, recur body))
          arms
      in
      { e with desc = CMatchArms (scrut', arms') }
  | CMatch (scrut, tree) ->
      {
        e with
        desc = CMatch (recur scrut, protect_loop_consumes_in_ctree env v ty tree);
      }
  | _ -> map_children recur e

and protect_loop_consumes_in_ctree (env : type_env) (v : var)
    (ty : Ast.type_expr) (tree : ctree) : ctree =
  match tree with
  | CTLeaf { ct_bindings; ct_body } ->
      if List.exists (fun (bv, _) -> bv.vname = v.vname) ct_bindings then tree
      else
        CTLeaf
          {
            ct_bindings;
            ct_body = protect_loop_consumes_for_var env v ty ct_body;
          }
  | CTFail -> CTFail
  | CTSwitchTag { cts_scrut; cts_cases; cts_default } ->
      CTSwitchTag
        {
          cts_scrut;
          cts_cases =
            List.map
              (fun (n, sub) -> (n, protect_loop_consumes_in_ctree env v ty sub))
              cts_cases;
          cts_default =
            Option.map (protect_loop_consumes_in_ctree env v ty) cts_default;
        }
  | CTSwitchLit { ctl_scrut; ctl_cases; ctl_default } ->
      CTSwitchLit
        {
          ctl_scrut;
          ctl_cases =
            List.map
              (fun (lit, sub) ->
                (lit, protect_loop_consumes_in_ctree env v ty sub))
              ctl_cases;
          ctl_default = protect_loop_consumes_in_ctree env v ty ctl_default;
        }
  | CTSwitchLen { ctl_len_scrut; ctl_len_cases; ctl_len_geq; ctl_len_default }
    ->
      CTSwitchLen
        {
          ctl_len_scrut;
          ctl_len_cases =
            List.map
              (fun (n, sub) -> (n, protect_loop_consumes_in_ctree env v ty sub))
              ctl_len_cases;
          ctl_len_geq =
            Option.map
              (fun (n, sub) -> (n, protect_loop_consumes_in_ctree env v ty sub))
              ctl_len_geq;
          ctl_len_default =
            Option.map (protect_loop_consumes_in_ctree env v ty) ctl_len_default;
        }

(** Transform a [CLet] whose body is [CMatch] (compiled tree). Walks every leaf
    of the compiled decision tree with branch ownership summaries and balances
    each mutually-exclusive leaf independently. *)
let transform_let_match_tree_body (env : type_env) (b : binding) (scrut : core)
    (tree : ctree) (mt_node : core) (outer : core) : core =
  let v = b.bind_var in
  let tree = freshen_ctree_shadow_bindings v tree in
  let mt_node = { mt_node with desc = CMatch (scrut, tree) } in
  let scrut_uses = summarize_linear_ownership_uses env v.vname scrut in
  let scrut_aliases_owner = borrow_expr_aliases_target env v.vname scrut in
  let leaf_uses = collect_ctree_leaf_uses env v tree in
  if
    scrut_aliases_owner
    && List.for_all
         (fun uses -> uses.consumed_refs = 0 && not uses.returns_alias)
         leaf_uses
  then { outer with desc = CLet (b, drop_after_body 1 v b.bind_ty mt_node) }
  else
    let max_leaf_required =
      max (if scrut_aliases_owner then 1 else 0) (max_required_refs leaf_uses)
    in
    let total_needed =
      max scrut_uses.required_refs (scrut_uses.consumed_refs + max_leaf_required)
    in
    let ty = b.bind_ty in
    if total_needed = 0 then
      let dropped = { mt_node with desc = CDrop (v, ty, mt_node) } in
      { outer with desc = CLet (b, dropped) }
    else
      let dups_count = max 0 (total_needed - 1) in
      let available_after_scrut = 1 + dups_count - scrut_uses.consumed_refs in
      let new_tree =
        balance_ctree_leaves env v ty ~available_refs:available_after_scrut
          ~scrut_aliases_owner tree
      in
      let new_mt = { mt_node with desc = CMatch (scrut, new_tree) } in
      let body = prepend_dups dups_count v ty new_mt in
      { outer with desc = CLet (b, body) }

(** Transform a [CConcurrent] node by inserting [CDup]/[CDrop] for each
    managed concurrent binding. Analogous to [transform_let] but applied
    N times — one per binding in [cb.conc_bindings] — since all bindings
    share the same tail [cb.conc_body].

    For each managed binding [b]:
    - [count = 0] → prepend a [CDrop] (binding is unused; release now).
    - [count = 1] → wrap the tail so it's evaluated to a temporary, then
      release [b], then return the temporary. Necessary because the single
      use doesn't actually consume the refcount in the current emit layer
      (CMatch scrutinees alias rather than own), and we can't place a
      post-use drop without forcing evaluation order.
    - [count ≥ 2] → prepend [N−1] dups AND wrap with the post-evaluation
      drop described above. Net effect: refcount rises to [N] at entry,
      each use consumes one, final drop consumes the last at end-of-body.

    Non-managed bindings (primitives, Int, etc.) pass through untouched. *)
let transform_concurrent (env : type_env) (e : core) : core =
  match e.desc with
  | CConcurrent cb ->
      let wrap_binding (tail : core) (b : conc_binding) : core =
        if not (is_managed_type env b.cb_ty) then tail
        else
          let count = count_uses b.cb_var.vname tail in
          if count = 0 then { tail with desc = CDrop (b.cb_var, b.cb_ty, tail) }
          else
            let dup_prefix = prepend_dups (count - 1) b.cb_var b.cb_ty in
            let body_with_dups = dup_prefix tail in
            if is_void_type tail.ty then
              (* Void-typed tail: no value to preserve. Sequence the
                 tail, then drop the binding. *)
              let void_node = { desc = CVoid; ty = tail.ty; loc = tail.loc } in
              let drop =
                {
                  desc = CDrop (b.cb_var, b.cb_ty, void_node);
                  ty = tail.ty;
                  loc = tail.loc;
                }
              in
              { tail with desc = CSeq (body_with_dups, drop) }
            else
              (* Value-returning tail: bind to a temp, drop, return the temp.
                 [CLet] + [CDrop] sequence: evaluate tail into [__cdrop_X],
                 then drop [b], then read back [__cdrop_X]. *)
              let tmp_name = Printf.sprintf "__cdrop_%s" b.cb_var.vname in
              let tmp_var = Core.Var.named tmp_name in
              let tmp_ty = tail.ty in
              let tmp_ref =
                { desc = CVar tmp_var; ty = tmp_ty; loc = tail.loc }
              in
              let drop_then_ret =
                {
                  desc = CDrop (b.cb_var, b.cb_ty, tmp_ref);
                  ty = tmp_ty;
                  loc = tail.loc;
                }
              in
              let bind =
                {
                  bind_var = tmp_var;
                  bind_mut = false;
                  bind_ty = tmp_ty;
                  bind_rhs = body_with_dups;
                }
              in
              { tail with desc = CLet (bind, drop_then_ret) }
      in
      let new_body =
        List.fold_left wrap_binding cb.conc_body cb.conc_bindings
      in
      { e with desc = CConcurrent { cb with conc_body = new_body } }
  | _ -> e

(** Transform a single [CLet] node for Perceus-lite refcount balance.

    {1 Linear body case}

    For a managed binding [b] with a linear body (no branches):
    - [count = 0] → wrap body in [CDrop(v, body)].
    - [count = 1] → unchanged (single use consumes).
    - [count ≥ 2] → prepend [N−1] nested [CDup] nodes.

    {1 Branching body case ([CIf])}

    Handled by [transform_let_if_body] — per-branch use counts
    determine excess drops on the shorter branch, plus dups before
    the condition to reach the max-branch refcount.

    {1 Other branching forms}

    [CMatchArms] and [CMatch] have dedicated transforms. Borrowed-only
    non-linear forms such as [CFor] and [CWhile] use the summary fallback
    below; consuming loop bodies and concurrency nodes remain conservative. *)
let transform_let (env : type_env) (e : core) : core =
  match e.desc with
  | CLet (b, body) ->
      let transformed =
        if not (is_managed_type env b.bind_ty) then e
        else if b.bind_mut then
          let target_starts_as_alias =
            is_managed_type env b.bind_ty
            && assignment_rhs_is_alias env b.bind_rhs
          in
          let body =
            release_reassigned_mutable_var env ~target_starts_as_alias
              b.bind_var b.bind_ty body
          in
          let body =
            protect_consuming_calls_for_var ~user_calls_only:true
              ~allow_final_consume:false env b.bind_var b.bind_ty body
          in
          let uses =
            summarize_linear_ownership_uses env b.bind_var.vname body
          in
          let returns_current_owner =
            expr_tail_aliases_var b.bind_var.vname body
          in
          let final_owner_consumed =
            expr_final_consumes_var_owner env b.bind_var.vname body
          in
          let body =
            if
              returns_current_owner || uses.returns_alias
              || final_owner_consumed
            then body
            else drop_after_body 1 b.bind_var b.bind_ty body
          in
          { e with desc = CLet (b, body) }
        else
          let body =
            protect_loop_consumes_for_var env b.bind_var b.bind_ty body
          in
          let e = { e with desc = CLet (b, body) } in
          match body.desc with
          | CIf (c, t, el) -> transform_let_if_body env b c t el body e
          | CMatchArms (scrut, arms) ->
              transform_let_match_body env b scrut arms body e
          | CMatch (scrut, tree) ->
              transform_let_match_tree_body env b scrut tree body e
          | _ when is_linear body ->
              let ty = b.bind_ty in
              let uses =
                summarize_linear_ownership_uses env b.bind_var.vname body
              in
              if not uses.touched then
                let dropped =
                  { body with desc = CDrop (b.bind_var, ty, body) }
                in
                { e with desc = CLet (b, dropped) }
              else
                let dups_count = max 0 (uses.required_refs - 1) in
                let owned_refs = 1 + dups_count in
                let post_drops =
                  if uses.returns_alias then 0
                  else max 0 (owned_refs - uses.consumed_refs)
                in
                let body_with_dups =
                  prepend_dups dups_count b.bind_var ty body
                in
                let balanced_body =
                  drop_after_body post_drops b.bind_var ty body_with_dups
                in
                { e with desc = CLet (b, balanced_body) }
          | _ ->
              let ty = b.bind_ty in
              let uses =
                summarize_linear_ownership_uses env b.bind_var.vname body
              in
              if not uses.touched then
                let dropped =
                  { body with desc = CDrop (b.bind_var, ty, body) }
                in
                { e with desc = CLet (b, dropped) }
              else if uses.consumed_refs = 0 && not uses.returns_alias then
                { e with desc = CLet (b, drop_after_body 1 b.bind_var ty body) }
              else
                let protected =
                  protect_consuming_calls_for_var env b.bind_var ty body
                in
                let protected_uses =
                  summarize_linear_ownership_uses env b.bind_var.vname protected
                in
                let dups_count = max 0 (protected_uses.required_refs - 1) in
                let owned_refs = 1 + dups_count in
                let post_drops =
                  if protected_uses.returns_alias then 0
                  else max 0 (owned_refs - protected_uses.consumed_refs)
                in
                let protected_with_dups =
                  prepend_dups dups_count b.bind_var ty protected
                in
                {
                  e with
                  desc =
                    CLet
                      ( b,
                        drop_after_body post_drops b.bind_var ty
                          protected_with_dups );
                }
      in
      transformed
  | _ -> e

let balance_consumed_param_body (env : type_env) (p : core_param) (body : core)
    : core =
  let void_rhs = { desc = CVoid; ty = p.cp_ty; loc = body.loc } in
  let fake_binding =
    {
      bind_var = p.cp_name;
      bind_mut = false;
      bind_ty = p.cp_ty;
      bind_rhs = void_rhs;
    }
  in
  let wrapped = { body with desc = CLet (fake_binding, body) } in
  match transform_let env wrapped with
  | { desc = CLet (_, balanced_body); _ } -> balanced_body
  | balanced -> balanced

let balance_consumed_params_body (env : type_env) (f : core_func) (body : core)
    : core =
  match
    lookup_user_call_contract env f.cf_name (Some f.cf_def_id)
      (List.length f.cf_params)
  with
  | None -> body
  | Some contract ->
      List.fold_right2
        (fun (p : core_param) mode acc ->
          if
            is_managed_type env p.cp_ty
            && Core_ownership.arg_consumes_caller mode
          then balance_consumed_param_body env p acc
          else acc)
        f.cf_params contract.Core_ownership.args body

let retain_alias_sources_expr (env : type_env) (e : core) : core =
  let rewrite node =
    match node.desc with
    | CLet (b, body) when is_managed_type env b.bind_ty ->
        { node with desc = CLet (b, retain_alias_source env b body) }
    | _ -> node
  in
  transform_bottom_up rewrite e

(** Walk an expression and insert RC ops, using [env] for managed-type
    lookup. Uses [transform_bottom_up] so nested lets are processed
    inside-out — each inner let is transformed before its surrounding
    let sees it. Runs two transforms:
    1. [transform_let]: immutable binding dup/drop (Phase 2.1 original).

    [Core_ssa] has already converted no-assignment and straight-line
    mutable locals into immutable lets. Mutable bindings that survive
    here contain control-flow reassignment; [transform_let] deliberately
    skips them because their ownership cannot be balanced with the
    immutable-binding rules.

    Additionally, record construction must retain managed fields
    (value semantics: every store is a logical copy). See
    [arc_memory_management.md] for the full plan. *)
let insert_drops_expr_with_env (env : type_env) (e : core) : core =
  let combined node =
    node |> transform_let env |> transform_concurrent env
    |> retain_borrowed_aggregate_members_in_matches env
    |> retain_borrowed_owned_call_args_in_matches env
    |> retain_borrowed_result_vars_in_matches env
    |> retain_assignment_alias_rhs env
  in
  e
  |> normalize_lambda_result_aliases env
  |> protect_consuming_field_args env
  |> bind_borrowed_owned_temporary_args env
  |> transform_bottom_up combined
  |> retain_alias_sources_expr env

(* ============================================================================
   Program-level walker
   ============================================================================ *)

let consumed_param_names_for_contract (env : type_env) (f : core_func) :
    string list =
  match
    lookup_user_call_contract env f.cf_name (Some f.cf_def_id)
      (List.length f.cf_params)
  with
  | Some { Core_ownership.args; _ }
    when List.length args = List.length f.cf_params ->
      List.fold_right2
        (fun (p : core_param) mode acc ->
          if Core_ownership.arg_consumes_caller mode then p.cp_name.vname :: acc
          else acc)
        f.cf_params args []
  | _ -> []

let insert_drops_func (env : type_env) (f : core_func) : core_func =
  let env = with_type_params env f.cf_type_params in
  match f.cf_body with
  | None -> f
  | Some body ->
      let all_param_names =
        List.map (fun (p : core_param) -> p.cp_name.vname) f.cf_params
      in
      let consumed_param_names = consumed_param_names_for_contract env f in
      let body =
        retain_borrowed_aggregate_members_in_expr env all_param_names body
      in
      let body =
        retain_borrowed_owned_call_args_in_expr env
          ~consumed_params:consumed_param_names all_param_names body
      in
      let body =
        if is_managed_type env f.cf_return_ty then
          body
          |> retain_borrowed_result_vars_in_expr env all_param_names
          |> normalize_owned_result_aliases env
        else body
      in
      let body = insert_drops_expr_with_env env body in
      let body = balance_consumed_params_body env f body in
      { f with cf_body = Some body }

let insert_drops_var (env : type_env) (v : core_var) : core_var =
  { v with cv_init = insert_drops_expr_with_env env v.cv_init }

let insert_drops_impl (env : type_env) (i : core_impl) : core_impl =
  { i with ci_methods = List.map (insert_drops_func env) i.ci_methods }

let rec insert_drops_decl (env : type_env) (d : core_decl) : core_decl =
  let desc' =
    match d.cd_desc with
    | CDFunc f -> CDFunc (insert_drops_func env f)
    | CDVar v -> CDVar (insert_drops_var env v)
    | CDImpl i -> CDImpl (insert_drops_impl env i)
    | CDTrait _ as other -> other (* no expressions; defaults live on AST *)
    | CDPrivate inner -> CDPrivate (insert_drops_decl env inner)
    | (CDType _ | CDRecord _ | CDImport _ | CDTypeAlias _) as other -> other
  in
  { d with cd_desc = desc' }

(** Walk a program, inserting drops for unused managed bindings in
    every function body, global initializer, impl method, and trait
    default body. Builds a [type_env] from the program's declarations
    so user records and non-enum unions are recognized as managed. *)
let insert_drops_program (prog : core_program) : core_program =
  let env = build_type_env prog in
  populate_user_call_contracts env prog;
  List.map (insert_drops_decl env) prog
