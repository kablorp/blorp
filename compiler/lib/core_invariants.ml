(** Phase-boundary invariant checks for the Core IR.

    Each check walks a [core_program] post-stage and collects a list of
    [Core_error.t] violations. A check that returns [[]] is saying "this
    property holds for every node I visited"; a non-empty list means the
    previous stage produced output that breaks a downstream assumption.

    Checks do not raise — they accumulate. The dispatcher
    [run_for_stage] is what callers usually want; it picks the enabled
    checks for each stage and returns the combined violation list. The
    CLI / pipeline decide whether to raise, log, or ignore.

    {1 Enabled checks}

    [run_for_stage] wires in checks that are known to pass against
    today's pipeline output:

    - [check_no_ckunknown] — ENABLED (post-specialize and final)
    - [check_no_debug_blocks] — ENABLED (post-debug and final)
    - [check_no_tyvar_leak] — ENABLED (post-mono)
    - [check_no_sugar] — ENABLED (post-desugar, bookended at Perceus and Final)
    - [check_no_desugarable_mutation] — ENABLED (post-desugar)
    - [check_no_cmatcharms] — ENABLED (post-match, bookended at Perceus and Final)
    - [check_no_codegen_unprepared_forms] — ENABLED (Final)
    - [check_resource_scope_contracts_at] — ENABLED (Perceus and Final)
    - [check_resource_scope_nonlocal_exits_at] — ENABLED (Final)
    - [check_resource_cleanup_exits_at] — ENABLED (Final)
    - [check_void_boxed_builtin_args_explicit] — ENABLED (Final)
    - [check_no_raw_top_level_function_refs] — ENABLED (Final)
    - [check_no_resource_capture_metadata_at] — ENABLED (Closure and Final)
    - [check_concurrent_semantics_at] — ENABLED (Final)

    Add new checks only after verifying no false positives across [std/]
    and [tests/]. *)

module StringSet = Set.Make (String)
module StringMap = Map.Make (String)
module IntSet = Set.Make (Int)

(** Walk every expression in a [core_program]. Visits:
    - function bodies (including nested lambdas)
    - global variable initializers
    - impl method bodies
    - trait default method bodies *)
let fold_program (f : 'a -> Core.core -> 'a) (init : 'a)
    (prog : Core.core_program) : 'a =
  let rec visit_decl acc (d : Core.core_decl) =
    match d.cd_desc with
    | Core.CDFunc fn -> (
        match fn.cf_body with
        | Some body -> Core.fold_tree f acc body
        | None -> acc)
    | Core.CDVar v -> Core.fold_tree f acc v.cv_init
    | Core.CDImpl i ->
        List.fold_left
          (fun acc m ->
            match m.Core.cf_body with
            | Some body -> Core.fold_tree f acc body
            | None -> acc)
          acc i.ci_methods
    | Core.CDTrait _ -> acc (* no expressions; defaults live on AST *)
    | Core.CDPrivate inner -> visit_decl acc inner
    | Core.CDType _ | Core.CDRecord _ | Core.CDImport _ | Core.CDTypeAlias _ ->
        acc
  in
  List.fold_left visit_decl init prog

(** Build a [Core_error.t] with [Stage s] phase tag. *)
let violation_at (stage : Core_stage.t) (loc : Ast.loc) ?hint msg : Core_error.t
    =
  { phase = Core_error.Stage stage; msg; loc; hint }

(* ============================================================================
   Post-specialize: every [CCall] has a resolved [call_kind]
   ============================================================================ *)

(** After [Core_specialize], no unresolved [CCall] target may survive.
    [Core_resolve] is allowed to leave type-dispatched stdlib operations
    as [CKUnknown] because [Core_specialize] owns those rewrites. Selected
    direct calls and compiler-owned intrinsics such as bitwise operators and
    debug reflection must resolve earlier because typed metadata or the
    intrinsic registry already identifies the target. Past that boundary,
    either form is an unresolved call or a later pass fabricating calls without
    tagging them. *)
let check_no_ckunknown_at (stage : Core_stage.t) (prog : Core.core_program) :
    Core_error.t list =
  fold_program
    (fun acc e ->
      match e.Core.desc with
      | Core.CCall ((Core.CKUnknown | Core.CKSelectedDirect _), _, _) ->
          let v =
            violation_at stage e.loc
              ~hint:
                "Core_resolve may leave specialization-owned calls as \
                 CKUnknown, but Core_specialize must rewrite every one before \
                 later Core passes or emission. CKSelectedDirect must be \
                 resolved to CKUser before specialization."
              "CCall with unresolved call target reached post-specialize IR"
          in
          v :: acc
      | _ -> acc)
    [] prog
  |> List.rev

let check_no_ckunknown (prog : Core.core_program) : Core_error.t list =
  check_no_ckunknown_at Core_stage.Specialize prog

let check_no_layoutless_list_alloc_at (stage : Core_stage.t)
    (prog : Core.core_program) : Core_error.t list =
  fold_program
    (fun acc e ->
      match e.Core.desc with
      | Core.CCall
          ( (Core.CKIntrinsic "list_alloc" | Core.CKBuiltin "blorp_list_new"),
            _,
            _ ) ->
          let name =
            match e.Core.desc with
            | Core.CCall (Core.CKBuiltin "blorp_list_new", _, _) ->
                "blorp_list_new"
            | _ -> "list_alloc"
          in
          let v =
            violation_at stage e.loc
              ~hint:
                "Core_specialize/Core_codegen_prepare should rewrite list \
                 allocations into CListAlloc nodes, which carry an explicit \
                 list storage layout for codegen."
              (Printf.sprintf
                 "layout-free %s allocation reached post-specialize IR" name)
          in
          v :: acc
      | _ -> acc)
    [] prog
  |> List.rev

let check_no_codegen_unprepared_forms_at (stage : Core_stage.t)
    (prog : Core.core_program) : Core_error.t list =
  fold_program
    (fun acc e ->
      let name_opt =
        match e.Core.desc with
        | Core.CTuple _ -> Some "CTuple"
        | Core.CList _ -> Some "CList"
        | Core.CVector _ -> Some "CVector"
        | Core.CDict _ -> Some "CDict"
        | Core.CRecord _ -> Some "CRecord"
        | Core.CBox _ -> Some "CBox"
        | Core.CUnbox _ -> Some "CUnbox"
        | _ -> None
      in
      match name_opt with
      | Some n ->
          let v =
            violation_at stage e.loc
              ~hint:
                (Printf.sprintf
                   "Core_codegen_prepare should rewrite %s into an explicit \
                    final-Core constructor before emission. Do not recover \
                    this layout or boxing decision in the emitter."
                   n)
              (Printf.sprintf "codegen-unprepared node %s reached final Core" n)
          in
          v :: acc
      | None -> acc)
    [] prog
  |> List.rev

let proof_carrying_string_byte_intrinsics =
  StringSet.of_list
    [
      "string_get_byte";
      "string_set_byte";
      "string_copy_bytes";
      "string_set_len";
    ]

let check_no_raw_string_byte_intrinsics_at (stage : Core_stage.t)
    (prog : Core.core_program) : Core_error.t list =
  fold_program
    (fun acc e ->
      match e.Core.desc with
      | Core.CCall (Core.CKIntrinsic name, _, _)
        when StringSet.mem name proof_carrying_string_byte_intrinsics ->
          let v =
            violation_at stage e.loc
              ~hint:
                "Core_codegen_prepare should rewrite unchecked string byte \
                 intrinsics into proof-carrying Core nodes before final Core. \
                 Add an explicit \
                 CStringByteRead/CStringByteWrite/CStringByteCopy/CStringSetLen \
                 node instead of emitting a raw intrinsic."
              (Printf.sprintf
                 "unchecked string byte intrinsic `%s` reached final Core \
                  without a proof-carrying Core node"
                 name)
          in
          v :: acc
      | _ -> acc)
    [] prog
  |> List.rev

let missing_ownership_contract_violation (stage : Core_stage.t) (loc : Ast.loc)
    ~(kind_name : string) ~(call_name : string) ~(arg_count : int) =
  violation_at stage loc
    ~hint:
      (Printf.sprintf
         "Add an explicit Core_ownership contract for `%s`/%d, or rewrite the \
          call before Perceus if it is a pre-ownership sentinel."
         call_name arg_count)
    (Printf.sprintf
       "%s `%s` reached Perceus without an ownership contract for arity %d"
       kind_name call_name arg_count)

let pre_perceus_sentinel_violation (stage : Core_stage.t) (loc : Ast.loc)
    ~(call_name : string) ~(reason : string) =
  violation_at stage loc
    ~hint:
      (Printf.sprintf
         "`%s` is registered only as a pre-Perceus sentinel: %s. Rewrite it \
          before Perceus instead of relying on ownership fallback behavior."
         call_name reason)
    (Printf.sprintf
       "pre-Perceus builtin `%s` reached Perceus; it must be specialized \
        before Perceus"
       call_name)

let check_call_ownership_contracts_at (stage : Core_stage.t)
    (prog : Core.core_program) : Core_error.t list =
  fold_program
    (fun acc e ->
      match e.Core.desc with
      | Core.CCall ((Core.CKIntrinsic name as kind), _, args) ->
          let arg_count = List.length args in
          if
            Option.is_some
              (Core_ownership.contract_for_call_kind kind ~arg_count)
          then acc
          else
            missing_ownership_contract_violation stage e.loc
              ~kind_name:"intrinsic" ~call_name:name ~arg_count
            :: acc
      | Core.CCall ((Core.CKBuiltin name as kind), _, args) -> (
          let arg_count = List.length args in
          match Core_ownership.contract_for_call_kind kind ~arg_count with
          | Some _ -> acc
          | None -> (
              match Core_ownership.builtin_ownership_coverage name with
              | Some (Core_ownership.Pre_perceus_sentinel reason) ->
                  pre_perceus_sentinel_violation stage e.loc ~call_name:name
                    ~reason
                  :: acc
              | Some Core_ownership.Covered_by_contract | None ->
                  missing_ownership_contract_violation stage e.loc
                    ~kind_name:"builtin" ~call_name:name ~arg_count
                  :: acc))
      | _ -> acc)
    [] prog
  |> List.rev

let registry_for_program (prog : Core.core_program) : Codegen_types.registry =
  let reg = Codegen_types.create_registry () in
  Core_flatten.register_types reg prog;
  reg

(** Resource-safety invariants only need alias expansion. Avoid the full codegen
    layout registry here so malformed resource-containing aggregates produce
    invariant violations instead of raising while destructor layouts are being
    classified. *)
let alias_registry_for_program (prog : Core.core_program) :
    Codegen_types.registry =
  let reg = Codegen_types.create_registry () in
  let rec register_decl d =
    match d.Core.cd_desc with
    | Core.CDTypeAlias a ->
        Hashtbl.replace reg.type_aliases a.alias_name
          (Ast.type_param_names a.alias_type_params, a.alias_target)
    | Core.CDPrivate inner -> register_decl inner
    | _ -> ()
  in
  List.iter register_decl prog;
  reg

let invariant_normalize_type ~(reg : Codegen_types.registry) ty =
  Codegen_types.expand_alias ~reg ty |> Codegen_types.normalize_type

let invariant_types_equal ~(reg : Codegen_types.registry) a b =
  Types.types_equal
    (invariant_normalize_type ~reg a)
    (invariant_normalize_type ~reg b)

let declared_resource_type_names_for_program (prog : Core.core_program) =
  let rec add_decl acc (d : Core.core_decl) =
    match d.cd_desc with
    | Core.CDType t when t.type_is_resource -> StringSet.add t.type_name acc
    | Core.CDPrivate inner -> add_decl acc inner
    | _ -> acc
  in
  List.fold_left add_decl StringSet.empty prog

let resource_type_names_for_scope ~reg resource_names scope_ty =
  match invariant_normalize_type ~reg scope_ty |> Types.head_resolve with
  | Ast.TyNamed (name, _) -> StringSet.add name resource_names
  | _ -> resource_names

let resource_type_names_for_program ~reg (prog : Core.core_program) =
  fold_program
    (fun acc e ->
      match e.Core.desc with
      | Core.CResourceScope s -> resource_type_names_for_scope ~reg acc s.rs_ty
      | _ -> acc)
    (declared_resource_type_names_for_program prog)
    prog

let aggregate_components_for_program (prog : Core.core_program) =
  let add name type_params component_types acc =
    StringMap.add name (Ast.type_param_names type_params, component_types) acc
  in
  let rec add_decl acc d =
    match d.Core.cd_desc with
    | Core.CDRecord r ->
        add r.record_name r.record_type_params
          (List.map (fun f -> f.Ast.field_type) r.record_fields)
          acc
    | Core.CDType t ->
        add t.type_name t.type_params
          (List.concat_map (fun v -> v.Ast.variant_fields) t.type_variants)
          acc
    | Core.CDPrivate inner -> add_decl acc inner
    | _ -> acc
  in
  List.fold_left add_decl StringMap.empty prog

let type_contains_resource_named ~reg ~resource_names ~aggregate_components ty =
  let apply_named_subst type_params args tys =
    let subst =
      if List.length type_params = List.length args then
        List.map2
          (fun var_name concrete_type -> { Types.var_name; concrete_type })
          type_params args
      else []
    in
    List.map (Types.apply_subst subst) tys
  in
  let component_types name args =
    match StringMap.find_opt name aggregate_components with
    | Some (type_params, tys) -> apply_named_subst type_params args tys
    | None -> []
  in
  let rec go visited ty =
    let ty = invariant_normalize_type ~reg ty |> Types.head_resolve in
    match ty with
    | Ast.TyNamed (name, args) ->
        StringSet.mem name resource_names
        || List.exists (go visited) args
        ||
        if StringSet.mem name visited then false
        else
          component_types name args
          |> List.exists (go (StringSet.add name visited))
    | Ast.TyArray (elem, dims) ->
        go visited elem || List.exists (go visited) dims
    | Ast.TyFunc { params; return; _ } ->
        List.exists (go visited) params || go visited return
    | Ast.TyTuple elems -> List.exists (go visited) elems
    | Ast.TyRange inner -> go visited inner
    | Ast.TyDimOp (_, left, right) -> go visited left || go visited right
    | Ast.TyBoundVar _ | Ast.TyConstInt _ | Ast.TyMeta _ | Ast.TySelf
    | Ast.TyVar _ | Ast.TyVarDims _ ->
        false
  in
  go StringSet.empty ty

let check_resource_scope_contracts_at (stage : Core_stage.t)
    (prog : Core.core_program) : Core_error.t list =
  let reg = alias_registry_for_program prog in
  let ty_void = Ast.TyNamed ("Void", []) in
  let program_resource_names = resource_type_names_for_program ~reg prog in
  let aggregate_components = aggregate_components_for_program prog in
  let check_cleanup_shape s acc =
    if not (invariant_types_equal ~reg s.Core.rs_cleanup.ty ty_void) then acc
    else
      match s.rs_cleanup.desc with
      | Core.CCall (_, _, [ { Core.desc = Core.CVar arg_var; ty = arg_ty; _ } ])
        ->
          if
            Core.Var.equal arg_var s.rs_var
            && invariant_types_equal ~reg arg_ty s.rs_ty
          then acc
          else
            violation_at stage s.rs_cleanup.loc
              ~hint:
                "A resource cleanup edge must finalize the scoped resource \
                 bound by this CResourceScope, not an outer or unrelated \
                 value."
              (Printf.sprintf
                 "resource cleanup argument `%s: %s` should be scoped resource \
                  `%s: %s`"
                 (Core.Var.to_string arg_var)
                 (Types.type_to_string arg_ty)
                 (Core.Var.to_string s.rs_var)
                 (Types.type_to_string s.rs_ty))
            :: acc
      | Core.CCall (_, _, args) ->
          violation_at stage s.rs_cleanup.loc
            ~hint:
              "Keep resource cleanup as one finalizer call whose only argument \
               is the scoped resource binding."
            (Printf.sprintf
               "resource cleanup call should take exactly one scoped resource \
                argument, got %d"
               (List.length args))
          :: acc
      | _ ->
          violation_at stage s.rs_cleanup.loc
            ~hint:
              "Keep cleanup as an explicit finalizer call so later cleanup \
               lowering has exactly one operation to emit."
            "resource cleanup must be a direct call on the scoped resource"
          :: acc
  in
  fold_program
    (fun acc e ->
      match e.Core.desc with
      | Core.CResourceScope s ->
          let acc =
            if invariant_types_equal ~reg s.rs_acquire.ty s.rs_ty then acc
            else
              violation_at stage s.rs_acquire.loc
                ~hint:
                  "Lowering should commit the resource capability type once on \
                   CResourceScope.rs_ty, and the acquisition expression must \
                   produce that exact type."
                (Printf.sprintf
                   "resource acquire type `%s` does not match binding type `%s`"
                   (Types.type_to_string s.rs_acquire.ty)
                   (Types.type_to_string s.rs_ty))
              :: acc
          in
          let acc =
            if invariant_types_equal ~reg e.Core.ty s.rs_body.ty then acc
            else
              violation_at stage s.rs_body.loc
                ~hint:
                  "A CResourceScope returns the value of its body. Keep \
                   cleanup as a separate Void action instead of mixing it into \
                   the result expression."
                (Printf.sprintf
                   "resource body type `%s` does not match scope result type \
                    `%s`"
                   (Types.type_to_string s.rs_body.ty)
                   (Types.type_to_string e.Core.ty))
              :: acc
          in
          let acc =
            let resource_names =
              resource_type_names_for_scope ~reg program_resource_names s.rs_ty
            in
            if
              type_contains_resource_named ~reg ~resource_names
                ~aggregate_components s.rs_body.ty
            then
              violation_at stage s.rs_body.loc
                ~hint:
                  "A resource scope may use the scoped capability internally, \
                   but its result must be ordinary data. Return data read from \
                   the resource, not the resource or a value containing it."
                (Printf.sprintf
                   "resource scope body type `%s` must not contain a resource \
                    type"
                   (Types.type_to_string s.rs_body.ty))
              :: acc
            else acc
          in
          let acc =
            if invariant_types_equal ~reg s.rs_cleanup.ty ty_void then acc
            else
              violation_at stage s.rs_cleanup.loc
                ~hint:
                  "Resource cleanup is a side-effecting finalizer and must \
                   return Void. The scope result comes only from the body."
                (Printf.sprintf "resource cleanup type `%s` should be Void"
                   (Types.type_to_string s.rs_cleanup.ty))
              :: acc
          in
          check_cleanup_shape s acc
      | _ -> acc)
    [] prog
  |> List.rev

let rec resource_scope_body_contains_nonlocal_exit (body : Core.core) : bool =
  let any_child e =
    Core.fold_immediate_children
      (fun found child ->
        found || resource_scope_body_contains_nonlocal_exit child)
      false e
  in
  match body.Core.desc with
  | Core.CBreak | Core.CContinue -> true
  | Core.CResourceCleanupExit _ -> false
  | Core.CWhile (cond, _) -> resource_scope_body_contains_nonlocal_exit cond
  | Core.CFor (_, iter, _) -> resource_scope_body_contains_nonlocal_exit iter
  | Core.CTailrecLoop _ -> false
  | Core.CMatch (scrutinee, tree) ->
      resource_scope_body_contains_nonlocal_exit scrutinee
      || resource_scope_ctree_contains_nonlocal_exit tree
  | Core.CMatchArms (scrutinee, arms) ->
      resource_scope_body_contains_nonlocal_exit scrutinee
      || List.exists
           (fun (_, arm_body) ->
             resource_scope_body_contains_nonlocal_exit arm_body)
           arms
  | _ -> any_child body

and resource_scope_ctree_contains_nonlocal_exit (tree : Core.ctree) : bool =
  match tree with
  | Core.CTLeaf { ct_body; _ } ->
      resource_scope_body_contains_nonlocal_exit ct_body
  | Core.CTFail -> false
  | Core.CTSwitchTag { cts_cases; cts_default; _ } ->
      List.exists
        (fun (_, subtree) ->
          resource_scope_ctree_contains_nonlocal_exit subtree)
        cts_cases
      || Option.fold ~none:false
           ~some:resource_scope_ctree_contains_nonlocal_exit cts_default
  | Core.CTSwitchLit { ctl_cases; ctl_default; _ } ->
      List.exists
        (fun (_, subtree) ->
          resource_scope_ctree_contains_nonlocal_exit subtree)
        ctl_cases
      || resource_scope_ctree_contains_nonlocal_exit ctl_default
  | Core.CTSwitchLen { ctl_len_cases; ctl_len_geq; ctl_len_default; _ } ->
      List.exists
        (fun (_, subtree) ->
          resource_scope_ctree_contains_nonlocal_exit subtree)
        ctl_len_cases
      || (match ctl_len_geq with
        | Some (_, subtree) ->
            resource_scope_ctree_contains_nonlocal_exit subtree
        | None -> false)
      || Option.fold ~none:false
           ~some:resource_scope_ctree_contains_nonlocal_exit ctl_len_default

let check_resource_scope_nonlocal_exits_at (stage : Core_stage.t)
    (prog : Core.core_program) : Core_error.t list =
  fold_program
    (fun acc e ->
      match e.Core.desc with
      | Core.CResourceScope s
        when resource_scope_body_contains_nonlocal_exit s.rs_body ->
          violation_at stage e.loc
            ~hint:
              "Normal resource-scope completion is emitted directly. Break and \
               continue need explicit cleanup-edge rewriting before they can \
               be allowed through a resource scope."
            "resource scope body contains nonlocal control flow before cleanup \
             rewriting"
          :: acc
      | _ -> acc)
    [] prog
  |> List.rev

let check_resource_cleanup_exits_at (stage : Core_stage.t)
    (prog : Core.core_program) : Core_error.t list =
  let ty_void = Ast.TyNamed ("Void", []) in
  fold_program
    (fun acc e ->
      match e.Core.desc with
      | Core.CResourceCleanupExit exit ->
          let acc =
            if exit.rce_cleanups = [] then
              violation_at stage e.loc
                ~hint:
                  "Only resource exits that leave at least one active resource \
                   scope need cleanup-edge rewriting."
                "resource cleanup exit has no cleanup actions"
              :: acc
            else acc
          in
          let acc =
            if not (Types.types_equal e.ty ty_void) then
              violation_at stage e.loc
                ~hint:
                  "A cleanup exit is statement-like control flow and must not \
                   produce a value."
                "resource cleanup exit should have type Void"
              :: acc
            else acc
          in
          List.fold_left
            (fun acc cleanup ->
              if Types.types_equal cleanup.Core.ty ty_void then acc
              else
                violation_at stage cleanup.loc
                  ~hint:
                    "Cleanup actions must be explicit Void-returning finalizer \
                     calls."
                  "resource cleanup exit contains non-Void cleanup action"
                :: acc)
            acc exit.rce_cleanups
      | _ -> acc)
    [] prog
  |> List.rev

let nth_opt xs n =
  let rec go i = function
    | [] -> None
    | x :: _ when i = n -> Some x
    | _ :: rest -> go (i + 1) rest
  in
  if n < 0 then None else go 0 xs

let void_slot_arg_is_explicit ~(reg : Codegen_types.registry) (arg : Core.core)
    : bool =
  match arg.desc with
  | Core.CBoxTyped _ -> true
  | _ -> Core_layout_type.is_pointer_type ~reg arg.ty

let check_void_boxed_builtin_args_explicit_at (stage : Core_stage.t)
    (prog : Core.core_program) : Core_error.t list =
  let reg = registry_for_program prog in
  fold_program
    (fun acc e ->
      match e.Core.desc with
      | Core.CCall (Core.CKBuiltin name, _, args) -> (
          match
            List.assoc_opt name Core_specialize.void_boxed_arg_positions
          with
          | None -> acc
          | Some positions ->
              List.fold_left
                (fun acc i ->
                  match nth_opt args i with
                  | None -> acc
                  | Some arg when void_slot_arg_is_explicit ~reg arg -> acc
                  | Some arg ->
                      let v =
                        violation_at stage arg.loc
                          ~hint:
                            "Core_specialize should insert CBox for runtime \
                             void* arguments and Core_codegen_prepare should \
                             rewrite it to CBoxTyped before final Core. Do not \
                             rely on Core_emit.emit_boxed as a fallback."
                          (Printf.sprintf
                             "builtin `%s` argument %d reaches final Core \
                              without explicit CBoxTyped for its void* ABI \
                              slot"
                             name i)
                      in
                      v :: acc)
                acc positions)
      | _ -> acc)
    [] prog
  |> List.rev

(* ============================================================================
   Final Core: first-class top-level function references are explicit closures
   ============================================================================ *)

type top_level_function_index = {
  top_fn_names : StringSet.t;
  top_fn_def_ids : IntSet.t;
}

let empty_top_level_function_index =
  { top_fn_names = StringSet.empty; top_fn_def_ids = IntSet.empty }

let top_level_function_is_runtime (f : Core.core_func) : bool =
  match f.cf_kind with
  | Core.CFForeign _ -> true
  | Core.CFBuiltin -> false
  | Core.CFUser | Core.CFClosureBody _ -> f.cf_body <> None

let add_top_level_function index (f : Core.core_func) : top_level_function_index
    =
  if not (top_level_function_is_runtime f) then index
  else
    {
      top_fn_names = StringSet.add f.cf_name index.top_fn_names;
      top_fn_def_ids = IntSet.add f.cf_def_id index.top_fn_def_ids;
    }

let collect_top_level_function_index (prog : Core.core_program) :
    top_level_function_index =
  let rec visit_decl index (d : Core.core_decl) =
    match d.cd_desc with
    | Core.CDFunc f -> add_top_level_function index f
    | Core.CDImpl i -> List.fold_left add_top_level_function index i.ci_methods
    | Core.CDPrivate inner -> visit_decl index inner
    | Core.CDType _ | Core.CDRecord _ | Core.CDImport _ | Core.CDTypeAlias _
    | Core.CDVar _ | Core.CDTrait _ ->
        index
  in
  List.fold_left visit_decl empty_top_level_function_index prog

let add_bound_var (bound : StringSet.t) (v : Core.var) : StringSet.t =
  StringSet.add v.vname bound

let add_bound_core_param (bound : StringSet.t) (p : Core.core_param) :
    StringSet.t =
  add_bound_var bound p.cp_name

let add_bound_closure_capture (bound : StringSet.t) ((name, _) : string * _) :
    StringSet.t =
  StringSet.add name bound

let add_bound_pattern_vars (bound : StringSet.t) (pat : Ast.pattern) :
    StringSet.t =
  List.fold_left
    (fun acc name -> StringSet.add name acc)
    bound
    (Ast.collect_pattern_vars pat)

let add_bound_function_scope (bound : StringSet.t) (f : Core.core_func) :
    StringSet.t =
  let bound = List.fold_left add_bound_core_param bound f.cf_params in
  match f.cf_kind with
  | Core.CFClosureBody abi ->
      let bound =
        List.fold_left
          (fun acc (v, _) -> add_bound_var acc v)
          bound abi.ca_params
      in
      List.fold_left add_bound_closure_capture bound abi.ca_captures
  | Core.CFUser | Core.CFBuiltin | Core.CFForeign _ -> bound

let raw_top_level_function_ref (index : top_level_function_index)
    (bound : StringSet.t) (v : Core.var) (ty : Ast.type_expr) : bool =
  match Codegen_types.normalize_type ty with
  | Ast.TyFunc _ ->
      (not (StringSet.mem v.vname bound))
      && begin match v.vdef_id with
      | Some id ->
          IntSet.mem id index.top_fn_def_ids
          || StringSet.mem v.vname index.top_fn_names
      | None -> StringSet.mem v.vname index.top_fn_names
      end
  | _ -> false

let direct_call_kind = function
  | Core.CKUser _ | Core.CKForeign _ | Core.CKBuiltin _ | Core.CKIntrinsic _
  | Core.CKUnknown | Core.CKSelectedDirect _ ->
      true
  | Core.CKClosure -> false

let check_no_raw_top_level_function_refs_at (stage : Core_stage.t)
    (prog : Core.core_program) : Core_error.t list =
  let index = collect_top_level_function_index prog in
  let violation_for (e : Core.core) (v : Core.var) =
    violation_at stage e.loc
      ~hint:
        "Core_closure.adapt_function_refs_program should rewrite first-class \
         top-level function references into explicit CClosureCreate eta \
         adapters before final Core. Emitters should lower the declared \
         closure ABI, not synthesize function-reference trampolines."
      (Printf.sprintf
         "top-level function reference `%s` reached final Core as raw CVar; \
          expected explicit CClosureCreate"
         v.vname)
  in
  let rec visit_ctree bound acc = function
    | Core.CTLeaf { ct_bindings; ct_body } ->
        let bound =
          List.fold_left
            (fun acc binding -> add_bound_var acc binding.Core.mb_var)
            bound ct_bindings
        in
        visit bound acc ct_body
    | Core.CTFail -> acc
    | Core.CTSwitchTag { cts_cases; cts_default; _ } ->
        let acc =
          List.fold_left
            (fun acc (_, sub) -> visit_ctree bound acc sub)
            acc cts_cases
        in
        Option.fold ~none:acc
          ~some:(fun sub -> visit_ctree bound acc sub)
          cts_default
    | Core.CTSwitchLit { ctl_cases; ctl_default; _ } ->
        let acc =
          List.fold_left
            (fun acc (_, sub) -> visit_ctree bound acc sub)
            acc ctl_cases
        in
        visit_ctree bound acc ctl_default
    | Core.CTSwitchLen { ctl_len_cases; ctl_len_geq; ctl_len_default; _ } ->
        let acc =
          List.fold_left
            (fun acc (_, sub) -> visit_ctree bound acc sub)
            acc ctl_len_cases
        in
        let acc =
          match ctl_len_geq with
          | Some (_, sub) -> visit_ctree bound acc sub
          | None -> acc
        in
        Option.fold ~none:acc
          ~some:(fun sub -> visit_ctree bound acc sub)
          ctl_len_default
  and visit_tailrec_loop bound acc = function
    | Core.TailrecUnmanagedLoop { tul_params; tul_body; _ } ->
        let bound = List.fold_left add_bound_core_param bound tul_params in
        visit bound acc tul_body
    | Core.TailrecListSpreadLoop
        { tls_params; tls_list_param; tls_cursor_var; tls_body; _ } ->
        let bound = List.fold_left add_bound_core_param bound tls_params in
        let bound = add_bound_core_param bound tls_list_param in
        let bound = add_bound_var bound tls_cursor_var in
        visit bound acc tls_body
  and visit_listhandoff bound acc (h : Core.list_handoff) =
    let acc = visit bound acc h.lh_source in
    let acc = visit bound acc h.lh_capacity in
    let body_bound =
      List.fold_left add_bound_var bound
        [ h.lh_source_var; h.lh_result_var; h.lh_len_var; h.lh_out_var ]
    in
    visit body_bound acc h.lh_body
  and visit bound acc (e : Core.core) =
    let acc =
      match e.desc with
      | Core.CVar v when raw_top_level_function_ref index bound v e.ty ->
          violation_for e v :: acc
      | _ -> acc
    in
    match e.desc with
    | Core.CLet (b, body) ->
        let acc = visit bound acc b.bind_rhs in
        visit (add_bound_var bound b.bind_var) acc body
    | Core.CBorrowLet (b, body) ->
        let acc = visit bound acc b.borrow_rhs in
        visit (add_bound_var bound b.borrow_var) acc body
    | Core.CLambda lam ->
        let bound =
          List.fold_left
            (fun acc (v, _) -> add_bound_var acc v)
            bound lam.lam_params
        in
        visit bound acc lam.lam_body
    | Core.CCall (kind, fn, args) ->
        let acc = if direct_call_kind kind then acc else visit bound acc fn in
        List.fold_left (visit bound) acc args
    | Core.CFor (binder, iter, body) ->
        let acc = visit bound acc iter in
        visit (add_bound_var bound binder.loop_var) acc body
    | Core.CMatchArms (scrut, arms) ->
        let acc = visit bound acc scrut in
        List.fold_left
          (fun acc (pat, body) ->
            visit (add_bound_pattern_vars bound pat) acc body)
          acc arms
    | Core.CMatch (scrut, tree) ->
        let acc = visit bound acc scrut in
        visit_ctree bound acc tree
    | Core.CTailrecLoop loop -> visit_tailrec_loop bound acc loop
    | Core.CConcurrent (block : Core.concurrent_block) ->
        let acc =
          List.fold_left
            (fun acc (b : Core.conc_binding) -> visit bound acc b.cb_rhs)
            acc block.conc_bindings
        in
        let acc =
          match block.conc_timeout with
          | Some timeout -> visit bound acc timeout
          | None -> acc
        in
        let body_bound =
          List.fold_left
            (fun acc (b : Core.conc_binding) -> add_bound_var acc b.cb_var)
            bound block.conc_bindings
        in
        visit body_bound acc block.conc_body
    | Core.CConcurrentlyLoop (cf : Core.concurrently_loop) ->
        let acc = visit bound acc cf.cf_iter in
        let acc =
          match cf.cf_timeout with
          | Some timeout -> visit bound acc timeout
          | None -> acc
        in
        visit (add_bound_var bound cf.cf_var) acc cf.cf_body
    | Core.CListHandoff h -> visit_listhandoff bound acc h
    | _ -> Core.fold_immediate_children (visit bound) acc e
  in
  let rec visit_decl acc (d : Core.core_decl) =
    match d.cd_desc with
    | Core.CDFunc f -> (
        match f.cf_body with
        | Some body ->
            visit (add_bound_function_scope StringSet.empty f) acc body
        | None -> acc)
    | Core.CDVar v -> visit StringSet.empty acc v.cv_init
    | Core.CDImpl i ->
        List.fold_left
          (fun acc (m : Core.core_func) ->
            match m.cf_body with
            | Some body ->
                visit (add_bound_function_scope StringSet.empty m) acc body
            | None -> acc)
          acc i.ci_methods
    | Core.CDPrivate inner -> visit_decl acc inner
    | Core.CDTrait _ | Core.CDType _ | Core.CDRecord _ | Core.CDImport _
    | Core.CDTypeAlias _ ->
        acc
  in
  List.fold_left visit_decl [] prog |> List.rev

(* ============================================================================
   Post-mono: user-function call arg types are type-variable-free
   ============================================================================ *)

(** Does a type contain any [TyVar] (or [TyVarDims], which is the same
    concept at the dim-list level)? Looks through the whole tree; a
    single variable anywhere is a leak. *)
let rec type_has_tyvar (t : Ast.type_expr) : bool =
  match t with
  | Ast.TyVar _ -> true
  | Ast.TyBoundVar _ -> true
  | Ast.TyVarDims _ -> true
  | Ast.TyNamed (_, args) -> List.exists type_has_tyvar args
  | Ast.TyArray (elem, dims) ->
      type_has_tyvar elem || List.exists type_has_tyvar dims
  | Ast.TyFunc { params; return; _ } ->
      List.exists type_has_tyvar params || type_has_tyvar return
  | Ast.TyTuple ts -> List.exists type_has_tyvar ts
  | Ast.TyRange t -> type_has_tyvar t
  | Ast.TyDimOp (_, a, b) -> type_has_tyvar a || type_has_tyvar b
  | Ast.TySelf ->
      true
      (* Self morally is a type variable here — if it survives past mono,
       something upstream failed to substitute it. Treating it as a
       tyvar leak surfaces the bug instead of silently hiding it. *)
  | Ast.TyMeta _ | Ast.TyConstInt _ -> false

(** After [Core_mono], user-function call sites should have concrete
    argument *and* return types. Substituting both is mono's job; a
    tyvar in either position is a specialization miss.

    Scope note: checks [CKUser] only. [CKBuiltin] / [CKForeign] /
    [CKIntrinsic] handle generic inputs via runtime dispatch (e.g.
    `blorp_list_get` accepts any element type), so a TyVar on their
    arg types is legitimate. [CKClosure] calls are also exempt: a
    closure can legitimately close over type variables in code that
    hasn't reached its specialize boundary yet, and specialize is what
    resolves them — not mono. A future invariant post-specialize could
    tighten this for closures. *)
let check_no_tyvar_leak (prog : Core.core_program) : Core_error.t list =
  fold_program
    (fun acc e ->
      match e.Core.desc with
      | Core.CCall (Core.CKUser (name, _), _, args) ->
          let arg_violations =
            List.fold_left
              (fun acc (a : Core.core) ->
                if type_has_tyvar a.ty then
                  let v =
                    violation_at Core_stage.Mono a.loc
                      ~hint:
                        (Printf.sprintf
                           "call to user function %S has an argument whose \
                            type still carries a type variable — \
                            monomorphization failed to specialize for this \
                            call site"
                           name)
                      "call-site argument contains an unresolved type variable"
                  in
                  v :: acc
                else acc)
              acc args
          in
          if type_has_tyvar e.ty then
            let v =
              violation_at Core_stage.Mono e.loc
                ~hint:
                  (Printf.sprintf
                     "call to user function %S has a return type that still \
                      carries a type variable — monomorphization failed to \
                      specialize for this call site"
                     name)
                "call-site return type contains an unresolved type variable"
            in
            v :: arg_violations
          else arg_violations
      (* CBox / CUnbox annotations are the source / target types for
       runtime boxing. Post-mono, they must be concrete — if a TyVar
       leaks in, the emitter will pick the wrong box strategy or
       silently fall through to the pointer default. *)
      | Core.CBox (_, ty) when type_has_tyvar ty ->
          let v =
            violation_at Core_stage.Mono e.loc
              ~hint:
                "CBox's source-type annotation must be concrete after \
                 monomorphization; a TyVar here means a generic value is being \
                 boxed without specialization"
              "CBox source-type annotation contains an unresolved type variable"
          in
          v :: acc
      | Core.CUnbox (_, ty) when type_has_tyvar ty ->
          let v =
            violation_at Core_stage.Mono e.loc
              ~hint:
                "CUnbox's target-type annotation must be concrete after \
                 monomorphization; a TyVar here means a generic value is being \
                 unboxed without specialization"
              "CUnbox target-type annotation contains an unresolved type \
               variable"
          in
          v :: acc
      | _ -> acc)
    [] prog
  |> List.rev

(* ============================================================================
   Post-debug: no debug blocks survive
   ============================================================================ *)

(** [Core_debug] is the only pass that decides whether [debug:] blocks are
    erased or retained. Downstream passes and emitters should never see
    [CDebugBlock]; by then the block is either [CVoid] (normal build) or its
    unwrapped body (debug build). *)
let check_no_debug_blocks_at (stage : Core_stage.t) (prog : Core.core_program) :
    Core_error.t list =
  fold_program
    (fun acc e ->
      match e.Core.desc with
      | Core.CDebugBlock _ ->
          let v =
            violation_at stage e.loc
              ~hint:
                "Core_debug should lower every debug block immediately after \
                 Core_lower. Do not let later passes or emitters decide debug \
                 build behavior."
              "debug block survived Core_debug lowering"
          in
          v :: acc
      | _ -> acc)
    [] prog
  |> List.rev

(* ============================================================================
   Post-desugar: no sugar constructors survive
   ============================================================================ *)

(** After [Core_desugar], no sugar constructors should survive. [CStringInterp]
    and [CRecordUpdate] are handled by [Core_desugar]. A surviving sugar node
    means a lowering/desugaring path missed a case and emit would otherwise
    need a phase-violating fallback. *)
let check_no_sugar (prog : Core.core_program) : Core_error.t list =
  fold_program
    (fun acc e ->
      let name_opt =
        match e.Core.desc with
        | Core.CStringInterp _ -> Some "CStringInterp"
        | Core.CRecordUpdate _ -> Some "CRecordUpdate"
        | _ -> None
      in
      match name_opt with
      | Some n ->
          let v =
            violation_at Core_stage.Desugar e.loc
              ~hint:
                (Printf.sprintf
                   "%s is a sugar constructor — Core_desugar should have \
                    eliminated it before downstream Core passes."
                   n)
              (Printf.sprintf "sugar node %s survived desugaring" n)
          in
          v :: acc
      | None -> acc)
    [] prog
  |> List.rev

(* ============================================================================
   Post-desugar: no desugarable mutable locals survive
   ============================================================================ *)

(** [Core_ssa] runs as part of the Desugar stage and owns mutable locals
    that are either never reassigned or reassigned in straight-line code.
    Control-flow mutation is explicitly out of scope for that pass today,
    so this invariant flags only the shapes that [Core_ssa] is expected
    to eliminate. *)
let check_no_desugarable_mutation (prog : Core.core_program) : Core_error.t list
    =
  fold_program
    (fun acc e ->
      match e.Core.desc with
      | Core.CLet (b, body) when b.bind_mut -> (
          match Core_ssa.classify_assignment_shape b.bind_var.vname body with
          | Core_ssa.No_assign ->
              let v =
                violation_at Core_stage.Desugar e.loc
                  ~hint:
                    "Core_ssa should convert var bindings with no reassignment \
                     into immutable lets during the Desugar stage."
                  "mutable local binding without assignment survived desugaring"
              in
              v :: acc
          | Core_ssa.Straight_line_assign ->
              let v =
                violation_at Core_stage.Desugar e.loc
                  ~hint:
                    "Core_ssa should rewrite straight-line reassignment into \
                     versioned immutable lets during the Desugar stage."
                  "straight-line mutable assignment survived desugaring"
              in
              v :: acc
          | Core_ssa.Control_flow_assign -> acc)
      | _ -> acc)
    [] prog
  |> List.rev

(* ============================================================================
   Post-match: no raw CMatchArms survives
   ============================================================================ *)

(** After [Core_match], every pattern match should have been compiled
    from [CMatchArms] into the decision-tree [CMatch] form. A surviving
    [CMatchArms] means [Core_match]'s [classify_arms] fell through for
    this shape and emission would hit a dead path. *)
let check_no_cmatcharms (prog : Core.core_program) : Core_error.t list =
  fold_program
    (fun acc e ->
      match e.Core.desc with
      | Core.CMatchArms _ ->
          let v =
            violation_at Core_stage.Match e.loc
              ~hint:
                "Core_match should have compiled every CMatchArms into the \
                 decision-tree CMatch form. A surviving CMatchArms means \
                 classify_arms fell through — add the missing arm-shape \
                 handler."
              "raw CMatchArms survived match-compilation"
          in
          v :: acc
      | _ -> acc)
    [] prog
  |> List.rev

(* ============================================================================
   Post-closure: no raw lambdas or task-less concurrency forms survive
   ============================================================================ *)

let check_no_preclosure_forms (prog : Core.core_program) : Core_error.t list =
  fold_program
    (fun acc e ->
      match e.Core.desc with
      | Core.CLambda _ ->
          let v =
            violation_at Core_stage.Closure e.loc
              ~hint:
                "Core_closure should hoist every CLambda into a top-level \
                 closure body and replace the site with CClosureCreate."
              "raw CLambda survived closure conversion"
          in
          v :: acc
      | Core.CConcurrent block ->
          List.fold_left
            (fun acc (b : Core.conc_binding) ->
              match b.cb_task with
              | Some _ -> acc
              | None ->
                  let v =
                    violation_at Core_stage.Closure b.cb_rhs.loc
                      ~hint:
                        "Core_closure should attach task metadata to every \
                         concurrent binding before emission."
                      "concurrent binding is missing task closure metadata"
                  in
                  v :: acc)
            acc block.conc_bindings
      | Core.CConcurrentlyLoop cf -> (
          match cf.cf_task with
          | Some _ -> acc
          | None ->
              let v =
                violation_at Core_stage.Closure cf.cf_body.loc
                  ~hint:
                    "Core_closure should attach task metadata to every for ... \
                     concurrently body before emission."
                  "for ... concurrently is missing task closure metadata"
              in
              v :: acc)
      | Core.CDetach detach -> (
          match detach.detach_task with
          | Some _ -> acc
          | None ->
              let v =
                violation_at Core_stage.Closure detach.detach_body.loc
                  ~hint:
                    "Core_closure should attach task metadata to every detach \
                     body before emission."
                  "detach is missing task closure metadata"
              in
              v :: acc)
      | _ -> acc)
    [] prog
  |> List.rev

let check_no_resource_capture_metadata_at (stage : Core_stage.t)
    (prog : Core.core_program) : Core_error.t list =
  let reg = alias_registry_for_program prog in
  let resource_names = resource_type_names_for_program ~reg prog in
  let aggregate_components = aggregate_components_for_program prog in
  let resource_capture_violation loc ~context name ty =
    violation_at stage loc
      ~hint:
        "Core_closure must not encode scoped resources in closure or task \
         capture metadata. Keep resource use inside its with scope, or capture \
         ordinary data read from the resource instead."
      (Printf.sprintf "resource capture `%s: %s` reached %s metadata" name
         (Types.type_to_string ty) context)
  in
  let check_captures loc ~context captures acc =
    List.fold_left
      (fun acc (name, ty) ->
        if
          type_contains_resource_named ~reg ~resource_names
            ~aggregate_components ty
        then resource_capture_violation loc ~context name ty :: acc
        else acc)
      acc captures
  in
  let unsupported_task_capture_violation loc ~context capture =
    violation_at stage loc
      ~hint:
        "Only ordinary copy captures are currently implemented for child \
         tasks. Resource item moves and structured task borrows need explicit \
         lowering before they can reach closure metadata."
      (Printf.sprintf "unsupported %s capture `%s: %s`" context
         capture.Core.task_capture_name
         (Types.type_to_string capture.Core.task_capture_ty))
  in
  let check_task_captures ?allowed_resource_move loc ~context task acc =
    let acc =
      List.fold_left
        (fun acc capture ->
          match capture.Core.task_capture_kind with
          | Core.TaskCopyCapture -> acc
          | Core.TaskMoveResourceItem -> (
              match allowed_resource_move with
              | Some (name, ty)
                when capture.Core.task_capture_name = name
                     && invariant_types_equal ~reg capture.Core.task_capture_ty
                          ty ->
                  acc
              | _ ->
                  unsupported_task_capture_violation loc ~context capture :: acc
              )
          | Core.TaskStructuredTaskBorrow ->
              unsupported_task_capture_violation loc ~context capture :: acc)
        acc task.Core.tc_captures
    in
    let copy_capture_bindings =
      task.Core.tc_captures
      |> List.filter_map (fun capture ->
          match capture.Core.task_capture_kind with
          | Core.TaskCopyCapture -> Some (Core.task_capture_binding capture)
          | Core.TaskMoveResourceItem | Core.TaskStructuredTaskBorrow -> None)
    in
    check_captures loc ~context copy_capture_bindings acc
  in
  let check_task ?allowed_resource_move loc ~context task_opt acc =
    match task_opt with
    | Some task ->
        check_task_captures ?allowed_resource_move loc ~context task acc
    | None -> acc
  in
  let check_func acc (f : Core.core_func) =
    match f.cf_kind with
    | Core.CFClosureBody abi ->
        let loc =
          match f.cf_body with Some body -> body.loc | None -> Ast.dummy_loc
        in
        let copied_captures =
          List.filter
            (fun (name, _) -> not (List.mem name abi.ca_moved_captures))
            abi.ca_captures
        in
        check_captures loc ~context:"closure ABI" copied_captures acc
    | Core.CFUser | Core.CFBuiltin | Core.CFForeign _ -> acc
  in
  let rec visit_decl acc (d : Core.core_decl) =
    match d.cd_desc with
    | Core.CDFunc f -> check_func acc f
    | Core.CDImpl i -> List.fold_left check_func acc i.ci_methods
    | Core.CDPrivate inner -> visit_decl acc inner
    | Core.CDType _ | Core.CDRecord _ | Core.CDImport _ | Core.CDTypeAlias _
    | Core.CDVar _ | Core.CDTrait _ ->
        acc
  in
  let acc = List.fold_left visit_decl [] prog in
  fold_program
    (fun acc e ->
      match e.Core.desc with
      | Core.CClosureCreate cc ->
          check_captures e.loc ~context:"closure creation" cc.cc_captures acc
      | Core.CConcurrent block ->
          List.fold_left
            (fun acc (b : Core.conc_binding) ->
              check_task b.cb_rhs.loc ~context:"concurrent binding task"
                b.cb_task acc)
            acc block.conc_bindings
      | Core.CConcurrentlyLoop cf ->
          let allowed_resource_move =
            match cf.cf_item_mode with
            | Core.ConcurrentlyLoopMoveResourceItem { clmi_resource_ty; _ } ->
                Some (cf.cf_var.Core.vname, clmi_resource_ty)
            | Core.ConcurrentlyLoopCopyItem -> None
          in
          check_task ?allowed_resource_move cf.cf_body.loc
            ~context:"for ... concurrently task" cf.cf_task acc
      | Core.CDetach detach ->
          check_task detach.detach_body.loc ~context:"detach task"
            detach.detach_task acc
      | _ -> acc)
    acc prog
  |> List.rev

(* ============================================================================
   Final Core: concurrency result and task contracts are explicit
   ============================================================================ *)

let concurrency_error_ty = Ast.TyNamed ("ConcurrencyError", [])
let int_ty = Ast.TyNamed ("Int", [])
let ty_void = Ast.TyNamed ("Void", [])

let concurrent_result_ty ok_ty =
  Ast.TyNamed ("Result", [ ok_ty; concurrency_error_ty ])

let list_ty elem_ty = Ast.TyNamed ("List", [ elem_ty ])

let check_concurrent_semantics_at (stage : Core_stage.t)
    (prog : Core.core_program) : Core_error.t list =
  let reg = registry_for_program prog in
  let type_mismatch loc ~subject ~expected ~actual acc =
    violation_at stage loc
      ~hint:
        "Infer/Core_lower/Core_closure should preserve one explicit \
         concurrency contract: task bodies have raw type T, joined bindings \
         have Result[T, ConcurrencyError], and collecting concurrently-loop \
         Core forms have List[Result[T, ConcurrencyError]]."
      (Printf.sprintf "%s `%s` does not match expected `%s`" subject
         (Types.type_to_string actual)
         (Types.type_to_string expected))
    :: acc
  in
  let check_timeout label loc timeout acc =
    if invariant_types_equal ~reg timeout.Core.ty int_ty then acc
    else
      type_mismatch loc
        ~subject:(Printf.sprintf "%s timeout type" label)
        ~expected:int_ty ~actual:timeout.Core.ty acc
  in
  let check_max_threads label loc max_threads acc =
    match max_threads with
    | Some n when n <= 0 ->
        violation_at stage loc
          ~hint:
            "Parser/typechecking should only construct positive max_threads \
             limits for concurrency forms."
          (Printf.sprintf "%s max_threads must be positive, got %d" label n)
        :: acc
    | _ -> acc
  in
  let check_concurrently_loop_width loc width acc =
    match width with
    | Core.ConcurrentlyLoopLimit limit ->
        if invariant_types_equal ~reg limit.Core.ty int_ty then acc
        else
          type_mismatch loc ~subject:"for ... concurrently limit type"
            ~expected:int_ty ~actual:limit.Core.ty acc
  in
  let check_concurrent_task_scope loc ~subject
      (scope : Core.concurrent_task_scope) acc =
    let parent_id = Core.task_scope_id_to_int scope.Core.task_parent_scope_id in
    let child_id = Core.task_scope_id_to_int scope.Core.task_child_scope_id in
    let acc =
      if parent_id < 0 then
        violation_at stage loc
          ~hint:
            "Core_lower should assign non-negative task scope ids, with 0 \
             reserved for the root task scope."
          (Printf.sprintf "%s parent task scope id must be non-negative, got %d"
             subject parent_id)
        :: acc
      else acc
    in
    let acc =
      if child_id <= 0 then
        violation_at stage loc
          ~hint:
            "Core_lower should assign positive child task scope ids. Scope id \
             0 is reserved for the root task."
          (Printf.sprintf "%s child task scope id must be positive, got %d"
             subject child_id)
        :: acc
      else acc
    in
    if parent_id = child_id then
      violation_at stage loc
        ~hint:
          "A child task scope must be a distinct scope owned by its parent. \
           Reuse the parent id only for code that remains synchronous."
        (Printf.sprintf "%s parent and child task scope ids must differ, got %d"
           subject parent_id)
      :: acc
    else acc
  in
  let check_task_return loc ~subject task_opt expected acc =
    match task_opt with
    | Some task
      when not (invariant_types_equal ~reg task.Core.tc_return_ty expected) ->
        type_mismatch loc
          ~subject:(subject ^ " task return type")
          ~expected ~actual:task.Core.tc_return_ty acc
    | _ -> acc
  in
  let check_unique_concurrent_binding_names bindings acc =
    let rec go seen acc = function
      | [] -> acc
      | (b : Core.conc_binding) :: rest ->
          let name = b.cb_var.vname in
          if StringSet.mem name seen then
            let acc =
              violation_at stage b.cb_rhs.loc
                ~hint:
                  "Infer/Core_lower should ensure each concurrent result \
                   binding has a distinct name before Core reaches emission."
                (Printf.sprintf
                   "duplicate concurrent binding `%s` in concurrent block" name)
              :: acc
            in
            go seen acc rest
          else go (StringSet.add name seen) acc rest
    in
    go StringSet.empty acc bindings
  in
  fold_program
    (fun acc e ->
      match e.Core.desc with
      | Core.CConcurrent block ->
          let acc =
            if invariant_types_equal ~reg e.ty block.conc_body.ty then acc
            else
              type_mismatch e.loc ~subject:"concurrent block expression type"
                ~expected:block.conc_body.ty ~actual:e.ty acc
          in
          let acc =
            check_unique_concurrent_binding_names block.conc_bindings acc
          in
          let acc =
            List.fold_left
              (fun acc (b : Core.conc_binding) ->
                let expected = concurrent_result_ty b.cb_rhs.ty in
                let acc =
                  if invariant_types_equal ~reg b.cb_ty expected then acc
                  else
                    type_mismatch b.cb_rhs.loc
                      ~subject:"concurrent binding result type" ~expected
                      ~actual:b.cb_ty acc
                in
                check_task_return b.cb_rhs.loc ~subject:"concurrent binding"
                  b.cb_task b.cb_rhs.ty acc
                |> check_concurrent_task_scope b.cb_rhs.loc
                     ~subject:"concurrent binding" b.cb_task_scope)
              acc block.conc_bindings
          in
          let acc =
            match block.conc_timeout with
            | Some timeout ->
                check_timeout "concurrent block" timeout.loc timeout acc
            | None -> acc
          in
          check_max_threads "concurrent block" e.loc block.conc_max_threads acc
      | Core.CConcurrentlyLoop cf ->
          let acc =
            match
              (cf.cf_item_mode, invariant_normalize_type ~reg cf.cf_iter.ty)
            with
            | Core.ConcurrentlyLoopCopyItem, Ast.TyNamed ("List", [ _ ]) -> acc
            | ( Core.ConcurrentlyLoopMoveResourceItem
                  { clmi_resource_ty; clmi_error_ty },
                Ast.TyNamed (name, [ resource_ty; error_ty ]) )
              when Type_name_metadata.is_resource_source_name name
                   && invariant_types_equal ~reg resource_ty clmi_resource_ty
                   && invariant_types_equal ~reg error_ty clmi_error_ty ->
                acc
            | Core.ConcurrentlyLoopCopyItem, _ ->
                violation_at stage cf.cf_iter.loc
                  ~hint:
                    "List fan-out must use copy-item mode. Resource-source \
                     fan-out must use move-resource-item mode."
                  (Printf.sprintf
                     "copy-item for ... concurrently requires List[T], got `%s`"
                     (Types.type_to_string cf.cf_iter.ty))
                :: acc
            | Core.ConcurrentlyLoopMoveResourceItem _, _ ->
                violation_at stage cf.cf_iter.loc
                  ~hint:
                    "Resource-source fan-out must keep the source type and \
                     moved item metadata in sync."
                  (Printf.sprintf
                     "move-resource for ... concurrently requires \
                      ResourceSource[R, E], got `%s`"
                     (Types.type_to_string cf.cf_iter.ty))
                :: acc
          in
          let acc =
            match (cf.cf_item_mode, cf.cf_output) with
            | ( Core.ConcurrentlyLoopMoveResourceItem _,
                Core.ConcurrentlyLoopCollect ) ->
                violation_at stage e.loc
                  ~hint:
                    "Resource-source fan-out is statement-only until result \
                     collection has an explicit ownership story."
                  "resource-source for ... concurrently cannot collect results"
                :: acc
            | Core.ConcurrentlyLoopCopyItem, _
            | ( Core.ConcurrentlyLoopMoveResourceItem _,
                Core.ConcurrentlyLoopDiscard ) ->
                acc
          in
          let expected_result =
            match cf.cf_output with
            | Core.ConcurrentlyLoopCollect ->
                list_ty (concurrent_result_ty cf.cf_body.ty)
            | Core.ConcurrentlyLoopDiscard -> ty_void
          in
          let acc =
            if invariant_types_equal ~reg e.ty expected_result then acc
            else
              type_mismatch e.loc ~subject:"for ... concurrently result type"
                ~expected:expected_result ~actual:e.ty acc
          in
          let acc =
            match cf.cf_output with
            | Core.ConcurrentlyLoopCollect -> acc
            | Core.ConcurrentlyLoopDiscard
              when invariant_types_equal ~reg cf.cf_body.ty ty_void ->
                acc
            | Core.ConcurrentlyLoopDiscard ->
                type_mismatch cf.cf_body.loc
                  ~subject:"discarding for ... concurrently body type"
                  ~expected:ty_void ~actual:cf.cf_body.ty acc
          in
          let acc =
            check_task_return cf.cf_body.loc ~subject:"for ... concurrently"
              cf.cf_task cf.cf_body.ty acc
          in
          let acc =
            match cf.cf_timeout with
            | Some timeout ->
                check_timeout "for ... concurrently" timeout.loc timeout acc
            | None -> acc
          in
          let acc = check_concurrently_loop_width e.loc cf.cf_width acc in
          check_concurrent_task_scope e.loc ~subject:"for ... concurrently"
            cf.cf_task_scope acc
      | _ -> acc)
    [] prog
  |> List.rev

(* ============================================================================
   Post-specialize: raw tensor views are scoped, typed, and kind-consistent
   ============================================================================ *)

let normalize_with_reg ?reg ty =
  match reg with
  | Some reg ->
      Codegen_types.expand_alias ~reg ty |> Codegen_types.normalize_type
  | None -> Codegen_types.normalize_type ty

let raw_tensor_scalar_accepts_type ~reg (kind : Core.tensor_unboxed_scalar)
    (ty : Ast.type_expr) : bool =
  Core_layout_type.tensor_raw_scalar_accepts_type ~reg kind ty

let raw_tensor_scalar_name = Core.tensor_unboxed_scalar_str

let raw_tensor_source_matches_kind ~reg (kind : Core.tensor_unboxed_scalar)
    (source : Core.core) : bool =
  match Core_tensor_type.of_core ~reg source with
  | Some tensor_ty -> raw_tensor_scalar_accepts_type ~reg kind tensor_ty.elem_ty
  | None -> false

let raw_view_binding_kind env (v : Core.var) : Core.tensor_unboxed_scalar option
    =
  List.find_map
    (fun (bound_v, kind) ->
      if Core.Var.equal bound_v v then Some kind else None)
    env

let remove_raw_view_binding env (v : Core.var) =
  List.filter (fun (bound_v, _) -> not (Core.Var.equal bound_v v)) env

let check_raw_tensor_views_at (stage : Core_stage.t) (prog : Core.core_program)
    : Core_error.t list =
  let reg = registry_for_program prog in
  let raw_view_scope_hint =
    "Core_specialize should construct raw tensor views only through \
     CTensorRawViewLet, and CTensorRawRead/CTensorRawWrite must reference a \
     dominating view with the same closed scalar kind."
  in
  let kind_mismatch_hint =
    "Do not pair a raw tensor view variable with a separately chosen pointer \
     intrinsic or generic Ptr. Carry the closed tensor scalar kind through the \
     Core node that binds, reads, and writes the view."
  in
  let violation e ?hint msg acc =
    violation_at stage e.Core.loc ?hint msg :: acc
  in
  let rec visit env acc (e : Core.core) =
    match e.desc with
    | Core.CTensorRawRead r ->
        let acc =
          match raw_view_binding_kind env r.trr_view with
          | None ->
              violation e ~hint:raw_view_scope_hint
                (Printf.sprintf "raw tensor read uses unbound view `%s`"
                   (Core.Var.to_string r.trr_view))
                acc
          | Some bound_kind when bound_kind <> r.trr_kind ->
              violation e ~hint:kind_mismatch_hint
                (Printf.sprintf
                   "raw tensor read kind `%s` does not match view `%s` kind \
                    `%s`"
                   (raw_tensor_scalar_name r.trr_kind)
                   (Core.Var.to_string r.trr_view)
                   (raw_tensor_scalar_name bound_kind))
                acc
          | Some _ -> acc
        in
        let acc =
          if raw_tensor_scalar_accepts_type ~reg r.trr_kind e.ty then acc
          else
            violation e ~hint:kind_mismatch_hint
              (Printf.sprintf
                 "raw tensor read kind `%s` is incompatible with result type \
                  `%s`"
                 (raw_tensor_scalar_name r.trr_kind)
                 (Types.type_to_string e.ty))
              acc
        in
        visit env acc r.trr_index
    | Core.CTensorRawWrite w ->
        let acc =
          match raw_view_binding_kind env w.trw_view with
          | None ->
              violation e ~hint:raw_view_scope_hint
                (Printf.sprintf "raw tensor write uses unbound view `%s`"
                   (Core.Var.to_string w.trw_view))
                acc
          | Some bound_kind when bound_kind <> w.trw_kind ->
              violation e ~hint:kind_mismatch_hint
                (Printf.sprintf
                   "raw tensor write kind `%s` does not match view `%s` kind \
                    `%s`"
                   (raw_tensor_scalar_name w.trw_kind)
                   (Core.Var.to_string w.trw_view)
                   (raw_tensor_scalar_name bound_kind))
                acc
          | Some _ -> acc
        in
        let acc =
          if raw_tensor_scalar_accepts_type ~reg w.trw_kind w.trw_value.ty then
            acc
          else
            violation e ~hint:kind_mismatch_hint
              (Printf.sprintf
                 "raw tensor write kind `%s` is incompatible with value type \
                  `%s`"
                 (raw_tensor_scalar_name w.trw_kind)
                 (Types.type_to_string w.trw_value.ty))
              acc
        in
        let acc = visit env acc w.trw_index in
        visit env acc w.trw_value
    | Core.CTensorRawViewLet (b, body) ->
        let acc = visit env acc b.trv_source in
        let acc =
          if raw_tensor_source_matches_kind ~reg b.trv_kind b.trv_source then
            acc
          else
            violation b.trv_source ~hint:kind_mismatch_hint
              (Printf.sprintf
                 "raw tensor view kind `%s` is incompatible with source type \
                  `%s`"
                 (raw_tensor_scalar_name b.trv_kind)
                 (Types.type_to_string b.trv_source.ty))
              acc
        in
        visit ((b.trv_var, b.trv_kind) :: env) acc body
    | Core.CLet (b, body) ->
        let acc = visit env acc b.bind_rhs in
        visit (remove_raw_view_binding env b.bind_var) acc body
    | Core.CBorrowLet (b, body) ->
        let acc = visit env acc b.borrow_rhs in
        visit (remove_raw_view_binding env b.borrow_var) acc body
    | Core.CFor (binder, iter, body) ->
        let acc = visit env acc iter in
        visit (remove_raw_view_binding env binder.loop_var) acc body
    | _ -> Core.fold_immediate_children (visit env) acc e
  in
  let visit_decl acc (d : Core.core_decl) =
    match d.cd_desc with
    | Core.CDFunc fn -> (
        match fn.cf_body with Some body -> visit [] acc body | None -> acc)
    | Core.CDVar v -> visit [] acc v.cv_init
    | Core.CDImpl i ->
        List.fold_left
          (fun acc m ->
            match m.Core.cf_body with
            | Some body -> visit [] acc body
            | None -> acc)
          acc i.ci_methods
    | Core.CDPrivate inner -> (
        match inner.cd_desc with
        | Core.CDFunc fn -> (
            match fn.cf_body with Some body -> visit [] acc body | None -> acc)
        | Core.CDVar v -> visit [] acc v.cv_init
        | _ -> acc)
    | Core.CDTrait _ | Core.CDType _ | Core.CDRecord _ | Core.CDImport _
    | Core.CDTypeAlias _ ->
        acc
  in
  List.fold_left visit_decl [] prog |> List.rev

type raw_tensor_storage_guard = {
  rtsg_source_var : Core.var;
  rtsg_kind : Core.tensor_unboxed_scalar;
}

let guarded_raw_tensor_storage_source cond =
  match cond.Core.desc with
  | Core.CCall (Core.CKIntrinsic pred_name, _, [ pred_source ]) -> (
      match
        ( Core_specialize.raw_tensor_kind_of_storage_pred pred_name,
          pred_source.desc )
      with
      | Some pred_kind, Core.CVar pred_var ->
          Some { rtsg_source_var = pred_var; rtsg_kind = pred_kind }
      | _ -> None)
  | _ -> None

let rec guarded_raw_tensor_storage_sources cond =
  match cond.Core.desc with
  | Core.CLog (Ast.And, left, right) ->
      guarded_raw_tensor_storage_sources left
      @ guarded_raw_tensor_storage_sources right
  | _ -> (
      match guarded_raw_tensor_storage_source cond with
      | Some guard -> [ guard ]
      | None -> [])

type raw_tensor_get_call =
  | NotRawTensorGet
  | MalformedRawTensorGet of { rtg_name : string; rtg_arg_count : int }
  | WellFormedRawTensorGet of {
      rtg_name : string;
      rtg_source : Core.core;
      rtg_index : Core.core;
      rtg_kind : Core.tensor_unboxed_scalar;
    }

let classify_raw_tensor_get_call e =
  match e.Core.desc with
  | Core.CCall (Core.CKIntrinsic name, _, args) -> (
      match Core_specialize.raw_tensor_kind_of_raw_get name with
      | None -> NotRawTensorGet
      | Some kind -> (
          match args with
          | [ source; index ] ->
              WellFormedRawTensorGet
                {
                  rtg_name = name;
                  rtg_source = source;
                  rtg_index = index;
                  rtg_kind = kind;
                }
          | _ ->
              MalformedRawTensorGet
                { rtg_name = name; rtg_arg_count = List.length args }))
  | _ -> NotRawTensorGet

let remove_guarded_raw_tensor_source env v =
  List.filter (fun guard -> not (Core.Var.equal guard.rtsg_source_var v)) env

let remove_guarded_raw_tensor_source_name env name =
  List.filter (fun guard -> guard.rtsg_source_var.Core.vname <> name) env

let guarded_raw_tensor_source_matches env raw_source raw_kind =
  match raw_source.Core.desc with
  | Core.CVar raw_var ->
      List.exists
        (fun guard ->
          Core.Var.equal guard.rtsg_source_var raw_var
          && guard.rtsg_kind = raw_kind)
        env
  | _ -> false

let check_no_unguarded_raw_tensor_gets_at (stage : Core_stage.t)
    (prog : Core.core_program) : Core_error.t list =
  let reg = registry_for_program prog in
  let hint =
    "Raw unchecked tensor get intrinsics must either be rewritten into \
     CTensorRawRead under CTensorRawViewLet, or appear only in the true branch \
     dominated by the matching tensor_is_*_storage guard."
  in
  let violation e name acc =
    violation_at stage e.Core.loc ~hint
      (Printf.sprintf
         "raw tensor intrinsic `%s` reached final Core without its storage \
          guard"
         name)
    :: acc
  in
  let malformed_violation e name arg_count acc =
    violation_at stage e.Core.loc ~hint
      (Printf.sprintf
         "raw tensor intrinsic `%s` reached final Core with arity %d; expected \
          2 arguments"
         name arg_count)
    :: acc
  in
  let source_type_violation name source kind acc =
    violation_at stage source.Core.loc ~hint
      (Printf.sprintf
         "raw tensor intrinsic `%s` source type `%s` is incompatible with raw \
          storage kind `%s`"
         name
         (Types.type_to_string source.ty)
         (raw_tensor_scalar_name kind))
    :: acc
  in
  let result_type_violation e name kind acc =
    violation_at stage e.Core.loc ~hint
      (Printf.sprintf
         "raw tensor intrinsic `%s` result type `%s` is incompatible with raw \
          storage kind `%s`"
         name
         (Types.type_to_string e.Core.ty)
         (raw_tensor_scalar_name kind))
    :: acc
  in
  let validate_raw_tensor_get e name raw_source raw_kind acc =
    let acc =
      if raw_tensor_source_matches_kind ~reg raw_kind raw_source then acc
      else source_type_violation name raw_source raw_kind acc
    in
    let acc =
      if raw_tensor_scalar_accepts_type ~reg raw_kind e.Core.ty then acc
      else result_type_violation e name raw_kind acc
    in
    acc
  in
  let rec visit env acc (e : Core.core) =
    match e.desc with
    | Core.CIf (cond, then_expr, else_expr) ->
        let acc = visit env acc cond in
        let then_env = guarded_raw_tensor_storage_sources cond @ env in
        let acc = visit then_env acc then_expr in
        visit env acc else_expr
    | Core.CCall (Core.CKIntrinsic _, _, _) -> (
        match classify_raw_tensor_get_call e with
        | WellFormedRawTensorGet { rtg_name; rtg_source; rtg_kind; _ } ->
            let acc = Core.fold_immediate_children (visit env) acc e in
            let acc =
              validate_raw_tensor_get e rtg_name rtg_source rtg_kind acc
            in
            if guarded_raw_tensor_source_matches env rtg_source rtg_kind then
              acc
            else violation e rtg_name acc
        | MalformedRawTensorGet { rtg_name; rtg_arg_count } ->
            let acc = Core.fold_immediate_children (visit env) acc e in
            malformed_violation e rtg_name rtg_arg_count acc
        | NotRawTensorGet -> Core.fold_immediate_children (visit env) acc e)
    | Core.CLet (b, body) ->
        let acc = visit env acc b.bind_rhs in
        visit (remove_guarded_raw_tensor_source env b.bind_var) acc body
    | Core.CBorrowLet (b, body) ->
        let acc = visit env acc b.borrow_rhs in
        visit (remove_guarded_raw_tensor_source env b.borrow_var) acc body
    | Core.CFor (binder, iter, body) ->
        let acc = visit env acc iter in
        visit (remove_guarded_raw_tensor_source env binder.loop_var) acc body
    | Core.CMatchArms (scrut, arms) ->
        let acc = visit env acc scrut in
        List.fold_left
          (fun acc (pat, body) ->
            let body_env =
              List.fold_left remove_guarded_raw_tensor_source_name env
                (Core.pat_vars pat)
            in
            visit body_env acc body)
          acc arms
    | Core.CMatch (scrut, tree) ->
        let acc = visit env acc scrut in
        visit_ctree env acc tree
    | Core.CConcurrent block ->
        let acc =
          List.fold_left
            (fun acc b -> visit env acc b.Core.cb_rhs)
            acc block.conc_bindings
        in
        let acc =
          match block.conc_timeout with
          | Some timeout -> visit env acc timeout
          | None -> acc
        in
        let body_env =
          List.fold_left
            (fun env b -> remove_guarded_raw_tensor_source env b.Core.cb_var)
            env block.conc_bindings
        in
        visit body_env acc block.conc_body
    | Core.CConcurrentlyLoop cf ->
        let acc = visit env acc cf.cf_iter in
        let acc =
          match cf.cf_timeout with
          | Some timeout -> visit env acc timeout
          | None -> acc
        in
        visit (remove_guarded_raw_tensor_source env cf.cf_var) acc cf.cf_body
    | Core.CTailrecLoop (Core.TailrecUnmanagedLoop loop) ->
        let body_env =
          List.fold_left
            (fun env p -> remove_guarded_raw_tensor_source env p.Core.cp_name)
            env loop.tul_params
        in
        visit body_env acc loop.tul_body
    | Core.CTailrecLoop (Core.TailrecListSpreadLoop loop) ->
        let body_env =
          List.fold_left
            (fun env p -> remove_guarded_raw_tensor_source env p.Core.cp_name)
            env
            (loop.tls_list_param :: loop.tls_params)
        in
        let body_env =
          remove_guarded_raw_tensor_source body_env loop.tls_cursor_var
        in
        visit body_env acc loop.tls_body
    | Core.CListHandoff h ->
        let acc = visit env acc h.lh_source in
        let acc = visit env acc h.lh_capacity in
        let body_env =
          List.fold_left remove_guarded_raw_tensor_source env
            [ h.lh_source_var; h.lh_result_var; h.lh_len_var; h.lh_out_var ]
        in
        visit body_env acc h.lh_body
    | _ -> Core.fold_immediate_children (visit env) acc e
  and visit_ctree env acc tree =
    match tree with
    | Core.CTLeaf { ct_bindings; ct_body } ->
        let body_env =
          List.fold_left
            (fun env binding ->
              remove_guarded_raw_tensor_source env binding.Core.mb_var)
            env ct_bindings
        in
        visit body_env acc ct_body
    | Core.CTFail -> acc
    | Core.CTSwitchTag { cts_cases; cts_default; _ } ->
        let acc =
          List.fold_left
            (fun acc (_, sub) -> visit_ctree env acc sub)
            acc cts_cases
        in
        Option.fold ~none:acc ~some:(visit_ctree env acc) cts_default
    | Core.CTSwitchLit { ctl_cases; ctl_default; _ } ->
        let acc =
          List.fold_left
            (fun acc (_, sub) -> visit_ctree env acc sub)
            acc ctl_cases
        in
        visit_ctree env acc ctl_default
    | Core.CTSwitchLen { ctl_len_cases; ctl_len_geq; ctl_len_default; _ } ->
        let acc =
          List.fold_left
            (fun acc (_, sub) -> visit_ctree env acc sub)
            acc ctl_len_cases
        in
        let acc =
          Option.fold ~none:acc
            ~some:(fun (_, sub) -> visit_ctree env acc sub)
            ctl_len_geq
        in
        Option.fold ~none:acc ~some:(visit_ctree env acc) ctl_len_default
  in
  let visit_decl acc (d : Core.core_decl) =
    match d.cd_desc with
    | Core.CDFunc fn -> (
        match fn.cf_body with Some body -> visit [] acc body | None -> acc)
    | Core.CDVar v -> visit [] acc v.cv_init
    | Core.CDImpl i ->
        List.fold_left
          (fun acc m ->
            match m.Core.cf_body with
            | Some body -> visit [] acc body
            | None -> acc)
          acc i.ci_methods
    | Core.CDPrivate inner -> (
        match inner.cd_desc with
        | Core.CDFunc fn -> (
            match fn.cf_body with Some body -> visit [] acc body | None -> acc)
        | Core.CDVar v -> visit [] acc v.cv_init
        | _ -> acc)
    | Core.CDTrait _ | Core.CDType _ | Core.CDRecord _ | Core.CDImport _
    | Core.CDTypeAlias _ ->
        acc
  in
  List.fold_left visit_decl [] prog |> List.rev

let check_tensor_literal_layouts_at (stage : Core_stage.t)
    (prog : Core.core_program) : Core_error.t list =
  fold_program
    (fun acc e ->
      match e.Core.desc with
      | Core.CTensorLiteral tl
        when not
               (Core.tensor_literal_layout_matches_payload tl.tl_layout
                  tl.tl_payload) ->
          let expected =
            Core.tensor_storage_slot_layout_str tl.tl_layout.tsl_slots
          in
          let actual =
            Core.tensor_storage_slot_layout_str
              (Core.tensor_literal_payload_slot_layout tl.tl_payload)
          in
          let v =
            violation_at stage e.loc
              ~hint:
                "Core_codegen_prepare must construct tensor literals with one \
                 authoritative storage layout. Later passes should consume \
                 tl_layout instead of recovering representation from payload \
                 variants."
              (Printf.sprintf
                 "tensor literal layout `%s` does not match payload storage \
                  `%s`"
                 expected actual)
          in
          v :: acc
      | _ -> acc)
    [] prog
  |> List.rev

let check_tensor_loop_storage_provenance_at (stage : Core_stage.t)
    (prog : Core.core_program) : Core_error.t list =
  let reg = registry_for_program prog in
  let hint =
    "Core_codegen_prepare must attach tensor loop storage proofs only when the \
     loop source's runtime storage layout is known. Unknown-boundary tensors \
     should keep TensorStorageUnknown so emission uses a layout-safe runtime \
     reader."
  in
  fold_program
    (fun acc e ->
      match e.Core.desc with
      | Core.CFor (binder, iter, _) -> (
          match binder.loop_source_storage with
          | Core.TensorStorageProven { tsp_layout; _ } -> (
              match Core_tensor_type.of_core ~reg iter with
              | None ->
                  violation_at stage iter.loc ~hint
                    (Printf.sprintf
                       "loop source storage proof attached to non-tensor \
                        iterable `%s`"
                       (Types.type_to_string iter.ty))
                  :: acc
              | Some tensor_ty -> (
                  match tsp_layout.tsl_elem_ty with
                  | Some proven_elem
                    when Types.types_equal
                           (normalize_with_reg ~reg proven_elem)
                           tensor_ty.elem_ty ->
                      acc
                  | Some proven_elem ->
                      violation_at stage iter.loc ~hint
                        (Printf.sprintf
                           "loop source storage proof element type `%s` does \
                            not match iterable element type `%s`"
                           (Types.type_to_string proven_elem)
                           (Types.type_to_string tensor_ty.elem_ty))
                      :: acc
                  | None ->
                      violation_at stage iter.loc ~hint
                        "loop source storage proof is missing its element type"
                      :: acc))
          | Core.TensorStorageUnknown _ -> acc)
      | _ -> acc)
    [] prog
  |> List.rev

(* ============================================================================
   Dispatcher
   ============================================================================ *)

(** Run every enabled invariant check for the named stage. Returns the
    combined violation list. Stages without enabled checks return [[]].
    Keep unchecked stages explicit so adding a new invariant is a local,
    greppable change instead of being hidden in a bundled catch-all. *)
let run_for_stage (stage : Core_stage.t) (prog : Core.core_program) :
    Core_error.t list =
  match stage with
  | Core_stage.Specialize | Core_stage.Dce | Core_stage.ConsumeSpecialize ->
      check_no_ckunknown_at stage prog
      @ check_no_layoutless_list_alloc_at stage prog
      @ check_raw_tensor_views_at stage prog
  | Core_stage.Debug -> check_no_debug_blocks_at stage prog
  | Core_stage.Mono -> check_no_tyvar_leak prog
  (* Sugar and CMatchArms checks run at the pass that should have
     eliminated them AND at Perceus (one stage before emit) as a
     bookend: "eliminated here, still gone there." Catches any
     post-elimination pass that synthesizes the forbidden form. O(n)
     folds, negligible next to Perceus itself. *)
  | Core_stage.Desugar ->
      check_no_sugar prog @ check_no_desugarable_mutation prog
  | Core_stage.Match -> check_no_cmatcharms prog
  | Core_stage.Perceus ->
      check_no_sugar prog @ check_no_cmatcharms prog
      @ check_raw_tensor_views_at stage prog (* bookend *)
      @ check_call_ownership_contracts_at stage prog
      @ check_resource_scope_contracts_at stage prog
  | Core_stage.Closure ->
      check_no_preclosure_forms prog
      @ check_no_resource_capture_metadata_at stage prog
  | Core_stage.Final ->
      check_no_debug_blocks_at stage prog
      @ check_no_sugar prog @ check_no_cmatcharms prog
      @ check_no_ckunknown_at stage prog
      @ check_no_layoutless_list_alloc_at stage prog
      @ check_no_codegen_unprepared_forms_at stage prog
      @ check_void_boxed_builtin_args_explicit_at stage prog
      @ check_no_raw_top_level_function_refs_at stage prog
      @ check_no_preclosure_forms prog
      @ check_no_resource_capture_metadata_at stage prog
      @ check_raw_tensor_views_at stage prog
      @ check_no_unguarded_raw_tensor_gets_at stage prog
      @ check_no_raw_string_byte_intrinsics_at stage prog
      @ check_tensor_literal_layouts_at stage prog
      @ check_tensor_loop_storage_provenance_at stage prog
      @ check_resource_scope_contracts_at stage prog
      @ check_resource_scope_nonlocal_exits_at stage prog
      @ check_resource_cleanup_exits_at stage prog
      @ check_concurrent_semantics_at stage prog
  (* No invariants drafted for these stages yet: *)
  | Core_stage.Lower | Core_stage.Synth | Core_stage.TraitResolve
  | Core_stage.Resolve | Core_stage.StdInline | Core_stage.Tailrec
  | Core_stage.Fusion | Core_stage.Reuse ->
      []
