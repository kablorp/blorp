(** Core IR → C emission. The sole backend.

    Reads a [Core.core] tree (produced by the Core IR pipeline in
    [Core_pipeline]) and emits C to the emission context's output
    buffer. Since the 2026-04-14 cutover this is the only path from
    Core IR to C — the legacy [Codegen_expr]/[Codegen_stmt] modules
    are gone.

    {1 Scope}

    Every Core IR constructor is handled here: arithmetic, control
    flow, let-bindings, direct calls, closure calls, pattern
    matching (decision-tree [CMatch] via [emit_ctree_assign] /
    [emit_ctree_stmt]), allocation (tuples, lists, vectors, dicts,
    records, strings, closures), statement-level control flow
    ([CWhile] / [CFor] / [CAssign] / [CBreak]), concurrency
    ([CConcurrent] / [CConcurrentFor] / [CDetach]), and RC ops
    ([CDup] / [CDrop]).

    Sugar constructors ([CStringInterp] / [CRecordUpdate]), the pre-compile
    match form ([CMatchArms]),
    and unresolved calls ([CCall (CKUnknown, _, _)]) are eliminated by
    earlier Core passes.
    If they reach emission it is a pipeline-level invariant violation
    — [Core_invariants.check_no_sugar] and [check_no_cmatcharms] fire
    at Match/Perceus/Desugar and [check_no_ckunknown] fires after
    specialization as the authoritative guardrails; this module retains
    small emit-time backstops for the same cases that
    raise [Core_error.Emit] with a hint pointing at
    [--check-invariants]. Keep them as defense-in-depth; their
    duplication with [Core_invariants] is intentional.

    {1 Conventions}

    - Literals, operators, and GCC statement expressions
      ([({ decls; body; })]) match the output the legacy codegen
      used, which is still what the C compiler expects.
    - Pointer-classification ([is_pointer_type]) is sourced from
      [Codegen_types] with the emission context's registry so
      enum-typed unions are classified consistently across the
      pipeline.
    - Stateless helpers ([type_to_c], [normalize_type],
      [escape_c_ident]) come from [Codegen_types]; the shared
      [codegen_builtins.ml] / [codegen_names.ml] / [codegen_types.ml]
      triad is this module's only runtime dependency in the
      [compiler/lib/codegen/] directory.

    {1 Decomposition}

    At ~1800 LOC this file is the single largest module in the
    compiler. It should be split into
    [core_emit_intrinsic.ml] / [core_emit_pattern.ml] /
    [core_emit_concurrent.ml] / [core_emit_lambda.ml], leaving
    [core_emit.ml] as a slim top-level dispatcher. *)

open Core
open Core_emit_context
open Codegen_types

(* Non-recursive helpers (Phase 5.1 step 1) — is_pointer_type,
   type_to_c, emit_binop/logop, box_kind/classify_for_boxing,
   collect_free_vars(_filtered), emit_box_to_void, unbox_decl_str,
   emit_unbox_decl, emit_capture_box/unbox, type_requires_release,
   type_requires_retain,
   render_accessor, emit_lit_cmp, plus the StringSet/StringMap
   modules. All are pure helpers that don't call into the mutual-
   recursion block below. *)
open Core_emit_util

(* ============================================================================
   C symbol mangling (A4.2)

   Every user-defined function / global / impl method / constructor
   emits its C symbol via [Codegen_names.mangle_by_def_id]. The single
   exception is [main], which must stay bare so the C linker can find
   it as the program entry point. Foreign functions ([CFForeign]) and
   runtime builtins ([CKBuiltin]) bypass this helper entirely — their
   C names come from the user-specified [c_name] / the
   [Codegen_builtins] registry.
   ============================================================================ *)

(** C symbol for a function decl. Mangled via the function's [cf_def_id]
    unless the function is [main]. *)
let func_c_name (f : core_func) : string =
  if f.cf_name = "main" then "main"
  else Codegen_names.mangle_by_def_id f.cf_def_id f.cf_name

(** C symbol for a call site that resolved to a user function. The
    [CKUser (name, Some id)] path produces the same string as
    [func_c_name] applied to the callee — both read from the same
    [cf_def_id]. The [None] fallback preserves legacy name-based
    emission for call sites that haven't been wired through [env.user_funcs];
    if any such call meets a def-id-mangled decl at link time, the
    build errors with "undefined symbol" rather than silently
    mis-dispatching. *)
let user_call_c_name (name : string) (def_id : int option) : string =
  match def_id with
  | Some id -> Codegen_names.mangle_by_def_id id name
  | None -> name

let constructor_c_name (name : string) (def_id : int option) : string =
  match def_id with
  | Some id -> Codegen_names.mangle_by_def_id id name
  | None -> name

let variant_c_name (v : Ast.variant) : string =
  constructor_c_name v.variant_name v.variant_def_id

let variant_tag_c_name (type_name : string) (v : Ast.variant) : string =
  Printf.sprintf "TAG_%s_%s"
    (Codegen_names.sanitize_c_ident type_name)
    (Codegen_names.sanitize_c_ident v.variant_name)

let expr_drops_var (target : var) (e : core) : bool =
  fold_tree
    (fun found node ->
      found
      ||
      match node.desc with
      | CDrop (v, _, _) -> Var.equal v target
      | _ -> false)
    false e

let expr_assigns_var (target : var) (e : core) : bool =
  fold_tree
    (fun found node ->
      found
      ||
      match node.desc with
      | CAssign (v, _) -> Var.equal v target
      | _ -> false)
    false e

let cleanup_frame_c_name (v : var) : string =
  "__blorp_cleanup_" ^ escape_c_ident (Var.to_c_name v)

let cancellation_cleanup_pop_slot_stmt (v : var) : string =
  Printf.sprintf "blorp_task_cleanup_pop_slot(&%s)"
    (escape_c_ident (Var.to_c_name v))

let cleanup_release_fn_for_call_kind = function
  | CKUser (name, def_id) ->
      Some (escape_c_ident (user_call_c_name name def_id))
  | CKForeign { fc_c_name; _ } -> Some fc_c_name
  | CKBuiltin c_name -> Some c_name
  | CKIntrinsic _ | CKClosure | CKUnknown | CKSelectedDirect _ -> None

let resource_cleanup_var_and_release_fn (cleanup : core) : (var * string) option
    =
  match cleanup.desc with
  | CCall (kind, _, [ { desc = CVar resource_var; _ } ]) ->
      Option.map
        (fun release_fn -> (resource_var, release_fn))
        (cleanup_release_fn_for_call_kind kind)
  | _ -> None

let resource_cancellation_cleanup_push_stmt (scope : resource_scope) : string =
  match resource_cleanup_var_and_release_fn scope.rs_cleanup with
  | Some (resource_var, release_fn) when Var.equal resource_var scope.rs_var ->
      let resource_c = escape_c_ident (Var.to_c_name scope.rs_var) in
      let frame_c = cleanup_frame_c_name scope.rs_var in
      Printf.sprintf
        "blorp_CancelCleanupFrame %s; blorp_task_cleanup_push(&%s, &%s, \
         (void*)%s, (blorp_CancelCleanupFn)%s);"
        frame_c frame_c resource_c resource_c release_fn
  | Some _ | None ->
      Core_error.errorf Core_error.Emit scope.rs_cleanup.loc
        ~hint:
          "Resource cleanup must be a direct finalizer call on the scoped \
           resource so cancellation can run the same semantic cleanup."
        "resource cleanup cannot be registered for cancellation"

let resource_cleanup_pop_slot_stmt (cleanup : core) : string option =
  match resource_cleanup_var_and_release_fn cleanup with
  | Some (resource_var, _) ->
      Some (cancellation_cleanup_pop_slot_stmt resource_var)
  | None -> None

let cancellation_cleanup_tracks_binding (ctx : Core_emit_context.t) (v : var)
    (ty : Ast.type_expr) (body : core) : bool =
  v.vname <> "_"
  && Option.is_some (cancellation_cleanup_release_fn ctx ty)
  && expr_drops_var v body
  && not (expr_assigns_var v body)

let emit_cancellation_cleanup_push (ctx : Core_emit_context.t) (v : var)
    (ty : Ast.type_expr) : unit =
  match cancellation_cleanup_release_fn ctx ty with
  | None -> ()
  | Some release_fn ->
      let var_c = escape_c_ident (Var.to_c_name v) in
      let frame_c = cleanup_frame_c_name v in
      emit_line ctx (Printf.sprintf "blorp_CancelCleanupFrame %s;" frame_c);
      emit_line ctx
        (Printf.sprintf "blorp_task_cleanup_push(&%s, &%s, (void*)%s, %s);"
           frame_c var_c var_c release_fn)

let emit_generated_stack_option_none_assignment ctx abi result_tmp =
  emit ctx
    (Printf.sprintf "%s = ((%s){ .tag = BLORP_TAG_NONE, .value = %s });"
       result_tmp abi.Core_layout_type.gsog_option_c_type
       abi.Core_layout_type.gsog_none_value)

let emit_generated_stack_option_some_assignment ctx abi result_tmp payload_expr
    =
  emit ctx
    (Printf.sprintf "%s = ((%s){ .tag = BLORP_TAG_SOME, .value = %s });"
       result_tmp abi.Core_layout_type.gsog_option_c_type payload_expr)

let emit_generated_stack_option_typedef ctx ~payload_c_type ~option_c_type =
  emit_line ctx
    (Printf.sprintf "typedef struct { int tag; %s value; } %s;" payload_c_type
       option_c_type)

let emit_builtin_generated_stack_option_typedefs ctx =
  emit_generated_stack_option_typedef ctx ~payload_c_type:"__int128"
    ~option_c_type:"blorp_StackOption_Int128";
  emit_generated_stack_option_typedef ctx ~payload_c_type:"unsigned __int128"
    ~option_c_type:"blorp_StackOption_UInt128";
  emit_generated_stack_option_typedef ctx ~payload_c_type:"long"
    ~option_c_type:"blorp_StackOption_Range";
  emit ctx "\n"

let emit_named_generated_stack_option_typedef ctx name payload_c_type =
  let option_c_type = Codegen_types.generated_stack_option_c_type_name name in
  let payload_ty = Ast.TyNamed (name, []) in
  let option_ty = Ast.TyNamed ("Option", [ Ast.TyNamed (name, []) ]) in
  match
    ( Codegen_types.is_primitive_stack_option_payload payload_ty,
      Core_layout_type.stack_option_c_type ~reg:ctx.reg option_ty )
  with
  | true, _ -> ()
  | false, Some c_ty when String.equal c_ty option_c_type ->
      emit_generated_stack_option_typedef ctx ~payload_c_type ~option_c_type
  | _ -> ()

let singleton_instance_c_name (v : Ast.variant) : string =
  "__instance_" ^ variant_c_name v

let singleton_init_c_name (v : Ast.variant) : string =
  "__init_" ^ variant_c_name v

let var_ref_c_name (ctx : Core_emit_context.t) (v : Core.var) : string =
  if Hashtbl.mem ctx.constructor_names v.vname then
    match v.vdef_id with
    | Some _ -> constructor_c_name v.vname v.vdef_id
    | None -> (
        match Hashtbl.find_opt ctx.constructor_c_names v.vname with
        | Some name -> name
        | None -> Var.to_c_name v)
  else Var.to_c_name v

let var_ref_c_name_for_type (ctx : Core_emit_context.t) (v : Core.var)
    (ty : Ast.type_expr) : string =
  if Hashtbl.mem ctx.constructor_names v.vname then
    match v.vdef_id with
    | Some _ -> constructor_c_name v.vname v.vdef_id
    | None -> (
        match normalize_type ty with
        | Ast.TyNamed (type_name, _) -> (
            match
              Hashtbl.find_opt ctx.constructor_c_names_by_type
                (type_name, v.vname)
            with
            | Some name -> name
            | None -> var_ref_c_name ctx v)
        | _ -> var_ref_c_name ctx v)
  else Var.to_c_name v

let cvar_is_typed_constructor (ctx : Core_emit_context.t) (v : Core.var)
    (ty : Ast.type_expr) ~(type_name : string) ~(ctor_name : string) : bool =
  match normalize_type ty with
  | Ast.TyNamed (name, _) when String.equal name type_name -> (
      let source_name_matches =
        Hashtbl.mem ctx.constructor_names ctor_name
        && String.equal v.vname ctor_name
      in
      match
        Hashtbl.find_opt ctx.constructor_c_names_by_type (type_name, ctor_name)
      with
      | Some ctor_c_name ->
          String.equal (var_ref_c_name_for_type ctx v ty) ctor_c_name
          || source_name_matches
      | None -> source_name_matches)
  | _ -> false

let expr_with_expected_type_for_constructors (ctx : Core_emit_context.t)
    (e : core) (expected_ty : Ast.type_expr) : core =
  match e.desc with
  | CVar v
    when cvar_is_typed_constructor ctx v expected_ty ~type_name:"Option"
           ~ctor_name:"None" ->
      { e with ty = expected_ty }
  | _ -> e

let is_global_func_var (ctx : Core_emit_context.t) (v : Core.var) : bool =
  match v.vdef_id with
  | Some id -> Hashtbl.mem ctx.global_def_ids id
  | None -> false

(** True when a literal can legally appear in a C static initializer.
    String literals lower to a lazy [blorp_string_literal(...)] expression,
    so global strings must be initialized at runtime in
    [__blorp_init_globals]. *)
let is_c_static_literal = function
  | Ast.LitInt _ | Ast.LitInt128 _ | Ast.LitFloat _ | Ast.LitBool _
  | Ast.LitChar _ ->
      true
  | Ast.LitString _ -> false

let float_modulo_emission (ty : Ast.type_expr) =
  match normalize_type ty with
  | Ast.TyNamed ("Float", []) -> Some ("double", "0.0", "fmod", false)
  | Ast.TyNamed ("Float32", []) -> Some ("float", "0.0f", "fmodf", false)
  | Ast.TyNamed ("Float16", []) ->
      Some ("_Float16", "(_Float16)0.0", "fmod", true)
  | _ -> None

let is_fixed_ty (ty : Ast.type_expr) =
  match normalize_type ty with Ast.TyNamed ("Fixed", []) -> true | _ -> false

let fixed_binop_runtime (op : Ast.binop) =
  match op with
  | Ast.Add -> Some (`Call "blorp_fixed_add")
  | Ast.Sub -> Some (`Call "blorp_fixed_sub")
  | Ast.Mul -> Some (`Call "blorp_fixed_mul")
  | Ast.Div -> Some (`Call "blorp_fixed_div")
  | Ast.Eq -> Some (`Call "blorp_fixed_eq")
  | Ast.Ne -> Some (`NegatedCall "blorp_fixed_eq")
  | Ast.Lt -> Some (`Call "blorp_fixed_lt")
  | Ast.Le -> Some (`Call "blorp_fixed_le")
  | Ast.Gt -> Some (`Call "blorp_fixed_gt")
  | Ast.Ge -> Some (`Call "blorp_fixed_ge")
  | Ast.Mod -> None

let trait_method_c_name_for_type (ctx : Core_emit_context.t) ~(loc : Ast.loc)
    (trait_name : string) (method_name : string) (ty : Ast.type_expr) : string =
  match Codegen_types.type_key_for_impl ty with
  | None ->
      Core_error.errorf Core_error.Emit loc
        "cannot form trait method name for `%s.%s` on type `%s`" trait_name
        method_name (Types.type_to_string ty)
  | Some type_name -> (
      let source_name =
        Printf.sprintf "%s_%s_%s" trait_name method_name type_name
      in
      match Hashtbl.find_opt ctx.trait_impl_def_ids source_name with
      | Some id -> Codegen_names.mangle_by_def_id id source_name
      | None -> source_name)

let is_erased_record_field (ctx : Core_emit_context.t) (ty : Ast.type_expr) :
    bool =
  Core_layout_type.record_field_uses_erased_storage ~reg:ctx.reg ty

let loc_for_record_decl (r : Ast.record_decl) : Ast.loc =
  match r.record_fields with fd :: _ -> fd.field_loc | [] -> Ast.dummy_loc

let loc_for_type_decl (t : Ast.type_decl) : Ast.loc =
  match t.type_variants with v :: _ -> v.variant_loc | [] -> Ast.dummy_loc

let managed_type_kind_name = function
  | ManagedHeapRecord -> "heap record"
  | ManagedUnion -> "union"
  | ManagedRuntimeBuiltin -> "runtime builtin"

let source_emitted_destructor_name ~loc ~type_name = function
  | ArcReleaseOnly -> None
  | GeneratedDestructor name -> Some name
  | RuntimeDestructor name ->
      Core_error.errorf Core_error.Emit loc
        ~hint:
          "RuntimeDestructor is reserved for runtime-owned managed builtins. \
           Source-emitted records and unions must use ArcReleaseOnly or \
           GeneratedDestructor."
        "runtime destructor `%s` registered for source-emitted type `%s`" name
        type_name

let heap_record_destructor_policy (ctx : Core_emit_context.t)
    (r : Ast.record_decl) : managed_destructor =
  match Codegen_types.managed_type_info ctx.reg r.record_name with
  | Some { managed_kind = ManagedHeapRecord; destructor } -> destructor
  | Some { managed_kind; _ } ->
      Core_error.errorf Core_error.Emit (loc_for_record_decl r)
        ~hint:
          "Type registration must use register_heap_record_type for record \
           declarations before C emission."
        "managed type `%s` was registered as %s, but emitted as heap record"
        r.record_name
        (managed_type_kind_name managed_kind)
  | None ->
      let destructor =
        Core_layout_type.record_destructor_policy ~phase:Core_error.Emit
          ~reg:ctx.reg r
      in
      Codegen_types.register_heap_record_type ctx.reg r.record_name ~destructor;
      destructor

let union_destructor_policy (ctx : Core_emit_context.t) (t : Ast.type_decl) :
    managed_destructor =
  match Codegen_types.managed_type_info ctx.reg t.type_name with
  | Some { managed_kind = ManagedUnion; destructor } -> destructor
  | Some { managed_kind; _ } ->
      Core_error.errorf Core_error.Emit (loc_for_type_decl t)
        ~hint:
          "Type registration must use register_union_type for union \
           declarations before C emission."
        "managed type `%s` was registered as %s, but emitted as union"
        t.type_name
        (managed_type_kind_name managed_kind)
  | None ->
      let destructor =
        Core_layout_type.union_destructor_policy ~phase:Core_error.Emit
          ~reg:ctx.reg t
      in
      Codegen_types.register_union_type ctx.reg t.type_name ~destructor;
      destructor

let record_field_decl (ctx : Core_emit_context.t) type_name field_name =
  match Hashtbl.find_opt ctx.record_decls type_name with
  | None -> None
  | Some r ->
      List.find_opt
        (fun (fd : Ast.field_decl) -> fd.field_name = field_name)
        r.record_fields

let record_field_storage_is_erased ctx type_name field_name =
  match record_field_decl ctx type_name field_name with
  | Some fd -> is_erased_record_field ctx fd.field_type
  | None -> false

let emit_void_as_type ctx target_ty emit_source =
  match normalize_type target_ty with
  | Ast.TyNamed ("Float", _) ->
      emit ctx "blorp_unbox_float(";
      emit_source ();
      emit ctx ")"
  | Ast.TyNamed ("Float32", _) ->
      emit ctx "blorp_unbox_float32(";
      emit_source ();
      emit ctx ")"
  | Ast.TyNamed ("Float16", _) ->
      emit ctx "blorp_unbox_float16(";
      emit_source ();
      emit ctx ")"
  | Ast.TyNamed ("Int128", _) ->
      emit ctx "blorp_unbox_int128(";
      emit_source ();
      emit ctx ")"
  | Ast.TyNamed ("UInt128", _) ->
      emit ctx "blorp_unbox_uint128(";
      emit_source ();
      emit ctx ")"
  | Ast.TyNamed ("Int", _) | Ast.TyNamed ("Bool", _) | Ast.TyNamed ("Char", _)
    ->
      emit ctx (Printf.sprintf "((%s)(long)" (type_to_c ctx target_ty));
      emit_source ();
      emit ctx ")"
  | ty when Types.is_any_integer_type ty ->
      emit ctx (Printf.sprintf "((%s)(long)" (type_to_c ctx target_ty));
      emit_source ();
      emit ctx ")"
  | ty when is_value_record_type ctx ty ->
      let c_ty = value_record_storage_c_type ctx target_ty in
      emit ctx (Printf.sprintf "(*(%s*)((char*)" c_ty);
      emit_source ();
      emit ctx " + sizeof(blorp_Object)))"
  | _ ->
      emit ctx (Printf.sprintf "((%s)" (type_to_c ctx target_ty));
      emit_source ();
      emit ctx ")"

let tuple_field_needs_release ctx field =
  boxed_value_needs_release ctx field.ty field.loc

let tuple_field_needs_retain ctx field =
  tuple_field_needs_release ctx field
  &&
  match field.desc with
  | CField _ | CUnbox _ | CUnboxTyped _ | CLit (Ast.LitString _) -> true
  | _ -> false

let dict_value_needs_release ctx dict_ty loc =
  match normalize_type dict_ty with
  | Ast.TyNamed ("Dict", [ _key_ty; value_ty ]) ->
      boxed_value_needs_release ctx value_ty loc
  | _ -> false

let emit_dict_value_release_init ctx dict_c =
  emit ctx
    (Printf.sprintf " blorp_dict_set_value_release(%s, blorp_elem_release_fn);"
       dict_c)

let boxed_value_release_arg ctx ty loc =
  if boxed_value_needs_release ctx ty loc then "blorp_elem_release_fn"
  else "NULL"

let tensor_type_of_type ctx ty = Core_tensor_type.of_type ~reg:ctx.reg ty
let tensor_type_of_expr ctx expr = Core_tensor_type.of_core ~reg:ctx.reg expr
let is_tensor_type ctx ty = Core_tensor_type.is_type ~reg:ctx.reg ty

let tensor_element_needs_release ctx ty loc =
  match tensor_type_of_type ctx ty with
  | Some tensor_ty -> boxed_value_needs_release ctx tensor_ty.elem_ty loc
  | None -> false

let tensor_inline_struct_c_type ctx ty =
  match tensor_type_of_type ctx ty with
  | Some tensor_ty -> (
      match
        Core_layout_type.tensor_element_storage ~reg:ctx.reg tensor_ty.elem_ty
      with
      | Core_layout_type.TensorElementInlineStruct c_ty -> Some c_ty
      | Core_layout_type.TensorElementRawScalar _
      | Core_layout_type.TensorElementPackedBits _
      | Core_layout_type.TensorElementBoxed ->
          None)
  | None -> None

let tensor_fill_factory_uses_direct_layout ctx ty loc =
  let layout =
    Core_layout_type.tensor_storage_layout_of_type ~reg:ctx.reg ty loc
  in
  match layout.tsl_slots with
  | TensorRawScalarStorage _ | TensorPackedStorage _ -> true
  | _ -> false

let tensor_arg_element_needs_release ctx args loc =
  match args with
  | arr :: _ -> tensor_element_needs_release ctx arr.ty loc
  | [] -> false

let channel_element_needs_release ctx ty loc =
  match normalize_type ty with
  | Ast.TyNamed ("Channel", [ elem ]) -> boxed_value_needs_release ctx elem loc
  | _ -> false

let boxed_expr_transfers_ownership ctx (el : core) =
  match el.desc with
  | CBox (_, source_ty) -> boxed_value_needs_release ctx source_ty el.loc
  | CBoxTyped b -> boxed_value_needs_release ctx b.box_source_ty el.loc
  | CVar _ | CField _ | CUnbox _ | CUnboxTyped _ | CLit (Ast.LitString _) -> (
      match classify_for_boxing ctx el.ty el.loc with
      | BoxStruct _ -> true
      | _ -> false)
  | _ -> boxed_value_needs_release ctx el.ty el.loc

let boxed_expr_needs_constructor_release ctx (el : core) =
  match el.desc with
  | CBox (_, source_ty) -> boxed_value_needs_release ctx source_ty el.loc
  | CBoxTyped b -> boxed_value_needs_release ctx b.box_source_ty el.loc
  | _ -> boxed_value_needs_release ctx el.ty el.loc

let emit_dict_constructor_expr ctx dict_ty loc emit_ctor =
  if dict_value_needs_release ctx dict_ty loc then begin
    let tmp = Printf.sprintf "__dict_%d" (fresh_temp ctx) in
    emit ctx (Printf.sprintf "({ blorp_Dict* %s = " tmp);
    emit_ctor ();
    emit ctx ";";
    emit_dict_value_release_init ctx tmp;
    emit ctx (Printf.sprintf " %s; })" tmp)
  end
  else emit_ctor ()

let capture_slot_needs_release (ctx : Core_emit_context.t) (ty : Ast.type_expr)
    =
  match normalize_type ty with
  | ty when is_value_record_type ctx ty -> true
  | _ when is_pointer_type ctx ty -> type_requires_release ctx ty
  | _ -> false

let closure_env_release_mask (ctx : Core_emit_context.t)
    (captures : (string * Ast.type_expr) list) : int =
  captures
  |> List.mapi (fun i (_, ty) ->
      if capture_slot_needs_release ctx ty then 1 lsl i else 0)
  |> List.fold_left ( lor ) 0

let emit_closure_env_release_mask_expr (ctx : Core_emit_context.t)
    (tmp : string) (captures : (string * Ast.type_expr) list) : unit =
  let mask = closure_env_release_mask ctx captures in
  emit ctx (Printf.sprintf " %s->env_release_mask = %dUL;" tmp mask)

let emit_closure_env_release_mask_stmt (ctx : Core_emit_context.t)
    (tmp : string) (captures : (string * Ast.type_expr) list) : unit =
  let mask = closure_env_release_mask ctx captures in
  emit_line ctx (Printf.sprintf "%s->env_release_mask = %dUL;" tmp mask)

let direct_returned_capture (ctx : Core_emit_context.t)
    (captures : (string * Ast.type_expr) list) (body : core) : string option =
  match body.desc with
  | CVar v
    when List.exists (fun (name, _) -> name = v.vname) captures
         && is_pointer_type ctx body.ty ->
      Some (escape_c_ident (Var.to_c_name v))
  | _ -> None

(** [CMatch] emission introduces a C temp for the scrutinee. Perceus cannot see
    that temp, so emission must close its lifetime when a non-place scrutinee
    expression produces an owned ARC value. Variables and fields stay under
    Perceus/source ownership because they may be borrowed pattern aliases. *)
let rec match_scrutinee_needs_release (ctx : Core_emit_context.t) (scrut : core)
    : bool =
  match scrut.desc with
  | CVar _ | CField _ -> false
  | CCast (inner, _) | CUnbox (inner, _) ->
      match_scrutinee_needs_release ctx inner
  | _ when not (type_requires_release ctx scrut.ty) -> false
  | CCall (kind, _, args) -> (
      match
        Core_ownership.contract_for_call_kind kind ~arg_count:(List.length args)
      with
      | Some { result = Core_ownership.ReturnOwned; _ } -> true
      | Some
          {
            result =
              ( Core_ownership.ReturnVoid | Core_ownership.ReturnPrimitive
              | Core_ownership.ReturnBorrowed
              | Core_ownership.ReturnAliasOfArg _ );
            _;
          } ->
          false
      | None -> (
          match kind with
          | CKUnknown | CKSelectedDirect _ -> false
          | CKUser _ | CKForeign _ | CKBuiltin _ | CKClosure -> true
          | CKIntrinsic _ -> false))
  | _ -> true

(* ============================================================================
   Expression emission

   Everything below is one big [let rec ... and ... and ...] mutual-
   recursion block. The sections are grouped for readability but they
   all share one scope — splitting across files requires the "late-
   binding via record" refactor. Until then, the grouping below serves as the
   structural index:

     §1. [emit_intrinsic]      — backend-defined primitives (lines ~74-530)
     §2. [emit_expr]           — main expression dispatcher (~531)
     §3. [emit_stmt]           — statement-level dispatch (~1158)
     §4. [emit_boxed]          — boxing wrapper for void* returns (~1292)
     §5. Preamble + type decls — records / enums / unions (~1355)
     §6. Top-level decls       — globals / impls / funcs / program (~1577)
     §7. For-loop variants     — list / tensor / string / dict (~1887)
     §8. Pattern-match emit    — [emit_ctree_assign] / [emit_ctree_stmt] (~2170)
     §9. Lambda / closure emit — hoisted body + static closures (~2347)
     §10. Concurrency emit     — [CConcurrent] / [CDetach] / [CConcurrentFor] (~2490)
     §11. Collection / init    — hoisted lambdas + global init (~2643)
   ============================================================================ *)

(* --- §1. emit_intrinsic ----------------------------------------------------- *)

let emit_list_alloc_call (ctx : Core_emit_context.t)
    (layout : list_storage_layout) (emit_cap : unit -> unit) : unit =
  match layout.lsl_slots with
  | ListPointerStorage ->
      emit ctx "blorp_list_new(";
      emit_cap ();
      emit ctx ")"
  | ListInlineStorage width ->
      emit ctx "blorp_list_new_inline(";
      emit_cap ();
      emit ctx (Printf.sprintf ", %d)" (inline_storage_width_bytes width))
  | ListInlineStructStorage c_ty ->
      emit ctx "blorp_list_new_inline(";
      emit_cap ();
      emit ctx (Printf.sprintf ", sizeof(%s))" c_ty)

let list_storage_runtime_args (layout : list_storage_layout) : string * string =
  match layout.lsl_slots with
  | ListPointerStorage -> ("BLORP_LIST_STORAGE_POINTER", "sizeof(void*)")
  | ListInlineStorage width ->
      ( "BLORP_LIST_STORAGE_INLINE",
        string_of_int (inline_storage_width_bytes width) )
  | ListInlineStructStorage c_ty ->
      ("BLORP_LIST_STORAGE_INLINE", "sizeof(" ^ c_ty ^ ")")

let list_callback_result_encoding_arg (layout : list_storage_layout) : string =
  match layout.lsl_value_layout with
  | ListElementStackStruct _ -> "BLORP_LIST_CALLBACK_BOXED_STRUCT"
  | ListElementPointer | ListElementInlineBits _ | ListElementBoxedValue
  | ListElementUnknownValue _ ->
      "BLORP_LIST_CALLBACK_BITS"

let is_list_filter_map_parallel_builtin_name (c_name : string) : bool =
  String.starts_with ~prefix:"blorp_filter_map_parallel" c_name

let is_list_parallel_layout_builtin_name (c_name : string) : bool =
  match c_name with
  | "blorp_map_parallel" | "blorp_zip_parallel" | "blorp_map_parallel_with"
  | "blorp_zip_parallel_with" ->
      true
  | _ -> is_list_filter_map_parallel_builtin_name c_name

let vector_parallel_storage_runtime_args (layout : tensor_storage_layout) :
    string * string =
  match layout.tsl_slots with
  | TensorRawScalarStorage TensorFloat64Elements ->
      ("BLORP_VECTOR_STORAGE_F64", "sizeof(double)")
  | TensorRawScalarStorage TensorFloat32Elements ->
      ("BLORP_VECTOR_STORAGE_F32", "sizeof(float)")
  | TensorRawScalarStorage TensorInt64Elements ->
      ("BLORP_VECTOR_STORAGE_I64", "sizeof(long)")
  | TensorInlineStructStorage c_ty ->
      ("BLORP_VECTOR_STORAGE_INLINE", "sizeof(" ^ c_ty ^ ")")
  | TensorPackedStorage _ | TensorWordStorage | TensorBoxedStorage ->
      ("BLORP_VECTOR_STORAGE_POINTER", "sizeof(void*)")

let vector_callback_result_encoding_arg (layout : tensor_storage_layout) :
    string =
  match layout.tsl_slots with
  | TensorInlineStructStorage _ -> "BLORP_VECTOR_CALLBACK_BOXED_STRUCT"
  | TensorRawScalarStorage TensorFloat64Elements ->
      "BLORP_VECTOR_CALLBACK_BOXED_FLOAT"
  | TensorRawScalarStorage TensorFloat32Elements ->
      "BLORP_VECTOR_CALLBACK_BOXED_FLOAT32"
  | TensorRawScalarStorage TensorInt64Elements
  | TensorPackedStorage _ | TensorWordStorage | TensorBoxedStorage ->
      "BLORP_VECTOR_CALLBACK_BITS"

let is_vector_parallel_layout_builtin_name (c_name : string) : bool =
  match c_name with
  | "blorp_matrix_map" | "blorp_matrix_map_indexed" | "blorp_matrix_zip_map"
  | "blorp_vmap_parallel" | "blorp_vmap_indexed_parallel"
  | "blorp_vzip_parallel" | "blorp_mmap_parallel"
  | "blorp_mmap_indexed_parallel" | "blorp_mmap_flat_indexed_parallel"
  | "blorp_mzip_parallel" | "blorp_mzip_indexed_parallel" ->
      true
  | _ -> false

let tensor_for_in_proven_raw_storage (ctx : Core_emit_context.t) (loc : Ast.loc)
    (elem_ty : Ast.type_expr) (proof : tensor_storage_provenance) :
    Core_layout_type.tensor_raw_scalar_abi option =
  match proof with
  | TensorStorageUnknown _ -> None
  | TensorStorageProven { tsp_layout; _ } -> (
      match Core_layout_type.tensor_raw_scalar_abi_of_layout tsp_layout with
      | None -> None
      | Some raw -> (
          let expected =
            Core_layout_type.tensor_storage_layout_of_elem ~reg:ctx.reg elem_ty
              loc
          in
          match (tsp_layout.tsl_slots, expected.tsl_slots) with
          | TensorRawScalarStorage actual, TensorRawScalarStorage expected
            when actual = expected ->
              Some raw
          | _ ->
              Core_error.errorf Core_error.Emit loc
                ~hint:
                  "Final Core storage provenance must agree with the loop \
                   element type before C emission can use a direct raw load."
                "tensor loop storage proof `%s` does not match element type \
                 `%s`"
                (tensor_storage_slot_layout_str tsp_layout.tsl_slots)
                (Types.type_to_string elem_ty)))

(** Emit an IR intrinsic — a primitive operation defined at the IR level.
    Each intrinsic emits structured C code (not a function-name call).
    These are the backend-defined primitives that [builtin] functions
    compile down to.

    Phase 5.1 step 3 moved the ~460-LOC match body to
    [core_emit_intrinsic.ml] — this wrapper re-binds the mutual-
    recursion partners as labeled callbacks so the extracted file
    doesn't need to live inside the rec chain. [emit_stmt] is
    threaded defensively though no intrinsic arm consumes it today —
    see [Core_emit_intrinsic]'s header for why. *)
let rec emit_intrinsic (ctx : Core_emit_context.t) (e : core) (name : string)
    (args : core list) : unit =
  Core_emit_intrinsic.emit ~emit_expr ~emit_stmt ~emit_boxed ctx e name args

and emit_tensor_raw_view_decl (ctx : Core_emit_context.t)
    (b : tensor_raw_view_binding) : unit =
  let c_ty =
    (Core_layout_type.tensor_raw_scalar_abi b.trv_kind).tras_pointer_c_type
  in
  emit ctx c_ty;
  emit ctx " ";
  emit ctx (escape_c_ident (Var.to_c_name b.trv_var));
  emit ctx " = (";
  emit ctx c_ty;
  emit ctx ")((blorp_Vector*)";
  emit_expr ctx b.trv_source;
  emit ctx ")->data"

and emit_list_get (ctx : Core_emit_context.t) (get : list_get) : unit =
  match get.lg_layout.lsl_slots with
  | ListPointerStorage ->
      emit ctx "blorp_list_get((blorp_List*)";
      emit_expr ctx get.lg_list;
      emit ctx ", ";
      emit_expr ctx get.lg_index;
      emit ctx ")"
  | ListInlineStorage width ->
      let list_tmp = Printf.sprintf "__lg_list_%d" (fresh_temp ctx) in
      let idx_tmp = Printf.sprintf "__lg_idx_%d" (fresh_temp ctx) in
      let bits_tmp = Printf.sprintf "__lg_bits_%d" (fresh_temp ctx) in
      let width_bytes = inline_storage_width_bytes width in
      emit ctx (Printf.sprintf "({\nblorp_List* %s = (blorp_List*)" list_tmp);
      emit_expr ctx get.lg_list;
      emit ctx (Printf.sprintf ";\nlong %s = " idx_tmp);
      emit_expr ctx get.lg_index;
      emit ctx ";\n";
      (match get.lg_bounds with
      | ListBoundsChecked ->
          emit ctx
            (Printf.sprintf
               "(__builtin_expect(!%s || %s < 0 || %s >= %s->len, 0) ? NULL : "
               list_tmp idx_tmp idx_tmp list_tmp)
      | ListBoundsProven -> ());
      (* [CListGet] carries the concrete monomorphized list storage layout.
         Re-checking [storage_mode]/[elem_size] here turns an impossible Core
         state into a hot runtime branch. Generic pointer storage still uses the
         runtime helper above; inline storage can load the slot directly. *)
      emit ctx
        (Printf.sprintf
           "({ uintptr_t %s = 0; memcpy(&%s, (char*)%s->data + %s * %d, %d); \
            (void*)%s; })"
           bits_tmp bits_tmp list_tmp idx_tmp width_bytes width_bytes bits_tmp);
      (match get.lg_bounds with
      | ListBoundsChecked -> emit ctx ")"
      | ListBoundsProven -> ());
      emit ctx ";\n})"
  | ListInlineStructStorage _ ->
      emit ctx "blorp_list_get((blorp_List*)";
      emit_expr ctx get.lg_list;
      emit ctx ", ";
      emit_expr ctx get.lg_index;
      emit ctx ")"

and emit_string_byte_read (ctx : Core_emit_context.t) (read : string_byte_read)
    : unit =
  emit ctx "(long)(unsigned char)((blorp_String*)";
  emit_expr ctx read.sbr_source;
  emit ctx ")->data[";
  emit_expr ctx read.sbr_index;
  emit ctx "]"

and emit_string_byte_write (ctx : Core_emit_context.t)
    (write : string_byte_write) : unit =
  emit ctx "(((blorp_String*)";
  emit_expr ctx write.sbw_target;
  emit ctx ")->data[";
  emit_expr ctx write.sbw_index;
  emit ctx "] = (char)";
  emit_expr ctx write.sbw_byte;
  emit ctx ")"

and emit_string_byte_copy (ctx : Core_emit_context.t) (copy : string_byte_copy)
    : unit =
  let id = fresh_temp ctx in
  let dst_tmp = Printf.sprintf "__string_copy_dst_%d" id in
  let dst_pos_tmp = Printf.sprintf "__string_copy_dst_pos_%d" id in
  let src_tmp = Printf.sprintf "__string_copy_src_%d" id in
  let src_pos_tmp = Printf.sprintf "__string_copy_src_pos_%d" id in
  let len_tmp = Printf.sprintf "__string_copy_len_%d" id in
  emit ctx (Printf.sprintf "({ blorp_String* %s = (blorp_String*)" dst_tmp);
  emit_expr ctx copy.sbc_dst;
  emit ctx (Printf.sprintf "; long %s = " dst_pos_tmp);
  emit_expr ctx copy.sbc_dst_pos;
  emit ctx (Printf.sprintf "; blorp_String* %s = (blorp_String*)" src_tmp);
  emit_expr ctx copy.sbc_src;
  emit ctx (Printf.sprintf "; long %s = " src_pos_tmp);
  emit_expr ctx copy.sbc_src_pos;
  emit ctx (Printf.sprintf "; long %s = " len_tmp);
  emit_expr ctx copy.sbc_len;
  emit ctx
    (Printf.sprintf
       "; if (%s > 0) { memcpy(%s->data + %s, %s->data + %s, (size_t)%s); } \
        (void)0; })"
       len_tmp dst_tmp dst_pos_tmp src_tmp src_pos_tmp len_tmp)

and emit_string_set_len (ctx : Core_emit_context.t) (set_len : string_set_len) :
    unit =
  emit ctx "({ blorp_String* __sl = (blorp_String*)";
  emit_expr ctx set_len.ssl_target;
  emit ctx "; long __sn = ";
  emit_expr ctx set_len.ssl_len;
  emit ctx "; __sl->len = __sn; __sl->data[__sn] = '\\0'; (void)0; })"

and emit_box_op (ctx : Core_emit_context.t) (b : box_op) : unit =
  match b.box_kind with
  | BoxVoid ->
      emit ctx "({ ";
      emit_stmt ctx b.box_value;
      emit ctx "(void*)0; })"
  | _ ->
      let tmp = Printf.sprintf "__box_%d" (fresh_temp ctx) in
      let c_ty = type_to_c ctx b.box_source_ty in
      emit ctx (Printf.sprintf "({ %s %s = " c_ty tmp);
      emit_expr ctx b.box_value;
      emit ctx "; ";
      (match b.box_kind with
      | BoxFloat -> emit ctx (Printf.sprintf "blorp_box_float(%s)" tmp)
      | BoxFloat32 -> emit ctx (Printf.sprintf "blorp_box_float32(%s)" tmp)
      | BoxFloat16 -> emit ctx (Printf.sprintf "blorp_box_float16(%s)" tmp)
      | BoxInt128 -> emit ctx (Printf.sprintf "blorp_box_int128(%s)" tmp)
      | BoxUInt128 -> emit ctx (Printf.sprintf "blorp_box_uint128(%s)" tmp)
      | BoxPointer -> emit ctx (Printf.sprintf "(void*)%s" tmp)
      | BoxPrim -> emit ctx (Printf.sprintf "(void*)(long)(%s)" tmp)
      | BoxStruct _
        when Core_layout_type.is_stack_result_type ~reg:ctx.reg b.box_source_ty
        ->
          emit ctx (Printf.sprintf "blorp_box_stack_result(%s)" tmp)
      | BoxStruct _ ->
          emit ctx (Printf.sprintf "blorp_box_struct(&%s, sizeof(%s))" tmp c_ty)
      | BoxVoid -> assert false);
      emit ctx "; })"

and emit_boxed_storage (ctx : Core_emit_context.t) (value : boxed_storage_value)
    : unit =
  emit_box_op ctx value.bsv_box

and emit_list_inline_struct_dynamic_load ctx ~list_tmp ~idx_tmp ~out_tmp
    ~struct_ty ~bounds =
  let raw_tmp = Printf.sprintf "__lg_raw_%d" (fresh_temp ctx) in
  (match bounds with
  | ListBoundsChecked ->
      emit ctx
        (Printf.sprintf
           "if (__builtin_expect(!%s || %s < 0 || %s >= %s->len, 0)) { \
            memset(&%s, 0, sizeof(%s)); } else "
           list_tmp idx_tmp idx_tmp list_tmp out_tmp struct_ty)
  | ListBoundsProven -> ());
  emit ctx
    (Printf.sprintf
       "if (%s->storage_mode == BLORP_LIST_STORAGE_INLINE && %s->elem_size == \
        (int16_t)sizeof(%s)) { memcpy(&%s, (char*)%s->data + %s * sizeof(%s), \
        sizeof(%s)); } else { void* %s = blorp_list_get(%s, %s); if (!%s) { \
        memset(&%s, 0, sizeof(%s)); } else { %s = blorp_unbox_struct(%s, %s); \
        } }"
       list_tmp list_tmp struct_ty out_tmp list_tmp idx_tmp struct_ty struct_ty
       raw_tmp list_tmp idx_tmp raw_tmp out_tmp struct_ty out_tmp raw_tmp
       struct_ty)

and emit_unbox_op (ctx : Core_emit_context.t) (u : unbox_op) : unit =
  let c_ty = type_to_c ctx u.unbox_target_ty in
  match (u.unbox_kind, u.unbox_value.desc) with
  | UnboxStruct struct_ty, CListGet get
    when get.lg_layout.lsl_slots = ListInlineStructStorage struct_ty ->
      let list_tmp = Printf.sprintf "__lg_list_%d" (fresh_temp ctx) in
      let idx_tmp = Printf.sprintf "__lg_idx_%d" (fresh_temp ctx) in
      let out_tmp = Printf.sprintf "__lg_out_%d" (fresh_temp ctx) in
      emit ctx (Printf.sprintf "({ blorp_List* %s = (blorp_List*)" list_tmp);
      emit_expr ctx get.lg_list;
      emit ctx (Printf.sprintf "; long %s = " idx_tmp);
      emit_expr ctx get.lg_index;
      emit ctx (Printf.sprintf "; %s %s; " struct_ty out_tmp);
      emit_list_inline_struct_dynamic_load ctx ~list_tmp ~idx_tmp ~out_tmp
        ~struct_ty ~bounds:get.lg_bounds;
      emit ctx (Printf.sprintf " %s; })" out_tmp)
  | UnboxStruct struct_ty, CCall (CKBuiltin "blorp_checked_get", _, [ arr; idx ])
    ->
      let arr_tmp = Printf.sprintf "__tg_arr_%d" (fresh_temp ctx) in
      let idx_tmp = Printf.sprintf "__tg_idx_%d" (fresh_temp ctx) in
      let out_tmp = Printf.sprintf "__tg_out_%d" (fresh_temp ctx) in
      emit ctx (Printf.sprintf "({ blorp_Vector* %s = (blorp_Vector*)" arr_tmp);
      emit_expr ctx arr;
      emit ctx (Printf.sprintf "; long %s = " idx_tmp);
      emit_expr ctx idx;
      emit ctx
        (Printf.sprintf
           "; %s %s = {0}; if (__builtin_expect(%s && %s >= 0 && %s < %s->len, \
            1)) { if (__builtin_expect(%s->storage_mode == \
            BLORP_VECTOR_STORAGE_INLINE && %s->elem_size == sizeof(%s), 1)) { \
            memcpy(&%s, (char*)%s->data + %s * sizeof(%s), sizeof(%s)); } else \
            { void* __raw = %s->data[%s]; %s = blorp_unbox_struct(__raw, %s); \
            } } %s; })"
           struct_ty out_tmp arr_tmp idx_tmp idx_tmp arr_tmp arr_tmp arr_tmp
           struct_ty out_tmp arr_tmp idx_tmp struct_ty struct_ty arr_tmp idx_tmp
           out_tmp struct_ty out_tmp)
  | ( UnboxStruct struct_ty,
      CCall (CKIntrinsic "tensor_get_unchecked", _, [ arr; idx ]) ) ->
      let arr_tmp = Printf.sprintf "__tgu_arr_%d" (fresh_temp ctx) in
      let idx_tmp = Printf.sprintf "__tgu_idx_%d" (fresh_temp ctx) in
      let out_tmp = Printf.sprintf "__tgu_out_%d" (fresh_temp ctx) in
      emit ctx (Printf.sprintf "({ blorp_Vector* %s = (blorp_Vector*)" arr_tmp);
      emit_expr ctx arr;
      emit ctx (Printf.sprintf "; long %s = " idx_tmp);
      emit_expr ctx idx;
      emit ctx
        (Printf.sprintf
           "; %s %s; if (__builtin_expect(%s->storage_mode == \
            BLORP_VECTOR_STORAGE_INLINE && %s->elem_size == sizeof(%s), 1)) { \
            memcpy(&%s, (char*)%s->data + %s * sizeof(%s), sizeof(%s)); } else \
            { void* __raw = %s->data[%s]; %s = blorp_unbox_struct(__raw, %s); \
            } %s; })"
           struct_ty out_tmp arr_tmp arr_tmp struct_ty out_tmp arr_tmp idx_tmp
           struct_ty struct_ty arr_tmp idx_tmp out_tmp struct_ty out_tmp)
  | ( UnboxStruct struct_ty,
      CCall (CKBuiltin "blorp_matrix_checked_get", _, [ arr; row; col ]) ) ->
      let arr_tmp = Printf.sprintf "__tg_arr_%d" (fresh_temp ctx) in
      let row_tmp = Printf.sprintf "__tg_row_%d" (fresh_temp ctx) in
      let col_tmp = Printf.sprintf "__tg_col_%d" (fresh_temp ctx) in
      let out_tmp = Printf.sprintf "__tg_out_%d" (fresh_temp ctx) in
      emit ctx (Printf.sprintf "({ blorp_Vector* %s = (blorp_Vector*)" arr_tmp);
      emit_expr ctx arr;
      emit ctx (Printf.sprintf "; long %s = " row_tmp);
      emit_expr ctx row;
      emit ctx (Printf.sprintf "; long %s = " col_tmp);
      emit_expr ctx col;
      emit ctx
        (Printf.sprintf
           "; long __tg_cols = (%s && %s->len > 0) ? %s->capacity / %s->len : \
            0; long __tg_idx = %s * __tg_cols + %s; %s %s = {0}; if \
            (__builtin_expect(%s && %s >= 0 && %s >= 0 && %s < %s->len && %s < \
            __tg_cols && __tg_idx >= 0 && __tg_idx < %s->capacity, 1)) { if \
            (__builtin_expect(%s->storage_mode == BLORP_VECTOR_STORAGE_INLINE \
            && %s->elem_size == sizeof(%s), 1)) { memcpy(&%s, (char*)%s->data \
            + __tg_idx * sizeof(%s), sizeof(%s)); } else { void* __raw = \
            %s->data[__tg_idx]; %s = blorp_unbox_struct(__raw, %s); } } %s; })"
           arr_tmp arr_tmp arr_tmp arr_tmp row_tmp col_tmp struct_ty out_tmp
           arr_tmp row_tmp col_tmp row_tmp arr_tmp col_tmp arr_tmp arr_tmp
           arr_tmp struct_ty out_tmp arr_tmp struct_ty struct_ty arr_tmp out_tmp
           struct_ty out_tmp)
  | kind, _ -> (
      match kind with
      | UnboxFloat ->
          emit ctx "blorp_unbox_float(";
          emit_expr ctx u.unbox_value;
          emit ctx ")"
      | UnboxFloat32 ->
          emit ctx "blorp_unbox_float32(";
          emit_expr ctx u.unbox_value;
          emit ctx ")"
      | UnboxFloat16 ->
          emit ctx "blorp_unbox_float16(";
          emit_expr ctx u.unbox_value;
          emit ctx ")"
      | UnboxInt128 ->
          emit ctx "blorp_unbox_int128(";
          emit_expr ctx u.unbox_value;
          emit ctx ")"
      | UnboxUInt128 ->
          emit ctx "blorp_unbox_uint128(";
          emit_expr ctx u.unbox_value;
          emit ctx ")"
      | UnboxPrim ->
          emit ctx (Printf.sprintf "((%s)(long)" c_ty);
          emit_expr ctx u.unbox_value;
          emit ctx ")"
      | UnboxPointer ->
          emit ctx (Printf.sprintf "((%s)" c_ty);
          emit_expr ctx u.unbox_value;
          emit ctx ")"
      | UnboxStruct _ ->
          emit ctx (Printf.sprintf "(*(%s*)((char*)" c_ty);
          emit_expr ctx u.unbox_value;
          emit ctx " + sizeof(blorp_Object)))")

and emit_dict_ctor_for_kind ctx loc = function
  | DictGeneric -> emit ctx "blorp_dict_new()"
  | DictString -> emit ctx "blorp_dict_new_string()"
  | DictFloat -> emit ctx "blorp_dict_new_float()"
  | DictCustom key_ty ->
      let hash_c =
        trait_method_c_name_for_type ctx ~loc "Hashable" "hash" key_ty
      in
      let eq_c =
        trait_method_c_name_for_type ctx ~loc "Equatable" "equals" key_ty
      in
      let key_release = boxed_value_release_arg ctx key_ty loc in
      emit ctx
        (Printf.sprintf
           "blorp_dict_new_custom((unsigned long (*)(void*))%s, (bool \
            (*)(void*, void*))%s, %s)"
           hash_c eq_c key_release)

and emit_dict_construct ctx e dc =
  let emit_ctor () = emit_dict_ctor_for_kind ctx e.loc dc.dc_constructor in
  let emit_body tmp =
    if dc.dc_value_needs_release then emit_dict_value_release_init ctx tmp;
    List.iter
      (fun (k, v) ->
        emit ctx (Printf.sprintf " %s = blorp_dict_insert(%s, " tmp tmp);
        emit_boxed_storage ctx k;
        emit ctx ", ";
        emit_boxed_storage ctx v;
        emit ctx ");")
      dc.dc_entries
  in
  match (dc.dc_entries, dc.dc_value_needs_release) with
  | [], false -> emit_ctor ()
  | _ ->
      let tmp = Printf.sprintf "__dict_%d" (fresh_temp ctx) in
      emit ctx (Printf.sprintf "({ blorp_Dict* %s = " tmp);
      emit_ctor ();
      emit ctx ";";
      emit_body tmp;
      emit ctx (Printf.sprintf " %s; })" tmp)

and emit_set_alloc ctx loc = function
  | SetGeneric -> emit ctx "blorp_set_new()"
  | SetString -> emit ctx "blorp_set_new_string()"
  | SetFloat -> emit ctx "blorp_set_new_float()"
  | SetCustom elem_ty ->
      let hash_c =
        trait_method_c_name_for_type ctx ~loc "Hashable" "hash" elem_ty
      in
      let eq_c =
        trait_method_c_name_for_type ctx ~loc "Equatable" "equals" elem_ty
      in
      let elem_release = boxed_value_release_arg ctx elem_ty loc in
      emit ctx
        (Printf.sprintf
           "blorp_set_new_custom((unsigned long (*)(void*))%s, (bool \
            (*)(void*, void*))%s, %s)"
           hash_c eq_c elem_release)

and emit_tuple_construct ctx tc =
  if tc.tc_release_mask = 0 then begin
    emit ctx (Printf.sprintf "blorp_tuple_new(%d" (List.length tc.tc_elems));
    List.iter
      (fun value ->
        emit ctx ", ";
        emit_boxed_storage ctx value)
      tc.tc_elems;
    emit ctx ")"
  end
  else begin
    let tmp = Printf.sprintf "__tup_%d" (fresh_temp ctx) in
    emit ctx
      (Printf.sprintf "({ blorp_Tuple* %s = blorp_tuple_new(%d" tmp
         (List.length tc.tc_elems));
    List.iter
      (fun value ->
        emit ctx ", ";
        emit_boxed_storage ctx value)
      tc.tc_elems;
    emit ctx ");";
    List.iteri
      (fun i _ ->
        if tc.tc_retain_mask land (1 lsl i) <> 0 then
          emit ctx
            (Printf.sprintf " if (%s->elem[%d]) blorp_retain(%s->elem[%d]);" tmp
               i tmp i))
      tc.tc_elems;
    emit ctx
      (Printf.sprintf " blorp_tuple_set_rc(%s, %dUL); %s; })" tmp
         tc.tc_release_mask tmp)
  end

and emit_list_construct ctx lc =
  let tmp = Printf.sprintf "__lst_%d" (fresh_temp ctx) in
  emit ctx (Printf.sprintf "({ blorp_List* %s = " tmp);
  emit_list_alloc_call ctx lc.lc_layout (fun () ->
      emit ctx (string_of_int (List.length lc.lc_elems)));
  emit ctx ";";
  (match lc.lc_layout.lsl_slots with
  | ListInlineStructStorage c_ty ->
      List.iteri
        (fun i value ->
          let elem_tmp = Printf.sprintf "__lst_elem_%d" (fresh_temp ctx) in
          emit ctx (Printf.sprintf " { %s %s = " c_ty elem_tmp);
          emit_expr ctx value.bsv_box.box_value;
          emit ctx
            (Printf.sprintf "; blorp_list_set_raw_copy(%s, %d, &%s); }" tmp i
               elem_tmp))
        lc.lc_elems;
      emit ctx (Printf.sprintf " %s->len = %d;" tmp (List.length lc.lc_elems))
  | ListPointerStorage | ListInlineStorage _ ->
      if lc.lc_elem_needs_release then
        emit ctx
          (Printf.sprintf
             " blorp_list_init_elem_release(%s, blorp_elem_release_fn);" tmp);
      List.iter
        (fun value ->
          let append_fn =
            if lc.lc_elem_needs_release && value.bsv_transfers_ownership then
              "blorp_list_append_owned"
            else "blorp_list_append"
          in
          emit ctx (Printf.sprintf " %s = %s(%s, " tmp append_fn tmp);
          emit_boxed_storage ctx value;
          emit ctx ");")
        lc.lc_elems);
  emit ctx (Printf.sprintf " %s; })" tmp)

and emit_record_construct ctx rc =
  emit ctx (Printf.sprintf "%s_make(" rc.rc_type_name);
  List.iteri
    (fun i field ->
      if i > 0 then emit ctx ", ";
      match field with
      | RecordRawField (_, value) -> emit_expr ctx value
      | RecordErasedField (_, value) -> emit_boxed_storage ctx value)
    rc.rc_fields;
  (match rc.rc_erased_release_mask with
  | Some mask ->
      if rc.rc_fields <> [] then emit ctx ", ";
      emit ctx (Printf.sprintf "%dUL" mask)
  | None -> ());
  emit ctx ")"

and emit_tensor_literal ctx loc tl =
  if not (tensor_literal_layout_matches_payload tl.tl_layout tl.tl_payload) then
    let expected = tensor_storage_slot_layout_str tl.tl_layout.tsl_slots in
    let actual =
      tensor_storage_slot_layout_str
        (tensor_literal_payload_slot_layout tl.tl_payload)
    in
    Core_error.errorf Core_error.Emit loc
      ~hint:
        "Run with --check-invariants to catch malformed final Core before \
         emission. Tensor literal storage layout and payload representation \
         must be selected together in Core_codegen_prepare."
      "tensor literal layout `%s` does not match payload storage `%s`" expected
      actual
  else ();
  let vector_ctor, tensor_ctor =
    match tl.tl_layout.tsl_slots with
    | TensorRawScalarStorage TensorFloat32Elements ->
        ("blorp_vector_new_f32", "blorp_tensor_new_f32")
    | TensorRawScalarStorage TensorFloat64Elements ->
        ("blorp_vector_new_f64", "blorp_tensor_new_f64")
    | TensorRawScalarStorage TensorInt64Elements ->
        ("blorp_vector_new_i64", "blorp_tensor_new_i64")
    | TensorWordStorage -> ("blorp_vector_new", "blorp_tensor_new")
    | TensorPackedStorage _ ->
        ("blorp_vector_new_packed", "blorp_tensor_new_packed")
    | TensorInlineStructStorage _ ->
        ("blorp_vector_new_sized", "blorp_tensor_new_sized")
    | TensorBoxedStorage -> ("blorp_vector_new", "blorp_tensor_new")
  in
  let packed_width_arg = function
    | InlineBytes1 -> "1"
    | InlineBytes2 -> "2"
    | InlineBytes4 -> "4"
    | InlineBytes8 -> "8"
  in
  let ctor, first_dim, total =
    match tl.tl_shape with
    | TensorStaticShape (first :: _ as dims) ->
        (tensor_ctor, first, List.fold_left ( * ) 1 dims)
    | TensorStaticShape [] -> (vector_ctor, 0, 0)
    | TensorVectorLength n -> (vector_ctor, n, n)
  in
  let tmp = Printf.sprintf "__ten_%d" (fresh_temp ctx) in
  (match tl.tl_shape with
  | TensorStaticShape (_ :: _) -> (
      match tl.tl_layout.tsl_slots with
      | TensorPackedStorage width ->
          emit ctx
            (Printf.sprintf "({ blorp_Vector* %s = %s(%d, %d, %s);" tmp ctor
               first_dim total (packed_width_arg width))
      | TensorInlineStructStorage c_ty ->
          emit ctx
            (Printf.sprintf "({ blorp_Vector* %s = %s(%d, %d, sizeof(%s));" tmp
               ctor first_dim total c_ty)
      | _ ->
          emit ctx
            (Printf.sprintf "({ blorp_Vector* %s = %s(%d, %d);" tmp ctor
               first_dim total))
  | TensorStaticShape [] | TensorVectorLength _ -> (
      match tl.tl_layout.tsl_slots with
      | TensorPackedStorage width ->
          emit ctx
            (Printf.sprintf "({ blorp_Vector* %s = %s(%d, %s);" tmp ctor
               first_dim (packed_width_arg width))
      | TensorInlineStructStorage c_ty ->
          emit ctx
            (Printf.sprintf "({ blorp_Vector* %s = %s(%d, sizeof(%s));" tmp ctor
               first_dim c_ty)
      | _ ->
          emit ctx
            (Printf.sprintf "({ blorp_Vector* %s = %s(%d);" tmp ctor first_dim)));
  let elem_needs_release =
    tensor_storage_layout_requires_release_or_error ~phase:Core_error.Emit ~loc
      tl.tl_layout
  in
  if elem_needs_release then
    emit ctx
      (Printf.sprintf
         " blorp_vector_init_elem_release(%s, blorp_elem_release_fn);" tmp);
  (match tl.tl_payload with
  | TensorRawElements (TensorFloat32Elements, elems) ->
      List.iteri
        (fun i el ->
          emit ctx (Printf.sprintf " ((float*)%s->data)[%d] = " tmp i);
          emit_expr ctx el;
          emit ctx ";")
        elems
  | TensorRawElements (TensorFloat64Elements, elems) ->
      List.iteri
        (fun i el ->
          emit ctx (Printf.sprintf " blorp_vector_write_f64(%s, %d, " tmp i);
          emit_expr ctx el;
          emit ctx ");")
        elems
  | TensorRawElements (TensorInt64Elements, elems) ->
      List.iteri
        (fun i el ->
          emit ctx (Printf.sprintf " ((long*)%s->data)[%d] = " tmp i);
          emit_expr ctx el;
          emit ctx ";")
        elems
  | TensorWordElements elems ->
      List.iteri
        (fun i el ->
          emit ctx (Printf.sprintf " %s->data[%d] = (void*)(intptr_t)(" tmp i);
          emit_expr ctx el;
          emit ctx ");")
        elems
  | TensorPackedElements (_, elems) ->
      List.iteri
        (fun i el ->
          emit ctx (Printf.sprintf " blorp_packed_set(%s, %d, (long)(" tmp i);
          emit_expr ctx el;
          emit ctx "));")
        elems
  | TensorInlineStructElements (c_ty, elems) ->
      List.iteri
        (fun i el ->
          let elem_tmp = Printf.sprintf "__ten_elem_%d" (fresh_temp ctx) in
          emit ctx (Printf.sprintf " { %s %s = " c_ty elem_tmp);
          emit_expr ctx el;
          emit ctx
            (Printf.sprintf
               "; memcpy((char*)%s->data + %d * sizeof(%s), &%s, sizeof(%s)); }"
               tmp i c_ty elem_tmp c_ty))
        elems
  | TensorBoxedElements elems ->
      List.iteri
        (fun i value ->
          if elem_needs_release then begin
            let elem_tmp = Printf.sprintf "__elem_%d" (fresh_temp ctx) in
            emit ctx (Printf.sprintf " void* %s = " elem_tmp);
            emit_boxed_storage ctx value;
            emit ctx (Printf.sprintf "; %s->data[%d] = %s;" tmp i elem_tmp);
            if not value.bsv_transfers_ownership then
              emit ctx
                (Printf.sprintf " if (%s) blorp_retain(%s);" elem_tmp elem_tmp)
          end
          else begin
            emit ctx (Printf.sprintf " %s->data[%d] = " tmp i);
            emit_boxed_storage ctx value;
            emit ctx ";"
          end)
        elems);
  emit ctx (Printf.sprintf " %s; })" tmp)

and emit_tensor_fill_total_expr ctx dim_tmps =
  let rec emit_product = function
    | [] -> emit ctx "0"
    | [ dim ] -> emit ctx dim
    | dim :: rest ->
        emit ctx "(";
        emit ctx dim;
        emit ctx " * ";
        emit_product rest;
        emit ctx ")"
  in
  emit_product dim_tmps

and emit_tensor_fill_alloc_call ctx loc layout first_dim total_dim =
  match layout.tsl_slots with
  | TensorRawScalarStorage TensorInt64Elements ->
      emit ctx "blorp_tensor_new_i64(";
      emit ctx first_dim;
      emit ctx ", ";
      emit ctx total_dim;
      emit ctx ")"
  | TensorRawScalarStorage TensorFloat64Elements ->
      emit ctx "blorp_tensor_new_f64(";
      emit ctx first_dim;
      emit ctx ", ";
      emit ctx total_dim;
      emit ctx ")"
  | TensorRawScalarStorage TensorFloat32Elements ->
      emit ctx "blorp_tensor_new_f32(";
      emit ctx first_dim;
      emit ctx ", ";
      emit ctx total_dim;
      emit ctx ")"
  | TensorPackedStorage width ->
      emit ctx "blorp_tensor_new_packed(";
      emit ctx first_dim;
      emit ctx ", ";
      emit ctx total_dim;
      emit ctx (Printf.sprintf ", %d)" (inline_storage_width_bytes width))
  | _ ->
      Core_error.errorf Core_error.Emit loc
        "unsupported tensor fill allocation layout"

and emit_tensor_fill_factory ctx loc ty value dims =
  let layout =
    Core_layout_type.tensor_storage_layout_of_type ~reg:ctx.reg ty loc
  in
  match layout.tsl_slots with
  | TensorRawScalarStorage _ | TensorPackedStorage _ -> (
      match dims with
      | [] ->
          Core_error.errorf Core_error.Emit loc
            ~hint:
              "tensor fill factories should carry at least the first dimension \
               by the time they reach C emission"
            "malformed tensor fill factory call"
      | _ ->
          let dim_tmps =
            List.map
              (fun _ -> Printf.sprintf "__tensor_fill_dim_%d" (fresh_temp ctx))
              dims
          in
          let value_tmp =
            Printf.sprintf "__tensor_fill_value_%d" (fresh_temp ctx)
          in
          let value =
            match value.desc with
            | CBoxTyped b -> b.box_value
            | CBox (inner, _) -> inner
            | _ -> value
          in
          let total_tmp =
            Printf.sprintf "__tensor_fill_total_%d" (fresh_temp ctx)
          in
          let vec_tmp =
            Printf.sprintf "__tensor_fill_vec_%d" (fresh_temp ctx)
          in
          let i_tmp = Printf.sprintf "__tensor_fill_i_%d" (fresh_temp ctx) in
          let value_c_ty, emit_store =
            match layout.tsl_slots with
            | TensorRawScalarStorage kind ->
                let c_ty =
                  (Core_layout_type.tensor_raw_scalar_abi kind).tras_c_type
                in
                let raw_tmp =
                  Printf.sprintf "__tensor_fill_raw_%d" (fresh_temp ctx)
                in
                ( c_ty,
                  fun () ->
                    emit ctx
                      (Printf.sprintf "%s* %s = (%s*)%s->data; " c_ty raw_tmp
                         c_ty vec_tmp);
                    emit ctx
                      (Printf.sprintf
                         "for (long %s = 0; %s < %s->capacity; %s++) %s[%s] = \
                          %s;"
                         i_tmp i_tmp vec_tmp i_tmp raw_tmp i_tmp value_tmp) )
            | TensorPackedStorage _ ->
                ( "long",
                  fun () ->
                    emit ctx
                      (Printf.sprintf
                         "for (long %s = 0; %s < %s->capacity; %s++) \
                          blorp_packed_set(%s, %s, %s);"
                         i_tmp i_tmp vec_tmp i_tmp vec_tmp i_tmp value_tmp) )
            | _ -> assert false
          in
          emit ctx "({ ";
          List.iter2
            (fun dim_tmp dim ->
              emit ctx (Printf.sprintf "long %s = " dim_tmp);
              emit_expr ctx dim;
              emit ctx "; ")
            dim_tmps dims;
          emit ctx (Printf.sprintf "long %s = " total_tmp);
          emit_tensor_fill_total_expr ctx dim_tmps;
          emit ctx "; ";
          emit ctx (Printf.sprintf "%s %s = " value_c_ty value_tmp);
          emit_expr ctx value;
          emit ctx "; ";
          emit ctx (Printf.sprintf "blorp_Vector* %s = " vec_tmp);
          emit_tensor_fill_alloc_call ctx loc layout (List.hd dim_tmps)
            total_tmp;
          emit ctx "; ";
          emit_store ();
          emit ctx (Printf.sprintf " %s; })" vec_tmp))
  | _ ->
      Core_error.errorf Core_error.Emit loc
        ~hint:
          "Only raw numeric and packed tensor fill factories are emitted by \
           this path; boxed and inline-struct tensors use their dedicated \
           ownership-aware emitters."
        "unsupported tensor fill storage layout: %s"
        (tensor_storage_slot_layout_str layout.tsl_slots)

and emit_union_construct ctx uc =
  let option_constructor_abi =
    match uc.uc_representation with
    | OptionUnion layout ->
        Some (Core_layout_type.option_constructor_abi_of_layout layout)
    | GenericUnion | ResultUnion _ -> None
  in
  let emit_nullable_managed_payload arg =
    match normalize_type arg.bsv_box.box_source_ty with
    | Ast.TyFunc _ -> emit_boxed ctx arg.bsv_box.box_value
    | _ -> emit_expr ctx arg.bsv_box.box_value
  in
  match (uc.uc_representation, uc.uc_args) with
  | ResultUnion result_layout, [ arg ] ->
      let abi =
        Core_layout_type.stack_result_constructor_abi_of_layout result_layout
      in
      emit ctx
        (Printf.sprintf
           "((%s){ .tag = %d, .release_mask = %dUL, .data.%s.field0 = "
           abi.src_result_c_type uc.uc_tag uc.uc_release_mask
           uc.uc_constructor_name);
      emit_boxed_storage ctx arg;
      emit ctx " })"
  | ResultUnion _, _ ->
      Core_error.errorf Core_error.Emit Ast.dummy_loc
        ~hint:"stack Result constructors are represented as tag + one payload"
        "invalid stack Result constructor arity for %s" uc.uc_constructor_name
  | _ -> (
      match (option_constructor_abi, uc.uc_args) with
      | Some Core_layout_type.OptionConstructorNullableManaged, [] ->
          emit ctx "NULL"
      | Some Core_layout_type.OptionConstructorNullableManaged, [ arg ] ->
          emit_nullable_managed_payload arg
      | Some Core_layout_type.OptionConstructorNullableManaged, _ ->
          Core_error.errorf Core_error.Emit Ast.dummy_loc
            ~hint:
              "nullable managed Option constructors are represented as NULL or \
               one managed payload pointer"
            "invalid nullable managed Option constructor arity for %s"
            uc.uc_constructor_name
      | Some (Core_layout_type.OptionConstructorStackInline abi), [] ->
          emit ctx
            (Printf.sprintf "((%s){ .tag = %d, .value = %s })" abi.soe_c_type
               uc.uc_tag abi.soe_none_value)
      | Some (Core_layout_type.OptionConstructorStackInline abi), [ arg ]
        when is_void_ty arg.bsv_box.box_value.ty ->
          emit ctx "({ ";
          emit_stmt ctx arg.bsv_box.box_value;
          emit ctx
            (Printf.sprintf "((%s){ .tag = %d, .value = 0 }); })" abi.soe_c_type
               uc.uc_tag)
      | Some (Core_layout_type.OptionConstructorStackInline abi), [ arg ] ->
          emit ctx
            (Printf.sprintf "((%s){ .tag = %d, .value = " abi.soe_c_type
               uc.uc_tag);
          emit_expr ctx arg.bsv_box.box_value;
          emit ctx " })"
      | Some (Core_layout_type.OptionConstructorStackInline _), _ ->
          Core_error.errorf Core_error.Emit Ast.dummy_loc
            ~hint:
              "stack Option constructors are represented as tag + one payload"
            "invalid stack Option constructor arity for %s"
            uc.uc_constructor_name
      | Some (Core_layout_type.OptionConstructorUnavailable reason), _ ->
          Core_error.errorf Core_error.Emit Ast.dummy_loc
            ~hint:
              "Option constructor emission must use the representation chosen \
               by the late layout boundary; do not fall back to boxed-union \
               emission for stack Option layouts."
            "unsupported Option constructor layout for %s: %s"
            uc.uc_constructor_name reason
      | (Some Core_layout_type.OptionConstructorBoxedUnion | None), [] ->
          emit ctx (escape_c_ident uc.uc_c_name)
      | (Some Core_layout_type.OptionConstructorBoxedUnion | None), args ->
          emit ctx uc.uc_c_name;
          emit ctx "(";
          List.iteri
            (fun i arg ->
              if i > 0 then emit ctx ", ";
              emit_boxed_storage ctx arg)
            args;
          emit ctx (Printf.sprintf ", %dUL)" uc.uc_release_mask))

and emit_generated_stack_option_vector_get ctx abi arr idx =
  let vec_tmp = Printf.sprintf "__gso_vec_%d" (fresh_temp ctx) in
  let idx_tmp = Printf.sprintf "__gso_idx_%d" (fresh_temp ctx) in
  let raw_tmp = Printf.sprintf "__gso_raw_%d" (fresh_temp ctx) in
  let payload_tmp = Printf.sprintf "__gso_payload_%d" (fresh_temp ctx) in
  let result_tmp = Printf.sprintf "__gso_result_%d" (fresh_temp ctx) in
  emit ctx (Printf.sprintf "({ blorp_Vector* %s = (blorp_Vector*)" vec_tmp);
  emit_expr ctx arr;
  emit ctx (Printf.sprintf "; long %s = " idx_tmp);
  emit_expr ctx idx;
  emit ctx
    (Printf.sprintf "; %s %s; " abi.Core_layout_type.gsog_option_c_type
       result_tmp);
  emit ctx
    (Printf.sprintf "if (!%s || %s < 0 || %s >= %s->len) { " vec_tmp idx_tmp
       idx_tmp vec_tmp);
  emit_generated_stack_option_none_assignment ctx abi result_tmp;
  emit ctx " } else { ";
  (match abi.Core_layout_type.gsog_payload_storage with
  | Core_layout_type.GeneratedStackOptionValueRecord _ ->
      emit ctx
        (Printf.sprintf
           "if (%s->storage_mode == BLORP_VECTOR_STORAGE_INLINE) { %s %s; \
            memcpy(&%s, (char*)%s->data + %s * %s->elem_size, sizeof(%s)); "
           vec_tmp abi.Core_layout_type.gsog_payload_c_type payload_tmp
           payload_tmp vec_tmp idx_tmp vec_tmp
           abi.Core_layout_type.gsog_payload_c_type);
      emit_generated_stack_option_some_assignment ctx abi result_tmp payload_tmp;
      emit ctx
        (Printf.sprintf " } else { void* %s = %s->data[%s]; " raw_tmp vec_tmp
           idx_tmp);
      emit_generated_stack_option_some_assignment ctx abi result_tmp
        (Core_layout_type.generated_stack_option_payload_from_erased abi raw_tmp);
      emit ctx " }"
  | Core_layout_type.GeneratedStackOptionLong ->
      emit_generated_stack_option_some_assignment ctx abi result_tmp
        (Printf.sprintf "blorp_vector_read_i64(%s, %s)" vec_tmp idx_tmp)
  | Core_layout_type.GeneratedStackOptionInt128
  | Core_layout_type.GeneratedStackOptionUInt128 ->
      emit ctx
        (Printf.sprintf "void* %s = %s->data[%s];" raw_tmp vec_tmp idx_tmp);
      emit_generated_stack_option_some_assignment ctx abi result_tmp
        (Core_layout_type.generated_stack_option_payload_from_erased abi raw_tmp));
  emit ctx (Printf.sprintf " } %s; })" result_tmp)

and emit_generated_stack_option_matrix_get ctx abi arr row col =
  let vec_tmp = Printf.sprintf "__gso_mat_%d" (fresh_temp ctx) in
  let row_tmp = Printf.sprintf "__gso_row_%d" (fresh_temp ctx) in
  let col_tmp = Printf.sprintf "__gso_col_%d" (fresh_temp ctx) in
  let cols_tmp = Printf.sprintf "__gso_cols_%d" (fresh_temp ctx) in
  let idx_tmp = Printf.sprintf "__gso_idx_%d" (fresh_temp ctx) in
  let raw_tmp = Printf.sprintf "__gso_raw_%d" (fresh_temp ctx) in
  let payload_tmp = Printf.sprintf "__gso_payload_%d" (fresh_temp ctx) in
  let result_tmp = Printf.sprintf "__gso_result_%d" (fresh_temp ctx) in
  emit ctx (Printf.sprintf "({ blorp_Vector* %s = (blorp_Vector*)" vec_tmp);
  emit_expr ctx arr;
  emit ctx (Printf.sprintf "; long %s = " row_tmp);
  emit_expr ctx row;
  emit ctx (Printf.sprintf "; long %s = " col_tmp);
  emit_expr ctx col;
  emit ctx
    (Printf.sprintf
       "; long %s = (%s && %s->len > 0) ? %s->capacity / %s->len : 0; long %s \
        = %s * %s + %s; %s %s; "
       cols_tmp vec_tmp vec_tmp vec_tmp vec_tmp idx_tmp row_tmp cols_tmp col_tmp
       abi.Core_layout_type.gsog_option_c_type result_tmp);
  emit ctx
    (Printf.sprintf
       "if (!%s || %s < 0 || %s < 0 || %s < 0 || %s >= %s->capacity) { " vec_tmp
       row_tmp col_tmp idx_tmp idx_tmp vec_tmp);
  emit_generated_stack_option_none_assignment ctx abi result_tmp;
  emit ctx " } else { ";
  (match abi.Core_layout_type.gsog_payload_storage with
  | Core_layout_type.GeneratedStackOptionValueRecord _ ->
      emit ctx
        (Printf.sprintf
           "if (%s->storage_mode == BLORP_VECTOR_STORAGE_INLINE) { %s %s; \
            memcpy(&%s, (char*)%s->data + %s * %s->elem_size, sizeof(%s)); "
           vec_tmp abi.Core_layout_type.gsog_payload_c_type payload_tmp
           payload_tmp vec_tmp idx_tmp vec_tmp
           abi.Core_layout_type.gsog_payload_c_type);
      emit_generated_stack_option_some_assignment ctx abi result_tmp payload_tmp;
      emit ctx
        (Printf.sprintf " } else { void* %s = %s->data[%s]; " raw_tmp vec_tmp
           idx_tmp);
      emit_generated_stack_option_some_assignment ctx abi result_tmp
        (Core_layout_type.generated_stack_option_payload_from_erased abi raw_tmp);
      emit ctx " }"
  | Core_layout_type.GeneratedStackOptionLong ->
      emit_generated_stack_option_some_assignment ctx abi result_tmp
        (Printf.sprintf "blorp_vector_read_i64(%s, %s)" vec_tmp idx_tmp)
  | Core_layout_type.GeneratedStackOptionInt128
  | Core_layout_type.GeneratedStackOptionUInt128 ->
      emit ctx
        (Printf.sprintf "void* %s = %s->data[%s];" raw_tmp vec_tmp idx_tmp);
      emit_generated_stack_option_some_assignment ctx abi result_tmp
        (Core_layout_type.generated_stack_option_payload_from_erased abi raw_tmp));
  emit ctx (Printf.sprintf " } %s; })" result_tmp)

and emit_generated_stack_option_dict_get ctx abi dict key =
  let dict_tmp = Printf.sprintf "__gso_dict_%d" (fresh_temp ctx) in
  let key_tmp = Printf.sprintf "__gso_key_%d" (fresh_temp ctx) in
  let found_tmp = Printf.sprintf "__gso_found_%d" (fresh_temp ctx) in
  let raw_tmp = Printf.sprintf "__gso_raw_%d" (fresh_temp ctx) in
  let result_tmp = Printf.sprintf "__gso_result_%d" (fresh_temp ctx) in
  let key_needs_release = boxed_expr_transfers_ownership ctx key in
  emit ctx (Printf.sprintf "({ blorp_Dict* %s = (blorp_Dict*)" dict_tmp);
  emit_expr ctx dict;
  emit ctx (Printf.sprintf "; void* %s = " key_tmp);
  emit_boxed ctx key;
  emit ctx
    (Printf.sprintf
       "; void* %s = NULL; bool %s = blorp_dict_get_raw(%s, %s, &%s); %s %s; "
       raw_tmp found_tmp dict_tmp key_tmp raw_tmp
       abi.Core_layout_type.gsog_option_c_type result_tmp);
  emit ctx (Printf.sprintf "if (%s) { " found_tmp);
  emit_generated_stack_option_some_assignment ctx abi result_tmp
    (Core_layout_type.generated_stack_option_payload_from_erased abi raw_tmp);
  emit ctx " } else { ";
  emit_generated_stack_option_none_assignment ctx abi result_tmp;
  emit ctx " }";
  if key_needs_release then
    emit ctx (Printf.sprintf " blorp_release(%s);" key_tmp);
  emit ctx (Printf.sprintf " %s; })" result_tmp)

and emit_option_equality ctx e l r =
  let option_ty =
    match normalize_type l.ty with
    | Ast.TyNamed ("Option", _) -> l.ty
    | _ -> r.ty
  in
  match Core_layout_type.option_equality_abi ~reg:ctx.reg option_ty with
  | Core_layout_type.OptionEqualityStackInline { oeq_option_c_type } ->
      let lhs_tmp = Printf.sprintf "__opt_eq_l_%d" (fresh_temp ctx) in
      let rhs_tmp = Printf.sprintf "__opt_eq_r_%d" (fresh_temp ctx) in
      emit ctx (Printf.sprintf "({ %s %s = " oeq_option_c_type lhs_tmp);
      emit_expr ctx l;
      emit ctx (Printf.sprintf "; %s %s = " oeq_option_c_type rhs_tmp);
      emit_expr ctx r;
      emit ctx
        (Printf.sprintf
           "; ((%s.tag == %s.tag) && (%s.tag != BLORP_TAG_SOME || %s.value == \
            %s.value)); })"
           lhs_tmp rhs_tmp lhs_tmp lhs_tmp rhs_tmp)
  | Core_layout_type.OptionEqualityNullableString ->
      let option_c_type = type_to_c ctx option_ty in
      let lhs_tmp = Printf.sprintf "__opt_eq_l_%d" (fresh_temp ctx) in
      let rhs_tmp = Printf.sprintf "__opt_eq_r_%d" (fresh_temp ctx) in
      emit ctx (Printf.sprintf "({ %s %s = " option_c_type lhs_tmp);
      emit_expr ctx l;
      emit ctx (Printf.sprintf "; %s %s = " option_c_type rhs_tmp);
      emit_expr ctx r;
      emit ctx
        (Printf.sprintf
           "; ((%s == %s) || (%s != NULL && %s != NULL && blorp_string_eq(%s, \
            %s))); })"
           lhs_tmp rhs_tmp lhs_tmp rhs_tmp lhs_tmp rhs_tmp)
  | Core_layout_type.OptionEqualityBoxedUnionRuntime fn ->
      emit ctx fn;
      emit ctx "(";
      emit_expr ctx l;
      emit ctx ", ";
      emit_expr ctx r;
      emit ctx ")"
  | Core_layout_type.OptionEqualityUnavailable reason ->
      Core_error.errorf Core_error.Emit e.loc
        ~hint:
          "Option equality reached emission without a layout-safe lowering. \
           Add a Core_layout_type option_equality_abi case for this \
           representation."
        "cannot emit Option equality safely: %s" reason

(* --- §2. emit_expr --------------------------------------------------------- *)

(** Emit a Core expression into [ctx.output] in expression context (i.e.,
    the result is a C expression that can appear as the RHS of [=] or the
    operand of [return]). *)
and emit_expr (ctx : Core_emit_context.t) (e : core) : unit =
  match e.desc with
  | CLit lit -> gen_literal ctx lit
  | CVar v ->
      if
        cvar_is_typed_constructor ctx v e.ty ~type_name:"Option"
          ~ctor_name:"None"
      then
        match
          ( Core_layout_type.stack_option_c_type ~reg:ctx.reg e.ty,
            nullable_managed_option_payload_type ctx e.ty )
        with
        | Some c_ty, _ ->
            emit ctx
              (Printf.sprintf "((%s){ .tag = BLORP_TAG_NONE, .value = %s })"
                 c_ty
                 (Core_layout_type.stack_option_none_value_for_type ~reg:ctx.reg
                    e.ty))
        | None, Some _ -> emit ctx "NULL"
        | None, None ->
            emit ctx (escape_c_ident (var_ref_c_name_for_type ctx v e.ty))
      else if Hashtbl.mem ctx.constructor_names v.vname then
        emit ctx (escape_c_ident (var_ref_c_name_for_type ctx v e.ty))
      else if
        (match normalize_type e.ty with Ast.TyFunc _ -> true | _ -> false)
        && is_global_func_var ctx v
      then
        Core_error.errorf Core_error.Emit e.loc
          ~hint:
            "Core_closure.adapt_function_refs_program should rewrite \
             first-class top-level function references into CClosureCreate eta \
             adapters before final Core. Do not synthesize function-reference \
             trampolines in the emitter."
          "raw top-level function reference `%s` reached Core_emit" v.vname
      else
        (* Bare CVar references stay unmangled in A4.2. Direct function
         call sites use [CKUser (name, Some id)] and emit the callee
         without evaluating this expression node. First-class top-level
         function references must already be explicit [CClosureCreate]
         nodes by Final Core. *)
        emit ctx (escape_c_ident (Var.to_c_name v))
  | CVoid ->
      (* Void expression in an expression context: parity with existing
         codegen uses [(void)0] when a void value needs to sit inside an
         expression slot. *)
      emit ctx "(void)0"
  | CListHandoff h -> emit_list_handoff ctx e h
  (* ---- Operators ---- *)
  | CBin (op, l, r) -> (
      (* String ordering/equality must dispatch to the runtime instead of
         emitting a raw C operator — raw [>=] etc. on [blorp_String*]
         compares pointer addresses, which is non-deterministic. *)
      let is_string_ty ty =
        match normalize_type ty with
        | Ast.TyNamed ("String", _) | Ast.TyNamed ("LiteralString", _) -> true
        | _ -> false
      in
      let list_elem ty =
        match normalize_type ty with
        | Ast.TyNamed ("List", [ elem ]) -> Some (normalize_type elem)
        | _ -> None
      in
      (* Dict value type drives the eq-variant: String values need deep
         compare, Float values need NaN-safe compare, others compare
         via the boxed void* slot. Keys always use the dict's hash_fn /
         slot lookup, so the variant is picked on value type alone. *)
      let dict_value_ty ty =
        match normalize_type ty with
        | Ast.TyNamed ("Dict", [ _; v ]) -> Some (normalize_type v)
        | _ -> None
      in
      let is_set_ty ty =
        match normalize_type ty with
        | Ast.TyNamed ("Set", _) -> true
        | _ -> false
      in
      let string_cmp = is_string_ty l.ty || is_string_ty r.ty in
      let list_cmp =
        match (list_elem l.ty, list_elem r.ty) with
        | Some e, _ | _, Some e -> Some e
        | None, None -> None
      in
      let dict_cmp =
        match (dict_value_ty l.ty, dict_value_ty r.ty) with
        | Some v, _ | _, Some v -> Some v
        | None, None -> None
      in
      let set_cmp = is_set_ty l.ty || is_set_ty r.ty in
      let fixed_cmp = is_fixed_ty l.ty || is_fixed_ty r.ty in
      let emit_fixed_call fn =
        emit ctx fn;
        emit ctx "(";
        emit_expr ctx l;
        emit ctx ", ";
        emit_expr ctx r;
        emit ctx ")"
      in
      if fixed_cmp then
        match fixed_binop_runtime op with
        | Some (`Call fn) -> emit_fixed_call fn
        | Some (`NegatedCall fn) ->
            emit ctx "(!";
            emit_fixed_call fn;
            emit ctx ")"
        | None ->
            Core_error.errorf
              ~hint:"Fixed modulo should be rejected during type checking."
              Core_error.Emit e.loc
              "unsupported Fixed operator reached C emission"
      else
        match (op, string_cmp, list_cmp, dict_cmp, set_cmp) with
        | Ast.Eq, true, _, _, _ ->
            emit ctx "blorp_string_eq(";
            emit_expr ctx l;
            emit ctx ", ";
            emit_expr ctx r;
            emit ctx ")"
        | Ast.Ne, true, _, _, _ ->
            emit ctx "(!blorp_string_eq(";
            emit_expr ctx l;
            emit ctx ", ";
            emit_expr ctx r;
            emit ctx "))"
        | (Ast.Lt | Ast.Gt | Ast.Le | Ast.Ge), true, _, _, _ ->
            let c_op =
              match op with
              | Ast.Lt -> " < "
              | Ast.Gt -> " > "
              | Ast.Le -> " <= "
              | Ast.Ge -> " >= "
              | _ -> " "
            in
            emit ctx "(blorp_string_compare(";
            emit_expr ctx l;
            emit ctx ", ";
            emit_expr ctx r;
            emit ctx (Printf.sprintf ")%s0)" c_op)
        (* List equality: element-wise compare via the runtime. Picks the
          right variant by element type so String elements get deep
          compare and Float elements get NaN-safe compare. *)
        | Ast.Eq, _, Some elem_ty, _, _ ->
            let fn =
              match elem_ty with
              | Ast.TyNamed ("String", _) -> "blorp_list_eq_string"
              | Ast.TyNamed ("Float", _) -> "blorp_list_eq_float"
              | _ -> "blorp_list_eq"
            in
            emit ctx fn;
            emit ctx "(";
            emit_expr ctx l;
            emit ctx ", ";
            emit_expr ctx r;
            emit ctx ")"
        | Ast.Ne, _, Some elem_ty, _, _ ->
            let fn =
              match elem_ty with
              | Ast.TyNamed ("String", _) -> "blorp_list_eq_string"
              | Ast.TyNamed ("Float", _) -> "blorp_list_eq_float"
              | _ -> "blorp_list_eq"
            in
            emit ctx "(!";
            emit ctx fn;
            emit ctx "(";
            emit_expr ctx l;
            emit ctx ", ";
            emit_expr ctx r;
            emit ctx "))"
        (* Dict equality: same variant-by-value-type pattern as List.
          Dict keys dispatch via the dict's own hash_fn / eq_fn during
          slot lookup, so only the value type drives the variant. *)
        | Ast.Eq, _, _, Some v_ty, _ ->
            let fn =
              match v_ty with
              | Ast.TyNamed ("String", _) -> "blorp_dict_eq_string_value"
              | Ast.TyNamed ("Float", _) -> "blorp_dict_eq_float_value"
              | _ -> "blorp_dict_eq"
            in
            emit ctx fn;
            emit ctx "(";
            emit_expr ctx l;
            emit ctx ", ";
            emit_expr ctx r;
            emit ctx ")"
        | Ast.Ne, _, _, Some v_ty, _ ->
            let fn =
              match v_ty with
              | Ast.TyNamed ("String", _) -> "blorp_dict_eq_string_value"
              | Ast.TyNamed ("Float", _) -> "blorp_dict_eq_float_value"
              | _ -> "blorp_dict_eq"
            in
            emit ctx "(!";
            emit ctx fn;
            emit ctx "(";
            emit_expr ctx l;
            emit ctx ", ";
            emit_expr ctx r;
            emit ctx "))"
        (* Set equality: single runtime entry — sets don't have a
          String/Float-value variant because sets have no values. *)
        | Ast.Eq, _, _, _, true ->
            emit ctx "blorp_set_eq(";
            emit_expr ctx l;
            emit ctx ", ";
            emit_expr ctx r;
            emit ctx ")"
        | Ast.Ne, _, _, _, true ->
            emit ctx "(!blorp_set_eq(";
            emit_expr ctx l;
            emit ctx ", ";
            emit_expr ctx r;
            emit ctx "))"
        (* Safe integer division: 10 / 0 → 0, 10 % 0 → 0.
          Language principle: "No runtime panics — operations succeed by
          design." C integer div/mod by zero is undefined behavior. *)
        | (Ast.Div | Ast.Mod), _, _, _, _
          when match normalize_type l.ty with
               | Ast.TyNamed ("Int", _) -> true
               | ty when Types.Dim.is_value_dim ty -> true
               | ty when Types.is_any_integer_type ty -> true
               | _ -> false ->
            let id = fresh_temp ctx in
            let d = Printf.sprintf "__d_%d" id in
            emit ctx (Printf.sprintf "({ long %s = " d);
            emit_expr ctx r;
            emit ctx (Printf.sprintf "; (%s == 0L ? 0L : " d);
            emit_expr ctx l;
            emit_binop ctx op;
            emit ctx (Printf.sprintf "%s); })" d)
        (* C has no [%] for floats. Preserve blorp's infallible modulo
          semantics by evaluating both operands once and returning zero
          when the divisor is zero. *)
        | Ast.Mod, _, _, _, _ -> (
            match float_modulo_emission l.ty with
            | Some (c_ty, zero, fn, cast_via_double) ->
                let id = fresh_temp ctx in
                let n = Printf.sprintf "__fm_n_%d" id in
                let d = Printf.sprintf "__fm_d_%d" id in
                emit ctx (Printf.sprintf "({ %s %s = " c_ty n);
                emit_expr ctx l;
                emit ctx (Printf.sprintf "; %s %s = " c_ty d);
                emit_expr ctx r;
                if cast_via_double then
                  emit ctx
                    (Printf.sprintf
                       "; (%s == %s ? %s : (%s)%s((double)%s, (double)%s)); })"
                       d zero zero c_ty fn n d)
                else
                  emit ctx
                    (Printf.sprintf "; (%s == %s ? %s : %s(%s, %s)); })" d zero
                       zero fn n d)
            | None ->
                emit ctx "(";
                emit_expr ctx l;
                emit_binop ctx op;
                emit_expr ctx r;
                emit ctx ")")
        | _ ->
            emit ctx "(";
            emit_expr ctx l;
            emit_binop ctx op;
            emit_expr ctx r;
            emit ctx ")")
  | CUn (Neg, ({ desc = CLit (Ast.LitInt n); _ } as x)) when n < 0L ->
      emit ctx "(-(";
      emit_expr ctx x;
      emit ctx "))"
  | CUn (Neg, x) ->
      emit ctx "(-";
      emit_expr ctx x;
      emit ctx ")"
  | CUn (Not, x) ->
      emit ctx "(!";
      emit_expr ctx x;
      emit ctx ")"
  | CLog (op, l, r) ->
      emit ctx "(";
      emit_expr ctx l;
      emit_logop ctx op;
      emit_expr ctx r;
      emit ctx ")"
  (* ---- Control flow (expression form) ---- *)
  | CIf (cond, then_e, else_e) ->
      (* Ternary for expression position. Complex cases (void body, etc.)
         use statement expressions in the existing codegen; we'll match
         that progressively. *)
      emit ctx "(";
      emit_expr ctx cond;
      emitln ctx " ?";
      ctx.indent <- ctx.indent + 1;
      emit_indent ctx;
      emit_expr ctx then_e;
      emitln ctx " :";
      emit_indent ctx;
      emit_expr ctx else_e;
      ctx.indent <- ctx.indent - 1;
      emit ctx ")"
  (* ---- Let-normal sequencing ---- *)
  | CLet (b, body) when is_void_ty b.bind_ty ->
      (* Void-typed binding: C has no [void x = ...] declarator, so
         sequence the rhs and discard the name. The body must not refer
         to the bound variable (type-checker enforces this). *)
      emit ctx "({ ";
      emit_expr ctx b.bind_rhs;
      emit ctx "; ";
      emit_expr ctx body;
      emit ctx "; })"
  | CBorrowLet (b, body) when is_void_ty b.borrow_ty ->
      emit ctx "({ ";
      emit_expr ctx b.borrow_rhs;
      emit ctx "; ";
      emit_expr ctx body;
      emit ctx "; })"
  | CLet (b, body) when b.bind_var.vname = "_" ->
      emit ctx "({ (void)(";
      emit_expr ctx b.bind_rhs;
      emit ctx "); ";
      emit_expr ctx body;
      emit ctx "; })"
  | CBorrowLet (b, body) when b.borrow_var.vname = "_" ->
      emit ctx "({ (void)(";
      emit_expr ctx b.borrow_rhs;
      emit ctx "); ";
      emit_expr ctx body;
      emit ctx "; })"
  | CLet (b, body) ->
      let rhs =
        expr_with_expected_type_for_constructors ctx b.bind_rhs b.bind_ty
      in
      let track_cleanup =
        cancellation_cleanup_tracks_binding ctx b.bind_var b.bind_ty body
      in
      emit ctx "({ ";
      emit ctx (type_to_c ctx b.bind_ty);
      emit ctx " ";
      emit ctx (escape_c_ident (Var.to_c_name b.bind_var));
      emit ctx " = ";
      (match normalize_type b.bind_ty with
      | Ast.TyFunc _ -> emit_boxed ctx rhs
      | _ -> emit_expr ctx rhs);
      emit ctx "; ";
      if track_cleanup then begin
        let var_c = escape_c_ident (Var.to_c_name b.bind_var) in
        let frame_c = cleanup_frame_c_name b.bind_var in
        let release_fn =
          match cancellation_cleanup_release_fn ctx b.bind_ty with
          | Some fn -> fn
          | None ->
              Core_error.errorf Core_error.Emit e.loc
                "missing cancellation cleanup release function for tracked \
                 binding"
        in
        emit ctx
          (Printf.sprintf
             "blorp_CancelCleanupFrame %s; blorp_task_cleanup_push(&%s, &%s, \
              (void*)%s, %s); "
             frame_c frame_c var_c var_c release_fn);
        if is_void_ty body.ty then begin
          emit_expr ctx body;
          emit ctx
            (Printf.sprintf "; %s; "
               (cancellation_cleanup_pop_slot_stmt b.bind_var))
        end
        else begin
          let result_tmp =
            Printf.sprintf "__cleanup_result_%d" (fresh_temp ctx)
          in
          emit ctx
            (Printf.sprintf "%s %s = " (type_to_c ctx body.ty) result_tmp);
          emit_expr ctx body;
          emit ctx
            (Printf.sprintf "; %s; %s"
               (cancellation_cleanup_pop_slot_stmt b.bind_var)
               result_tmp)
        end
      end
      else emit_expr ctx body;
      emit ctx "; })"
  | CBorrowLet (b, body) ->
      let rhs =
        expr_with_expected_type_for_constructors ctx b.borrow_rhs b.borrow_ty
      in
      emit ctx "({ ";
      emit ctx (type_to_c ctx b.borrow_ty);
      emit ctx " ";
      emit ctx (escape_c_ident (Var.to_c_name b.borrow_var));
      emit ctx " = ";
      (match normalize_type b.borrow_ty with
      | Ast.TyFunc _ -> emit_boxed ctx rhs
      | _ -> emit_expr ctx rhs);
      emit ctx "; ";
      emit_expr ctx body;
      emit ctx "; })"
  | CTensorRawViewLet (b, body) ->
      emit ctx "({ ";
      emit_tensor_raw_view_decl ctx b;
      emit ctx "; ";
      emit_expr ctx body;
      emit ctx "; })"
  | CSeq (a, b) ->
      (* Discard the first value's result; the sequence evaluates to b. *)
      emit ctx "({ ";
      emit_expr ctx a;
      emit ctx "; ";
      emit_expr ctx b;
      emit ctx "; })"
  (* ---- Call / field access ---- *)
  | CCall (CKBuiltin "blorp_list_to_string_cb", _, [ list_arg ]) ->
      let elem_ty =
        match normalize_type list_arg.ty with
        | TyNamed ("List", [ elem ]) -> elem
        | _ ->
            Core_error.errorf Core_error.Emit e.loc
              "blorp_list_to_string_cb on non-List type"
      in
      let elem_to_str =
        trait_method_c_name_for_type ctx ~loc:e.loc "Stringable" "to_string"
          elem_ty
      in
      emit ctx "blorp_list_to_string_cb(";
      emit_expr ctx list_arg;
      emit ctx
        (Printf.sprintf ", (blorp_String* (*)(void*))%s)"
           (escape_c_ident elem_to_str))
  | CCall (kind, _, _)
    when match kind with
         | CKBuiltin ("blorp_dict_new_custom" | "blorp_set_new_custom") -> true
         | _ -> false ->
      (* User-key Dict/Set construction. The specialize pass routes
         [Dict[UserType, V]] / [Set[UserType]] creation here; we emit
         the full call inline with function-pointer casts to the
         user's Hashable/Equatable impl names. Core IR doesn't have
         a "C function reference" expression type, so the argument
         synthesis happens here where C strings are the normal form.

         ABI note: the cast from the user's hash fn signature
         ("Hashable_hash_T" : T* => long) to the dict's internal
         (void* => unsigned long) relies on ABI-compatible layouts
         for pointer-arg + word-return — true on every platform
         blorp targets today. If CFI ever lands, this call site
         needs per-type wrapper functions instead. *)
      let fn_name, key_type =
        match kind with
        | CKBuiltin "blorp_dict_new_custom" ->
            let kty =
              match normalize_type e.ty with
              | TyNamed ("Dict", k :: _) -> k
              | _ ->
                  Core_error.errorf Core_error.Emit e.loc
                    "blorp_dict_new_custom on non-Dict type"
            in
            ("blorp_dict_new_custom", kty)
        | CKBuiltin "blorp_set_new_custom" ->
            let kty =
              match normalize_type e.ty with
              | TyNamed ("Set", [ elem ]) -> elem
              | _ ->
                  Core_error.errorf Core_error.Emit e.loc
                    "blorp_set_new_custom on non-Set type"
            in
            ("blorp_set_new_custom", kty)
        | _ -> assert false
      in
      (* A4.2: mangle the trait-method fn-ptrs to match their
         [__def_N_] decl. [ctx.trait_impl_def_ids] is populated by
         [emit_impl] as it walks each trait method. *)
      let trait_method_c_name trait method_name =
        trait_method_c_name_for_type ctx ~loc:e.loc trait method_name key_type
      in
      let key_release = boxed_value_release_arg ctx key_type e.loc in
      emit_dict_constructor_expr ctx e.ty e.loc (fun () ->
          emit ctx
            (Printf.sprintf
               "%s((unsigned long (*)(void*))%s, (bool (*)(void*, void*))%s, \
                %s)"
               fn_name
               (trait_method_c_name "Hashable" "hash")
               (trait_method_c_name "Equatable" "equals")
               key_release))
  | CCall (CKBuiltin "blorp_dict_with_capacity_custom", _, [ cap ]) ->
      let key_type =
        match normalize_type e.ty with
        | TyNamed ("Dict", k :: _) -> k
        | _ ->
            Core_error.errorf Core_error.Emit e.loc
              "blorp_dict_with_capacity_custom on non-Dict type"
      in
      let trait_method_c_name trait method_name =
        trait_method_c_name_for_type ctx ~loc:e.loc trait method_name key_type
      in
      let key_release = boxed_value_release_arg ctx key_type e.loc in
      emit_dict_constructor_expr ctx e.ty e.loc (fun () ->
          emit ctx "blorp_dict_with_capacity_custom(";
          emit_expr ctx cap;
          emit ctx
            (Printf.sprintf
               ", (unsigned long (*)(void*))%s, (bool (*)(void*, void*))%s, %s)"
               (trait_method_c_name "Hashable" "hash")
               (trait_method_c_name "Equatable" "equals")
               key_release))
  | CCall
      ( CKBuiltin
          (("blorp_dict_new" | "blorp_dict_new_string" | "blorp_dict_new_float")
           as ctor),
        _,
        [] ) ->
      emit_dict_constructor_expr ctx e.ty e.loc (fun () ->
          emit ctx (ctor ^ "()"))
  | CCall
      ( CKBuiltin
          (( "blorp_dict_with_capacity" | "blorp_dict_with_capacity_string"
           | "blorp_dict_with_capacity_float" ) as ctor),
        _,
        [ cap ] ) ->
      emit_dict_constructor_expr ctx e.ty e.loc (fun () ->
          emit ctx (ctor ^ "(");
          emit_expr ctx cap;
          emit ctx ")")
  | CCall (CKBuiltin "blorp_list_new", _, [ cap ]) ->
      let layout =
        Core_layout_type.list_storage_layout_of_type ~reg:ctx.reg e.ty e.loc
      in
      if list_element_needs_release ctx e.ty e.loc then begin
        let tmp = Printf.sprintf "__lst_%d" (fresh_temp ctx) in
        emit ctx (Printf.sprintf "({ blorp_List* %s = " tmp);
        emit_list_alloc_call ctx layout (fun () -> emit_expr ctx cap);
        emit ctx
          (Printf.sprintf
             "; blorp_list_init_elem_release(%s, blorp_elem_release_fn); %s; })"
             tmp tmp)
      end
      else emit_list_alloc_call ctx layout (fun () -> emit_expr ctx cap)
  | CCall (CKBuiltin "blorp_channel_new", _, [ cap ])
    when channel_element_needs_release ctx e.ty e.loc ->
      let tmp = Printf.sprintf "__ch_%d" (fresh_temp ctx) in
      emit ctx (Printf.sprintf "({ blorp_Channel* %s = blorp_channel_new(" tmp);
      emit_expr ctx cap;
      emit ctx
        (Printf.sprintf
           "); blorp_channel_init_elem_release(%s, blorp_elem_release_fn); %s; \
            })"
           tmp tmp)
  | CCall
      ( CKBuiltin
          ("blorp_tensor3_new" | "blorp_tensor4_new" | "blorp_tensor5_new"),
        _,
        value :: dims )
    when tensor_fill_factory_uses_direct_layout ctx e.ty e.loc ->
      emit_tensor_fill_factory ctx e.loc e.ty value dims
  | CCall
      ( CKBuiltin
          (( "blorp_vector_new_fill" | "blorp_matrix_new_fill"
           | "blorp_tensor3_new" | "blorp_tensor4_new" | "blorp_tensor5_new" )
           as ctor),
        _,
        value :: dims )
    when Option.is_some (tensor_inline_struct_c_type ctx e.ty) ->
      let c_ty =
        match tensor_inline_struct_c_type ctx e.ty with
        | Some c_ty -> c_ty
        | None -> assert false
      in
      let value =
        match value.desc with
        | CBoxTyped b -> b.box_value
        | CBox (inner, _) -> inner
        | _ -> value
      in
      let fill_tmp = Printf.sprintf "__fill_%d" (fresh_temp ctx) in
      emit ctx (Printf.sprintf "({ %s %s = " c_ty fill_tmp);
      emit_expr ctx value;
      emit ctx (Printf.sprintf "; %s_sized(&%s" ctor fill_tmp);
      List.iter
        (fun dim ->
          emit ctx ", ";
          emit_expr ctx dim)
        dims;
      emit ctx (Printf.sprintf ", sizeof(%s)); })" c_ty)
  | CCall
      ( CKBuiltin
          (( "blorp_vector_new_fill" | "blorp_matrix_new_fill"
           | "blorp_tensor3_new" | "blorp_tensor4_new" | "blorp_tensor5_new" )
           as ctor),
        _,
        value :: dims )
    when tensor_element_needs_release ctx e.ty e.loc ->
      let value_tmp = Printf.sprintf "__fill_%d" (fresh_temp ctx) in
      let vector_tmp = Printf.sprintf "__vec_%d" (fresh_temp ctx) in
      emit ctx (Printf.sprintf "({ void* %s = " value_tmp);
      emit_boxed ctx value;
      emit ctx
        (Printf.sprintf "; blorp_Vector* %s = %s(%s" vector_tmp ctor value_tmp);
      List.iter
        (fun dim ->
          emit ctx ", ";
          emit_expr ctx dim)
        dims;
      emit ctx
        (Printf.sprintf
           "); blorp_vector_set_elem_release(%s, blorp_elem_release_fn);"
           vector_tmp);
      if boxed_expr_transfers_ownership ctx value then
        emit ctx
          (Printf.sprintf " if (%s) blorp_release(%s);" value_tmp value_tmp);
      emit ctx (Printf.sprintf " %s; })" vector_tmp)
  | CCall
      ( CKBuiltin
          (( "blorp_vector_set_cow" | "blorp_checked_set"
           | "blorp_vector_set_cow_nullable" | "blorp_vector_set_inplace"
           | "blorp_matrix_checked_set" | "blorp_matrix_set_opt"
           | "blorp_matrix_set_opt_nullable" | "blorp_tensor3_checked_set"
           | "blorp_tensor4_checked_set" | "blorp_tensor5_checked_set" ) as
           setter),
        _,
        args )
    when tensor_arg_element_needs_release ctx args e.loc -> (
      match List.rev args with
      | value :: rev_prefix when boxed_expr_transfers_ownership ctx value ->
          let prefix = List.rev rev_prefix in
          let value_tmp = Printf.sprintf "__set_value_%d" (fresh_temp ctx) in
          let result_tmp = Printf.sprintf "__set_result_%d" (fresh_temp ctx) in
          emit ctx (Printf.sprintf "({ void* %s = " value_tmp);
          emit_boxed ctx value;
          emit ctx
            (Printf.sprintf "; %s %s = %s(" (type_to_c ctx e.ty) result_tmp
               setter);
          List.iteri
            (fun i arg ->
              if i > 0 then emit ctx ", ";
              emit_expr ctx arg)
            prefix;
          if prefix <> [] then emit ctx ", ";
          emit ctx value_tmp;
          emit ctx
            (Printf.sprintf "); if (%s) blorp_release(%s); %s; })" value_tmp
               value_tmp result_tmp)
      | _ ->
          emit ctx (setter ^ "(");
          List.iteri
            (fun i arg ->
              if i > 0 then emit ctx ", ";
              emit_expr ctx arg)
            args;
          emit ctx ")")
  | CCall (kind, callee, args) -> (
      match (kind, args) with
      | CKBuiltin "__blorp_option_eq_layout", [ l; r ] ->
          emit_option_equality ctx e l r
      | _ -> (
          (* Dispatch on [call_kind]. For the supported subset today all
         kinds emit [name(args)] — the hook exists so Phase 1.2c can
         refine per kind (e.g. boxing rules, env-pointer passing,
         closure indirection) without expanding the emitter beyond
         one top-level match. *)
          let try_emit_stack_option_ctor () =
            let callee_is_registered_constructor ctor_name =
              match callee.desc with
              | CVar v -> Hashtbl.mem ctx.constructor_names v.vname
              | CField (_, field) -> Hashtbl.mem ctx.constructor_names field
              | _ -> Hashtbl.mem ctx.constructor_names ctor_name
            in
            let emit_some c_ty arg =
              if is_void_ty arg.ty then begin
                emit ctx "({ ";
                emit_stmt ctx arg;
                emit ctx
                  (Printf.sprintf
                     "((%s){ .tag = BLORP_TAG_SOME, .value = 0 }); })" c_ty)
              end
              else begin
                emit ctx
                  (Printf.sprintf "((%s){ .tag = BLORP_TAG_SOME, .value = " c_ty);
                emit_expr ctx arg;
                emit ctx " })"
              end
            in
            match
              ( kind,
                Core_layout_type.stack_option_c_type ~reg:ctx.reg e.ty,
                args )
            with
            | CKBuiltin "blorp_option_some", Some c_ty, [ arg ] ->
                emit_some c_ty arg;
                true
            | CKUser ("Some", _), Some c_ty, [ arg ]
              when callee_is_registered_constructor "Some" ->
                emit_some c_ty arg;
                true
            | CKBuiltin "blorp_option_none", Some c_ty, [] ->
                emit ctx
                  (Printf.sprintf "((%s){ .tag = BLORP_TAG_NONE, .value = %s })"
                     c_ty
                     (Core_layout_type.stack_option_none_value_for_type
                        ~reg:ctx.reg e.ty));
                true
            | _ -> false
          in
          let try_emit_stack_result_ctor () =
            let callee_is_registered_constructor ctor_name =
              match callee.desc with
              | CVar v -> Hashtbl.mem ctx.constructor_names v.vname
              | CField (_, field) -> Hashtbl.mem ctx.constructor_names field
              | _ -> Hashtbl.mem ctx.constructor_names ctor_name
            in
            let emit_stack_result_ctor c_ty tag field arg =
              let release_mask =
                if boxed_value_needs_release ctx arg.ty arg.loc then 1 else 0
              in
              let box =
                {
                  box_value = arg;
                  box_source_ty = arg.ty;
                  box_kind = classify_for_boxing ctx arg.ty arg.loc;
                }
              in
              emit ctx
                (Printf.sprintf
                   "((%s){ .tag = %s, .release_mask = %dUL, .data.%s.field0 = "
                   c_ty tag release_mask field);
              emit_box_op ctx box;
              emit ctx " })"
            in
            match
              ( kind,
                Core_layout_type.stack_result_c_type ~reg:ctx.reg e.ty,
                args )
            with
            | CKBuiltin "blorp_result_ok", Some c_ty, [ arg ] ->
                emit_stack_result_ctor c_ty "BLORP_TAG_OK" "Ok" arg;
                true
            | CKBuiltin "blorp_result_err", Some c_ty, [ arg ] ->
                emit_stack_result_ctor c_ty "BLORP_TAG_ERR" "Err" arg;
                true
            | CKUser ("Ok", _), Some c_ty, [ arg ]
              when callee_is_registered_constructor "Ok" ->
                emit_stack_result_ctor c_ty "BLORP_TAG_OK" "Ok" arg;
                true
            | CKUser ("Err", _), Some c_ty, [ arg ]
              when callee_is_registered_constructor "Err" ->
                emit_stack_result_ctor c_ty "BLORP_TAG_ERR" "Err" arg;
                true
            | _ -> false
          in
          let try_emit_nullable_managed_option_ctor () =
            let callee_is_registered_constructor ctor_name =
              match callee.desc with
              | CVar v -> Hashtbl.mem ctx.constructor_names v.vname
              | CField (_, field) -> Hashtbl.mem ctx.constructor_names field
              | _ -> Hashtbl.mem ctx.constructor_names ctor_name
            in
            let emit_payload arg =
              match normalize_type arg.ty with
              | Ast.TyFunc _ -> emit_boxed ctx arg
              | _ -> emit_expr ctx arg
            in
            match
              (kind, nullable_managed_option_payload_type ctx e.ty, args)
            with
            | CKBuiltin "blorp_option_some", Some _, [ arg ] ->
                emit_payload arg;
                true
            | CKUser ("Some", _), Some _, [ arg ]
              when callee_is_registered_constructor "Some" ->
                emit_payload arg;
                true
            | CKBuiltin "blorp_option_none", Some _, [] ->
                emit ctx "NULL";
                true
            | _ -> false
          in
          let try_emit_typed_option_result_ctor () =
            match (kind, normalize_type e.ty, args) with
            | CKBuiltin "blorp_option_some", Ast.TyNamed ("Option", _), [ arg ]
              ->
                Some ("Option", "Some", arg)
            | CKBuiltin "blorp_result_ok", Ast.TyNamed ("Result", _), [ arg ] ->
                Some ("Result", "Ok", arg)
            | CKBuiltin "blorp_result_err", Ast.TyNamed ("Result", _), [ arg ]
              ->
                Some ("Result", "Err", arg)
            | _ -> None
          in
          let try_emit_generated_stack_option_get () =
            match
              ( kind,
                args,
                Core_layout_type.generated_stack_option_get_abi ~reg:ctx.reg
                  e.ty )
            with
            | CKBuiltin "blorp_vector_get_opt", [ arr; idx ], Some abi ->
                emit_generated_stack_option_vector_get ctx abi arr idx;
                true
            | CKBuiltin "blorp_matrix_get_opt", [ arr; row; col ], Some abi ->
                emit_generated_stack_option_matrix_get ctx abi arr row col;
                true
            | CKBuiltin "blorp_dict_get", [ dict; key ], Some abi ->
                emit_generated_stack_option_dict_get ctx abi dict key;
                true
            | _ -> false
          in
          if try_emit_stack_option_ctor () then ()
          else if try_emit_stack_result_ctor () then ()
          else if try_emit_generated_stack_option_get () then ()
          else if try_emit_nullable_managed_option_ctor () then ()
          else
            match try_emit_typed_option_result_ctor () with
            | Some (type_name, ctor_name, arg) ->
                let ctor_c =
                  match
                    Hashtbl.find_opt ctx.constructor_c_names_by_type
                      (type_name, ctor_name)
                  with
                  | Some name -> name
                  | None ->
                      Core_error.errorf Core_error.Emit e.loc
                        ~hint:
                          "Option/Result ?= lowering must emit typed union \
                           constructors so managed payloads carry a release \
                           mask."
                        "missing typed constructor `%s.%s` during C emission"
                        type_name ctor_name
                in
                emit ctx ctor_c;
                emit ctx "(";
                emit_boxed ctx arg;
                emit ctx
                  (Printf.sprintf ", %dUL)"
                     (if boxed_expr_needs_constructor_release ctx arg then 1
                      else 0))
            | None ->
                let builtin_return_cast =
                  match kind with
                  | CKBuiltin _ when is_pointer_type ctx e.ty ->
                      Some (type_to_c ctx e.ty)
                  | _ -> None
                in
                let boxed_result_return_cast =
                  match kind with
                  | CKBuiltin _ | CKForeign _ ->
                      Core_layout_type.is_stack_result_type ~reg:ctx.reg e.ty
                  | _ -> false
                in
                let file_io_error_type_name err_ty =
                  match normalize_type (expand_alias ~reg:ctx.reg err_ty) with
                  | Ast.TyNamed (name, [])
                    when name = "IOError" || name = "std_file__IOError"
                         ||
                         match Types.split_canonical_module_type_name name with
                         | Some (module_path, type_name) ->
                             module_path = "std/file" && type_name = "IOError"
                         | None -> false ->
                      name
                  | Ast.TyNamed (name, []) ->
                      Core_error.errorf Core_error.Emit e.loc
                        ~hint:
                          "typed file operations currently use the std/file \
                           IOError bridge; add a separate bridge before using \
                           another fallible stream error type"
                        "typed file operation error payload must be IOError, \
                         got `%s`"
                        name
                  | other ->
                      Core_error.errorf Core_error.Emit e.loc
                        ~hint:
                          "typed file operations must return Result[..., \
                           IOError]"
                        "typed file operation error payload has unsupported \
                         type `%s`"
                        (Types.type_to_string other)
                in
                let file_io_error_ctor err_name ctor_name =
                  match
                    Hashtbl.find_opt ctx.constructor_c_names_by_type
                      (err_name, ctor_name)
                  with
                  | Some ctor_c -> ctor_c
                  | None ->
                      Core_error.errorf Core_error.Emit e.loc
                        ~hint:
                          "std/file IOError constructors must be visible to \
                           the C emitter before typed file operation emission"
                        "missing typed file error constructor `%s.%s`" err_name
                        ctor_name
                in
                let emit_file_io_error_case state_tmp err_tmp err_name
                    runtime_tag ctor_name =
                  emit ctx (Printf.sprintf "case %s: " runtime_tag);
                  emit ctx
                    (Printf.sprintf
                       "%s = %s((void*)%s.detail, %s.detail ? 1UL : 0UL); \
                        break; "
                       err_tmp
                       (file_io_error_ctor err_name ctor_name)
                       state_tmp state_tmp)
                in
                let emit_file_io_error_switch_cases state_tmp err_tmp err_name =
                  List.iter
                    (fun (runtime_tag, ctor_name) ->
                      emit_file_io_error_case state_tmp err_tmp err_name
                        runtime_tag ctor_name)
                    [
                      ("BLORP_FILE_ERROR_NOT_FOUND", "NotFound");
                      ("BLORP_FILE_ERROR_PERMISSION_DENIED", "PermissionDenied");
                      ("BLORP_FILE_ERROR_ALREADY_EXISTS", "AlreadyExists");
                      ("BLORP_FILE_ERROR_INVALID_INPUT", "InvalidInput");
                      ("BLORP_FILE_ERROR_INTERRUPTED", "Interrupted");
                      ("BLORP_FILE_ERROR_TIMED_OUT", "TimedOut");
                      ("BLORP_FILE_ERROR_UNSUPPORTED", "Unsupported");
                      ("BLORP_FILE_ERROR_OTHER", "Other");
                    ]
                in
                let try_emit_file_open_bridge () =
                  let file_open_spec = function
                    | CKBuiltin "blorp_file_open_read_raw" ->
                        Some
                          ( "blorp_file_open_read_raw",
                            "blorp_FileOpenReaderResult",
                            [
                              "FileReader";
                              "std/file::FileReader";
                              "std_file__FileReader";
                            ] )
                    | CKBuiltin "blorp_file_open_write_raw" ->
                        Some
                          ( "blorp_file_open_write_raw",
                            "blorp_FileOpenWriterResult",
                            [
                              "FileWriter";
                              "std/file::FileWriter";
                              "std_file__FileWriter";
                            ] )
                    | CKBuiltin "blorp_file_open_append_raw" ->
                        Some
                          ( "blorp_file_open_append_raw",
                            "blorp_FileOpenWriterResult",
                            [
                              "FileWriter";
                              "std/file::FileWriter";
                              "std_file__FileWriter";
                            ] )
                    | CKBuiltin "blorp_file_open_read_write_raw" ->
                        Some
                          ( "blorp_file_open_read_write_raw",
                            "blorp_FileOpenResult",
                            [ "File"; "std/file::File"; "std_file__File" ] )
                    | _ -> None
                  in
                  let is_file_resource_ty expected ty =
                    match normalize_type (expand_alias ~reg:ctx.reg ty) with
                    | Ast.TyNamed (name, []) -> List.mem name expected
                    | _ -> false
                  in
                  match
                    ( file_open_spec kind,
                      args,
                      normalize_type (expand_alias ~reg:ctx.reg e.ty) )
                  with
                  | ( Some (open_c_name, open_result_c, expected_ok_names),
                      [ path_arg ],
                      Ast.TyNamed ("Result", [ ok_ty; err_ty ]) )
                    when is_file_resource_ty expected_ok_names ok_ty ->
                      if
                        Core_layout_type.stack_result_c_type ~reg:ctx.reg e.ty
                        <> None
                      then
                        Core_error.errorf Core_error.Emit e.loc
                          ~hint:
                            "update the file-open bridge before classifying \
                             file resources as stack Result payloads"
                          "typed file open bridge currently emits the boxed \
                           Result ABI";
                      let err_name = file_io_error_type_name err_ty in
                      let result_c = type_to_c ctx e.ty in
                      let err_c = type_to_c ctx err_ty in
                      let path_tmp =
                        Printf.sprintf "__file_path_%d" (fresh_temp ctx)
                      in
                      let open_tmp =
                        Printf.sprintf "__file_open_%d" (fresh_temp ctx)
                      in
                      let result_tmp =
                        Printf.sprintf "__file_result_%d" (fresh_temp ctx)
                      in
                      let err_tmp =
                        Printf.sprintf "__file_error_%d" (fresh_temp ctx)
                      in
                      emit ctx
                        (Printf.sprintf "({ blorp_String* %s = " path_tmp);
                      emit_expr ctx path_arg;
                      emit ctx
                        (Printf.sprintf
                           "; %s %s = %s(%s); %s %s = NULL; if (%s.error_kind \
                            == BLORP_FILE_ERROR_NONE) { %s = \
                            (%s)blorp_result_ok((void*)%s.handle); } else { %s \
                            %s = NULL; switch (%s.error_kind) { "
                           open_result_c open_tmp open_c_name path_tmp result_c
                           result_tmp open_tmp result_tmp result_c open_tmp
                           err_c err_tmp open_tmp);
                      emit_file_io_error_switch_cases open_tmp err_tmp err_name;
                      emit ctx
                        (Printf.sprintf
                           "default: %s = %s((void*)%s.detail, %s.detail ? 1UL \
                            : 0UL); break; } %s = \
                            (%s)blorp_result_err((void*)%s); \
                            ((blorp_Result*)%s)->release_mask = 1UL; } %s; })"
                           err_tmp
                           (file_io_error_ctor err_name "Other")
                           open_tmp open_tmp result_tmp result_c err_tmp
                           result_tmp result_tmp);
                      true
                  | _ -> false
                in
                let try_emit_file_operation_bridge () =
                  let file_operation_spec = function
                    | CKBuiltin "blorp_file_read_text_reader_raw" ->
                        Some
                          ( "blorp_file_read_text_reader_raw",
                            "blorp_FileStringResult",
                            `String )
                    | CKBuiltin "blorp_file_read_text_file_raw" ->
                        Some
                          ( "blorp_file_read_text_file_raw",
                            "blorp_FileStringResult",
                            `String )
                    | CKBuiltin "blorp_file_read_bytes_reader_raw" ->
                        Some
                          ( "blorp_file_read_bytes_reader_raw",
                            "blorp_FileBytesResult",
                            `Bytes )
                    | CKBuiltin "blorp_file_read_bytes_file_raw" ->
                        Some
                          ( "blorp_file_read_bytes_file_raw",
                            "blorp_FileBytesResult",
                            `Bytes )
                    | CKBuiltin "blorp_file_read_chunk_reader_raw" ->
                        Some
                          ( "blorp_file_read_chunk_reader_raw",
                            "blorp_FileBytesResult",
                            `Bytes )
                    | CKBuiltin "blorp_file_read_chunk_file_raw" ->
                        Some
                          ( "blorp_file_read_chunk_file_raw",
                            "blorp_FileBytesResult",
                            `Bytes )
                    | CKBuiltin "blorp_fallible_stream_collect_file_raw" ->
                        Some
                          ( "blorp_fallible_stream_collect_file_raw",
                            "blorp_FileListResult",
                            `List )
                    | CKBuiltin "blorp_fallible_stream_fold_file_raw" ->
                        Some
                          ( "blorp_fallible_stream_fold_file_raw",
                            "blorp_FileValueResult",
                            `Erased )
                    | CKBuiltin "blorp_fallible_stream_count_file_raw" ->
                        Some
                          ( "blorp_fallible_stream_count_file_raw",
                            "blorp_FileIntResult",
                            `Int )
                    | CKBuiltin
                        (( "blorp_fallible_stream_find_file_raw_nullable"
                         | "blorp_fallible_stream_find_file_raw_int"
                         | "blorp_fallible_stream_find_file_raw_int8"
                         | "blorp_fallible_stream_find_file_raw_int16"
                         | "blorp_fallible_stream_find_file_raw_int32"
                         | "blorp_fallible_stream_find_file_raw_int64"
                         | "blorp_fallible_stream_find_file_raw_uint8"
                         | "blorp_fallible_stream_find_file_raw_uint16"
                         | "blorp_fallible_stream_find_file_raw_uint32"
                         | "blorp_fallible_stream_find_file_raw_uint64"
                         | "blorp_fallible_stream_find_file_raw_float"
                         | "blorp_fallible_stream_find_file_raw_bool"
                         | "blorp_fallible_stream_find_file_raw_char"
                         | "blorp_fallible_stream_find_file_raw_f32"
                         | "blorp_fallible_stream_find_file_raw_f16" ) as c_name)
                      ->
                        Some (c_name, "blorp_FileValueResult", `Option)
                    | CKBuiltin "blorp_fallible_stream_any_file_raw" ->
                        Some
                          ( "blorp_fallible_stream_any_file_raw",
                            "blorp_FileBoolResult",
                            `Bool )
                    | CKBuiltin "blorp_fallible_stream_all_file_raw" ->
                        Some
                          ( "blorp_fallible_stream_all_file_raw",
                            "blorp_FileBoolResult",
                            `Bool )
                    | CKBuiltin "blorp_file_write_text_writer_raw" ->
                        Some
                          ( "blorp_file_write_text_writer_raw",
                            "blorp_FileVoidResult",
                            `Void )
                    | CKBuiltin "blorp_file_write_text_file_raw" ->
                        Some
                          ( "blorp_file_write_text_file_raw",
                            "blorp_FileVoidResult",
                            `Void )
                    | CKBuiltin "blorp_file_write_bytes_writer_raw" ->
                        Some
                          ( "blorp_file_write_bytes_writer_raw",
                            "blorp_FileVoidResult",
                            `Void )
                    | CKBuiltin "blorp_file_write_bytes_file_raw" ->
                        Some
                          ( "blorp_file_write_bytes_file_raw",
                            "blorp_FileVoidResult",
                            `Void )
                    | CKBuiltin "blorp_file_write_chunk_writer_raw" ->
                        Some
                          ( "blorp_file_write_chunk_writer_raw",
                            "blorp_FileIntResult",
                            `Int )
                    | CKBuiltin "blorp_file_write_chunk_file_raw" ->
                        Some
                          ( "blorp_file_write_chunk_file_raw",
                            "blorp_FileIntResult",
                            `Int )
                    | CKBuiltin "blorp_file_count_lines_reader_raw" ->
                        Some
                          ( "blorp_file_count_lines_reader_raw",
                            "blorp_FileIntResult",
                            `Int )
                    | CKBuiltin "blorp_file_count_lines_file_raw" ->
                        Some
                          ( "blorp_file_count_lines_file_raw",
                            "blorp_FileIntResult",
                            `Int )
                    | _ -> None
                  in
                  let ok_payload_matches payload ok_ty =
                    match
                      (payload, normalize_type (expand_alias ~reg:ctx.reg ok_ty))
                    with
                    | `String, Ast.TyNamed ("String", []) -> true
                    | `Bytes, Ast.TyNamed ("Bytes", []) -> true
                    | `List, Ast.TyNamed ("List", _) -> true
                    | `Int, Ast.TyNamed ("Int", []) -> true
                    | `Bool, Ast.TyNamed ("Bool", []) -> true
                    | `Void, Ast.TyNamed ("Void", []) -> true
                    | `Option, Ast.TyNamed ("Option", [ _ ]) -> true
                    | `Erased, _ -> true
                    | _ -> false
                  in
                  let ok_payload_release_mask payload ok_ty =
                    match payload with
                    | `String | `Bytes | `List -> 1
                    | `Erased | `Option ->
                        if boxed_value_needs_release ctx ok_ty e.loc then 1
                        else 0
                    | `Int | `Bool | `Void -> 0
                  in
                  let emit_ok_payload op_tmp payload =
                    match payload with
                    | `String | `Bytes | `List ->
                        emit ctx (Printf.sprintf "(void*)%s.value" op_tmp)
                    | `Int | `Bool | `Erased | `Option ->
                        emit ctx (Printf.sprintf "(void*)%s.value" op_tmp)
                    | `Void -> emit ctx "NULL"
                  in
                  let emit_arg_list args =
                    List.iteri
                      (fun i arg ->
                        if i > 0 then emit ctx ", ";
                        emit_expr ctx arg)
                      args
                  in
                  let emit_file_operation_args payload ok_ty args =
                    emit_arg_list args;
                    match payload with
                    | `List ->
                        let layout =
                          Core_layout_type.list_storage_layout_of_type
                            ~reg:ctx.reg ok_ty e.loc
                        in
                        let storage_mode, elem_size =
                          list_storage_runtime_args layout
                        in
                        emit ctx
                          (Printf.sprintf ", %s, %s" storage_mode elem_size)
                    | `String | `Bytes | `Int | `Bool | `Void | `Option
                    | `Erased ->
                        ()
                  in
                  match
                    ( file_operation_spec kind,
                      normalize_type (expand_alias ~reg:ctx.reg e.ty) )
                  with
                  | ( Some (op_c_name, op_result_c, payload),
                      Ast.TyNamed ("Result", [ ok_ty; err_ty ]) )
                    when ok_payload_matches payload ok_ty ->
                      let err_name = file_io_error_type_name err_ty in
                      let result_c = type_to_c ctx e.ty in
                      let err_c = type_to_c ctx err_ty in
                      let op_tmp =
                        Printf.sprintf "__file_op_%d" (fresh_temp ctx)
                      in
                      let result_tmp =
                        Printf.sprintf "__file_result_%d" (fresh_temp ctx)
                      in
                      let err_tmp =
                        Printf.sprintf "__file_error_%d" (fresh_temp ctx)
                      in
                      let stack_result =
                        Core_layout_type.stack_result_c_type ~reg:ctx.reg e.ty
                        <> None
                      in
                      emit ctx
                        (Printf.sprintf "({ %s %s = %s(" op_result_c op_tmp
                           op_c_name);
                      emit_file_operation_args payload ok_ty args;
                      emit ctx "); ";
                      if stack_result then (
                        emit ctx
                          (Printf.sprintf
                             "%s %s; if (%s.error_kind == \
                              BLORP_FILE_ERROR_NONE) { %s = ((%s){ .tag = \
                              BLORP_TAG_OK, .release_mask = %dUL, \
                              .data.Ok.field0 = "
                             result_c result_tmp op_tmp result_tmp result_c
                             (ok_payload_release_mask payload ok_ty));
                        emit_ok_payload op_tmp payload;
                        emit ctx
                          (Printf.sprintf
                             " }); } else { %s %s = NULL; switch \
                              (%s.error_kind) { "
                             err_c err_tmp op_tmp);
                        emit_file_io_error_switch_cases op_tmp err_tmp err_name;
                        emit ctx
                          (Printf.sprintf
                             "default: %s = %s((void*)%s.detail, %s.detail ? \
                              1UL : 0UL); break; } %s = ((%s){ .tag = \
                              BLORP_TAG_ERR, .release_mask = 1UL, \
                              .data.Err.field0 = (void*)%s }); } %s; })"
                             err_tmp
                             (file_io_error_ctor err_name "Other")
                             op_tmp op_tmp result_tmp result_c err_tmp
                             result_tmp))
                      else (
                        emit ctx
                          (Printf.sprintf
                             "%s %s = NULL; if (%s.error_kind == \
                              BLORP_FILE_ERROR_NONE) { %s = \
                              (%s)blorp_result_ok("
                             result_c result_tmp op_tmp result_tmp result_c);
                        emit_ok_payload op_tmp payload;
                        let ok_release_mask =
                          ok_payload_release_mask payload ok_ty
                        in
                        emit ctx
                          (if ok_release_mask = 1 then
                             Printf.sprintf
                               "); ((blorp_Result*)%s)->release_mask = 1UL; } \
                                else { %s %s = NULL; switch (%s.error_kind) { "
                               result_tmp err_c err_tmp op_tmp
                           else
                             Printf.sprintf
                               "); } else { %s %s = NULL; switch \
                                (%s.error_kind) { "
                               err_c err_tmp op_tmp);
                        emit_file_io_error_switch_cases op_tmp err_tmp err_name;
                        emit ctx
                          (Printf.sprintf
                             "default: %s = %s((void*)%s.detail, %s.detail ? \
                              1UL : 0UL); break; } %s = \
                              (%s)blorp_result_err((void*)%s); \
                              ((blorp_Result*)%s)->release_mask = 1UL; } %s; \
                              })"
                             err_tmp
                             (file_io_error_ctor err_name "Other")
                             op_tmp op_tmp result_tmp result_c err_tmp
                             result_tmp result_tmp));
                      true
                  | _ -> false
                in
                let try_emit_foreign_copy_call () =
                  match kind with
                  | CKForeign
                      {
                        fc_c_name;
                        fc_arg_passing = ForeignDefaultArgs policies;
                      } ->
                      if List.length policies <> List.length args then
                        Core_error.errorf Core_error.Emit e.loc
                          ~hint:
                            "Core_ffi_boundary must attach exactly one default \
                             FFI policy for each foreign function parameter \
                             before call resolution"
                          "foreign call to '%s' has %d argument(s) but %d \
                           boundary polic%s"
                          fc_c_name (List.length args) (List.length policies)
                          (if List.length policies = 1 then "y" else "ies");
                      let copy_args =
                        List.mapi
                          (fun i policy ->
                            match policy with
                            | ForeignDefensiveCopy copy_kind ->
                                let copy_spec =
                                  Core_ffi_boundary.copy_spec_for_core_kind
                                    copy_kind
                                in
                                Some
                                  ( i,
                                    copy_kind,
                                    copy_spec.c_type,
                                    copy_spec.copy_fn,
                                    Printf.sprintf "%s%d" copy_spec.temp_prefix
                                      (fresh_temp ctx) )
                            | ForeignScalarByValue -> None)
                          policies
                        |> List.filter_map (fun x -> x)
                      in
                      if copy_args = [] then false
                      else
                        let copy_name_for_arg i =
                          List.find_map
                            (fun (j, copy_kind, _c_ty, _copy_fn, copy_name) ->
                              if i = j then Some (copy_kind, copy_name)
                              else None)
                            copy_args
                        in
                        let is_void = is_void_ty e.ty in
                        let result_tmp =
                          if is_void then None
                          else
                            Some
                              (Printf.sprintf "__ffi_result_%d" (fresh_temp ctx))
                        in
                        emit ctx "({ ";
                        List.iter
                          (fun (i, _copy_kind, c_ty, copy_fn, copy_name) ->
                            let arg = List.nth args i in
                            emit ctx
                              (Printf.sprintf "%s %s = %s(" c_ty copy_name
                                 copy_fn);
                            emit_expr ctx arg;
                            emit ctx "); ")
                          copy_args;
                        (match result_tmp with
                        | Some tmp ->
                            emit ctx
                              (Printf.sprintf "%s %s = " (type_to_c ctx e.ty)
                                 tmp)
                        | None -> ());
                        if boxed_result_return_cast then
                          emit ctx
                            "blorp_stack_result_from_boxed((blorp_Result*)";
                        emit ctx fc_c_name;
                        emit ctx "(";
                        List.iteri
                          (fun i arg ->
                            if i > 0 then emit ctx ", ";
                            match copy_name_for_arg i with
                            | Some (ForeignStringCopy, copy_name) ->
                                emit ctx
                                  (Printf.sprintf "(const char*)((%s)->data)"
                                     copy_name)
                            | Some (ForeignBytesCopy, copy_name) ->
                                emit ctx copy_name
                            | None -> emit_expr ctx arg)
                          args;
                        emit ctx ")";
                        if boxed_result_return_cast then emit ctx ")";
                        emit ctx "; ";
                        List.iter
                          (fun (_, _copy_kind, _c_ty, _copy_fn, copy_name) ->
                            emit ctx
                              (Printf.sprintf "blorp_release(%s); " copy_name))
                          copy_args;
                        (match result_tmp with
                        | Some tmp -> emit ctx (Printf.sprintf "%s; " tmp)
                        | None -> ());
                        emit ctx "})";
                        true
                  | _ -> false
                in
                if try_emit_file_open_bridge () then ()
                else if try_emit_file_operation_bridge () then ()
                else if try_emit_foreign_copy_call () then ()
                else begin
                  (match kind with
                  | CKUnknown | CKSelectedDirect _ ->
                      let callee_name =
                        match callee.desc with
                        | CVar v -> v.vname
                        | CField (_, field) -> field
                        | _ -> "<expression>"
                      in
                      Core_error.errorf Core_error.Emit e.loc
                        ~hint:
                          "Core_specialize must rewrite every CKUnknown left \
                           by Core_resolve. Run with --check-invariants to \
                           catch the leak at the specialize/final boundary."
                        "CCall with unresolved call target reached C emission \
                         for `%s`"
                        callee_name
                  | CKUser (resolved_name, def_id) ->
                      emit ctx
                        (escape_c_ident (user_call_c_name resolved_name def_id));
                      emit ctx "("
                  | CKForeign { fc_c_name; _ } ->
                      if boxed_result_return_cast then
                        emit ctx
                          (Printf.sprintf
                             "blorp_stack_result_from_boxed((blorp_Result*)%s("
                             fc_c_name)
                      else begin
                        emit ctx fc_c_name;
                        emit ctx "("
                      end
                  | CKBuiltin c_name -> (
                      match (boxed_result_return_cast, builtin_return_cast) with
                      | true, _ ->
                          emit ctx
                            (Printf.sprintf
                               "blorp_stack_result_from_boxed((blorp_Result*)%s("
                               c_name)
                      | false, Some c_ty ->
                          emit ctx (Printf.sprintf "((%s)%s(" c_ty c_name)
                      | false, None ->
                          emit ctx c_name;
                          emit ctx "(")
                  | CKIntrinsic name -> emit_intrinsic ctx e name args
                  | CKClosure ->
                      let cl_tmp = Printf.sprintf "__cl_%d" (fresh_temp ctx) in
                      let nargs = List.length args in
                      let arg_types =
                        String.concat ", "
                          ("void*" :: List.init nargs (fun _ -> "void*"))
                      in
                      let boxed_abi_temp_needs_release = function
                        | BoxInt128 | BoxUInt128 | BoxStruct _ -> true
                        | BoxFloat | BoxFloat32 | BoxFloat16 | BoxVoid
                        | BoxPointer | BoxPrim ->
                            false
                      in
                      let emit_arg_bindings () =
                        List.map
                          (fun arg ->
                            let arg_tmp =
                              Printf.sprintf "__cl_arg_%d" (fresh_temp ctx)
                            in
                            let box_kind =
                              classify_for_boxing ctx arg.ty arg.loc
                            in
                            emit ctx (Printf.sprintf "; void* %s = " arg_tmp);
                            emit_boxed ctx arg;
                            (arg_tmp, boxed_abi_temp_needs_release box_kind))
                          args
                      in
                      let emit_call_args arg_bindings =
                        List.iter
                          (fun (arg_tmp, _) ->
                            emit ctx ", ";
                            emit ctx arg_tmp)
                          arg_bindings
                      in
                      let emit_arg_releases arg_bindings =
                        List.iter
                          (fun (arg_tmp, needs_release) ->
                            if needs_release then
                              emit ctx
                                (Printf.sprintf "; blorp_release(%s)" arg_tmp))
                          arg_bindings
                      in
                      let emit_unboxed_return tmp_r box_kind =
                        let ret_c_ty = type_to_c ctx e.ty in
                        let emit_owned_unbox unbox_expr =
                          let value_tmp =
                            Printf.sprintf "__cl_unboxed_%d" (fresh_temp ctx)
                          in
                          emit ctx
                            (Printf.sprintf
                               "; %s %s = %s; blorp_release(%s); %s; })"
                               ret_c_ty value_tmp unbox_expr tmp_r value_tmp)
                        in
                        match box_kind with
                        | BoxFloat ->
                            emit ctx
                              (Printf.sprintf "; blorp_unbox_float(%s); })"
                                 tmp_r)
                        | BoxFloat32 ->
                            emit ctx
                              (Printf.sprintf "; blorp_unbox_float32(%s); })"
                                 tmp_r)
                        | BoxFloat16 ->
                            emit ctx
                              (Printf.sprintf "; blorp_unbox_float16(%s); })"
                                 tmp_r)
                        | BoxInt128 ->
                            emit_owned_unbox
                              (Printf.sprintf "blorp_unbox_int128(%s)" tmp_r)
                        | BoxUInt128 ->
                            emit_owned_unbox
                              (Printf.sprintf "blorp_unbox_uint128(%s)" tmp_r)
                        | BoxStruct c_ty ->
                            emit_owned_unbox
                              (Printf.sprintf "blorp_unbox_struct(%s, %s)" tmp_r
                                 c_ty)
                        | BoxPrim ->
                            emit ctx
                              (Printf.sprintf "; (%s)(long)%s; })" ret_c_ty
                                 tmp_r)
                        | BoxPointer ->
                            emit ctx
                              (Printf.sprintf "; (%s)%s; })" ret_c_ty tmp_r)
                        | BoxVoid -> emit ctx "; (void)0; })"
                      in
                      let is_void = is_void_ty e.ty in
                      let ret_c = if is_void then "void" else "void*" in
                      let return_box_kind =
                        if is_void then None
                        else
                          let box_kind = classify_for_boxing ctx e.ty e.loc in
                          match box_kind with
                          | BoxPointer -> None
                          | _ -> Some box_kind
                      in
                      if Option.is_some return_box_kind then begin
                        let r_id = fresh_temp ctx in
                        let tmp_r = Printf.sprintf "__cl_r_%d" r_id in
                        emit ctx
                          (Printf.sprintf
                             "({ blorp_Closure* %s = (blorp_Closure*)" cl_tmp);
                        emit_expr ctx callee;
                        let arg_bindings = emit_arg_bindings () in
                        emit ctx
                          (Printf.sprintf
                             "; void* %s = ((%s (*)(%s))(%s->func))(%s->env"
                             tmp_r ret_c arg_types cl_tmp cl_tmp);
                        emit_call_args arg_bindings;
                        emit ctx ")";
                        emit_arg_releases arg_bindings;
                        match return_box_kind with
                        | Some box_kind -> emit_unboxed_return tmp_r box_kind
                        | None ->
                            emit ctx
                              (Printf.sprintf "; (%s)%s; })"
                                 (type_to_c ctx e.ty) tmp_r)
                      end
                      else begin
                        emit ctx
                          (Printf.sprintf
                             "({ blorp_Closure* %s = (blorp_Closure*)" cl_tmp);
                        emit_expr ctx callee;
                        let arg_bindings = emit_arg_bindings () in
                        emit ctx
                          (Printf.sprintf "; ((%s (*)(%s))(%s->func))(%s->env"
                             ret_c arg_types cl_tmp cl_tmp);
                        emit_call_args arg_bindings;
                        emit ctx ")";
                        emit_arg_releases arg_bindings;
                        emit ctx "; })"
                      end);
                  match kind with
                  | CKClosure | CKIntrinsic _ -> ()
                  | _ ->
                      (* Legacy/direct-emitter boxing fallback: final pipeline Core
              is checked by [Core_invariants] so runtime [void*] ABI slots
              should already be explicit [CBoxTyped] where scalar/value args
              need boxing. Keep this branch for direct emitter unit tests and
              pre-final debugging, not as a semantic recovery path. *)
                      (* For builtins, we know which arg positions are [void*] —
              only those need boxing (e.g. [blorp_list_set]'s long index
              must NOT be boxed). For union constructors, all primitive
              fields are stored as pointers, so box every arg. *)
                      let void_positions =
                        match kind with
                        | CKBuiltin c -> (
                            match
                              List.assoc_opt c
                                Core_specialize.void_boxed_arg_positions
                            with
                            | Some ps -> Some ps
                            | None -> None)
                        | _ -> None
                      in
                      let is_union_constructor =
                        match callee.desc with
                        | CVar v -> Hashtbl.mem ctx.constructor_names v.vname
                        | CField (_, field) ->
                            Hashtbl.mem ctx.constructor_names field
                        | _ -> false
                      in
                      let box_all =
                        match (kind, void_positions) with
                        | _, Some _ -> false
                        | _, None -> is_union_constructor
                      in
                      List.iteri
                        (fun i arg ->
                          if i > 0 then emit ctx ", ";
                          (* Foreign functions conventionally take [const char*] for
                blorp [String] args (see std/*/_ffi.h). Passing the
                [blorp_String*] directly reads the object header as
                string bytes — appears to "work" for tests that don't
                care about content, but silently wrecks anything that
                does (e.g. sqlite3_open(":memory:") → "unable to open").
                Extract [.data] at the call site so the FFI sees the
                actual char buffer. *)
                          let is_foreign_string_arg =
                            match (kind, normalize_type arg.ty) with
                            | CKForeign _, Ast.TyNamed ("String", _) -> true
                            | CKForeign _, Ast.TyNamed ("LiteralString", _) ->
                                true
                            | _ -> false
                          in
                          let should_box =
                            match void_positions with
                            | Some ps -> List.mem i ps
                            | None -> box_all
                          in
                          if is_foreign_string_arg then begin
                            emit ctx "(const char*)((";
                            emit_expr ctx arg;
                            emit ctx ")->data)"
                          end
                          else if should_box then emit_boxed ctx arg
                          else emit_expr ctx arg)
                        args;
                      (* Union-variant constructors take a trailing release_mask
              parameter — see [emit_union_type]'s constructor for why
              the mask must be computed at the call site rather than
              baked in. Bit [i] is set iff the boxed payload is owned
              ARC-managed heap storage. RC source values and boxed
              value-record structs are releasable; scalar bit-pattern
              boxes such as Float stay unowned. *)
                      if is_union_constructor then begin
                        let mask =
                          List.fold_left
                            (fun acc (i, ty) ->
                              if boxed_value_needs_release ctx ty e.loc then
                                acc lor (1 lsl i)
                              else acc)
                            0
                            (List.mapi (fun i a -> (i, a.ty)) args)
                        in
                        if args <> [] then emit ctx ", ";
                        emit ctx (Printf.sprintf "%dUL" mask)
                      end;
                      (match kind with
                      | CKBuiltin c_name
                        when is_list_parallel_layout_builtin_name c_name ->
                          let layout =
                            list_storage_layout_of_type ctx e.ty e.loc
                          in
                          let storage_mode_c, elem_size_c =
                            list_storage_runtime_args layout
                          in
                          if args <> [] then emit ctx ", ";
                          emit ctx storage_mode_c;
                          emit ctx ", ";
                          emit ctx elem_size_c;
                          emit ctx ", ";
                          emit ctx (list_callback_result_encoding_arg layout)
                      | CKBuiltin c_name
                        when is_vector_parallel_layout_builtin_name c_name ->
                          let layout =
                            Core_layout_type.tensor_storage_layout_of_type
                              ~reg:ctx.reg e.ty e.loc
                          in
                          let storage_mode_c, elem_size_c =
                            vector_parallel_storage_runtime_args layout
                          in
                          if args <> [] then emit ctx ", ";
                          emit ctx storage_mode_c;
                          emit ctx ", ";
                          emit ctx elem_size_c;
                          emit ctx ", ";
                          emit ctx (vector_callback_result_encoding_arg layout)
                      | _ -> ());
                      emit ctx ")";
                      if
                        boxed_result_return_cast
                        || Option.is_some builtin_return_cast
                      then emit ctx ")"
                end))
  | CTensorRawRead r ->
      emit ctx (escape_c_ident (Var.to_c_name r.trr_view));
      emit ctx "[";
      emit_expr ctx r.trr_index;
      emit ctx "]"
  | CTensorRawWrite w ->
      emit ctx "({ ";
      emit ctx (escape_c_ident (Var.to_c_name w.trw_view));
      emit ctx "[";
      emit_expr ctx w.trw_index;
      emit ctx "] = ";
      emit_expr ctx w.trw_value;
      emit ctx "; (void)0; })"
  | CStringByteRead read -> emit_string_byte_read ctx read
  | CStringByteWrite write -> emit_string_byte_write ctx write
  | CStringByteCopy copy -> emit_string_byte_copy ctx copy
  | CStringSetLen set_len -> emit_string_set_len ctx set_len
  | CField (obj, name) -> (
      match normalize_type obj.ty with
      | TyTuple _ ->
          let tmp = Printf.sprintf "__tup_%d" (fresh_temp ctx) in
          let elem_access =
            Printf.sprintf "((blorp_Tuple*)%s)->elem[%s]" tmp name
          in
          emit ctx (Printf.sprintf "({ void* %s = (void*)" tmp);
          emit_expr ctx obj;
          emit ctx "; ";
          (match normalize_type e.ty with
          | Ast.TyNamed ("Float", []) ->
              emit ctx (Printf.sprintf "blorp_unbox_float(%s)" elem_access)
          | Ast.TyNamed ("Float32", []) ->
              emit ctx (Printf.sprintf "blorp_unbox_float32(%s)" elem_access)
          | Ast.TyNamed ("Float16", []) ->
              emit ctx (Printf.sprintf "blorp_unbox_float16(%s)" elem_access)
          | Ast.TyNamed ("Int128", []) ->
              emit ctx (Printf.sprintf "blorp_unbox_int128(%s)" elem_access)
          | Ast.TyNamed ("UInt128", []) ->
              emit ctx (Printf.sprintf "blorp_unbox_uint128(%s)" elem_access)
          | Ast.TyNamed ("Int", [])
          | Ast.TyNamed ("Bool", [])
          | Ast.TyNamed ("Char", []) ->
              emit ctx
                (Printf.sprintf "(%s)(long)%s" (type_to_c ctx e.ty) elem_access)
          | ty when Types.is_any_integer_type ty ->
              emit ctx
                (Printf.sprintf "(%s)(long)%s" (type_to_c ctx e.ty) elem_access)
          | ty
            when Core_layout_type.stack_option_c_type ~reg:ctx.reg ty <> None
                 || Core_layout_type.stack_result_c_type ~reg:ctx.reg ty <> None
            ->
              let c_ty = type_to_c ctx e.ty in
              emit ctx
                (Printf.sprintf "blorp_unbox_struct(%s, %s)" elem_access c_ty)
          | ty when is_value_record_type ctx ty ->
              (* Value-record: the element is a [blorp_box_struct]-boxed
                   pointer, not a raw struct value. Cast-to-struct would
                   be invalid C; dereference past the object header. *)
              emit ctx
                (Printf.sprintf "blorp_unbox_struct(%s, %s)" elem_access
                   (value_record_storage_c_type ctx ty))
          | _ ->
              emit ctx
                (Printf.sprintf "(%s)%s" (type_to_c ctx e.ty) elem_access));
          emit ctx "; })"
      | TyNamed (_, _) when is_value_record_type ctx obj.ty -> (
          match value_record_layout ctx obj.ty with
          | Some layout ->
              if record_field_storage_is_erased ctx layout.vrl_name name then
                emit_void_as_type ctx e.ty (fun () ->
                    emit_expr ctx obj;
                    emit ctx ".";
                    emit ctx (escape_c_ident name))
              else begin
                emit_expr ctx obj;
                emit ctx ".";
                emit ctx (escape_c_ident name)
              end
          | None ->
              emit_expr ctx obj;
              emit ctx "->";
              emit ctx (escape_c_ident name))
      | TyNamed ("Module", []) when Hashtbl.mem ctx.constructor_names name ->
          (* Qualified constructor value: `O.None`. Prefer the registered
              constructor C symbol so combined harnesses can contain multiple
              modules that define the same source constructor name. *)
          let c_name =
            match Hashtbl.find_opt ctx.constructor_c_names name with
            | Some name -> name
            | None -> name
          in
          emit ctx (escape_c_ident c_name)
      | _ -> (
          match normalize_type obj.ty with
          | TyNamed (type_name, _)
            when record_field_storage_is_erased ctx type_name name ->
              emit_void_as_type ctx e.ty (fun () ->
                  emit_expr ctx obj;
                  emit ctx "->";
                  emit ctx (escape_c_ident name))
          | _ ->
              emit_expr ctx obj;
              emit ctx "->";
              emit ctx (escape_c_ident name)))
  (* ---- Range value expression ---- *)
  | CRange (lo, hi) ->
      let range_c_type =
        match normalize_type e.ty with
        | TyNamed ("Range", []) -> type_to_c ctx e.ty
        | _ ->
            Core_error.errorf Core_error.Emit e.loc
              ~hint:
                "range expressions should carry the first-class Range type \
                 after inference; internal loop ranges should be consumed by \
                 CFor emission"
              "range expression reached C emission with non-Range type %s"
              (Types.type_to_string e.ty)
      in
      let tmp = Printf.sprintf "__range_%d" (fresh_temp ctx) in
      emit ctx (Printf.sprintf "({ %s %s = { " range_c_type tmp);
      emit_expr ctx lo;
      emit ctx ", ";
      emit_expr ctx hi;
      emit ctx (Printf.sprintf " }; %s; })" tmp)
  (* ---- Allocating: tuple / list ---- *)
  | CTupleConstruct tc -> emit_tuple_construct ctx tc
  | CListConstruct lc -> emit_list_construct ctx lc
  | CTuple elems ->
      let release_mask =
        List.mapi
          (fun i el -> if tuple_field_needs_release ctx el then 1 lsl i else 0)
          elems
        |> List.fold_left ( lor ) 0
      in
      if release_mask = 0 then begin
        emit ctx (Printf.sprintf "blorp_tuple_new(%d" (List.length elems));
        List.iter
          (fun el ->
            emit ctx ", ";
            emit_boxed ctx el)
          elems;
        emit ctx ")"
      end
      else begin
        let tmp = Printf.sprintf "__tup_%d" (fresh_temp ctx) in
        emit ctx
          (Printf.sprintf "({ blorp_Tuple* %s = blorp_tuple_new(%d" tmp
             (List.length elems));
        List.iter
          (fun el ->
            emit ctx ", ";
            emit_boxed ctx el)
          elems;
        emit ctx ");";
        List.iteri
          (fun i el ->
            if tuple_field_needs_retain ctx el then
              emit ctx
                (Printf.sprintf " if (%s->elem[%d]) blorp_retain(%s->elem[%d]);"
                   tmp i tmp i))
          elems;
        emit ctx
          (Printf.sprintf " blorp_tuple_set_rc(%s, %dUL); %s; })" tmp
             release_mask tmp)
      end
  | CList lit ->
      let elems = lit.ll_elems in
      let n = List.length elems in
      let tmp = Printf.sprintf "__lst_%d" (fresh_temp ctx) in
      emit ctx (Printf.sprintf "({ blorp_List* %s = " tmp);
      emit_list_alloc_call ctx lit.ll_layout (fun () ->
          emit ctx (string_of_int n));
      emit ctx ";";
      (match lit.ll_layout.lsl_slots with
      | ListInlineStructStorage c_ty ->
          List.iteri
            (fun i el ->
              let elem_tmp = Printf.sprintf "__lst_elem_%d" (fresh_temp ctx) in
              emit ctx (Printf.sprintf " { %s %s = " c_ty elem_tmp);
              emit_expr ctx el;
              emit ctx
                (Printf.sprintf "; blorp_list_set_raw_copy(%s, %d, &%s); }" tmp
                   i elem_tmp))
            elems;
          emit ctx (Printf.sprintf " %s->len = %d;" tmp n)
      | ListPointerStorage | ListInlineStorage _ ->
          let elem_needs_release =
            list_storage_layout_requires_release_or_error ~phase:Core_error.Emit
              ~loc:e.loc lit.ll_layout
          in
          if elem_needs_release then
            emit ctx
              (Printf.sprintf
                 " blorp_list_init_elem_release(%s, blorp_elem_release_fn);" tmp);
          List.iter
            (fun el ->
              let append_fn =
                if elem_needs_release && boxed_expr_transfers_ownership ctx el
                then "blorp_list_append_owned"
                else "blorp_list_append"
              in
              emit ctx (Printf.sprintf " %s = %s(%s, " tmp append_fn tmp);
              emit_boxed ctx el;
              emit ctx ");")
            elems);
      emit ctx (Printf.sprintf " %s; })" tmp)
  | CListAlloc alloc ->
      if
        list_storage_layout_requires_release_or_error ~phase:Core_error.Emit
          ~loc:e.loc alloc.la_layout
      then begin
        let tmp = Printf.sprintf "__lst_%d" (fresh_temp ctx) in
        emit ctx (Printf.sprintf "({ blorp_List* %s = " tmp);
        emit_list_alloc_call ctx alloc.la_layout (fun () ->
            emit_expr ctx alloc.la_capacity);
        emit ctx
          (Printf.sprintf
             "; blorp_list_init_elem_release(%s, blorp_elem_release_fn); %s; })"
             tmp tmp)
      end
      else
        emit_list_alloc_call ctx alloc.la_layout (fun () ->
            emit_expr ctx alloc.la_capacity)
  | CListGet get -> emit_list_get ctx get
  | CRecordConstruct rc -> emit_record_construct ctx rc
  | CDictConstruct dc -> emit_dict_construct ctx e dc
  | CSetAlloc sa -> emit_set_alloc ctx e.loc sa.sa_constructor
  | CTensorLiteral tl -> emit_tensor_literal ctx e.loc tl
  | CUnionConstruct uc -> emit_union_construct ctx uc
  (* ---- Record construction: [TypeName_make(field0, field1, ...)] ----
     Matches the legacy codegen's constructor convention. The result
     type's name is used as the constructor prefix. Fields are emitted
     raw (not boxed) — the _make function expects typed args. *)
  | CRecord fields -> (
      (* Empty [{}] with a Dict/Set/Tensor/List expected type is parsed as
         [ERecord []]; the type drives which runtime constructor we emit. *)
      match (normalize_type e.ty, fields) with
      | TyNamed ("Dict", k :: _), [] ->
          let ctor =
            Core_hash_container_layout.dict_constructor_kind ~reg:ctx.reg k
          in
          emit_dict_constructor_expr ctx e.ty e.loc (fun () ->
              emit_dict_ctor_for_kind ctx e.loc ctor)
      | TyNamed ("Set", [ elem ]), [] ->
          let ctor =
            Core_hash_container_layout.set_constructor_kind ~reg:ctx.reg elem
          in
          emit_set_alloc ctx e.loc ctor
      | ty, [] when is_tensor_type ctx ty -> emit ctx "blorp_vector_new(0)"
      | TyNamed ("List", _), [] ->
          let layout =
            Core_layout_type.list_storage_layout_of_type ~reg:ctx.reg e.ty e.loc
          in
          if list_element_needs_release ctx e.ty e.loc then begin
            let tmp = Printf.sprintf "__lst_%d" (fresh_temp ctx) in
            emit ctx (Printf.sprintf "({ blorp_List* %s = " tmp);
            emit_list_alloc_call ctx layout (fun () -> emit ctx "0");
            emit ctx
              (Printf.sprintf
                 "; blorp_list_init_elem_release(%s, blorp_elem_release_fn); \
                  %s; })"
                 tmp tmp)
          end
          else emit_list_alloc_call ctx layout (fun () -> emit ctx "0")
      | ty, _ ->
          let type_name =
            match ty with
            | TyNamed (n, _) -> n
            | _ ->
                Core_error.errorf Core_error.Emit e.loc
                  ~hint:
                    "a CRecord must carry a named record type so we can \
                     resolve its constructor; check that the expression's type \
                     was populated during inference"
                  "CRecord with non-TyNamed type"
          in
          emit ctx (Printf.sprintf "%s_make(" type_name);
          let record_decl = Hashtbl.find_opt ctx.record_decls type_name in
          let record_subst =
            match (record_decl, normalize_type e.ty) with
            | Some r, TyNamed (_, args)
              when List.length r.record_type_params = List.length args ->
                List.combine (Ast.type_param_names r.record_type_params) args
            | _ -> []
          in
          let field_decl_type field_name =
            match record_decl with
            | None -> None
            | Some r ->
                List.find_opt
                  (fun (fd : Ast.field_decl) -> fd.field_name = field_name)
                  r.record_fields
                |> Option.map (fun (fd : Ast.field_decl) -> fd.field_type)
          in
          let field_expected_type field_name =
            Option.map
              (apply_codegen_subst record_subst)
              (field_decl_type field_name)
          in
          let field_value_for_emit field_name v =
            match (field_expected_type field_name, v.desc) with
            | Some ty, CRecord [] -> { v with ty }
            | _ -> v
          in
          let ordered_fields =
            match record_decl with
            | None -> fields
            | Some r ->
                List.map
                  (fun (fd : Ast.field_decl) ->
                    match List.assoc_opt fd.field_name fields with
                    | Some v -> (fd.field_name, v)
                    | None ->
                        Core_error.errorf Core_error.Emit e.loc
                          ~hint:
                            "record literals should be validated during type \
                             checking before Core emission"
                          "record literal for %s is missing field %s" type_name
                          fd.field_name)
                  r.record_fields
          in
          let erased_field_indices =
            match record_decl with
            | Some r ->
                r.record_fields
                |> List.mapi (fun i (fd : Ast.field_decl) -> (i, fd))
                |> List.filter (fun (_, (fd : Ast.field_decl)) ->
                    is_erased_record_field ctx fd.field_type)
                |> List.map fst
            | None -> []
          in
          List.iteri
            (fun i (field_name, v) ->
              if i > 0 then emit ctx ", ";
              let v = field_value_for_emit field_name v in
              let should_box =
                match field_decl_type field_name with
                | Some ty -> is_erased_record_field ctx ty
                | None -> false
              in
              if should_box then emit_boxed ctx v else emit_expr ctx v)
            ordered_fields;
          if erased_field_indices <> [] then begin
            if ordered_fields <> [] then emit ctx ", ";
            let mask =
              List.fold_left
                (fun acc (i, (_, v)) ->
                  if
                    List.mem i erased_field_indices
                    && boxed_value_needs_release ctx v.ty v.loc
                  then acc lor (1 lsl i)
                  else acc)
                0
                (List.mapi (fun i f -> (i, f)) ordered_fields)
            in
            emit ctx (Printf.sprintf "%dUL" mask)
          end;
          emit ctx ")")
  (* ---- Dict construction ----
     Dispatches on key type for the initial new call (string/float/
     generic), then threads through [blorp_dict_insert] calls for
     each pair. Keys and values are boxed via [emit_boxed] so they
     fit the [void*] interface. *)
  | CDict kvs ->
      let key_ty =
        match Core_layout_type.canonical_type ~reg:ctx.reg e.ty with
        | TyNamed ("Dict", key_ty :: _) -> key_ty
        | _ -> TyNamed ("Any", [])
      in
      let dict_ctor =
        Core_hash_container_layout.dict_constructor_kind ~reg:ctx.reg key_ty
      in
      let tmp = Printf.sprintf "__dict_%d" (fresh_temp ctx) in
      emit ctx (Printf.sprintf "({ blorp_Dict* %s = " tmp);
      emit_dict_ctor_for_kind ctx e.loc dict_ctor;
      emit ctx ";";
      if dict_value_needs_release ctx e.ty e.loc then
        emit_dict_value_release_init ctx tmp;
      List.iter
        (fun (k, v) ->
          emit ctx (Printf.sprintf " %s = blorp_dict_insert(%s, " tmp tmp);
          emit_boxed ctx k;
          emit ctx ", ";
          emit_boxed ctx v;
          emit ctx ");")
        kvs;
      emit ctx (Printf.sprintf " %s; })" tmp)
  | CVector elems -> (
      (* Multi-dimensional tensor literal (e.g. {{1,2,3},{4,5,6}} typed
         as Int[#2, #3]) must flatten into row-major storage so
         subscript peeling ([blorp_tensor_slice_row]) reads the right
         bytes. A naive per-level [blorp_vector_new] produces a
         vector-of-vectors whose outer [data[i]] holds a pointer to an
         inner vector — incompatible with flat-storage peel/set
         primitives. Detect T[d0, d1, ...] types and flatten. *)
      let tensor_ty =
        match tensor_type_of_expr ctx e with
        | Some tensor_ty -> tensor_ty
        | None ->
            Core_error.errorf Core_error.Emit e.loc
              ~hint:
                "CVector nodes should only reach emission with a tensor, \
                 vector, or matrix semantic type carrying at least one \
                 dimension"
              "CVector emission requires a ranked tensor type, got %s"
              (Types.type_to_string e.ty)
      in
      let elem_ty = tensor_ty.elem_ty in
      let is_float32_literal =
        match elem_ty with Ast.TyNamed ("Float32", _) -> true | _ -> false
      in
      let is_float64_literal =
        match elem_ty with Ast.TyNamed ("Float", _) -> true | _ -> false
      in
      let is_i64_literal =
        match elem_ty with Ast.TyNamed ("Int", _) -> true | _ -> false
      in
      let elem_needs_release = boxed_value_needs_release ctx elem_ty e.loc in
      let tensor_dims =
        match tensor_ty.dims with
        | dims when List.length dims >= 2 ->
            (* Require all dims to be constant for flat allocation. *)
            let all_const =
              List.for_all
                (function Ast.TyConstInt _ -> true | _ -> false)
                dims
            in
            if all_const then
              Some (List.map (function Ast.TyConstInt n -> n | _ -> 0) dims)
            else None
        | _ -> None
      in
      match tensor_dims with
      | Some dims ->
          (* Flatten nested CVectors in row-major order. Inner elements
              are scalars (or nested CVectors one level deep per dim). *)
          let first_dim = List.hd dims in
          let total = List.fold_left ( * ) 1 dims in
          let rec collect_leaves acc e =
            match e.desc with
            | CVector inner -> List.fold_left collect_leaves acc inner
            | _ -> e :: acc
          in
          let flat = List.rev (List.fold_left collect_leaves [] elems) in
          let tmp = Printf.sprintf "__ten_%d" (fresh_temp ctx) in
          emit ctx
            (Printf.sprintf "({ blorp_Vector* %s = %s(%d, %d);" tmp
               (if is_i64_literal then "blorp_tensor_new_i64"
                else if is_float64_literal then "blorp_tensor_new_f64"
                else if is_float32_literal then "blorp_tensor_new_f32"
                else "blorp_tensor_new")
               first_dim total);
          if elem_needs_release then
            emit ctx
              (Printf.sprintf
                 " blorp_vector_init_elem_release(%s, blorp_elem_release_fn);"
                 tmp);
          List.iteri
            (fun i el ->
              if is_i64_literal then begin
                emit ctx (Printf.sprintf " ((long*)%s->data)[%d] = " tmp i);
                emit_expr ctx el
              end
              else if is_float64_literal then begin
                emit ctx (Printf.sprintf " ((double*)%s->data)[%d] = " tmp i);
                emit_expr ctx el
              end
              else if is_float32_literal then begin
                emit ctx (Printf.sprintf " ((float*)%s->data)[%d] = " tmp i);
                emit_expr ctx el
              end
              else if elem_needs_release then begin
                let elem_tmp = Printf.sprintf "__elem_%d" (fresh_temp ctx) in
                emit ctx (Printf.sprintf " void* %s = " elem_tmp);
                emit_boxed ctx el;
                emit ctx (Printf.sprintf "; %s->data[%d] = %s;" tmp i elem_tmp);
                if not (boxed_expr_transfers_ownership ctx el) then
                  emit ctx
                    (Printf.sprintf " if (%s) blorp_retain(%s);" elem_tmp
                       elem_tmp)
              end
              else begin
                emit ctx (Printf.sprintf " %s->data[%d] = " tmp i);
                emit_boxed ctx el
              end;
              emit ctx ";")
            flat;
          emit ctx (Printf.sprintf " %s; })" tmp)
      | None ->
          let n = List.length elems in
          let tmp = Printf.sprintf "__vec_%d" (fresh_temp ctx) in
          emit ctx
            (Printf.sprintf "({ blorp_Vector* %s = %s(%d);" tmp
               (if is_i64_literal then "blorp_vector_new_i64"
                else if is_float64_literal then "blorp_vector_new_f64"
                else if is_float32_literal then "blorp_vector_new_f32"
                else "blorp_vector_new")
               n);
          if elem_needs_release then
            emit ctx
              (Printf.sprintf
                 " blorp_vector_init_elem_release(%s, blorp_elem_release_fn);"
                 tmp);
          List.iteri
            (fun i el ->
              if is_i64_literal then begin
                emit ctx (Printf.sprintf " ((long*)%s->data)[%d] = " tmp i);
                emit_expr ctx el
              end
              else if is_float64_literal then begin
                emit ctx (Printf.sprintf " ((double*)%s->data)[%d] = " tmp i);
                emit_expr ctx el
              end
              else if is_float32_literal then begin
                emit ctx (Printf.sprintf " ((float*)%s->data)[%d] = " tmp i);
                emit_expr ctx el
              end
              else if elem_needs_release then begin
                let elem_tmp = Printf.sprintf "__elem_%d" (fresh_temp ctx) in
                emit ctx (Printf.sprintf " void* %s = " elem_tmp);
                emit_boxed ctx el;
                emit ctx (Printf.sprintf "; %s->data[%d] = %s;" tmp i elem_tmp);
                if not (boxed_expr_transfers_ownership ctx el) then
                  emit ctx
                    (Printf.sprintf " if (%s) blorp_retain(%s);" elem_tmp
                       elem_tmp)
              end
              else begin
                emit ctx (Printf.sprintf " %s->data[%d] = " tmp i);
                emit_boxed ctx el
              end;
              emit ctx ";")
            elems;
          emit ctx (Printf.sprintf " %s; })" tmp))
  | CRecordUpdate _ ->
      (* Phase 2.4: Core_desugar.desugar_record_update rewrites every
         record update (value or heap) into CLet + CRecord. Reaching
         emit means field_map lacked the record type during desugaring
         — typically because a module declaring it wasn't loaded in
         time. --check-invariants localizes the break. *)
      Core_error.errorf Core_error.Emit e.loc
        ~hint:
          "record declaration missing from core_desugar's field_map; ensure \
           the module declaring this record is loaded, then run with \
           --check-invariants to confirm"
        "CRecordUpdate survived desugaring (invariant violated)"
  | CResourceScope scope ->
      let resource_ty_c = type_to_c ctx scope.rs_ty in
      let resource_c = escape_c_ident (Var.to_c_name scope.rs_var) in
      let cleanup_push = resource_cancellation_cleanup_push_stmt scope in
      let cleanup_pop = cancellation_cleanup_pop_slot_stmt scope.rs_var in
      emit ctx "({ ";
      emit ctx (Printf.sprintf "%s %s = " resource_ty_c resource_c);
      emit_expr ctx scope.rs_acquire;
      emit ctx "; ";
      emit ctx cleanup_push;
      emit ctx " ";
      if is_void_ty scope.rs_body.ty then begin
        emit_expr ctx scope.rs_body;
        emit ctx "; ";
        emit ctx cleanup_pop;
        emit ctx "; ";
        emit_expr ctx scope.rs_cleanup;
        emit ctx "; })"
      end
      else begin
        let result_tmp =
          Printf.sprintf "__resource_result_%d" (fresh_temp ctx)
        in
        emit ctx
          (Printf.sprintf "%s %s = "
             (type_to_c ctx scope.rs_body.ty)
             result_tmp);
        emit_expr ctx scope.rs_body;
        emit ctx "; ";
        emit ctx cleanup_pop;
        emit ctx "; ";
        emit_expr ctx scope.rs_cleanup;
        emit ctx (Printf.sprintf "; %s; })" result_tmp)
      end
  | CLambda _ ->
      Core_error.errorf Core_error.Emit e.loc
        ~hint:
          "run with --check-invariants to confirm core_closure hoisted every \
           lambda and replaced it with CClosureCreate"
        "raw CLambda survived closure conversion (emit invariant violated)"
  | CClosureCreate cc ->
      let cfunc_c = Codegen_names.mangle_by_def_id cc.cc_def_id cc.cc_func in
      if cc.cc_captures = [] then
        emit ctx (Printf.sprintf "((void*)&__sc_%s)" (escape_c_ident cfunc_c))
      else begin
        let nc = List.length cc.cc_captures in
        let tmp = Printf.sprintf "__cl_%d" (fresh_temp ctx) in
        emit ctx
          (Printf.sprintf
             "({ blorp_Closure* %s = blorp_closure_new_inline((void*)%s, %d);"
             tmp (escape_c_ident cfunc_c) nc);
        List.iteri
          (fun i (cap_name, cap_ty) ->
            emit ctx (Printf.sprintf " ((void**)%s->env)[%d] = " tmp i);
            emit_capture_box ctx cap_name cap_ty;
            emit ctx ";")
          cc.cc_captures;
        emit_closure_env_release_mask_expr ctx tmp cc.cc_captures;
        emit ctx (Printf.sprintf " (void*)%s; })" tmp)
      end
  (* Phase 2.5: every CMatchArms must be compiled to CMatch (decision
     tree) by core_match. The [Core_invariants.check_no_cmatcharms] check
     at [--check-invariants] localizes the responsible pass with a
     full dump. A fall-through here means an arm shape slipped past
     [classify_arms]. *)
  | CMatchArms _ ->
      Core_error.errorf Core_error.Emit e.loc
        ~hint:
          "run with --check-invariants to confirm core_match eliminated every \
           CMatchArms; if so, this arm shape is the gap in classify_arms"
        "raw CMatchArms survived match-compilation (emit invariant violated)"
  | CMatch _ when is_void_ty e.ty ->
      emit ctx "({ ";
      emit_stmt ctx e;
      emit ctx "(void)0; })"
  | CMatch (scrut, tree) ->
      let scrut_ty_c = type_to_c ctx scrut.ty in
      let id_s = fresh_temp ctx in
      let id_r = fresh_temp ctx in
      let scrut_name = Printf.sprintf "__scrut_%d" id_s in
      let result_name = Printf.sprintf "__mr_%d" id_r in
      let result_ty_c = type_to_c ctx e.ty in
      emit ctx "({ ";
      emit ctx (Printf.sprintf "%s %s = " scrut_ty_c scrut_name);
      emit_expr ctx scrut;
      emit ctx (Printf.sprintf "; %s %s; " result_ty_c result_name);
      emit_ctree_assign ctx scrut_name scrut.ty result_name tree;
      if match_scrutinee_needs_release ctx scrut then
        emit ctx
          (Printf.sprintf "%s; " (release_value_call ctx scrut.ty scrut_name));
      emit ctx (Printf.sprintf "%s; })" result_name)
  (* ---- Statement-level control flow in expression position ----
     These constructs don't produce values. If they show up here it's
     because lowering produced a tree we can't render as a C expression.
     Callers that have a statement context should use [emit_stmt]. *)
  | CWhile _ | CFor _ | CBreak | CContinue | CAssign _ | CResourceCleanupExit _
    ->
      emit ctx "({ ";
      emit_stmt ctx e;
      emit ctx "(void)0; })"
  | CTailrecLoop _ | CTailrecRecur _ ->
      Core_error.errorf Core_error.Emit e.loc
        ~hint:
          "Core tailrec loop forms are function-body control flow. They must \
           be emitted by the function emitter, not as nested expressions."
        "tailrec loop form reached expression emission"
  (* Sugar nodes (Phase 2.4): these are guaranteed to be eliminated by
     [Core_desugar] — the [Core_invariants.check_no_sugar] check at
     [--check-invariants] localizes exactly which pass (if any) failed
     to desugar. If we reach here, an earlier pass constructed sugar
     AFTER desugar OR desugar itself has a gap. *)
  | CDebugBlock _ ->
      Core_error.errorf Core_error.Emit e.loc
        ~hint:
          "run with --check-invariants to localize the pass that produced this \
           form; Core_debug should have lowered it"
        "debug block survived Core_debug lowering (emit invariant violated)"
  | CStringInterp _ ->
      Core_error.errorf Core_error.Emit e.loc
        ~hint:
          "run with --check-invariants to localize the pass that produced this \
           sugar form; desugar should have eliminated it"
        "sugar node survived desugaring (emit invariant violated)"
  (* ---- Concurrency (expression context) ---- *)
  | CConcurrent block ->
      emit ctx "({ ";
      emit_concurrent_block ctx block;
      emit ctx " })"
  | CConcurrentFor cf ->
      (* Expression position: the value of [concurrent for] is the
         collected [List[Result[T, ConcurrencyError]]]. The result
         list lives in the temp [__conc_results_<id>]; close the
         stmt-expr with that name so the surrounding [blorp_List* x =
         (concurrent for …)] gets the list, not [void]. *)
      emit ctx "({ ";
      let results_var = emit_concurrent_for_collecting ~collect:true ctx cf in
      emit ctx (Printf.sprintf " %s; })" results_var)
  | CDetach detach -> emit_detach_expr ctx detach e.loc
  (* ---- Type operations (inserted by Core_specialize) ---- *)
  | CCast (x, target_ty) ->
      let c_ty = type_to_c ctx target_ty in
      emit ctx (Printf.sprintf "((%s)" c_ty);
      emit_expr ctx x;
      emit ctx ")"
  | CUnboxTyped u -> emit_unbox_op ctx u
  | CUnbox (x, target_ty) -> (
      match (normalize_type target_ty, x.desc) with
      | ( Ast.TyNamed (_, _),
          ( CCall (CKIntrinsic "tensor_get_unchecked", _, [ arr; idx ])
          | CCast
              ( {
                  desc =
                    CCall (CKIntrinsic "tensor_get_unchecked", _, [ arr; idx ]);
                  _;
                },
                _ ) ) )
        when is_value_record_type ctx target_ty ->
          let c_ty = value_record_storage_c_type ctx target_ty in
          let arr_tmp = Printf.sprintf "__tgu_arr_%d" (fresh_temp ctx) in
          let idx_tmp = Printf.sprintf "__tgu_idx_%d" (fresh_temp ctx) in
          let out_tmp = Printf.sprintf "__tgu_out_%d" (fresh_temp ctx) in
          emit ctx
            (Printf.sprintf "({ blorp_Vector* %s = (blorp_Vector*)" arr_tmp);
          emit_expr ctx arr;
          emit ctx (Printf.sprintf "; long %s = " idx_tmp);
          emit_expr ctx idx;
          emit ctx
            (Printf.sprintf
               "; %s %s; if (__builtin_expect(%s->storage_mode == \
                BLORP_VECTOR_STORAGE_INLINE && %s->elem_size == sizeof(%s), \
                1)) { memcpy(&%s, (char*)%s->data + %s * sizeof(%s), \
                sizeof(%s)); } else { void* __raw = %s->data[%s]; %s = \
                blorp_unbox_struct(__raw, %s); } %s; })"
               c_ty out_tmp arr_tmp arr_tmp c_ty out_tmp arr_tmp idx_tmp c_ty
               c_ty arr_tmp idx_tmp out_tmp c_ty out_tmp)
      | _ -> (
          match normalize_type target_ty with
          | Ast.TyNamed ("Float", _) ->
              emit ctx "blorp_unbox_float(";
              emit_expr ctx x;
              emit ctx ")"
          | Ast.TyNamed ("Float32", _) ->
              emit ctx "blorp_unbox_float32(";
              emit_expr ctx x;
              emit ctx ")"
          | Ast.TyNamed ("Float16", _) ->
              emit ctx "blorp_unbox_float16(";
              emit_expr ctx x;
              emit ctx ")"
          | Ast.TyNamed ("Int128", _) ->
              emit ctx "blorp_unbox_int128(";
              emit_expr ctx x;
              emit ctx ")"
          | Ast.TyNamed ("UInt128", _) ->
              emit ctx "blorp_unbox_uint128(";
              emit_expr ctx x;
              emit ctx ")"
          | Ast.TyNamed ("Int", _)
          | Ast.TyNamed ("Bool", _)
          | Ast.TyNamed ("Char", _) ->
              let c_ty = type_to_c ctx target_ty in
              emit ctx (Printf.sprintf "((%s)(long)" c_ty);
              emit_expr ctx x;
              emit ctx ")"
          | ty when Types.is_any_integer_type ty ->
              let c_ty = type_to_c ctx target_ty in
              emit ctx (Printf.sprintf "((%s)(long)" c_ty);
              emit_expr ctx x;
              emit ctx ")"
          | ty
            when Core_layout_type.stack_option_c_type ~reg:ctx.reg ty <> None
                 || Core_layout_type.stack_result_c_type ~reg:ctx.reg ty <> None
            ->
              let c_ty = type_to_c ctx target_ty in
              emit ctx (Printf.sprintf "(*(%s*)((char*)" c_ty);
              emit_expr ctx x;
              emit ctx " + sizeof(blorp_Object)))"
          | ty when is_value_record_type ctx ty ->
              (* Struct unboxing: stored in containers as blorp_Object header + struct data.
              Dereference past the header to get the struct value. *)
              let c_ty = value_record_storage_c_type ctx target_ty in
              emit ctx (Printf.sprintf "(*(%s*)((char*)" c_ty);
              emit_expr ctx x;
              emit ctx " + sizeof(blorp_Object)))"
          | _ ->
              let c_ty = type_to_c ctx target_ty in
              emit ctx (Printf.sprintf "((%s)" c_ty);
              emit_expr ctx x;
              emit ctx ")"))
  | CBoxTyped b -> emit_box_op ctx b
  | CBox (x, source_ty) ->
      (* Phase 2.6.3: box strategy is driven by the explicit source-type
         annotation, not by the inner node's [.ty] — an earlier pass may
         have rewritten [x] to have a different [.ty] (e.g. Void after a
         reinterpret). The [source_ty] field is the single source of
         truth for "what type was the value before boxing." *)
      let tmp = Printf.sprintf "__box_%d" (fresh_temp ctx) in
      let c_ty = type_to_c ctx source_ty in
      emit ctx (Printf.sprintf "({ %s %s = " c_ty tmp);
      emit_expr ctx x;
      emit ctx "; ";
      emit_box_to_void ~loc:e.loc ctx tmp source_ty;
      emit ctx "; })"
  (* ---- RC operations (Phase 2.8a) ----
     Drop-BEFORE semantics: emit the RC op, then recurse into the
     wrapped body. In expression position, wrap in a GCC statement
     expression so the result is the body's value. *)
  | CDup (v, ty, body) ->
      if type_requires_retain ctx ty then begin
        emit ctx "({ ";
        emit ctx
          (Printf.sprintf "%s; "
             (retain_value_call ctx ty
                (escape_c_ident (var_ref_c_name_for_type ctx v ty))));
        emit_expr ctx body;
        emit ctx "; })"
      end
      else emit_expr ctx body
  | CDrop (v, ty, body) ->
      if type_requires_release ctx ty then begin
        emit ctx "({ ";
        emit ctx (Printf.sprintf "%s; " (cancellation_cleanup_pop_slot_stmt v));
        emit ctx
          (Printf.sprintf "%s; "
             (release_value_call ctx ty
                (escape_c_ident (var_ref_c_name_for_type ctx v ty))));
        emit_expr ctx body;
        emit ctx "; })"
      end
      else emit_expr ctx body

(** Emit a list producer/fusion handoff.

    [BorrowFresh] allocates a fresh builder and borrows the source for reads.
    [ConsumeReuse] consumes the source owner. If the runtime proves the source
    is unique, compatible, and large enough, the result aliases the source
    storage. Handoff bodies must write through handoff-aware stores so owned
    produced values are transferred, borrowed source slots are moved or
    retained according to the runtime reuse decision, and overwritten managed
    slots are released exactly once. After the body, any old tail slots past the
    compacted output length are released before shrinking [len]. *)
and emit_list_handoff (ctx : Core_emit_context.t) (e : core) (h : list_handoff)
    : unit =
  let source_c = escape_c_ident (Var.to_c_name h.lh_source_var) in
  let result_c = escape_c_ident (Var.to_c_name h.lh_result_var) in
  let len_c = escape_c_ident (Var.to_c_name h.lh_len_var) in
  let out_c = escape_c_ident (Var.to_c_name h.lh_out_var) in
  let id = fresh_temp ctx in
  let cap_c = Printf.sprintf "__lh_cap_%d" id in
  let reuse_c = Printf.sprintf "__lh_reuse_%d" id in
  let release_c = Printf.sprintf "__lh_release_%d" id in
  let source_ty_c = type_to_c ctx h.lh_source_ty in
  let result_ty_c = type_to_c ctx h.lh_result_ty in
  let storage_mode_c, elem_size_c = list_storage_runtime_args h.lh_layout in
  let result_needs_release =
    list_storage_layout_requires_release_or_error ~phase:Core_error.Emit
      ~loc:e.loc h.lh_layout
  in
  emit ctx "({ ";
  emit ctx (Printf.sprintf "%s %s = " source_ty_c source_c);
  emit_expr ctx h.lh_source;
  emit ctx "; ";
  emit ctx (Printf.sprintf "long %s = " cap_c);
  emit_expr ctx h.lh_capacity;
  emit ctx "; ";
  emit ctx
    (Printf.sprintf "long %s = %s ? ((blorp_List*)%s)->len : 0L; " len_c
       source_c source_c);
  emit ctx
    (Printf.sprintf "void (*%s)(void*) = %s; " release_c
       (if result_needs_release then "blorp_elem_release_fn" else "NULL"));
  (match h.lh_mode with
  | BorrowFresh ->
      emit ctx
        (Printf.sprintf
           "%s %s = (%s)blorp_list_handoff_begin_borrow(%s, %s, %s, %s); "
           result_ty_c result_c result_ty_c cap_c release_c storage_mode_c
           elem_size_c)
  | ConsumeReuse ->
      emit ctx (Printf.sprintf "bool %s = false; " reuse_c);
      emit ctx
        (Printf.sprintf
           "%s %s = (%s)blorp_list_handoff_begin_reuse((blorp_List*)%s, %s, \
            %s, %s, %s, &%s); "
           result_ty_c result_c result_ty_c source_c cap_c release_c
           storage_mode_c elem_size_c reuse_c));
  emit ctx (Printf.sprintf "long %s = 0L; " out_c);
  emit_stmt ctx h.lh_body;
  (match h.lh_mode with
  | BorrowFresh ->
      emit ctx
        (Printf.sprintf
           "blorp_list_handoff_finish((blorp_List*)%s, %s, %s, false, NULL); "
           result_c out_c len_c)
  | ConsumeReuse ->
      emit ctx
        (Printf.sprintf
           "blorp_list_handoff_finish((blorp_List*)%s, %s, %s, %s, \
            (blorp_List*)%s); "
           result_c out_c len_c reuse_c source_c));
  emit ctx result_c;
  emit ctx "; })"

(* --- §3. emit_stmt --------------------------------------------------------- *)

(** Emit a Core expression into [ctx.output] in statement context.

    In statement context, result values are discarded — the caller must
    explicitly wrap the tail position with [emit_return] when producing a
    value is required (e.g., at the end of a function body).

    Statement emission differs from expression emission in three ways:
    - [CLet] becomes a real [T x = rhs; ...] declaration, not [({ ... })].
    - [CSeq] becomes two separate statements, not a statement expression.
    - [CIf] becomes an [if/else], not a ternary.

    Control-flow constructs ([CWhile], [CFor], [CBreak], [CContinue],
    [CAssign]) only make sense in statement context and are exclusively
    handled here. *)
and emit_stmt (ctx : Core_emit_context.t) (e : core) : unit =
  match e.desc with
  (* ---- Empty statement ---- *)
  | CVoid -> ()
  (* ---- Sequencing ---- *)
  | CLet (b, body) when is_void_ty b.bind_ty ->
      (* Void-typed binding: no declarator — emit as two statements. *)
      emit_stmt ctx b.bind_rhs;
      emit_stmt ctx body
  | CBorrowLet (b, body) when is_void_ty b.borrow_ty ->
      emit_stmt ctx b.borrow_rhs;
      emit_stmt ctx body
  | CLet (b, body) when b.bind_var.vname = "_" ->
      emit_discard_stmt ctx b.bind_rhs;
      emit_stmt ctx body
  | CBorrowLet (b, body) when b.borrow_var.vname = "_" ->
      emit_discard_stmt ctx b.borrow_rhs;
      emit_stmt ctx body
  | CLet (b, body) ->
      let rhs =
        expr_with_expected_type_for_constructors ctx b.bind_rhs b.bind_ty
      in
      let track_cleanup =
        cancellation_cleanup_tracks_binding ctx b.bind_var b.bind_ty body
      in
      emit_indent ctx;
      emit ctx (type_to_c ctx b.bind_ty);
      emit ctx " ";
      emit ctx (escape_c_ident (Var.to_c_name b.bind_var));
      emit ctx " = ";
      (match normalize_type b.bind_ty with
      | Ast.TyFunc _ -> emit_boxed ctx rhs
      | _ -> emit_expr ctx rhs);
      emitln ctx ";";
      if track_cleanup then
        emit_cancellation_cleanup_push ctx b.bind_var b.bind_ty;
      emit_stmt ctx body;
      if track_cleanup then
        emit_line ctx
          (Printf.sprintf "%s;" (cancellation_cleanup_pop_slot_stmt b.bind_var))
  | CBorrowLet (b, body) ->
      let rhs =
        expr_with_expected_type_for_constructors ctx b.borrow_rhs b.borrow_ty
      in
      emit_indent ctx;
      emit ctx (type_to_c ctx b.borrow_ty);
      emit ctx " ";
      emit ctx (escape_c_ident (Var.to_c_name b.borrow_var));
      emit ctx " = ";
      (match normalize_type b.borrow_ty with
      | Ast.TyFunc _ -> emit_boxed ctx rhs
      | _ -> emit_expr ctx rhs);
      emitln ctx ";";
      emit_stmt ctx body
  | CTensorRawViewLet (b, body) ->
      emit_indent ctx;
      emit_tensor_raw_view_decl ctx b;
      emitln ctx ";";
      emit_stmt ctx body
  | CSeq (a, b) ->
      emit_stmt ctx a;
      emit_stmt ctx b
  (* ---- Control flow ---- *)
  | CIf (cond, then_e, else_e) -> (
      emit_indent ctx;
      emit ctx "if (";
      emit_expr ctx cond;
      emitln ctx ") {";
      ctx.indent <- ctx.indent + 1;
      emit_stmt ctx then_e;
      ctx.indent <- ctx.indent - 1;
      (* Only emit else block if it's non-void *)
      match else_e.desc with
      | CVoid ->
          emit_indent ctx;
          emitln ctx "}"
      | _ ->
          emit_indent ctx;
          emitln ctx "} else {";
          ctx.indent <- ctx.indent + 1;
          emit_stmt ctx else_e;
          ctx.indent <- ctx.indent - 1;
          emit_indent ctx;
          emitln ctx "}")
  | CWhile (cond, body) ->
      emit_indent ctx;
      emit ctx "while (";
      emit_expr ctx cond;
      emitln ctx ") {";
      ctx.indent <- ctx.indent + 1;
      emit_stmt ctx body;
      ctx.indent <- ctx.indent - 1;
      emit_indent ctx;
      emitln ctx "}"
  | CFor (binder, iter, body) -> emit_for_loop ctx binder iter body
  | CResourceScope scope ->
      let resource_ty_c = type_to_c ctx scope.rs_ty in
      let resource_c = escape_c_ident (Var.to_c_name scope.rs_var) in
      emit_line ctx "{";
      ctx.indent <- ctx.indent + 1;
      emit_indent ctx;
      emit ctx (Printf.sprintf "%s %s = " resource_ty_c resource_c);
      emit_expr ctx scope.rs_acquire;
      emitln ctx ";";
      emit_line ctx (resource_cancellation_cleanup_push_stmt scope);
      emit_stmt ctx scope.rs_body;
      emit_line ctx (cancellation_cleanup_pop_slot_stmt scope.rs_var ^ ";");
      emit_stmt ctx scope.rs_cleanup;
      ctx.indent <- ctx.indent - 1;
      emit_line ctx "}"
  | CResourceCleanupExit exit -> (
      List.iter
        (fun cleanup ->
          (match resource_cleanup_pop_slot_stmt cleanup with
          | Some pop -> emit_line ctx (pop ^ ";")
          | None -> ());
          emit_stmt ctx cleanup)
        exit.rce_cleanups;
      match exit.rce_exit with
      | ResourceBreak -> emit_line ctx "break;"
      | ResourceContinue -> emit_line ctx "continue;")
  | CBreak -> emit_line ctx "break;"
  | CContinue -> emit_line ctx "continue;"
  | CAssign (v, rhs) ->
      if v.vname = "_" then begin
        emit_discard_stmt ctx rhs
      end
      else begin
        emit_indent ctx;
        emit ctx (escape_c_ident (Var.to_c_name v));
        emit ctx " = ";
        emit_expr ctx rhs;
        emitln ctx ";"
      end
  (* See phase 2.5 note above. *)
  | CMatchArms _ ->
      Core_error.errorf Core_error.Emit e.loc
        ~hint:
          "run with --check-invariants to confirm core_match eliminated every \
           CMatchArms; if so, this arm shape is the gap in classify_arms"
        "raw CMatchArms survived match-compilation (emit invariant violated)"
  | CMatch (scrut, tree) ->
      let scrut_ty_c = type_to_c ctx scrut.ty in
      let id = fresh_temp ctx in
      let scrut_name = Printf.sprintf "__scrut_%d" id in
      emit_indent ctx;
      emit ctx (Printf.sprintf "%s %s = " scrut_ty_c scrut_name);
      emit_expr ctx scrut;
      emitln ctx ";";
      emit_ctree_stmt ctx scrut_name scrut.ty tree;
      if match_scrutinee_needs_release ctx scrut then
        emit_line ctx
          (Printf.sprintf "%s;" (release_value_call ctx scrut.ty scrut_name))
  (* ---- RC ops in statement position: emit as separate statements ---- *)
  | CDup (v, ty, body) ->
      if type_requires_retain ctx ty then
        emit_line ctx
          (Printf.sprintf "%s;"
             (retain_value_call ctx ty
                (escape_c_ident (var_ref_c_name_for_type ctx v ty))));
      emit_stmt ctx body
  | CDrop (v, ty, body) ->
      if type_requires_release ctx ty then
        emit_line ctx
          (Printf.sprintf "%s;" (cancellation_cleanup_pop_slot_stmt v));
      if type_requires_release ctx ty then
        emit_line ctx
          (Printf.sprintf "%s;"
             (release_value_call ctx ty
                (escape_c_ident (var_ref_c_name_for_type ctx v ty))));
      emit_stmt ctx body
  (* ---- Everything else: evaluate and discard the result ----
     For function calls, arithmetic, etc., emit the expression followed
     by a semicolon. The result is discarded.
     [CDup]/[CDrop] are handled explicitly above — NOT in this catch-all —
     so emission produces proper sequential statements rather than
     wrapping them in GCC statement-expressions. *)
  (* ---- Concurrency (statement context) ---- *)
  | CConcurrent block -> emit_concurrent_block ctx block
  | CConcurrentFor cf -> emit_concurrent_for ctx cf
  | CDetach detach -> emit_detach_stmt ctx detach e.loc
  | CTensorRawWrite w ->
      emit_indent ctx;
      emit ctx (escape_c_ident (Var.to_c_name w.trw_view));
      emit ctx "[";
      emit_expr ctx w.trw_index;
      emit ctx "] = ";
      emit_expr ctx w.trw_value;
      emitln ctx ";"
  (* ---- Everything else: evaluate and discard the result ---- *)
  | CLit _ | CVar _ | CBin _ | CUn _ | CLog _ | CCall _ | CTensorRawRead _
  | CStringByteRead _ | CStringByteWrite _ | CStringByteCopy _ | CStringSetLen _
  | CField _ | CTuple _ | CTupleConstruct _ | CList _ | CListConstruct _
  | CListAlloc _ | CListGet _ | CVector _ | CTensorLiteral _ | CDict _
  | CDictConstruct _ | CSetAlloc _ | CRecord _ | CRecordConstruct _
  | CRecordUpdate _ | CRange _ | CLambda _ | CClosureCreate _ | CStringInterp _
  | CDebugBlock _ | CCast _ | CUnbox _ | CUnboxTyped _ | CBox _ | CBoxTyped _
  | CUnionConstruct _ | CListHandoff _ | CTailrecLoop _ | CTailrecRecur _ ->
      emit_indent ctx;
      emit_expr ctx e;
      emitln ctx ";"

and emit_discard_stmt (ctx : Core_emit_context.t) (rhs : core) : unit =
  match rhs.desc with
  | CVar v when type_requires_release ctx rhs.ty ->
      emit_line ctx
        (Printf.sprintf "%s;"
           (release_value_call ctx rhs.ty
              (escape_c_ident (var_ref_c_name_for_type ctx v rhs.ty))))
  | _ when type_requires_release ctx rhs.ty ->
      let tmp = Printf.sprintf "__discard_%d" (fresh_temp ctx) in
      emit_indent ctx;
      emit ctx (type_to_c ctx rhs.ty);
      emit ctx " ";
      emit ctx tmp;
      emit ctx " = ";
      emit_expr ctx rhs;
      emitln ctx ";";
      emit_line ctx (Printf.sprintf "%s;" (release_value_call ctx rhs.ty tmp))
  | _ ->
      emit_indent ctx;
      emit ctx "(void)(";
      emit_expr ctx rhs;
      emitln ctx ");"

(* --- §4. emit_boxed -------------------------------------------------------- *)

(** Emit a Core expression, boxing its value to [void*] if necessary.
    Used for container elements (tuples, lists) which need uniformly
    boxed storage.

    - Float/Float32/Float16 → dedicated [blorp_box_float*] calls
    - Pointer types → pass through unchanged
    - Primitives (Int, Bool, Char, sized ints) cast via [(void* )(long)] *)
and emit_boxed (ctx : Core_emit_context.t) (e : core) : unit =
  match e.desc with
  | CBox _ | CBoxTyped _ -> emit_expr ctx e
  | _ -> (
      match classify_for_boxing ctx e.ty e.loc with
      | BoxFloat ->
          emit ctx "blorp_box_float(";
          emit_expr ctx e;
          emit ctx ")"
      | BoxFloat32 ->
          emit ctx "blorp_box_float32(";
          emit_expr ctx e;
          emit ctx ")"
      | BoxFloat16 ->
          emit ctx "blorp_box_float16(";
          emit_expr ctx e;
          emit ctx ")"
      | BoxInt128 ->
          emit ctx "blorp_box_int128(";
          emit_expr ctx e;
          emit ctx ")"
      | BoxUInt128 ->
          emit ctx "blorp_box_uint128(";
          emit_expr ctx e;
          emit ctx ")"
      | BoxVoid ->
          emit ctx "({ ";
          emit_stmt ctx e;
          emit ctx "(void*)0; })"
      | BoxPointer -> emit_expr ctx e
      | BoxPrim ->
          emit ctx "(void*)(long)(";
          emit_expr ctx e;
          emit ctx ")"
      | BoxStruct type_name ->
          let tmp = Printf.sprintf "__box_%d" (fresh_temp ctx) in
          emit ctx (Printf.sprintf "({ %s %s = " type_name tmp);
          emit_expr ctx e;
          emit ctx
            (Printf.sprintf "; blorp_box_struct(&%s, sizeof(%s)); })" tmp
               type_name))
(* ============================================================================
   Decl-level emission (Phase 1.2c)
   ============================================================================

   [emit_func] produces a C function definition from a [core_func].
   [emit_value_record] produces a typedef + [_make] constructor for
   stack-allocated records (record_is_value = true).
   [emit_program] walks a [core_program] emitting each declaration.

   Heap records, union types, closures, and traits remain deferred
   — [emit_decl] raises [not_yet] for them. *)

(* --- §5. Preamble + type declarations ------------------------------------- *)

(** Emit a for loop. For Phase 1.2b we only support iteration over a
    literal [CRange(lo, hi)] — produces a simple C [for (long var = lo;
    var < hi; var++)] loop. Collection iteration (lists, strings, dicts)
    requires the iterator protocol and is deferred. *)

and emit_preamble (ctx : Core_emit_context.t) : unit =
  emit_line ctx "#include <stdbool.h>";
  emit_line ctx "#include <stdio.h>";
  emit_line ctx "#include <stdlib.h>";
  emit ctx "\n"

(** Emit [#include "header.h"] for each unique header named in a
    [foreign(include: ...)] block. Without this, foreign function names
    appear in call sites without prototypes and the C compiler reports
    them as undeclared. Source-relative header search paths are carried
    separately as pipeline metadata; the emitter keeps generated C portable
    by preserving the user's include spelling rather than absolutizing it. *)
and emit_foreign_includes (ctx : Core_emit_context.t) (prog : core_program) :
    unit =
  let seen = Hashtbl.create 8 in
  let ordered = ref [] in
  let rec visit d =
    match d.cd_desc with
    | CDFunc f -> (
        match f.cf_kind with
        | CFForeign { includes; _ } ->
            List.iter
              (fun h ->
                if not (Hashtbl.mem seen h) then begin
                  Hashtbl.add seen h ();
                  ordered := h :: !ordered
                end)
              includes
        | _ -> ())
    | CDPrivate inner -> visit inner
    | _ -> ()
  in
  List.iter visit prog;
  if !ordered <> [] then begin
    List.iter
      (fun h -> emit_line ctx (Printf.sprintf "#include \"%s\"" h))
      (List.rev !ordered);
    emit ctx "\n"
  end

(** Emit a value-struct typedef plus its [Name_make] constructor.
    Produces:
    {v
    typedef struct { T1 f1; T2 f2; ... } Name;
    static inline Name Name_make(T1 f1, T2 f2, ...) { ... }
    v} *)
and emit_value_record (ctx : Core_emit_context.t) (r : Ast.record_decl) : unit =
  let n = r.record_name in
  (* typedef struct { ... } Name; *)
  emit ctx "typedef struct { ";
  List.iter
    (fun (fd : Ast.field_decl) ->
      emit ctx
        (Printf.sprintf "%s %s; "
           (type_to_c ctx fd.field_type)
           (escape_c_ident fd.field_name)))
    r.record_fields;
  emit ctx (Printf.sprintf "} %s;\n" n);
  emit_named_generated_stack_option_typedef ctx n n;
  (* static inline Name Name_make(params) { Name __r = { fields }; return __r; } *)
  emit ctx (Printf.sprintf "static inline %s %s_make(" n n);
  if r.record_fields = [] then emit ctx "void"
  else
    List.iteri
      (fun i (fd : Ast.field_decl) ->
        if i > 0 then emit ctx ", ";
        emit ctx
          (Printf.sprintf "%s %s"
             (type_to_c ctx fd.field_type)
             (escape_c_ident fd.field_name)))
      r.record_fields;
  emit ctx ") { ";
  emit ctx (Printf.sprintf "%s __r = { " n);
  List.iteri
    (fun i (fd : Ast.field_decl) ->
      if i > 0 then emit ctx ", ";
      emit ctx (escape_c_ident fd.field_name))
    r.record_fields;
  emit ctx " }; return __r; }\n\n"

(** Emit a heap record: typedef struct, optional destructor, constructor.

    Heap records have a [blorp_Object header] as their first field for
    ARC management. Type-layout registration decides whether the record
    needs a generated destructor; emission only consumes that policy. *)
and emit_heap_record (ctx : Core_emit_context.t) (r : Ast.record_decl) : unit =
  let n = r.record_name in
  let record_ty_c = type_to_c ctx (Ast.TyNamed (n, [])) in
  let destructor_name =
    source_emitted_destructor_name ~loc:(loc_for_record_decl r) ~type_name:n
      (heap_record_destructor_policy ctx r)
  in
  let erased_fields =
    r.record_fields
    |> List.mapi (fun i (fd : Ast.field_decl) -> (i, fd))
    |> List.filter (fun (_, (fd : Ast.field_decl)) ->
        is_erased_record_field ctx fd.field_type)
  in
  (* typedef struct Name { blorp_Object header; fields... } Name; *)
  emitln ctx (Printf.sprintf "typedef struct %s {" n);
  ctx.indent <- ctx.indent + 1;
  emit_line ctx "blorp_Object header;";
  if erased_fields <> [] then emit_line ctx "unsigned long release_mask;";
  List.iter
    (fun (fd : Ast.field_decl) ->
      emit_line ctx
        (Printf.sprintf "%s %s;"
           (type_to_c ctx fd.field_type)
           (escape_c_ident fd.field_name)))
    r.record_fields;
  ctx.indent <- ctx.indent - 1;
  emitln ctx (Printf.sprintf "} %s;" n);
  emit ctx "\n";
  (* Destructor policy is computed during type-layout registration. *)
  (match destructor_name with
  | None -> ()
  | Some destroy_name ->
      let rc_fields =
        r.record_fields
        |> List.filter (fun (fd : Ast.field_decl) ->
            (not (is_erased_record_field ctx fd.field_type))
            && type_requires_release ctx fd.field_type)
      in
      emitln ctx (Printf.sprintf "static void %s(void* obj) {" destroy_name);
      ctx.indent <- ctx.indent + 1;
      emit_line ctx (Printf.sprintf "%s* __rec = (%s*)obj;" n n);
      if rc_fields = [] && erased_fields = [] then emit_line ctx "(void)__rec;";
      List.iter
        (fun (fd : Ast.field_decl) ->
          let c_f = escape_c_ident fd.field_name in
          emit_line ctx
            (Printf.sprintf
               "if (__rec->%s) blorp_release((blorp_Object*)__rec->%s);" c_f c_f))
        rc_fields;
      List.iter
        (fun (i, (fd : Ast.field_decl)) ->
          let c_f = escape_c_ident fd.field_name in
          emit_line ctx
            (Printf.sprintf
               "if ((__rec->release_mask & %dUL) && __rec->%s) \
                blorp_release((blorp_Object*)__rec->%s);"
               (1 lsl i) c_f c_f))
        erased_fields;
      ctx.indent <- ctx.indent - 1;
      emitln ctx "}";
      emit ctx "\n");
  (* Constructor: Name* Name_make(params) { alloc + init + return }
     The declared return uses [type_to_c] so runtime-backed ABI records such as
     MemStats return their runtime C typedef at the constructor boundary. *)
  emit ctx (Printf.sprintf "%s %s_make(" record_ty_c n);
  if r.record_fields = [] then emit ctx "void"
  else
    List.iteri
      (fun i (fd : Ast.field_decl) ->
        if i > 0 then emit ctx ", ";
        emit ctx
          (Printf.sprintf "%s %s"
             (type_to_c ctx fd.field_type)
             (escape_c_ident fd.field_name)))
      r.record_fields;
  if erased_fields <> [] then begin
    if r.record_fields <> [] then emit ctx ", ";
    emit ctx "unsigned long release_mask"
  end;
  emitln ctx ") {";
  ctx.indent <- ctx.indent + 1;
  emit_line ctx
    (Printf.sprintf "%s* __rec = (%s*)blorp_alloc(sizeof(%s));" n n n);
  emit_line ctx (Printf.sprintf "BLORP_TAG(__rec, \"%s\");" n);
  (match destructor_name with
  | None -> ()
  | Some destroy_name ->
      emit_line ctx
        (Printf.sprintf "BLORP_SET_DESTRUCTOR(__rec, %s);" destroy_name));
  if erased_fields <> [] then
    emit_line ctx "__rec->release_mask = release_mask;";
  List.iter
    (fun (fd : Ast.field_decl) ->
      let c_f = escape_c_ident fd.field_name in
      emit_line ctx (Printf.sprintf "__rec->%s = %s;" c_f c_f))
    r.record_fields;
  emit_line ctx (Printf.sprintf "return (%s)__rec;" record_ty_c);
  ctx.indent <- ctx.indent - 1;
  emitln ctx "}";
  emit ctx "\n"

(** Emit an enum type: [#define] per variant. Enums are plain integers. *)
and emit_enum_type (ctx : Core_emit_context.t) (t : Ast.type_decl) : unit =
  List.iter
    (fun (v : Ast.variant) ->
      emit_line ctx
        (Printf.sprintf "#define %s %dL" (variant_c_name v) v.variant_tag))
    t.type_variants;
  emit_named_generated_stack_option_typedef ctx t.type_name "long";
  let enum_c = Codegen_names.sanitize_c_ident t.type_name in
  let enum_to_string = Printf.sprintf "__blorp_enum_to_string_%s" enum_c in
  let vector_to_string = Printf.sprintf "blorp_vector_to_string_%s" enum_c in
  emit_line ctx
    (Printf.sprintf "static blorp_String* %s(long v) {" enum_to_string);
  emit_line ctx "    switch (v) {";
  List.iter
    (fun (v : Ast.variant) ->
      emit_line ctx
        (Printf.sprintf "        case %s: return blorp_string_literal(%S);"
           (variant_c_name v) v.variant_name))
    t.type_variants;
  emit_line ctx "        default: return blorp_to_string(v);";
  emit_line ctx "    }";
  emit_line ctx "}";
  emit_line ctx
    (Printf.sprintf "blorp_String* %s(blorp_Vector* v) {" vector_to_string);
  emit_line ctx
    (Printf.sprintf "    return blorp_vector_to_string_packed_enum(v, %s);"
       enum_to_string);
  emit_line ctx "}";
  emit ctx "\n"

(** Emit a union/variant type: struct with header + tag + release_mask
    + data union, TAG_ defines, destructor, and constructor functions. *)
and emit_union_type (ctx : Core_emit_context.t) (t : Ast.type_decl) : unit =
  let n = t.type_name in
  let destructor_name =
    source_emitted_destructor_name ~loc:(loc_for_type_decl t) ~type_name:n
      (union_destructor_policy ctx t)
  in
  (* typedef struct Name { header; tag; release_mask; union { ... } data; } Name; *)
  emitln ctx (Printf.sprintf "typedef struct %s {" n);
  ctx.indent <- ctx.indent + 1;
  emit_line ctx "blorp_Object header;";
  emit_line ctx "int tag;";
  emit_line ctx "unsigned long release_mask;";
  emit_line ctx "union {";
  ctx.indent <- ctx.indent + 1;
  List.iter
    (fun (v : Ast.variant) ->
      if v.variant_fields <> [] then begin
        emit_indent ctx;
        emit ctx "struct { ";
        List.iteri
          (fun i _ft -> emit ctx (Printf.sprintf "void* field%d; " i))
          v.variant_fields;
        emitln ctx (Printf.sprintf "} %s;" v.variant_name)
      end
      else emit_line ctx (Printf.sprintf "char %s;" v.variant_name))
    t.type_variants;
  ctx.indent <- ctx.indent - 1;
  emit_line ctx "} data;";
  ctx.indent <- ctx.indent - 1;
  emitln ctx (Printf.sprintf "} %s;" n);
  emit ctx "\n";
  (* TAG_ defines *)
  List.iter
    (fun (v : Ast.variant) ->
      emit_line ctx
        (Printf.sprintf "#define %s %d" (variant_tag_c_name n v) v.variant_tag))
    t.type_variants;
  emit ctx "\n";
  (* Destructor policy is computed during type-layout registration. *)
  (match destructor_name with
  | None -> ()
  | Some destroy_name ->
      let rc_indices_by_variant =
        List.map
          (fun (v : Ast.variant) ->
            let rc_indices =
              List.mapi (fun i ft -> (i, ft)) v.variant_fields
              |> List.filter (fun (_, ft) ->
                  boxed_value_needs_release ctx ft v.variant_loc)
            in
            (v, rc_indices))
          t.type_variants
      in
      let has_destructor_body =
        List.exists
          (fun (_, rc_indices) -> rc_indices <> [])
          rc_indices_by_variant
      in
      emitln ctx (Printf.sprintf "static void %s(void* obj) {" destroy_name);
      ctx.indent <- ctx.indent + 1;
      emit_line ctx (Printf.sprintf "%s* self = (%s*)obj;" n n);
      if not has_destructor_body then emit_line ctx "(void)self;";
      List.iter
        (fun (v, rc_indices) ->
          if rc_indices <> [] then begin
            emit_indent ctx;
            emitln ctx
              (Printf.sprintf "if (self->tag == %s) {" (variant_tag_c_name n v));
            ctx.indent <- ctx.indent + 1;
            List.iter
              (fun (i, _) ->
                emit_line ctx
                  (Printf.sprintf
                     "if ((self->release_mask & %dUL) && \
                      self->data.%s.field%d) \
                      blorp_release(self->data.%s.field%d);"
                     (1 lsl i) v.variant_name i v.variant_name i))
              rc_indices;
            ctx.indent <- ctx.indent - 1;
            emit_line ctx "}"
          end)
        rc_indices_by_variant;
      ctx.indent <- ctx.indent - 1;
      emitln ctx "}";
      emit ctx "\n");
  (* Constructor functions for non-empty variants.

     The release_mask is passed as a trailing parameter rather than
     baked in at emission time. Generic union fields are typed [TyVar T]
     at the constructor site, where source-value ownership can differ from
     boxed-storage ownership; using a constant declaration-time mask would
     produce a destroy-time [blorp_release(42)] when [Option[Int]] is destroyed
     (the Int payload is non-null and "looks like" a heap pointer).
     Each call site already knows the real per-arg types post-mono, so
     the mask is computed there — see [constructor_release_mask] in
     [emit_expr]'s [CCall] case. *)
  List.iter
    (fun (v : Ast.variant) ->
      if v.variant_fields <> [] then begin
        (* A4.5: constructors-with-fields mangle through
         [variant_def_id] to match the DefId scheme used by regular
         user functions. Nullary constructors keep their bare name
         because they're emitted as C [#define]s, not functions — the
         C preprocessor can't expand a [__def_N_None] macro at
         non-macro reference sites. *)
        let ctor_c =
          match v.variant_def_id with
          | Some id -> Codegen_names.mangle_by_def_id id v.variant_name
          | None -> v.variant_name
        in
        emit ctx (Printf.sprintf "%s* %s(" n ctor_c);
        List.iteri
          (fun i _ft ->
            if i > 0 then emit ctx ", ";
            emit ctx (Printf.sprintf "void* field%d" i))
          v.variant_fields;
        emitln ctx ", unsigned long release_mask) {";
        ctx.indent <- ctx.indent + 1;
        emit_line ctx
          (Printf.sprintf "%s* __vc = (%s*)blorp_alloc(sizeof(%s));" n n n);
        emit_line ctx (Printf.sprintf "BLORP_TAG(__vc, \"%s\");" n);
        (match destructor_name with
        | None -> ()
        | Some destroy_name ->
            emit_line ctx
              (Printf.sprintf "BLORP_SET_DESTRUCTOR(__vc, %s);" destroy_name));
        emit_line ctx
          (Printf.sprintf "__vc->tag = %s;" (variant_tag_c_name n v));
        emit_line ctx "__vc->release_mask = release_mask;";
        List.iteri
          (fun i _ ->
            emit_line ctx
              (Printf.sprintf "__vc->data.%s.field%d = field%d;" v.variant_name
                 i i))
          v.variant_fields;
        emit_line ctx "return __vc;";
        ctx.indent <- ctx.indent - 1;
        emitln ctx "}";
        emit ctx "\n"
      end
      else begin
        let ctor_c = variant_c_name v in
        let instance_c = singleton_instance_c_name v in
        let init_c = singleton_init_c_name v in
        emitln ctx (Printf.sprintf "static %s %s;" n instance_c);
        emitln ctx
          (Printf.sprintf "__attribute__((constructor)) static void %s(void) {"
             init_c);
        ctx.indent <- ctx.indent + 1;
        emit_line ctx
          (Printf.sprintf
             "atomic_store_explicit(&%s.header.refcount, \
              BLORP_IMMORTAL_REFCOUNT, memory_order_relaxed);"
             instance_c);
        emit_line ctx
          (Printf.sprintf "%s.tag = %s;" instance_c (variant_tag_c_name n v));
        ctx.indent <- ctx.indent - 1;
        emitln ctx "}";
        emitln ctx (Printf.sprintf "#define %s ((%s*)&%s)" ctor_c n instance_c);
        emit ctx "\n"
      end)
    t.type_variants

(* --- §6. Top-level declarations ------------------------------------------- *)

(** Emit a global variable declaration.

    Constant literals get inline initialization. Non-constant
    initializers are emitted as [static Type name;] — runtime
    initialization via [__blorp_init_globals] is handled at
    pipeline wiring time. *)
and emit_global_var (ctx : Core_emit_context.t) (v : core_var) : unit =
  let ty_c = type_to_c ctx v.cv_ty in
  (* Globals keep their bare (flatten-prefixed) names in A4.2.
     They are [static] in C so there's no cross-TU symbol collision,
     and [CVar] references to them stay bare as well. A5 can switch
     both sides together once scope tracking is in place. *)
  let name_c = escape_c_ident (Var.to_c_name v.cv_name) in
  (* Only primitive literals are C static initializers. String literals
     expand to a lazy [blorp_string_literal(...)] expression, so route
     those through [__blorp_init_globals]. *)
  match v.cv_init.desc with
  | CLit lit when is_c_static_literal lit ->
      emit_indent ctx;
      emit ctx (Printf.sprintf "static %s %s = " ty_c name_c);
      gen_literal ctx lit;
      emitln ctx ";";
      emit ctx "\n"
  | _ ->
      emit_line ctx (Printf.sprintf "static %s %s;" ty_c name_c);
      emit ctx "\n"

(** Emit an impl block: each method as a function with a mangled
    name of the form [Trait_method_Type]. *)
and emit_impl (ctx : Core_emit_context.t) (i : core_impl) : unit =
  if has_type_vars i.ci_for_type then ()
  else
    let type_name =
      match Codegen_types.type_key_for_impl i.ci_for_type with
      | Some n -> n
      | None -> "Unknown"
    in
    List.iter
      (fun (m : core_func) ->
        let mangled =
          Printf.sprintf "%s_%s_%s" i.ci_trait m.cf_name type_name
        in
        (* A4.2: record the trait-method's def_id under its mangled
       source name so hardcoded trait-ptr emission sites (e.g.
       [blorp_set_new_custom] for user-hashable keys) can mangle
       the pointer to match this decl's C symbol. *)
        Hashtbl.replace ctx.trait_impl_def_ids mangled m.cf_def_id;
        emit_func ctx { m with cf_name = mangled })
      i.ci_methods

and profile_name_for_func (f : core_func) : string =
  match f.cf_module with
  | Some m -> Printf.sprintf "%s (%s)" f.cf_name (Filename.basename m)
  | None -> f.cf_name

and emit_profile_start (ctx : Core_emit_context.t) (name : string) : unit =
  if ctx.profile then
    emit_line ctx (Printf.sprintf "blorp_profile_start(%S);" name)

and emit_profile_end (ctx : Core_emit_context.t) (name : string) : unit =
  if ctx.profile then
    emit_line ctx (Printf.sprintf "blorp_profile_end(%S);" name)

(** Emit a function definition: signature, body, closing brace.

    For non-void return types, the body is emitted as [return EXPR;]
    using [emit_expr] — this wraps any [CLet]/[CSeq] in GCC statement
    expressions, which is valid under clang/gcc.

    For void return types, the body is emitted as a statement via
    [emit_stmt], no return wrapper.

    Foreign/builtin functions ([cf_body = None]) are skipped entirely
    — the emitter is not responsible for generating foreign decls. *)
and emit_func (ctx : Core_emit_context.t) (f : core_func) : unit =
  match (f.cf_body, f.cf_kind) with
  | None, _ -> ()
  | _, _ when f.cf_type_params <> [] -> ()
  | Some body, CFClosureBody ca ->
      (* Hoisted lambda function — emit with void* closure ABI. Use
         the mangled C name; static closures and CClosureCreate refer
         to the function via the same mangled name. *)
      let c_name = func_c_name f in
      let cl =
        {
          Core_emit_context.cl_name = c_name;
          cl_profile_name = profile_name_for_func f;
          cl_params = ca.ca_params;
          cl_captures = ca.ca_captures;
          cl_body = body;
          cl_return_ty = f.cf_return_ty;
          cl_task_abi = ca.ca_task_abi;
        }
      in
      emit_lambda_body ctx cl;
      (* Static closure for zero-capture lambdas *)
      if ca.ca_captures = [] then
        emitln ctx
          (Printf.sprintf
             "static blorp_Closure __sc_%s = { { %s, BLORP_ALLOC_CLASS_DIRECT, \
              0 }, (void*)%s, NULL, 0, 0 };"
             (escape_c_ident c_name) "BLORP_IMMORTAL_REFCOUNT"
             (escape_c_ident c_name))
  | Some body, _ ->
      if f.cf_name = "main" then emit_main_func ctx f body
      else begin
        let profile_name = profile_name_for_func f in
        let ret_ty_c = type_to_c ctx f.cf_return_ty in
        let is_void = ret_ty_c = "void" in
        let params_c =
          if f.cf_params = [] then "void"
          else
            String.concat ", "
              (List.map
                 (fun (p : core_param) ->
                   Printf.sprintf "%s %s" (type_to_c ctx p.cp_ty)
                     (escape_c_ident (Var.to_c_name p.cp_name)))
                 f.cf_params)
        in
        emit ctx
          (Printf.sprintf "%s %s(%s) {\n" ret_ty_c
             (escape_c_ident (func_c_name f))
             params_c);
        ctx.indent <- ctx.indent + 1;
        (match body.desc with
        | CTailrecLoop loop -> emit_tailrec_loop ctx f loop
        | _ ->
            emit_profile_start ctx profile_name;
            if is_void then begin
              emit_stmt ctx body;
              emit_profile_end ctx profile_name
            end
            else if ctx.profile then begin
              let body =
                expr_with_expected_type_for_constructors ctx body f.cf_return_ty
              in
              emit_indent ctx;
              emit ctx (Printf.sprintf "%s __blorp_profile_result = " ret_ty_c);
              emit_expr ctx body;
              emitln ctx ";";
              emit_profile_end ctx profile_name;
              emit_line ctx "return __blorp_profile_result;"
            end
            else begin
              let body =
                expr_with_expected_type_for_constructors ctx body f.cf_return_ty
              in
              emit_indent ctx;
              emit ctx "return ";
              emit_expr ctx body;
              emitln ctx ";"
            end);
        ctx.indent <- ctx.indent - 1;
        emit ctx "}\n\n"
      end

and emit_main_func (ctx : Core_emit_context.t) (f : core_func) (body : core) :
    unit =
  let arg_name =
    match f.cf_params with
    | p :: _ -> escape_c_ident (Var.to_c_name p.cp_name)
    | [] -> "args"
  in
  let has_return =
    match normalize_type f.cf_return_ty with
    | Ast.TyNamed ("Void", []) -> false
    | Ast.TyNamed ("Int", []) -> true
    | _ -> false
  in
  emitln ctx (Printf.sprintf "int main(int argc, char** argv) {");
  ctx.indent <- ctx.indent + 1;
  emit_line ctx "__blorp_init_globals();";
  emit_line ctx "setlinebuf(stdout);";
  if ctx.profile then begin
    emit_line ctx "blorp_profile_enable();";
    emit_line ctx "atexit(blorp_profile_report);"
  end;
  emit_line ctx
    (Printf.sprintf "blorp_List* %s = blorp_list_new(argc);" arg_name);
  emit_line ctx
    (Printf.sprintf "blorp_list_init_elem_release(%s, blorp_elem_release_fn);"
       arg_name);
  emit_line ctx
    (Printf.sprintf
       "for (int __i = 0; __i < argc; __i++) %s = blorp_list_append_owned(%s, \
        (void*)blorp_string_create(argv[__i]));"
       arg_name arg_name);
  let body_is_void = is_void_ty body.ty in
  if has_return && body_is_void then
    Core_error.errorf Core_error.Emit body.loc
      ~hint:
        "explicit `main -> Int` must end with an Int expression; omit the \
         return type or write `-> Void` for implicit exit code 0"
      "main declared return type Int but body has type Void";
  emit_profile_start ctx "main";
  if has_return && not body_is_void then begin
    emit_indent ctx;
    emit ctx "long __blorp_main_result = (long)";
    emit_expr ctx body;
    emitln ctx ";";
    emit_profile_end ctx "main";
    emit_line ctx (Printf.sprintf "blorp_release(%s);" arg_name);
    emit_line ctx "return (int)__blorp_main_result;"
  end
  else begin
    emit_stmt ctx body;
    emit_profile_end ctx "main";
    emit_line ctx (Printf.sprintf "blorp_release(%s);" arg_name);
    emit_line ctx "return 0;"
  end;
  ctx.indent <- ctx.indent - 1;
  emit ctx "}\n\n"

(** Emit a single top-level declaration.

    Functions and value-struct records are fully supported. Heap
    records (with ARC header), union types, global vars, and impls
    raise [not_yet] — they'll land in a later phase. Imports,
    traits, and type aliases are no-ops at the C level (they carry
    compile-time information only). *)
and emit_decl (ctx : Core_emit_context.t) (d : core_decl) : unit =
  match d.cd_desc with
  | CDFunc f -> emit_func ctx f
  | CDRecord _ -> () (* emitted in preamble *)
  | CDType _ -> () (* emitted in preamble *)
  | CDVar v -> emit_global_var ctx v
  | CDImpl i -> emit_impl ctx i
  | CDTrait _ | CDImport _ | CDTypeAlias _ -> ()
  | CDPrivate inner -> emit_decl ctx inner

(** Emit a whole program: preamble (includes) + every declaration in
    source order. *)
and emit_program ?(embed_runtime = false) (ctx : Core_emit_context.t)
    (prog : core_program) : unit =
  emit_preamble ctx;
  if embed_runtime then begin
    emit ctx Runtime.runtime_code;
    emit ctx "\n"
  end;
  emit_foreign_includes ctx prog;
  emit_builtin_generated_stack_option_typedefs ctx;
  (* Register type info so downstream emission works correctly *)
  List.iter
    (fun d ->
      let rec collect_ctors d =
        match d.cd_desc with
        | CDType t ->
            List.iter
              (fun (v : Ast.variant) ->
                Hashtbl.replace ctx.constructor_names v.variant_name ();
                Hashtbl.replace ctx.constructor_c_names v.variant_name
                  (variant_c_name v);
                Hashtbl.replace ctx.constructor_c_names_by_type
                  (t.type_name, v.variant_name)
                  (variant_c_name v);
                Hashtbl.replace ctx.ctor_parent_types v.variant_name t.type_name)
              t.type_variants
        | CDPrivate inner -> collect_ctors inner
        | _ -> ()
      in
      collect_ctors d)
    prog;
  List.iter
    (fun d ->
      let rec collect_globals d =
        match d.cd_desc with
        | CDFunc f when f.cf_body <> None ->
            Hashtbl.replace ctx.global_names f.cf_name ();
            Hashtbl.replace ctx.global_def_ids f.cf_def_id ()
        | CDFunc f when match f.cf_kind with CFForeign _ -> true | _ -> false ->
            Hashtbl.replace ctx.global_names f.cf_name ();
            Hashtbl.replace ctx.global_def_ids f.cf_def_id ()
        | CDImpl i ->
            List.iter
              (fun (m : core_func) ->
                Hashtbl.replace ctx.global_names m.cf_name ();
                Hashtbl.replace ctx.global_def_ids m.cf_def_id ())
              i.ci_methods
        | CDPrivate inner -> collect_globals inner
        | _ -> ()
      in
      collect_globals d)
    prog;
  (* Primary registration of type-aliases, value-records, and enum
     types happens in [Core_flatten.register_types] before
     monomorphization, so [Core_mono] and [Core_specialize] can
     classify types correctly. This late loop is an idempotent safety
     net for direct callers of [emit_program] (e.g. unit tests) that
     bypass [Core_pipeline]. *)
  List.iter
    (fun d ->
      let rec seed d =
        match d.cd_desc with
        | CDRecord r ->
            Hashtbl.replace ctx.record_decls r.record_name r;
            if r.record_is_value then
              Hashtbl.replace ctx.reg.value_records r.record_name ()
            else
              Codegen_types.register_heap_record_type ctx.reg r.record_name
                ~destructor:
                  (Codegen_types.GeneratedDestructor (r.record_name ^ "_destroy"))
        | CDType t when t.type_is_enum ->
            Codegen_types.register_enum_type ctx.reg t.type_name t.type_variants
        | CDType t when not t.type_is_builtin ->
            Codegen_types.register_union_type ctx.reg t.type_name
              ~destructor:
                (Codegen_types.GeneratedDestructor (t.type_name ^ "_destroy"))
        | CDTypeAlias a ->
            Hashtbl.replace ctx.reg.type_aliases a.alias_name
              (Ast.type_param_names a.alias_type_params, a.alias_target)
        | CDPrivate inner -> seed inner
        | _ -> ()
      in
      seed d)
    prog;
  List.iter
    (fun d ->
      let rec refine d =
        match d.cd_desc with
        | CDRecord r when (not r.record_is_value) && not r.record_is_builtin ->
            Codegen_types.register_heap_record_type ctx.reg r.record_name
              ~destructor:
                (Core_layout_type.record_destructor_policy
                   ~phase:Core_error.Emit ~reg:ctx.reg r)
        | CDType t when (not t.type_is_enum) && not t.type_is_builtin ->
            Codegen_types.register_union_type ctx.reg t.type_name
              ~destructor:
                (Core_layout_type.union_destructor_policy ~phase:Core_error.Emit
                   ~reg:ctx.reg t)
        | CDPrivate inner -> refine inner
        | _ -> ()
      in
      refine d)
    prog;
  (* Register concrete trait method def-ids before emitting any function body.
     Some expression emit paths synthesize function pointers directly
     (e.g. List[T].to_string callback dispatch), so they cannot depend on
     source-order visits through [emit_impl]. *)
  List.iter
    (fun d ->
      let rec register d =
        match d.cd_desc with
        | CDImpl i when not (has_type_vars i.ci_for_type) -> (
            match Codegen_types.type_key_for_impl i.ci_for_type with
            | Some type_name ->
                List.iter
                  (fun (m : core_func) ->
                    let source_name =
                      Printf.sprintf "%s_%s_%s" i.ci_trait m.cf_name type_name
                    in
                    Hashtbl.replace ctx.trait_impl_def_ids source_name
                      m.cf_def_id)
                  i.ci_methods
            | None -> ())
        | CDPrivate inner -> register inner
        | _ -> ()
      in
      register d)
    prog;
  (* Emit all type declarations early (before function forward declarations
     and function bodies that may reference constructors/tags) *)
  List.iter
    (fun d ->
      let rec emit_type d =
        match d.cd_desc with
        (* [{builtin}] / [= builtin] markers MUST be checked before any
         storage-class guard fires. A future [struct Foo {builtin}]
         carries both [record_is_builtin] and [record_is_value]; without
         the builtin guard first, the value-record path would try to
         emit C for a type whose representation lives in the runtime. *)
        | CDRecord r when r.record_is_builtin -> ()
        | CDType t when t.type_is_builtin -> ()
        | CDRecord r when r.record_is_value -> emit_value_record ctx r
        | CDRecord r -> emit_heap_record ctx r
        | CDType t when t.type_is_enum -> emit_enum_type ctx t
        | CDType t -> emit_union_type ctx t
        | CDPrivate inner -> emit_type inner
        | _ -> ()
      in
      emit_type d)
    prog;
  (* Forward declarations for heap records and union types *)
  let rec collect_type_names acc = function
    | [] -> List.rev acc
    | { cd_desc = CDRecord r; _ } :: rest
      when (not r.record_is_value) && not r.record_is_builtin ->
        collect_type_names (r.record_name :: acc) rest
    | { cd_desc = CDType t; _ } :: rest
      when (not t.type_is_enum) && not t.type_is_builtin ->
        collect_type_names (t.type_name :: acc) rest
    | { cd_desc = CDPrivate inner; _ } :: rest ->
        collect_type_names acc (inner :: rest)
    | _ :: rest -> collect_type_names acc rest
  in
  let type_names = collect_type_names [] prog in
  if type_names <> [] then begin
    List.iter
      (fun name ->
        emit_line ctx (Printf.sprintf "typedef struct %s %s;" name name))
      type_names;
    emit ctx "\n"
  end;
  (* Function forward declarations *)
  let rec collect_func_fwds acc = function
    | [] -> List.rev acc
    | { cd_desc = CDFunc f; _ } :: rest
      when f.cf_body <> None && f.cf_name <> "main" && f.cf_type_params = [] ->
        collect_func_fwds (f :: acc) rest
    | { cd_desc = CDImpl i; _ } :: rest ->
        if has_type_vars i.ci_for_type then collect_func_fwds acc rest
        else
          let type_name =
            match Codegen_types.type_key_for_impl i.ci_for_type with
            | Some n -> n
            | None -> "Unknown"
          in
          let mangled =
            List.map
              (fun (m : core_func) ->
                {
                  m with
                  cf_name =
                    Printf.sprintf "%s_%s_%s" i.ci_trait m.cf_name type_name;
                })
              i.ci_methods
          in
          collect_func_fwds (List.rev_append mangled acc) rest
    | { cd_desc = CDPrivate inner; _ } :: rest ->
        collect_func_fwds acc (inner :: rest)
    | _ :: rest -> collect_func_fwds acc rest
  in
  let func_fwds = collect_func_fwds [] prog in
  if func_fwds <> [] then begin
    List.iter
      (fun (f : core_func) ->
        (* A4.2: forward decls must use the same mangled C name as the
         definition. [func_c_name] handles the [main] special-case and
         reads [cf_def_id] otherwise. *)
        let c_name = func_c_name f in
        match f.cf_kind with
        | CFClosureBody ca ->
            (* Closure-ABI: void* fn(void*, void*, ...) *)
            let ret =
              if is_void_ty f.cf_return_ty && not ca.ca_task_abi then "void"
              else "void*"
            in
            emit_indent ctx;
            emit ctx (Printf.sprintf "%s %s(void*" ret (escape_c_ident c_name));
            List.iter (fun _ -> emit ctx ", void*") ca.ca_params;
            emitln ctx ");";
            if ca.ca_captures = [] then
              emit_line ctx
                (Printf.sprintf "static blorp_Closure __sc_%s;"
                   (escape_c_ident c_name))
        | CFUser | CFBuiltin | CFForeign _ ->
            let ret_c = type_to_c ctx f.cf_return_ty in
            let params_c =
              if f.cf_params = [] then "void"
              else
                String.concat ", "
                  (List.map
                     (fun (p : core_param) -> type_to_c ctx p.cp_ty)
                     f.cf_params)
            in
            emit_line ctx
              (Printf.sprintf "%s %s(%s);" ret_c (escape_c_ident c_name)
                 params_c))
      func_fwds;
    emit ctx "\n"
  end;
  (* Emit code to a secondary buffer so string literals are discovered *)
  let code_buf = Buffer.create 4096 in
  let saved_output = ctx.output in
  ctx.output <- code_buf;
  List.iter (emit_decl ctx) prog;
  emit_collected_lambdas ctx;
  emit_global_init ctx prog;
  ctx.output <- saved_output;
  (* Emit string literal pool (must precede function bodies) *)
  if Buffer.length ctx.string_literals_buffer > 0 then begin
    emit ctx (Buffer.contents ctx.string_literals_buffer);
    emit ctx "\n"
  end;
  (* Forward declarations for lambda body functions and static closures *)
  List.iter
    (fun (cl : Core_emit_context.collected_lambda) ->
      let ret =
        if is_void_ty cl.cl_return_ty && not cl.cl_task_abi then "void"
        else "void*"
      in
      emit_indent ctx;
      emit ctx (Printf.sprintf "%s %s(void*" ret cl.cl_name);
      List.iteri (fun _ _ -> emit ctx ", void*") cl.cl_params;
      emitln ctx ");";
      if cl.cl_captures = [] then
        emit_line ctx
          (Printf.sprintf "static blorp_Closure __sc_%s;" cl.cl_name))
    (List.rev ctx.collected_lambdas);
  (* Forward decl for __blorp_init_globals — main always calls it *)
  emit_line ctx "void __blorp_init_globals(void);";
  (* Append the code *)
  emit ctx (Buffer.contents code_buf)

(* --- §7. For-loop variants ------------------------------------------------ *)

and emit_for_loop (ctx : Core_emit_context.t) (binder : loop_binder)
    (iter : core) (body : core) : unit =
  match iter.desc with
  | CRange (lo, hi) ->
      let cvar = escape_c_ident (Var.to_c_name binder.loop_var) in
      let id = fresh_temp ctx in
      let start_tmp = Printf.sprintf "__range_start_%d" id in
      let end_tmp = Printf.sprintf "__range_end_%d" id in
      let step_tmp = Printf.sprintf "__range_step_%d" id in
      let lit_int = function
        | { desc = CLit (Ast.LitInt n); _ } -> Some n
        | _ -> None
      in
      let is_static_forward =
        match (lit_int lo, lit_int hi) with
        | Some lo, Some hi -> Int64.compare lo hi <= 0
        | _ -> false
      in
      let is_forward_proven =
        is_static_forward
        ||
        match binder.loop_range_direction with
        | RangeForwardOnly -> true
        | RangeMayRunBackward -> false
      in
      emit_indent ctx;
      emit ctx (Printf.sprintf "long %s = " start_tmp);
      emit_expr ctx lo;
      emitln ctx ";";
      emit_indent ctx;
      emit ctx (Printf.sprintf "long %s = " end_tmp);
      emit_expr ctx hi;
      emitln ctx ";";
      if is_forward_proven then begin
        emit_indent ctx;
        emit ctx "for (long ";
        emit ctx cvar;
        emit ctx
          (Printf.sprintf " = %s; %s < %s; %s++) {" start_tmp cvar end_tmp cvar)
      end
      else begin
        emit_line ctx
          (Printf.sprintf "long %s = (%s <= %s) ? 1L : -1L;" step_tmp start_tmp
             end_tmp);
        emit_indent ctx;
        emit ctx "for (long ";
        emit ctx cvar;
        emit ctx
          (Printf.sprintf " = %s; %s != %s; %s += %s) {" start_tmp cvar end_tmp
             cvar step_tmp)
      end;
      emitln ctx "";
      ctx.indent <- ctx.indent + 1;
      emit_stmt ctx body;
      ctx.indent <- ctx.indent - 1;
      emit_indent ctx;
      emitln ctx "}"
  | _ -> (
      match normalize_type iter.ty with
      | Ast.TyNamed ("List", _) -> emit_for_list ctx binder iter body
      | Ast.TyNamed ("Set", _) ->
          (* Sets are hash-table-with-linked-list — the flat-list iter
             would read garbage. [emit_for_set] walks the insertion-
             order [first → next_order] chain. *)
          emit_for_set ctx binder iter body
      | Ast.TyNamed ("String", _) -> emit_for_string ctx binder iter body
      | Ast.TyNamed ("Dict", _) -> emit_for_dict ctx binder iter body
      | Ast.TyNamed ("Channel", _) -> emit_for_channel ctx binder iter body
      | Ast.TyNamed ("Stream", _) -> emit_for_stream ctx binder iter body
      | Ast.TyNamed ("Range", []) -> emit_for_range_value ctx binder iter body
      | ty when is_tensor_type ctx ty -> emit_for_list ctx binder iter body
      | Ast.TyNamed ("Bytes", _) -> emit_for_list ctx binder iter body
      | ty ->
          Core_error.errorf Core_error.Emit iter.loc
            ~hint:
              "for-loop iterable validation belongs in typecheck/lowering; if \
               this Core was compiler-produced, run with --check-invariants to \
               find the earlier phase that accepted it"
            "unsupported for-loop iterable reached C emission: %s"
            (Types.type_to_string ty))

and emit_for_stream (ctx : Core_emit_context.t) (binder : loop_binder)
    (iter : core) (body : core) : unit =
  let id = fresh_temp ctx in
  let iter_c = Printf.sprintf "__stream_iter_%d" id in
  let value_c = Printf.sprintf "__stream_value_%d" id in
  let var_c = escape_c_ident (Var.to_c_name binder.loop_var) in
  let elem_ty = binder.loop_ty in
  let iter_needs_release = boxed_expr_transfers_ownership ctx iter in
  emit_indent ctx;
  emit ctx (Printf.sprintf "blorp_Stream* %s = (blorp_Stream*)" iter_c);
  emit_expr ctx iter;
  emitln ctx ";";
  emit_line ctx (Printf.sprintf "void* %s = NULL;" value_c);
  emit_indent ctx;
  emit ctx
    (Printf.sprintf
       "for (; blorp_stream_next_raw(%s, &%s); \
        blorp_stream_release_pulled_if_owned(%s, %s), %s = NULL) {"
       iter_c value_c iter_c value_c value_c);
  emitln ctx "";
  ctx.indent <- ctx.indent + 1;
  emit_unbox_decl ctx var_c value_c elem_ty;
  emit_stmt ctx body;
  ctx.indent <- ctx.indent - 1;
  emit_indent ctx;
  emitln ctx "}";
  emit_line ctx
    (Printf.sprintf
       "if (%s != NULL) blorp_stream_release_pulled_if_owned(%s, %s);" value_c
       iter_c value_c);
  if iter_needs_release then
    emit_line ctx (Printf.sprintf "%s;" (release_value_call ctx iter.ty iter_c))

and emit_for_range_value (ctx : Core_emit_context.t) (binder : loop_binder)
    (iter : core) (body : core) : unit =
  let cvar = escape_c_ident (Var.to_c_name binder.loop_var) in
  let id = fresh_temp ctx in
  let range_tmp = Printf.sprintf "__range_iter_%d" id in
  let step_tmp = Printf.sprintf "__range_step_%d" id in
  emit_indent ctx;
  emit ctx (Printf.sprintf "%s %s = " (type_to_c ctx iter.ty) range_tmp);
  emit_expr ctx iter;
  emitln ctx ";";
  emit_line ctx
    (Printf.sprintf "long %s = (%s.start <= %s.end) ? 1L : -1L;" step_tmp
       range_tmp range_tmp);
  emit_indent ctx;
  emit ctx
    (Printf.sprintf "for (long %s = %s.start; %s != %s.end; %s += %s) {" cvar
       range_tmp cvar range_tmp cvar step_tmp);
  emitln ctx "";
  ctx.indent <- ctx.indent + 1;
  emit_stmt ctx body;
  ctx.indent <- ctx.indent - 1;
  emit_indent ctx;
  emitln ctx "}"

and emit_for_list (ctx : Core_emit_context.t) (binder : loop_binder)
    (iter : core) (body : core) : unit =
  (* Dimension peeling (Phase 4.1): [for row in m:] on a 2D+ tensor yields
     row sub-tensors. A copying row-slice is emitted via
     [blorp_tensor_slice_row]; the zero-copy view form is Phase 4.4. *)
  match tensor_type_of_expr ctx iter with
  | Some { dims = _ :: _ :: _; _ } -> emit_for_tensor_peel ctx binder iter body
  | _ -> emit_for_list_flat ctx binder iter body

and emit_for_tensor_element_decl (ctx : Core_emit_context.t) (var_c : string)
    (iter_c : string) (idx_c : string) (elem_ty : Ast.type_expr) : unit =
  let elem_ty = Core_layout_type.canonical_type ~reg:ctx.reg elem_ty in
  let scalar_read helper =
    emit_line ctx
      (Printf.sprintf "%s %s = (%s)%s(%s, %s);" (type_to_c ctx elem_ty) var_c
         (type_to_c ctx elem_ty) helper iter_c idx_c)
  in
  match
    Core_layout_type.tensor_runtime_read_helper_of_type ~reg:ctx.reg elem_ty
  with
  | Some helper -> scalar_read helper.trrh_c_helper
  | None -> (
      match Core_layout_type.tensor_element_storage ~reg:ctx.reg elem_ty with
      | Core_layout_type.TensorElementInlineStruct c_ty ->
          emit_line ctx
            (Printf.sprintf
               "%s %s; if (__builtin_expect(%s->storage_mode == \
                BLORP_VECTOR_STORAGE_INLINE && %s->elem_size == sizeof(%s), \
                1)) { memcpy(&%s, (char*)%s->data + %s * sizeof(%s), \
                sizeof(%s)); } else { void* __raw = %s->data[%s]; %s = \
                (*(%s*)((char*)__raw + sizeof(blorp_Object))); }"
               c_ty var_c iter_c iter_c c_ty var_c iter_c idx_c c_ty c_ty iter_c
               idx_c var_c c_ty)
      | Core_layout_type.TensorElementRawScalar _
      | Core_layout_type.TensorElementPackedBits _
      | Core_layout_type.TensorElementBoxed ->
          emit_unbox_decl ctx var_c
            (Printf.sprintf "%s->data[%s]" iter_c idx_c)
            elem_ty)

and emit_for_list_flat (ctx : Core_emit_context.t) (binder : loop_binder)
    (iter : core) (body : core) : unit =
  let id = fresh_temp ctx in
  let iter_c = Printf.sprintf "__iter_%d" id in
  let len_c = Printf.sprintf "__len_%d" id in
  let idx_c = Printf.sprintf "__i_%d" id in
  let var_c = escape_c_ident (Var.to_c_name binder.loop_var) in
  let elem_ty = binder.loop_ty in
  (* [blorp_Vector] and [blorp_List] have distinct struct layouts — Vector
     carries [elem_size] + [storage_mode] + padding between [elem_release]
     and [data[]], so [data[]] sits 8 bytes further in. Declaring a Vector
     iter as [blorp_List*] and reading [->data[0]] pulls from inside those
     extra fields and returns garbage. Pick the correct container type. *)
  let iter_c_type =
    if is_tensor_type ctx iter.ty then "blorp_Vector*" else "blorp_List*"
  in
  let is_array_iter = is_tensor_type ctx iter.ty in
  emit_indent ctx;
  emit ctx (Printf.sprintf "%s %s = " iter_c_type iter_c);
  emit_expr ctx iter;
  emitln ctx ";";
  emit_line ctx (Printf.sprintf "long %s = %s->len;" len_c iter_c);
  let emit_loop emit_element_decl =
    emit_indent ctx;
    emit ctx
      (Printf.sprintf "for (long %s = 0; %s < %s; %s++) {" idx_c idx_c len_c
         idx_c);
    emitln ctx "";
    ctx.indent <- ctx.indent + 1;
    emit_element_decl ();
    emit_stmt ctx body;
    ctx.indent <- ctx.indent - 1;
    emit_indent ctx;
    emitln ctx "}"
  in
  let emit_list_element_decl () =
    let layout = list_storage_layout_of_type ctx iter.ty iter.loc in
    match layout.lsl_slots with
    | ListInlineStructStorage c_ty ->
        emit_indent ctx;
        emit ctx (Printf.sprintf "%s %s; " c_ty var_c);
        emit_list_inline_struct_dynamic_load ctx ~list_tmp:iter_c ~idx_tmp:idx_c
          ~out_tmp:var_c ~struct_ty:c_ty ~bounds:ListBoundsProven;
        emitln ctx ""
    | ListInlineStorage width ->
        let width_bytes = inline_storage_width_bytes width in
        let bits_tmp = Printf.sprintf "__iter_bits_%d" (fresh_temp ctx) in
        emit_line ctx
          (Printf.sprintf
             "uintptr_t %s = 0; memcpy(&%s, (char*)%s->data + %s * %d, %d);"
             bits_tmp bits_tmp iter_c idx_c width_bytes width_bytes);
        emit_unbox_decl ctx var_c (Printf.sprintf "(void*)%s" bits_tmp) elem_ty
    | ListPointerStorage ->
        emit_unbox_decl ctx var_c
          (Printf.sprintf "blorp_list_get(%s, %s)" iter_c idx_c)
          elem_ty
  in
  if is_array_iter then
    match
      tensor_for_in_proven_raw_storage ctx iter.loc elem_ty
        binder.loop_source_storage
    with
    | Some raw ->
        let raw_c = Printf.sprintf "__iter_raw_%d" (fresh_temp ctx) in
        emit_line ctx
          (Printf.sprintf "%s %s = (%s)%s->data;" raw.tras_pointer_c_type raw_c
             raw.tras_pointer_c_type iter_c);
        emit_loop (fun () ->
            emit_line ctx
              (Printf.sprintf "%s %s = (%s)%s[%s];" (type_to_c ctx elem_ty)
                 var_c (type_to_c ctx elem_ty) raw_c idx_c))
    | None ->
        emit_loop (fun () ->
            emit_for_tensor_element_decl ctx var_c iter_c idx_c elem_ty)
  else emit_loop emit_list_element_decl

(** Emit [for row in m:] where m is a 2D+ Tensor. Each iteration binds
    [row] to a freshly-allocated copy of the flat row-range via
    [blorp_tensor_slice_row(mat, idx, row_size, result_first_dim)]. The
    copy is released at the end of the body.

    Row-size derivation from [T[#M, #D2, #D3, ...]]:
      row_size = product of #D2..#Dn
      result_first_dim = #D2 (the leading dim of the peeled sub-tensor)

    All dims must be compile-time known ([TyConstInt]). Generic-dim
    shapes reach this path with [TyVar] dims and need the runtime-derived
    row_size = capacity/len fallback path — deferred to 4.4 alongside
    view-based iteration. *)
and emit_for_tensor_peel (ctx : Core_emit_context.t) (binder : loop_binder)
    (iter : core) (body : core) : unit =
  let id = fresh_temp ctx in
  let iter_c = Printf.sprintf "__iter_%d" id in
  let len_c = Printf.sprintf "__len_%d" id in
  let idx_c = Printf.sprintf "__i_%d" id in
  let var_c = escape_c_ident (Var.to_c_name binder.loop_var) in
  let elem_ty, inner_dims =
    match tensor_type_of_expr ctx iter with
    | Some { elem_ty; dims = _outer :: rest; _ } -> (elem_ty, rest)
    | _ ->
        Core_error.errorf Core_error.Emit iter.loc
          ~hint:
            "tensor peeling is only valid for Tensor/Vector/Matrix types with \
             at least two dimensions"
          "tensor peel emission requires a 2D+ tensor, got %s"
          (Types.type_to_string (normalize_type iter.ty))
  in
  (* Compute row_size (product of all inner dims) and result_first_dim (the
     first inner dim = the `len` of the peeled sub-tensor).

     2D with generic dims: inner_dims = [TyVar "#N"] (length 1). row_size and
       result_first_dim are both that dim — runtime derive as capacity/len.
     3D+ all-literal: compute both at compile time.
     3D+ with any non-literal inner dim: we'd need to split out the first
       dim separately from the inner-product. The tensor only carries flat
       capacity and outer-len at runtime, so there's no way to recover #D2
       independently without additional shape metadata. Error rather than
       silently producing a peeled sub-tensor with the wrong [len] — which
       would make later iteration / subscript access read/write the wrong
       elements. *)
  let all_literal =
    List.for_all (function Ast.TyConstInt _ -> true | _ -> false) inner_dims
  in
  let row_size_c, result_first_dim_c =
    match inner_dims with
    | [ Ast.TyConstInt n ] -> (Printf.sprintf "%dL" n, Printf.sprintf "%dL" n)
    | [ _ ] ->
        (* 2D with a single generic inner dim: row_size = cols = capacity/len. *)
        ( Printf.sprintf "(%s->capacity / %s->len)" iter_c iter_c,
          Printf.sprintf "(%s->capacity / %s->len)" iter_c iter_c )
    | Ast.TyConstInt d :: rest when all_literal ->
        let prod =
          List.fold_left
            (fun acc ty ->
              match ty with Ast.TyConstInt n -> acc * n | _ -> acc)
            d rest
        in
        (Printf.sprintf "%dL" prod, Printf.sprintf "%dL" d)
    | _ :: _ ->
        (* 3D+ with at least one non-literal inner dim — row_size and
           result_first_dim diverge and we can't compute result_first_dim
           from runtime flat metadata alone. *)
        Core_error.errorf (Core_error.Stage Core_stage.Final) iter.loc
          ~hint:
            "peeling a 3D+ tensor with non-literal inner dimensions needs \
             per-dim shape metadata the runtime doesn't carry today. \
             Monomorphize the caller to concrete inner dims, or wait for Phase \
             4.5's TensorView which will carry full shape info."
          "cannot peel %d-D tensor with non-literal inner dims"
          (List.length inner_dims + 1)
    | [] ->
        (* 1D — should have routed to emit_for_list_flat, not here. *)
        Core_error.errorf (Core_error.Stage Core_stage.Final) iter.loc
          "emit_for_tensor_peel invoked on 1D tensor; should have routed to \
           emit_for_list_flat"
  in
  let peeled_ty =
    match inner_dims with
    | [] -> elem_ty
    | _ -> Types.ty_array elem_ty inner_dims
  in
  let peeled_c = type_to_c ctx peeled_ty in
  emit_indent ctx;
  emit ctx (Printf.sprintf "blorp_Vector* %s = " iter_c);
  emit_expr ctx iter;
  emitln ctx ";";
  emit_line ctx (Printf.sprintf "long %s = %s->len;" len_c iter_c);
  emit_indent ctx;
  emit ctx
    (Printf.sprintf "for (long %s = 0; %s < %s; %s++) {" idx_c idx_c len_c idx_c);
  emitln ctx "";
  ctx.indent <- ctx.indent + 1;
  emit_line ctx
    (Printf.sprintf "%s %s = (%s)blorp_tensor_slice_row(%s, %s, %s, %s);"
       peeled_c var_c peeled_c iter_c idx_c row_size_c result_first_dim_c);
  emit_stmt ctx body;
  emit_line ctx (Printf.sprintf "blorp_release(%s);" var_c);
  ctx.indent <- ctx.indent - 1;
  emit_indent ctx;
  emitln ctx "}"

and emit_for_string (ctx : Core_emit_context.t) (binder : loop_binder)
    (iter : core) (body : core) : unit =
  let id = fresh_temp ctx in
  let iter_c = Printf.sprintf "__str_iter_%d" id in
  let idx_c = Printf.sprintf "__si_%d" id in
  let var_c = escape_c_ident (Var.to_c_name binder.loop_var) in
  emit_indent ctx;
  emit ctx (Printf.sprintf "blorp_String* %s = (blorp_String*)" iter_c);
  emit_expr ctx iter;
  emitln ctx ";";
  emit_indent ctx;
  emit ctx
    (Printf.sprintf "for (long %s = 0; %s < %s->len; ) {" idx_c idx_c iter_c);
  emitln ctx "";
  ctx.indent <- ctx.indent + 1;
  emit_line ctx
    (Printf.sprintf "int32_t %s = blorp_string_next_codepoint(%s, &%s);" var_c
       iter_c idx_c);
  emit_stmt ctx body;
  ctx.indent <- ctx.indent - 1;
  emit_indent ctx;
  emitln ctx "}"

and emit_for_dict (ctx : Core_emit_context.t) (binder : loop_binder)
    (iter : core) (body : core) : unit =
  let id = fresh_temp ctx in
  let iter_c = Printf.sprintf "__dict_iter_%d" id in
  let idx_c = Printf.sprintf "__di_%d" id in
  let slot_c = Printf.sprintf "__dslot_%d" id in
  let var_c = escape_c_ident (Var.to_c_name binder.loop_var) in
  let key_ty =
    match normalize_type iter.ty with
    | Ast.TyNamed ("Dict", [ kt; _ ]) -> kt
    | ty ->
        Core_error.errorf Core_error.Emit iter.loc
          ~hint:
            "dictionary iteration must carry both key and value type arguments \
             before code emission"
          "dict iteration requires Dict[K, V], got %s" (Types.type_to_string ty)
  in
  let key_c = type_to_c ctx key_ty in
  let binder_ty = normalize_type binder.loop_ty in
  emit_indent ctx;
  emit ctx (Printf.sprintf "blorp_Dict* %s = (blorp_Dict*)" iter_c);
  emit_expr ctx iter;
  emitln ctx ";";
  emit_indent ctx;
  emitln ctx
    (Printf.sprintf "for (long %s = 0; %s < %s->order_len; %s++) {" idx_c idx_c
       iter_c idx_c);
  ctx.indent <- ctx.indent + 1;
  emit_line ctx (Printf.sprintf "long %s = %s->order[%s];" slot_c iter_c idx_c);
  emit_line ctx (Printf.sprintf "if (%s < 0) continue;" slot_c);
  (match binder_ty with
  | Ast.TyTuple [ _; _ ] ->
      emit_line ctx
        (Printf.sprintf
           "blorp_Tuple* %s = blorp_tuple_new(2, %s->keys[%s], %s->values[%s]);"
           var_c iter_c slot_c iter_c slot_c);
      emit_stmt ctx body;
      emit_line ctx (Printf.sprintf "blorp_release(%s);" var_c)
  | _ ->
      emit_line ctx
        (Printf.sprintf "%s %s = (%s)%s->keys[%s];" key_c var_c key_c iter_c
           slot_c);
      emit_stmt ctx body);
  ctx.indent <- ctx.indent - 1;
  emit_indent ctx;
  emitln ctx "}"

(** Emit [for elem in ch:] for a [Channel[T]] by receiving until the channel
    is closed and drained. Channel buffers own retained RC elements; each
    received RC value is released after the loop body consumes that iteration
    binding. *)
and emit_for_channel (ctx : Core_emit_context.t) (binder : loop_binder)
    (iter : core) (body : core) : unit =
  let id = fresh_temp ctx in
  let iter_c = Printf.sprintf "__chan_iter_%d" id in
  let raw_c = Printf.sprintf "__chan_val_%d" id in
  let var_c = escape_c_ident (Var.to_c_name binder.loop_var) in
  let elem_ty = binder.loop_ty in
  emit_indent ctx;
  emit ctx (Printf.sprintf "blorp_Channel* %s = (blorp_Channel*)" iter_c);
  emit_expr ctx iter;
  emitln ctx ";";
  emit_line ctx (Printf.sprintf "void* %s = NULL;" raw_c);
  emit_indent ctx;
  emitln ctx
    (Printf.sprintf "while (blorp_channel_recv_raw(%s, &%s)) {" iter_c raw_c);
  ctx.indent <- ctx.indent + 1;
  emit_unbox_decl ctx var_c raw_c elem_ty;
  emit_stmt ctx body;
  if type_requires_release ctx elem_ty then
    emit_line ctx
      (Printf.sprintf "if (%s) blorp_release((blorp_Object*)%s);" var_c var_c);
  ctx.indent <- ctx.indent - 1;
  emit_indent ctx;
  emitln ctx "}"

(** Emit [for elem in s:] for a [Set[T]] by walking its insertion-order
    linked list. Each [blorp_SetEntry] has a [key] (the element) and a
    [next_order] pointer; the set carries [first] and [last] anchors.

    [Set] cannot share the [emit_for_list] flat-array path because its
    runtime layout is hash-table-with-linked-list — there's no [data[]]
    field to index. The previous routing through [emit_for_list] cast
    [blorp_Set*] to [blorp_List*] and read garbage from misaligned
    fields, producing wrong-but-not-crashing iteration.

    {b Mutation contract}: the body may reassign the source variable
    (e.g. [s = S.add(s, ...)]) and the loop continues to iterate the
    {i original} set captured at loop entry. The emitter takes a
    [blorp_retain] on the iter pointer to force any concurrent
    [S.add] / [S.remove] on the unique-refcount original to COW
    instead of mutating in place — otherwise [blorp_set_add] would
    append to [last->next_order] during the walk and the loop would
    never terminate. The matching [blorp_release] runs at loop-bottom.
    [break] / [return] inside the body skip the release (matching
    [emit_for_tensor_peel]'s existing limitation); Perceus's
    scope-exit tracking covers Core-level variables, not these raw
    C temps. *)
and emit_for_set (ctx : Core_emit_context.t) (binder : loop_binder)
    (iter : core) (body : core) : unit =
  let id = fresh_temp ctx in
  let iter_c = Printf.sprintf "__set_iter_%d" id in
  let entry_c = Printf.sprintf "__set_entry_%d" id in
  let var_c = escape_c_ident (Var.to_c_name binder.loop_var) in
  let elem_ty = binder.loop_ty in
  emit_indent ctx;
  emit ctx (Printf.sprintf "blorp_Set* %s = (blorp_Set*)" iter_c);
  emit_expr ctx iter;
  emitln ctx ";";
  emit_line ctx (Printf.sprintf "blorp_retain(%s);" iter_c);
  emit_indent ctx;
  emitln ctx
    (Printf.sprintf
       "for (blorp_SetEntry* %s = %s->first; %s != NULL; %s = %s->next_order) {"
       entry_c iter_c entry_c entry_c entry_c);
  ctx.indent <- ctx.indent + 1;
  emit_unbox_decl ctx var_c (Printf.sprintf "%s->key" entry_c) elem_ty;
  emit_stmt ctx body;
  ctx.indent <- ctx.indent - 1;
  emit_indent ctx;
  emitln ctx "}";
  emit_line ctx (Printf.sprintf "blorp_release(%s);" iter_c)

(* [collect_var_types], [find_var_type], [accessor_is_enum], and
   [tag_test_str] moved to [Core_emit_util] (Phase 5.1) — all are
   non-recursive helpers that only read ctx fields. Callers reach
   them via [open Core_emit_util] at the top of this file. *)

(* --- §8. Pattern-match decision-tree emit -------------------------------- *)

(** Emit a [ctree] in expression context — compact, single-line
    format. Each leaf assigns its body to [result_name]. Phase 5.1
    step 3 moved the body to [Core_emit_pattern.assign]; this
    wrapper re-binds the mutual-recursion partners. *)
and emit_ctree_assign (ctx : Core_emit_context.t) (scrut_name : string)
    (scrut_ty : Ast.type_expr) (result_name : string) (tree : ctree) : unit =
  Core_emit_pattern.assign ~emit_expr ~emit_ctree_assign ctx scrut_name scrut_ty
    result_name tree

(** Emit a [ctree] in statement context — multi-line, indented
    format. Leaf bodies run via [emit_stmt]. Body lives in
    [Core_emit_pattern.stmt]. *)
and emit_ctree_stmt (ctx : Core_emit_context.t) (scrut_name : string)
    (scrut_ty : Ast.type_expr) (tree : ctree) : unit =
  Core_emit_pattern.stmt ~emit_stmt ~emit_ctree_stmt ctx scrut_name scrut_ty
    tree

(* --- §8b. Tail-recursive unmanaged self-call emit ------------------------- *)

(** Return [args] when [e] is a direct self-call to [f]. DefId is the
    authoritative identity; the name fallback keeps older unresolved fixtures
    working during focused unit tests. *)
and self_tail_call_args (f : core_func) (e : core) : core list option =
  match e.desc with
  | CCall (CKUser (_, Some id), _, args) when id = f.cf_def_id -> Some args
  | CCall (CKUser (name, None), _, args) when name = f.cf_name -> Some args
  | _ -> None

and ctree_has_tail_self_call (f : core_func) (tree : ctree) : bool =
  match tree with
  | CTLeaf { ct_body; _ } -> expr_has_tail_self_call f ct_body
  | CTFail -> false
  | CTSwitchTag { cts_cases; cts_default; _ } ->
      List.exists (fun (_, sub) -> ctree_has_tail_self_call f sub) cts_cases
      || Option.fold ~none:false ~some:(ctree_has_tail_self_call f) cts_default
  | CTSwitchLit { ctl_cases; ctl_default; _ } ->
      List.exists (fun (_, sub) -> ctree_has_tail_self_call f sub) ctl_cases
      || ctree_has_tail_self_call f ctl_default
  | CTSwitchLen { ctl_len_cases; ctl_len_geq; ctl_len_default; _ } ->
      List.exists (fun (_, sub) -> ctree_has_tail_self_call f sub) ctl_len_cases
      || Option.fold ~none:false
           ~some:(fun (_, sub) -> ctree_has_tail_self_call f sub)
           ctl_len_geq
      || Option.fold ~none:false
           ~some:(ctree_has_tail_self_call f)
           ctl_len_default

and expr_has_tail_self_call (f : core_func) (e : core) : bool =
  match self_tail_call_args f e with
  | Some _ -> true
  | None -> (
      match e.desc with
      | CLet (_, body)
      | CBorrowLet (_, body)
      | CSeq (_, body)
      | CDup (_, _, body)
      | CDrop (_, _, body) ->
          expr_has_tail_self_call f body
      | CIf (_, then_e, else_e) ->
          expr_has_tail_self_call f then_e || expr_has_tail_self_call f else_e
      | CMatch (_, tree) -> ctree_has_tail_self_call f tree
      | _ -> false)

and tailrec_type_is_known_unmanaged (ctx : Core_emit_context.t)
    (ty : Ast.type_expr) : bool =
  try not (type_requires_release ctx ty) with Core_error.Core_error _ -> false

and tailrec_list_type = function
  | Ast.TyNamed ("List", [ _ ]) -> true
  | _ -> false

and tailrec_list_param_plan (ctx : Core_emit_context.t) (f : core_func) :
    (int * core_param) option =
  let rec collect i acc = function
    | [] -> List.rev acc
    | (p : core_param) :: rest ->
        let acc' =
          if tailrec_list_type (normalize_type p.cp_ty) then (i, p) :: acc
          else acc
        in
        collect (i + 1) acc' rest
  in
  match collect 0 [] f.cf_params with
  | [ (list_index, list_param) ] ->
      let rec non_list_params_unmanaged i = function
        | [] -> true
        | (p : core_param) :: rest ->
            (i = list_index || tailrec_type_is_known_unmanaged ctx p.cp_ty)
            && non_list_params_unmanaged (i + 1) rest
      in
      if
        f.cf_name <> "main"
        && tailrec_type_is_known_unmanaged ctx f.cf_return_ty
        && non_list_params_unmanaged 0 f.cf_params
      then Some (list_index, list_param)
      else None
  | _ -> None

and tailrec_nth_opt xs n =
  let rec go i = function
    | [] -> None
    | x :: _ when i = n -> Some x
    | _ :: rest -> go (i + 1) rest
  in
  if n < 0 then None else go 0 xs

and tailrec_core_uses_var (target : var) (e : core) : bool =
  let here = match e.desc with CVar v -> Var.equal v target | _ -> false in
  here
  || Core.fold_immediate_children
       (fun found child -> found || tailrec_core_uses_var target child)
       false e

and tailrec_list_self_call_spread_binding (f : core_func) (list_index : int)
    (bindings : (var * accessor) list) (e : core) :
    (var * int * core list) option =
  match self_tail_call_args f e with
  | None -> None
  | Some args -> (
      match tailrec_nth_opt args list_index with
      | Some { desc = CVar spread_var; _ } -> (
          match
            List.find_opt
              (fun (v, acc) ->
                Var.equal v spread_var
                &&
                match acc with
                | AccListSpread (AccRoot, _) -> true
                | _ -> false)
              bindings
          with
          | Some (_, AccListSpread (AccRoot, offset))
            when List.for_all
                   (fun (i, arg) ->
                     i = list_index
                     || not (tailrec_core_uses_var spread_var arg))
                   (List.mapi (fun i arg -> (i, arg)) args) ->
              Some (spread_var, offset, args)
          | _ -> None)
      | _ -> None)

and tailrec_list_accessor_supported = function
  | AccRoot -> true
  | AccListElem (AccRoot, _) | AccListSpread (AccRoot, _) -> true
  | AccVariantField (parent, _, _) | AccTupleField (parent, _) ->
      tailrec_list_accessor_supported parent
  | AccListElem (parent, _) -> tailrec_list_accessor_supported parent
  | AccListSpread _ -> false

and tailrec_list_ctree_supported (f : core_func) (list_index : int)
    (tree : ctree) : bool =
  match tree with
  | CTLeaf { ct_bindings; ct_body } ->
      List.for_all
        (fun (_, acc) -> tailrec_list_accessor_supported acc)
        ct_bindings
      && ((not (expr_has_tail_self_call f ct_body))
         || Option.is_some
              (tailrec_list_self_call_spread_binding f list_index ct_bindings
                 ct_body))
  | CTFail -> true
  | CTSwitchTag { cts_scrut; cts_cases; cts_default } ->
      tailrec_list_accessor_supported cts_scrut
      && List.for_all
           (fun (_, sub) -> tailrec_list_ctree_supported f list_index sub)
           cts_cases
      && Option.fold ~none:true
           ~some:(tailrec_list_ctree_supported f list_index)
           cts_default
  | CTSwitchLit { ctl_scrut; ctl_cases; ctl_default } ->
      tailrec_list_accessor_supported ctl_scrut
      && List.for_all
           (fun (_, sub) -> tailrec_list_ctree_supported f list_index sub)
           ctl_cases
      && tailrec_list_ctree_supported f list_index ctl_default
  | CTSwitchLen
      { ctl_len_scrut = AccRoot; ctl_len_cases; ctl_len_geq; ctl_len_default }
    ->
      List.for_all
        (fun (_, sub) -> tailrec_list_ctree_supported f list_index sub)
        ctl_len_cases
      && Option.fold ~none:true
           ~some:(fun (_, sub) -> tailrec_list_ctree_supported f list_index sub)
           ctl_len_geq
      && Option.fold ~none:true
           ~some:(tailrec_list_ctree_supported f list_index)
           ctl_len_default
  | CTSwitchLen _ -> false

and tailrec_cursor_index_expr (cursor_name : string) (offset : int) : string =
  if offset = 0 then cursor_name
  else Printf.sprintf "(%s + %dL)" cursor_name offset

and render_tailrec_list_accessor (ctx : Core_emit_context.t)
    ~(list_name : string) ~(cursor_name : string) (acc : accessor) : string =
  let rec go = function
    | AccRoot -> list_name
    | AccListElem (AccRoot, idx) ->
        Printf.sprintf "blorp_list_get((blorp_List*)%s, %s)" list_name
          (tailrec_cursor_index_expr cursor_name idx)
    | AccListSpread (AccRoot, idx) ->
        Printf.sprintf "blorp_list_drop((blorp_List*)%s, %s)" list_name
          (tailrec_cursor_index_expr cursor_name idx)
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
    | AccTupleField (parent, idx) ->
        Printf.sprintf "((blorp_Tuple*)%s)->elem[%d]" (go parent) idx
    | AccListElem (parent, idx) ->
        Printf.sprintf "blorp_list_get((blorp_List*)%s, %d)" (go parent) idx
    | AccListSpread (parent, idx) ->
        Printf.sprintf "blorp_list_drop((blorp_List*)%s, %d)" (go parent) idx
  in
  go acc

and emit_tailrec_list_binding (ctx : Core_emit_context.t)
    ~(list_ty : Ast.type_expr) ~(list_name : string) ~(cursor_name : string)
    ~(loc : Ast.loc) (v : var) (acc : accessor) (var_ty : Ast.type_expr) : unit
    =
  let var_c = escape_c_ident (Var.to_c_name v) in
  match acc with
  | AccListElem (AccRoot, idx) -> (
      let idx_c = tailrec_cursor_index_expr cursor_name idx in
      let layout = list_storage_layout_of_type ctx list_ty loc in
      match layout.lsl_slots with
      | ListInlineStorage width ->
          let width_bytes = inline_storage_width_bytes width in
          let bits_tmp = Printf.sprintf "__tailrec_bits_%d" (fresh_temp ctx) in
          emit_line ctx
            (Printf.sprintf
               "uintptr_t %s = 0; memcpy(&%s, (char*)((blorp_List*)%s)->data + \
                %s * %d, %d);"
               bits_tmp bits_tmp list_name idx_c width_bytes width_bytes);
          emit_line ctx (unbox_decl_str ctx var_c ("(void*)" ^ bits_tmp) var_ty)
      | ListInlineStructStorage c_ty ->
          emit_indent ctx;
          emit ctx (Printf.sprintf "%s %s; " c_ty var_c);
          emit_list_inline_struct_dynamic_load ctx
            ~list_tmp:(Printf.sprintf "((blorp_List*)%s)" list_name)
            ~idx_tmp:idx_c ~out_tmp:var_c ~struct_ty:c_ty
            ~bounds:ListBoundsProven;
          emitln ctx ""
      | ListPointerStorage ->
          let acc_c =
            render_tailrec_list_accessor ctx ~list_name ~cursor_name acc
          in
          emit_line ctx (unbox_decl_str ctx var_c acc_c var_ty))
  | _ ->
      let acc_c =
        render_tailrec_list_accessor ctx ~list_name ~cursor_name acc
      in
      emit_line ctx (unbox_decl_str ctx var_c acc_c var_ty)

and emit_list_tailrec_rebind (ctx : Core_emit_context.t) (f : core_func)
    ~(list_index : int) ~(cursor_name : string) ~(offset : int)
    (args : core list) : unit =
  if List.length args <> List.length f.cf_params then
    Core_error.errorf Core_error.Emit Ast.dummy_loc
      "tail-recursive self-call arity mismatch in %s" f.cf_name;
  let temps =
    List.filter_map
      (fun (i, ((p : core_param), arg)) ->
        if i = list_index then None
        else
          let tmp = Printf.sprintf "__tailrec_arg_%d_%d" i (fresh_temp ctx) in
          Some (p, arg, tmp))
      (List.mapi (fun i pair -> (i, pair)) (List.combine f.cf_params args))
  in
  List.iter
    (fun (p, arg, tmp) ->
      emit_indent ctx;
      emit ctx (Printf.sprintf "%s %s = " (type_to_c ctx p.cp_ty) tmp);
      emit_expr ctx arg;
      emitln ctx ";")
    temps;
  List.iter
    (fun ((p : core_param), _, tmp) ->
      emit_line ctx
        (Printf.sprintf "%s = %s;"
           (escape_c_ident (Var.to_c_name p.cp_name))
           tmp))
    temps;
  if offset <> 0 then
    emit_line ctx (Printf.sprintf "%s += %dL;" cursor_name offset);
  emit_line ctx "continue;"

and emit_list_tailrec_rebinds (ctx : Core_emit_context.t) (f : core_func)
    ~(cursor_name : string) ~(offset : int) (rebinds : (int * core) list) : unit
    =
  let param_at i =
    let rec go idx = function
      | [] -> None
      | x :: _ when idx = i -> Some x
      | _ :: rest -> go (idx + 1) rest
    in
    match if i < 0 then None else go 0 f.cf_params with
    | Some p -> p
    | None ->
        Core_error.errorf Core_error.Emit Ast.dummy_loc
          "tail-recursive rebind index %d out of range in %s" i f.cf_name
  in
  let temps =
    List.map
      (fun (i, arg) ->
        let p = param_at i in
        let tmp = Printf.sprintf "__tailrec_arg_%d_%d" i (fresh_temp ctx) in
        (p, arg, tmp))
      rebinds
  in
  List.iter
    (fun (p, arg, tmp) ->
      emit_indent ctx;
      emit ctx (Printf.sprintf "%s %s = " (type_to_c ctx p.cp_ty) tmp);
      emit_expr ctx arg;
      emitln ctx ";")
    temps;
  List.iter
    (fun ((p : core_param), _, tmp) ->
      emit_line ctx
        (Printf.sprintf "%s = %s;"
           (escape_c_ident (Var.to_c_name p.cp_name))
           tmp))
    temps;
  if offset <> 0 then
    emit_line ctx (Printf.sprintf "%s += %dL;" cursor_name offset);
  emit_line ctx "continue;"

and emit_list_tailrec_tail (ctx : Core_emit_context.t) (f : core_func)
    ~(list_index : int) ~(cursor_name : string)
    ~(bindings : (var * accessor) list) ~(profile_name : string)
    ~(return_ty : Ast.type_expr) (e : core) : unit =
  match e.desc with
  | CTailrecRecur (TailrecListSpreadRecur { tr_rebinds; tr_cursor_advance }) ->
      emit_list_tailrec_rebinds ctx f ~cursor_name ~offset:tr_cursor_advance
        tr_rebinds
  | _ -> (
      match tailrec_list_self_call_spread_binding f list_index bindings e with
      | Some (_, offset, args) ->
          emit_list_tailrec_rebind ctx f ~list_index ~cursor_name ~offset args
      | None -> emit_tailrec_return ctx ~profile_name ~return_ty e)

and emit_list_tailrec_leaf (ctx : Core_emit_context.t) (f : core_func)
    ~(list_index : int) ~(list_ty : Ast.type_expr) ~(list_name : string)
    ~(cursor_name : string) ~(profile_name : string)
    ~(return_ty : Ast.type_expr) (bindings : (var * accessor) list)
    (body : core) : unit =
  let skip_spread_var =
    match tailrec_list_self_call_spread_binding f list_index bindings body with
    | Some (v, _, _) -> Some v
    | None -> None
  in
  let body_is_explicit_list_recur =
    match body.desc with
    | CTailrecRecur (TailrecListSpreadRecur _) -> true
    | _ -> false
  in
  let var_types = collect_var_types body in
  List.iter
    (fun (v, acc) ->
      let should_skip =
        match skip_spread_var with
        | Some skip -> Var.equal v skip
        | None -> (
            body_is_explicit_list_recur
            && match acc with AccListSpread (AccRoot, _) -> true | _ -> false)
      in
      if (not should_skip) && not (Hashtbl.mem ctx.constructor_names v.vname)
      then begin
        let var_ty = find_var_type v.vname var_types in
        emit_tailrec_list_binding ctx ~list_ty ~list_name ~cursor_name
          ~loc:body.loc v acc var_ty
      end)
    bindings;
  emit_list_tailrec_tail ctx f ~list_index ~cursor_name ~bindings ~profile_name
    ~return_ty body

and emit_list_tailrec_ctree_stmt (ctx : Core_emit_context.t) (f : core_func)
    ~(list_index : int) ~(list_ty : Ast.type_expr) ~(list_name : string)
    ~(len_name : string) ~(cursor_name : string) ~(scrut_ty : Ast.type_expr)
    ~(profile_name : string) ~(return_ty : Ast.type_expr) (tree : ctree) : unit
    =
  match tree with
  | CTLeaf { ct_bindings; ct_body } ->
      emit_list_tailrec_leaf ctx f ~list_index ~list_ty ~list_name ~cursor_name
        ~profile_name ~return_ty ct_bindings ct_body
  | CTFail ->
      emit_line ctx "fprintf(stderr, \"blorp: non-exhaustive match\\n\");";
      emit_line ctx "abort();"
  | CTSwitchTag { cts_scrut; cts_cases; cts_default } -> (
      let acc_c =
        render_tailrec_list_accessor ctx ~list_name ~cursor_name cts_scrut
      in
      List.iteri
        (fun i (ctor, subtree) ->
          emit_indent ctx;
          let test = tag_test_str ctx scrut_ty cts_scrut acc_c ctor in
          if i = 0 then emitln ctx (Printf.sprintf "if (%s) {" test)
          else emitln ctx (Printf.sprintf "} else if (%s) {" test);
          ctx.indent <- ctx.indent + 1;
          emit_list_tailrec_ctree_stmt ctx f ~list_index ~list_ty ~list_name
            ~len_name ~cursor_name ~scrut_ty ~profile_name ~return_ty subtree;
          ctx.indent <- ctx.indent - 1)
        cts_cases;
      match cts_default with
      | Some d ->
          emit_indent ctx;
          emitln ctx "} else {";
          ctx.indent <- ctx.indent + 1;
          emit_list_tailrec_ctree_stmt ctx f ~list_index ~list_ty ~list_name
            ~len_name ~cursor_name ~scrut_ty ~profile_name ~return_ty d;
          ctx.indent <- ctx.indent - 1;
          emit_indent ctx;
          emitln ctx "}"
      | None ->
          emit_indent ctx;
          emitln ctx "}")
  | CTSwitchLit { ctl_scrut; ctl_cases; ctl_default } ->
      let acc_c =
        render_tailrec_list_accessor ctx ~list_name ~cursor_name ctl_scrut
      in
      List.iteri
        (fun i (lit, subtree) ->
          emit_indent ctx;
          if i = 0 then begin
            emit ctx "if (";
            emit_lit_cmp ctx acc_c lit;
            emitln ctx ") {"
          end
          else begin
            emit ctx "} else if (";
            emit_lit_cmp ctx acc_c lit;
            emitln ctx ") {"
          end;
          ctx.indent <- ctx.indent + 1;
          emit_list_tailrec_ctree_stmt ctx f ~list_index ~list_ty ~list_name
            ~len_name ~cursor_name ~scrut_ty ~profile_name ~return_ty subtree;
          ctx.indent <- ctx.indent - 1)
        ctl_cases;
      emit_indent ctx;
      emitln ctx "} else {";
      ctx.indent <- ctx.indent + 1;
      emit_list_tailrec_ctree_stmt ctx f ~list_index ~list_ty ~list_name
        ~len_name ~cursor_name ~scrut_ty ~profile_name ~return_ty ctl_default;
      ctx.indent <- ctx.indent - 1;
      emit_indent ctx;
      emitln ctx "}"
  | CTSwitchLen { ctl_len_cases; ctl_len_geq; ctl_len_default; _ } -> (
      let all_cases =
        ctl_len_cases
        @ match ctl_len_geq with Some (n, t) -> [ (n, t) ] | None -> []
      in
      List.iteri
        (fun i (len, subtree) ->
          let is_geq = ctl_len_geq <> None && i = List.length ctl_len_cases in
          let op = if is_geq then ">=" else "==" in
          let rhs = tailrec_cursor_index_expr cursor_name len in
          emit_indent ctx;
          if i = 0 then
            emitln ctx (Printf.sprintf "if (%s %s %s) {" len_name op rhs)
          else
            emitln ctx (Printf.sprintf "} else if (%s %s %s) {" len_name op rhs);
          ctx.indent <- ctx.indent + 1;
          emit_list_tailrec_ctree_stmt ctx f ~list_index ~list_ty ~list_name
            ~len_name ~cursor_name ~scrut_ty ~profile_name ~return_ty subtree;
          ctx.indent <- ctx.indent - 1)
        all_cases;
      match ctl_len_default with
      | Some d ->
          emit_indent ctx;
          if all_cases = [] then emitln ctx "if (1) {"
          else emitln ctx "} else {";
          ctx.indent <- ctx.indent + 1;
          emit_list_tailrec_ctree_stmt ctx f ~list_index ~list_ty ~list_name
            ~len_name ~cursor_name ~scrut_ty ~profile_name ~return_ty d;
          ctx.indent <- ctx.indent - 1;
          emit_indent ctx;
          emitln ctx "}"
      | None ->
          emit_indent ctx;
          emitln ctx "}")

and emit_list_tailrec_body (ctx : Core_emit_context.t) (f : core_func)
    ~(list_index : int) ~(list_name : string) ~(len_name : string)
    ~(cursor_name : string) ~(scrut_ty : Ast.type_expr) ~(profile_name : string)
    ~(return_ty : Ast.type_expr) (body : core) : unit =
  match body.desc with
  | CLet (b, tail_body) when is_void_ty b.bind_ty ->
      emit_stmt ctx b.bind_rhs;
      emit_list_tailrec_body ctx f ~list_index ~list_name ~len_name ~cursor_name
        ~scrut_ty ~profile_name ~return_ty tail_body
  | CBorrowLet (b, tail_body) when is_void_ty b.borrow_ty ->
      emit_stmt ctx b.borrow_rhs;
      emit_list_tailrec_body ctx f ~list_index ~list_name ~len_name ~cursor_name
        ~scrut_ty ~profile_name ~return_ty tail_body
  | CLet (b, tail_body) when b.bind_var.vname = "_" ->
      emit_discard_stmt ctx b.bind_rhs;
      emit_list_tailrec_body ctx f ~list_index ~list_name ~len_name ~cursor_name
        ~scrut_ty ~profile_name ~return_ty tail_body
  | CBorrowLet (b, tail_body) when b.borrow_var.vname = "_" ->
      emit_discard_stmt ctx b.borrow_rhs;
      emit_list_tailrec_body ctx f ~list_index ~list_name ~len_name ~cursor_name
        ~scrut_ty ~profile_name ~return_ty tail_body
  | CLet (b, tail_body) ->
      let rhs =
        expr_with_expected_type_for_constructors ctx b.bind_rhs b.bind_ty
      in
      emit_indent ctx;
      emit ctx (type_to_c ctx b.bind_ty);
      emit ctx " ";
      emit ctx (escape_c_ident (Var.to_c_name b.bind_var));
      emit ctx " = ";
      (match normalize_type b.bind_ty with
      | Ast.TyFunc _ -> emit_boxed ctx rhs
      | _ -> emit_expr ctx rhs);
      emitln ctx ";";
      emit_list_tailrec_body ctx f ~list_index ~list_name ~len_name ~cursor_name
        ~scrut_ty ~profile_name ~return_ty tail_body
  | CBorrowLet (b, tail_body) ->
      let rhs =
        expr_with_expected_type_for_constructors ctx b.borrow_rhs b.borrow_ty
      in
      emit_indent ctx;
      emit ctx (type_to_c ctx b.borrow_ty);
      emit ctx " ";
      emit ctx (escape_c_ident (Var.to_c_name b.borrow_var));
      emit ctx " = ";
      (match normalize_type b.borrow_ty with
      | Ast.TyFunc _ -> emit_boxed ctx rhs
      | _ -> emit_expr ctx rhs);
      emitln ctx ";";
      emit_list_tailrec_body ctx f ~list_index ~list_name ~len_name ~cursor_name
        ~scrut_ty ~profile_name ~return_ty tail_body
  | CSeq (head, tail_body) ->
      emit_stmt ctx head;
      emit_list_tailrec_body ctx f ~list_index ~list_name ~len_name ~cursor_name
        ~scrut_ty ~profile_name ~return_ty tail_body
  | CDup (v, ty, tail_body) ->
      if type_requires_retain ctx ty then
        emit_line ctx
          (Printf.sprintf "%s;"
             (retain_value_call ctx ty
                (escape_c_ident (var_ref_c_name_for_type ctx v ty))));
      emit_list_tailrec_body ctx f ~list_index ~list_name ~len_name ~cursor_name
        ~scrut_ty ~profile_name ~return_ty tail_body
  | CDrop (v, ty, tail_body) ->
      if type_requires_release ctx ty then
        emit_line ctx
          (Printf.sprintf "%s;"
             (release_value_call ctx ty
                (escape_c_ident (var_ref_c_name_for_type ctx v ty))));
      emit_list_tailrec_body ctx f ~list_index ~list_name ~len_name ~cursor_name
        ~scrut_ty ~profile_name ~return_ty tail_body
  | CMatch (_, tree) ->
      emit_list_tailrec_ctree_stmt ctx f ~list_index ~list_ty:scrut_ty
        ~list_name ~len_name ~cursor_name ~scrut_ty ~profile_name ~return_ty
        tree
  | _ ->
      Core_error.errorf Core_error.Emit body.loc
        "tail-recursive list loop reached emit without a supported list match \
         tail body"

and emit_list_spread_tailrec_loop (ctx : Core_emit_context.t) (f : core_func)
    (loop : tailrec_loop) : unit =
  let profile_name = profile_name_for_func f in
  let list_index, list_param, cursor_var, body =
    match loop with
    | TailrecListSpreadLoop
        { tls_list_index; tls_list_param; tls_cursor_var; tls_body; _ } ->
        (tls_list_index, tls_list_param, tls_cursor_var, tls_body)
    | TailrecUnmanagedLoop _ ->
        Core_error.errorf Core_error.Emit Ast.dummy_loc
          "unmanaged tailrec loop passed to list-spread emitter"
  in
  let list_name = escape_c_ident (Var.to_c_name list_param.cp_name) in
  let cursor_name = escape_c_ident (Var.to_c_name cursor_var) in
  let len_name = Printf.sprintf "__tailrec_list_len_%d" (fresh_temp ctx) in
  emit_profile_start ctx profile_name;
  emit_line ctx (Printf.sprintf "long %s = 0L;" cursor_name);
  emit_line ctx
    (Printf.sprintf "long %s = ((blorp_List*)%s)->len;" len_name list_name);
  emit_line ctx "while (1) {";
  ctx.indent <- ctx.indent + 1;
  emit_list_tailrec_body ctx f ~list_index ~list_name ~len_name ~cursor_name
    ~scrut_ty:list_param.cp_ty ~profile_name ~return_ty:f.cf_return_ty body;
  ctx.indent <- ctx.indent - 1;
  emit_line ctx "}"

and emit_tailrec_return (ctx : Core_emit_context.t) ~(profile_name : string)
    ~(return_ty : Ast.type_expr) (e : core) : unit =
  if is_void_ty return_ty then begin
    emit_stmt ctx e;
    emit_profile_end ctx profile_name;
    emit_line ctx "return;"
  end
  else if ctx.profile then begin
    let e = expr_with_expected_type_for_constructors ctx e return_ty in
    let ret_ty_c = type_to_c ctx return_ty in
    let tmp = Printf.sprintf "__tailrec_result_%d" (fresh_temp ctx) in
    emit_indent ctx;
    emit ctx (Printf.sprintf "%s %s = " ret_ty_c tmp);
    emit_expr ctx e;
    emitln ctx ";";
    emit_profile_end ctx profile_name;
    emit_line ctx (Printf.sprintf "return %s;" tmp)
  end
  else begin
    let e = expr_with_expected_type_for_constructors ctx e return_ty in
    emit_indent ctx;
    emit ctx "return ";
    emit_expr ctx e;
    emitln ctx ";"
  end

and emit_tailrec_rebind (ctx : Core_emit_context.t) (f : core_func)
    (args : core list) : unit =
  if List.length args <> List.length f.cf_params then
    Core_error.errorf Core_error.Emit Ast.dummy_loc
      "tail-recursive self-call arity mismatch in %s" f.cf_name;
  let temps =
    List.mapi
      (fun i (p : core_param) ->
        let tmp = Printf.sprintf "__tailrec_arg_%d_%d" i (fresh_temp ctx) in
        (p, tmp))
      f.cf_params
  in
  List.iter2
    (fun (p, tmp) arg ->
      emit_indent ctx;
      emit ctx (Printf.sprintf "%s %s = " (type_to_c ctx p.cp_ty) tmp);
      emit_expr ctx arg;
      emitln ctx ";")
    temps args;
  List.iter
    (fun ((p : core_param), tmp) ->
      emit_line ctx
        (Printf.sprintf "%s = %s;"
           (escape_c_ident (Var.to_c_name p.cp_name))
           tmp))
    temps;
  emit_line ctx "continue;"

and emit_tailrec_ctree_stmt (ctx : Core_emit_context.t) (f : core_func)
    ~(profile_name : string) ~(return_ty : Ast.type_expr) (scrut_name : string)
    (scrut_ty : Ast.type_expr) (tree : ctree) : unit =
  let emit_tail ctx body =
    emit_tailrec_tail ctx f ~profile_name ~return_ty body
  in
  let emit_tree ctx scrut_name scrut_ty tree =
    emit_tailrec_ctree_stmt ctx f ~profile_name ~return_ty scrut_name scrut_ty
      tree
  in
  Core_emit_pattern.stmt ~emit_stmt:emit_tail ~emit_ctree_stmt:emit_tree ctx
    scrut_name scrut_ty tree

and emit_tailrec_tail (ctx : Core_emit_context.t) (f : core_func)
    ~(profile_name : string) ~(return_ty : Ast.type_expr) (e : core) : unit =
  match e.desc with
  | CTailrecRecur (TailrecRecur { tr_args }) ->
      emit_tailrec_rebind ctx f tr_args
  | CTailrecRecur (TailrecListSpreadRecur _) ->
      Core_error.errorf Core_error.Emit e.loc
        "list-spread tailrec recur used outside a list-spread tailrec loop"
  | _ -> (
      match self_tail_call_args f e with
      | Some args -> emit_tailrec_rebind ctx f args
      | None -> (
          match e.desc with
          | CLet (b, body) when is_void_ty b.bind_ty ->
              emit_stmt ctx b.bind_rhs;
              emit_tailrec_tail ctx f ~profile_name ~return_ty body
          | CBorrowLet (b, body) when is_void_ty b.borrow_ty ->
              emit_stmt ctx b.borrow_rhs;
              emit_tailrec_tail ctx f ~profile_name ~return_ty body
          | CLet (b, body) when b.bind_var.vname = "_" ->
              emit_discard_stmt ctx b.bind_rhs;
              emit_tailrec_tail ctx f ~profile_name ~return_ty body
          | CBorrowLet (b, body) when b.borrow_var.vname = "_" ->
              emit_discard_stmt ctx b.borrow_rhs;
              emit_tailrec_tail ctx f ~profile_name ~return_ty body
          | CLet (b, body) ->
              let rhs =
                expr_with_expected_type_for_constructors ctx b.bind_rhs
                  b.bind_ty
              in
              emit_indent ctx;
              emit ctx (type_to_c ctx b.bind_ty);
              emit ctx " ";
              emit ctx (escape_c_ident (Var.to_c_name b.bind_var));
              emit ctx " = ";
              (match normalize_type b.bind_ty with
              | Ast.TyFunc _ -> emit_boxed ctx rhs
              | _ -> emit_expr ctx rhs);
              emitln ctx ";";
              emit_tailrec_tail ctx f ~profile_name ~return_ty body
          | CBorrowLet (b, body) ->
              let rhs =
                expr_with_expected_type_for_constructors ctx b.borrow_rhs
                  b.borrow_ty
              in
              emit_indent ctx;
              emit ctx (type_to_c ctx b.borrow_ty);
              emit ctx " ";
              emit ctx (escape_c_ident (Var.to_c_name b.borrow_var));
              emit ctx " = ";
              (match normalize_type b.borrow_ty with
              | Ast.TyFunc _ -> emit_boxed ctx rhs
              | _ -> emit_expr ctx rhs);
              emitln ctx ";";
              emit_tailrec_tail ctx f ~profile_name ~return_ty body
          | CSeq (a, b) ->
              emit_stmt ctx a;
              emit_tailrec_tail ctx f ~profile_name ~return_ty b
          | CIf (cond, then_e, else_e) ->
              emit_indent ctx;
              emit ctx "if (";
              emit_expr ctx cond;
              emitln ctx ") {";
              ctx.indent <- ctx.indent + 1;
              emit_tailrec_tail ctx f ~profile_name ~return_ty then_e;
              ctx.indent <- ctx.indent - 1;
              emit_indent ctx;
              emitln ctx "} else {";
              ctx.indent <- ctx.indent + 1;
              emit_tailrec_tail ctx f ~profile_name ~return_ty else_e;
              ctx.indent <- ctx.indent - 1;
              emit_indent ctx;
              emitln ctx "}"
          | CMatch (scrut, tree) ->
              let scrut_ty_c = type_to_c ctx scrut.ty in
              let id = fresh_temp ctx in
              let scrut_name = Printf.sprintf "__scrut_%d" id in
              emit_indent ctx;
              emit ctx (Printf.sprintf "%s %s = " scrut_ty_c scrut_name);
              emit_expr ctx scrut;
              emitln ctx ";";
              emit_tailrec_ctree_stmt ctx f ~profile_name ~return_ty scrut_name
                scrut.ty tree
          | CDup (v, ty, body) ->
              if type_requires_retain ctx ty then
                emit_line ctx
                  (Printf.sprintf "%s;"
                     (retain_value_call ctx ty
                        (escape_c_ident (var_ref_c_name_for_type ctx v ty))));
              emit_tailrec_tail ctx f ~profile_name ~return_ty body
          | CDrop (v, ty, body) ->
              if type_requires_release ctx ty then
                emit_line ctx
                  (Printf.sprintf "%s;"
                     (release_value_call ctx ty
                        (escape_c_ident (var_ref_c_name_for_type ctx v ty))));
              emit_tailrec_tail ctx f ~profile_name ~return_ty body
          | _ -> emit_tailrec_return ctx ~profile_name ~return_ty e))

and emit_unmanaged_tailrec_loop (ctx : Core_emit_context.t) (f : core_func)
    (body : core) : unit =
  let profile_name = profile_name_for_func f in
  emit_profile_start ctx profile_name;
  emit_line ctx "while (1) {";
  ctx.indent <- ctx.indent + 1;
  emit_tailrec_tail ctx f ~profile_name ~return_ty:f.cf_return_ty body;
  ctx.indent <- ctx.indent - 1;
  emit_line ctx "}"

and emit_tailrec_loop (ctx : Core_emit_context.t) (f : core_func)
    (loop : tailrec_loop) : unit =
  match loop with
  | TailrecUnmanagedLoop { tul_body; _ } ->
      emit_unmanaged_tailrec_loop ctx f tul_body
  | TailrecListSpreadLoop _ -> emit_list_spread_tailrec_loop ctx f loop

(* --- §9. Lambda / closure emit ------------------------------------------- *)

(** Emit a single collected lambda as a top-level C function.

    Signature: [void* _blorp_lambda_N(void* __env, void* __arg0, ...)]
    Body unboxes captures from [__env] and parameters from [void*],
    then runs the Core body. *)
and emit_lambda_body (ctx : Core_emit_context.t)
    (cl : Core_emit_context.collected_lambda) : unit =
  let is_void = is_void_ty cl.cl_return_ty in
  let ret = if is_void && not cl.cl_task_abi then "void" else "void*" in
  let emit_boxed_result () =
    match direct_returned_capture ctx cl.cl_captures cl.cl_body with
    | Some c_name ->
        emit_box_to_void ~loc:cl.cl_body.loc ctx c_name cl.cl_body.ty
    | None -> emit_boxed ctx cl.cl_body
  in
  emit ctx (Printf.sprintf "%s %s(void* __env" ret cl.cl_name);
  List.iteri
    (fun i _ -> emit ctx (Printf.sprintf ", void* __arg%d" i))
    cl.cl_params;
  emitln ctx ") {";
  ctx.indent <- ctx.indent + 1;
  emit_profile_start ctx cl.cl_profile_name;
  if cl.cl_captures <> [] then begin
    emit_line ctx "void** __e = (void**)__env;";
    List.iteri
      (fun i (name, ty) -> emit_capture_unbox ctx name ty i)
      cl.cl_captures
  end;
  List.iteri
    (fun i (v, ty) ->
      emit_unbox_decl ctx
        (escape_c_ident (Var.to_c_name v))
        (Printf.sprintf "__arg%d" i)
        ty)
    cl.cl_params;
  if is_void && not cl.cl_task_abi then begin
    emit_stmt ctx cl.cl_body;
    emit_profile_end ctx cl.cl_profile_name
  end
  else if is_void then begin
    emit_stmt ctx cl.cl_body;
    emit_profile_end ctx cl.cl_profile_name;
    emit_line ctx "return (void*)0;"
  end
  else if ctx.profile then begin
    emit_indent ctx;
    emit ctx "void* __blorp_profile_result = ";
    emit_boxed_result ();
    emitln ctx ";";
    emit_profile_end ctx cl.cl_profile_name;
    emit_line ctx "return __blorp_profile_result;"
  end
  else begin
    emit_indent ctx;
    emit ctx "return ";
    emit_boxed_result ();
    emitln ctx ";"
  end;
  ctx.indent <- ctx.indent - 1;
  emitln ctx "}";
  emit ctx "\n"

and emit_static_closures (ctx : Core_emit_context.t) : unit =
  List.iter
    (fun (cl : Core_emit_context.collected_lambda) ->
      if cl.cl_captures = [] then
        emitln ctx
          (Printf.sprintf
             "static blorp_Closure __sc_%s = { { %s, BLORP_ALLOC_CLASS_DIRECT, \
              0 }, (void*)%s, NULL, 0, 0 };"
             cl.cl_name "BLORP_IMMORTAL_REFCOUNT" cl.cl_name))
    (List.rev ctx.collected_lambdas)

(** Emit closure construction for a concurrent task. Returns tmp name. *)
and emit_conc_closure (ctx : Core_emit_context.t) (lambda_name : string)
    (captures : (string * Ast.type_expr) list) : string =
  let fn_tmp = Printf.sprintf "__conc_fn_%d" (fresh_temp ctx) in
  emit_indent ctx;
  if captures = [] then
    emitln ctx
      (Printf.sprintf "blorp_Closure* %s = ((blorp_Closure*)&__sc_%s);" fn_tmp
         lambda_name)
  else begin
    let nc = List.length captures in
    emitln ctx
      (Printf.sprintf
         "blorp_Closure* %s = blorp_closure_new_inline((void*)%s, %d);" fn_tmp
         lambda_name nc);
    List.iteri
      (fun i (cap_name, cap_ty) ->
        emit_indent ctx;
        emit ctx (Printf.sprintf "((void**)%s->env)[%d] = " fn_tmp i);
        emit_capture_box ctx cap_name cap_ty;
        emitln ctx ";")
      captures;
    emit_closure_env_release_mask_stmt ctx fn_tmp captures
  end;
  fn_tmp

and task_copy_capture_bindings_for_emit ~loc ~context
    (captures : task_capture list) : (string * Ast.type_expr) list =
  List.map
    (fun capture ->
      match capture.task_capture_kind with
      | TaskCopyCapture -> task_capture_binding capture
      | TaskMoveResourceItem | TaskStructuredTaskBorrow ->
          Core_error.errorf Core_error.Emit loc
            ~hint:
              "Core lowering must not erase task-capture ownership. Resource \
               item moves and structured task borrows need explicit runtime \
               lowering before C emission can build a closure ABI."
            "unsupported %s task capture `%s: %s` reached emit" context
            capture.task_capture_name
            (Types.type_to_string capture.task_capture_ty))
    captures

and emit_concurrent_deadline_init (ctx : Core_emit_context.t) deadline_c
    timeout_expr : unit =
  emit_indent ctx;
  emit ctx (Printf.sprintf "long %s = blorp_concurrent_deadline_us(" deadline_c);
  emit_expr ctx timeout_expr;
  emitln ctx ");"

and emit_concurrent_remaining_init (ctx : Core_emit_context.t) remaining_c
    deadline_c : unit =
  emit_line ctx
    (Printf.sprintf "long %s = blorp_concurrent_remaining_ms(%s);" remaining_c
       deadline_c)

(* --- §10. Concurrency emit ------------------------------------------------ *)

(** Emit a [concurrent:] block in statement context.

    [block.conc_bindings] carries the explicit (var, user-type, rhs)
    triples; [block.conc_body] is the tail that uses the bindings.
    [cb_ty] is [Result[T, ConcurrencyError]] — the type of the C variable
    after [blorp_concurrent_join]. [cb_rhs.ty] is [T] (the task body's raw
    return type), which drives the spawned lambda's return type and the
    RC classification of what the task stores. *)
and emit_concurrent_block (ctx : Core_emit_context.t) (block : concurrent_block)
    : unit =
  (match block.conc_max_threads with
  | Some n -> emit_line ctx (Printf.sprintf "blorp_thread_pool_init(%d);" n)
  | None -> ());
  let batch_tmp = Printf.sprintf "__conc_batch_%d" (fresh_temp ctx) in
  emit_line ctx (Printf.sprintf "blorp_TaskBatch %s;" batch_tmp);
  emit_line ctx (Printf.sprintf "blorp_task_batch_init(&%s);" batch_tmp);
  (* Spawn phase *)
  let task_infos =
    List.map
      (fun (cb : conc_binding) ->
        let task_ret_ty, lambda_name, captures =
          match cb.cb_task with
          | Some task ->
              let c_name =
                Codegen_names.mangle_by_def_id task.tc_def_id task.tc_func
                |> escape_c_ident
              in
              ( task.tc_return_ty,
                c_name,
                task_copy_capture_bindings_for_emit ~loc:cb.cb_rhs.loc
                  ~context:"concurrent binding" task.tc_captures )
          | None ->
              Core_error.errorf Core_error.Emit cb.cb_rhs.loc
                ~hint:
                  "Core_closure should attach task metadata to every \
                   concurrent binding before emission"
                "concurrent binding reached emit without task closure metadata"
        in
        let fn_tmp = emit_conc_closure ctx lambda_name captures in
        let task_tmp = Printf.sprintf "__conc_task_%d" (fresh_temp ctx) in
        let use_rc = type_requires_release ctx task_ret_ty in
        let spawn_fn =
          if use_rc then "blorp_task_spawn_owned_rc_in_batch"
          else "blorp_task_spawn_owned_in_batch"
        in
        emit_line ctx
          (Printf.sprintf "blorp_Task* %s = (blorp_Task*)%s(&%s, %s);" task_tmp
             spawn_fn batch_tmp fn_tmp);
        (cb, task_tmp))
      block.conc_bindings
  in
  emit_line ctx (Printf.sprintf "blorp_task_batch_flush(&%s);" batch_tmp);
  let emit_join_binding (cb : conc_binding) task_tmp timeout_c =
    let var_c = escape_c_ident (Var.to_c_name cb.cb_var) in
    let ty_c = type_to_c ctx cb.cb_ty in
    let join_call =
      Printf.sprintf "blorp_concurrent_join(%s, %s)" task_tmp timeout_c
    in
    let rhs_c =
      if Core_layout_type.is_stack_result_type ~reg:ctx.reg cb.cb_ty then
        Printf.sprintf "blorp_stack_result_from_boxed((blorp_Result*)%s)"
          join_call
      else Printf.sprintf "(%s)%s" ty_c join_call
    in
    emit_line ctx (Printf.sprintf "%s %s = %s;" ty_c var_c rhs_c)
  in
  (* Join phase — compute deadline from timeout if specified *)
  let has_timeout = block.conc_timeout <> None in
  let conc_id = fresh_temp ctx in
  if has_timeout then begin
    let deadline = Printf.sprintf "__conc_deadline_%d" conc_id in
    (match block.conc_timeout with
    | Some timeout -> emit_concurrent_deadline_init ctx deadline timeout
    | None -> ());
    List.iter
      (fun ((cb : conc_binding), task_tmp) ->
        let rem = Printf.sprintf "__conc_rem_%d" (fresh_temp ctx) in
        emit_concurrent_remaining_init ctx rem deadline;
        emit_join_binding cb task_tmp rem;
        emit_line ctx
          (Printf.sprintf "blorp_release((blorp_Object*)%s);" task_tmp))
      task_infos
  end
  else
    List.iter
      (fun ((cb : conc_binding), task_tmp) ->
        emit_join_binding cb task_tmp "-1";
        emit_line ctx
          (Printf.sprintf "blorp_release((blorp_Object*)%s);" task_tmp))
      task_infos;
  (* Tail body *)
  emit_stmt ctx block.conc_body

(** Emit [detach expr] in statement context. *)
and emit_detach_stmt (ctx : Core_emit_context.t) (detach : detach_expr)
    (_loc : Ast.loc) : unit =
  let lambda_name, captures =
    match detach.detach_task with
    | Some task ->
        let c_name =
          Codegen_names.mangle_by_def_id task.tc_def_id task.tc_func
          |> escape_c_ident
        in
        ( c_name,
          task_copy_capture_bindings_for_emit ~loc:detach.detach_body.loc
            ~context:"detach" task.tc_captures )
    | None ->
        Core_error.errorf Core_error.Emit detach.detach_body.loc
          ~hint:
            "Core_closure should attach task metadata to every detach body \
             before emission"
          "detach reached emit without task closure metadata"
  in
  let fn_tmp = emit_conc_closure ctx lambda_name captures in
  emit_line ctx (Printf.sprintf "blorp_detach(%s);" fn_tmp)

(** Emit [detach expr] in expression context (returns void). *)
and emit_detach_expr (ctx : Core_emit_context.t) (detach : detach_expr)
    (loc : Ast.loc) : unit =
  emit ctx "({ ";
  emit_detach_stmt ctx detach loc;
  emit ctx "(void)0; })"

(** Emit [concurrent for v in iter: body] in statement context.
    Discards the per-iteration results — no list is allocated. *)
and emit_concurrent_for (ctx : Core_emit_context.t) (cf : concurrent_for) : unit
    =
  ignore (emit_concurrent_for_collecting ~collect:false ctx cf)

and concurrent_for_emit_plan (_ctx : Core_emit_context.t) (cf : concurrent_for)
    : Ast.type_expr * Ast.type_expr * string * (string * Ast.type_expr) list =
  let elem_ty =
    match normalize_type cf.cf_iter.ty with
    | Ast.TyNamed ("List", [ et ]) -> et
    | ty ->
        Core_error.errorf Core_error.Emit cf.cf_iter.loc
          ~hint:
            "concurrent for is currently list-only; accept other collection \
             layouts by adding explicit emitter paths rather than casting them \
             to blorp_List"
          "concurrent for requires List[T], got %s" (Types.type_to_string ty)
  in
  let task_ret_ty, lambda_name, captures =
    match cf.cf_task with
    | Some task ->
        let c_name =
          Codegen_names.mangle_by_def_id task.tc_def_id task.tc_func
          |> escape_c_ident
        in
        ( task.tc_return_ty,
          c_name,
          task_copy_capture_bindings_for_emit ~loc:cf.cf_body.loc
            ~context:"concurrent-for" task.tc_captures )
    | None ->
        Core_error.errorf Core_error.Emit cf.cf_body.loc
          ~hint:
            "Core_closure should attach task metadata to every concurrent-for \
             body before emission"
          "concurrent-for reached emit without task closure metadata"
  in
  (elem_ty, task_ret_ty, lambda_name, captures)

and emit_concurrent_for_collecting_limited ~(collect : bool)
    (ctx : Core_emit_context.t) (cf : concurrent_for) (limit : int) : string =
  emit_line ctx (Printf.sprintf "blorp_thread_pool_init(%d);" limit);
  let id = fresh_temp ctx in
  let list_c = Printf.sprintf "__conc_list_%d" id in
  let len_c = Printf.sprintf "__conc_len_%d" id in
  let limit_c = Printf.sprintf "__conc_limit_%d" id in
  let tasks_c = Printf.sprintf "__conc_tasks_%d" id in
  let start_c = Printf.sprintf "__conc_start_%d" id in
  let window_end_c = Printf.sprintf "__conc_window_end_%d" id in
  let idx_c = Printf.sprintf "__conc_i_%d" id in
  let slot_c = Printf.sprintf "__conc_slot_%d" id in
  let results_c = Printf.sprintf "__conc_results_%d" id in
  let batch_c = Printf.sprintf "__conc_batch_%d" id in
  let var_c = escape_c_ident (Var.to_c_name cf.cf_var) in
  let elem_ty, task_ret_ty, lambda_name, captures =
    concurrent_for_emit_plan ctx cf
  in
  emit_indent ctx;
  emit ctx (Printf.sprintf "blorp_List* %s = (blorp_List*)" list_c);
  emit_expr ctx cf.cf_iter;
  emitln ctx ";";
  emit_line ctx (Printf.sprintf "long %s = %s->len;" len_c list_c);
  emit_line ctx (Printf.sprintf "long %s = %dL;" limit_c limit);
  emit_line ctx
    (Printf.sprintf
       "blorp_Task** %s = blorp_malloc_checked((%s > 0 ? %s : 1) * \
        sizeof(blorp_Task*));"
       tasks_c limit_c limit_c);
  emit_line ctx (Printf.sprintf "blorp_TaskBatch %s;" batch_c);
  if collect then begin
    emit_line ctx
      (Printf.sprintf "blorp_List* %s = blorp_list_new(%s);" results_c len_c);
    emit_line ctx
      (Printf.sprintf "blorp_list_init_elem_release(%s, blorp_elem_release_fn);"
         results_c)
  end;
  let has_timeout = cf.cf_timeout <> None in
  let deadline_c = Printf.sprintf "__conc_deadline_%d" (fresh_temp ctx) in
  if has_timeout then
    begin match cf.cf_timeout with
    | Some timeout -> emit_concurrent_deadline_init ctx deadline_c timeout
    | None -> ()
    end;
  let use_rc = type_requires_release ctx task_ret_ty in
  let spawn_fn =
    if use_rc then "blorp_task_spawn_owned_rc_in_batch"
    else "blorp_task_spawn_owned_in_batch"
  in
  emit_indent ctx;
  emitln ctx
    (Printf.sprintf "for (long %s = 0; %s < %s; %s += %s) {" start_c start_c
       len_c start_c limit_c);
  ctx.indent <- ctx.indent + 1;
  emit_line ctx
    (Printf.sprintf "long %s = %s + %s;" window_end_c start_c limit_c);
  emit_line ctx
    (Printf.sprintf "if (%s > %s) %s = %s;" window_end_c len_c window_end_c
       len_c);
  emit_line ctx (Printf.sprintf "blorp_task_batch_init(&%s);" batch_c);
  emit_indent ctx;
  emitln ctx
    (Printf.sprintf "for (long %s = %s; %s < %s; %s++) {" idx_c start_c idx_c
       window_end_c idx_c);
  ctx.indent <- ctx.indent + 1;
  emit_line ctx (Printf.sprintf "long %s = %s - %s;" slot_c idx_c start_c);
  emit_unbox_decl ctx var_c
    (Printf.sprintf "blorp_list_get(%s, %s)" list_c idx_c)
    elem_ty;
  let fn_tmp = emit_conc_closure ctx lambda_name captures in
  emit_line ctx
    (Printf.sprintf "%s[%s] = (blorp_Task*)%s(&%s, %s);" tasks_c slot_c spawn_fn
       batch_c fn_tmp);
  emit_line ctx
    (Printf.sprintf "if (((%s + 1) %% BLORP_TASK_BATCH_FLUSH_INTERVAL) == 0) {"
       slot_c);
  ctx.indent <- ctx.indent + 1;
  emit_line ctx (Printf.sprintf "blorp_task_batch_flush(&%s);" batch_c);
  ctx.indent <- ctx.indent - 1;
  emit_line ctx "}";
  ctx.indent <- ctx.indent - 1;
  emit_indent ctx;
  emitln ctx "}";
  emit_line ctx (Printf.sprintf "blorp_task_batch_flush(&%s);" batch_c);
  emit_indent ctx;
  emitln ctx
    (Printf.sprintf "for (long %s = %s; %s < %s; %s++) {" idx_c start_c idx_c
       window_end_c idx_c);
  ctx.indent <- ctx.indent + 1;
  emit_line ctx (Printf.sprintf "long %s = %s - %s;" slot_c idx_c start_c);
  let join_call =
    if has_timeout then begin
      let rem = Printf.sprintf "__cf_rem_%d" (fresh_temp ctx) in
      emit_concurrent_remaining_init ctx rem deadline_c;
      Printf.sprintf "blorp_concurrent_join(%s[%s], %s)" tasks_c slot_c rem
    end
    else Printf.sprintf "blorp_concurrent_join(%s[%s], -1)" tasks_c slot_c
  in
  if collect then
    emit_line ctx
      (Printf.sprintf "blorp_list_set_raw(%s, %s, (void*)(%s));" results_c idx_c
         join_call)
  else
    emit_line ctx
      (Printf.sprintf "blorp_release((blorp_Object*)(%s));" join_call);
  emit_line ctx
    (Printf.sprintf "blorp_release((blorp_Object*)%s[%s]);" tasks_c slot_c);
  ctx.indent <- ctx.indent - 1;
  emit_indent ctx;
  emitln ctx "}";
  ctx.indent <- ctx.indent - 1;
  emit_indent ctx;
  emitln ctx "}";
  emit_line ctx (Printf.sprintf "free(%s);" tasks_c);
  if collect then emit_line ctx (Printf.sprintf "%s->len = %s;" results_c len_c);
  results_c

(** Emit [concurrent for] and, when [collect] is true, return the C
    identifier holding the collected [blorp_List*] of
    [Result[T, ConcurrencyError]] entries.

    When [collect] is false (statement context), no result list is
    allocated and join return values are released individually — saves
    an allocation and avoids retaining N Results just to immediately
    drop them.

    When [collect] is true (expression context), the list is allocated
    with capacity = iter length, populated in the join loop by writing
    directly into [data[i]] (each [Result*] arrives at refcount 1, so
    we take ownership without a retain), and tagged with
    [blorp_elem_release_fn] so the list's destructor releases each
    Result when the list itself goes out of scope. *)
and emit_concurrent_for_collecting ~(collect : bool) (ctx : Core_emit_context.t)
    (cf : concurrent_for) : string =
  match cf.cf_width with
  | Ast.ConcurrentForLimit limit ->
      emit_concurrent_for_collecting_limited ~collect ctx cf limit
  | Ast.ConcurrentForDefault | Ast.ConcurrentForMaxThreads _ ->
      (* INVARIANT (enforced by [infer.ml:infer_concurrent_for]): [concurrent for]
     accepts only [List[T]], never [Tensor]/[Vector]/[Matrix]. The cast to
     [blorp_List*] below is safe because of that gate. If the constraint is
     ever relaxed to accept Vector-family types, the list-vs-vector struct
     layout bug that bit [emit_for_list_flat] in Phase 4.1 reappears here
     identically — [blorp_List] and [blorp_Vector] have different field
     orderings before [data[]], so reading [->data[0]] through the wrong
     pointer type returns padding instead of element 0. Update the cast and
     add a tensor-aware path at the same time. *)
      (match Ast.concurrent_for_width_value cf.cf_width with
      | Some n -> emit_line ctx (Printf.sprintf "blorp_thread_pool_init(%d);" n)
      | None -> ());
      let id = fresh_temp ctx in
      let list_c = Printf.sprintf "__conc_list_%d" id in
      let len_c = Printf.sprintf "__conc_len_%d" id in
      let tasks_c = Printf.sprintf "__conc_tasks_%d" id in
      let idx_c = Printf.sprintf "__conc_i_%d" id in
      let results_c = Printf.sprintf "__conc_results_%d" id in
      let batch_c = Printf.sprintf "__conc_batch_%d" id in
      let var_c = escape_c_ident (Var.to_c_name cf.cf_var) in
      let elem_ty, task_ret_ty, lambda_name, captures =
        concurrent_for_emit_plan ctx cf
      in
      emit_indent ctx;
      emit ctx (Printf.sprintf "blorp_List* %s = (blorp_List*)" list_c);
      emit_expr ctx cf.cf_iter;
      emitln ctx ";";
      emit_line ctx (Printf.sprintf "long %s = %s->len;" len_c list_c);
      emit_line ctx
        (Printf.sprintf
           "blorp_Task** %s = blorp_malloc_checked((%s > 0 ? %s : 1) * \
            sizeof(blorp_Task*));"
           tasks_c len_c len_c);
      emit_line ctx (Printf.sprintf "blorp_TaskBatch %s;" batch_c);
      emit_line ctx (Printf.sprintf "blorp_task_batch_init(&%s);" batch_c);
      (* Result list — preallocated to the iter length so each join can
     write directly into [data[i]] without going through
     [blorp_list_append]'s COW + retain branches. Tagged with
     [blorp_elem_release_fn] so the list's destructor releases each
     [Result*] when the list itself dies. Skipped entirely in
     statement context (no observable list, no point in allocating). *)
      if collect then begin
        emit_line ctx
          (Printf.sprintf "blorp_List* %s = blorp_list_new(%s);" results_c len_c);
        emit_line ctx
          (Printf.sprintf
             "blorp_list_init_elem_release(%s, blorp_elem_release_fn);"
             results_c)
      end;
      (* Spawn phase *)
      emit_indent ctx;
      emitln ctx
        (Printf.sprintf "for (long %s = 0; %s < %s; %s++) {" idx_c idx_c len_c
           idx_c);
      ctx.indent <- ctx.indent + 1;
      emit_unbox_decl ctx var_c
        (Printf.sprintf "blorp_list_get(%s, %s)" list_c idx_c)
        elem_ty;
      (* Register the lambda with the body's real return type, NOT Void.
     [emit_lambda_body] discards the body's value when [cl_return_ty]
     is Void; that loses the per-iteration result and the task's join
     returns garbage. The body's type is exactly what [blorp_task_spawn]
     stores and [blorp_concurrent_join] returns wrapped in
     [Result[T, ConcurrencyError]]. *)
      let fn_tmp = emit_conc_closure ctx lambda_name captures in
      let use_rc = type_requires_release ctx task_ret_ty in
      let spawn_fn =
        if use_rc then "blorp_task_spawn_owned_rc_in_batch"
        else "blorp_task_spawn_owned_in_batch"
      in
      emit_line ctx
        (Printf.sprintf "%s[%s] = (blorp_Task*)%s(&%s, %s);" tasks_c idx_c
           spawn_fn batch_c fn_tmp);
      emit_line ctx
        (Printf.sprintf
           "if (((%s + 1) %% BLORP_TASK_BATCH_FLUSH_INTERVAL) == 0) {" idx_c);
      ctx.indent <- ctx.indent + 1;
      emit_line ctx (Printf.sprintf "blorp_task_batch_flush(&%s);" batch_c);
      ctx.indent <- ctx.indent - 1;
      emit_line ctx "}";
      ctx.indent <- ctx.indent - 1;
      emit_indent ctx;
      emitln ctx "}";
      emit_line ctx (Printf.sprintf "blorp_task_batch_flush(&%s);" batch_c);
      (* Join phase — append each task's [Result*] return value to the
     result list. [blorp_list_append] returns the (possibly COW-copied)
     list; reassign to keep [results_c] pointing at the live one. *)
      let has_timeout = cf.cf_timeout <> None in
      let deadline_c = Printf.sprintf "__conc_deadline_%d" (fresh_temp ctx) in
      if has_timeout then
        begin match cf.cf_timeout with
        | Some timeout -> emit_concurrent_deadline_init ctx deadline_c timeout
        | None -> ()
        end;
      emit_indent ctx;
      emitln ctx
        (Printf.sprintf "for (long %s = 0; %s < %s; %s++) {" idx_c idx_c len_c
           idx_c);
      ctx.indent <- ctx.indent + 1;
      let join_call =
        if has_timeout then begin
          let rem = Printf.sprintf "__cf_rem_%d" (fresh_temp ctx) in
          emit_concurrent_remaining_init ctx rem deadline_c;
          Printf.sprintf "blorp_concurrent_join(%s[%s], %s)" tasks_c idx_c rem
        end
        else Printf.sprintf "blorp_concurrent_join(%s[%s], -1)" tasks_c idx_c
      in
      if collect then begin
        (* Take ownership directly: [blorp_concurrent_join] returns the
       Result with refcount 1, and [blorp_elem_release_fn] (set above)
       will release it when the list dies. No retain needed; no
       [blorp_list_append] indirection — we sized the list to len, so
       raw-storing at index and bumping [len] at the end is sound. *)
        emit_line ctx
          (Printf.sprintf "blorp_list_set_raw(%s, %s, (void*)(%s));" results_c
             idx_c join_call)
      end
      else
        (* Statement context: discard the join result. Release it
       immediately so the per-iteration Result doesn't leak. *)
        emit_line ctx
          (Printf.sprintf "blorp_release((blorp_Object*)(%s));" join_call);
      emit_line ctx
        (Printf.sprintf "blorp_release((blorp_Object*)%s[%s]);" tasks_c idx_c);
      ctx.indent <- ctx.indent - 1;
      emit_indent ctx;
      emitln ctx "}";
      emit_line ctx (Printf.sprintf "free(%s);" tasks_c);
      if collect then
        emit_line ctx (Printf.sprintf "%s->len = %s;" results_c len_c);
      results_c

(* --- §11. Collection / global init --------------------------------------- *)

and emit_collected_lambdas (ctx : Core_emit_context.t) : unit =
  if ctx.collected_lambdas <> [] then begin
    emit ctx "\n";
    (* Drain iteratively: emitting a lambda body may collect new nested
       lambdas, so we loop until the list is stable. Accumulate all
       emitted lambdas so forward declarations can be generated later. *)
    let all_emitted = ref [] in
    let rec drain () =
      match ctx.collected_lambdas with
      | [] -> ()
      | _ ->
          let batch = List.rev ctx.collected_lambdas in
          ctx.collected_lambdas <- [];
          all_emitted := !all_emitted @ batch;
          List.iter (emit_lambda_body ctx) batch;
          drain ()
    in
    drain ();
    (* Restore collected_lambdas so forward declarations can be generated *)
    ctx.collected_lambdas <- List.rev !all_emitted;
    emit_static_closures ctx
  end

(** Emit [__blorp_init_globals] for global initializers that cannot be
    represented as C static initializers. *)
and emit_global_init (ctx : Core_emit_context.t) (prog : core_program) : unit =
  let rec collect acc = function
    | [] -> List.rev acc
    | { cd_desc = CDVar v; _ } :: rest -> (
        match v.cv_init.desc with
        | CLit lit when is_c_static_literal lit -> collect acc rest
        | _ ->
            collect ((v.cv_name, v.cv_def_id, v.cv_ty, v.cv_init) :: acc) rest)
    | { cd_desc = CDPrivate { cd_desc = CDVar v; _ }; _ } :: rest -> (
        match v.cv_init.desc with
        | CLit lit when is_c_static_literal lit -> collect acc rest
        | _ ->
            collect ((v.cv_name, v.cv_def_id, v.cv_ty, v.cv_init) :: acc) rest)
    | _ :: rest -> collect acc rest
  in
  let deferred = collect [] prog in
  emit ctx "\n";
  emitln ctx "void __blorp_init_globals(void) {";
  ctx.indent <- ctx.indent + 1;
  (* Only emit the None singleton init for the Option type (has both None and Some) *)
  if
    Hashtbl.mem ctx.constructor_names "None"
    && Hashtbl.mem ctx.constructor_names "Some"
  then begin
    let none_c =
      match Hashtbl.find_opt ctx.constructor_c_names "None" with
      | Some name -> name
      | None -> "None"
    in
    emit_line ctx
      (Printf.sprintf "__blorp_none_singleton_ptr = (void*)%s;"
         (escape_c_ident none_c))
  end;
  ctx.indent <- ctx.indent - 1;
  if deferred <> [] then begin
    ctx.indent <- ctx.indent + 1;
    List.iter
      (fun (var, _def_id, ty, init) ->
        let init = expr_with_expected_type_for_constructors ctx init ty in
        emit_indent ctx;
        (* Global bare name — matches [emit_global_var]'s bare decl. *)
        emit ctx (escape_c_ident (Var.to_c_name var));
        emit ctx " = ";
        emit_expr ctx init;
        emitln ctx ";")
      deferred;
    ctx.indent <- ctx.indent - 1
  end;
  emitln ctx "}"
