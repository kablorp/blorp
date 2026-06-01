(** Core dead-code elimination.

    This pass prunes only declaration classes whose reachability can be proven
    from explicit Core identities. It currently removes unreachable concrete
    function bodies, concrete impl methods and now-empty concrete impl blocks,
    compile-time generic templates, and monomorphic non-ABI source type
    declarations. Other declarations stay retained until their dependency
    models are explicit. *)

open Core

type trait_method_key = string * string * string

type constructor_ref =
  | RecordConstructor of { type_name : string; c_name : string }
  | UnionConstructor of {
      parent_type : string;
      variant_name : string;
      c_name : string;
    }

type destructor_ref =
  | RecordDestructor of { type_name : string; c_name : string }
  | UnionDestructor of { type_name : string; c_name : string }

type stack_result_layout_ref = StackResultErased | StackResultManaged

type runtime_builtin_release_path =
  | RuntimeBuiltinArcReleaseOnly
  | RuntimeBuiltinDestructor of string

type erased_record_field_ref = {
  erased_field_name : string;
  erased_field_index : int;
}

type generated_artifact_ref =
  | EnumVariantMacro of {
      type_name : string;
      variant_name : string;
      c_name : string;
    }
  | EnumStringifier of { type_name : string; c_name : string }
  | EnumVectorStringifier of { type_name : string; c_name : string }
  | HeapRecordRuntimeTypeTag of { type_name : string }
  | UnionTagMacro of {
      type_name : string;
      variant_name : string;
      c_name : string;
    }
  | UnionRuntimeTypeTag of { type_name : string }
  | UnionReleaseMask of { type_name : string }
  | RecordErasedFieldReleaseMask of {
      type_name : string;
      erased_fields : erased_record_field_ref list;
    }
  | RuntimeManagedBuiltinLifecycle of {
      type_name : string;
      c_type : string;
      release_path : runtime_builtin_release_path;
    }
  | UnionSingleton of {
      parent_type : string;
      variant_name : string;
      constructor_c_name : string;
      instance_c_name : string;
      init_c_name : string;
    }
  | StackOptionSpecialization of {
      payload_type : string;
      option_c_type : string;
      payload_c_type : string;
    }
  | StackResultSpecialization of {
      c_type : string;
      layout : stack_result_layout_ref;
    }

type decl_ref =
  | FunctionBody of int
  | GlobalDecl of int
  | TypeDecl of string
  | RecordDecl of string
  | TypeAliasDecl of string
  | TraitDecl of string
  | ConstructorDecl of constructor_ref
  | DestructorDecl of destructor_ref
  | GeneratedArtifactDecl of generated_artifact_ref

module DeclRefSet = Set.Make (struct
  type t = decl_ref

  let compare = compare
end)

type root_reason = RootMain | RootGlobalInitializer | RootRetainedByBackend

type type_dependency_context =
  | FunctionSignatureType
  | ExprValueType
  | GlobalBindingType
  | RecordFieldType of { field_name : string }
  | UnionVariantFieldType of { variant_name : string }
  | TypeAliasTargetType
  | ImplReceiverType
  | TraitMethodSignatureType

type constructor_dependency_context =
  | RecordTypeLayout
  | RecordValueConstruction
  | UnionVariantLayout of { variant_name : string }
  | UnionValueConstruction

type destructor_dependency_context = HeapRecordTypeLayout | UnionTypeLayout

type generated_artifact_dependency_context =
  | EnumVariantTagLayout of { variant_name : string }
  | EnumStringification
  | EnumVectorStringification
  | HeapRecordRuntimeTypeTagLayout
  | UnionRuntimeTypeTagLayout
  | UnionVariantTagLayout of { variant_name : string }
  | UnionReleaseMaskLayout
  | RecordErasedFieldReleaseMaskLayout
  | RuntimeManagedBuiltinLifecycleLayout
  | UnionNullaryVariantSingleton of { variant_name : string }
  | SourceGeneratedStackOptionLayout
  | RuntimeOwnedStackOptionLayout
  | BackendGeneratedStackOptionLayout
  | RuntimeOwnedStackResultLayout

type dependency_reason =
  | DirectCall
  | ClosureCreate
  | TaskClosure
  | RuntimeTraitCallback of { trait_name : string; method_name : string }
  | TypeDependency of type_dependency_context
  | ConstructorDependency of constructor_dependency_context
  | DestructorDependency of destructor_dependency_context
  | GeneratedArtifactDependency of generated_artifact_dependency_context

type dependency_edge = { de_target : decl_ref; de_reason : dependency_reason }

type dependency_graph = {
  roots : (decl_ref, root_reason list) Hashtbl.t;
  edges : (decl_ref, dependency_edge list) Hashtbl.t;
}

type dependency_source = Root of root_reason | Decl of decl_ref

type reachability_analysis = {
  reachable : DeclRefSet.t;
  dependency_graph : dependency_graph;
  fail_closed : bool;
  saw_main : bool;
}

type reachability = {
  reg : Codegen_types.registry;
  known_refs : (decl_ref, unit) Hashtbl.t;
  declarations_by_ref : (decl_ref, core_decl) Hashtbl.t;
  concrete_functions_by_id : (int, core_func) Hashtbl.t;
  trait_methods_by_key : (trait_method_key, decl_ref) Hashtbl.t;
  type_decl_refs_by_name : (string, decl_ref list) Hashtbl.t;
  impl_receiver_by_function_id : (int, Ast.type_expr) Hashtbl.t;
  dependency_graph : dependency_graph;
  mutable scan_source : dependency_source option;
  mutable reachable : DeclRefSet.t;
  mutable worklist : decl_ref list;
  mutable fail_closed : bool;
}

type prunable_declaration =
  | PrunableFunction of core_func
  | PrunableType of Ast.type_decl
  | PrunableRecord of Ast.record_decl

let has_concrete_emitted_body (f : core_func) : bool =
  f.cf_body <> None && f.cf_type_params = []

let is_compile_time_function_template (f : core_func) : bool =
  f.cf_type_params <> []

let is_prunable_function (f : core_func) : bool =
  has_concrete_emitted_body f
  && match f.cf_kind with CFUser | CFClosureBody _ -> true | _ -> false

let emitted_impl (i : core_impl) : bool =
  not (Codegen_types.has_type_vars i.ci_for_type)

let is_compile_time_impl_template (i : core_impl) : bool =
  Codegen_types.has_type_vars i.ci_for_type

let monomorphic_record_decl (record_decl : Ast.record_decl) : bool =
  record_decl.record_type_params = []

let monomorphic_type_decl (type_decl : Ast.type_decl) : bool =
  type_decl.type_params = []

let is_global_abi_type_anchor name = Types.is_global_abi_type_name name

let is_prunable_type_decl (type_decl : Ast.type_decl) : bool =
  (not type_decl.type_is_builtin)
  && monomorphic_type_decl type_decl
  && not (is_global_abi_type_anchor type_decl.type_name)

let is_prunable_record_decl (record_decl : Ast.record_decl) : bool =
  (not record_decl.record_is_builtin)
  && monomorphic_record_decl record_decl
  && not (is_global_abi_type_anchor record_decl.record_name)

let prunable_declaration_ref = function
  | PrunableFunction f -> FunctionBody f.cf_def_id
  | PrunableType type_decl -> TypeDecl type_decl.type_name
  | PrunableRecord record_decl -> RecordDecl record_decl.record_name

let classify_prunable_declaration (decl : core_decl) :
    prunable_declaration option =
  match decl.cd_desc with
  | CDFunc f when is_prunable_function f -> Some (PrunableFunction f)
  | CDType type_decl when is_prunable_type_decl type_decl ->
      Some (PrunableType type_decl)
  | CDRecord record_decl when is_prunable_record_decl record_decl ->
      Some (PrunableRecord record_decl)
  | _ -> None

let declaration_exists (state : reachability) decl_ref =
  Hashtbl.mem state.known_refs decl_ref

let create_dependency_graph () =
  { roots = Hashtbl.create 32; edges = Hashtbl.create 128 }

let add_root graph decl_ref reason =
  let existing =
    Option.value (Hashtbl.find_opt graph.roots decl_ref) ~default:[]
  in
  if not (List.exists (( = ) reason) existing) then
    Hashtbl.replace graph.roots decl_ref (reason :: existing)

let add_edge graph source target reason =
  let existing =
    Option.value (Hashtbl.find_opt graph.edges source) ~default:[]
  in
  let already_exists =
    List.exists
      (fun edge -> edge.de_target = target && edge.de_reason = reason)
      existing
  in
  if not already_exists then
    Hashtbl.replace graph.edges source
      ({ de_target = target; de_reason = reason } :: existing)

let add_known_ref (state : reachability) (decl_ref : decl_ref) : unit =
  Hashtbl.replace state.known_refs decl_ref ()

let mark_reachable_decl (state : reachability) (decl_ref : decl_ref) : unit =
  if
    declaration_exists state decl_ref
    && not (DeclRefSet.mem decl_ref state.reachable)
  then begin
    state.reachable <- DeclRefSet.add decl_ref state.reachable;
    state.worklist <- decl_ref :: state.worklist
  end

let mark_dependency (state : reachability) (reason : dependency_reason)
    (target : decl_ref) : unit =
  if declaration_exists state target then begin
    (match state.scan_source with
    | Some (Root root_reason) ->
        add_root state.dependency_graph target root_reason
    | Some (Decl source) -> add_edge state.dependency_graph source target reason
    | None -> ());
    mark_reachable_decl state target
  end

let mark_generated_artifact_dependency (state : reachability)
    (reason : dependency_reason) (target : decl_ref) : unit =
  add_known_ref state target;
  mark_dependency state reason target

let mark_root (state : reachability) (reason : root_reason) (target : decl_ref)
    : unit =
  if declaration_exists state target then begin
    add_root state.dependency_graph target reason;
    mark_reachable_decl state target
  end

let mark_function_dependency (state : reachability) (reason : dependency_reason)
    (def_id : int) : unit =
  mark_dependency state reason (FunctionBody def_id)

let mark_named_type_dependency (state : reachability)
    (context : type_dependency_context) (name : string) : unit =
  match Hashtbl.find_opt state.type_decl_refs_by_name name with
  | None -> ()
  | Some decl_refs ->
      List.iter (mark_dependency state (TypeDependency context)) decl_refs

let record_constructor_ref (record_decl : Ast.record_decl) : decl_ref =
  ConstructorDecl
    (RecordConstructor
       {
         type_name = record_decl.record_name;
         c_name = record_decl.record_name ^ "_make";
       })

let union_constructor_c_name (variant : Ast.variant) : string =
  match variant.variant_def_id with
  | Some id -> Codegen_names.mangle_by_def_id id variant.variant_name
  | None -> variant.variant_name

let union_tag_c_name (type_decl : Ast.type_decl) (variant : Ast.variant) :
    string =
  Printf.sprintf "TAG_%s_%s"
    (Codegen_names.sanitize_c_ident type_decl.type_name)
    (Codegen_names.sanitize_c_ident variant.variant_name)

let union_constructor_ref (type_decl : Ast.type_decl) (variant : Ast.variant) :
    decl_ref =
  ConstructorDecl
    (UnionConstructor
       {
         parent_type = type_decl.type_name;
         variant_name = variant.variant_name;
         c_name = union_constructor_c_name variant;
       })

let enum_variant_macro_ref (type_decl : Ast.type_decl) (variant : Ast.variant) :
    decl_ref =
  GeneratedArtifactDecl
    (EnumVariantMacro
       {
         type_name = type_decl.type_name;
         variant_name = variant.variant_name;
         c_name = union_constructor_c_name variant;
       })

let enum_stringifier_ref (type_decl : Ast.type_decl) : decl_ref =
  let type_c_name = Codegen_names.sanitize_c_ident type_decl.type_name in
  GeneratedArtifactDecl
    (EnumStringifier
       {
         type_name = type_decl.type_name;
         c_name = "__blorp_enum_to_string_" ^ type_c_name;
       })

let enum_vector_stringifier_ref (type_decl : Ast.type_decl) : decl_ref =
  let type_c_name = Codegen_names.sanitize_c_ident type_decl.type_name in
  GeneratedArtifactDecl
    (EnumVectorStringifier
       {
         type_name = type_decl.type_name;
         c_name = "blorp_vector_to_string_" ^ type_c_name;
       })

let union_tag_macro_ref (type_decl : Ast.type_decl) (variant : Ast.variant) :
    decl_ref =
  GeneratedArtifactDecl
    (UnionTagMacro
       {
         type_name = type_decl.type_name;
         variant_name = variant.variant_name;
         c_name = union_tag_c_name type_decl variant;
       })

let union_release_mask_ref (type_decl : Ast.type_decl) : decl_ref =
  GeneratedArtifactDecl (UnionReleaseMask { type_name = type_decl.type_name })

let union_runtime_type_tag_ref (type_decl : Ast.type_decl) : decl_ref =
  GeneratedArtifactDecl
    (UnionRuntimeTypeTag { type_name = type_decl.type_name })

let union_singleton_ref (type_decl : Ast.type_decl) (variant : Ast.variant) :
    decl_ref =
  let constructor_c_name = union_constructor_c_name variant in
  GeneratedArtifactDecl
    (UnionSingleton
       {
         parent_type = type_decl.type_name;
         variant_name = variant.variant_name;
         constructor_c_name;
         instance_c_name = "__instance_" ^ constructor_c_name;
         init_c_name = "__init_" ^ constructor_c_name;
       })

let generated_record_destructor_ref (state : reachability)
    (record_decl : Ast.record_decl) : decl_ref option =
  match
    Core_layout_type.record_destructor_policy ~reg:state.reg record_decl
  with
  | Codegen_types.GeneratedDestructor c_name ->
      Some
        (DestructorDecl
           (RecordDestructor { type_name = record_decl.record_name; c_name }))
  | Codegen_types.ArcReleaseOnly | Codegen_types.RuntimeDestructor _ -> None

let heap_record_runtime_type_tag_ref (record_decl : Ast.record_decl) : decl_ref
    =
  GeneratedArtifactDecl
    (HeapRecordRuntimeTypeTag { type_name = record_decl.record_name })

let erased_record_fields (state : reachability) (record_decl : Ast.record_decl)
    : erased_record_field_ref list =
  record_decl.record_fields
  |> List.mapi (fun erased_field_index (field : Ast.field_decl) ->
      if
        Core_layout_type.record_field_uses_erased_storage ~reg:state.reg
          field.field_type
      then Some { erased_field_name = field.field_name; erased_field_index }
      else None)
  |> List.filter_map Fun.id

let record_erased_field_release_mask_ref (state : reachability)
    (record_decl : Ast.record_decl) : decl_ref option =
  match erased_record_fields state record_decl with
  | [] -> None
  | erased_fields ->
      Some
        (GeneratedArtifactDecl
           (RecordErasedFieldReleaseMask
              { type_name = record_decl.record_name; erased_fields }))

let runtime_managed_builtin_release_path = function
  | "String" | "LiteralString" | "Bytes" | "Fixed" | "MemStats"
  | "SchedulerStats" | "ConcurrencyError" ->
      Some RuntimeBuiltinArcReleaseOnly
  | "StringSlice" -> Some (RuntimeBuiltinDestructor "blorp_slice_destructor")
  | "List" | "ParallelList" ->
      Some (RuntimeBuiltinDestructor "blorp_list_destroy")
  | "Tensor" | "Vector" | "Matrix" | "ParallelVector" ->
      Some (RuntimeBuiltinDestructor "blorp_vector_destroy")
  | "Dict" -> Some (RuntimeBuiltinDestructor "blorp_dict_destroy")
  | "Set" -> Some (RuntimeBuiltinDestructor "blorp_set_destroy")
  | "Task" -> Some (RuntimeBuiltinDestructor "blorp_task_destructor")
  | "Channel" -> Some (RuntimeBuiltinDestructor "blorp_channel_destructor")
  | name when Type_name_metadata.is_stream_name name ->
      Some (RuntimeBuiltinDestructor "blorp_stream_destroy")
  | name when Type_name_metadata.is_fallible_stream_name name ->
      Some (RuntimeBuiltinDestructor "blorp_fallible_stream_destroy")
  | "TcpListener" ->
      Some (RuntimeBuiltinDestructor "blorp_tcp_listener_destructor")
  | "TcpStream" -> Some (RuntimeBuiltinDestructor "blorp_tcp_stream_destructor")
  | _ -> None

let runtime_managed_builtin_lifecycle_ref (state : reachability)
    (ty : Ast.type_expr) : decl_ref option =
  match Codegen_types.expand_alias ~reg:state.reg ty with
  | Ast.TyNamed (type_name, _) -> (
      match runtime_managed_builtin_release_path type_name with
      | None -> None
      | Some release_path ->
          Some
            (GeneratedArtifactDecl
               (RuntimeManagedBuiltinLifecycle
                  {
                    type_name;
                    c_type = Core_layout_type.c_type ~reg:state.reg ty;
                    release_path;
                  })))
  | _ -> None

let stack_option_specialization_ref ~(payload_type : string)
    ~(option_c_type : string) ~(payload_c_type : string) : decl_ref =
  GeneratedArtifactDecl
    (StackOptionSpecialization { payload_type; option_c_type; payload_c_type })

let source_generated_stack_option_ref ~(payload_type : string)
    ~(payload_c_type : string) : decl_ref =
  stack_option_specialization_ref ~payload_type
    ~option_c_type:
      (Codegen_types.generated_stack_option_c_type_name payload_type)
    ~payload_c_type

let runtime_owned_stack_option_ref (state : reachability)
    (payload_ty : Ast.type_expr) : decl_ref option =
  let payload_ty = Codegen_types.expand_alias ~reg:state.reg payload_ty in
  match Codegen_types.primitive_stack_option_c_type_of_payload payload_ty with
  | None -> None
  | Some option_c_type ->
      Some
        (stack_option_specialization_ref
           ~payload_type:(Types.type_to_string payload_ty)
           ~option_c_type
           ~payload_c_type:(Core_layout_type.c_type ~reg:state.reg payload_ty))

let backend_generated_stack_option_ref (state : reachability)
    (payload_ty : Ast.type_expr) : decl_ref option =
  let payload_ty = Codegen_types.expand_alias ~reg:state.reg payload_ty in
  let payload_type =
    match payload_ty with
    | Ast.TyNamed ("Int128", []) -> Some "Int128"
    | Ast.TyNamed ("UInt128", []) -> Some "UInt128"
    | Ast.TyRange _ -> Some "Range"
    | _ -> None
  in
  match payload_type with
  | None -> None
  | Some payload_type -> (
      let option_ty = Ast.TyNamed ("Option", [ payload_ty ]) in
      match
        Core_layout_type.generated_stack_option_get_abi ~reg:state.reg option_ty
      with
      | None -> None
      | Some abi ->
          Some
            (stack_option_specialization_ref ~payload_type
               ~option_c_type:abi.Core_layout_type.gsog_option_c_type
               ~payload_c_type:abi.Core_layout_type.gsog_payload_c_type))

let stack_result_layout_ref_of_layout = function
  | Core_result_layout.StackErased -> StackResultErased
  | Core_result_layout.StackManaged -> StackResultManaged

let runtime_owned_stack_result_ref (state : reachability)
    (result_ty : Ast.type_expr) : decl_ref option =
  match
    ( Core_layout_type.stack_result_layout ~reg:state.reg result_ty,
      Core_layout_type.stack_result_c_type ~reg:state.reg result_ty )
  with
  | Some layout, Some c_type ->
      Some
        (GeneratedArtifactDecl
           (StackResultSpecialization
              { c_type; layout = stack_result_layout_ref_of_layout layout }))
  | None, _ | _, None -> None

let generated_union_destructor_ref (state : reachability)
    (type_decl : Ast.type_decl) : decl_ref option =
  match Core_layout_type.union_destructor_policy ~reg:state.reg type_decl with
  | Codegen_types.GeneratedDestructor c_name ->
      Some
        (DestructorDecl
           (UnionDestructor { type_name = type_decl.type_name; c_name }))
  | Codegen_types.ArcReleaseOnly | Codegen_types.RuntimeDestructor _ -> None

let rec mark_type_dependencies (state : reachability)
    (context : type_dependency_context) (ty : Ast.type_expr) : unit =
  match ty with
  | TyNamed ("Option", [ payload_ty ]) ->
      Option.iter
        (mark_generated_artifact_dependency state
           (GeneratedArtifactDependency RuntimeOwnedStackOptionLayout))
        (runtime_owned_stack_option_ref state payload_ty);
      Option.iter
        (mark_generated_artifact_dependency state
           (GeneratedArtifactDependency BackendGeneratedStackOptionLayout))
        (backend_generated_stack_option_ref state payload_ty);
      mark_named_type_dependency state context "Option";
      mark_type_dependencies state context payload_ty
  | TyNamed ("Result", ([ _; _ ] as args)) ->
      Option.iter
        (mark_generated_artifact_dependency state
           (GeneratedArtifactDependency RuntimeOwnedStackResultLayout))
        (runtime_owned_stack_result_ref state ty);
      mark_named_type_dependency state context "Result";
      List.iter (mark_type_dependencies state context) args
  | TyNamed (name, args) ->
      Option.iter
        (mark_generated_artifact_dependency state
           (GeneratedArtifactDependency RuntimeManagedBuiltinLifecycleLayout))
        (runtime_managed_builtin_lifecycle_ref state ty);
      mark_named_type_dependency state context name;
      List.iter (mark_type_dependencies state context) args
  | TyArray (elem_ty, dim_tys) ->
      mark_type_dependencies state context elem_ty;
      List.iter (mark_type_dependencies state context) dim_tys
  | TyFunc { params; return; _ } ->
      List.iter (mark_type_dependencies state context) params;
      mark_type_dependencies state context return
  | TyTuple tys -> List.iter (mark_type_dependencies state context) tys
  | TyRange ty -> mark_type_dependencies state context ty
  | TyDimOp (_, left, right) ->
      mark_type_dependencies state context left;
      mark_type_dependencies state context right
  | TyVar _ | TyBoundVar _ | TyConstInt _ | TySelf | TyVarDims _ | TyMeta _ ->
      ()

let mark_trait_method (state : reachability) (trait_name : string)
    (method_name : string) (ty : Ast.type_expr) : unit =
  (* Missing callback impls are diagnosed by normal trait/codegen checks. DCE
     only records edges for methods that are actually present in Core. *)
  match Codegen_types.type_key_for_impl ty with
  | None -> ()
  | Some type_name -> (
      match
        Hashtbl.find_opt state.trait_methods_by_key
          (trait_name, method_name, type_name)
      with
      | Some decl_ref ->
          mark_dependency state
            (RuntimeTraitCallback { trait_name; method_name })
            decl_ref
      | None -> ())

let mark_hash_callbacks (state : reachability) (ty : Ast.type_expr) : unit =
  mark_trait_method state "Hashable" "hash" ty;
  mark_trait_method state "Equatable" "equals" ty

let mark_task (state : reachability) (task : task_closure option) : unit =
  match task with
  | None -> ()
  | Some task -> mark_function_dependency state TaskClosure task.tc_def_id

let dict_key_type (state : reachability) (ty : Ast.type_expr) :
    Ast.type_expr option =
  match Core_layout_type.canonical_type ~reg:state.reg ty with
  | Ast.TyNamed ("Dict", key_ty :: _) -> Some key_ty
  | _ -> None

let set_elem_type (state : reachability) (ty : Ast.type_expr) :
    Ast.type_expr option =
  match Core_layout_type.canonical_type ~reg:state.reg ty with
  | Ast.TyNamed ("Set", [ elem_ty ]) -> Some elem_ty
  | _ -> None

let list_elem_type (state : reachability) (ty : Ast.type_expr) :
    Ast.type_expr option =
  match Core_layout_type.canonical_type ~reg:state.reg ty with
  | Ast.TyNamed ("List", [ elem_ty ]) -> Some elem_ty
  | _ -> None

let mark_dict_constructor_callbacks (state : reachability)
    (key_ty : Ast.type_expr) : unit =
  match
    Core_hash_container_layout.dict_constructor_kind ~reg:state.reg key_ty
  with
  | DictCustom callback_ty -> mark_hash_callbacks state callback_ty
  | DictGeneric | DictString | DictFloat -> ()

let mark_set_constructor_callbacks (state : reachability)
    (elem_ty : Ast.type_expr) : unit =
  match
    Core_hash_container_layout.set_constructor_kind ~reg:state.reg elem_ty
  with
  | SetCustom callback_ty -> mark_hash_callbacks state callback_ty
  | SetGeneric | SetString | SetFloat -> ()

let scan_expr (state : reachability) (expr : core) : unit =
  let rec visit e =
    mark_type_dependencies state ExprValueType e.ty;
    let visit_children () =
      Core.fold_immediate_children
        (fun () child ->
          visit child;
          ())
        () e
    in
    match e.desc with
    | CCall (CKUser (_, Some def_id), callee, args) ->
        mark_function_dependency state DirectCall def_id;
        visit callee;
        List.iter visit args
    | CCall (CKUser (_, None), callee, args) ->
        state.fail_closed <- true;
        visit callee;
        List.iter visit args
    | CCall ((CKUnknown | CKSelectedDirect _), callee, args) ->
        state.fail_closed <- true;
        visit callee;
        List.iter visit args
    | CCall (CKClosure, callee, args) ->
        visit callee;
        List.iter visit args
    | CCall (CKBuiltin "blorp_list_to_string_cb", callee, [ list_arg ]) ->
        (match list_elem_type state list_arg.ty with
        | Some elem_ty ->
            mark_trait_method state "Stringable" "to_string" elem_ty
        | None -> state.fail_closed <- true);
        visit callee;
        visit list_arg
    | CCall
        ( CKBuiltin ("blorp_dict_new_custom" | "blorp_dict_with_capacity_custom"),
          callee,
          args ) ->
        (match dict_key_type state e.ty with
        | Some key_ty -> mark_hash_callbacks state key_ty
        | None -> state.fail_closed <- true);
        visit callee;
        List.iter visit args
    | CCall (CKBuiltin "blorp_set_new_custom", callee, args) ->
        (match set_elem_type state e.ty with
        | Some elem_ty -> mark_hash_callbacks state elem_ty
        | None -> state.fail_closed <- true);
        visit callee;
        List.iter visit args
    | CCall ((CKForeign _ | CKBuiltin _ | CKIntrinsic _), callee, args) ->
        visit callee;
        List.iter visit args
    | CClosureCreate closure ->
        mark_function_dependency state ClosureCreate closure.cc_def_id
    | CRecordConstruct rc ->
        mark_generated_artifact_dependency state
          (ConstructorDependency RecordValueConstruction)
          (ConstructorDecl
             (RecordConstructor
                {
                  type_name = rc.rc_type_name;
                  c_name = rc.rc_type_name ^ "_make";
                }));
        visit_children ()
    | CUnionConstruct uc ->
        if uc.uc_args <> [] then
          mark_generated_artifact_dependency state
            (ConstructorDependency UnionValueConstruction)
            (ConstructorDecl
               (UnionConstructor
                  {
                    parent_type = uc.uc_type_name;
                    variant_name = uc.uc_constructor_name;
                    c_name = uc.uc_c_name;
                  }));
        visit_children ()
    | CDict _ ->
        (match dict_key_type state e.ty with
        | Some key_ty -> mark_dict_constructor_callbacks state key_ty
        | None -> ());
        visit_children ()
    | CDictConstruct dc ->
        (match dc.dc_constructor with
        | DictCustom key_ty -> mark_hash_callbacks state key_ty
        | DictGeneric | DictString | DictFloat -> ());
        visit_children ()
    | CSetAlloc sa ->
        (match sa.sa_constructor with
        | SetCustom elem_ty -> mark_hash_callbacks state elem_ty
        | SetGeneric | SetString | SetFloat -> ());
        visit_children ()
    | CRecord [] ->
        (match (dict_key_type state e.ty, set_elem_type state e.ty) with
        | Some key_ty, _ -> mark_dict_constructor_callbacks state key_ty
        | None, Some elem_ty -> mark_set_constructor_callbacks state elem_ty
        | None, None -> ());
        visit_children ()
    | CConcurrent block ->
        List.iter
          (fun binding -> mark_task state binding.cb_task)
          block.conc_bindings;
        visit_children ()
    | CConcurrentlyLoop cf ->
        mark_task state cf.cf_task;
        visit_children ()
    | CDetach detach ->
        mark_task state detach.detach_task;
        visit_children ()
    | _ -> visit_children ()
  in
  visit expr

let scan_function_signature (state : reachability) (f : core_func) : unit =
  List.iter
    (fun (param : core_param) ->
      mark_type_dependencies state FunctionSignatureType param.cp_ty)
    f.cf_params;
  mark_type_dependencies state FunctionSignatureType f.cf_return_ty;
  match Hashtbl.find_opt state.impl_receiver_by_function_id f.cf_def_id with
  | None -> ()
  | Some ty -> mark_type_dependencies state ImplReceiverType ty

let scan_function_decl (state : reachability) (f : core_func) : unit =
  scan_function_signature state f;
  match f.cf_body with None -> () | Some body -> scan_expr state body

let scan_function_body (state : reachability) (f : core_func) : unit =
  match f.cf_body with None -> () | Some body -> scan_expr state body

let scan_global_decl (state : reachability) (v : core_var) : unit =
  mark_type_dependencies state GlobalBindingType v.cv_ty;
  scan_expr state v.cv_init

let scan_type_decl (state : reachability) (type_decl : Ast.type_decl) : unit =
  if monomorphic_type_decl type_decl && not type_decl.type_is_builtin then
    if type_decl.type_is_enum then begin
      mark_generated_artifact_dependency state
        (GeneratedArtifactDependency SourceGeneratedStackOptionLayout)
        (source_generated_stack_option_ref ~payload_type:type_decl.type_name
           ~payload_c_type:"long");
      mark_generated_artifact_dependency state
        (GeneratedArtifactDependency EnumStringification)
        (enum_stringifier_ref type_decl);
      mark_generated_artifact_dependency state
        (GeneratedArtifactDependency EnumVectorStringification)
        (enum_vector_stringifier_ref type_decl);
      List.iter
        (fun (variant : Ast.variant) ->
          mark_generated_artifact_dependency state
            (GeneratedArtifactDependency
               (EnumVariantTagLayout { variant_name = variant.variant_name }))
            (enum_variant_macro_ref type_decl variant))
        type_decl.type_variants
    end
    else begin
      mark_generated_artifact_dependency state
        (GeneratedArtifactDependency UnionRuntimeTypeTagLayout)
        (union_runtime_type_tag_ref type_decl);
      mark_generated_artifact_dependency state
        (GeneratedArtifactDependency UnionReleaseMaskLayout)
        (union_release_mask_ref type_decl);
      List.iter
        (fun (variant : Ast.variant) ->
          mark_generated_artifact_dependency state
            (GeneratedArtifactDependency
               (UnionVariantTagLayout { variant_name = variant.variant_name }))
            (union_tag_macro_ref type_decl variant);
          if variant.variant_fields = [] then
            mark_generated_artifact_dependency state
              (GeneratedArtifactDependency
                 (UnionNullaryVariantSingleton
                    { variant_name = variant.variant_name }))
              (union_singleton_ref type_decl variant)
          else
            mark_generated_artifact_dependency state
              (ConstructorDependency
                 (UnionVariantLayout { variant_name = variant.variant_name }))
              (union_constructor_ref type_decl variant))
        type_decl.type_variants;
      Option.iter
        (mark_generated_artifact_dependency state
           (DestructorDependency UnionTypeLayout))
        (generated_union_destructor_ref state type_decl)
    end;
  List.iter
    (fun (variant : Ast.variant) ->
      List.iter
        (mark_type_dependencies state
           (UnionVariantFieldType { variant_name = variant.variant_name }))
        variant.variant_fields)
    type_decl.type_variants

let scan_record_decl (state : reachability) (record_decl : Ast.record_decl) :
    unit =
  if
    (not record_decl.record_is_builtin)
    && record_decl.record_is_value
    && monomorphic_record_decl record_decl
  then
    mark_generated_artifact_dependency state
      (GeneratedArtifactDependency SourceGeneratedStackOptionLayout)
      (source_generated_stack_option_ref ~payload_type:record_decl.record_name
         ~payload_c_type:record_decl.record_name);
  if
    (not record_decl.record_is_builtin)
    && (not record_decl.record_is_value)
    && monomorphic_record_decl record_decl
  then
    mark_generated_artifact_dependency state
      (GeneratedArtifactDependency HeapRecordRuntimeTypeTagLayout)
      (heap_record_runtime_type_tag_ref record_decl);
  if (not record_decl.record_is_builtin) && not record_decl.record_is_value then
    Option.iter
      (mark_generated_artifact_dependency state
         (GeneratedArtifactDependency RecordErasedFieldReleaseMaskLayout))
      (record_erased_field_release_mask_ref state record_decl);
  if (not record_decl.record_is_builtin) && monomorphic_record_decl record_decl
  then
    mark_generated_artifact_dependency state
      (ConstructorDependency RecordTypeLayout)
      (record_constructor_ref record_decl);
  if
    monomorphic_record_decl record_decl
    && (not record_decl.record_is_value)
    && not record_decl.record_is_builtin
  then
    Option.iter
      (mark_generated_artifact_dependency state
         (DestructorDependency HeapRecordTypeLayout))
      (generated_record_destructor_ref state record_decl);
  List.iter
    (fun (field : Ast.field_decl) ->
      mark_type_dependencies state
        (RecordFieldType { field_name = field.field_name })
        field.field_type)
    record_decl.record_fields

let scan_type_alias_decl (state : reachability)
    (alias_decl : Ast.type_alias_decl) : unit =
  mark_type_dependencies state TypeAliasTargetType alias_decl.alias_target

let scan_trait_decl (state : reachability) (trait_decl : core_trait) : unit =
  List.iter
    (fun method_decl ->
      List.iter
        (fun (param : core_param) ->
          mark_type_dependencies state TraitMethodSignatureType param.cp_ty)
        method_decl.ctm_params;
      Option.iter
        (mark_type_dependencies state TraitMethodSignatureType)
        method_decl.ctm_return_ty)
    trait_decl.ct_methods

let with_scan_source (state : reachability) source f =
  let previous = state.scan_source in
  state.scan_source <- Some source;
  Fun.protect ~finally:(fun () -> state.scan_source <- previous) f

let scan_function_decl_body (state : reachability) (decl_ref : decl_ref)
    (f : core_func) : unit =
  with_scan_source state (Decl decl_ref) (fun () -> scan_function_decl state f)

let collect_reachability_tables (prog : core_program) :
    (decl_ref, unit) Hashtbl.t
    * (decl_ref, core_decl) Hashtbl.t
    * (int, core_func) Hashtbl.t
    * (trait_method_key, decl_ref) Hashtbl.t
    * (string, decl_ref list) Hashtbl.t
    * (int, Ast.type_expr) Hashtbl.t
    * bool =
  let known_refs = Hashtbl.create 128 in
  let declarations_by_ref = Hashtbl.create 128 in
  let concrete_functions_by_id = Hashtbl.create 128 in
  let trait_methods_by_key = Hashtbl.create 128 in
  let type_decl_refs_by_name = Hashtbl.create 128 in
  let impl_receiver_by_function_id = Hashtbl.create 128 in
  let duplicate_decl_ref = ref false in
  let duplicate_def_id = ref false in
  let duplicate_trait_method_key = ref false in
  let add_known_ref decl_ref = Hashtbl.replace known_refs decl_ref () in
  let add_decl_ref decl_ref decl =
    add_known_ref decl_ref;
    if Hashtbl.mem declarations_by_ref decl_ref then duplicate_decl_ref := true
    else Hashtbl.add declarations_by_ref decl_ref decl
  in
  let add_type_decl_ref name decl_ref =
    let refs =
      Option.value (Hashtbl.find_opt type_decl_refs_by_name name) ~default:[]
    in
    Hashtbl.replace type_decl_refs_by_name name (decl_ref :: refs)
  in
  let add_body f =
    if has_concrete_emitted_body f then
      if Hashtbl.mem concrete_functions_by_id f.cf_def_id then
        duplicate_def_id := true
      else begin
        add_known_ref (FunctionBody f.cf_def_id);
        Hashtbl.add concrete_functions_by_id f.cf_def_id f
      end
  in
  let add_impl_method i m =
    add_body m;
    Hashtbl.replace impl_receiver_by_function_id m.cf_def_id i.ci_for_type;
    match Codegen_types.type_key_for_impl i.ci_for_type with
    | None -> ()
    | Some type_name ->
        let key = (i.ci_trait, m.cf_name, type_name) in
        if Hashtbl.mem trait_methods_by_key key then
          duplicate_trait_method_key := true
        else Hashtbl.add trait_methods_by_key key (FunctionBody m.cf_def_id)
  in
  let rec collect_decl decl =
    match decl.cd_desc with
    | CDFunc f -> add_body f
    | CDVar v -> add_decl_ref (GlobalDecl v.cv_def_id) decl
    | CDImpl i when emitted_impl i -> List.iter (add_impl_method i) i.ci_methods
    | CDTrait trait -> add_decl_ref (TraitDecl trait.ct_name) decl
    | CDType type_decl ->
        let decl_ref = TypeDecl type_decl.type_name in
        add_decl_ref decl_ref decl;
        add_type_decl_ref type_decl.type_name decl_ref
    | CDRecord record_decl ->
        let decl_ref = RecordDecl record_decl.record_name in
        add_decl_ref decl_ref decl;
        add_type_decl_ref record_decl.record_name decl_ref
    | CDTypeAlias alias_decl ->
        let decl_ref = TypeAliasDecl alias_decl.alias_name in
        add_decl_ref decl_ref decl;
        add_type_decl_ref alias_decl.alias_name decl_ref
    | CDPrivate inner -> collect_decl inner
    | _ -> ()
  in
  List.iter collect_decl prog;
  ( known_refs,
    declarations_by_ref,
    concrete_functions_by_id,
    trait_methods_by_key,
    type_decl_refs_by_name,
    impl_receiver_by_function_id,
    !duplicate_decl_ref || !duplicate_def_id || !duplicate_trait_method_key )

let seed_roots (state : reachability) (prog : core_program) : bool =
  let saw_main = ref false in
  let rec visit_decl decl =
    match decl.cd_desc with
    | CDFunc f when String.equal f.cf_name "main" ->
        saw_main := true;
        if has_concrete_emitted_body f then
          mark_root state RootMain (FunctionBody f.cf_def_id)
        else
          with_scan_source state (Root RootMain) (fun () ->
              scan_function_body state f)
    | CDFunc f when has_concrete_emitted_body f && not (is_prunable_function f)
      ->
        mark_root state RootRetainedByBackend (FunctionBody f.cf_def_id)
    | CDVar v -> mark_root state RootGlobalInitializer (GlobalDecl v.cv_def_id)
    | CDImpl i when emitted_impl i ->
        List.iter
          (fun m ->
            if has_concrete_emitted_body m && not (is_prunable_function m) then
              mark_root state RootRetainedByBackend (FunctionBody m.cf_def_id))
          i.ci_methods
    | CDPrivate inner -> visit_decl inner
    | _ -> ()
  in
  List.iter visit_decl prog;
  !saw_main

let drain_worklist (state : reachability) : unit =
  while state.worklist <> [] && not state.fail_closed do
    match state.worklist with
    | [] -> ()
    | FunctionBody def_id :: rest -> (
        state.worklist <- rest;
        match Hashtbl.find_opt state.concrete_functions_by_id def_id with
        | None -> ()
        | Some f -> scan_function_decl_body state (FunctionBody def_id) f)
    | decl_ref :: rest -> (
        state.worklist <- rest;
        match Hashtbl.find_opt state.declarations_by_ref decl_ref with
        | None -> ()
        | Some decl ->
            with_scan_source state (Decl decl_ref) (fun () ->
                match decl.cd_desc with
                | CDVar v -> scan_global_decl state v
                | CDType type_decl -> scan_type_decl state type_decl
                | CDRecord record_decl -> scan_record_decl state record_decl
                | CDTypeAlias alias_decl ->
                    scan_type_alias_decl state alias_decl
                | CDTrait trait_decl -> scan_trait_decl state trait_decl
                | CDPrivate _ | CDFunc _ | CDImpl _ | CDImport _ -> ()))
  done

let filter_program (reachable : DeclRefSet.t) (prog : core_program) :
    core_program =
  let keep_prunable_declaration decl =
    match classify_prunable_declaration decl with
    | None -> Some decl
    | Some prunable ->
        if DeclRefSet.mem (prunable_declaration_ref prunable) reachable then
          Some decl
        else None
  in
  let keep_concrete_impl decl i =
    let methods =
      List.filter
        (fun (m : core_func) ->
          (not (is_compile_time_function_template m))
          && ((not (is_prunable_function m))
             || DeclRefSet.mem (FunctionBody m.cf_def_id) reachable))
        i.ci_methods
    in
    if methods = [] then None
    else Some { decl with cd_desc = CDImpl { i with ci_methods = methods } }
  in
  let rec keep_decl decl =
    match decl.cd_desc with
    | CDFunc f when is_compile_time_function_template f -> None
    | CDImpl i when is_compile_time_impl_template i -> None
    | CDImpl i when emitted_impl i -> keep_concrete_impl decl i
    | CDPrivate inner -> (
        match keep_decl inner with
        | None -> None
        | Some inner' -> Some { decl with cd_desc = CDPrivate inner' })
    | _ -> keep_prunable_declaration decl
  in
  List.filter_map keep_decl prog

let analyze_reachability ~(reg : Codegen_types.registry) (prog : core_program) :
    reachability_analysis =
  let ( known_refs,
        declarations_by_ref,
        concrete_functions_by_id,
        trait_methods_by_key,
        type_decl_refs_by_name,
        impl_receiver_by_function_id,
        duplicate_def_id ) =
    collect_reachability_tables prog
  in
  if duplicate_def_id then
    {
      reachable = DeclRefSet.empty;
      dependency_graph = create_dependency_graph ();
      fail_closed = true;
      saw_main = false;
    }
  else
    let state =
      {
        reg;
        known_refs;
        declarations_by_ref;
        concrete_functions_by_id;
        trait_methods_by_key;
        type_decl_refs_by_name;
        impl_receiver_by_function_id;
        dependency_graph = create_dependency_graph ();
        scan_source = None;
        reachable = DeclRefSet.empty;
        worklist = [];
        fail_closed = false;
      }
    in
    let saw_main = seed_roots state prog in
    if not saw_main then
      {
        reachable = state.reachable;
        dependency_graph = state.dependency_graph;
        fail_closed = true;
        saw_main;
      }
    else begin
      drain_worklist state;
      {
        reachable = state.reachable;
        dependency_graph = state.dependency_graph;
        fail_closed = state.fail_closed;
        saw_main;
      }
    end

let prune_unreachable_declarations ~(reg : Codegen_types.registry)
    (prog : core_program) : core_program =
  let analysis = analyze_reachability ~reg prog in
  if (not analysis.saw_main) || analysis.fail_closed then prog
  else filter_program analysis.reachable prog
