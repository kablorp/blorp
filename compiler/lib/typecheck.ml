(** Main Type Checker Driver for blorp

    Orchestrates type checking of entire programs:
    - Processes declarations to build environment
    - Type checks function bodies
    - Verifies pattern matching exhaustiveness
    - Checks purity constraints
    - Validates @tailrec annotations
*)

open Ast
open Types
open Env
open Infer
open Modules

(** Create a compiler_error from a source location *)
let error_at ?(kind = OtherError) loc message : compiler_error =
  { message; loc; phase = TypeCheck; kind; notes = []; help = None }

let error_with ?(kind = OtherError) ~notes ~help loc message : compiler_error =
  { message; loc; phase = TypeCheck; kind; notes; help }

type call_ref = Purity_analysis.call_ref = {
  called_name : string;
  call_loc : loc;
  called_id : int option;
}
[@@deriving show]
(** A reference to a function call found during AST traversal *)

type recursive_call_ref = { rec_call_loc : loc; is_tail : bool }
(** A reference to a recursive call, with tail position info *)

type imported_name_binding = {
  in_local_name : string;
  in_module_path : string;
  in_original_name : string;
}
(** A selective import binding in the local namespace. This is deliberately
    keyed by the post-alias local name: [import: a: parse as read] and
    [import: b: parse as read] are the same local declaration and must be
    rejected before later env insertion can accidentally pick a winner. *)

type func_callable_key = string * int * int * int * int * string option

let func_callable_key ~name (loc : loc) : func_callable_key =
  (name, loc.line, loc.column, loc.end_line, loc.end_column, loc.loc_file)

type check_state = {
  env : env;
  errors : compiler_error list;
  module_aliases : (string * string) list;
      (* Maps alias → module path for qualified imports *)
  imported_names : imported_name_binding list;
      (* Local names introduced by selective imports *)
  imported_modules : string list;
      (* Canonical names of already-imported modules *)
  import_bindings : Session.import_binding list;
      (** Canonical import bindings for this compilation unit. Reused by later
      Core passes so they do not need to reconstruct import resolution from
      [DImport] syntax. [original_name = None] marks a qualified module alias. *)
  module_origin : Session.module_origin;
      (** Source origin for this compilation unit. Policy decisions such as
          whether [builtin] declarations are legal should flow from this
          explicit origin instead of re-deriving path/string booleans. *)
  allow_debug_only_calls : bool;
      (** True in explicit debug builds and test harness compilation. When false,
          @debug_only functions may only be referenced inside a [debug:] block. *)
  private_impls : Env.impl_instance list;
      (** Private impls registered in this compilation unit. They do NOT
      go into [env.impls] / [env.impl_index] (private impls are
      module-internal and must not satisfy trait bounds for cross-
      module callers), but they DO emit C code with the same mangled
      name as a public impl would — so two private impls of the same
      (trait, for-type) collide at link time. This list is consulted
      by the coherence check alongside [env.impls]. *)
  known_type_names : (string, unit) Hashtbl.t;
      (** Type/record/alias names declared at the top level of this compilation
      unit, collected before [first_pass] runs. Used by
      [process_func_signature]'s auto-generalization guard so a function
      declared before a forward-referenced type (e.g. [func f(x: T)] declared
      above [union T]) still sees [T] as a concrete type, not auto-generalized
      into a free type param. Without this, the guard's [is_existing_type]
      check (which only consults [state.env]) misses forward refs. *)
  known_resource_type_names : (string, unit) Hashtbl.t;
      (** Resource type names declared at the top level of this compilation
      unit, collected by the [first_pass] pre-scan before function signatures
      are registered. Resource-operation metadata is checked while signatures
      are registered, so this table keeps [@resource_result_ordinary]
      validation order-independent for local resource types. *)
  top_level_names : (string, string) Hashtbl.t;
      (** Names declared at the top level of this compilation unit, collected
      before imports are processed. Module aliases share the same user-facing
      namespace as declarations, so this pre-scan prevents order-dependent
      alias collisions such as [import: ./m as Foo] followed by [record Foo]. *)
  type_home : (string, string) Hashtbl.t;
      (** PER-MODULE map from named type / record / enum to the canonical
      path of the declaring module. Populated at [first_pass] (current
      module's decls) and at [process_imported_decl] sites for types
      flowing in from imports. Consulted by the Phase 3.4 orphan-rule
      check to answer "where does this type live?" when deciding
      whether an impl is in a legal home.

      Deliberately not on [env]: two user files that each declare a
      local [record Vec2] need to see THEIR OWN Vec2's home, not the
      other file's. The [env] Hashtbls (impl_index / overloads / …)
      are shared across [Pipeline.check_modules] iterations on
      purpose (cross-module trait dispatch); [type_home] is the one
      piece that must not share. *)
  func_callable_ids : (func_callable_key, int) Hashtbl.t;
      (** Callable ids minted for named source functions in this compilation
      unit. Keyed by declaration name and source declaration location so typed
      AST construction can preserve identity without re-resolving by name. *)
}
(** Check result - collects multiple errors *)

type checked_func_signature = {
  cfs_name : string;
  cfs_param_types : type_expr list;
  cfs_param_names : string option list;
  cfs_return_type : type_expr;
  cfs_func_type : type_expr;
  cfs_effective_type_params : Ast.type_param_decl list;
  cfs_purity : purity;
  cfs_origin : func_origin;
  cfs_resource_args : resource_arg_policy;
  cfs_module_path : string option;
  cfs_dim_constraints : (type_expr * type_expr) list;
  cfs_loop_producer : loop_producer option;
  cfs_debug_only : bool;
}
(** Function signature after the declaration-boundary checks have resolved aliases,
    effective type params, purity, origin, and module ownership. Later phases should
    consume this shape instead of re-deriving parallel fields from [func_decl]. *)

let record_func_callable_id (state : check_state) ~name ~loc =
  let callable_id = Session.mint_def_id (Session.current ()) in
  Hashtbl.replace state.func_callable_ids
    (func_callable_key ~name loc)
    callable_id;
  callable_id

let loop_producer_of_registered_func ~(module_path : string option)
    ~(origin : func_origin) (name : string) : loop_producer option =
  match (origin, module_path, name) with
  | Builtin, _, "enumerate2" -> Some LoopProducerEnumerate2
  | _, Some "std/tensor", "indices" -> Some LoopProducerIndices
  | _, Some "std/tensor", "enumerate" -> Some LoopProducerEnumerate
  | _, Some "std/tensor", "enumerate2" -> Some LoopProducerEnumerate2
  | _, Some "std/tensor", "windows" -> Some LoopProducerWindows
  | _ -> None

let get_state_env state = state.env
let get_state_module_aliases state = state.module_aliases

let get_state_func_callable_id state ~name ~loc =
  Hashtbl.find_opt state.func_callable_ids (func_callable_key ~name loc)

let ctx_of_state state =
  make_ctx ~module_aliases:state.module_aliases
    ~allow_debug_only_calls:state.allow_debug_only_calls state.env

let type_is_resource_name ~is_resource_name ty =
  match Types.head_resolve ty with
  | TyNamed (name, _) -> is_resource_name name
  | TyVar _ | TyBoundVar _ | TyConstInt _ | TySelf | TyVarDims _ | TyMeta _ ->
      false
  | TyTuple _ | TyFunc _ | TyRange _ | TyArray _ | TyDimOp _ -> false

let type_is_known_resource state ty =
  type_is_resource_name ty ~is_resource_name:(fun name ->
      Hashtbl.mem state.known_resource_type_names name
      || Env.get_type_kind state.env name = Some TypeResource)

let type_contains_known_resource state ty =
  let rec contains_forward_resource ty =
    type_is_known_resource state ty
    ||
    match Types.head_resolve ty with
    | TyNamed (_, args) -> List.exists contains_forward_resource args
    | TyTuple elems -> List.exists contains_forward_resource elems
    | TyFunc { params; return; _ } ->
        List.exists contains_forward_resource params
        || contains_forward_resource return
    | TyRange inner -> contains_forward_resource inner
    | TyArray (elem, dims) ->
        contains_forward_resource elem
        || List.exists contains_forward_resource dims
    | TyDimOp (_, left, right) ->
        contains_forward_resource left || contains_forward_resource right
    | TyVar _ | TyBoundVar _ | TyConstInt _ | TySelf | TyVarDims _ | TyMeta _ ->
        false
  in
  Infer.type_contains_resource (ctx_of_state state) ty
  || contains_forward_resource ty

let resource_containing_aggregate_error loc message =
  error_with
    ~notes:
      [
        "Records, structs, and unions are ordinary value-semantic data. \
         Embedding a resource would make the resource copyable and allow it to \
         outlive its scoped cleanup.";
      ]
    ~help:
      (Some
         "Keep resource handles in a `with` binding and store only ordinary \
          data derived from them.")
    loc message

let one_shot_stream_containing_aggregate_error loc message =
  error_with
    ~notes:
      [
        "Records, structs, and unions are ordinary value-semantic data. \
         Embedding a one-shot stream would make cursor state copyable and hide \
         mutation behind an ordinary aggregate.";
      ]
    ~help:
      (Some
         "Keep stream cursors in direct local bindings, store producer \
          functions if you need to build streams later, or collect ordinary \
          data before storing it.")
    loc message

let register_resource_cleanup_metadata (decl : type_decl) : unit =
  if decl.type_is_resource then
    Option.iter
      (Session.register_resource_cleanup (Session.current ())
         ~type_name:decl.type_name)
      decl.type_resource_cleanup

let type_is_env_resource env ty =
  type_is_resource_name ty ~is_resource_name:(fun name ->
      Env.get_type_kind env name = Some TypeResource)

let param_is_borrowed (param : Ast.param) =
  match param.param_passing with ParamBorrow -> true | ParamByValue -> false

let func_has_borrowed_param (func : func_decl) =
  List.exists param_is_borrowed func.func_params

let type_is_scoped_dependency_carrier ty =
  match Types.head_resolve ty with
  | TyNamed (name, _) -> (
      match Types.split_canonical_module_type_name name with
      | Some (module_path, type_name) ->
          module_path = "std/stream" && type_name = "FallibleStream"
      | None -> name = "FallibleStream" || name = "std_stream__FallibleStream")
  | _ -> false

let type_is_scoped_dependency_carrier_in_env env ty =
  let norm_ctx = Infer_type_normalization.make_context ~env () in
  ty
  |> Infer_type_normalization.canonical norm_ctx
       Infer_type_normalization.ResourceBinding
  |> type_is_scoped_dependency_carrier

let type_contains_scoped_dependency_carrier env ty =
  let norm_ctx = Infer_type_normalization.make_context ~env () in
  let rec contains ty =
    let ty =
      Infer_type_normalization.canonical norm_ctx
        Infer_type_normalization.ResourceBinding ty
    in
    type_is_scoped_dependency_carrier ty
    ||
    match Types.head_resolve ty with
    | TyNamed (_, args) -> List.exists contains args
    | TyTuple elems -> List.exists contains elems
    | TyFunc { params; return; _ } ->
        List.exists contains params || contains return
    | TyRange inner -> contains inner
    | TyArray (elem, dims) -> contains elem || List.exists contains dims
    | TyDimOp (_, left, right) -> contains left || contains right
    | TyVar _ | TyBoundVar _ | TyConstInt _ | TySelf | TyVarDims _ | TyMeta _ ->
        false
  in
  contains ty

let resource_arg_policy_of_func ~contains_resource_param
    ~contains_scoped_dependency_param (func : func_decl) : resource_arg_policy =
  let has_borrowed_resource_param =
    func_has_borrowed_param func && contains_resource_param
  in
  match func.func_body with
  | FuncBuiltinBody _
    when contains_resource_param || contains_scoped_dependency_param ->
      let result_policy =
        if func.func_resource_result_ordinary then ResourceResultOrdinary
        else ResourceResultDependent
      in
      AllowResourceArgs result_policy
  | FuncBodyExpr _ when has_borrowed_resource_param ->
      AllowResourceArgs ResourceResultOrdinary
  | FuncBuiltinBody _ | FuncBodyExpr _ | FuncForeign _ | FuncNoBody ->
      RejectResourceArgs

let type_resolution_context (state : check_state) (env : env) =
  Type_resolution.make_context ~env ~module_aliases:state.module_aliases ()

let canonical_type_annotation_in_env (state : check_state) (env : env)
    (ty : type_expr) : type_expr =
  let ctx = type_resolution_context state env in
  Type_resolution.annotation_canonical ctx ty

let canonical_type_annotation (state : check_state) (ty : type_expr) : type_expr
    =
  canonical_type_annotation_in_env state state.env ty

let canonical_record_field_type_in_env (state : check_state) (env : env)
    (ty : type_expr) : type_expr =
  let ctx = type_resolution_context state env in
  Type_resolution.record_field_type_canonical ctx ty

let canonical_record_field_type (state : check_state) (ty : type_expr) :
    type_expr =
  canonical_record_field_type_in_env state state.env ty

let canonical_variant_field_type_in_env (state : check_state) (env : env)
    (ty : type_expr) : type_expr =
  let ctx = type_resolution_context state env in
  Type_resolution.variant_field_type_canonical ctx ty

let canonical_variant_field_type (state : check_state) (ty : type_expr) :
    type_expr =
  canonical_variant_field_type_in_env state state.env ty

let canonical_type_alias_target_in_env (state : check_state) (env : env)
    (ty : type_expr) : type_expr =
  let ctx = type_resolution_context state env in
  Type_resolution.type_alias_target_canonical ctx ty

let canonical_type_alias_target (state : check_state) (ty : type_expr) :
    type_expr =
  canonical_type_alias_target_in_env state state.env ty

let canonicalize_func_annotations (state : check_state) (func : func_decl) :
    func_decl =
  {
    func with
    func_return_type =
      Option.map (canonical_type_annotation state) func.func_return_type;
    func_params =
      List.map
        (fun p ->
          {
            p with
            param_type =
              Option.map (canonical_type_annotation state) p.param_type;
          })
        func.func_params;
  }

let preserve_source_return_annotation ~(source_func : func_decl)
    (canonical_func : func_decl) : func_decl =
  match (source_func.func_body, source_func.func_return_type) with
  | FuncBodyExpr _, Some source_return_ty ->
      { canonical_func with func_return_type = Some source_return_ty }
  | _ -> canonical_func

let add_import_binding (state : check_state) ~(local_name : string)
    ~(module_path : string) ~(original_name : string option) : check_state =
  let binding = Session.{ local_name; module_path; original_name } in
  let same_binding existing =
    existing.Session.local_name = local_name
    && existing.module_path = module_path
    && existing.original_name = original_name
  in
  if List.exists same_binding state.import_bindings then state
  else { state with import_bindings = binding :: state.import_bindings }

(** Record the declaring module for a named type/record/enum in the
    PER-MODULE [state.type_home].

    [~imported:false] (default — called from [first_pass] for
    decls in the CURRENT module) overwrites any existing entry so a
    local [record Vec2] wins over an earlier [import: geometry
    { Vec2 }] that would otherwise have claimed the name. [~imported:
    true] is first-write-wins: the declaring module's loc locks in,
    and subsequent imports (including diamond transitive re-imports)
    are no-ops. *)
let record_type_home ?(imported = false) (state : check_state) ~(name : string)
    ~(module_path : string) : check_state =
  if imported then
    begin if not (Hashtbl.mem state.type_home name) then
      Hashtbl.replace state.type_home name module_path
    end
  else Hashtbl.replace state.type_home name module_path;
  state

(** Look up the declaring module of a named type, if known. *)
let lookup_type_home (state : check_state) (name : string) : string option =
  Hashtbl.find_opt state.type_home name

(** Collect record/union/type-alias names declared by a module. Imported
    signatures and impls need owner-qualified type identity; otherwise two
    modules that each declare [record Widget] collapse to one bare [Widget]. *)
let module_local_type_names_from_decls (decls : Ast.program) : string list =
  let rec collect acc decl =
    match decl.decl_desc with
    | DPrivate inner -> collect acc inner
    | DRecord r -> r.record_name :: acc
    | DType t -> t.type_name :: acc
    | DTypeAlias a -> a.alias_name :: acc
    | _ -> acc
  in
  List.fold_left collect [] decls |> List.sort_uniq String.compare

type module_resource_type_metadata = {
  mrt_name : string;
  mrt_type_params : string list;
  mrt_cleanup : resource_cleanup option;
}

let module_resource_types_from_decls (decls : Ast.program) :
    module_resource_type_metadata list =
  let rec collect acc decl =
    match decl.decl_desc with
    | DPrivate inner -> collect acc inner
    | DType t when t.type_is_resource ->
        {
          mrt_name = t.type_name;
          mrt_type_params = Ast.type_param_names t.type_params;
          mrt_cleanup = t.type_resource_cleanup;
        }
        :: acc
    | _ -> acc
  in
  List.fold_left collect [] decls |> List.sort_uniq compare

let module_decls_for_type_metadata module_path =
  match Modules.find_cached module_path with
  | None -> []
  | Some m -> (
      match Modules.get_typed_decls m.name with
      | Some typed -> Typed_ast.program_ast typed
      | None -> m.decls)

let type_is_imported_resource_param env ~(module_path : string) ty =
  let resource_names =
    module_decls_for_type_metadata module_path
    |> module_resource_types_from_decls
    |> List.concat_map (fun metadata ->
        [
          metadata.mrt_name;
          Types.canonical_module_type_name ~module_path metadata.mrt_name;
        ])
  in
  type_is_resource_name ty ~is_resource_name:(fun name ->
      Env.get_type_kind env name = Some TypeResource
      || List.mem name resource_names)

let qualify_imported_type_expr ~(module_path : string option) ty =
  match module_path with
  | None -> ty
  | Some module_path ->
      let local_type_names =
        module_decls_for_type_metadata module_path
        |> module_local_type_names_from_decls
      in
      Types.qualify_module_local_types ~module_path local_type_names ty

let env_has_type_name env name =
  Types.is_global_abi_type_name name
  || Env.get_type_decl env name <> None
  || Env.get_record env name <> None
  || Env.get_alias env name <> None

let state_has_type_name state name =
  Hashtbl.mem state.known_type_names name || env_has_type_name state.env name

let canonical_type_lookup_name env name =
  match Env.get_type_decl env name with
  | Some _ -> name
  | None -> (
      match Env.get_alias env name with
      | Some (_, TyNamed (target, _)) when Env.get_type_decl env target <> None
        ->
          target
      | _ -> name)

let effective_type_params_from_func_type ~(is_existing_type : string -> bool)
    (func : func_decl) (func_type : type_expr) : Ast.type_param_decl list =
  let declared = Ast.type_param_names func.func_type_params in
  let implicit =
    Types.collect_type_param_candidates func_type
    |> List.map Env.type_param_name
    |> List.sort_uniq String.compare
    |> List.filter (fun name ->
        name <> "#_"
        && (not (List.mem name declared))
        && not (is_existing_type name))
    |> List.map (fun name -> Ast.make_type_param name [])
  in
  func.func_type_params @ implicit

(** Compute the effective type-parameter list for a function signature:
    the declared params plus any free type vars from the signature that
    aren't already declared, aren't [#_] (the wildcard dim), and aren't
    existing types in the env/pre-scan.

    Used at every site that reads [func.func_type_params] so downstream
    consumers (body inference, tensor-dim validation, overload entries,
    impl methods) see the same augmented list the env stores at
    registration time. Computing at use-site (rather than mutating the
    decl) keeps the AST immutable and avoids phase-ordering bugs. *)
let compute_effective_type_params (state : check_state) (func : func_decl) :
    Ast.type_param_decl list =
  let func_type =
    TyFunc
      {
        params = List.filter_map (fun p -> p.param_type) func.func_params;
        return = Option.value func.func_return_type ~default:ty_void;
        is_pure = func.func_is_pure;
      }
  in
  let is_existing_type name = state_has_type_name state name in
  effective_type_params_from_func_type ~is_existing_type func func_type

let effective_type_param_names params = Ast.type_param_names params

let checked_func_signature_of_func ?(module_path : string option)
    (state : check_state) (func : func_decl) : checked_func_signature option =
  match func.func_name with
  | None -> None
  | Some name ->
      let resolution_ctx = type_resolution_context state state.env in
      let resolve_signature_type ty =
        Type_resolution.annotation_canonical resolution_ctx
          ~qualify_owner:(qualify_imported_type_expr ~module_path)
          ty
      in
      let typed_params =
        List.filter (fun p -> Option.is_some p.param_type) func.func_params
      in
      let param_types =
        List.filter_map (fun p -> p.param_type) typed_params
        |> List.map resolve_signature_type
      in
      let param_names =
        List.map (fun (p : Ast.param) -> p.param_name) typed_params
      in
      let return_type =
        Option.value func.func_return_type ~default:ty_void
        |> resolve_signature_type
      in
      let raw_func_type =
        TyFunc
          {
            params = param_types;
            return = return_type;
            is_pure = func.func_is_pure;
          }
      in
      let effective_type_params =
        effective_type_params_from_func_type
          ~is_existing_type:(state_has_type_name state)
          func raw_func_type
      in
      let func_type =
        Types.instantiate_type_params
          (effective_type_param_names effective_type_params)
          raw_func_type
      in
      let origin = if func_is_foreign func then Foreign else UserDefined in
      let is_resource_param =
        match module_path with
        | Some module_path ->
            fun ty ->
              type_is_known_resource state ty
              || type_is_imported_resource_param state.env ~module_path ty
        | None -> type_is_known_resource state
      in
      Some
        {
          cfs_name = name;
          cfs_param_types = param_types;
          cfs_param_names = param_names;
          cfs_return_type = return_type;
          cfs_func_type = func_type;
          cfs_effective_type_params = effective_type_params;
          cfs_purity = (if func.func_is_pure then Pure else Impure);
          cfs_origin = origin;
          cfs_resource_args =
            resource_arg_policy_of_func func
              ~contains_resource_param:
                (List.exists is_resource_param param_types)
              ~contains_scoped_dependency_param:
                (List.exists
                   (type_is_scoped_dependency_carrier_in_env state.env)
                   param_types);
          cfs_module_path = module_path;
          cfs_dim_constraints = func.func_dim_constraints;
          cfs_loop_producer =
            loop_producer_of_registered_func ~module_path ~origin name;
          cfs_debug_only = func.func_debug_only;
        }

let checked_func_signature_of_imported_func ~(env : env) ~(module_path : string)
    (func : func_decl) : checked_func_signature option =
  match func.func_name with
  | None -> None
  | Some name ->
      let resolution_ctx =
        Type_resolution.make_context ~env ~module_aliases:[] ()
      in
      let resolve_signature_type ty =
        Type_resolution.imported_signature_canonical resolution_ctx
          ~qualify_owner:
            (qualify_imported_type_expr ~module_path:(Some module_path))
          ty
      in
      let typed_params =
        List.filter (fun p -> Option.is_some p.param_type) func.func_params
      in
      let param_types =
        List.filter_map (fun p -> p.param_type) typed_params
        |> List.map resolve_signature_type
      in
      let param_names =
        List.map (fun (p : Ast.param) -> p.param_name) typed_params
      in
      let return_type =
        Option.value func.func_return_type ~default:ty_void
        |> resolve_signature_type
      in
      let raw_func_type =
        TyFunc
          {
            params = param_types;
            return = return_type;
            is_pure = func.func_is_pure;
          }
      in
      let is_existing_type name = env_has_type_name env name in
      let effective_type_params =
        effective_type_params_from_func_type ~is_existing_type func
          raw_func_type
      in
      let func_type =
        Types.instantiate_type_params
          (effective_type_param_names effective_type_params)
          raw_func_type
      in
      let origin = if func_is_foreign func then Foreign else UserDefined in
      Some
        {
          cfs_name = name;
          cfs_param_types = param_types;
          cfs_param_names = param_names;
          cfs_return_type = return_type;
          cfs_func_type = func_type;
          cfs_effective_type_params = effective_type_params;
          cfs_purity = (if func.func_is_pure then Pure else Impure);
          cfs_origin = origin;
          cfs_resource_args =
            resource_arg_policy_of_func func
              ~contains_resource_param:
                (List.exists
                   (type_is_imported_resource_param env ~module_path)
                   param_types)
              ~contains_scoped_dependency_param:
                (List.exists
                   (type_is_scoped_dependency_carrier_in_env env)
                   param_types);
          cfs_module_path = Some module_path;
          cfs_dim_constraints = func.func_dim_constraints;
          cfs_loop_producer =
            loop_producer_of_registered_func ~module_path:(Some module_path)
              ~origin name;
          cfs_debug_only = func.func_debug_only;
        }

let overload_entry_of_checked_signature ?callable_id
    (sig_ : checked_func_signature) : overload_entry =
  {
    ol_def_id =
      Option.value callable_id
        ~default:(Session.mint_def_id (Session.current ()));
    ol_func_type = sig_.cfs_func_type;
    ol_type_params = sig_.cfs_effective_type_params;
    ol_param_names = sig_.cfs_param_names;
    ol_purity = sig_.cfs_purity;
    ol_origin = sig_.cfs_origin;
    ol_resource_args = sig_.cfs_resource_args;
    ol_module_path = sig_.cfs_module_path;
    ol_dim_constraints = sig_.cfs_dim_constraints;
    ol_loop_producer = sig_.cfs_loop_producer;
    ol_debug_only = sig_.cfs_debug_only;
  }

(** Forward ref for loading prelude UFCS methods — filled after first_pass is defined. *)
let load_prelude_ref : (env -> env) ref = ref (fun env -> env)

let effective_module_origin ?module_origin () =
  match module_origin with Some origin -> origin | None -> Session.User_module

let state_allows_builtin state =
  Session.module_origin_allows_builtin state.module_origin

let state_allows_foreign state =
  Session.module_origin_allows_foreign state.module_origin

let state_is_stdlib_module state =
  Session.module_origin_is_std state.module_origin

(** Initial state with builtins *)
let init_state ?module_origin ?(allow_debug_only_calls = false) () =
  let env = Env_builtins.with_builtins (empty ()) in
  let env = !load_prelude_ref env in
  let module_origin = effective_module_origin ?module_origin () in
  {
    env;
    errors = [];
    imported_names = [];
    module_aliases = [];
    imported_modules = [];
    import_bindings = [];
    module_origin;
    allow_debug_only_calls;
    private_impls = [];
    known_type_names = Hashtbl.create 16;
    known_resource_type_names = Hashtbl.create 16;
    top_level_names = Hashtbl.create 32;
    type_home = Hashtbl.create 32;
    func_callable_ids = Hashtbl.create 32;
  }

(** Add an error to the state *)
let add_error state err = { state with errors = err :: state.errors }

let check_removed_tensor_type_syntax state loc ty =
  match Types.removed_tensor_type_syntax_message ty with
  | Some msg -> add_error state (error_at loc msg)
  | None -> state

let check_removed_tensor_type_syntax_opt state loc = function
  | Some ty -> check_removed_tensor_type_syntax state loc ty
  | None -> state

let check_removed_tensor_param_syntax state (param : Ast.param) =
  check_removed_tensor_type_syntax_opt state param.param_loc param.param_type

let check_removed_tensor_func_syntax state loc (func : func_decl) =
  let state =
    List.fold_left check_removed_tensor_param_syntax state func.func_params
  in
  check_removed_tensor_type_syntax_opt state loc func.func_return_type

let rec check_removed_tensor_expr_syntax state (expr : Ast.expr) =
  let state =
    match expr.expr_desc with
    | EAscription (_, ty) ->
        check_removed_tensor_type_syntax state expr.expr_loc ty
    | EVarDecl (_, ty, _, _)
    | EQuestionBind (_, ty, _)
    | EConcurrentBind (_, ty, _) ->
        check_removed_tensor_type_syntax_opt state expr.expr_loc ty
    | EWith (binding, _) ->
        check_removed_tensor_type_syntax_opt state expr.expr_loc
          binding.with_type
    | ELambda func | EFuncDecl func ->
        check_removed_tensor_func_syntax state expr.expr_loc func
    | _ -> state
  in
  List.fold_left check_removed_tensor_expr_syntax state (expr_children expr)

let check_removed_tensor_trait_method_syntax state loc
    (method_ : Ast.trait_method) =
  let state =
    List.fold_left check_removed_tensor_param_syntax state method_.method_params
  in
  let state =
    check_removed_tensor_type_syntax_opt state loc method_.method_return_type
  in
  match method_.method_default_body with
  | Some body -> check_removed_tensor_expr_syntax state body
  | None -> state

let check_removed_tensor_impl_syntax state loc (impl : impl_decl) =
  let state = check_removed_tensor_type_syntax state loc impl.impl_for_type in
  List.fold_left
    (fun state func -> check_removed_tensor_func_syntax state loc func)
    state impl.impl_methods

let validate_type_param_name state loc raw =
  let name = Env.type_param_name raw in
  if Types.is_valid_named_type_param raw || Types.is_valid_dim_type_param raw
  then state
  else if Types.Dim.is_var_name name then
    add_error state
      (error_with ~notes:[]
         ~help:
           (Some
              "Use a dimension parameter like #N or #Rows. #_ is reserved for \
               wildcard dimensions.")
         loc
         (Printf.sprintf
            "Invalid dimension parameter '%s': Dimension parameters must use # \
             followed by a capital letter and contain only letters and digits"
            name))
  else
    add_error state
      (error_with ~notes:[]
         ~help:
           (Some
              "Use a generic name like T, Elem, or Item2. Use #N for dimension \
               parameters.")
         loc
         (Printf.sprintf
            "Invalid type parameter '%s': Generic type parameters must start \
             with a capital letter and contain only letters and digits"
            name))

let validate_type_param_names state loc params =
  List.fold_left
    (fun state raw -> validate_type_param_name state loc raw)
    state params

let validate_type_params state loc params =
  validate_type_param_names state loc (Ast.type_param_names params)

let module_alias_collision_message (state : check_state) ~(alias : string)
    ~(canonical_name : string) : string option =
  match List.assoc_opt alias state.module_aliases with
  | Some existing_mod when existing_mod <> canonical_name ->
      Some
        (Printf.sprintf "module alias '%s' already used for module '%s'" alias
           existing_mod)
  | Some _ -> None
  | None -> (
      match
        List.find_opt
          (fun binding -> binding.in_local_name = alias)
          state.imported_names
      with
      | Some binding ->
          Some
            (Printf.sprintf
               "module alias '%s' conflicts with '%s' already imported from \
                '%s'"
               alias alias
               (Filename.basename binding.in_module_path))
      | None -> (
          match Hashtbl.find_opt state.top_level_names alias with
          | Some kind ->
              Some
                (Printf.sprintf
                   "module alias '%s' conflicts with %s '%s' declared in this \
                    module"
                   alias kind alias)
          | None -> (
              match Env.lookup state.env alias with
              | Some
                  { Env.kind = Env.FuncSymbol { origin = Env.Builtin; _ }; _ }
                ->
                  Some
                    (Printf.sprintf
                       "module alias '%s' shadows a builtin function" alias)
              | Some sym ->
                  Some
                    (Printf.sprintf
                       "module alias '%s' conflicts with existing %s '%s'" alias
                       (Env.symbol_kind_label sym)
                       alias)
              | None -> None)))

let register_module_alias (state : check_state) (loc : loc) ~(alias : string)
    ~(canonical_name : string) : check_state =
  match module_alias_collision_message state ~alias ~canonical_name with
  | Some message -> add_error state (error_at loc message)
  | None ->
      let state =
        {
          state with
          module_aliases = (alias, canonical_name) :: state.module_aliases;
        }
      in
      add_import_binding state ~local_name:alias ~module_path:canonical_name
        ~original_name:None

let imported_name_collision_message (state : check_state) ~(local_name : string)
    ~(module_path : string) ~(original_name : string) : string option =
  match
    List.find_opt
      (fun binding -> binding.in_local_name = local_name)
      state.imported_names
  with
  | Some binding
    when binding.in_original_name = local_name
         && original_name = local_name
         && binding.in_module_path <> module_path ->
      Some
        (Printf.sprintf
           "Ambiguous import: '%s' is already imported from '%s'. Use an alias \
            to disambiguate: %s { %s as %s_%s }"
           local_name binding.in_module_path module_path original_name
           (Filename.basename module_path)
           original_name)
  | Some binding ->
      Some
        (Printf.sprintf
           "imported name '%s' is already imported from '%s'; use a distinct \
            alias"
           local_name
           (Filename.basename binding.in_module_path))
  | None -> (
      match List.assoc_opt local_name state.module_aliases with
      | Some existing_mod ->
          Some
            (Printf.sprintf
               "imported name '%s' is already used as module alias '%s' for \
                '%s'"
               local_name local_name
               (Filename.basename existing_mod))
      | None -> (
          match Hashtbl.find_opt state.top_level_names local_name with
          | Some kind ->
              Some
                (Printf.sprintf
                   "imported name '%s' conflicts with %s '%s' declared in this \
                    module"
                   local_name kind local_name)
          | None -> None))

let register_imported_name (state : check_state) (loc : loc)
    ~(local_name : string) ~(module_path : string) ~(original_name : string) :
    check_state * bool =
  match
    imported_name_collision_message state ~local_name ~module_path
      ~original_name
  with
  | Some message -> (add_error state (error_at loc message), false)
  | None ->
      let binding =
        {
          in_local_name = local_name;
          in_module_path = module_path;
          in_original_name = original_name;
        }
      in
      let state =
        { state with imported_names = binding :: state.imported_names }
      in
      ( add_import_binding state ~local_name ~module_path
          ~original_name:(Some original_name),
        true )

(* ============================================================================
   Declaration Processing - First Pass
   ============================================================================ *)

(** Process a type declaration, adding it and its constructors to env.

    [loc] is the source location of the declaration; when the loc
    carries a [loc_file] (set by the parser via [pos_fname]), we use
    it to register [type_name → module_path] in [state.type_home] for
    Phase 3.4's orphan-rule check. [imported] is passed through to
    [record_type_home] so a local [type T] overrides an earlier
    [import: m: T] but a later same-name re-import doesn't clobber
    a locally-declared [T]. *)
let process_type_decl ?(loc : loc option) ?(imported = false)
    (state : check_state) (decl : type_decl) : check_state =
  let decl_loc = Option.value loc ~default:dummy_loc in
  let state =
    List.fold_left
      (fun state (v : variant) ->
        List.fold_left
          (fun state field_ty ->
            match Types.removed_tensor_type_syntax_message field_ty with
            | Some msg -> add_error state (error_at v.variant_loc msg)
            | None -> state)
          state v.variant_fields)
      state decl.type_variants
  in
  let decl =
    {
      decl with
      type_variants =
        List.map
          (fun v ->
            {
              v with
              variant_fields =
                List.map (canonical_variant_field_type state) v.variant_fields;
            })
          decl.type_variants;
    }
  in
  let state = validate_type_params state decl_loc decl.type_params in
  (* Validate enum constraints *)
  let state =
    if decl.type_is_enum then begin
      let state =
        if decl.type_params <> [] then
          add_error state
            (error_at dummy_loc
               (Printf.sprintf "Enum '%s' cannot have type parameters"
                  decl.type_name))
        else state
      in
      List.fold_left
        (fun state (v : variant) ->
          if v.variant_fields <> [] then
            add_error state
              (error_at v.variant_loc
                 (Printf.sprintf
                    "Enum variant '%s' cannot have fields — use 'union' instead"
                    v.variant_name))
          else state)
        state decl.type_variants
    end
    else state
  in
  (* [type Name = builtin] and [resource type Name = builtin] are reserved for
     stdlib declarations. In user code the declaration would pass typechecking
     but the type has no representation — codegen skips emission, so the first
     use produces an opaque C-compile error. Reject up front. *)
  let state =
    if
      decl.type_is_builtin && (not (state_allows_builtin state)) && not imported
    then
      let syntax =
        if decl.type_is_resource then "resource type " ^ decl.type_name
        else "type " ^ decl.type_name
      in
      add_error state
        (error_with ~notes:[]
           ~help:
             (Some
                "Declare a concrete type with [union] or [record] instead, or \
                 wrap a foreign pointer with [record Name {...}] holding a \
                 [Ptr] field")
           dummy_loc
           (Printf.sprintf
              "'%s = builtin' can only be used in the standard library" syntax))
    else state
  in
  let state =
    if decl.type_is_builtin || decl.type_is_resource then state
    else
      List.fold_left
        (fun state (v : variant) ->
          List.fold_left
            (fun state field_ty ->
              let state =
                if type_contains_known_resource state field_ty then
                  add_error state
                    (resource_containing_aggregate_error v.variant_loc
                       (Printf.sprintf
                          "Union variant '%s' cannot contain a resource type"
                          v.variant_name))
                else state
              in
              if Infer.type_contains_one_shot_stream state.env field_ty then
                add_error state
                  (one_shot_stream_containing_aggregate_error v.variant_loc
                     (Printf.sprintf
                        "Union variant '%s' cannot contain a one-shot stream \
                         type"
                        v.variant_name))
              else state)
            state v.variant_fields)
        state decl.type_variants
  in
  (* Assign variant tags. [variant_def_id] is NOT minted here: the
     first pass stores variants in the env (where no downstream reader
     consults [variant_def_id]), and the AST decls are re-processed in
     [second_pass] where the canonical mint happens. Minting in both
     places would produce divergent DefIds between env and AST — the
     env would hold [Some N] and the AST would hold [Some M, M ≠ N]
     for the same source variant, and any future reader that consults
     both would see inconsistent identity. *)
  let variants =
    List.mapi (fun i v -> { v with variant_tag = i }) decl.type_variants
  in
  let type_kind =
    if decl.type_is_resource then TypeResource
    else if decl.type_is_builtin then TypeBuiltin
    else if decl.type_is_enum then TypeEnum
    else TypeUnion
  in
  let state =
    {
      state with
      env =
        add_type state.env decl.type_name
          (Ast.type_param_names decl.type_params)
          variants ~kind:type_kind;
    }
  in
  register_resource_cleanup_metadata decl;
  (* Register the owning module so the orphan-rule check can find the
     type's home. Stdlib primitives like [type Int = builtin] declared
     in std/int.brp land here via their decl's [loc_file]. *)
  let state =
    match Option.bind loc (fun l -> l.loc_file) with
    | Some m ->
        record_type_home ~imported state ~name:decl.type_name ~module_path:m
    | None -> state
  in
  (* Enums implicitly implement Stringable and Equatable (codegen handles this).
     Non-enum unions get Stringable only — users can add Equatable via explicit impl. *)
  let state =
    if decl.type_is_enum then
      (* Auto-registered for typecheck only: the actual [to_string] / [equals]
       functions for enums are synthesized by codegen, not by user source. *)
      let ty = TyNamed (decl.type_name, []) in
      let state =
        {
          state with
          env =
            add_impl state.env
              {
                ii_def_id = Session.mint_def_id (Session.current ());
                ii_trait = "Stringable";
                ii_for_type = ty;
                ii_bounds = [];
                ii_is_builtin = true;
                ii_loc = None;
              };
        }
      in
      {
        state with
        env =
          add_impl state.env
            {
              ii_def_id = Session.mint_def_id (Session.current ());
              ii_trait = "Equatable";
              ii_for_type = ty;
              ii_bounds = [];
              ii_is_builtin = true;
              ii_loc = None;
            };
      }
    else state
  in
  state

(** Process a record declaration *)
let process_record_decl ?(imported = false) (state : check_state)
    (decl : record_decl) (loc : loc) : check_state =
  let state = validate_type_params state loc decl.record_type_params in
  let state =
    List.fold_left
      (fun state (f : field_decl) ->
        match Types.removed_tensor_type_syntax_message f.field_type with
        | Some msg -> add_error state (error_at f.field_loc msg)
        | None -> state)
      state decl.record_fields
  in
  (* Builtin record declarations: restrict to std/ files, skip field validation.
     Skip the origin check for imported declarations (already validated in source module). *)
  if decl.record_is_builtin then begin
    let state =
      if (not (state_allows_builtin state)) && not imported then
        add_error state
          (error_with ~notes:[]
             ~help:
               (Some "Builtin types can only be defined in the standard library")
             loc
             (Printf.sprintf
                "'builtin' record '%s' can only be used in the standard library"
                decl.record_name))
      else state
    in
    let env =
      Env.add_symbol state.env
        {
          name = decl.record_name;
          kind =
            TypeSymbol
              {
                type_params = Ast.type_param_names decl.record_type_params;
                variants = [];
                type_kind = TypeBuiltin;
              };
        }
    in
    { state with env }
  end
  else
    let decl =
      {
        decl with
        record_fields =
          List.map
            (fun f ->
              {
                f with
                field_type = canonical_record_field_type state f.field_type;
              })
            decl.record_fields;
      }
    in
    let state =
      List.fold_left
        (fun state (f : field_decl) ->
          let kind = if decl.record_is_value then "Struct" else "Record" in
          let state =
            if type_contains_known_resource state f.field_type then
              add_error state
                (resource_containing_aggregate_error f.field_loc
                   (Printf.sprintf
                      "%s '%s' field '%s' cannot contain a resource type" kind
                      decl.record_name f.field_name))
            else state
          in
          if Infer.type_contains_one_shot_stream state.env f.field_type then
            add_error state
              (one_shot_stream_containing_aggregate_error f.field_loc
                 (Printf.sprintf
                    "%s '%s' field '%s' cannot contain a one-shot stream type"
                    kind decl.record_name f.field_name))
          else state)
        state decl.record_fields
    in
    (* Reject variadic dims in record field types — runtime-sized data should use List[T] *)
    let state =
      List.fold_left
        (fun state (f : field_decl) ->
          if Types.Dim.contains_vardims f.field_type then
            add_error state
              (error_with ~notes:[]
                 ~help:
                   (Some
                      (Printf.sprintf
                         "Use List[T] for runtime-sized data, or a concrete \
                          dimension like #N"))
                 loc
                 (Printf.sprintf
                    "Variadic dimensions (#N...) cannot appear in record field \
                     '%s' of '%s'"
                    f.field_name decl.record_name))
          else state)
        state decl.record_fields
    in
    (* Reject directly recursive record/struct types — infinite size at runtime.
       Heap-indirected wrappers provide the indirection that makes recursion safe. *)
    let state =
      let contains_type_directly name (f : field_decl) =
        match f.field_type with
        | TyNamed (n, _) when n = name -> true
        | TyNamed (wrapper, _)
          when Type_metadata.is_heap_indirected_name wrapper ->
            false
        | TyArray _ -> false
        | TyTuple ts ->
            List.exists
              (fun t ->
                match t with TyNamed (n, _) when n = name -> true | _ -> false)
              ts
        | _ -> false
      in
      if
        List.exists (contains_type_directly decl.record_name) decl.record_fields
      then
        add_error state
          (error_with ~notes:[]
             ~help:(Some "Use Option[T] or List[T] for indirect recursion") loc
             (Printf.sprintf
                "Type '%s' is directly recursive — this would require infinite \
                 memory"
                decl.record_name))
      else state
    in
    (* Validate struct field types: only primitives and other structs allowed.
     Skip for imported structs — they were already validated in their source module,
     and the importing env may not have all referenced struct types registered yet. *)
    let state =
      if decl.record_is_value && not imported then begin
        let state =
          if decl.record_type_params <> [] then
            add_error state
              (error_at loc
                 (Printf.sprintf "Struct '%s' cannot have type parameters"
                    decl.record_name))
          else state
        in
        let state =
          if decl.record_fields = [] then
            add_error state
              (error_at loc
                 (Printf.sprintf "Struct '%s' must have at least one field"
                    decl.record_name))
          else state
        in
        let is_valid_struct_field_type ty =
          Type_metadata.is_struct_scalar_field_type ty
          ||
          match ty with
          | TyNamed (name, []) -> is_value_record state.env name
          | _ -> false
        in
        List.fold_left
          (fun state (f : field_decl) ->
            if not (is_valid_struct_field_type f.field_type) then
              add_error state
                (error_at loc
                   (Printf.sprintf
                      "Struct '%s' field '%s' has invalid type: struct fields \
                       must be primitive types (Int, Float, Bool, Char) or \
                       other structs"
                      decl.record_name f.field_name))
            else state)
          state decl.record_fields
      end
      else state
    in
    let state =
      {
        state with
        env =
          add_record state.env decl.record_name
            (Ast.type_param_names decl.record_type_params)
            decl.record_fields ~is_value:decl.record_is_value ();
      }
    in
    (* Register owning module for Phase 3.4's orphan-rule check. *)
    match loc.loc_file with
    | Some m ->
        record_type_home ~imported state ~name:decl.record_name ~module_path:m
    | None -> state

(** Process a type alias declaration *)
let process_type_alias ?(loc = dummy_loc) (state : check_state)
    (decl : type_alias_decl) : check_state =
  let state = validate_type_params state loc decl.alias_type_params in
  let state =
    match Types.removed_tensor_type_syntax_message decl.alias_target with
    | Some msg -> add_error state (error_at loc msg)
    | None -> state
  in
  let decl =
    {
      decl with
      alias_target = canonical_type_alias_target state decl.alias_target;
    }
  in
  {
    state with
    env =
      add_alias state.env decl.alias_name
        (Ast.type_param_names decl.alias_type_params)
        decl.alias_target;
  }

let validate_default_foreign_arg_safety loc (state : check_state)
    (sig_ : checked_func_signature) (func : func_decl) : check_state =
  if sig_.cfs_origin <> Foreign || func.func_is_pure || func.func_no_copy then
    state
  else
    let metadata = Ffi_boundary.metadata_for_env state.env in
    let rec fold index names types state =
      match (names, types) with
      | name :: rest_names, ty :: rest_types ->
          let state =
            match
              Ffi_boundary.classify_arg ~metadata
                ~mode:Ffi_boundary.DefaultCopyMode ty
            with
            | Ffi_boundary.RejectedDefault _ ->
                let param =
                  match name with
                  | Some n -> Printf.sprintf "parameter '%s'" n
                  | None -> Printf.sprintf "parameter %d" (index + 1)
                in
                add_error state
                  (error_with loc
                     (Printf.sprintf
                        "Foreign function '%s' cannot defensively copy %s of \
                         type %s in default foreign mode"
                        sig_.cfs_name param (type_to_string ty))
                     ~notes:
                       [
                         "Default foreign functions copy String and Bytes \
                          arguments before C sees them.";
                         "Other managed values would currently be borrowed \
                          implicitly, which makes mutation safety unclear.";
                       ]
                     ~help:
                       (Some
                          "Use @no_copy if the C function only borrows the \
                           value, mark the foreign function pure if it has no \
                           side effects and does not mutate arguments, or \
                           change the boundary to String, Bytes, or scalar \
                           parameters."))
            | Ffi_boundary.ScalarByValue | Ffi_boundary.DefensiveCopy _
            | Ffi_boundary.ExplicitBorrow ->
                state
          in
          fold (index + 1) rest_names rest_types state
      | _ -> state
    in
    fold 0 sig_.cfs_param_names sig_.cfs_param_types state

let validate_foreign_metadata loc (state : check_state)
    (sig_ : checked_func_signature) (func : func_decl) : check_state =
  if sig_.cfs_origin <> Foreign then state
  else
    match func.func_body with
    | FuncForeign foreign ->
        Ffi_boundary.validate_metadata foreign
        |> List.fold_left
             (fun state err ->
               add_error state
                 (error_with loc
                    (Ffi_boundary.metadata_validation_error_to_string err)
                    ~notes:
                      [
                        "foreign metadata is emitted near C code, so Blorp \
                         accepts only narrow, structured forms here.";
                      ]
                    ~help:
                      (Some
                         "Use a plain C identifier for the target function and \
                          a source-relative header path such as \
                          \"sqlite_ffi.h\".")))
             state
    | _ -> state

let validate_resource_result_annotation loc (state : check_state)
    (func : func_decl) (sig_ : checked_func_signature) : check_state =
  if not func.func_resource_result_ordinary then state
  else if not (func_has_builtin_body func) then
    add_error state
      (error_with loc
         "@resource_result_ordinary can only be used on builtin resource \
          operation declarations"
         ~notes:
           [
             "The annotation is compiler metadata for operations that borrow a \
              scoped resource and return ordinary data.";
           ]
         ~help:
           (Some
              "Remove the annotation from source or foreign functions. Source \
               functions with `borrow` parameters already return ordinary \
               values when their bodies type-check."))
  else if
    type_contains_known_resource state sig_.cfs_return_type
    || type_contains_scoped_dependency_carrier state.env sig_.cfs_return_type
  then
    add_error state
      (error_with loc
         "@resource_result_ordinary cannot be used on a builtin that returns a \
          resource-dependent value"
         ~notes:
           [
             "The annotation tells scoped-resource analysis that the result no \
              longer depends on the borrowed resource.";
             "Returning a resource, stream, cursor, or value that contains one \
              would erase a scoped lifetime and let that value escape cleanup.";
           ]
         ~help:
           (Some
              "Remove the annotation from carrier-producing builtins. Only \
               terminal operations that return ordinary data should use \
               @resource_result_ordinary."))
  else
    match sig_.cfs_resource_args with
    | AllowResourceArgs _ -> state
    | RejectResourceArgs ->
        add_error state
          (error_with loc
             "@resource_result_ordinary requires a builtin operation with a \
              direct resource parameter"
             ~notes:
               [
                 "The annotation describes the result of a compiler-owned \
                  operation that borrows a scoped resource. Without a resource \
                  parameter directly in the function signature, there is no \
                  resource dependency to classify.";
               ]
             ~help:
               (Some
                  "Remove the annotation, or add it only to builtin operations \
                   whose parameters directly borrow a resource type."))

let resource_signature_boundary_error loc message =
  error_with
    ~notes:
      [
        "Ordinary function parameters and return values use value semantics. \
         Copying a resource would duplicate cleanup ownership.";
        "A source function may borrow a scoped resource only by declaring an \
         explicit `borrow` parameter, and the type checker verifies that \
         nothing resource-dependent escapes the call.";
      ]
    ~help:
      (Some
         "Keep resources inside a `with` block, or add an explicit builtin \
          resource operation only when the compiler/runtime owns the cleanup \
          contract. Source helpers that need a scoped handle should use \
          `param: borrow ResourceType`.")
    loc message

let borrowed_resource_param_error loc message =
  error_with
    ~notes:
      [
        "Borrowed resource parameters do not own cleanup. They can only use \
         the scoped resource for the duration of the current call.";
        "The function body must be visible to the type checker so it can \
         reject returning, storing, or spawning work that depends on the \
         borrowed resource.";
      ]
    ~help:
      (Some
         "Use `with handle = ...:` at the call site and declare helpers as \
          `func helper(handle: borrow ResourceType) -> OrdinaryType:`.")
    loc message

let validate_resource_signature_boundary loc (state : check_state)
    (func : func_decl) (sig_ : checked_func_signature) : check_state =
  let typed_params : Ast.param list =
    List.filter (fun p -> Option.is_some p.param_type) func.func_params
  in
  let param_pairs = List.combine typed_params sig_.cfs_param_types in
  let state =
    List.fold_left
      (fun state ((param : Ast.param), param_ty) ->
        if param_is_borrowed param then
          let param_name = Option.value param.param_name ~default:"_" in
          let state =
            match func.func_body with
            | FuncBodyExpr _ -> state
            | FuncBuiltinBody _ | FuncForeign _ | FuncNoBody ->
                add_error state
                  (borrowed_resource_param_error param.param_loc
                     "borrowed resource parameters require a function body")
          in
          if type_is_known_resource state param_ty then state
          else
            add_error state
              (borrowed_resource_param_error param.param_loc
                 (Printf.sprintf
                    "borrow parameter '%s' must have a direct resource type"
                    param_name))
        else state)
      state param_pairs
  in
  if func_has_builtin_body func then state
  else
    let state =
      List.fold_left
        (fun state ((param : Ast.param), param_ty) ->
          if
            (not (param_is_borrowed param))
            && type_contains_known_resource state param_ty
          then
            let param_name = Option.value param.param_name ~default:"_" in
            add_error state
              (resource_signature_boundary_error param.param_loc
                 (Printf.sprintf
                    "Function '%s' parameter '%s' cannot contain a resource \
                     type"
                    sig_.cfs_name param_name))
          else state)
        state param_pairs
    in
    if type_contains_known_resource state sig_.cfs_return_type then
      add_error state
        (resource_signature_boundary_error loc
           (Printf.sprintf
              "Function '%s' return type cannot contain a resource type"
              sig_.cfs_name))
    else state

let register_imported_resource_signature_types ~(module_path : string option)
    (state : check_state) (sig_ : checked_func_signature) : check_state =
  match module_path with
  | None -> state
  | Some module_path ->
      let resource_params_by_name =
        module_decls_for_type_metadata module_path
        |> module_resource_types_from_decls
        |> List.map (fun metadata ->
            ( Types.canonical_module_type_name ~module_path metadata.mrt_name,
              metadata ))
      in
      let resource_metadata name =
        List.assoc_opt name resource_params_by_name
      in
      let rec type_names acc ty =
        match Types.head_resolve ty with
        | TyNamed (name, args) -> List.fold_left type_names (name :: acc) args
        | TyTuple elems -> List.fold_left type_names acc elems
        | TyFunc { params; return; _ } ->
            List.fold_left type_names (type_names acc return) params
        | TyRange inner -> type_names acc inner
        | TyArray (elem, dims) ->
            List.fold_left type_names (type_names acc elem) dims
        | TyDimOp (_, left, right) -> type_names (type_names acc left) right
        | TyVar _ | TyBoundVar _ | TyConstInt _ | TySelf | TyVarDims _
        | TyMeta _ ->
            acc
      in
      let names =
        List.fold_left type_names []
          (sig_.cfs_return_type :: sig_.cfs_param_types)
        |> List.sort_uniq String.compare
      in
      let env =
        List.fold_left
          (fun env name ->
            match resource_metadata name with
            | None -> env
            | Some metadata when Env.get_type_kind env name = Some TypeResource
              ->
                Option.iter
                  (Session.register_resource_cleanup (Session.current ())
                     ~type_name:name)
                  metadata.mrt_cleanup;
                env
            | Some metadata ->
                Option.iter
                  (Session.register_resource_cleanup (Session.current ())
                     ~type_name:name)
                  metadata.mrt_cleanup;
                Env.add_type ~with_ctors:false ~kind:TypeResource env name
                  metadata.mrt_type_params [])
          state.env names
      in
      { state with env }

(** Process a function declaration - first pass (add signature only) *)
let process_func_signature ?(module_path : string option) ?(loc = dummy_loc)
    (state : check_state) (func : func_decl) : check_state =
  let state = validate_type_params state loc func.func_type_params in
  match checked_func_signature_of_func ?module_path state func with
  | None -> state (* Lambda, not a top-level function *)
  | Some sig_ ->
      let state =
        register_imported_resource_signature_types ~module_path state sig_
      in
      let state = validate_resource_result_annotation loc state func sig_ in
      let state = validate_resource_signature_boundary loc state func sig_ in
      let callable_id =
        record_func_callable_id state ~name:sig_.cfs_name ~loc
      in
      (* Foreign functions cannot RETURN refinement types (TyRange, LiteralString)
         because the compiler cannot verify that C code respects the invariants.
         Receiving them as parameters is fine — they erase to plain C types. *)
      let state =
        if sig_.cfs_origin = Foreign then
          let has_range ty =
            let found = ref false in
            ignore
              (Types.map_type_expr
                 (function
                   | TyRange _ ->
                       found := true;
                       None
                   | _ -> None)
                 ty);
            !found
          in
          let has_literal_string ty =
            let found = ref false in
            ignore
              (Types.map_type_expr
                 (function
                   | TyNamed ("LiteralString", []) ->
                       found := true;
                       None
                   | _ -> None)
                 ty);
            !found
          in
          if has_range sig_.cfs_return_type then
            add_error state
              (error_at dummy_loc
                 (Printf.sprintf
                    "Foreign function '%s' cannot return range types (..#N) — \
                     the compiler cannot verify C code respects bounds \
                     invariants"
                    sig_.cfs_name))
          else if has_literal_string sig_.cfs_return_type then
            add_error state
              (error_at dummy_loc
                 (Printf.sprintf
                    "Foreign function '%s' cannot return LiteralString — use \
                     String instead"
                    sig_.cfs_name))
          else state
        else state
      in
      let state = validate_foreign_metadata loc state sig_ func in
      let state = validate_default_foreign_arg_safety loc state sig_ func in
      (* When importing a function that has the same name as a polymorphic builtin,
         don't overwrite the builtin in scope — just add as an overload entry.
         A builtin is "polymorphic" if its first parameter is a bare type variable (TyVar),
         meaning it accepts any type. Examples: to_string, length, equals,
         to_int, bit_and.
         This prevents `import: list: to_string` from narrowing the builtin to only
         work on List[T]. Non-polymorphic builtins like send (first param Channel[T])
         CAN be shadowed by imports since they have specific param types. *)
      let is_polymorphic_builtin_import =
        module_path <> None
        && Env.is_builtin_func state.env sig_.cfs_name
        &&
        match Env.get_func_info state.env sig_.cfs_name with
        | Some (TyFunc { params = TyVar _ :: _; _ }, _, _) -> true
        | _ -> false
      in
      let env =
        if is_polymorphic_builtin_import then
          state.env (* keep the builtin in scope *)
        else
          add_func state.env sig_.cfs_name sig_.cfs_func_type ~callable_id
            ~type_params:sig_.cfs_effective_type_params
            ~param_names:sig_.cfs_param_names ~purity:sig_.cfs_purity
            ~origin:sig_.cfs_origin ~resource_args:sig_.cfs_resource_args
            ?module_path ~dim_constraints:sig_.cfs_dim_constraints
            ?loop_producer:sig_.cfs_loop_producer
            ~debug_only:sig_.cfs_debug_only ()
      in
      (* Register overload entry when importing from a module *)
      let env =
        match module_path with
        | Some _ ->
            add_overload env sig_.cfs_name
              (overload_entry_of_checked_signature ~callable_id sig_)
        | None -> env
      in
      { state with env }

(** Process a variable declaration *)
let process_var_decl (state : check_state) (decl : var_decl) : check_state =
  match decl.var_name with
  | None -> state
  | Some name ->
      let source_type =
        Option.map
          (fun source_ty ->
            let ctx = type_resolution_context state state.env in
            Type_resolution.local_binding_annotation ctx source_ty
            |> Type_resolution.source)
          decl.var_type
      in
      let var_type =
        match decl.var_type with
        | Some ty -> canonical_type_annotation state ty
        | None -> (
            (* Infer type from value *)
            let ctx = ctx_of_state state in
            match infer_expr ctx decl.var_value with
            | Ok (ty, _) ->
                inferred_binding_type ~is_mutable:decl.var_is_mutable ty
            | Error _ -> ty_void (* Will be caught in second pass *))
      in
      {
        state with
        env =
          add_var state.env name var_type ?source_type
            ~mutability:(if decl.var_is_mutable then Mutable else Immutable)
            ();
      }

let add_imported_type_alias ~(module_path : string option) state
    ~(alias : string) ~(original_name : string) ~(type_params : string list) =
  match module_path with
  | None -> state
  | Some module_path ->
      let target_name =
        Types.canonical_module_type_name ~module_path original_name
      in
      if alias = target_name then state
      else
        let args =
          List.map (fun p -> TyVar (Env.type_param_name p)) type_params
        in
        let target = TyNamed (target_name, args) in
        { state with env = add_alias state.env alias type_params target }

let canonical_imported_type_name ~(module_path : string option) name =
  match module_path with
  | None -> name
  | Some module_path -> Types.canonical_module_type_name ~module_path name

let register_qualified_import_resource_types ~(module_path : string)
    (state : check_state) exports : check_state =
  List.fold_left
    (fun state (_export_name, decl) ->
      match decl.decl_desc with
      | DType type_decl when type_decl.type_is_resource ->
          let canonical_name =
            canonical_imported_type_name ~module_path:(Some module_path)
              type_decl.type_name
          in
          if Env.get_type_kind state.env canonical_name = Some TypeResource then
            state
          else
            let type_decl = { type_decl with type_name = canonical_name } in
            process_type_decl ~loc:decl.decl_loc ~imported:true state type_decl
      | _ -> state)
    state exports

let process_imported_type_decl ?alias ~(module_path : string option) state
    (decl : type_decl) (loc : loc) : check_state =
  let original_name = decl.type_name in
  let canonical_name =
    canonical_imported_type_name ~module_path original_name
  in
  let decl =
    {
      decl with
      type_name = canonical_name;
      type_variants =
        List.map
          (fun v ->
            {
              v with
              variant_fields =
                List.map
                  (qualify_imported_type_expr ~module_path)
                  v.variant_fields;
            })
          decl.type_variants;
    }
  in
  let state = process_type_decl ~loc ~imported:true state decl in
  let alias = Option.value alias ~default:original_name in
  add_imported_type_alias ~module_path state ~alias ~original_name
    ~type_params:(Ast.type_param_names decl.type_params)

let process_imported_record_decl ?alias ~(module_path : string option) state
    (decl : record_decl) (loc : loc) : check_state =
  let original_name = decl.record_name in
  let canonical_name =
    canonical_imported_type_name ~module_path original_name
  in
  let decl =
    {
      decl with
      record_name = canonical_name;
      record_fields =
        List.map
          (fun f ->
            {
              f with
              field_type = qualify_imported_type_expr ~module_path f.field_type;
            })
          decl.record_fields;
    }
  in
  let state = process_record_decl ~imported:true state decl loc in
  let alias = Option.value alias ~default:original_name in
  add_imported_type_alias ~module_path state ~alias ~original_name
    ~type_params:(Ast.type_param_names decl.record_type_params)

let process_imported_type_alias_decl ?alias ~(module_path : string option) state
    (decl : type_alias_decl) (loc : loc) : check_state =
  match module_path with
  | None ->
      let decl =
        match alias with
        | None -> decl
        | Some alias -> { decl with alias_name = alias }
      in
      process_type_alias ~loc state decl
  | Some _ ->
      let original_name = decl.alias_name in
      let canonical_name =
        canonical_imported_type_name ~module_path original_name
      in
      let canonical_decl =
        {
          decl with
          alias_name = canonical_name;
          alias_target =
            qualify_imported_type_expr ~module_path decl.alias_target;
        }
      in
      let state = process_type_alias ~loc state canonical_decl in
      let alias = Option.value alias ~default:original_name in
      add_imported_type_alias ~module_path state ~alias ~original_name
        ~type_params:(Ast.type_param_names decl.alias_type_params)

(** Process an imported declaration to add it to the environment *)
let rec process_imported_decl ~(module_path : string option) state decl =
  match decl.decl_desc with
  | DPrivate inner -> process_imported_decl ~module_path state inner
  | DType type_decl ->
      process_imported_type_decl ~module_path state type_decl decl.decl_loc
  | DRecord record_decl ->
      process_imported_record_decl ~module_path state record_decl decl.decl_loc
  | DTypeAlias alias_decl ->
      process_imported_type_alias_decl ~module_path state alias_decl
        decl.decl_loc
  | DFunc func_decl ->
      process_func_signature ?module_path ~loc:decl.decl_loc state func_decl
  | DVar var_decl -> process_var_decl state var_decl
  | DImpl impl ->
      List.fold_left
        (fun state func ->
          process_func_signature ?module_path ~loc:decl.decl_loc state func)
        state impl.impl_methods
  | _ -> state

(** Process an imported declaration with an alias *)
and process_imported_decl_as ~(module_path : string option) state decl alias =
  match decl.decl_desc with
  | DPrivate inner -> process_imported_decl_as ~module_path state inner alias
  | DFunc func_decl ->
      let renamed = { func_decl with func_name = Some alias } in
      process_func_signature ?module_path ~loc:decl.decl_loc state renamed
  | DType type_decl ->
      process_imported_type_decl ~alias ~module_path state type_decl
        decl.decl_loc
  | DRecord record_decl ->
      process_imported_record_decl ~alias ~module_path state record_decl
        decl.decl_loc
  | DTypeAlias alias_decl ->
      process_imported_type_alias_decl ~alias ~module_path state alias_decl
        decl.decl_loc
  | DVar var_decl ->
      let renamed = { var_decl with var_name = Some alias } in
      process_var_decl state renamed
  | DTrait _ ->
      add_error state
        (error_at decl.decl_loc
           "trait imports cannot be aliased yet; import the trait or method by \
            its original name")
  | _ -> process_imported_decl ~module_path state decl

(* Extract inline bounds from structured bound type-variable nodes. Walks
   [TyNamed] args and [TyTuple] elements — both are declaration sites where
   bounded type vars can appear ([Option[T: Eq]] / [(A: Eq, B: Eq)]). *)
let rec extract_inline_bounds ty =
  let from_child child =
    match child with
    | TyBoundVar param -> [ param ]
    | TyNamed _ | TyTuple _ -> extract_inline_bounds child
    | _ -> []
  in
  match ty with
  | TyNamed (_, args) -> List.concat_map from_child args
  | TyTuple elems -> List.concat_map from_child elems
  | _ -> []

let default_impl_bound_env () = Env_builtins.with_builtins (empty ())

let rec collect_impl_type_param_candidates ?(allow_bare = true) ty =
  match ty with
  | TyVar v -> [ v ]
  | TyBoundVar p -> [ p.param_name ]
  | TyVarDims v -> [ v ]
  | TyNamed (name, [])
    when allow_bare
         && (Types.is_valid_named_type_param name
            || Types.is_valid_dim_type_param name) ->
      [ Env.type_param_name name ]
  | TyNamed (_, args) ->
      List.concat_map (collect_impl_type_param_candidates ~allow_bare:true) args
  | TyArray (elem, dims) ->
      collect_impl_type_param_candidates ~allow_bare:true elem
      @ List.concat_map
          (collect_impl_type_param_candidates ~allow_bare:true)
          dims
  | TyTuple elems ->
      List.concat_map
        (collect_impl_type_param_candidates ~allow_bare:true)
        elems
  | TyFunc { params; return; _ } ->
      List.concat_map
        (collect_impl_type_param_candidates ~allow_bare:true)
        params
      @ collect_impl_type_param_candidates ~allow_bare:true return
  | TyRange inner -> collect_impl_type_param_candidates ~allow_bare:true inner
  | TyDimOp (_, a, b) ->
      collect_impl_type_param_candidates ~allow_bare:true a
      @ collect_impl_type_param_candidates ~allow_bare:true b
  | _ -> []

let impl_bounds_for_type ?env ty =
  let env = Option.value env ~default:(default_impl_bound_env ()) in
  let explicit = extract_inline_bounds ty in
  let explicit_names = Generic_params.param_names explicit in
  let implicit =
    collect_impl_type_param_candidates ~allow_bare:false ty
    |> Env.type_param_names
    |> List.sort_uniq String.compare
    |> List.filter (fun name ->
        name <> "#_"
        && (not (String.length name > 0 && name.[0] = '#'))
        && (not (List.mem name explicit_names))
        && not (env_has_type_name env name))
    |> List.map (fun name -> Generic_params.make_bound_type_param name [])
  in
  explicit @ implicit

let validate_impl_inline_type_params state loc impl =
  extract_inline_bounds impl.impl_for_type
  |> Generic_params.param_names
  |> validate_type_param_names state loc

let make_impl_instance ?(loc : loc option) ?env impl =
  let bounds = impl_bounds_for_type ?env impl.impl_for_type in
  {
    ii_def_id = Session.mint_def_id (Session.current ());
    ii_trait = impl.impl_trait;
    ii_for_type = impl.impl_for_type;
    ii_bounds = bounds;
    ii_is_builtin = false;
    ii_loc = loc;
  }

(** Describe an impl instance for error messages: ["trait T for Type"].
    Qualifies [T] with its home module via [Env.format_trait_name] so
    coherence errors disambiguate which trait is meant when multiple
    modules define traits of the same name. Track B. *)
let describe_impl (env : Env.env) (ii : Env.impl_instance) : string =
  Printf.sprintf "'%s' for type '%s'"
    (Env.format_trait_name env ii.ii_trait)
    (Types.type_to_string ii.ii_for_type)

(** Build the coherence-conflict diagnostic citing the prior impl's source
    location when available. *)
let build_conflict_error (env : Env.env) (loc : loc)
    ~(candidate : Env.impl_instance) ~(existing : Env.impl_instance) :
    compiler_error =
  let prior_note =
    match existing.ii_loc with
    | Some prior_loc ->
        let at =
          match prior_loc.loc_file with
          | Some f ->
              Printf.sprintf "%s:%d:%d" f prior_loc.line prior_loc.column
          | None -> Printf.sprintf "L%d:%d" prior_loc.line prior_loc.column
        in
        Printf.sprintf "previously implemented as %s at %s"
          (describe_impl env existing)
          at
    | None ->
        Printf.sprintf "previously implemented as %s"
          (describe_impl env existing)
  in
  error_with ~notes:[ prior_note ]
    ~help:
      (Some "Remove or narrow one of the implementations so they don't overlap")
    loc
    (Printf.sprintf "conflicting implementation of trait %s"
       (describe_impl env candidate))

let same_std_source_module (a : loc) (b : loc) : bool =
  let is_embedded_std file =
    let prefix = "<embedded:std/" in
    String.length file >= String.length prefix
    && String.sub file 0 (String.length prefix) = prefix
  in
  match (a.loc_file, b.loc_file) with
  | Some a_file, Some b_file
    when is_embedded_std a_file <> is_embedded_std b_file -> (
      match
        ( Modules.std_module_name_for_source_file a_file,
          Modules.std_module_name_for_source_file b_file )
      with
      | Some a_mod, Some b_mod -> a_mod = b_mod
      | _ -> false)
  | _ -> false

(** Attempt to register a source-level impl, emitting a coherence error if
    another source-level impl already covers an overlapping (trait, for-type)
    pair. Returns [(state, registered)] — [registered] is [false] when the
    impl was rejected, so the caller can skip method processing that would
    depend on the impl being in the index. *)
let try_add_source_impl (state : check_state) (loc : loc)
    (ii : Env.impl_instance) : check_state * bool =
  match find_conflicting_impl state.env ii with
  | None -> ({ state with env = add_impl state.env ii }, true)
  | Some existing
    when match existing.ii_loc with
         | Some prior_loc -> same_std_source_module loc prior_loc
         | None -> false ->
      (state, true)
  | Some existing ->
      ( add_error state
          (build_conflict_error state.env loc ~candidate:ii ~existing),
        false )

(** Does [cand] overlap with [existing] (same trait + unifiable for-types)?
    Pulled out of [Env.find_conflicting_impl] so we can reuse the logic
    against ad-hoc lists (e.g. [state.private_impls]) without going
    through [env.impls]. *)
let impls_overlap (cand : Env.impl_instance) (existing : Env.impl_instance) :
    bool =
  if cand.ii_is_builtin || existing.ii_is_builtin then false
  else if cand.ii_trait <> existing.ii_trait then false
  else
    let cp = Generic_params.param_names cand.ii_bounds in
    let ep = Generic_params.param_names existing.ii_bounds in
    Types.types_bidirectional ~type_params:(cp @ ep) existing.ii_for_type
      cand.ii_for_type

(** Track a private impl: it does NOT enter [env.impls] / [env.impl_index]
    (private impls can't satisfy trait bounds for other modules), but DOES
    emit a C symbol, so two private impls of the same (trait, for-type)
    collide at link. This helper checks against already-registered public
    impls AND previously-seen private impls in the same compilation unit. *)
let try_add_private_impl (state : check_state) (loc : loc)
    (ii : Env.impl_instance) : check_state =
  let public_conflict = find_conflicting_impl state.env ii in
  let private_conflict = List.find_opt (impls_overlap ii) state.private_impls in
  match (public_conflict, private_conflict) with
  | None, None -> { state with private_impls = ii :: state.private_impls }
  | Some existing, _ | None, Some existing ->
      add_error state
        (build_conflict_error state.env loc ~candidate:ii ~existing)

(** Register trait impls from a module's declarations *)
let register_module_impls ~(module_path : string) (state : check_state)
    (decls : program) : check_state =
  let local_type_names = module_local_type_names_from_decls decls in
  let qualify_impl impl =
    {
      impl with
      impl_for_type =
        Types.qualify_module_local_types ~module_path local_type_names
          impl.impl_for_type;
    }
  in
  List.fold_left
    (fun state decl ->
      let impl_opt =
        match decl.decl_desc with
        | DPrivate _ -> None
        | DImpl impl -> Some (qualify_impl impl)
        | _ -> None
      in
      match impl_opt with
      | Some impl ->
          let state, _ =
            try_add_source_impl state decl.decl_loc
              (make_impl_instance ~loc:decl.decl_loc ~env:state.env impl)
          in
          state
      | _ -> state)
    state decls

(** The orphan rule (Phase 3.4): an [impl T for U] may appear only in:

    - the module that declares the trait [T], OR
    - the module that declares the type [U], OR
    - for stdlib primitive types, the primitive's home (e.g. `std/int`
      for [Int]) or `std/traits` (the trait-owning module for the
      primitive-numeric trait hierarchy).

    This keeps dispatch predictable across the module graph: two
    modules can't both implement `Stringable for List[Int]` without
    the user having to know which one won. A user who wants to add
    behavior to a foreign type wraps it in a local record ("newtype").

    Returns [None] (no error) when orphan cannot be determined —
    missing module info shouldn't spuriously reject an otherwise
    well-formed impl.

    [canonical_module_path] below normalizes four input shapes —
    `<embedded:std/foo>`, absolute paths, relative paths, and
    `.brp`-suffixed paths — to bare module identifiers so stdlib and
    user sites compare equal regardless of how the file got loaded
    (embedded table or an explicit filesystem std override). *)
let canonical_module_path (s : string) : string =
  let s =
    if
      String.length s > 11
      && String.sub s 0 10 = "<embedded:"
      && s.[String.length s - 1] = '>'
    then String.sub s 10 (String.length s - 11)
    else s
  in
  (* Drop the [.brp] extension so file-based paths match the bare
     module-path form used by [Type_metadata.primitive_home]. *)
  let s =
    if Filename.check_suffix s ".brp" then Filename.chop_suffix s ".brp" else s
  in
  (* Strip path prefixes so `/abs/path/to/std/int` and `./std/int`
     both normalize to `std/int`. We look for a [std/] or [tests/]
     root segment and take from there. A path that contains neither
     root (a user file outside the standard trees) keeps its tail
     after a leading [./] strip — the orphan check only needs
     self-equality for those, not canonical form. *)
  let take_from_root segment s =
    let sep_prefix = "/" ^ segment ^ "/" in
    let plen = String.length sep_prefix in
    let slen = String.length s in
    let rec scan i =
      if i + plen > slen then None
      else if String.sub s i plen = sep_prefix then
        Some (String.sub s (i + 1) (slen - i - 1))
      else scan (i + 1)
    in
    (* Handle leading [segment/] (no preceding slash) by rewriting
       via a virtual `/` prefix and reusing the scanner. *)
    let with_virtual_slash = "/" ^ s in
    scan 0 |> function
    | Some _ as r -> r
    | None ->
        let prefix = segment ^ "/" in
        if
          String.length s >= String.length prefix
          && String.sub s 0 (String.length prefix) = prefix
        then Some s
        else
          (* Check the [./segment/] form. *)
          let rec scan2 i =
            let slen' = String.length with_virtual_slash in
            if i + plen > slen' then None
            else if String.sub with_virtual_slash i plen = sep_prefix then
              Some (String.sub with_virtual_slash (i + 1) (slen' - i - 1))
            else scan2 (i + 1)
          in
          scan2 0
  in
  match take_from_root "std" s with
  | Some rest -> rest
  | None -> (
      match take_from_root "tests" s with
      | Some rest -> rest
      | None ->
          (* Neither standard tree: strip a leading [./] if present. *)
          if String.length s >= 2 && String.sub s 0 2 = "./" then
            String.sub s 2 (String.length s - 2)
          else s)

let check_orphan (state : check_state) (impl : Ast.impl_decl) (loc : Ast.loc) :
    Ast.compiler_error option =
  match loc.loc_file with
  | None -> None (* No source location → can't check *)
  | Some impl_mod_raw ->
      let impl_mod = canonical_module_path impl_mod_raw in
      let canon_opt = Option.map canonical_module_path in
      let trait_mod_opt =
        canon_opt
          (Option.bind (Env.get_trait state.env impl.impl_trait) (fun t ->
               Option.bind t.td_loc (fun l -> l.loc_file)))
      in
      let type_head =
        match Codegen_types.normalize_type impl.impl_for_type with
        | Ast.TyNamed (n, _) -> Some n
        | _ -> None
      in
      let type_mod_opt =
        match type_head with
        | Some name -> (
            match Types.split_canonical_module_type_name name with
            | Some (module_path, _) -> Some (canonical_module_path module_path)
            | None -> canon_opt (lookup_type_home state name))
        | None -> None
      in
      let prim_home_opt = Type_metadata.primitive_home impl.impl_for_type in
      let matches = function Some m -> m = impl_mod | None -> false in
      let trait_match = matches trait_mod_opt in
      let type_match = matches type_mod_opt in
      let prim_match =
        match prim_home_opt with
        | Some h when h = impl_mod -> true
        | Some _ -> impl_mod = "std/traits"
        | None -> false
      in
      if trait_match || type_match || prim_match then None
      else
        let type_str = Types.type_to_string impl.impl_for_type in
        let help =
          Printf.sprintf
            "`impl %s for %s` can live in the module that declares `%s`, the \
             module that declares `%s`, or — for stdlib primitive types — the \
             primitive's home module. To add behavior to a type you don't own, \
             wrap it in a local record (the \"newtype\" pattern): `record My%s \
             { wrapped: %s }`, then impl the trait on `My%s`."
            impl.impl_trait type_str impl.impl_trait type_str type_str type_str
            type_str
        in
        Some
          (error_with ~notes:[] ~help:(Some help) loc
             (Printf.sprintf
                "orphan impl: `%s for %s` is not in the trait's module or the \
                 type's module"
                impl.impl_trait type_str))

(** Add a trait-function binding under [state], emitting a diagnostic
    when [func_name] is already bound to a different trait. Idempotent
    same-pair re-registration (supertrait sweep, re-imports) no-ops.
    Used by user-facing trait-registration paths; [env_builtins] uses
    [Env.add_trait_function] directly since its foundational
    registrations are trusted. *)
let add_trait_function_checked (state : check_state) (loc : Ast.loc)
    (func_name : string) (trait_name : string) : check_state =
  match Env.trait_function_collision state.env func_name trait_name with
  | Some existing_trait ->
      let msg =
        Printf.sprintf
          "method '%s' is already registered under trait '%s'; cannot also \
           register under '%s'. Rename one of the methods so each trait has a \
           distinct set of method names, or consolidate the traits if they \
           represent the same concept."
          func_name existing_trait trait_name
      in
      add_error state (error_at loc msg)
  | None ->
      if Env.get_function_trait state.env func_name = Some trait_name then state
      else
        {
          state with
          env = Env.add_trait_function state.env func_name trait_name;
        }

(** Add an imported trait definition to [state.env] without exposing any of its
    methods as bare functions. The session trait index already knows about all
    loaded public traits for supertrait/bound lookup; this env-local insertion
    is for imports that make the trait name itself lexical. *)
let register_imported_trait_def ?(module_path : string option)
    (state : check_state) (loc : Ast.loc) (trait : Ast.trait_decl) : check_state
    =
  let trait_def = Env.trait_def_of_decl ~loc ?module_path trait in
  match Env.try_add_trait state.env trait_def with
  | Ok env' -> { state with env = env' }
  | Error msg -> add_error state (error_at loc msg)

let expose_trait_method (state : check_state) (loc : Ast.loc)
    (method_name : string) (trait_name : string) : check_state =
  add_trait_function_checked state loc method_name trait_name

let expose_all_trait_methods (state : check_state) (loc : Ast.loc)
    (trait_name : string) : check_state =
  List.fold_left
    (fun state (method_name, declaring_trait) ->
      expose_trait_method state loc method_name declaring_trait)
    state
    (Env.trait_methods_with_declaring_trait state.env trait_name)

let semantic_func_export (func : Typed_ast.func_decl) : func_decl =
  let ast_func = Typed_ast.func_ast func in
  let info = Typed_ast.func_info func in
  let func_params =
    try
      List.map2
        (fun (param : param) (param_info : Typed_ast.func_param_info) ->
          { param with param_type = Some param_info.semantic_param_ty })
        ast_func.func_params info.param_infos
    with Invalid_argument _ -> ast_func.func_params
  in
  { ast_func with func_params; func_return_type = Some info.semantic_return_ty }

let semantic_record_export (record : Typed_ast.record_decl) : record_decl =
  let ast_record = Typed_ast.record_ast record in
  let info = Typed_ast.record_info record in
  let record_fields =
    try
      List.map2
        (fun (field : field_decl) (field_info : Typed_ast.record_field_info) ->
          { field with field_type = field_info.semantic_field_ty })
        ast_record.record_fields info.field_infos
    with Invalid_argument _ -> ast_record.record_fields
  in
  { ast_record with record_fields }

let semantic_type_alias_export (alias : Typed_ast.type_alias_decl) :
    type_alias_decl =
  let ast_alias = Typed_ast.type_alias_ast alias in
  let info = Typed_ast.type_alias_info alias in
  { ast_alias with alias_target = info.semantic_target_ty }

let rec semantic_export_decl (decl : Typed_ast.decl) : decl =
  let ast_decl = Typed_ast.decl_ast decl in
  match Typed_ast.decl_view decl with
  | Typed_ast.DeclFunction func ->
      { ast_decl with decl_desc = DFunc (semantic_func_export func) }
  | Typed_ast.DeclVar var ->
      let ast_var = Typed_ast.var_ast var in
      let info = Typed_ast.var_info var in
      {
        ast_decl with
        decl_desc = DVar { ast_var with var_type = Some info.binding_ty };
      }
  | Typed_ast.DeclRecord record ->
      { ast_decl with decl_desc = DRecord (semantic_record_export record) }
  | Typed_ast.DeclTypeAlias alias ->
      {
        ast_decl with
        decl_desc = DTypeAlias (semantic_type_alias_export alias);
      }
  | Typed_ast.DeclImpl impl ->
      let ast_impl = Typed_ast.impl_ast impl in
      let impl_methods =
        List.map semantic_func_export (Typed_ast.impl_methods impl)
      in
      { ast_decl with decl_desc = DImpl { ast_impl with impl_methods } }
  | Typed_ast.DeclPrivate inner ->
      { ast_decl with decl_desc = DPrivate (semantic_export_decl inner) }
  | Typed_ast.DeclOther -> ast_decl

let semantic_export_program (typed : Typed_ast.program) : program =
  List.map semantic_export_decl (Typed_ast.program_decls typed)

let module_exports_for_import (m : Modules.loaded_module) : (string * decl) list
    =
  match Modules.get_typed_decls m.name with
  | Some typed_decls ->
      Modules.collect_exports (semantic_export_program typed_decls)
  | None -> m.exports

(** Process a selectively imported trait or trait method.

    Trait definitions and trait method names have different visibility:
    loading a module registers public trait definitions in the session so bounds
    and supertraits are resolvable, but only selective imports expose bare
    method names in the current lexical scope. This keeps alias-only imports
    ([import: m as M]) from merging every imported module's trait-method
    namespace into the importer. *)
let process_imported_trait_symbol ?(module_path : string option)
    (state : check_state) (loc : Ast.loc) (trait : Ast.trait_decl)
    ~(symbol_name : string) : check_state =
  let state = register_imported_trait_def ?module_path state loc trait in
  if symbol_name = trait.trait_name then
    expose_all_trait_methods state loc trait.trait_name
  else if
    List.exists
      (fun (m : Ast.trait_method) -> m.method_name = symbol_name)
      trait.trait_methods
  then expose_trait_method state loc symbol_name trait.trait_name
  else state

(** Register a trait into [state] as a single atomic operation: builds
    the [trait_def] from the AST (with [?loc] for Phase 3.4's orphan
    check), inserts it via [Env.add_trait], and registers each method
    name via the collision-checked wrapper. Callers MUST use this
    helper instead of the three primitives separately — the pair is
    load-bearing (bare method calls in synthesized default bodies need
    the trait-function mapping to resolve; an `Env.add_trait` without
    the per-method registration surfaces as "undefined identifier
    `equals`" inside a synthesized `not_equals` body at typecheck time). *)
let register_trait ?(loc : Ast.loc option) ?(module_path : string option)
    (state : check_state) (trait : Ast.trait_decl) : check_state =
  let trait_loc = match loc with Some l -> l | None -> Ast.dummy_loc in
  let trait_def = Env.trait_def_of_decl ?loc ?module_path trait in
  let env = Env.add_trait state.env trait_def in
  let state = { state with env } in
  (* Register trait-function bindings for this trait's OWN methods, plus
     every method inherited via the transitive supertrait chain — each
     under its declaring trait. Without the supertrait sweep, importing
     [Taggable: Identifiable { ... }] would bind only [Taggable]'s own
     methods; calling an inherited method like [id] on a [T: Taggable]
     value would fall through bare-name resolution. Supertrait defs
     come from the session-scoped trait registry (step 3), so this
     works even when the importing file doesn't explicitly name the
     supertrait's home module. *)
  let state =
    List.fold_left
      (fun state (m : Ast.trait_method) ->
        add_trait_function_checked state trait_loc m.method_name
          trait.trait_name)
      state trait.trait_methods
  in
  List.fold_left
    (fun state (mname, declaring_trait) ->
      if declaring_trait = trait.trait_name then state (* already added above *)
      else add_trait_function_checked state trait_loc mname declaring_trait)
    state
    (Env.trait_methods_with_declaring_trait state.env trait.trait_name)

(** Register trait DEFINITIONS (not impls) from a module's declarations.
    Without this, a trait declared in [std/traits.brp] is invisible to
    any other module that imports it — including the [get_trait] lookup
    in [second_pass] that drives default-body synthesis. Skipped for
    [DPrivate] decls so private traits stay scoped to their module.

    This is intentionally NOT part of ordinary [process_import]. Most
    imports only make trait definitions available through the session
    index; bare trait methods are exposed only by selective trait/method
    imports. Use this helper only when intentionally seeding a lexical
    environment with a module's trait methods, such as prelude setup.
    [?module_path] is the canonical name of the module supplying the
    decls (e.g. ["std/traits"]); passed through so duplicate-trait
    diagnostics can name the home module.

    Uses [Env.try_add_trait] for conflict detection: an identical
    redeclaration (same name + structurally equal) no-ops, while a
    name clash with differing supertraits or method signatures
    surfaces an error. Trait-function bindings ([add_trait_function])
    only run when the trait def is actually newly added — if a def is
    already present (idempotent case), its trait functions were
    registered earlier and don't need re-installation. *)
let register_module_trait_defs ?(module_path : string option)
    (state : check_state) (decls : program) : check_state =
  List.fold_left
    (fun state decl ->
      match decl.decl_desc with
      | DTrait trait -> (
          let trait_def =
            Env.trait_def_of_decl ~loc:decl.decl_loc ?module_path trait
          in
          match Env.try_add_trait state.env trait_def with
          | Ok env' when env' == state.env ->
              (* Idempotent: same def already present, nothing to do. *)
              state
          | Ok env' ->
              (* Freshly added: also install trait-function bindings so
                bare-name dispatch (e.g. [x.equals(y)] via [Equatable.equals])
                resolves in callers. Use the checked variant so two
                traits claiming the same method name are flagged at
                the import site. *)
              let state = { state with env = env' } in
              List.fold_left
                (fun state (m : Ast.trait_method) ->
                  add_trait_function_checked state decl.decl_loc m.method_name
                    trait.trait_name)
                state trait.trait_methods
          | Error msg -> add_error state (error_at decl.decl_loc msg))
      | _ -> state)
    state decls

(** Extract the head type name from a function's first parameter.
    Returns None if the function has no params, no type annotation,
    or the first param is a bare type variable (generic over all types). *)
let func_first_param_head (func : func_decl) : string option =
  match func.func_params with
  | [] -> None
  | p :: _ -> (
      match p.param_type with
      | Some (TyNamed (name, _)) -> Some name
      | _ -> None)

let unwrap_to_func (d : decl) : func_decl option =
  match d.decl_desc with DFunc f -> Some f | _ -> None

(** Build an overload_entry from the checked signature boundary for an imported
    function. *)
let overload_entry_of_func ~(env : env) ~(module_path : string)
    (func : func_decl) : overload_entry =
  match checked_func_signature_of_imported_func ~env ~module_path func with
  | Some sig_ -> overload_entry_of_checked_signature sig_
  | None ->
      invalid_arg
        "overload_entry_of_func expected a named imported function declaration"

(** Register UFCS methods for a type imported from a module.
    Scans all exports for functions whose first param head type matches [type_name],
    skipping any function names in [explicit_names] (already imported as bare names).
    Registered as UFCS-only — accessible via x.f(...) but NOT as bare f(...).

    [?loc] is the location of the import statement driving this
    registration; used when reporting a cross-module UFCS collision.
    When absent (prelude auto-registration, etc.) collisions still
    detect but are reported at [dummy_loc]. *)
let register_ufcs_methods_for_type ?(loc = dummy_loc) (state : check_state)
    (m : Modules.loaded_module) (type_name : string)
    (explicit_names : string list) : check_state =
  let exports = module_exports_for_import m in
  List.fold_left
    (fun state (export_name, export_decl) ->
      match unwrap_to_func export_decl with
      | Some func when not (List.mem export_name explicit_names) -> (
          match func_first_param_head func with
          | Some head when head = type_name -> (
              let entry =
                overload_entry_of_func ~env:state.env ~module_path:m.name func
              in
              match ufcs_collision state.env export_name entry with
              | Some existing ->
                  let existing_mod =
                    match existing.ol_module_path with
                    | Some p -> p
                    | None -> "<unknown>"
                  in
                  let msg =
                    Printf.sprintf
                      "UFCS method '%s' on first-arg type '%s' is already \
                       auto-registered from module '%s'; cannot also register \
                       from '%s'. Rename one of the source functions, or \
                       import the conflicting type under an alias so its \
                       methods don't auto-register."
                      export_name type_name existing_mod m.name
                  in
                  add_error state (error_at loc msg)
              | None ->
                  {
                    state with
                    env = add_ufcs_method state.env export_name entry;
                  })
          | _ -> state)
      | _ -> state)
    state exports

(** Process an import declaration - load and add imported symbols *)
let process_import (state : check_state) (loc : loc) (decl : import_decl) :
    check_state =
  match Modules.find_cached decl.import_module with
  | None -> state
  | Some m
    when state_is_stdlib_module state && Modules.is_package_loaded_module m ->
      add_error state
        {
          message = "standard library modules cannot import package modules";
          loc;
          phase = TypeCheck;
          kind = OtherError;
          notes = [];
          help =
            Some
              "Keep std portable: move optional native integrations to pkg/, \
               or depend only on std modules and compiler/runtime builtins";
        }
  | Some m -> (
      let canonical_name = m.name in
      let exports = module_exports_for_import m in
      (* Each module may only be imported once per file *)
      if List.mem canonical_name state.imported_modules then
        add_error state
          (error_at loc
             (Printf.sprintf "module '%s' is already imported"
                (Filename.basename decl.import_module)))
      else
        let state =
          {
            state with
            imported_modules = canonical_name :: state.imported_modules;
          }
        in
        let module_path = Some m.name in
        let state = register_module_impls ~module_path:m.name state m.decls in
        match decl.import_symbols with
        | Some symbols -> (
            (* Check for duplicate symbols within this import list *)
            let seen_names = Hashtbl.create 8 in
            let state =
              List.fold_left
                (fun state sym ->
                  let local_name =
                    match sym.sym_alias with
                    | Some a -> a
                    | None -> sym.sym_name
                  in
                  let state =
                    if sym.sym_ctors = CtorNone then (
                      match Hashtbl.find_opt seen_names local_name with
                      | Some _ ->
                          add_error state
                            (error_at loc
                               (Printf.sprintf
                                  "'%s' is already imported from this module"
                                  local_name))
                      | None ->
                          Hashtbl.replace seen_names local_name ();
                          state)
                    else (
                      Hashtbl.replace seen_names local_name ();
                      state)
                  in
                  (* Reject bare constructor imports — must use Type(Ctor) syntax.
               E.g., import: option: Some is illegal; use option: Option(Some, None).
               Check both the local env (for prelude types like Option/Result) and the
               module's exports (for non-prelude union types like ParseResult).
               Skip for aliased imports (e.g., Some as Just). *)
                  let state =
                    if sym.sym_ctors = CtorNone && sym.sym_alias = None then
                      let is_ctor_in_env =
                        match get_constructor state.env sym.sym_name with
                        | Some _ -> true
                        | None -> false
                      in
                      let is_ctor_in_module =
                        List.exists
                          (fun (_, decl) ->
                            match decl.decl_desc with
                            | DType t ->
                                List.exists
                                  (fun v -> v.variant_name = sym.sym_name)
                                  t.type_variants
                            | _ -> false)
                          exports
                      in
                      if is_ctor_in_env || is_ctor_in_module then
                        let parent_name =
                          match get_constructor state.env sym.sym_name with
                          | Some (parent, _, _, _) -> parent
                          | None -> (
                              (* Find parent type name from module exports *)
                              match
                                List.find_map
                                  (fun (_, decl) ->
                                    match decl.decl_desc with
                                    | DType t
                                      when List.exists
                                             (fun v ->
                                               v.variant_name = sym.sym_name)
                                             t.type_variants ->
                                        Some t.type_name
                                    | _ -> None)
                                  exports
                              with
                              | Some name -> name
                              | None -> "?")
                        in
                        add_error state
                          {
                            message =
                              Printf.sprintf
                                "'%s' is a constructor of '%s' — import it \
                                 with the type: %s(%s)"
                                sym.sym_name parent_name parent_name
                                sym.sym_name;
                            loc;
                            phase = TypeCheck;
                            kind = OtherError;
                            notes = [];
                            help = None;
                          }
                      else state
                    else state
                  in
                  let matching =
                    List.filter_map
                      (fun (name, decl) ->
                        if name = sym.sym_name then Some decl else None)
                      exports
                  in
                  if matching = [] then
                    let private_names = Modules.collect_private_names m.decls in
                    let is_private =
                      List.exists
                        (fun (name, _) -> name = sym.sym_name)
                        private_names
                    in
                    if is_private then
                      add_error state
                        (error_at loc
                           (Printf.sprintf
                              "'%s' is private in module '%s' and cannot be \
                               imported"
                              sym.sym_name decl.import_module))
                    else
                      (* Validate function imports: check if the symbol exists in the
                   specified module's exports, any other loaded module, or as a
                   builtin. Skip validation for types/constructors (uppercase). *)
                      let name = sym.sym_name in
                      let is_uppercase =
                        String.length name > 0
                        && name.[0] >= 'A'
                        && name.[0] <= 'Z'
                      in
                      (* Helper: check if name exists in a module's declarations
                   (types, constructors, records, traits, aliases) *)
                      let in_module_decls =
                        List.exists
                          (fun d ->
                            let rec check d =
                              match d.Ast.decl_desc with
                              | Ast.DType td ->
                                  td.Ast.type_name = name
                                  || List.exists
                                       (fun v -> v.Ast.variant_name = name)
                                       td.Ast.type_variants
                              | Ast.DRecord rd -> rd.Ast.record_name = name
                              | Ast.DTrait t -> t.Ast.trait_name = name
                              | Ast.DTypeAlias a -> a.Ast.alias_name = name
                              | Ast.DPrivate inner -> check inner
                              | _ -> false
                            in
                            check d)
                          m.decls
                      in
                      if in_module_decls then state
                      else if is_uppercase then
                        (* Check env-declared types/constructors/aliases and other modules.
                     Avoid a hardcoded builtin type-name list here: [state.env] is
                     already seeded with builtin declarations. *)
                        let type_exists =
                          (match Env.get_type_decl state.env name with
                            | Some _ -> true
                            | None -> false)
                          || (match Env.get_alias state.env name with
                            | Some _ -> true
                            | None -> false)
                          || (match Env.get_constructor state.env name with
                            | Some _ -> true
                            | None -> false)
                          || List.exists
                               (fun other_mod ->
                                 List.exists
                                   (fun (n, _) -> n = name)
                                   other_mod.Modules.exports)
                               (Modules.get_all_modules ())
                        in
                        if type_exists then state
                        else
                          let help = Modules.suggest_export m name in
                          add_error state
                            {
                              message =
                                Printf.sprintf
                                  "'%s' is not exported by module '%s'" name
                                  decl.import_module;
                              loc;
                              phase = TypeCheck;
                              kind = NotExported (name, decl.import_module);
                              notes = [];
                              help;
                            }
                      else
                        (* Function import: check if it exists in the specified module's exports
                     or as a builtin. Builtins are always available regardless of import. *)
                        let in_this_module =
                          List.exists (fun (n, _) -> n = name) exports
                        in
                        let is_builtin = Env.is_builtin_func state.env name in
                        if in_this_module || is_builtin then state
                        else
                          (* Check if it exists in a different module for a better hint *)
                          let other_module =
                            List.find_map
                              (fun (other : Modules.loaded_module) ->
                                if
                                  List.exists
                                    (fun (n, _) -> n = name)
                                    other.Modules.exports
                                then Some (Filename.basename other.Modules.name)
                                else None)
                              (Modules.get_all_modules ())
                          in
                          let help =
                            match other_module with
                            | Some other_mod ->
                                Some
                                  (Printf.sprintf
                                     "'%s' is not in '%s'. Did you mean: \
                                      import: %s: %s"
                                     name decl.import_module other_mod name)
                            | None -> Modules.suggest_export m name
                          in
                          add_error state
                            {
                              message =
                                Printf.sprintf
                                  "'%s' is not exported by module '%s'" name
                                  decl.import_module;
                              loc;
                              phase = TypeCheck;
                              kind = NotExported (name, decl.import_module);
                              notes = [];
                              help;
                            }
                  else
                    let local_name =
                      match sym.sym_alias with
                      | Some a -> a
                      | None -> sym.sym_name
                    in
                    let state, registered =
                      register_imported_name state loc ~local_name
                        ~module_path:canonical_name ~original_name:sym.sym_name
                    in
                    if not registered then state
                    else
                      List.fold_left
                        (fun state export_decl ->
                          match (export_decl.decl_desc, sym.sym_alias) with
                          | DTrait trait, None ->
                              process_imported_trait_symbol ?module_path state
                                export_decl.decl_loc trait
                                ~symbol_name:sym.sym_name
                          | DTrait _, Some _ ->
                              add_error state
                                (error_at loc
                                   "trait imports cannot be aliased yet; \
                                    import the trait or method by its original \
                                    name")
                          | _, None ->
                              process_imported_decl ~module_path state
                                export_decl
                          | _, Some alias ->
                              process_imported_decl_as ~module_path state
                                export_decl alias)
                        state matching)
                state symbols
            in
            (* UFCS method registration: for each imported type name (uppercase),
             scan module for functions whose first param matches and register
             as method-only (accessible via UFCS but not as bare names). *)
            let explicit_names = List.map (fun sym -> sym.sym_name) symbols in
            let state =
              List.fold_left
                (fun state sym ->
                  let name = sym.sym_name in
                  let is_type_name =
                    String.length name > 0 && name.[0] >= 'A' && name.[0] <= 'Z'
                  in
                  (* UFCS method registration *)
                  let state =
                    if is_type_name && sym.sym_alias = None then
                      register_ufcs_methods_for_type ~loc state m name
                        explicit_names
                    else state
                  in
                  (* Constructor import for Type(..) and Type(Ctor1, Ctor2) *)
                  let state =
                    match sym.sym_ctors with
                    | CtorNone -> state
                    | CtorSome ctor_names ->
                        let type_lookup_name =
                          canonical_type_lookup_name state.env name
                        in
                        (* Find constructors: check env (builtins like Option/Result)
                     and module exports (user-defined unions) *)
                        let ctors_to_import =
                          match get_type_decl state.env type_lookup_name with
                          | Some (_, variants) ->
                              List.filter
                                (fun (v : variant) ->
                                  List.mem v.variant_name ctor_names)
                                variants
                          | None -> (
                              (* Check module exports for a DType declaration *)
                              let type_decl =
                                List.find_map
                                  (fun (_n, d) ->
                                    let find d =
                                      match d.decl_desc with
                                      | DType td when td.type_name = name ->
                                          Some td
                                      | _ -> None
                                    in
                                    find d)
                                  exports
                              in
                              match type_decl with
                              | Some td ->
                                  List.filter
                                    (fun (v : variant) ->
                                      List.mem v.variant_name ctor_names)
                                    td.type_variants
                              | None -> [])
                        in
                        (* Add each constructor to the environment *)
                        List.fold_left
                          (fun state (v : variant) ->
                            (* Only add if not already in scope (builtins like Some/None are pre-registered) *)
                            match lookup state.env v.variant_name with
                            | Some { kind = ConstructorSymbol _; _ } -> state
                            | _ ->
                                let env =
                                  add_symbol state.env
                                    {
                                      name = v.variant_name;
                                      kind =
                                        ConstructorSymbol
                                          {
                                            parent_type = type_lookup_name;
                                            constructor_id =
                                              Session.mint_def_id
                                                (Session.current ());
                                            type_params =
                                              (match
                                                 get_type_decl state.env
                                                   type_lookup_name
                                               with
                                              | Some (tps, _) -> tps
                                              | None -> []);
                                            field_types = v.variant_fields;
                                            tag = v.variant_tag;
                                          };
                                    }
                                in
                                { state with env })
                          state ctors_to_import
                  in
                  state)
                state symbols
            in
            (* If combined import (e.g., heap as H { Heap }), also register module alias *)
            match decl.import_alias with
            | Some alias ->
                register_module_alias state loc ~alias ~canonical_name
            | None -> state)
        | None ->
            let alias =
              match decl.import_alias with
              | Some a -> a
              | None -> Filename.basename decl.import_module
            in
            let state =
              register_qualified_import_resource_types
                ~module_path:canonical_name state exports
            in
            register_module_alias state loc ~alias ~canonical_name)

(** First pass: collect all type and function signatures.

    Pre-scans all top-level type/record/alias names into [known_type_names]
    and resource type names into [known_resource_type_names] so the
    auto-generalization guard and resource-operation metadata checks in
    [process_func_signature] handle forward references (a function declared
    before the type it uses must still see that type as concrete, not
    auto-generalize the name).

    Also pre-scans declaration names into [top_level_names] so module-alias
    namespace checks are independent of declaration order. *)
let rec first_pass (state : check_state) (decls : program) : check_state =
  let remember_top_level name kind =
    if not (Hashtbl.mem state.top_level_names name) then
      Hashtbl.add state.top_level_names name kind
  in
  let rec collect_decl_names d =
    match d.decl_desc with
    | DType t ->
        Hashtbl.replace state.known_type_names t.type_name ();
        if t.type_is_resource then
          Hashtbl.replace state.known_resource_type_names t.type_name ();
        remember_top_level t.type_name "type";
        List.iter
          (fun v -> remember_top_level v.variant_name "constructor")
          t.type_variants
    | DRecord r ->
        Hashtbl.replace state.known_type_names r.record_name ();
        remember_top_level r.record_name "type"
    | DTypeAlias a ->
        Hashtbl.replace state.known_type_names a.alias_name ();
        remember_top_level a.alias_name "type"
    | DFunc f ->
        Option.iter (fun name -> remember_top_level name "function") f.func_name
    | DVar v ->
        Option.iter (fun name -> remember_top_level name "variable") v.var_name
    | DTrait t -> remember_top_level t.trait_name "trait"
    | DPrivate inner -> collect_decl_names inner
    | _ -> ()
  in
  List.iter collect_decl_names decls;
  List.fold_left
    (fun state decl ->
      match decl.decl_desc with
      | DType type_decl -> process_type_decl ~loc:decl.decl_loc state type_decl
      | DRecord record_decl ->
          process_record_decl state record_decl decl.decl_loc
      | DTypeAlias alias_decl ->
          process_type_alias ~loc:decl.decl_loc state alias_decl
      | DFunc func_decl ->
          (* Keep std portable: native FFI belongs in explicit package/user
             modules, while std uses compiler/runtime builtins. *)
          let state =
            if func_is_foreign func_decl && not (state_allows_foreign state)
            then
              add_error state
                {
                  message =
                    "'foreign' declarations cannot be used in the standard \
                     library";
                  loc = decl.decl_loc;
                  phase = TypeCheck;
                  kind = OtherError;
                  notes = [];
                  help =
                    Some
                      "Move optional native bindings to a pkg/ module, or \
                       implement std functionality with Blorp source or \
                       compiler/runtime builtins";
                }
            else state
          in
          (* Reject compiler-provided function bodies outside the standard library. *)
          let has_builtin = func_has_builtin_body func_decl in
          let state =
            if has_builtin && not (state_allows_builtin state) then
              add_error state
                {
                  message = "'builtin' can only be used in the standard library";
                  loc = decl.decl_loc;
                  phase = TypeCheck;
                  kind = OtherError;
                  notes = [];
                  help =
                    Some
                      "Implement the function body, or declare it inside a \
                       'foreign:' block for C interop";
                }
            else state
          in
          let state =
            match func_decl.func_name with
            | Some name
              when (not (func_is_foreign func_decl))
                   && not (is_builtin_func state.env name) -> (
                let new_purity =
                  if func_decl.func_is_pure then Pure else Impure
                in
                match get_func_info state.env name with
                | Some (_, _, existing_purity) when existing_purity = new_purity
                  ->
                    add_error state
                      (error_at decl.decl_loc
                         (Printf.sprintf "function '%s' is already defined" name))
                | _ -> state)
            | _ -> state
          in
          process_func_signature ~loc:decl.decl_loc state func_decl
      | DVar var_decl -> process_var_decl state var_decl
      | DImport import_decl -> process_import state decl.decl_loc import_decl
      | DPrivate inner -> (
          match inner.decl_desc with
          | DPrivate _ ->
              add_error state
                (error_at decl.decl_loc
                   "redundant 'private' modifier — declaration is already \
                    private")
          | DImpl _ -> state
          | _ -> first_pass state [ inner ])
      | DTrait trait ->
          (* First, check that all trait method parameters have explicit types *)
          let trait_loc = decl.decl_loc in
          let state =
            validate_type_params state trait_loc trait.trait_type_params
          in
          let state =
            List.fold_left
              (fun state meth ->
                check_removed_tensor_trait_method_syntax state trait_loc meth)
              state trait.trait_methods
          in
          let state =
            List.fold_left
              (fun state meth ->
                List.fold_left
                  (fun s p ->
                    match p.param_type with
                    | None ->
                        let param_name =
                          match p.param_name with Some n -> n | None -> "_"
                        in
                        add_error s
                          (error_at trait_loc
                             (Printf.sprintf
                                "trait %s method '%s': parameter '%s' must \
                                 have an explicit type"
                                trait.trait_name meth.method_name param_name))
                    | Some _ -> s)
                  state meth.method_params)
              state trait.trait_methods
          in
          (* Register as one atomic operation — see [register_trait]
           for why the trait def and its method-name mappings must
           always be installed together. *)
          register_trait ~loc:trait_loc state trait
      | DImpl _impl ->
          (* Impls are registered in second_pass after validation,
           so that validate_impl's supertrait check isn't fooled by
           the impl being validated. *)
          state)
    state decls

(* Initialize prelude loader now that first_pass is defined.
   Loads option/result modules and registers their functions as UFCS methods,
   so opt.get_or(default) and result.map(f) work without explicit import. *)
let () =
  load_prelude_ref :=
    fun env ->
      let base_dir = try Sys.getcwd () with _ -> "." in
      Modules.init_module_paths base_dir;
      let add_builtin_impls_from_module env (m : Modules.loaded_module) =
        List.fold_left
          (fun env (decl : Ast.decl) ->
            match decl.decl_desc with
            | Ast.DImpl impl ->
                let inst =
                  Env.
                    {
                      ii_def_id = Session.mint_def_id (Session.current ());
                      ii_trait = impl.impl_trait;
                      ii_for_type = impl.impl_for_type;
                      ii_bounds = impl_bounds_for_type ~env impl.impl_for_type;
                      ii_is_builtin = true;
                      ii_loc = Some decl.decl_loc;
                    }
                in
                Env.add_impl env inst
            | _ -> env)
          env m.decls
      in
      let prelude_type_imports =
        [
          ("option", "Option");
          ("result", "Result");
          ("bool", "Bool");
          ("char", "Char");
          ("bytes", "Bytes");
          ("string", "String");
          ("list", "List");
          ("list", "ParallelList");
          ("parallel_list", "ParallelList");
          ("range", "Range");
          ("dict", "Dict");
          ("set", "Set");
        ]
      in
      let env =
        List.fold_left
          (fun env (mod_name, type_name) ->
            ignore (Modules.load_module mod_name base_dir);
            match Modules.find_cached mod_name with
            | Some m ->
                let env = add_builtin_impls_from_module env m in
                let state =
                  {
                    env;
                    errors = [];
                    imported_names = [];
                    module_aliases = [];
                    imported_modules = [];
                    import_bindings = [];
                    module_origin = Session.Stdlib_module;
                    allow_debug_only_calls = false;
                    private_impls = [];
                    known_type_names = Hashtbl.create 4;
                    known_resource_type_names = Hashtbl.create 4;
                    top_level_names = Hashtbl.create 4;
                    type_home = Hashtbl.create 4;
                    func_callable_ids = Hashtbl.create 4;
                  }
                in
                let state =
                  register_ufcs_methods_for_type state m type_name []
                in
                state.env
            | None -> env)
          env prelude_type_imports
      in
      (* Tuples are a built-in surface-level type with no importable constructor.
     Auto-register their trait impls in every compilation so
     [to_string((1, 2))] / [(a, b) == (c, d)] / [a < b] work without an
     explicit [import: tuple]. Registered as [ii_is_builtin = true] — same
     treatment as [env_builtins] stubs for stdlib primitive impls. Marking
     them builtin means:
       (a) the coherence check skips them when the same impls are seen
           again during direct compile of [std/tuple.brp] or explicit import;
       (b) they still satisfy trait-bound checks via Env's trait-obligation
           resolver.
     No UFCS methods to register — tuple field access is a first-class
     syntactic form, not a method call. *)
      ignore (Modules.load_module "tuple" base_dir);
      match Modules.find_cached "tuple" with
      | Some m ->
          let env = add_builtin_impls_from_module env m in
          let state =
            {
              env;
              errors = [];
              imported_names = [];
              module_aliases = [];
              imported_modules = [];
              import_bindings = [];
              module_origin = Session.Stdlib_module;
              allow_debug_only_calls = false;
              private_impls = [];
              known_type_names = Hashtbl.create 4;
              known_resource_type_names = Hashtbl.create 4;
              top_level_names = Hashtbl.create 4;
              type_home = Hashtbl.create 4;
              func_callable_ids = Hashtbl.create 4;
            }
          in
          let state =
            register_module_trait_defs ~module_path:m.name state m.decls
          in
          state.env
      | None -> env

(* ============================================================================
   Pattern Exhaustiveness Checking (Pattern Matrix Algorithm)
   ============================================================================ *)

(** Normalize a pattern: resolve PatVar of known constructors to PatConstructor,
    and PatLiteral(LitBool _) to PatConstructor *)
let rec normalize_pattern env = function
  | PatVar name -> (
      match get_constructor env name with
      | Some (_, _, field_types, _) when field_types = [] ->
          PatConstructor (name, [])
      | _ -> PatVar name)
  | PatLiteral (LitBool true) -> PatConstructor ("True", [])
  | PatLiteral (LitBool false) -> PatConstructor ("False", [])
  | PatConstructor (name, args) ->
      PatConstructor (name, List.map (normalize_pattern env) args)
  | PatQualified (_, name, args) ->
      PatConstructor (name, List.map (normalize_pattern env) args)
  | PatTuple elems -> PatTuple (List.map (normalize_pattern env) elems)
  | PatList (elems, spread) ->
      PatList
        ( List.map (normalize_pattern env) elems,
          Option.map (normalize_pattern env) spread )
  | PatOr pats -> PatOr (List.map (normalize_pattern env) pats)
  | p -> p

(** Check if a pattern is a wildcard/catch-all (matches anything) *)
let is_wildcard_pattern env = function
  | PatWildcard -> true
  | PatVar name -> (
      match get_constructor env name with Some _ -> false | None -> true)
  | _ -> false

(** Check if a pattern covers every value at its position. *)
let rec pattern_is_catch_all env pat =
  match normalize_pattern env pat with
  | PatOr pats -> List.exists (pattern_is_catch_all env) pats
  | pat -> is_wildcard_pattern env pat

(** Get the constructor head of a pattern, if any.
    Returns (constructor_name, arity) *)
let pattern_head env = function
  | PatConstructor (name, args) -> Some (name, List.length args)
  | PatTuple elems -> Some ("#tuple", List.length elems)
  | PatLiteral (LitBool true) -> Some ("True", 0)
  | PatLiteral (LitBool false) -> Some ("False", 0)
  | PatVar name -> (
      match get_constructor env name with
      | Some (_, _, field_types, _) -> Some (name, List.length field_types)
      | None -> None)
  | _ -> None

(** Get all constructors and their arities for a type.
    Returns (name, arity, sub_types) list, or None for open types (Int, String, etc.) *)
let type_constructors env = function
  | TyNamed ("Bool", []) -> Some [ ("True", 0, []); ("False", 0, []) ]
  | TyNamed ("List", _) -> None (* infinite constructors *)
  | TyNamed (("Int" | "Float" | "Float32" | "Float16" | "String" | "Char"), [])
    ->
      None
  | TyNamed (type_name, type_args) -> (
      match get_type_decl env type_name with
      | Some (type_params, variants)
        when List.length type_params = List.length type_args ->
          let bindings = List.combine type_params type_args in
          let subst_ty ty =
            Types.map_type_expr
              (function
                | TyVar name -> (
                    match List.assoc_opt name bindings with
                    | Some t -> Some t
                    | None -> None)
                | TyNamed (name, []) -> (
                    match List.assoc_opt name bindings with
                    | Some t -> Some t
                    | None -> None)
                | _ -> None)
              ty
          in
          Some
            (List.map
               (fun v ->
                 let field_types = List.map subst_ty v.variant_fields in
                 (v.variant_name, List.length v.variant_fields, field_types))
               variants)
      | Some _ -> None (* param/arg count mismatch or no variants *)
      | None -> None)
  | TyTuple elems -> Some [ ("#tuple", List.length elems, elems) ]
  | _ -> None

(** Expand or-patterns in a matrix: each PatOr row becomes multiple rows *)
let expand_or_patterns (rows : pattern list list) : pattern list list =
  List.concat_map
    (fun row ->
      match row with
      | PatOr pats :: rest -> List.map (fun p -> p :: rest) pats
      | _ -> [ row ])
    rows

(** Specialize a pattern matrix for constructor [ctor] with [arity].
    For each row: if head matches [ctor], expand sub-patterns; if wildcard, expand with wildcards;
    otherwise skip the row. *)
let specialize_matrix env ctor arity (rows : pattern list list) :
    pattern list list =
  let rows = expand_or_patterns rows in
  List.filter_map
    (fun row ->
      match row with
      | [] -> None
      | p :: rest -> (
          let p = normalize_pattern env p in
          match pattern_head env p with
          | Some (name, _) when name = ctor ->
              let sub_pats =
                match p with
                | PatConstructor (_, args) -> args
                | PatTuple elems -> elems
                | _ -> []
              in
              (* Pad with wildcards if arity doesn't match (shouldn't happen in well-typed code) *)
              let sub_pats =
                if List.length sub_pats < arity then
                  sub_pats
                  @ List.init
                      (arity - List.length sub_pats)
                      (fun _ -> PatWildcard)
                else sub_pats
              in
              Some (sub_pats @ rest)
          | Some _ -> None (* different constructor, skip *)
          | None ->
              (* Wildcard/var — expand to [arity] wildcards *)
              if is_wildcard_pattern env p then
                Some (List.init arity (fun _ -> PatWildcard) @ rest)
              else None (* literal or other non-matching pattern *)))
    rows

(** Default matrix: rows where the head is a wildcard, with head removed *)
let default_matrix env (rows : pattern list list) : pattern list list =
  let rows = expand_or_patterns rows in
  List.filter_map
    (fun row ->
      match row with
      | [] -> None
      | p :: rest -> (
          let p = normalize_pattern env p in
          if is_wildcard_pattern env p then Some rest
          else
            match pattern_head env p with
            | Some _ -> None (* constructor head, skip *)
            | None ->
                (* Literal patterns — not wildcards, skip (they're finite covers) *)
                None))
    rows

(** Check if a set of constructor names covers all constructors of a type *)
let is_complete_constructors env ty heads =
  match type_constructors env ty with
  | Some ctors -> List.for_all (fun (name, _, _) -> List.mem name heads) ctors
  | None -> false (* open type — never complete *)

(** Recursive exhaustiveness check on pattern matrix.
    Returns true if the matrix covers all possible values for the given types. *)
let rec is_exhaustive_matrix env (col_types : type_expr list)
    (rows : pattern list list) : bool =
  match col_types with
  | [] ->
      (* Zero columns: exhaustive iff at least one row exists *)
      rows <> []
  | ty :: rest_types ->
      (* Expand or-patterns before collecting heads *)
      let rows = expand_or_patterns rows in
      (* Collect unique constructor heads from first column *)
      let heads =
        List.filter_map
          (fun row ->
            match row with
            | [] -> None
            | p :: _ -> (
                let p = normalize_pattern env p in
                match pattern_head env p with
                | Some (name, _) -> Some name
                | None -> None))
          rows
      in
      let unique_heads = List.sort_uniq String.compare heads in
      if is_complete_constructors env ty unique_heads then
        (* All constructors present — specialize for each and recurse *)
        match type_constructors env ty with
        | Some ctors ->
            List.for_all
              (fun (name, arity, sub_types) ->
                let specialized = specialize_matrix env name arity rows in
                is_exhaustive_matrix env (sub_types @ rest_types) specialized)
              ctors
        | None -> false
      else
        (* Incomplete — check the default matrix *)
        let dm = default_matrix env rows in
        is_exhaustive_matrix env rest_types dm

(** Check List pattern exhaustiveness (kept as special case due to infinite constructors).
    Each pattern covers: without spread = exactly len(fixed), with spread = [len(fixed), inf).
    Find the lowest-N spread pattern, check all lengths in [0, N-1] are covered. *)
let check_list_exhaustiveness env (cases : match_case list) loc :
    compiler_error option =
  let list_pattern_covers_all_elements elems spread =
    List.for_all (pattern_is_catch_all env) elems
    &&
    match spread with
    | Some spread_pat -> pattern_is_catch_all env spread_pat
    | None -> true
  in
  let rec extract_list_pats pat =
    match normalize_pattern env pat with
    | PatList (elems, spread) ->
        if list_pattern_covers_all_elements elems spread then
          [ (List.length elems, Option.is_some spread) ]
        else []
    | PatOr pats -> List.concat_map extract_list_pats pats
    | _ -> []
  in
  let list_pats =
    List.concat_map (fun case -> extract_list_pats case.case_pattern) cases
  in
  let exact_lengths =
    List.filter_map
      (fun (n, has_spread) -> if not has_spread then Some n else None)
      list_pats
  in
  let spread_lengths =
    List.filter_map
      (fun (n, has_spread) -> if has_spread then Some n else None)
      list_pats
  in
  if spread_lengths = [] then
    Some
      (error_at loc
         "Non-exhaustive match on List: add a catch-all spread pattern (e.g., \
          [x, ...rest]) or wildcard (_)")
  else
    let min_spread = List.fold_left min max_int spread_lengths in
    let missing = ref [] in
    for i = 0 to min_spread - 1 do
      if not (List.mem i exact_lengths) then missing := i :: !missing
    done;
    if !missing = [] then None
    else
      let missing_strs =
        List.rev_map
          (fun n -> if n = 0 then "[]" else Printf.sprintf "length %d" n)
          !missing
      in
      Some
        (error_at loc
           (Printf.sprintf "Non-exhaustive match on List: missing %s"
              (String.concat ", " missing_strs)))

(** Generate a helpful non-exhaustive match error for the given scrutinee type. *)
let non_exhaustive_error env scrutinee_ty cases loc =
  match scrutinee_ty with
  | TyNamed ("Bool", []) ->
      let rec pat_covers_name target pat =
        match normalize_pattern env pat with
        | PatConstructor (name, _) -> name = target
        | PatOr pats -> List.exists (pat_covers_name target) pats
        | _ -> false
      in
      let has_true =
        List.exists (fun c -> pat_covers_name "True" c.case_pattern) cases
      in
      Some
        (error_at loc
           ("Non-exhaustive match on Bool: missing "
           ^ if not has_true then "True" else "False"))
  | TyNamed (type_name, _) -> (
      match get_type_decl env type_name with
      | Some (_, variants) ->
          let required = List.map (fun v -> v.variant_name) variants in
          let rec collect_ctor_names pat =
            match normalize_pattern env pat with
            | PatConstructor (name, _) -> [ name ]
            | PatOr pats -> List.concat_map collect_ctor_names pats
            | _ -> []
          in
          let covered =
            List.concat_map
              (fun case -> collect_ctor_names case.case_pattern)
              cases
          in
          let missing =
            List.filter (fun r -> not (List.mem r covered)) required
          in
          if missing <> [] then
            let missing_str = String.concat ", " missing in
            Some
              (error_with
                 ~notes:
                   [ Printf.sprintf "Missing constructors: %s" missing_str ]
                 ~help:
                   (Some "Add the missing cases, or add a wildcard '_' pattern")
                 loc
                 (Printf.sprintf "Non-exhaustive match on type '%s'" type_name))
          else
            Some
              (error_with ~notes:[]
                 ~help:
                   (Some
                      "Add the missing nested patterns, or add a wildcard '_' \
                       pattern") loc
                 (Printf.sprintf "Non-exhaustive match on type '%s'" type_name))
      | None ->
          Some
            (error_with ~notes:[]
               ~help:(Some "Add a wildcard '_' or default pattern") loc
               (Printf.sprintf "Non-exhaustive match on unresolvable type '%s'"
                  type_name)))
  | TyTuple _ ->
      Some
        (error_at loc
           "Non-exhaustive match on tuple: add a wildcard (_) or cover all \
            combinations")
  | _ ->
      Some
        (error_at loc
           "Non-exhaustive match: add a wildcard (_) or default pattern")

(** Main entry point: Check if a set of patterns is exhaustive for a type *)
let check_exhaustiveness (env : env) (scrutinee_ty : type_expr)
    (cases : match_case list) loc : compiler_error option =
  (* Quick check: if any case has a top-level catch-all, it's exhaustive *)
  let has_catch_all =
    List.exists (fun case -> pattern_is_catch_all env case.case_pattern) cases
  in
  if has_catch_all then None
  else
    match scrutinee_ty with
    (* Open scalar spaces always need a wildcard. *)
    | TyNamed (type_name, [])
      when Type_metadata.is_open_exhaustiveness_scalar_name type_name ->
        Some
          (error_at loc
             (Printf.sprintf
                "Non-exhaustive match on %s: add a wildcard (_) or default \
                 pattern to handle all values"
                type_name))
    (* Lists use special-case checker *)
    | TyNamed ("List", _) -> check_list_exhaustiveness env cases loc
    (* Closed types use pattern matrix algorithm *)
    | TyNamed _ | TyTuple _ ->
        let matrix =
          List.map
            (fun case -> [ normalize_pattern env case.case_pattern ])
            cases
        in
        if is_exhaustive_matrix env [ scrutinee_ty ] matrix then None
        else non_exhaustive_error env scrutinee_ty cases loc
    | _ -> None

(* ============================================================================
   Function Body Checking - Second Pass
   ============================================================================ *)

(** Create a type-checking environment scoped to a function's parameters.
    [source_func] preserves the parser-level parameter spelling when [func] has
    already had annotations canonicalized for semantic checking. *)
let setup_function_scope ?(source_func : func_decl option) (state : check_state)
    (func : func_decl) : env =
  let env = push_scope state.env in
  (* Use the effective (auto-generalized) type params so bodies see the
     same polymorphic names the registered signature does. *)
  let effective_type_params = compute_effective_type_params state func in
  let env =
    enter_function env
      (Option.value func.func_name ~default:"<lambda>")
      func.func_is_pure
      (effective_type_param_names effective_type_params)
  in
  (* Set up type parameter bounds from function signature (e.g., T:Stringable).
     Only the originally-declared params carry bounds; auto-generalized ones
     are bound-free. *)
  let env = set_type_param_bounds env func.func_type_params in
  let source_params =
    match source_func with
    | Some source_func -> source_func.func_params
    | None -> func.func_params
  in
  List.fold_left2
    (fun env (source_param : Ast.param) (param : Ast.param) ->
      match (param.param_name, source_param.param_type, param.param_type) with
      | Some name, source_ty_opt, Some ty ->
          let source_type =
            Option.map
              (fun source_ty ->
                let ctx = type_resolution_context state env in
                Type_resolution.function_parameter_annotation ctx source_ty
                |> Type_resolution.source)
              source_ty_opt
          in
          let origin =
            match source_param.param_passing with
            | ParamBorrow -> BorrowedResourceParam
            | ParamByValue -> FuncParam
          in
          add_var env name
            (canonical_type_annotation_in_env state env ty)
            ?source_type ~origin ()
      | _ -> env)
    env source_params func.func_params

(** Check a function body *)
let check_function_body (state : check_state) (func : func_decl) (_loc : loc) :
    check_state * func_body =
  match func.func_body with
  | FuncNoBody -> (state, FuncNoBody)
  | FuncBuiltinBody _ -> (state, func.func_body)
  | FuncForeign _ -> (state, func.func_body)
  | FuncBodyExpr body -> (
      (* Resolve qualified type names in param/return annotations before inference *)
      let source_func = func in
      let func = canonicalize_func_annotations state func in
      let env = setup_function_scope ~source_func state func in
      let ctx =
        make_ctx ~module_aliases:state.module_aliases
          ~allow_debug_only_calls:state.allow_debug_only_calls
          ~rigid_type_params:(Env.get_type_params env) env
      in
      (* Infer body type. Reset the meta-variable environment so
         unification bindings from earlier function bodies don't leak in,
         then [zonk_expr] resolves every [expr_type] through those
         bindings. This is the HM finalization pass that makes call-site
         return types concrete after later calls constrain their type
         parameters (e.g. [var c = C.cache(10); c = C.put(c, "a", "one")]
         retroactively gives the first call's result [Cache[String,String]]). *)
      Session.reset_meta (Session.current ());
      let inferred_body =
        match func.func_return_type with
        | Some ret_ty ->
            let resolved = canonical_type_annotation_in_env state env ret_ty in
            Infer.infer_expr_with_return_annotation ctx resolved body
        | None -> infer_expr ctx body
      in
      match inferred_body with
      | Ok (body_ty, typed_body) -> (
          let typed_body = Infer.zonk_expr typed_body in
          let body_ty = Types.zonk_type body_ty in
          (* Check return type matches *)
          match func.func_return_type with
          | Some expected_ty
            when not
                   (let type_params = Env.get_type_params env in
                    let expected_resolved =
                      canonical_type_annotation_in_env state env expected_ty
                    in
                    let compat =
                      if type_params <> [] then
                        types_compatible_rigid ~rigid_vars:type_params
                          expected_resolved body_ty
                      else types_compatible expected_resolved body_ty
                    in
                    compat) ->
              let body_loc =
                match typed_body.expr_desc with
                | EBlock exprs when exprs <> [] ->
                    (List.nth exprs (List.length exprs - 1)).expr_loc
                | _ -> typed_body.expr_loc
              in
              ( add_error state
                  (error_at body_loc
                     (Printf.sprintf
                        "Function '%s' returns wrong type\n\
                        \    expected: %s  (declared return type)\n\
                        \       found: %s  (body expression)"
                        (Option.value func.func_name ~default:"<lambda>")
                        (type_to_string expected_ty)
                        (type_to_string body_ty))),
                FuncBodyExpr typed_body )
          | None
            when body_ty <> ty_void
                 && body_ty <> TyNamed ("Void", [])
                 && func.func_name <> None
                 (* skip lambdas — they use expected-type inference *) ->
              let body_loc =
                match typed_body.expr_desc with
                | EBlock exprs when exprs <> [] ->
                    (List.nth exprs (List.length exprs - 1)).expr_loc
                | _ -> typed_body.expr_loc
              in
              ( add_error state
                  (error_at body_loc
                     (Printf.sprintf
                        "Function '%s' body has type %s but no return type is \
                         declared\n\
                        \    help: add '-> %s' to the function signature, or \
                         use '-> Void' if discarding the result"
                        (Option.value func.func_name ~default:"<lambda>")
                        (type_to_string body_ty) (type_to_string body_ty))),
                FuncBodyExpr typed_body )
          | _ -> (state, FuncBodyExpr typed_body))
      | Error err -> (add_error state err, FuncBodyExpr body))

(** Typecheck re-exports the shared purity helpers for existing callers/tests;
    the traversal and purity semantics live in [Purity_analysis]. *)
let is_impure_builtin = Purity_analysis.is_impure_builtin

let parallel_function_name = Purity_analysis.parallel_function_name
let collect_parallel_calls = Purity_analysis.collect_parallel_calls
let expr_function_purity = Purity_analysis.expr_function_purity
let collect_impure_calls = Purity_analysis.collect_impure_calls

(** Check for nested parallelism in a call to a parallel function.
    Examines lambda arguments for calls to other parallel functions. *)
let check_nested_parallelism (state : check_state) (callee_name : string)
    (args : expr list) : check_state =
  match parallel_function_name callee_name with
  | None -> state
  | Some outer_name ->
      List.fold_left
        (fun s arg ->
          match arg.expr_desc with
          | ELambda func -> (
              match func_body_expr_opt func.func_body with
              | Some body ->
                  let nested_calls = collect_parallel_calls body in
                  List.fold_left
                    (fun s' { called_name; call_loc; _ } ->
                      add_error s'
                        (error_at call_loc
                           (Printf.sprintf
                              "Nested parallelism: cannot call '%s' inside \
                               callback of '%s'. This could cause deadlocks or \
                               resource exhaustion."
                              called_name outer_name)))
                    s nested_calls
              | None -> s)
          | _ -> s)
        state args

let typed_expr_type_info_for_typecheck ~(context : string) (expr : expr) :
    (expr_type_info, compiler_error) result =
  match expr.expr_type_info with
  | Some info -> Ok info
  | None ->
      Error
        (error_with ~notes:[]
           ~help:
             (Some
                "This is an internal compiler invariant failure: this \
                 typecheck path expects inference to populate structured \
                 expression type metadata before later validation reads it.")
           expr.expr_loc
           (Printf.sprintf
              "partially typed expression reached %s; missing expression type \
               metadata"
              context))

let typed_expr_semantic_type_for_typecheck ~(context : string) (expr : expr) :
    (type_expr, compiler_error) result =
  Result.map
    (fun (info : expr_type_info) -> info.semantic_ty)
    (typed_expr_type_info_for_typecheck ~context expr)

let typed_expr_value_type_for_typecheck ~(context : string) (expr : expr) :
    (type_expr, compiler_error) result =
  Result.map
    (fun (info : expr_type_info) -> info.value_ty)
    (typed_expr_type_info_for_typecheck ~context expr)

(** Validate diagnostics-only debug usage.

    [@debug_only] is declaration metadata, not a name convention. Calls and
    function references to those declarations are allowed only inside [debug:]
    blocks unless the front-end has explicitly enabled debug-only calls (debug
    builds and test harness compilation). *)
let validate_debug_usage (state : check_state) (body : expr) : check_state =
  let debug_help =
    "Keep debug: blocks observational: call debug logging/reflection helpers \
     or pure formatting code, and move state changes or other effects outside \
     the block"
  in
  let debug_only_help =
    "Wrap the diagnostic call in a debug: block, compile with --debug, or keep \
     direct reflection assertions in blorp test code"
  in
  let debug_only_ref st expr =
    match expr.expr_desc with
    | EIdent name
      when Env.is_debug_only_func state.env name
           || Env.is_debug_only_overload_set state.env name -> (
        match
          typed_expr_semantic_type_for_typecheck
            ~context:"debug-only validation" expr
        with
        | Ok (TyFunc _) -> (st, `DebugOnlyRef name)
        | Ok _ -> (st, `NoDebugOnlyRef)
        | Error err -> (add_error st err, `InvalidDebugOnlyRef))
    | EFieldAccess ({ expr_desc = EIdent alias; _ }, func_name) -> (
        match List.assoc_opt alias state.module_aliases with
        | Some module_path
          when Modules.exported_func_is_debug_only module_path func_name ->
            (st, `DebugOnlyRef func_name)
        | _ -> (st, `NoDebugOnlyRef))
    | _ -> (st, `NoDebugOnlyRef)
  in
  let check_debug_only_ref st expr =
    match debug_only_ref st expr with
    | st, `NoDebugOnlyRef | st, `InvalidDebugOnlyRef -> st
    | st, `DebugOnlyRef name ->
        add_error st
          (error_with ~notes:[] ~help:(Some debug_only_help) expr.expr_loc
             (Printf.sprintf
                "debug-only function '%s' can only be used inside a debug: \
                 block"
                name))
  in
  let rec check_debug_assignments st expr =
    match expr.expr_desc with
    | EAssign _ | ESubscriptAssign _ ->
        add_error st
          (error_with ~notes:[] ~help:(Some debug_help) expr.expr_loc
             "debug: blocks cannot assign")
    | ELambda _ | EFuncDecl _ -> st
    | _ -> List.fold_left check_debug_assignments st (expr_children expr)
  in
  let check_inside_debug st expr =
    let st = check_debug_assignments st expr in
    let impure_calls =
      collect_impure_calls ~strict:true state.env state.module_aliases expr
    in
    List.fold_left
      (fun acc { called_name; call_loc; _ } ->
        add_error acc
          (error_with ~notes:[] ~help:(Some debug_help) call_loc
             (Printf.sprintf "debug: blocks cannot call impure function '%s'"
                called_name)))
      st impure_calls
  in
  let rec walk ~in_debug st expr =
    match expr.expr_desc with
    | EDebugBlock stmts ->
        let st = List.fold_left check_inside_debug st stmts in
        List.fold_left (walk ~in_debug:true) st stmts
    | ECall (callee, args)
      when (not in_debug) && not state.allow_debug_only_calls -> (
        match debug_only_ref st callee with
        | st, `DebugOnlyRef _ | st, `InvalidDebugOnlyRef ->
            (* Direct calls are rejected during inference, before debug
               reflection calls can be constant-folded away. Keep this pass
               focused on function references that remain in the typed tree. *)
            List.fold_left (walk ~in_debug) st args
        | st, `NoDebugOnlyRef ->
            List.fold_left (walk ~in_debug) st (callee :: args))
    | _ ->
        let st =
          if in_debug || state.allow_debug_only_calls then st
          else check_debug_only_ref st expr
        in
        List.fold_left (walk ~in_debug) st (expr_children expr)
  in
  walk ~in_debug:false state body

(** Check if an expression contains concurrent blocks or concurrent for.
    Used by the purify command to reject functions with concurrency. *)
let rec has_concurrency (expr : expr) : bool =
  match expr.expr_desc with
  | EConcurrent _ | EConcurrentFor _ -> true
  | ELambda _ -> false (* don't recurse into nested lambdas *)
  | _ -> List.exists has_concurrency (expr_children expr)

(** Report impure calls as errors for a pure function/lambda *)
let report_impure_calls state ~func_name ~help_msg impure_calls =
  List.fold_left
    (fun s { called_name; call_loc; _ } ->
      let note =
        if is_impure_builtin called_name then
          Printf.sprintf "'%s' is impure because it performs I/O" called_name
        else Printf.sprintf "'%s' is an impure function" called_name
      in
      add_error s
        (error_with ~notes:[ note ] ~help:(Some help_msg) call_loc
           (Printf.sprintf "Pure function '%s' cannot call impure function '%s'"
              func_name called_name)))
    state impure_calls

(** Check purity of pure lambdas nested within an expression.
    This catches pure lambdas inside impure outer functions, which
    collect_impure_calls wouldn't reach since check_purity short-circuits. *)
let rec check_nested_pure_lambdas (state : check_state) (expr : expr) :
    check_state =
  match expr.expr_desc with
  | ELambda func -> (
      let state =
        if func.func_is_pure then
          match func_body_expr_opt func.func_body with
          | Some body ->
              let purity_env =
                List.fold_left
                  (fun env (p : param) ->
                    match (p.param_name, p.param_type) with
                    | Some name, Some ty -> add_var env name ty ()
                    | _ -> env)
                  state.env func.func_params
              in
              let impure_calls =
                collect_impure_calls ~strict:true purity_env
                  state.module_aliases body
              in
              report_impure_calls state ~func_name:"<lambda>"
                ~help_msg:
                  "Remove 'pure' from the lambda, or use a pure alternative"
                impure_calls
          | None -> state
        else state
      in
      (* Recurse into body for further nested pure lambdas *)
      match func_body_expr_opt func.func_body with
      | Some body -> check_nested_pure_lambdas state body
      | None -> state)
  | _ -> List.fold_left check_nested_pure_lambdas state (expr_children expr)

(** Check purity constraints.
    Uses typed_body (from inference) when available, for expr_type on pattern bindings. *)
let check_purity (state : check_state) (func : func_decl)
    ~(typed_body : func_body) : check_state =
  match func_body_expr_opt typed_body with
  | None -> state
  | Some body ->
      let state = validate_debug_usage state body in
      let state = check_nested_pure_lambdas state body in
      if func.func_is_pure then
        let func_name =
          match func.func_name with Some n -> n | None -> "<lambda>"
        in
        (* Check that no parameter has an impure function type *)
        let state =
          List.fold_left
            (fun st (p : param) ->
              match p.param_type with
              | Some ty when Env.is_impure_function_type state.env ty ->
                  let param_name =
                    match p.param_name with Some n -> n | None -> "_"
                  in
                  add_error st
                    (error_at body.expr_loc
                       (Printf.sprintf
                          "Pure function '%s' has impure callback parameter \
                           '%s'. Use 'pure %s' for the parameter type"
                          func_name param_name
                          (type_to_string (Option.get p.param_type))))
              | _ -> st)
            state func.func_params
        in
        let purity_env =
          List.fold_left
            (fun env (p : param) ->
              match (p.param_name, p.param_type) with
              | Some name, Some ty -> add_var env name ty ()
              | _ -> env)
            state.env func.func_params
        in
        let impure_calls =
          collect_impure_calls ~strict:true purity_env state.module_aliases body
        in
        let state =
          report_impure_calls state ~func_name
            ~help_msg:
              "Remove 'pure' from the function signature, or use a pure \
               alternative"
            impure_calls
        in
        (* Check for assignments to module-level mutable vars *)
        let rec check_global_assigns (e : expr) : check_state -> check_state =
         fun st ->
          match e.expr_desc with
          | EAssign (name, _) -> (
              match Env.lookup state.env name with
              | Some { kind = Env.VarSymbol { mutability = Env.Mutable; _ }; _ }
                when not
                       (List.exists
                          (fun (p : param) -> p.param_name = Some name)
                          func.func_params) ->
                  add_error st
                    (error_at e.expr_loc
                       (Printf.sprintf
                          "Pure function '%s' cannot mutate module-level \
                           variable '%s'"
                          func_name name))
              | _ -> st)
          | _ ->
              List.fold_left
                (fun s child -> check_global_assigns child s)
                st (Ast.expr_children e)
        in
        check_global_assigns body state
      else state

(** Collect all recursive calls to a given function name in an expression.
    Tracks tail position: only EBlock (last), EIf (branches), and EMatch (cases)
    propagate tail position. All other sub-expressions are non-tail.
    Uses [Ast.expr_children] for the default non-tail traversal. *)
let rec collect_recursive_calls (func_name : string) (in_tail : bool)
    (expr : expr) : recursive_call_ref list =
  match expr.expr_desc with
  | ECall (callee, args) ->
      let is_recursive =
        match callee.expr_desc with
        | EIdent name -> name = func_name
        | _ -> false
      in
      let this_call =
        if is_recursive then
          [ { rec_call_loc = expr.expr_loc; is_tail = in_tail } ]
        else []
      in
      let arg_calls =
        List.concat_map (collect_recursive_calls func_name false) args
      in
      let callee_calls =
        if is_recursive then []
        else collect_recursive_calls func_name false callee
      in
      this_call @ arg_calls @ callee_calls
  | EBlock exprs -> (
      match List.rev exprs with
      | [] -> []
      | last :: rest ->
          collect_recursive_calls func_name in_tail last
          @ List.concat_map
              (collect_recursive_calls func_name false)
              (List.rev rest))
  | EIf (cond, then_branch, else_branch) -> (
      collect_recursive_calls func_name false cond
      @ collect_recursive_calls func_name in_tail then_branch
      @
      match else_branch with
      | Some e -> collect_recursive_calls func_name in_tail e
      | None -> [])
  | EMatch (scrutinee, cases) ->
      collect_recursive_calls func_name false scrutinee
      @ List.concat_map
          (fun c -> collect_recursive_calls func_name in_tail c.case_body)
          cases
  | ELambda _ -> [] (* Lambda bodies are separate contexts *)
  | _ ->
      List.concat_map
        (collect_recursive_calls func_name false)
        (expr_children expr)

(** Check @tailrec constraint *)
let check_tailrec (state : check_state) (func : func_decl) : check_state =
  if not func.func_is_tailrec then state
  else
    begin match (func.func_name, func_body_expr_opt func.func_body) with
    | Some name, Some body ->
        (* Collect all recursive calls and check if they're in tail position *)
        let calls = collect_recursive_calls name true body in
        let non_tail_calls = List.filter (fun c -> not c.is_tail) calls in
        List.fold_left
          (fun s { rec_call_loc; _ } ->
            add_error s
              (error_at rec_call_loc
                 (Printf.sprintf
                    "@tailrec function '%s' has recursive call not in tail \
                     position. The recursive call's result must be returned \
                     directly, not used in further computation."
                    name)))
          state non_tail_calls
    | _ -> state
    end

(** Check match exhaustiveness in an expression.
    Only EMatch, ECall, and ELambda need special handling; all other nodes
    just recurse into their children via [Ast.expr_children].

    Consumes the typed AST post-[check_function_body], so scrutinee types
    are read from structured expression metadata rather than re-inferred. *)
let rec check_matches_in_expr (state : check_state) (expr : expr) : check_state
    =
  match expr.expr_desc with
  | EMatch (scrutinee, cases) ->
      (* Recurse into all children first *)
      let state =
        List.fold_left check_matches_in_expr state
          (scrutinee :: List.map (fun c -> c.case_body) cases)
      in
      (* Check exhaustiveness using the scrutinee's already-inferred type. *)
      let state =
        match
          typed_expr_semantic_type_for_typecheck
            ~context:"match exhaustiveness checking" scrutinee
        with
        | Ok scrutinee_ty -> (
            match
              check_exhaustiveness state.env scrutinee_ty cases expr.expr_loc
            with
            | Some err -> add_error state err
            | None -> state)
        | Error err -> add_error state err
      in
      (* Check for unreachable arms: patterns after wildcard or duplicate no-arg constructors *)
      let _seen_wildcard, _seen_ctors, state =
        List.fold_left
          (fun (wildcard_seen, seen_ctors, st) case ->
            if wildcard_seen then
              (* Any arm after a wildcard/catch-all is unreachable *)
              ( true,
                seen_ctors,
                add_error st
                  (error_at case.case_body.expr_loc
                     "Unreachable match arm: a previous pattern already \
                      matches all values") )
            else
              let pat = normalize_pattern st.env case.case_pattern in
              let is_wildcard = pattern_is_catch_all st.env pat in
              let ctor_names =
                let rec collect pat =
                  match normalize_pattern st.env pat with
                  | PatConstructor (name, []) -> [ name ]
                  | PatOr pats -> List.concat_map collect pats
                  | _ -> []
                in
                collect pat
              in
              (* Check duplicate no-arg constructors, including alternatives
                 inside earlier or-patterns. *)
              let duplicate_ctors =
                List.filter (fun name -> List.mem name seen_ctors) ctor_names
              in
              let st =
                List.fold_left
                  (fun acc name ->
                    add_error acc
                      (error_at case.case_body.expr_loc
                         (Printf.sprintf
                            "Unreachable match arm: '%s' is already matched \
                             above"
                            name)))
                  st duplicate_ctors
              in
              let new_ctors = ctor_names @ seen_ctors in
              (is_wildcard, new_ctors, st))
          (false, [], state) cases
      in
      state
  | ECall (callee, args) ->
      let state =
        match callee.expr_desc with
        | EIdent name -> check_nested_parallelism state name args
        | EFieldAccess (_, name) -> check_nested_parallelism state name args
        | _ -> state
      in
      List.fold_left check_matches_in_expr state (callee :: args)
  | ELambda func -> (
      match func_body_expr_opt func.func_body with
      | Some body ->
          let env = push_scope state.env in
          let env =
            List.fold_left
              (fun env (p : Ast.param) ->
                match (p.param_name, p.param_type) with
                | Some name, Some ty ->
                    add_var env name
                      (canonical_type_annotation_in_env state env ty)
                      ()
                | _ -> env)
              env func.func_params
          in
          check_matches_in_expr { state with env } body
      | None -> state)
  | _ -> List.fold_left check_matches_in_expr state (expr_children expr)

(** Old operator-trait method spellings. This exists only for diagnostics; the
    old names are not accepted as aliases. *)
let legacy_operator_trait_method_name = function
  | "subtract" -> Some "sub"
  | "multiply" -> Some "mul"
  | "divide" -> Some "div"
  | "remainder" -> Some "mod"
  | "negate" -> Some "neg"
  | "equals" -> Some "eq"
  | "not_equals" -> Some "ne"
  | "less_than" -> Some "lt"
  | "greater_than" -> Some "gt"
  | "less_than_or_equal" -> Some "le"
  | "greater_than_or_equal" -> Some "ge"
  | _ -> None

let missing_trait_method_message (impl_method_names : string list)
    (method_name : string) : string =
  match legacy_operator_trait_method_name method_name with
  | Some legacy when List.mem legacy impl_method_names ->
      Printf.sprintf
        "missing required method '%s' (found old spelling '%s'; rename it to \
         '%s')"
        method_name legacy method_name
  | _ -> Printf.sprintf "missing required method '%s'" method_name

(** Validate a trait impl: check missing methods, supertraits, and method signatures *)
let validate_impl (state : check_state) (impl : impl_decl) (loc : loc) :
    check_state =
  match get_trait state.env impl.impl_trait with
  | None -> state (* Trait not found — might be from a not-yet-loaded module *)
  | Some trait_def ->
      let impl_err msg =
        error_at loc
          (Printf.sprintf "impl %s for %s: %s" impl.impl_trait
             (type_to_string impl.impl_for_type)
             msg)
      in
      (* Check missing required methods *)
      let impl_method_names =
        List.filter_map (fun f -> f.func_name) impl.impl_methods
      in
      let missing =
        List.filter
          (fun tm ->
            (not tm.tm_has_default)
            && not (List.mem tm.tm_name impl_method_names))
          trait_def.td_methods
      in
      let state =
        List.fold_left
          (fun s tm ->
            add_error s
              (impl_err
                 (missing_trait_method_message impl_method_names tm.tm_name)))
          state missing
      in
      (* Check supertraits *)
      let state =
        List.fold_left
          (fun s super ->
            match
              Env.resolve_trait_obligation state.env
                (Env.trait_obligation impl.impl_for_type super)
            with
            | TraitObligationSatisfied -> s
            | TraitObligationUnsatisfied | TraitObligationDeferred ->
                add_error s
                  (impl_err
                     (Printf.sprintf "supertrait '%s' is not implemented" super)))
          state trait_def.td_supertraits
      in
      (* Validate each method signature *)
      List.fold_left
        (fun s func ->
          match func.func_name with
          | None -> s
          | Some name -> (
              match
                List.find_opt (fun tm -> tm.tm_name = name) trait_def.td_methods
              with
              | None -> s
              | Some trait_method ->
                  let resolved =
                    get_resolved_method_sig trait_method impl.impl_for_type
                  in
                  let s =
                    if resolved.tm_is_pure && not func.func_is_pure then
                      add_error s
                        (impl_err
                           (Printf.sprintf "method '%s' must be pure" name))
                    else s
                  in
                  let impl_n = List.length func.func_params in
                  let trait_n = List.length resolved.tm_params in
                  let s =
                    if impl_n <> trait_n then
                      add_error s
                        (impl_err
                           (Printf.sprintf
                              "method '%s' has %d parameters, trait requires %d"
                              name impl_n trait_n))
                    else s
                  in
                  let s =
                    match func.func_return_type with
                    | Some impl_ret
                      when not (types_compatible resolved.tm_return impl_ret) ->
                        add_error s
                          (impl_err
                             (Printf.sprintf
                                "method '%s' returns %s, trait requires %s" name
                                (type_to_string impl_ret)
                                (type_to_string resolved.tm_return)))
                    | _ -> s
                  in
                  if impl_n = trait_n then
                    List.fold_left2
                      (fun s param expected_ty ->
                        match param.param_type with
                        | Some impl_ty
                          when not (types_compatible expected_ty impl_ty) ->
                            add_error s
                              (impl_err
                                 (Printf.sprintf
                                    "method '%s' parameter '%s' has type %s, \
                                     trait requires %s"
                                    name
                                    (Option.value param.param_name ~default:"_")
                                    (type_to_string impl_ty)
                                    (type_to_string expected_ty)))
                        | _ -> s)
                      s func.func_params resolved.tm_params
                  else s))
        state impl.impl_methods

(** Validate main function signature:
    func main(args: List[String]) -> Int:   -- returns exit code
    func main(args: List[String]):          -- void main (implicit exit 0)
    func main(args: List[String]) -> Void:  -- explicit Void also accepted *)
let validate_main_signature state func loc =
  match func.func_name with
  | Some "main" when List.length func.func_params <> 1 ->
      add_error state
        (error_at loc
           "main must have signature: func main(args: List[String]) -> Int:")
  | Some "main" ->
      let param = List.hd func.func_params in
      let valid_param =
        match param.param_type with
        | Some (TyNamed ("List", [ TyNamed ("String", []) ])) -> true
        | _ -> false
      in
      let valid_return =
        match func.func_return_type with
        | Some (TyNamed ("Int", [])) -> true (* explicit -> Int *)
        | Some (TyNamed ("Void", [])) -> true (* explicit -> Void *)
        | None -> true (* omitted: void main *)
        | _ -> false
      in
      if (not valid_param) && not valid_return then
        add_error state
          (error_at loc
             "main must have signature: func main(args: List[String]) -> Int:")
      else if not valid_return then
        add_error state
          (error_at loc
             (Printf.sprintf "main must return Int or Void, got %s"
                (match func.func_return_type with
                | Some t -> type_to_string t
                | None -> "Void")))
      else if not valid_param then
        add_error state
          (error_at loc
             (Printf.sprintf "main parameter must be List[String], got %s"
                (match param.param_type with
                | Some t -> type_to_string t
                | None -> "untyped")))
      else state
  | _ -> state

let rec second_pass (state : check_state) (decls : program) :
    check_state * program =
  let state, rev_decls =
    List.fold_left
      (fun (state, acc) decl ->
        let loc = decl.decl_loc in
        match decl.decl_desc with
        | DFunc func ->
            (* Validate tensor dimension types in function param/return annotations.
           Uses effective type params so auto-generalized dim names are
           recognized during validation. *)
            let effective_params = compute_effective_type_params state func in
            let func_tp =
              effective_type_param_names effective_params
              @ Env.get_type_params state.env
            in
            let validate_annotation st ty =
              match Types.removed_tensor_type_syntax_message ty with
              | Some msg -> add_error st (error_at loc msg)
              | None -> (
                  match Types.validate_tensor_dims func_tp ty with
                  | Some msg -> add_error st (error_at loc msg)
                  | None -> st)
            in
            let state =
              List.fold_left
                (fun st param ->
                  match param.param_type with
                  | Some ty -> validate_annotation st ty
                  | None -> st)
                state func.func_params
            in
            let state =
              match func.func_return_type with
              | Some ty -> validate_annotation state ty
              | None -> state
            in
            let state = validate_main_signature state func loc in
            let state, typed_body = check_function_body state func loc in
            let state = check_purity state func ~typed_body in
            let state = check_tailrec state func in
            let state =
              match func_body_expr_opt typed_body with
              | Some body ->
                  let saved_env = state.env in
                  let env = setup_function_scope state func in
                  let state = check_matches_in_expr { state with env } body in
                  { state with env = saved_env }
              | _ -> state
            in
            (* Persist effective type params (explicit + implicit) so
           downstream passes — especially [core_mono] — can specialize
           functions that rely on implicit generics like
           [pure func get_or(arr: T[#_], default: T) -> T]. *)
            let typed_func =
              preserve_source_return_annotation ~source_func:func
                (canonicalize_func_annotations state
                   {
                     func with
                     func_type_params = effective_params;
                     func_body = typed_body;
                   })
            in
            (state, { decl with decl_desc = DFunc typed_func } :: acc)
        | DVar var_decl ->
            (* Validate tensor dimension types in annotation *)
            let state =
              match var_decl.var_type with
              | Some ty -> (
                  match Types.removed_tensor_type_syntax_message ty with
                  | Some msg -> add_error state (error_at loc msg)
                  | None -> (
                      match
                        Types.validate_tensor_dims
                          (Env.get_type_params state.env)
                          ty
                      with
                      | Some msg -> add_error state (error_at loc msg)
                      | None -> state))
              | None -> state
            in
            (* Check that initializer type matches declared type *)
            let state, typed_value =
              match var_decl.var_type with
              | Some declared_ty -> (
                  let declared_ty =
                    canonical_type_annotation state declared_ty
                  in
                  match
                    Infer.infer_expr_with_annotated_expected
                      (ctx_of_state state) declared_ty var_decl.var_value
                  with
                  | Ok (actual_ty, typed_val) ->
                      if
                        types_compatible
                          ~type_params:(Env.get_type_params state.env)
                          declared_ty actual_ty
                      then (state, Some typed_val)
                      else
                        let name_str =
                          match var_decl.var_name with
                          | Some n -> Printf.sprintf " '%s'" n
                          | None -> ""
                        in
                        ( add_error state
                            (error_at loc
                               (Printf.sprintf
                                  "Type mismatch in variable%s\n\
                                  \    expected: %s\n\
                                  \       found: %s"
                                  name_str
                                  (type_to_string declared_ty)
                                  (type_to_string actual_ty))),
                          Some typed_val )
                  | Error err -> (add_error state err, None))
              | None -> (
                  (* Re-infer untyped var declarations to catch errors.
                 First pass typed these as Void on failure, but now all
                 signatures are available so forward refs resolve. *)
                  let ctx = ctx_of_state state in
                  match infer_expr ctx var_decl.var_value with
                  | Ok (ty, typed_val) ->
                      let bind_ty =
                        inferred_binding_type
                          ~is_mutable:var_decl.var_is_mutable ty
                      in
                      let typed_val =
                        Infer.annotate_inferred_binding_value
                          ~is_mutable:var_decl.var_is_mutable typed_val ty
                      in
                      (* Update env so downstream vars see the resolved type *)
                      let state =
                        match var_decl.var_name with
                        | Some name ->
                            {
                              state with
                              env =
                                add_var state.env name bind_ty
                                  ~mutability:
                                    (if var_decl.var_is_mutable then Mutable
                                     else Immutable)
                                  ();
                            }
                        | None -> state
                      in
                      (state, Some typed_val)
                  | Error err -> (add_error state err, None))
            in
            let typed_value = Option.map Infer.zonk_expr typed_value in
            let state =
              match typed_value with
              | Some tv -> check_matches_in_expr state tv
              | None -> state
            in
            let state, typed_var =
              match typed_value with
              | Some tv ->
                  let state, inferred_ty =
                    match
                      typed_expr_value_type_for_typecheck
                        ~context:"global variable finalization" tv
                    with
                    | Ok ty -> (state, Some ty)
                    | Error err -> (add_error state err, None)
                  in
                  let typed_var =
                    {
                      var_decl with
                      var_type =
                        (match var_decl.var_type with
                        | Some ty -> Some (canonical_type_annotation state ty)
                        | None -> inferred_ty);
                      var_value = tv;
                    }
                  in
                  let state =
                    match (typed_var.var_name, inferred_ty) with
                    | Some name, Some ty
                      when Infer.type_contains_resource (ctx_of_state state) ty
                      ->
                        add_error state
                          (error_at loc
                             (Printf.sprintf
                                "resource value '%s' cannot be bound to a \
                                 global"
                                name))
                    | Some name, Some ty
                      when Infer.type_contains_one_shot_stream state.env ty ->
                        add_error state
                          (error_with loc
                             (Printf.sprintf
                                "one-shot stream value '%s' cannot be bound to \
                                 a global"
                                name)
                             ~notes:
                               [
                                 "Global bindings are shared program state. A \
                                  stream cursor has mutable pull state and \
                                  must stay local to the code that consumes \
                                  it.";
                               ]
                             ~help:
                               (Some
                                  "Create the stream inside a function, keep \
                                   it in a direct local binding while building \
                                   the pipeline, and consume it with a \
                                   terminal stream operation."))
                    | _ -> state
                  in
                  (state, typed_var)
              | None -> (state, var_decl)
            in
            (state, { decl with decl_desc = DVar typed_var } :: acc)
        | DPrivate inner -> (
            match inner.decl_desc with
            | DImpl impl ->
                (* Private impl: validate methods and check for within-module
                coherence (two private impls of the same (trait, for-type)
                would emit duplicate C symbols), but don't register in the
                shared [impl_index] — private impls are module-internal
                and must not satisfy trait bounds for cross-module callers. *)
                let state = check_removed_tensor_impl_syntax state loc impl in
                let state = validate_impl_inline_type_params state loc impl in
                let state = validate_impl state impl loc in
                let inst = make_impl_instance ~loc ~env:state.env impl in
                let state = try_add_private_impl state loc inst in
                let env = set_type_param_bounds state.env inst.ii_bounds in
                let state_with_bounds = { state with env } in
                let state, typed_methods =
                  List.fold_left
                    (fun (s, meths) func ->
                      Option.iter
                        (fun name ->
                          ignore (record_func_callable_id s ~name ~loc))
                        func.func_name;
                      let s =
                        validate_type_params s loc func.func_type_params
                      in
                      let func =
                        {
                          func with
                          func_type_params =
                            inst.ii_bounds @ func.func_type_params;
                        }
                      in
                      let effective = compute_effective_type_params s func in
                      let s, typed_body = check_function_body s func loc in
                      let s = check_purity s func ~typed_body in
                      let typed_func =
                        {
                          (canonicalize_func_annotations s func) with
                          func_type_params = effective;
                          func_body = typed_body;
                        }
                      in
                      (s, typed_func :: meths))
                    (state_with_bounds, []) impl.impl_methods
                in
                let typed_impl =
                  { impl with impl_methods = List.rev typed_methods }
                in
                ( state,
                  {
                    decl with
                    decl_desc =
                      DPrivate { inner with decl_desc = DImpl typed_impl };
                  }
                  :: acc )
            | _ ->
                let state, typed_inner = second_pass state [ inner ] in
                let typed_decl =
                  match typed_inner with
                  | [ d ] -> { decl with decl_desc = DPrivate d }
                  | _ -> decl
                in
                (state, typed_decl :: acc))
        | DImpl impl ->
            let state = check_removed_tensor_impl_syntax state loc impl in
            let state = validate_impl_inline_type_params state loc impl in
            let state = validate_impl state impl loc in
            (* Orphan rule (Phase 3.4): the impl must live in the trait's
           or the type's home module (or a primitive's stdlib home).
           [type_home] is per-module (on [check_state], not [env]),
           so batch-mode typecheck doesn't leak one file's local
           [record Vec2] into another file's home table. *)
            let state =
              match check_orphan state impl loc with
              | None -> state
              | Some err -> add_error state err
            in
            (* Register the impl now that it's validated — but reject it if
           another source-level impl already covers an overlapping
           (trait, for-type) pair. *)
            let inst = make_impl_instance ~loc ~env:state.env impl in
            let state, _registered = try_add_source_impl state loc inst in
            (* Synthesize methods for any trait methods that have default bodies
           but weren't overridden by the impl. The synthesized func_decl
           copies the default body and substitutes TySelf in the signature
           with the impl's for-type; subsequent type-checking runs the body
           just like a user-written method.

           Scope: synthesis fires only for CONCRETE impl for-types.
           Generic impls (e.g. [implements Orderable for (A, B)] with
           free tyvars) would need monomorphization to produce usable
           bodies — the codegen trait registry skips generic for-types,
           so a synthesized body calling a sibling method would fail at
           [Core_trait_resolve] with "no impl of `less_than` for `Tuple2`".
           Deferring generic-impl synthesis until the mono pipeline is
           extended to cover it preserves the pre-Step-5 behavior for
           those cases. *)
            let impl =
              if Codegen_types.has_type_vars impl.impl_for_type then impl
              else
                match get_trait state.env impl.impl_trait with
                | None -> impl
                | Some trait_def ->
                    let has_impl_method name =
                      List.exists
                        (fun (f : func_decl) -> f.func_name = Some name)
                        impl.impl_methods
                    in
                    (* Substitute [TySelf] throughout source annotations in an
                 expression subtree: the [ty] slot of
                 [EVarDecl]/[EQuestionBind]/[EConcurrentBind], and param/return
                 types of nested [ELambda]s. The synthesized method body is
                 re-inferred below, so typed payloads are produced by the
                 normal inference path. *)
                    let subst = resolve_self impl.impl_for_type in
                    let rec subst_body (e : expr) : expr =
                      let desc' =
                        match e.expr_desc with
                        | EVarDecl (name, ty, init, is_mut) ->
                            EVarDecl
                              ( name,
                                Option.map subst ty,
                                subst_body init,
                                is_mut )
                        | EQuestionBind (name, ty, e1) ->
                            EQuestionBind
                              (name, Option.map subst ty, subst_body e1)
                        | EWith (binding, body) ->
                            EWith
                              ( {
                                  binding with
                                  with_type = Option.map subst binding.with_type;
                                  with_value = subst_body binding.with_value;
                                },
                                subst_body body )
                        | EConcurrentBind (name, ty, e1) ->
                            EConcurrentBind
                              (name, Option.map subst ty, subst_body e1)
                        | ELambda inner ->
                            ELambda
                              {
                                inner with
                                func_params =
                                  List.map
                                    (fun (p : param) ->
                                      {
                                        p with
                                        param_type =
                                          Option.map subst p.param_type;
                                      })
                                    inner.func_params;
                                func_return_type =
                                  Option.map subst inner.func_return_type;
                                func_body =
                                  map_func_body_expr subst_body inner.func_body;
                              }
                        | _ -> (expr_map_children subst_body e).expr_desc
                      in
                      { e with expr_desc = desc' }
                    in
                    let prepare_body body = subst_body body in
                    let synthesize (m : trait_method_sig) : func_decl option =
                      if (not m.tm_has_default) || has_impl_method m.tm_name
                      then None
                      else
                        match m.tm_default_body with
                        | None -> None
                        | Some body ->
                            let params =
                              List.mapi
                                (fun i ty ->
                                  let name =
                                    Option.join
                                      (List.nth_opt m.tm_param_names i)
                                  in
                                  {
                                    param_name = name;
                                    param_pattern = None;
                                    param_type = Some (subst ty);
                                    param_passing = ParamByValue;
                                    param_loc = loc;
                                  })
                                m.tm_params
                            in
                            Some
                              {
                                func_name = Some m.tm_name;
                                func_type_params = [];
                                func_params = params;
                                func_return_type = Some (subst m.tm_return);
                                func_body = FuncBodyExpr (prepare_body body);
                                func_is_pure = m.tm_is_pure;
                                func_is_tailrec = false;
                                func_no_copy = false;
                                func_debug_only = false;
                                func_resource_result_ordinary = false;
                                func_dim_constraints = [];
                              }
                    in
                    let synthesized =
                      List.filter_map synthesize trait_def.td_methods
                    in
                    { impl with impl_methods = impl.impl_methods @ synthesized }
            in
            (* Set up bounds in environment for checking the body *)
            let env = set_type_param_bounds state.env inst.ii_bounds in
            (* Step 5 (Option D): register the trait's methods + any
           transitive supertrait methods as trait-function bindings
           locally, just for this impl's body typecheck. Default-body
           synthesis emits bare-name calls (e.g. [less_than(b, a)] in
           [greater_than]'s default). Without these bindings, resolution falls
           through — a file that doesn't [import: traits] has no
           [less_than -> Orderable] entry in [trait_functions].

           Scoping: the additions live on [state_with_bounds.env],
           which threads through the method-body fold below. After
           the fold returns its final state, we restore the original
           [trait_functions] list so nothing leaks to the rest of the
           file — preventing the cross-file name-collision that made
           globally-registered trait functions unworkable (see the
           [std/set.brp] [add] / [Addable.add] conflict from the
           earlier structural attempt). *)
            (* Collect (method_name, declaring_trait) pairs across the impl
           trait and its transitive supertraits. A supertrait method
           must be registered under its OWN declaring trait — a
           default body calling [base_op] in trait [MyDerived: MyBase]
           should dispatch via [MyBase.base_op] since that's where
           [base_op] lives. Registering it as [MyDerived.base_op]
           would fail at dispatch because [MyDerived] has no such
           impl-method. *)
            let rec collect_methods_with_trait visited name =
              if List.mem name visited then []
              else
                match Env.get_trait env name with
                | None -> []
                | Some td ->
                    let own =
                      List.map
                        (fun (m : Env.trait_method_sig) -> (m.tm_name, name))
                        td.td_methods
                    in
                    let from_supers =
                      List.concat_map
                        (collect_methods_with_trait (name :: visited))
                        td.td_supertraits
                    in
                    own @ from_supers
            in
            let method_with_trait =
              if Env.get_trait env impl.impl_trait <> None then
                collect_methods_with_trait [] impl.impl_trait
              else []
            in
            let saved_trait_functions = env.trait_functions in
            let env =
              List.fold_left
                (fun env (mname, trait) ->
                  Env.add_trait_function env mname trait)
                env method_with_trait
            in
            let state_with_bounds = { state with env } in
            let state, typed_methods =
              List.fold_left
                (fun (s, meths) func ->
                  Option.iter
                    (fun name -> ignore (record_func_callable_id s ~name ~loc))
                    func.func_name;
                  let s = validate_type_params s loc func.func_type_params in
                  let func =
                    {
                      func with
                      func_type_params = inst.ii_bounds @ func.func_type_params;
                    }
                  in
                  let effective = compute_effective_type_params s func in
                  let s, typed_body = check_function_body s func loc in
                  let s = check_purity s func ~typed_body in
                  let s =
                    match func_body_expr_opt typed_body with
                    | Some body -> check_matches_in_expr s body
                    | None -> s
                  in
                  let typed_func =
                    preserve_source_return_annotation ~source_func:func
                      {
                        (canonicalize_func_annotations s func) with
                        func_type_params = effective;
                        func_body = typed_body;
                      }
                  in
                  (s, typed_func :: meths))
                (state_with_bounds, []) impl.impl_methods
            in
            (* Restore trait-function bindings to what the file had BEFORE
           this impl. Prevents leakage of trait-method names into the
           rest of the module's name-resolution scope (see comment at
           the registration site above). *)
            let state =
              {
                state with
                env = { state.env with trait_functions = saved_trait_functions };
              }
            in
            let typed_impl =
              { impl with impl_methods = List.rev typed_methods }
            in
            (state, { decl with decl_desc = DImpl typed_impl } :: acc)
        | DType t ->
            (* Second tag-assignment pass. Defensively mint [variant_def_id]
           in case this decl was constructed without going through
           [process_type_decl] — in practice every decl does, but
           guarding here keeps the invariant robust. *)
            let variants =
              List.mapi
                (fun i v ->
                  let def_id =
                    match v.variant_def_id with
                    | Some _ as id -> id
                    | None -> Some (Session.mint_def_id (Session.current ()))
                  in
                  {
                    v with
                    variant_tag = i;
                    variant_def_id = def_id;
                    variant_fields =
                      List.map
                        (canonical_variant_field_type state)
                        v.variant_fields;
                  })
                t.type_variants
            in
            ( state,
              {
                decl with
                decl_desc = DType { t with type_variants = variants };
              }
              :: acc )
        | DRecord r ->
            let fields =
              List.map
                (fun f ->
                  {
                    f with
                    field_type = canonical_record_field_type state f.field_type;
                  })
                r.record_fields
            in
            ( state,
              {
                decl with
                decl_desc = DRecord { r with record_fields = fields };
              }
              :: acc )
        | DTypeAlias a ->
            let alias_target =
              canonical_type_alias_target state a.alias_target
            in
            ( state,
              { decl with decl_desc = DTypeAlias { a with alias_target } }
              :: acc )
        | _ -> (state, decl :: acc))
      (state, []) decls
  in
  (state, List.rev rev_decls)

(* ============================================================================
   Main Entry Point
   ============================================================================ *)

(* Prepend prelude's [DImport] declarations to a main program's decls.
    [std/prelude.brp] is a re-export hub — it contains only [import:]
    statements that bring bare names (e.g. [print], [read_file]) into
    scope from their domain modules ([io], [system], etc.). Those import
    statements are prepended to every main program's decl list so users
    don't need to write [import: io: print] themselves.

    Stdlib modules do NOT get auto-prelude — they must import explicitly.
    This preserves the invariant that a [.brp] file's imports are
    locally visible by reading the top of the file.

    Returns the original program unchanged if [std/prelude] isn't loaded
    (e.g. during tests that bypass the prelude-loading machinery).

    Optional [current_module] is the identity of the module being
    typechecked (e.g. ["std/io"]). When set, prelude imports targeting
    that module are skipped — otherwise typechecking [std/io.brp] would
    try to inject [import: io: print] into io itself (self-import). *)
let prepend_prelude_imports ?(current_module = "") (program : program) : program
    =
  (* Prelude must not inject into itself. *)
  if current_module = "prelude" || current_module = "std/prelude" then program
  else
    match Modules.find_cached "prelude" with
    | None -> program
    | Some m ->
        let rec collect_top_level_names acc d =
          match d.Ast.decl_desc with
          | Ast.DType t ->
              t.Ast.type_name
              :: List.fold_left
                   (fun acc (v : Ast.variant) -> v.Ast.variant_name :: acc)
                   acc t.Ast.type_variants
          | Ast.DRecord r -> r.Ast.record_name :: acc
          | Ast.DTypeAlias a -> a.Ast.alias_name :: acc
          | Ast.DFunc f -> (
              match f.Ast.func_name with
              | Some name -> name :: acc
              | None -> acc)
          | Ast.DVar v -> (
              match v.Ast.var_name with Some name -> name :: acc | None -> acc)
          | Ast.DTrait t -> t.Ast.trait_name :: acc
          | Ast.DPrivate inner -> collect_top_level_names acc inner
          | Ast.DImport _ | Ast.DImpl _ -> acc
        in
        let local_top_level_names =
          List.fold_left collect_top_level_names [] program
          |> List.sort_uniq String.compare
        in
        let import_symbol_local_name (sym : Ast.import_symbol) =
          Option.value sym.Ast.sym_alias ~default:sym.Ast.sym_name
        in
        let drop_local_conflicts_from_prelude_import imp =
          match imp.Ast.import_symbols with
          | None -> Some imp
          | Some syms ->
              let syms =
                List.filter
                  (fun sym ->
                    not
                      (List.mem
                         (import_symbol_local_name sym)
                         local_top_level_names))
                  syms
              in
              if syms = [] then None
              else Some { imp with Ast.import_symbols = Some syms }
        in
        (* Resolve a literal [import_module] string (e.g. ["list"] or
         ["std/list"]) to the canonical module identity — the [m.name]
         stored in the module cache. Different import forms map to the
         same identity, so merge detection must key on the identity,
         not the literal path the user typed. [find_cached] returns
         [None] when the module hasn't been loaded yet; in that case
         fall back to the raw string (merge will be conservative). *)
        let resolve_identity path =
          match Modules.find_cached path with
          | Some m -> m.Modules.name
          | None -> path
        in
        let prelude_imports =
          List.filter_map
            (fun d ->
              match d.Ast.decl_desc with
              | Ast.DImport imp -> (
                  let id = resolve_identity imp.Ast.import_module in
                  (* Drop any prelude import that targets the module currently
               being typechecked — injecting it would be a self-import. *)
                  if id = current_module then None
                  else
                    match drop_local_conflicts_from_prelude_import imp with
                    | None -> None
                    | Some imp ->
                        Some
                          ({ d with Ast.decl_desc = Ast.DImport imp }, imp, id))
              | _ -> None)
            m.decls
        in
        let user_imports =
          List.filter_map
            (fun d ->
              match d.Ast.decl_desc with
              | Ast.DImport imp ->
                  Some (d, imp, resolve_identity imp.Ast.import_module)
              | _ -> None)
            program
        in
        let user_identities = List.map (fun (_, _, id) -> id) user_imports in
        let to_prepend, to_merge =
          List.partition
            (fun (_, _, id) -> not (List.mem id user_identities))
            prelude_imports
        in
        (* Merge: rewrite user's DImport to include prelude's symbols from
         the same module. Only selective imports ([import: io: x, y])
         can be merged; module aliases ([import: io as I]) are left alone
         (the alias form is a user choice — injecting selective symbols
         on top of it would be surprising). *)
        let program =
          List.map
            (fun d ->
              match d.Ast.decl_desc with
              | Ast.DImport user_imp -> (
                  match user_imp.Ast.import_symbols with
                  | None ->
                      d (* module alias or whole-module import; leave alone *)
                  | Some user_syms -> (
                      if
                        List.exists
                          (fun (s : Ast.import_symbol) -> s.sym_name = "*")
                          user_syms
                      then d
                      else
                        let user_id =
                          resolve_identity user_imp.Ast.import_module
                        in
                        match
                          List.find_opt
                            (fun (_, _, id) -> id = user_id)
                            to_merge
                        with
                        | None -> d
                        | Some (_, p_imp, _) -> (
                            match p_imp.Ast.import_symbols with
                            | None -> d
                            | Some p_syms ->
                                (* Union: keep all user's symbols, append any
                            prelude symbols not already in user's list. *)
                                let already =
                                  List.map
                                    (fun (s : Ast.import_symbol) -> s.sym_name)
                                    user_syms
                                in
                                let extra =
                                  List.filter
                                    (fun (s : Ast.import_symbol) ->
                                      not (List.mem s.sym_name already))
                                    p_syms
                                in
                                let merged_syms = user_syms @ extra in
                                let merged_imp =
                                  {
                                    user_imp with
                                    import_symbols = Some merged_syms;
                                  }
                                in
                                { d with decl_desc = Ast.DImport merged_imp })))
              | _ -> d)
            program
        in
        let prepend_decls = List.map (fun (d, _, _) -> d) to_prepend in
        prepend_decls @ program

(** Typecheck a main program and keep the final [check_state] plus the
    source-shaped declaration tree that lines up with the canonical checked
    tree. Typed consumers use both trees so diagnostics/tooling can preserve
    source spelling without exposing aliases to later semantic phases. *)
let typecheck_with_state_and_source ?module_origin ?(module_name = "")
    ?(allow_debug_only_calls = false) (program : program) :
    check_state * program * program =
  (* Phase 2.3: subscript-read desugar runs at the typecheck entry
     rather than inside [Modules.parse_source], so the formatter
     (which also parses) can still see the user's raw [x[i]]
     syntax. *)
  let program = Subscript_desugar.transform_program program in
  (* Auto-prelude: prepend [std/prelude.brp]'s [import:] statements to
     the main program so names like [print], [read_file] resolve without
     the caller writing the import explicitly. Stdlib modules that need
     these names still have to import them directly — this injection
     runs only on the main program path (not [typecheck_module_*]). *)
  let program = prepend_prelude_imports ~current_module:module_name program in
  let source_program = program in
  let state =
    first_pass (init_state ?module_origin ~allow_debug_only_calls ()) program
  in
  let state, typed_program = second_pass state program in
  (state, source_program, typed_program)

(** Typecheck a main program and keep the final [check_state] so callers can
    reuse resolved import metadata downstream. *)
let typecheck_with_state ?module_origin ?(module_name = "")
    ?(allow_debug_only_calls = false) (program : program) :
    check_state * program =
  let state, _source_program, typed_program =
    typecheck_with_state_and_source ?module_origin ~module_name
      ~allow_debug_only_calls program
  in
  (state, typed_program)

let typed_ast_error_to_compiler_error (err : Typed_ast.error) : compiler_error =
  let loc, message =
    match err with
    | MissingExprType { loc; context } ->
        ( loc,
          Printf.sprintf "internal typecheck error: %s missing expression type"
            context )
    | MissingExprTypeInfo { loc; context } ->
        ( loc,
          Printf.sprintf
            "internal typecheck error: %s missing structured expression type \
             metadata"
            context )
    | UnfinalizedExprType { loc; context; ty } ->
        ( loc,
          Printf.sprintf
            "internal typecheck error: %s still contains inference \
             metavariables: %s"
            context (Types.type_to_string ty) )
    | MissingRequiredType { loc; context } ->
        (loc, Printf.sprintf "internal typecheck error: %s missing type" context)
    | UnfinalizedType { loc; context; ty } ->
        ( loc,
          Printf.sprintf
            "internal typecheck error: %s still contains inference \
             metavariables: %s"
            context (Types.type_to_string ty) )
    | InvalidTypeInfo { loc; context; message } ->
        ( loc,
          Printf.sprintf "internal typecheck error: invalid %s: %s" context
            message )
  in
  {
    message;
    loc;
    phase = TypeCheck;
    kind = OtherError;
    notes = [];
    help =
      Some
        "This is a compiler bug: typecheck reported success but did not \
         produce a finalized typed AST.";
  }

let require_typed_program_for_typecheck ?source_program ?state
    (program : program) : (Typed_ast.program, compiler_error list) result =
  let callable_id_of_func =
    Option.map
      (fun state ~name ~loc ->
        Hashtbl.find_opt state.func_callable_ids (func_callable_key ~name loc))
      state
  in
  let typed_result =
    match source_program with
    | Some source_program ->
        Typed_ast.of_ast_program_with_sources ?callable_id_of_func
          ~source_program program
    | None -> Typed_ast.of_ast_program ?callable_id_of_func program
  in
  match typed_result with
  | Ok typed -> Ok typed
  | Error err -> Error [ typed_ast_error_to_compiler_error err ]

let typecheck_with_state_typed ?module_origin ?(module_name = "")
    ?(allow_debug_only_calls = false) (program : program) :
    (check_state * Typed_ast.program, compiler_error list) result =
  let state, source_program, typed_program =
    typecheck_with_state_and_source ?module_origin ~module_name
      ~allow_debug_only_calls program
  in
  match List.rev state.errors with
  | _ :: _ as errors -> Error errors
  | [] ->
      require_typed_program_for_typecheck ~source_program ~state typed_program
      |> Result.map (fun typed -> (state, typed))

let typecheck_typed ?module_origin ?(module_name = "")
    ?(allow_debug_only_calls = false) (program : program) :
    (Typed_ast.program, compiler_error list) result =
  match
    typecheck_with_state_typed ?module_origin ~module_name
      ~allow_debug_only_calls program
  with
  | Ok (_state, typed) -> Ok typed
  | Error _ as e -> e

let typecheck_with_env_typed ?module_origin ?(module_name = "")
    ?(allow_debug_only_calls = false) (program : program) :
    (Typed_ast.program * env, compiler_error list * env) result =
  let state, source_program, typed_program =
    typecheck_with_state_and_source ?module_origin ~module_name
      ~allow_debug_only_calls program
  in
  match List.rev state.errors with
  | _ :: _ as errors -> Error (errors, state.env)
  | [] -> (
      match
        require_typed_program_for_typecheck ~source_program ~state typed_program
      with
      | Ok typed -> Ok (typed, state.env)
      | Error errors -> Error (errors, state.env))

let typecheck_with_env ?module_origin ?(module_name = "")
    ?(allow_debug_only_calls = false) (program : program) :
    program * compiler_error list * env =
  match
    typecheck_with_env_typed ?module_origin ~module_name ~allow_debug_only_calls
      program
  with
  | Ok (typed_program, env) -> (Typed_ast.program_ast typed_program, [], env)
  | Error (errors, env) -> (program, errors, env)

(** Type check a program, returning typed AST and any errors.
    The returned program has expr_type annotations populated by type inference.
    Set [~module_origin:Session.Stdlib_module] to allow stdlib-only [builtin]
    declarations. [~allow_debug_only_calls] permits direct references to [@debug_only]
    functions for explicit debug builds and the test harness. *)
let typecheck ?module_origin ?(module_name = "")
    ?(allow_debug_only_calls = false) (program : program) :
    program * compiler_error list =
  let typed_program, errors, _env =
    typecheck_with_env ?module_origin ~module_name ~allow_debug_only_calls
      program
  in
  (typed_program, errors)

(** Type check a module's declarations, given an env pre-populated with
    imported module signatures (types, functions, records, aliases, impls).
    Returns typed AST and any errors. [module_origin] defaults to user-module
    policy so project modules never receive stdlib-only [builtin] privileges by
    omission. *)

(** Check that public functions don't expose private types in their signatures. *)
let check_private_type_leakage (state : check_state) (decls : program) :
    check_state =
  let private_type_names =
    List.filter_map
      (fun d ->
        match d.decl_desc with
        | DPrivate inner -> (
            match inner.decl_desc with
            | DRecord r -> Some r.record_name
            | DType t -> Some t.type_name
            | DTypeAlias a -> Some a.alias_name
            | _ -> None)
        | _ -> None)
      decls
  in
  if private_type_names = [] then state
  else
    let rec type_uses_private ty =
      match ty with
      | TyNamed (name, args) ->
          List.mem name private_type_names || List.exists type_uses_private args
      | TyFunc { params; return; _ } ->
          List.exists type_uses_private params || type_uses_private return
      | TyTuple elems -> List.exists type_uses_private elems
      | TyRange inner -> type_uses_private inner
      | _ -> false
    in
    List.fold_left
      (fun state decl ->
        match decl.decl_desc with
        | DPrivate _ | DImport _ -> state
        | DFunc f ->
            let func_name =
              match f.func_name with Some n -> n | None -> "<lambda>"
            in
            let state =
              match f.func_return_type with
              | Some ret when type_uses_private ret -> (
                  let priv_name =
                    List.find_opt
                      (fun n ->
                        let rec check t =
                          match t with
                          | TyNamed (name, _) when name = n -> true
                          | TyNamed (_, args) -> List.exists check args
                          | TyFunc { params; return; _ } ->
                              List.exists check params || check return
                          | TyTuple elems -> List.exists check elems
                          | TyRange inner -> check inner
                          | _ -> false
                        in
                        check ret)
                      private_type_names
                  in
                  match priv_name with
                  | Some pn ->
                      add_error state
                        (error_at ~kind:PrivateTypeLeak decl.decl_loc
                           (Printf.sprintf
                              "public function '%s' exposes private type '%s' \
                               in its return type"
                              func_name pn))
                  | None -> state)
              | _ -> state
            in
            List.fold_left
              (fun state param ->
                match param.param_type with
                | Some ty when type_uses_private ty ->
                    add_error state
                      (error_at ~kind:PrivateTypeLeak decl.decl_loc
                         (Printf.sprintf
                            "public function '%s' exposes a private type in \
                             its parameters"
                            func_name))
                | _ -> state)
              state f.func_params
        | _ -> state)
      state decls

let typecheck_module_with_state_and_source ?module_origin ?(module_name = "")
    ?(allow_debug_only_calls = false) (env : env) (decls : program) :
    check_state * program * program =
  (* See Phase 2.3 note in [typecheck_with_env]. *)
  let decls = Subscript_desugar.transform_program decls in
  (* Auto-prelude: inject [std/prelude.brp]'s imports into this module's
     decls too, so stdlib code (e.g., [std/memory.brp]) can use [print]
     without writing [import: io: print] at the top of every file.
     [module_name] guards against self-import (prelude's [import: io]
     is filtered out when typechecking io itself). *)
  let decls = prepend_prelude_imports ~current_module:module_name decls in
  (* [init_state] produces a fresh [type_home] per module — Phase 3.4's
     orphan check sees only types declared/imported by THIS module, so
     two files that each declare a local [record Vec2] don't collide. *)
  let state =
    { (init_state ?module_origin ~allow_debug_only_calls ()) with env }
  in
  let source_decls = decls in
  let state = first_pass state decls in
  let state, typed_decls = second_pass state decls in
  let state = check_private_type_leakage state decls in
  (state, source_decls, typed_decls)

let typecheck_module_with_state ?module_origin ?(module_name = "")
    ?(allow_debug_only_calls = false) (env : env) (decls : program) :
    check_state * program =
  let state, _source_decls, typed_decls =
    typecheck_module_with_state_and_source ?module_origin ~module_name
      ~allow_debug_only_calls env decls
  in
  (state, typed_decls)

let typecheck_module_with_state_typed ?module_origin ?(module_name = "")
    ?(allow_debug_only_calls = false) (env : env) (decls : program) :
    (check_state * Typed_ast.program, check_state * compiler_error list) result
    =
  let state, source_decls, typed_decls =
    typecheck_module_with_state_and_source ?module_origin ~module_name
      ~allow_debug_only_calls env decls
  in
  match List.rev state.errors with
  | _ :: _ as errors -> Error (state, errors)
  | [] -> (
      match
        require_typed_program_for_typecheck ~source_program:source_decls ~state
          typed_decls
      with
      | Ok typed -> Ok (state, typed)
      | Error errors -> Error (state, errors))

let typecheck_module ?module_origin ?(module_name = "")
    ?(allow_debug_only_calls = false) (env : env) (decls : program) :
    program * compiler_error list =
  let state, typed_decls =
    typecheck_module_with_state ?module_origin ~module_name
      ~allow_debug_only_calls env decls
  in
  (typed_decls, List.rev state.errors)
