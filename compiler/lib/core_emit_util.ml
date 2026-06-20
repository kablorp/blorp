(** Non-recursive helpers used by the [Core_emit] mutual-recursion
    block. Extracted in Phase 5.1 step 1 to reduce [core_emit.ml]'s
    size; every function here is a pure helper that neither takes
    nor calls into the main [emit_expr]/[emit_stmt]/[emit_intrinsic]
    chain.

    The big rec-chain in [core_emit.ml] itself cannot be split trivially because
    [emit_expr] and friends are a deep cycle; full extraction requires a
    late-binding interface for the recursive emit helpers. *)

open Core
open Core_emit_context
open Codegen_types

let is_pointer_type (ctx : Core_emit_context.t) ty =
  Core_layout_type.is_pointer_type ~reg:ctx.reg ty

(* ============================================================================
   Helpers
   ============================================================================ *)

let nullable_managed_option_payload_type (ctx : Core_emit_context.t)
    (ty : Ast.type_expr) : Ast.type_expr option =
  Core_layout_type.nullable_managed_option_payload_type ~reg:ctx.reg ty

let is_nullable_managed_option (ctx : Core_emit_context.t) ty =
  nullable_managed_option_payload_type ctx ty <> None

let value_record_c_type (ctx : Core_emit_context.t) ty =
  Core_layout_type.value_record_c_type ~reg:ctx.reg ty

let value_record_layout (ctx : Core_emit_context.t) ty =
  Core_layout_type.value_record_layout_of_type ~reg:ctx.reg ty

let is_value_record_type (ctx : Core_emit_context.t) ty =
  Option.is_some (value_record_layout ctx ty)

let rec type_to_c (ctx : Core_emit_context.t) ty =
  match nullable_managed_option_payload_type ctx ty with
  | Some payload_ty -> type_to_c ctx payload_ty
  | None -> Core_layout_type.c_type ~reg:ctx.reg ty

let value_record_storage_c_type ctx ty =
  match value_record_c_type ctx ty with
  | Some c_ty -> c_ty
  | None -> type_to_c ctx ty

(** Emit a binary operator symbol. Matches the existing codegen. *)
let emit_binop ctx = function
  | Ast.Add -> emit ctx " + "
  | Sub -> emit ctx " - "
  | Mul -> emit ctx " * "
  | Div -> emit ctx " / "
  | Mod -> emit ctx " % "
  | Lt -> emit ctx " < "
  | Gt -> emit ctx " > "
  | Le -> emit ctx " <= "
  | Ge -> emit ctx " >= "
  | Eq -> emit ctx " == "
  | Ne -> emit ctx " != "

let emit_logop ctx = function
  | Ast.And -> emit ctx " && "
  | Or -> emit ctx " || "

(** [not_yet name loc] — raise for deferred variants with location info. *)
let not_yet name (loc : Ast.loc) =
  Core_error.errorf Core_error.Emit loc
    ~hint:"this Core form is not yet implemented in the C emitter"
    "%s not yet supported" name

(** Does this type contain any type variables? Delegates to the canonical
    check in [Codegen_mono] so TyDimOp/TyVarDims/TyMeta stay in sync. *)
let has_type_vars = Codegen_types.has_type_vars

(** Is this type [Void]? Used to special-case void bindings in [CLet]. *)
let is_void_ty ty =
  match normalize_type ty with Ast.TyNamed ("Void", []) -> true | _ -> false

(** Classification of a Core value for boxing into [void*].

    Floats need dedicated box helpers because they don't fit in [void*]
    on 32-bit targets and need special handling for NaN-tagging.
    [Int128]/[UInt128] need their own boxes — a [(void* )(long)] cast
    would truncate. Pointers pass through. Small primitives cast via
    [(void* )(long)]. Anything else raises loudly so the silent-truncate
    bug can't recur. *)
type box_kind = Core.box_kind =
  | BoxFloat
  | BoxFloat32
  | BoxFloat16
  | BoxInt128
  | BoxUInt128
  | BoxVoid
  | BoxPointer
  | BoxPrim
  | BoxStruct of string
      (** struct type name — needs heap boxing via blorp_box_struct *)

type inline_storage_width = Core.inline_storage_width =
  | InlineBytes1
  | InlineBytes2
  | InlineBytes4
  | InlineBytes8

let inline_storage_width_bytes = Core.inline_storage_width_bytes

type list_storage_slot_layout = Core.list_storage_slot_layout =
  | ListPointerStorage
  | ListInlineStorage of inline_storage_width
  | ListInlineStructStorage of string

type storage_ownership = Core.storage_ownership =
  | StorageManaged
  | StorageUnmanaged
  | StorageUnknownOwnership of string

type storage_retain_policy = Core.storage_retain_policy =
  | StorageNoRetain
  | StorageArcRetain
  | StorageUnknownRetain of string

type storage_release_policy = Core.storage_release_policy =
  | StorageNoRelease
  | StorageArcRelease
  | StorageUnknownRelease of string

type storage_equality_policy = Core.storage_equality_policy =
  | StorageEqualityBits
  | StorageEqualityPointer
  | StorageUnknownEquality of string

type container_storage_policy = Core.container_storage_policy =
  | StoragePolicyUnmanagedBits
  | StoragePolicyManagedPointer
  | StoragePolicyOwnedErasedBox
  | StoragePolicyUnknown of string

type list_element_value_layout = Core.list_element_value_layout =
  | ListElementPointer
  | ListElementInlineBits of inline_storage_width
  | ListElementStackStruct of string
  | ListElementBoxedValue
  | ListElementUnknownValue of string

type list_storage_layout = Core.list_storage_layout = {
  lsl_slots : list_storage_slot_layout;
  lsl_elem_ty : Ast.type_expr option;
  lsl_value_layout : list_element_value_layout;
  lsl_policy : container_storage_policy;
}

let classify_for_boxing (ctx : Core_emit_context.t) (ty : Ast.type_expr)
    (loc : Ast.loc) : Core.box_kind =
  Core_layout_type.box_kind_of_type ~phase:Core_error.Emit ~reg:ctx.reg ty loc

let classify_for_unboxing (ctx : Core_emit_context.t) (ty : Ast.type_expr)
    (loc : Ast.loc) : Core.unbox_kind =
  Core_layout_type.unbox_kind_of_type ~phase:Core_error.Emit ~reg:ctx.reg ty loc

let list_storage_layout_of_type (ctx : Core_emit_context.t)
    (list_ty : Ast.type_expr) (loc : Ast.loc) : list_storage_layout =
  Core_emit_layout.list_storage_layout_of_type ctx list_ty loc

let tensor_element_storage (ctx : Core_emit_context.t) elem_ty =
  Core_emit_layout.tensor_element_storage ctx elem_ty

let tensor_storage_layout_of_type (ctx : Core_emit_context.t)
    (tensor_ty : Ast.type_expr) (loc : Ast.loc) : tensor_storage_layout =
  Core_emit_layout.tensor_storage_layout_of_type ctx tensor_ty loc

let tensor_storage_layout_of_elem (ctx : Core_emit_context.t)
    (elem_ty : Ast.type_expr) (loc : Ast.loc) : tensor_storage_layout =
  Core_emit_layout.tensor_storage_layout_of_elem ctx elem_ty loc

module StringSet = Set.Make (String)
module StringMap = Map.Make (String)

(** Collect free variables in a Core expression with their types.
    Returns a sorted list of (name, type) pairs. *)
let collect_free_vars (e : core) : (string * Ast.type_expr) list =
  let rec go_ctree bound = function
    | CTLeaf { ct_bindings; ct_body } ->
        let inner =
          List.fold_left
            (fun s binding -> StringSet.add binding.mb_var.vname s)
            bound ct_bindings
        in
        go inner ct_body
    | CTFail -> StringMap.empty
    | CTSwitchTag { cts_cases; cts_default; _ } ->
        let cases =
          List.fold_left
            (fun acc (_, sub) ->
              StringMap.union (fun _ a _ -> Some a) acc (go_ctree bound sub))
            StringMap.empty cts_cases
        in
        let default =
          match cts_default with
          | Some d -> go_ctree bound d
          | None -> StringMap.empty
        in
        StringMap.union (fun _ a _ -> Some a) cases default
    | CTSwitchLit { ctl_cases; ctl_default; _ } ->
        let cases =
          List.fold_left
            (fun acc (_, sub) ->
              StringMap.union (fun _ a _ -> Some a) acc (go_ctree bound sub))
            StringMap.empty ctl_cases
        in
        StringMap.union (fun _ a _ -> Some a) cases (go_ctree bound ctl_default)
    | CTSwitchLen { ctl_len_cases; ctl_len_geq; ctl_len_default; _ } ->
        let cases =
          List.fold_left
            (fun acc (_, sub) ->
              StringMap.union (fun _ a _ -> Some a) acc (go_ctree bound sub))
            StringMap.empty ctl_len_cases
        in
        let geq =
          match ctl_len_geq with
          | Some (_, sub) -> go_ctree bound sub
          | None -> StringMap.empty
        in
        let default =
          match ctl_len_default with
          | Some d -> go_ctree bound d
          | None -> StringMap.empty
        in
        StringMap.union
          (fun _ a _ -> Some a)
          cases
          (StringMap.union (fun _ a _ -> Some a) geq default)
  and go bound e =
    match e.desc with
    | CVar v ->
        if StringSet.mem v.vname bound then StringMap.empty
        else StringMap.singleton v.vname e.ty
    | CLit _ | CVoid | CBreak | CContinue | CCooperativeCheckpoint ->
        StringMap.empty
    | CLet (b, body) ->
        let rhs = go bound b.bind_rhs in
        let body = go (StringSet.add b.bind_var.vname bound) body in
        StringMap.union (fun _ a _ -> Some a) rhs body
    | CBorrowLet (b, body) ->
        let rhs = go bound b.borrow_rhs in
        let body = go (StringSet.add b.borrow_var.vname bound) body in
        StringMap.union (fun _ a _ -> Some a) rhs body
    | CLambda lam ->
        let inner =
          List.fold_left
            (fun s (v, _) -> StringSet.add v.vname s)
            bound lam.lam_params
        in
        go inner lam.lam_body
    | CClosureCreate cc ->
        (* Captures are the free variables *)
        List.fold_left
          (fun acc (n, ty) ->
            if StringSet.mem n bound then acc else StringMap.add n ty acc)
          StringMap.empty cc.cc_captures
    | CCall (kind, callee, args) -> (
        (* For direct calls (anything other than CKUnknown/CKClosure), the
           callee is emitted by kind, not by walking [callee]. Skip the callee
           so its CVar doesn't appear as a captured free variable. *)
        let args_frees =
          List.fold_left
            (fun acc a ->
              StringMap.union (fun _ a _ -> Some a) acc (go bound a))
            StringMap.empty args
        in
        match kind with
        | CKUnknown | CKClosure ->
            let c = go bound callee in
            StringMap.union (fun _ a _ -> Some a) c args_frees
        | CKSelectedDirect _ | CKUser _ | CKForeign _ | CKBuiltin _
        | CKIntrinsic _ ->
            args_frees)
    | CFor (binder, iter, body) ->
        let i = go bound iter in
        let b = go (StringSet.add binder.loop_var.vname bound) body in
        StringMap.union (fun _ a _ -> Some a) i b
    | CListHandoff h ->
        let source = go bound h.lh_source in
        let capacity = go bound h.lh_capacity in
        let inner =
          bound
          |> StringSet.add h.lh_source_var.vname
          |> StringSet.add h.lh_result_var.vname
          |> StringSet.add h.lh_len_var.vname
          |> StringSet.add h.lh_out_var.vname
        in
        let body = go inner h.lh_body in
        StringMap.union
          (fun _ a _ -> Some a)
          source
          (StringMap.union (fun _ a _ -> Some a) capacity body)
    | CResourceScope scope ->
        let acquire = go bound scope.rs_acquire in
        let scope_bound = StringSet.add scope.rs_var.vname bound in
        let body = go scope_bound scope.rs_body in
        let cleanup = go scope_bound scope.rs_cleanup in
        StringMap.union
          (fun _ a _ -> Some a)
          acquire
          (StringMap.union (fun _ a _ -> Some a) body cleanup)
    | CConcurrentlyLoop cf ->
        let i = go bound cf.cf_iter in
        let b = go (StringSet.add cf.cf_var.vname bound) cf.cf_body in
        let timeout =
          match cf.cf_timeout with
          | Some t -> go bound t
          | None -> StringMap.empty
        in
        StringMap.union
          (fun _ a _ -> Some a)
          i
          (StringMap.union (fun _ a _ -> Some a) b timeout)
    | CMatchArms (scrut, arms) ->
        let s = go bound scrut in
        let a =
          List.fold_left
            (fun acc (pat, body) ->
              let pvars = pat_vars pat in
              let inner =
                List.fold_left (fun s n -> StringSet.add n s) bound pvars
              in
              StringMap.union (fun _ a _ -> Some a) acc (go inner body))
            StringMap.empty arms
        in
        StringMap.union (fun _ a _ -> Some a) s a
    | CMatch (scrut, tree) ->
        let s = go bound scrut in
        let t = go_ctree bound tree in
        StringMap.union (fun _ a _ -> Some a) s t
    | _ ->
        let acc = ref StringMap.empty in
        let _ =
          map_children
            (fun c ->
              acc := StringMap.union (fun _ a _ -> Some a) !acc (go bound c);
              c)
            e
        in
        !acc
  in
  let free = go StringSet.empty e in
  StringMap.bindings free

(** Like [collect_free_vars] but filters out constructor names
    (they're [#define] macros, not capturable variables), module-alias
    references (sentinel [TyNamed "Module"] from [Core_lower]), and UFCS-
    mangled function names (resolved at call site, not value-carrying). *)
let collect_free_vars_filtered (ctx : Core_emit_context.t) (e : core) :
    (string * Ast.type_expr) list =
  collect_free_vars e
  |> List.filter (fun (n, ty) ->
      (not (Hashtbl.mem ctx.constructor_names n))
      && (not (Hashtbl.mem ctx.global_names n))
      && (match ty with Ast.TyNamed ("Module", []) -> false | _ -> true)
      &&
      match Codegen_names.parse_ufcs_name n with
      | Some _ -> false
      | None -> true)

(** Does this type need a generated release operation when ownership is
    consumed? Unknown named types are compiler invariant violations:
    guessing would either leak a managed value or release an unmanaged
    foreign pointer. *)
let type_requires_release (ctx : Core_emit_context.t) (ty : Ast.type_expr) :
    bool =
  Core_layout_type.source_value_requires_release_or_error ~phase:Core_error.Emit
    ~reg:ctx.reg ty Ast.dummy_loc

(** Does this type need a generated retain operation when ownership is
    shared? Unknown named types are compiler invariant violations, just
    like release classification. *)
let type_requires_retain (ctx : Core_emit_context.t) (ty : Ast.type_expr) : bool
    =
  Core_layout_type.source_value_requires_retain_or_error ~phase:Core_error.Emit
    ~reg:ctx.reg ty Ast.dummy_loc

let is_stack_result_type (ctx : Core_emit_context.t) (ty : Ast.type_expr) : bool
    =
  Core_layout_type.is_stack_result_type ~reg:ctx.reg ty

let retain_value_call (ctx : Core_emit_context.t) (ty : Ast.type_expr)
    (c_expr : string) : string =
  if is_stack_result_type ctx ty then
    Printf.sprintf "blorp_stack_result_retain(%s)" c_expr
  else Printf.sprintf "blorp_retain(%s)" c_expr

let release_value_call (ctx : Core_emit_context.t) (ty : Ast.type_expr)
    (c_expr : string) : string =
  if is_stack_result_type ctx ty then
    Printf.sprintf "blorp_stack_result_release(%s)" c_expr
  else
    let layout =
      Core_layout_type.source_value_layout_of_type ~phase:Core_error.Emit
        ~reg:ctx.reg ty Ast.dummy_loc
    in
    match Core_layout_type.source_value_release_path layout with
    | Core_layout_type.SourceValueArcReleaseOnly ->
        Printf.sprintf "blorp_release_arc_only(%s)" c_expr
    | Core_layout_type.SourceValueArcReleaseWithDestructor
    | Core_layout_type.SourceValueNoRelease ->
        Printf.sprintf "blorp_release(%s)" c_expr

let cancellation_cleanup_release_fn (ctx : Core_emit_context.t)
    (ty : Ast.type_expr) : string option =
  if is_stack_result_type ctx ty then
    if type_requires_release ctx ty then Some "blorp_cleanup_stack_result_value"
    else None
  else if not (type_requires_release ctx ty) then None
  else if not (is_pointer_type ctx ty) then None
  else
    let layout =
      Core_layout_type.source_value_layout_of_type ~phase:Core_error.Emit
        ~reg:ctx.reg ty Ast.dummy_loc
    in
    match Core_layout_type.source_value_release_path layout with
    | Core_layout_type.SourceValueArcReleaseOnly ->
        Some "blorp_cleanup_release_arc_only_value"
    | Core_layout_type.SourceValueArcReleaseWithDestructor ->
        Some "blorp_cleanup_release_arc_value"
    | Core_layout_type.SourceValueNoRelease -> None

let cancellation_cleanup_value_arg (ctx : Core_emit_context.t)
    (ty : Ast.type_expr) ~(slot_c : string) ~(value_c : string) : string =
  if is_stack_result_type ctx ty then Printf.sprintf "(void*)&%s" slot_c
  else Printf.sprintf "(void*)%s" value_c

(** Box a C expression to [void*] for storage in generic containers,
    closure environments, or variant fields. Single source of truth
    for the type → box-function dispatch. *)
let emit_box_to_void ?(loc = Ast.dummy_loc) (ctx : Core_emit_context.t)
    (c_expr : string) (ty : Ast.type_expr) : unit =
  match Core_layout_type.stack_option_c_type ~reg:ctx.reg ty with
  | Some c_ty ->
      emit ctx (Printf.sprintf "blorp_box_struct(&%s, sizeof(%s))" c_expr c_ty)
  | None -> (
      match Core_layout_type.stack_result_c_type ~reg:ctx.reg ty with
      | Some _ ->
          emit ctx
            (Printf.sprintf
               "blorp_box_stack_result(blorp_stack_result_retain_value(%s))"
               c_expr)
      | None -> (
          match classify_for_boxing ctx ty loc with
          | BoxFloat -> emit ctx (Printf.sprintf "blorp_box_float(%s)" c_expr)
          | BoxFloat32 ->
              emit ctx (Printf.sprintf "blorp_box_float32(%s)" c_expr)
          | BoxFloat16 ->
              emit ctx (Printf.sprintf "blorp_box_float16(%s)" c_expr)
          | BoxInt128 -> emit ctx (Printf.sprintf "blorp_box_int128(%s)" c_expr)
          | BoxUInt128 ->
              emit ctx (Printf.sprintf "blorp_box_uint128(%s)" c_expr)
          | BoxVoid -> emit ctx "(void*)0"
          | BoxStruct c_ty ->
              emit ctx
                (Printf.sprintf "blorp_box_struct(&%s, sizeof(%s))" c_expr c_ty)
          | BoxPrim -> emit ctx (Printf.sprintf "(void*)(long)%s" c_expr)
          | BoxPointer ->
              if type_requires_retain ctx ty then
                emit ctx
                  (Printf.sprintf "(void*)blorp_retain((blorp_Object*)%s)"
                     c_expr)
              else emit ctx (Printf.sprintf "(void*)%s" c_expr)))

(** Generate the unbox declaration string for a given type.
    Single source of truth for void* → typed variable declaration. *)
let unbox_decl_str ?(loc = Ast.dummy_loc) (ctx : Core_emit_context.t)
    (var_name : string) (source : string) (ty : Ast.type_expr) : string =
  let ty_c = type_to_c ctx ty in
  match Core_layout_type.stack_option_c_type ~reg:ctx.reg ty with
  | Some c_ty ->
      Printf.sprintf "%s %s = *(%s*)((char*)%s + sizeof(blorp_Object));" c_ty
        var_name c_ty source
  | None -> (
      match Core_layout_type.stack_result_c_type ~reg:ctx.reg ty with
      | Some c_ty ->
          Printf.sprintf "%s %s = *(%s*)((char*)%s + sizeof(blorp_Object));"
            c_ty var_name c_ty source
      | None -> (
          match classify_for_unboxing ctx ty loc with
          | UnboxFloat ->
              Printf.sprintf "double %s = blorp_unbox_float(%s);" var_name
                source
          | UnboxFloat32 ->
              Printf.sprintf "float %s = blorp_unbox_float32(%s);" var_name
                source
          | UnboxFloat16 ->
              Printf.sprintf "_Float16 %s = blorp_unbox_float16(%s);" var_name
                source
          | UnboxInt128 ->
              Printf.sprintf "__int128 %s = blorp_unbox_int128(%s);" var_name
                source
          | UnboxUInt128 ->
              Printf.sprintf "unsigned __int128 %s = blorp_unbox_uint128(%s);"
                var_name source
          | UnboxPrim ->
              Printf.sprintf "%s %s = (%s)(long)%s;" ty_c var_name ty_c source
          | UnboxStruct _ ->
              Printf.sprintf "%s %s = *(%s*)((char*)%s + sizeof(blorp_Object));"
                ty_c var_name ty_c source
          | UnboxPointer ->
              Printf.sprintf "%s %s = (%s)%s;" ty_c var_name ty_c source))

let normalize_accessed_type (ctx : Core_emit_context.t) ty =
  Core_layout_type.canonical_type ~reg:ctx.reg ty

let rec accessor_type (ctx : Core_emit_context.t) (scrut_ty : Ast.type_expr)
    (acc : accessor) : Ast.type_expr option =
  match acc with
  | AccRoot -> Some (normalize_accessed_type ctx scrut_ty)
  | AccTupleField (parent, idx) -> (
      match accessor_type ctx scrut_ty parent with
      | Some parent_ty -> (
          match normalize_accessed_type ctx parent_ty with
          | Ast.TyTuple elems -> List.nth_opt elems idx
          | _ -> None)
      | None -> None)
  | AccListElem (parent, _) -> (
      match accessor_type ctx scrut_ty parent with
      | Some parent_ty -> (
          match normalize_accessed_type ctx parent_ty with
          | Ast.TyNamed ("List", [ elem ]) -> Some elem
          | _ -> None)
      | None -> None)
  | AccListSpread (parent, _) -> accessor_type ctx scrut_ty parent
  | AccVariantField (parent, ctor, idx) -> (
      match (accessor_type ctx scrut_ty parent, ctor, idx) with
      | Some parent_ty, "Some", 0 -> (
          match normalize_accessed_type ctx parent_ty with
          | Ast.TyNamed ("Option", [ payload ]) -> Some payload
          | _ -> None)
      | Some parent_ty, "Ok", 0 -> (
          match normalize_accessed_type ctx parent_ty with
          | Ast.TyNamed ("Result", [ ok_ty; _ ]) -> Some ok_ty
          | _ -> None)
      | Some parent_ty, "Err", 0 -> (
          match normalize_accessed_type ctx parent_ty with
          | Ast.TyNamed ("Result", [ _; err_ty ]) -> Some err_ty
          | _ -> None)
      | Some parent_ty, ctor, idx -> (
          match normalize_accessed_type ctx parent_ty with
          | Ast.TyNamed (type_name, _) -> (
              match
                Codegen_types.lookup_union_variant ctx.reg type_name ctor
              with
              | Some variant -> List.nth_opt variant.variant_fields idx
              | None -> None)
          | _ -> None)
      | _ -> None)

let accessor_parent_type (ctx : Core_emit_context.t) (scrut_ty : Ast.type_expr)
    (acc : accessor) : Ast.type_expr option =
  match acc with
  | AccVariantField (parent, _, _)
  | AccTupleField (parent, _)
  | AccListElem (parent, _)
  | AccListSpread (parent, _) ->
      accessor_type ctx scrut_ty parent
  | AccRoot -> None

let accessor_parent_is_nullable_option (ctx : Core_emit_context.t)
    (scrut_ty : Ast.type_expr) (acc : accessor) : bool =
  match accessor_parent_type ctx scrut_ty acc with
  | Some parent_ty -> is_nullable_managed_option ctx parent_ty
  | None -> false

let accessor_parent_is_stack_option (ctx : Core_emit_context.t)
    (scrut_ty : Ast.type_expr) (acc : accessor) : bool =
  match accessor_parent_type ctx scrut_ty acc with
  | Some parent_ty ->
      Core_layout_type.is_stack_option_type ~reg:ctx.reg parent_ty
  | None -> false

let accessor_parent_is_stack_result (ctx : Core_emit_context.t)
    (scrut_ty : Ast.type_expr) (acc : accessor) : bool =
  match accessor_parent_type ctx scrut_ty acc with
  | Some parent_ty ->
      Core_layout_type.is_stack_result_type ~reg:ctx.reg parent_ty
  | None -> false

let stack_option_c_type_for_accessor (ctx : Core_emit_context.t)
    (scrut_ty : Ast.type_expr) (acc : accessor) : string option =
  match accessor_type ctx scrut_ty acc with
  | Some ty -> Core_layout_type.stack_option_c_type ~reg:ctx.reg ty
  | None -> None

let stack_result_c_type_for_accessor (ctx : Core_emit_context.t)
    (scrut_ty : Ast.type_expr) (acc : accessor) : string option =
  match accessor_type ctx scrut_ty acc with
  | Some ty -> Core_layout_type.stack_result_c_type ~reg:ctx.reg ty
  | None -> None

let stack_option_payload_type_for_accessor (ctx : Core_emit_context.t)
    (scrut_ty : Ast.type_expr) (accessor : accessor) fallback : Ast.type_expr =
  match accessor_parent_type ctx scrut_ty accessor with
  | Some parent_ty -> (
      match normalize_accessed_type ctx parent_ty with
      | Ast.TyNamed ("Option", [ payload ]) -> payload
      | _ -> fallback)
  | None -> fallback

let boxed_struct_payload_value c_ty source =
  Printf.sprintf "(*(%s*)((char*)%s + sizeof(blorp_Object)))" c_ty source

let accessor_reads_stack_option_payload (ctx : Core_emit_context.t)
    (scrut_ty : Ast.type_expr) (acc : accessor) : bool =
  match acc with
  | AccVariantField (_, "Some", 0) ->
      accessor_parent_is_stack_option ctx scrut_ty acc
  | _ -> false

let accessor_reads_stack_result_payload (ctx : Core_emit_context.t)
    (scrut_ty : Ast.type_expr) (acc : accessor) : bool =
  match acc with
  | AccVariantField (_, ("Ok" | "Err"), 0) ->
      accessor_parent_is_stack_result ctx scrut_ty acc
  | _ -> false

let accessor_reads_nullable_option_payload (ctx : Core_emit_context.t)
    (scrut_ty : Ast.type_expr) (acc : accessor) : bool =
  match acc with
  | AccVariantField (_, "Some", 0) ->
      accessor_parent_is_nullable_option ctx scrut_ty acc
  | _ -> false

let accessor_reads_typed_union_payload (ctx : Core_emit_context.t)
    (scrut_ty : Ast.type_expr) (acc : accessor) : bool =
  match acc with
  | AccVariantField (parent, _, _) -> (
      match accessor_type ctx scrut_ty parent with
      | Some parent_ty -> (
          match normalize_accessed_type ctx parent_ty with
          | Ast.TyNamed (type_name, _) ->
              Codegen_types.union_uses_typed_payload_storage ctx.reg type_name
          | _ -> false)
      | None -> false)
  | _ -> false

let typed_payload_decl_str (ctx : Core_emit_context.t) var_name source ty =
  let ty_c = type_to_c ctx ty in
  if
    is_value_record_type ctx ty
    || Core_layout_type.stack_option_c_type ~reg:ctx.reg ty <> None
    || Core_layout_type.stack_result_c_type ~reg:ctx.reg ty <> None
  then Printf.sprintf "%s %s = %s;" ty_c var_name source
  else Printf.sprintf "%s %s = (%s)%s;" ty_c var_name ty_c source

(** Generate an unbox declaration for a pattern accessor. Most accessors read
    erased [void*] storage and use [unbox_decl_str]. Primitive stack
    [Option[T]] payload access is already a direct scalar field, so treating it
    as boxed storage would call the wrong unbox helper for [Float]/[Float32]/etc. *)
let unbox_decl_for_accessor_str (ctx : Core_emit_context.t) (var_name : string)
    ~(scrut_ty : Ast.type_expr) ~(accessor : accessor) ~(source : string)
    (ty : Ast.type_expr) : string =
  if accessor_reads_stack_option_payload ctx scrut_ty accessor then
    let payload_ty =
      stack_option_payload_type_for_accessor ctx scrut_ty accessor ty
    in
    let ty_c = type_to_c ctx payload_ty in
    match normalize_type payload_ty with
    | ty when is_value_record_type ctx ty ->
        Printf.sprintf "%s %s = %s;" ty_c var_name source
    | _ -> Printf.sprintf "%s %s = (%s)%s;" ty_c var_name ty_c source
  else if accessor_reads_stack_result_payload ctx scrut_ty accessor then
    unbox_decl_str ctx var_name source ty
  else if accessor_reads_nullable_option_payload ctx scrut_ty accessor then
    let payload_ty =
      match accessor_parent_type ctx scrut_ty accessor with
      | Some parent_ty -> (
          match nullable_managed_option_payload_type ctx parent_ty with
          | Some payload -> payload
          | None -> ty)
      | None -> ty
    in
    let ty_c = type_to_c ctx payload_ty in
    Printf.sprintf "%s %s = (%s)%s;" ty_c var_name ty_c source
  else if accessor_reads_typed_union_payload ctx scrut_ty accessor then
    typed_payload_decl_str ctx var_name source ty
  else unbox_decl_str ctx var_name source ty

(** Emit as an indented line. *)
let emit_unbox_decl (ctx : Core_emit_context.t) (var_name : string)
    (source : string) (ty : Ast.type_expr) : unit =
  emit_line ctx (unbox_decl_str ctx var_name source ty)

(** Box a capture value — delegates to [emit_box_to_void]. *)
let emit_capture_box (ctx : Core_emit_context.t) (name : string)
    (ty : Ast.type_expr) : unit =
  emit_box_to_void ctx (escape_c_ident name) ty

(** Unbox a capture from the environment array — delegates to [emit_unbox_decl]. *)
let emit_capture_unbox (ctx : Core_emit_context.t) (name : string)
    (ty : Ast.type_expr) (idx : int) : unit =
  emit_unbox_decl ctx (escape_c_ident name) (Printf.sprintf "__e[%d]" idx) ty

let boxed_value_needs_release (ctx : Core_emit_context.t) (ty : Ast.type_expr)
    (loc : Ast.loc) : bool =
  Core_layout_type.boxed_storage_requires_release_or_error
    ~phase:Core_error.Emit ~reg:ctx.reg ty loc

(** Resolve an [accessor] path to a C expression string, using
    [scrut_name] as the root variable name. Casts intermediate
    void* values to the correct union type when accessing nested
    variant fields. *)
let render_accessor (ctx : Core_emit_context.t) (scrut_name : string)
    (acc : accessor) : string =
  let rec go = function
    | AccRoot -> scrut_name
    | AccVariantField (parent, ctor, idx) ->
        let parent_c = go parent in
        (* When the parent is a variant field, cast to the
           constructor's parent union type before accessing ->data *)
        let cast_parent =
          match parent with
          | AccVariantField _ | AccTupleField _ | AccListElem _ -> (
              match Hashtbl.find_opt ctx.ctor_parent_types ctor with
              | Some t -> Printf.sprintf "((%s*)%s)" t parent_c
              | None -> parent_c)
          | _ -> parent_c
        in
        Printf.sprintf "%s->data.%s.field%d" cast_parent ctor idx
    | AccTupleField (parent, idx) ->
        Core_emit_blorp_backend.render_tuple_field_element_at
          ~tuple_tmp:(go parent) ~index:idx
    | AccListElem (parent, idx) ->
        Printf.sprintf "blorp_list_get((blorp_List*)%s, %d)" (go parent) idx
    | AccListSpread (parent, idx) ->
        Printf.sprintf "blorp_list_drop((blorp_List*)%s, %d)" (go parent) idx
  in
  go acc

let render_accessor_typed (ctx : Core_emit_context.t) (scrut_name : string)
    (scrut_ty : Ast.type_expr) (acc : accessor) : string =
  let nullable_option_accessor_error ctor idx =
    Core_error.errorf Core_error.Emit Ast.dummy_loc
      ~hint:"nullable managed Option exposes only a nullable Some payload"
      "invalid nullable Option payload accessor %s.field%d" ctor idx
  in
  let rec go = function
    | AccRoot -> scrut_name
    | AccVariantField (AccRoot, "Some", 0)
      when Core_layout_type.is_stack_option_type ~reg:ctx.reg scrut_ty ->
        Printf.sprintf "%s.value" scrut_name
    | AccVariantField (AccRoot, ctor, idx)
      when Core_layout_type.is_stack_option_type ~reg:ctx.reg scrut_ty ->
        Core_error.errorf Core_error.Emit Ast.dummy_loc
          ~hint:
            "only Some(payload) has a payload field in primitive stack Option"
          "invalid primitive stack Option payload accessor %s.field%d" ctor idx
    | AccVariantField (parent, "Some", 0)
      when accessor_parent_is_stack_option ctx scrut_ty
             (AccVariantField (parent, "Some", 0)) ->
        let parent_c = go parent in
        begin match
          (parent, stack_option_c_type_for_accessor ctx scrut_ty parent)
        with
        | AccRoot, Some _ -> Printf.sprintf "%s.value" parent_c
        | _, Some c_ty ->
            Printf.sprintf "%s.value" (boxed_struct_payload_value c_ty parent_c)
        | _, None ->
            Core_error.errorf Core_error.Emit Ast.dummy_loc
              ~hint:"stack Option payload access must preserve the Option type"
              "invalid primitive stack Option payload accessor"
        end
    | AccVariantField (parent, ctor, idx)
      when accessor_parent_is_stack_option ctx scrut_ty
             (AccVariantField (parent, ctor, idx)) ->
        Core_error.errorf Core_error.Emit Ast.dummy_loc
          ~hint:
            "only Some(payload) has a payload field in primitive stack Option"
          "invalid primitive stack Option payload accessor %s.field%d" ctor idx
    | AccVariantField (AccRoot, (("Ok" | "Err") as ctor), 0)
      when Core_layout_type.is_stack_result_type ~reg:ctx.reg scrut_ty ->
        Printf.sprintf "%s.data.%s.field0" scrut_name ctor
    | AccVariantField (AccRoot, ctor, idx)
      when Core_layout_type.is_stack_result_type ~reg:ctx.reg scrut_ty ->
        Core_error.errorf Core_error.Emit Ast.dummy_loc
          ~hint:"stack Result exposes only Ok(payload) and Err(payload)"
          "invalid stack Result payload accessor %s.field%d" ctor idx
    | AccVariantField (parent, (("Ok" | "Err") as ctor), 0)
      when accessor_parent_is_stack_result ctx scrut_ty
             (AccVariantField (parent, ctor, 0)) ->
        let parent_c = go parent in
        begin match
          (parent, stack_result_c_type_for_accessor ctx scrut_ty parent)
        with
        | AccRoot, Some _ -> Printf.sprintf "%s.data.%s.field0" parent_c ctor
        | _, Some c_ty ->
            Printf.sprintf "%s.data.%s.field0"
              (boxed_struct_payload_value c_ty parent_c)
              ctor
        | _, None ->
            Core_error.errorf Core_error.Emit Ast.dummy_loc
              ~hint:"stack Result payload access must preserve the Result type"
              "invalid stack Result payload accessor"
        end
    | AccVariantField (parent, ctor, idx)
      when accessor_parent_is_stack_result ctx scrut_ty
             (AccVariantField (parent, ctor, idx)) ->
        Core_error.errorf Core_error.Emit Ast.dummy_loc
          ~hint:"stack Result exposes only Ok(payload) and Err(payload)"
          "invalid stack Result payload accessor %s.field%d" ctor idx
    | AccVariantField (parent, "Some", 0)
      when accessor_parent_is_nullable_option ctx scrut_ty
             (AccVariantField (parent, "Some", 0)) ->
        go parent
    | AccVariantField (parent, ctor, idx)
      when accessor_parent_is_nullable_option ctx scrut_ty
             (AccVariantField (parent, ctor, idx)) ->
        nullable_option_accessor_error ctor idx
    | AccVariantField (parent, ctor, idx) ->
        let parent_c = go parent in
        let cast_parent =
          match parent with
          | AccVariantField _ | AccTupleField _ | AccListElem _ -> (
              match Hashtbl.find_opt ctx.ctor_parent_types ctor with
              | Some t -> Printf.sprintf "((%s*)%s)" t parent_c
              | None -> parent_c)
          | _ -> parent_c
        in
        Printf.sprintf "%s->data.%s.field%d" cast_parent ctor idx
    | AccTupleField (parent, idx) -> (
        match accessor_type ctx scrut_ty parent with
        | Some parent_ty when is_nullable_managed_option ctx parent_ty ->
            Core_error.errorf Core_error.Emit Ast.dummy_loc
              ~hint:
                "match or bind Some(payload) before accessing fields of the \
                 payload"
              "invalid field accessor on nullable managed Option"
        | _ ->
            Core_emit_blorp_backend.render_tuple_field_element_at
              ~tuple_tmp:(go parent) ~index:idx)
    | AccListElem (parent, idx) -> (
        match accessor_type ctx scrut_ty parent with
        | Some parent_ty when is_nullable_managed_option ctx parent_ty ->
            Core_error.errorf Core_error.Emit Ast.dummy_loc
              ~hint:"match or bind Some(payload) before indexing the payload"
              "invalid list accessor on nullable managed Option"
        | _ ->
            Printf.sprintf "blorp_list_get((blorp_List*)%s, %d)" (go parent) idx
        )
    | AccListSpread (parent, idx) -> (
        match accessor_type ctx scrut_ty parent with
        | Some parent_ty when is_nullable_managed_option ctx parent_ty ->
            Core_error.errorf Core_error.Emit Ast.dummy_loc
              ~hint:"match or bind Some(payload) before spreading the payload"
              "invalid spread accessor on nullable managed Option"
        | _ ->
            Printf.sprintf "blorp_list_drop((blorp_List*)%s, %d)" (go parent)
              idx)
  in
  match (Core_layout_type.is_stack_option_type ~reg:ctx.reg scrut_ty, acc) with
  | true, AccRoot -> scrut_name
  | true, (AccTupleField _ | AccListElem _ | AccListSpread _) ->
      Core_error.errorf Core_error.Emit Ast.dummy_loc
        ~hint:"primitive stack Option exposes only a tag and Some payload"
        "invalid nested accessor on primitive stack Option"
  | true, AccVariantField (AccVariantField _, _, _) ->
      Core_error.errorf Core_error.Emit Ast.dummy_loc
        ~hint:
          "nested primitive stack Option access must be lowered before emission"
        "invalid nested variant accessor on primitive stack Option"
  | _ when Core_layout_type.is_stack_result_type ~reg:ctx.reg scrut_ty -> (
      match acc with
      | AccRoot -> scrut_name
      | AccTupleField (AccRoot, _)
      | AccListElem (AccRoot, _)
      | AccListSpread (AccRoot, _) ->
          Core_error.errorf Core_error.Emit Ast.dummy_loc
            ~hint:"stack Result exposes only a tag and variant payload"
            "invalid nested accessor on stack Result"
      | AccVariantField _ | AccTupleField _ | AccListElem _ | AccListSpread _ ->
          go acc)
  | _ -> go acc

(** Collect types for all variables used in an expression.
    Returns a map from variable name → type, found from CVar usage. *)
let collect_var_types (e : core) : (string, Ast.type_expr) Hashtbl.t =
  let types = Hashtbl.create 8 in
  let _ =
    transform_bottom_up
      (fun node ->
        (match node.desc with
        | CVar v when not (Hashtbl.mem types v.vname) ->
            Hashtbl.replace types v.vname node.ty
        | _ -> ());
        node)
      e
  in
  types

(** Look up a variable's type in a [collect_var_types] map, or
    return [TyVar "?"] as a placeholder when not found. *)
let find_var_type (name : string) (types : (string, Ast.type_expr) Hashtbl.t) :
    Ast.type_expr =
  match Hashtbl.find_opt types name with Some ty -> ty | None -> Ast.TyVar "?"

(** True if the value at [acc] (starting from a root of type [scrut_ty])
    is an enum-tagged scalar [long]. Enums have no fields, so anything
    deeper than [AccRoot] is by construction a non-enum value. *)
let accessor_is_enum (ctx : Core_emit_context.t) (scrut_ty : Ast.type_expr)
    (acc : accessor) : bool =
  match acc with
  | AccRoot -> (
      match Core_layout_type.enum_inline_width ~reg:ctx.reg scrut_ty with
      | Core_layout_type.EnumInlineBits _ -> true
      | Core_layout_type.NotInlineEnum -> false)
  | AccVariantField _ | AccTupleField _ | AccListElem _ | AccListSpread _ ->
      false

(** Format a tag-equality test. Enums compare as plain scalars
    ([acc == Ctor]); unions compare against their tag field
    ([acc->tag == TAG_Ctor]). *)
let constructor_c_name_for_match (ctx : Core_emit_context.t)
    (scrut_ty : Ast.type_expr) (acc : accessor) (ctor : string) : string =
  let by_parent parent_ty =
    Hashtbl.find_opt ctx.constructor_c_names_by_type (parent_ty, ctor)
  in
  let parent_ty =
    match acc with
    | AccRoot -> (
        match normalize_accessed_type ctx scrut_ty with
        | Ast.TyNamed (n, _) -> Some n
        | _ -> None)
    | AccVariantField _ | AccTupleField _ | AccListElem _ ->
        Hashtbl.find_opt ctx.ctor_parent_types ctor
    | AccListSpread _ -> None
  in
  match parent_ty with
  | Some parent -> (
      match by_parent parent with
      | Some c -> c
      | None -> (
          match Hashtbl.find_opt ctx.constructor_c_names ctor with
          | Some c -> c
          | None -> ctor))
  | None -> (
      match Hashtbl.find_opt ctx.constructor_c_names ctor with
      | Some c -> c
      | None -> ctor)

let tag_test_str (ctx : Core_emit_context.t) (scrut_ty : Ast.type_expr)
    (acc : accessor) (acc_c : string) (ctor : string) : string =
  let ctor_c = constructor_c_name_for_match ctx scrut_ty acc ctor in
  let nullable_option_tag_test () =
    match ctor with
    | "Some" -> Printf.sprintf "%s != NULL" acc_c
    | "None" -> Printf.sprintf "%s == NULL" acc_c
    | _ ->
        Core_error.errorf Core_error.Emit Ast.dummy_loc
          ~hint:"nullable managed Option can only be matched with Some or None"
          "invalid nullable managed Option constructor `%s`" ctor
  in
  match stack_option_c_type_for_accessor ctx scrut_ty acc with
  | Some c_ty ->
      let tag_c =
        match acc with
        | AccRoot -> Printf.sprintf "%s.tag" acc_c
        | _ -> Printf.sprintf "%s.tag" (boxed_struct_payload_value c_ty acc_c)
      in
      Printf.sprintf "%s == TAG_Option_%s" tag_c
        (Codegen_names.sanitize_c_ident ctor)
  | None -> (
      match stack_result_c_type_for_accessor ctx scrut_ty acc with
      | Some c_ty ->
          let tag_c =
            match acc with
            | AccRoot -> Printf.sprintf "%s.tag" acc_c
            | _ ->
                Printf.sprintf "%s.tag" (boxed_struct_payload_value c_ty acc_c)
          in
          Printf.sprintf "%s == TAG_Result_%s" tag_c
            (Codegen_names.sanitize_c_ident ctor)
      | None -> (
          match accessor_type ctx scrut_ty acc with
          | Some acc_ty when is_nullable_managed_option ctx acc_ty ->
              nullable_option_tag_test ()
          | _ when accessor_is_enum ctx scrut_ty acc ->
              Printf.sprintf "%s == %s" acc_c ctor_c
          | _ ->
              (* Cast to the constructor's parent type when the accessor yields
           a void pointer from a union field or tuple element. *)
              let parent_ty =
                match acc with
                | AccRoot -> (
                    match normalize_accessed_type ctx scrut_ty with
                    | Ast.TyNamed (n, _) -> Some n
                    | _ -> None)
                | AccVariantField _ | AccTupleField _ | AccListElem _ ->
                    Hashtbl.find_opt ctx.ctor_parent_types ctor
                | AccListSpread _ -> None
              in
              let cast_c =
                match (acc, parent_ty) with
                | (AccVariantField _ | AccTupleField _ | AccListElem _), Some t
                  ->
                    Printf.sprintf "((%s*)%s)" t acc_c
                | _ -> acc_c
              in
              let tag_c =
                match parent_ty with
                | Some t ->
                    Printf.sprintf "TAG_%s_%s"
                      (Codegen_names.sanitize_c_ident t)
                      (Codegen_names.sanitize_c_ident ctor)
                | None -> Printf.sprintf "TAG_%s" ctor_c
              in
              Printf.sprintf "%s->tag == %s" cast_c tag_c))

(** Emit a comparison of [scrut_expr] against [lit]. Strings use
    [blorp_string_eq_cstr]; everything else uses [==] + [gen_literal]. *)
let emit_lit_cmp (ctx : Core_emit_context.t) (scrut_expr : string)
    (lit : Ast.literal) : unit =
  match lit with
  | LitString (s, _) ->
      emit ctx
        (Printf.sprintf "blorp_string_eq_cstr(%s, \"%s\")" scrut_expr
           (String.escaped s))
  | _ ->
      emit ctx (Printf.sprintf "%s == " scrut_expr);
      gen_literal ctx lit
