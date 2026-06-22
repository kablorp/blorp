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
    ([CConcurrent] / [CConcurrentlyLoop] / [CDetach]), and RC ops
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
module Blorp_prepared = Core_emit_blorp_prepared_backend

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
   exception is the root program entrypoint, which must stay bare [main]
   so the C linker can find it. Imported module functions whose source
   name is [main] are ordinary functions. Foreign functions ([CFForeign])
   and runtime builtins ([CKBuiltin]) bypass this helper entirely — their
   C names come from the user-specified [c_name] / the [Codegen_builtins]
   registry.
   ============================================================================ *)

(** C symbol for a function decl. Mangled via the function's [cf_def_id]
    unless the function is the program entrypoint. *)
let func_c_name (f : core_func) : string =
  if Core.is_program_entrypoint f then "main"
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

let is_resource_source_type (ctx : Core_emit_context.t) (ty : Ast.type_expr) :
    bool =
  match normalize_type (expand_alias ~reg:ctx.reg ty) |> Types.head_resolve with
  | Ast.TyNamed (name, [ _resource_ty; _error_ty ]) ->
      Type_name_metadata.is_resource_source_name name
  | _ -> false

let cancellation_cleanup_tracks_binding (ctx : Core_emit_context.t) (v : var)
    (ty : Ast.type_expr) (body : core) : bool =
  v.vname <> "_"
  && Option.is_some (cancellation_cleanup_release_fn ctx ty)
  (* A cancellable task can unwind before a local reaches its normal ownership
     endpoint. That endpoint may be an explicit CDrop, or it may be a tail
     transfer such as returning the local. Track every non-assigned owned
     pointer local until lexical exit; CDrop pops the frame before releasing
     when ownership ends earlier. *)
  && not (expr_assigns_var v body)

let emit_cancellation_cleanup_push (ctx : Core_emit_context.t) (v : var)
    (ty : Ast.type_expr) : unit =
  match cancellation_cleanup_release_fn ctx ty with
  | None -> ()
  | Some release_fn ->
      let var_c = escape_c_ident (Var.to_c_name v) in
      let frame_c = cleanup_frame_c_name v in
      let value_arg =
        cancellation_cleanup_value_arg ctx ty ~slot_c:var_c ~value_c:var_c
      in
      emit_line ctx (Printf.sprintf "blorp_CancelCleanupFrame %s;" frame_c);
      emit_line ctx
        (Printf.sprintf "blorp_task_cleanup_push(&%s, &%s, %s, %s);" frame_c
           var_c value_arg release_fn)

let emit_arc_value_cleanup_push (ctx : Core_emit_context.t) value_c : unit =
  let frame_c = Printf.sprintf "__blorp_arc_cleanup_%d" (fresh_temp ctx) in
  emit_line ctx (Printf.sprintf "blorp_CancelCleanupFrame %s;" frame_c);
  emit_line ctx
    (Printf.sprintf
       "blorp_task_cleanup_push(&%s, &%s, (void*)%s, \
        blorp_cleanup_release_arc_value);"
       frame_c value_c value_c)

let emit_owned_temp_cancellation_cleanup_push (ctx : Core_emit_context.t)
    ~(slot_c : string) ~(value_c : string) ~(ty : Ast.type_expr) : bool =
  match cancellation_cleanup_release_fn ctx ty with
  | None -> false
  | Some release_fn ->
      let frame_c =
        Printf.sprintf "__blorp_owned_cleanup_%d" (fresh_temp ctx)
      in
      let value_arg = cancellation_cleanup_value_arg ctx ty ~slot_c ~value_c in
      emit_line ctx (Printf.sprintf "blorp_CancelCleanupFrame %s;" frame_c);
      emit_line ctx
        (Printf.sprintf "blorp_task_cleanup_push(&%s, &%s, %s, %s);" frame_c
           slot_c value_arg release_fn);
      true

let emit_owned_erased_value_unbox_decl (ctx : Core_emit_context.t)
    (var_c : string) (source_c : string) (ty : Ast.type_expr) : unit =
  if is_stack_result_type ctx ty then
    emit_line ctx
      (Printf.sprintf
         "%s %s = blorp_stack_result_from_boxed((blorp_Result*)%s);"
         (type_to_c ctx ty) var_c source_c)
  else emit_unbox_decl ctx var_c source_c ty

let boxed_abi_temp_needs_release = function
  | BoxInt128 | BoxUInt128 | BoxStruct _ -> true
  | BoxFloat | BoxFloat32 | BoxFloat16 | BoxVoid | BoxPointer | BoxPrim -> false

let boxed_expr_temp_needs_release (ctx : Core_emit_context.t) (expr : core) :
    bool =
  match expr.desc with
  | CBoxTyped box -> boxed_abi_temp_needs_release box.box_kind
  | CBox (_, source_ty) ->
      boxed_abi_temp_needs_release (classify_for_boxing ctx source_ty expr.loc)
  | _ -> false

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

(** True when a literal can legally appear directly in a scalar C static
    initializer. String literals use a separate static Blorp object shape
    because [blorp_String] has a flexible array member and runtime code expects
    a [blorp_String*]. *)
let is_c_static_literal = function
  | Ast.LitInt _ | Ast.LitInt128 _ | Ast.LitFloat _ | Ast.LitBool _
  | Ast.LitChar _ ->
      true
  | Ast.LitString _ -> false

let is_string_global_type ty =
  match normalize_type ty with
  | Ast.TyNamed (("String" | "LiteralString"), _) -> true
  | _ -> false

let static_string_global_storage_name name_c =
  Printf.sprintf "__blorp_static_string_%s" name_c

let static_list_global_storage_name name_c =
  Printf.sprintf "__blorp_static_list_%s" name_c

let static_tuple_global_storage_name name_c =
  Printf.sprintf "__blorp_static_tuple_%s" name_c

let static_record_global_storage_name name_c =
  Printf.sprintf "__blorp_static_record_%s" name_c

let static_union_global_storage_name name_c =
  Printf.sprintf "__blorp_static_union_%s" name_c

let static_child_path ~parent_path field_name =
  Printf.sprintf "%s_%s" parent_path (escape_c_ident field_name)

let static_list_child_path ~parent_path index =
  Printf.sprintf "%s_elem_%d" parent_path index

let static_union_child_path ~parent_path variant_name index =
  Printf.sprintf "%s_%s_%d" parent_path (escape_c_ident variant_name) index

let static_tuple_child_path ~parent_path index =
  Printf.sprintf "%s_%d" parent_path index

let c_string_trailing_nul_bytes = 1
let static_list_min_capacity = 1
let static_tuple_min_storage_slots = 1

(** Mirrors [blorp_List.__pad] in [runtime.c]/[runtime_decl.c]. The static
    wrapper must be layout-compatible with [blorp_List] before casting through
    the flexible-array pointer type. *)
let static_list_runtime_padding_bytes = 5

type static_inline_list_storage =
  | StaticInlineIntegerBits of inline_storage_width
  | StaticInlineFloat64
  | StaticInlineFloat32
  | StaticInlineFloat16

let static_inline_integer_storage_c_type = function
  | InlineBytes1 -> "uint8_t"
  | InlineBytes2 -> "uint16_t"
  | InlineBytes4 -> "uint32_t"
  | InlineBytes8 -> "uintptr_t"

let static_inline_list_storage_c_type = function
  | StaticInlineIntegerBits width -> static_inline_integer_storage_c_type width
  | StaticInlineFloat64 -> "double"
  | StaticInlineFloat32 -> "float"
  | StaticInlineFloat16 -> "_Float16"

let static_inline_list_storage_elem_size = function
  | StaticInlineIntegerBits width -> inline_storage_width_bytes width
  | StaticInlineFloat64 -> inline_storage_width_bytes InlineBytes8
  | StaticInlineFloat32 -> inline_storage_width_bytes InlineBytes4
  | StaticInlineFloat16 -> inline_storage_width_bytes InlineBytes2

let static_inline_list_storage_for_layout (layout : list_storage_layout) =
  match layout.lsl_slots with
  | ListInlineStorage width -> (
      match Option.map normalize_type layout.lsl_elem_ty with
      | Some (Ast.TyNamed ("Float", [])) when width = InlineBytes8 ->
          Some StaticInlineFloat64
      | Some (Ast.TyNamed ("Float32", [])) when width = InlineBytes4 ->
          Some StaticInlineFloat32
      | Some (Ast.TyNamed ("Float16", [])) when width = InlineBytes2 ->
          Some StaticInlineFloat16
      | _ -> Some (StaticInlineIntegerBits width))
  | ListPointerStorage | ListInlineStructStorage _ -> None

let can_emit_static_string_global (v : core_var) =
  match v.cv_init.desc with
  | CLit (Ast.LitString _) when v.cv_is_const && is_string_global_type v.cv_ty
    ->
      true
  | _ -> false

let c_static_literal_initializer = function
  | Ast.LitInt n -> Some (Printf.sprintf "%LdL" n)
  | Ast.LitInt128 digits ->
      let base = "1000000000000000000" in
      let len = String.length digits in
      let rec chunks acc end_idx =
        if end_idx <= 0 then acc
        else
          let start = max 0 (end_idx - 18) in
          let chunk = String.sub digits start (end_idx - start) in
          chunks (chunk :: acc) start
      in
      let expr =
        match chunks [] len with
        | [] -> "((__int128)0)"
        | first :: rest ->
            List.fold_left
              (fun acc chunk ->
                Printf.sprintf "((%s) * (__int128)%s + (__int128)%s)" acc base
                  chunk)
              (Printf.sprintf "(__int128)%s" first)
              rest
      in
      Some expr
  | Ast.LitFloat f ->
      let s =
        match classify_float f with
        | FP_nan -> "NAN"
        | FP_infinite -> if f < 0.0 then "-INFINITY" else "INFINITY"
        | FP_normal | FP_subnormal | FP_zero -> Printf.sprintf "%.17g" f
      in
      if
        String.equal s "NAN"
        || String.ends_with ~suffix:"INFINITY" s
        || String.contains s '.' || String.contains s 'e'
        || String.contains s 'E'
      then Some s
      else Some (s ^ ".0")
  | Ast.LitBool true -> Some "true"
  | Ast.LitBool false -> Some "false"
  | Ast.LitChar c -> Some (Printf.sprintf "%d" c)
  | Ast.LitString _ -> None

let uint32_bits_as_int64 bits = Int64.logand (Int64.of_int32 bits) 0xffffffffL

let c_static_float_box_initializer box_kind value =
  match (box_kind, value.desc) with
  | BoxFloat, CLit (Ast.LitFloat f) ->
      Some
        (Printf.sprintf "(void*)(uintptr_t)0x%016LxULL"
           (Float_bit_pattern.float64_bits f))
  | BoxFloat32, CLit (Ast.LitFloat f) ->
      Some
        (Printf.sprintf "(void*)(uintptr_t)0x%08LxUL"
           (uint32_bits_as_int64 (Float_bit_pattern.float32_bits f)))
  | BoxFloat16, CLit (Ast.LitFloat f) ->
      Some
        (Printf.sprintf "(void*)(uintptr_t)0x%04xUL"
           (Float_bit_pattern.float16_bits f))
  | _ -> None

let static_heap_record_decl_for_type (ctx : Core_emit_context.t) ty =
  match normalize_type ty with
  | Ast.TyNamed (type_name, []) -> (
      match Hashtbl.find_opt ctx.record_decls type_name with
      | Some record_decl
        when (not record_decl.record_is_value)
             && (not record_decl.record_is_builtin)
             && record_decl.record_type_params = [] ->
          Some (type_name, record_decl)
      | _ -> None)
  | _ -> None

let record_construct_raw_field rc field_name =
  List.find_map
    (function
      | RecordRawField (name, value) when String.equal name field_name ->
          Some value
      | RecordRawField _ | RecordErasedField _ -> None)
    rc.rc_fields

let record_construct_has_erased_field rc =
  List.exists
    (function RecordErasedField _ -> true | RecordRawField _ -> false)
    rc.rc_fields

let record_decl_has_erased_static_field (ctx : Core_emit_context.t)
    (record_decl : Ast.record_decl) =
  List.exists
    (fun (fd : Ast.field_decl) ->
      Core_layout_type.record_field_uses_erased_storage ~reg:ctx.reg
        fd.field_type)
    record_decl.record_fields

let static_union_variant_for_construct (ctx : Core_emit_context.t)
    (uc : union_construct) =
  Codegen_types.lookup_union_variant ctx.reg uc.uc_type_name
    uc.uc_constructor_name

let rec static_value_supported (ctx : Core_emit_context.t) ~ty (expr : core) =
  match expr.desc with
  | CLit (Ast.LitString _) -> is_string_global_type ty
  | CLit lit -> Option.is_some (c_static_literal_initializer lit)
  | CListConstruct lc -> static_list_construct_supported ctx lc
  | CTupleConstruct tc -> static_tuple_construct_supported ctx tc
  | CRecordConstruct rc -> static_record_construct_supported ctx ~ty rc
  | CUnionConstruct uc -> static_union_construct_supported ctx uc
  | _ -> false

and static_pointer_list_slot_supported (ctx : Core_emit_context.t)
    (value : boxed_storage_value) =
  match value.bsv_box.box_kind with
  | BoxPointer ->
      static_value_supported ctx ~ty:value.bsv_box.box_source_ty
        value.bsv_box.box_value
  | BoxVoid -> true
  | BoxPrim | BoxFloat | BoxFloat32 | BoxFloat16 | BoxInt128 | BoxUInt128
  | BoxStruct _ ->
      false

and static_inline_list_slot_supported storage (value : boxed_storage_value) =
  match (storage, value.bsv_box.box_kind, value.bsv_box.box_value.desc) with
  | StaticInlineIntegerBits _, BoxPrim, CLit lit ->
      Option.is_some (c_static_literal_initializer lit)
  | StaticInlineFloat64, BoxFloat, CLit (Ast.LitFloat _) -> true
  | StaticInlineFloat32, BoxFloat32, CLit (Ast.LitFloat _) -> true
  | StaticInlineFloat16, BoxFloat16, CLit (Ast.LitFloat _) -> true
  | _ -> false

and static_list_construct_supported (ctx : Core_emit_context.t)
    (lc : list_construct) =
  match lc.lc_layout.lsl_slots with
  | ListPointerStorage ->
      List.for_all (static_pointer_list_slot_supported ctx) lc.lc_elems
  | ListInlineStorage _ -> (
      match static_inline_list_storage_for_layout lc.lc_layout with
      | Some storage ->
          List.for_all (static_inline_list_slot_supported storage) lc.lc_elems
      | None -> false)
  | ListInlineStructStorage _ -> false

and static_tuple_slot_supported (ctx : Core_emit_context.t)
    (value : boxed_storage_value) =
  match (value.bsv_box.box_kind, value.bsv_box.box_value.desc) with
  | BoxPrim, CLit lit -> Option.is_some (c_static_literal_initializer lit)
  | BoxPrim, _ -> false
  | BoxPointer, _ ->
      static_value_supported ctx ~ty:value.bsv_box.box_source_ty
        value.bsv_box.box_value
  | BoxVoid, _ -> true
  | (BoxFloat | BoxFloat32 | BoxFloat16), _ ->
      Option.is_some
        (c_static_float_box_initializer value.bsv_box.box_kind
           value.bsv_box.box_value)
  | (BoxInt128 | BoxUInt128 | BoxStruct _), _ -> false

and static_tuple_construct_supported (ctx : Core_emit_context.t)
    (tc : tuple_construct) =
  List.for_all (static_tuple_slot_supported ctx) tc.tc_elems

and static_record_construct_supported (ctx : Core_emit_context.t) ~ty
    (rc : record_construct) =
  match static_heap_record_decl_for_type ctx ty with
  | None -> false
  | Some (_, record_decl) ->
      (not (record_construct_has_erased_field rc))
      && (not (record_decl_has_erased_static_field ctx record_decl))
      && List.for_all
           (fun (fd : Ast.field_decl) ->
             match record_construct_raw_field rc fd.field_name with
             | None -> false
             | Some value -> static_value_supported ctx ~ty:fd.field_type value)
           record_decl.record_fields

and static_union_construct_supported (ctx : Core_emit_context.t)
    (uc : union_construct) =
  match uc.uc_representation with
  | OptionUnion _ -> false
  | ResultUnion _ -> static_stack_result_construct_supported ctx uc
  | GenericUnion -> (
      Codegen_types.union_uses_typed_payload_storage ctx.reg uc.uc_type_name
      &&
      match static_union_variant_for_construct ctx uc with
      | None -> false
      | Some variant ->
          List.length variant.variant_fields = List.length uc.uc_args
          && List.for_all2
               (fun field_ty arg ->
                 static_value_supported ctx ~ty:field_ty arg.bsv_box.box_value)
               variant.variant_fields uc.uc_args)

and static_stack_result_construct_supported (ctx : Core_emit_context.t)
    (uc : union_construct) =
  match (uc.uc_constructor_name, uc.uc_args) with
  | ("Ok" | "Err"), [ arg ] ->
      static_result_payload_slot_supported ctx arg.bsv_box.box_source_ty arg
  | _ -> false

and static_result_payload_slot_supported (ctx : Core_emit_context.t) payload_ty
    (value : boxed_storage_value) =
  match value.bsv_box.box_kind with
  | BoxPointer ->
      static_value_supported ctx ~ty:payload_ty value.bsv_box.box_value
  | BoxVoid -> true
  | BoxPrim -> (
      match value.bsv_box.box_value.desc with
      | CLit lit -> Option.is_some (c_static_literal_initializer lit)
      | _ -> false)
  | BoxFloat | BoxFloat32 | BoxFloat16 ->
      Option.is_some
        (c_static_float_box_initializer value.bsv_box.box_kind
           value.bsv_box.box_value)
  | BoxInt128 | BoxUInt128 | BoxStruct _ -> false

let can_emit_static_record_global (ctx : Core_emit_context.t) (v : core_var) =
  match v.cv_init.desc with
  | CRecordConstruct rc when v.cv_is_const ->
      static_record_construct_supported ctx ~ty:v.cv_ty rc
  | _ -> false

let can_emit_static_union_global (ctx : Core_emit_context.t) (v : core_var) =
  match v.cv_init.desc with
  | CUnionConstruct uc when v.cv_is_const ->
      static_union_construct_supported ctx uc
  | _ -> false

let can_emit_static_tuple_global (ctx : Core_emit_context.t) (v : core_var) =
  match v.cv_init.desc with
  | CTupleConstruct tc when v.cv_is_const ->
      static_tuple_construct_supported ctx tc
  | _ -> false

let can_emit_static_list_global (ctx : Core_emit_context.t) (v : core_var) =
  match v.cv_init.desc with
  | CListConstruct lc when v.cv_is_const ->
      static_list_construct_supported ctx lc
  | _ -> false

let emit_static_string_object (ctx : Core_emit_context.t) ~storage_name text =
  let escaped = c_escape_string text in
  let byte_len = String.length text in
  let data_len = byte_len + c_string_trailing_nul_bytes in
  emit_line ctx
    (Printf.sprintf
       "static struct { blorp_Object header; long len; long capacity; char \
        data[%d]; } %s = {"
       data_len storage_name);
  ctx.indent <- ctx.indent + 1;
  emit_line ctx "{ BLORP_IMMORTAL_REFCOUNT, BLORP_ALLOC_CLASS_DIRECT, 0 },";
  emit_line ctx (Printf.sprintf "%dL," byte_len);
  emit_line ctx (Printf.sprintf "%dL," byte_len);
  emit_line ctx (Printf.sprintf "\"%s\"" escaped);
  ctx.indent <- ctx.indent - 1;
  emit_line ctx "};"

let emit_static_string_global (ctx : Core_emit_context.t) ~name_c text =
  let storage_name = static_string_global_storage_name name_c in
  emit_static_string_object ctx ~storage_name text;
  emit_line ctx
    (Printf.sprintf "static blorp_String* %s = (blorp_String*)&%s;" name_c
       storage_name);
  emit ctx "\n"

let static_record_literal_field_error loc =
  Core_error.errorf Core_error.Emit loc
    ~hint:
      "Only primitive literals and string literals can currently appear inside \
       static record constants."
    "cannot emit literal as a static record field"

let rec emit_static_value_initializer (ctx : Core_emit_context.t) ~path_c ~ty
    (expr : core) : string =
  match expr.desc with
  | CLit (Ast.LitString (text, _)) when is_string_global_type ty -> begin
      let storage_name = static_string_global_storage_name path_c in
      emit_static_string_object ctx ~storage_name text;
      emit ctx "\n";
      Printf.sprintf "(blorp_String*)&%s" storage_name
    end
  | CLit lit -> (
      match c_static_literal_initializer lit with
      | None -> static_record_literal_field_error expr.loc
      | Some init_expr -> init_expr)
  | CListConstruct lc ->
      let storage_name = emit_static_list_object ctx ~path_c lc in
      Printf.sprintf "(blorp_List*)&%s" storage_name
  | CTupleConstruct tc ->
      let storage_name = emit_static_tuple_object ctx ~path_c tc in
      Printf.sprintf "(blorp_Tuple*)&%s" storage_name
  | CRecordConstruct rc ->
      let storage_name = emit_static_record_object ctx ~path_c ~ty rc in
      Printf.sprintf "(%s)&%s" (type_to_c ctx ty) storage_name
  | CUnionConstruct uc -> (
      match uc.uc_representation with
      | ResultUnion _ -> emit_static_stack_result_initializer ctx ~path_c uc
      | GenericUnion | OptionUnion _ ->
          let storage_name = emit_static_union_object ctx ~path_c uc in
          Printf.sprintf "(%s)&%s" (type_to_c ctx ty) storage_name)
  | _ ->
      Core_error.errorf Core_error.Emit expr.loc
        ~hint:
          "Static constants currently support primitive literals, string \
           literals, nested supported list constants, nested supported tuple \
           constants, nested supported record constants, and nested supported \
           union constants."
        "cannot emit expression as a static constant field"

and emit_static_stack_result_initializer (ctx : Core_emit_context.t) ~path_c
    (uc : union_construct) : string =
  if not (static_stack_result_construct_supported ctx uc) then
    Core_error.errorf Core_error.Emit Ast.dummy_loc
      ~hint:
        "Static Result emission currently supports Ok/Err constructors whose \
         single payload can be represented as a static boxed slot."
      "cannot emit `%s.%s` as a static Result" uc.uc_type_name
      uc.uc_constructor_name;
  match (uc.uc_constructor_name, uc.uc_args) with
  | (("Ok" | "Err") as field_name), [ arg ] ->
      let payload_path_c =
        static_union_child_path ~parent_path:path_c field_name 0
      in
      let payload_initializer =
        emit_static_result_payload_slot_initializer ctx ~path_c:payload_path_c
          arg
      in
      Printf.sprintf "{ .tag = %d, .release_mask = %dUL, .data.%s.field0 = %s }"
        uc.uc_tag uc.uc_release_mask field_name payload_initializer
  | _ ->
      Core_error.errorf Core_error.Emit Ast.dummy_loc
        ~hint:"stack Result constructors are represented as tag + one payload"
        "invalid static Result constructor shape for %s" uc.uc_constructor_name

and emit_static_result_payload_slot_initializer (ctx : Core_emit_context.t)
    ~path_c (value : boxed_storage_value) : string =
  match value.bsv_box.box_kind with
  | BoxPointer ->
      let init_expr =
        emit_static_value_initializer ctx ~path_c
          ~ty:value.bsv_box.box_source_ty value.bsv_box.box_value
      in
      Printf.sprintf "(void*)%s" init_expr
  | BoxVoid -> "(void*)0"
  | BoxPrim -> (
      match value.bsv_box.box_value.desc with
      | CLit lit -> (
          match c_static_literal_initializer lit with
          | Some init_expr -> Printf.sprintf "(void*)(long)(%s)" init_expr
          | None ->
              static_record_literal_field_error value.bsv_box.box_value.loc)
      | _ ->
          Core_error.errorf Core_error.Emit value.bsv_box.box_value.loc
            ~hint:
              "Static Result primitive payloads must be compile-time literal \
               values so they can be represented as C static initializers."
            "cannot emit primitive Result payload as a static constant")
  | BoxFloat | BoxFloat32 | BoxFloat16 -> (
      match
        c_static_float_box_initializer value.bsv_box.box_kind
          value.bsv_box.box_value
      with
      | Some init_expr -> init_expr
      | None ->
          Core_error.errorf Core_error.Emit value.bsv_box.box_value.loc
            ~hint:
              "Static Result floating-point payloads must be compile-time \
               literals so they can be represented as runtime box bit \
               patterns."
            "cannot emit floating-point Result payload as a static constant")
  | BoxInt128 | BoxUInt128 | BoxStruct _ ->
      Core_error.errorf Core_error.Emit value.bsv_box.box_value.loc
        ~hint:
          "This Result payload would need a runtime box. Static Result \
           emission currently supports pointer slots, primitive literal slots, \
           floating-point literal slots, and void slots only."
        "cannot emit Result payload as a static constant"

and emit_static_pointer_list_slot_initializer (ctx : Core_emit_context.t)
    ~path_c (value : boxed_storage_value) : string =
  match value.bsv_box.box_kind with
  | BoxPointer ->
      let init_expr =
        emit_static_value_initializer ctx ~path_c
          ~ty:value.bsv_box.box_source_ty value.bsv_box.box_value
      in
      Printf.sprintf "(void*)%s" init_expr
  | BoxVoid -> "(void*)0"
  | BoxPrim | BoxFloat | BoxFloat32 | BoxFloat16 | BoxInt128 | BoxUInt128
  | BoxStruct _ ->
      Core_error.errorf Core_error.Emit value.bsv_box.box_value.loc
        ~hint:
          "Static list emission currently supports pointer-storage list slots \
           whose nested values are supported static constants."
        "cannot emit list slot as a static constant"

and emit_static_inline_list_slot_initializer storage
    (value : boxed_storage_value) : string =
  match (storage, value.bsv_box.box_kind, value.bsv_box.box_value.desc) with
  | StaticInlineIntegerBits _, BoxPrim, CLit lit -> (
      match c_static_literal_initializer lit with
      | Some init_expr -> init_expr
      | None -> static_record_literal_field_error value.bsv_box.box_value.loc)
  | StaticInlineFloat64, BoxFloat, CLit (Ast.LitFloat f) -> (
      match c_static_literal_initializer (Ast.LitFloat f) with
      | Some init_expr -> init_expr
      | None -> static_record_literal_field_error value.bsv_box.box_value.loc)
  | StaticInlineFloat32, BoxFloat32, CLit (Ast.LitFloat f) -> (
      match c_static_literal_initializer (Ast.LitFloat f) with
      | Some init_expr -> init_expr
      | None -> static_record_literal_field_error value.bsv_box.box_value.loc)
  | StaticInlineFloat16, BoxFloat16, CLit (Ast.LitFloat f) -> (
      match c_static_literal_initializer (Ast.LitFloat f) with
      | Some init_expr -> init_expr
      | None -> static_record_literal_field_error value.bsv_box.box_value.loc)
  | _ ->
      Core_error.errorf Core_error.Emit value.bsv_box.box_value.loc
        ~hint:
          "Static inline list emission currently supports integer-like \
           primitive literals, Float literals, Float32 literals, and Float16 \
           literals."
        "cannot emit inline list slot as a static constant"

and emit_static_pointer_list_object (ctx : Core_emit_context.t) ~path_c
    (lc : list_construct) : string =
  let elem_initializers =
    List.mapi
      (fun index elem ->
        emit_static_pointer_list_slot_initializer ctx
          ~path_c:(static_list_child_path ~parent_path:path_c index)
          elem)
      lc.lc_elems
  in
  let storage_name = static_list_global_storage_name path_c in
  let elem_count = List.length lc.lc_elems in
  let capacity = max static_list_min_capacity elem_count in
  emit_line ctx
    (Printf.sprintf
       "static struct { blorp_Object header; long len; long capacity; void \
        (*elem_release)(void*); int16_t elem_size; uint8_t storage_mode; char \
        __pad[%d]; void* data[%d]; } %s = {"
       static_list_runtime_padding_bytes capacity storage_name);
  ctx.indent <- ctx.indent + 1;
  emit_line ctx "{ BLORP_IMMORTAL_REFCOUNT, BLORP_ALLOC_CLASS_DIRECT, 0 },";
  emit_line ctx (Printf.sprintf "%dL," elem_count);
  emit_line ctx (Printf.sprintf "%dL," capacity);
  emit_line ctx
    (if lc.lc_elem_needs_release then "blorp_elem_release_fn," else "NULL,");
  emit_line ctx "(int16_t)sizeof(void*),";
  emit_line ctx "BLORP_LIST_STORAGE_POINTER,";
  emit_line ctx "{ 0 },";
  emit_line ctx "{";
  ctx.indent <- ctx.indent + 1;
  (match elem_initializers with
  | [] -> emit_line ctx "NULL"
  | _ ->
      List.iter
        (fun init_expr -> emit_line ctx (init_expr ^ ","))
        elem_initializers);
  ctx.indent <- ctx.indent - 1;
  emit_line ctx "}";
  ctx.indent <- ctx.indent - 1;
  emit_line ctx "};";
  emit ctx "\n";
  storage_name

and emit_static_inline_list_object (ctx : Core_emit_context.t) ~path_c
    (lc : list_construct) : string =
  let storage =
    match static_inline_list_storage_for_layout lc.lc_layout with
    | Some storage -> storage
    | None ->
        Core_error.errorf Core_error.Emit Ast.dummy_loc
          ~hint:
            "Static inline list emission needs a concrete list storage \
             descriptor from Core list layout."
          "cannot emit inline list as a static constant"
  in
  let elem_initializers =
    List.map (emit_static_inline_list_slot_initializer storage) lc.lc_elems
  in
  let storage_name = static_list_global_storage_name path_c in
  let elem_count = List.length lc.lc_elems in
  let capacity = max static_list_min_capacity elem_count in
  let storage_c_type = static_inline_list_storage_c_type storage in
  let elem_size = static_inline_list_storage_elem_size storage in
  emit_line ctx
    (Printf.sprintf
       "static struct { blorp_Object header; long len; long capacity; void \
        (*elem_release)(void*); int16_t elem_size; uint8_t storage_mode; char \
        __pad[%d]; %s data[%d]; } %s = {"
       static_list_runtime_padding_bytes storage_c_type capacity storage_name);
  ctx.indent <- ctx.indent + 1;
  emit_line ctx "{ BLORP_IMMORTAL_REFCOUNT, BLORP_ALLOC_CLASS_DIRECT, 0 },";
  emit_line ctx (Printf.sprintf "%dL," elem_count);
  emit_line ctx (Printf.sprintf "%dL," capacity);
  emit_line ctx "NULL,";
  emit_line ctx (Printf.sprintf "(int16_t)%d," elem_size);
  emit_line ctx "BLORP_LIST_STORAGE_INLINE,";
  emit_line ctx "{ 0 },";
  emit_line ctx "{";
  ctx.indent <- ctx.indent + 1;
  (match elem_initializers with
  | [] -> emit_line ctx "0"
  | _ ->
      List.iter
        (fun init_expr ->
          emit_line ctx (Printf.sprintf "((%s)(%s))," storage_c_type init_expr))
        elem_initializers);
  ctx.indent <- ctx.indent - 1;
  emit_line ctx "}";
  ctx.indent <- ctx.indent - 1;
  emit_line ctx "};";
  emit ctx "\n";
  storage_name

and emit_static_list_object (ctx : Core_emit_context.t) ~path_c
    (lc : list_construct) : string =
  if not (static_list_construct_supported ctx lc) then
    Core_error.errorf Core_error.Emit Ast.dummy_loc
      ~hint:
        "Static list emission currently supports pointer-storage lists whose \
         elements are supported static constants and inline primitive literal \
         lists."
      "cannot emit list as a static constant";
  match lc.lc_layout.lsl_slots with
  | ListPointerStorage -> emit_static_pointer_list_object ctx ~path_c lc
  | ListInlineStorage _ -> emit_static_inline_list_object ctx ~path_c lc
  | ListInlineStructStorage _ ->
      Core_error.errorf Core_error.Emit Ast.dummy_loc
        ~hint:
          "Inline struct list static emission needs typed byte initializers \
           and is intentionally not enabled by this path."
        "cannot emit inline struct list as a static constant"

and emit_static_tuple_slot_initializer (ctx : Core_emit_context.t) ~path_c
    (value : boxed_storage_value) : string =
  match value.bsv_box.box_kind with
  | BoxPrim -> (
      match value.bsv_box.box_value.desc with
      | CLit lit -> (
          match c_static_literal_initializer lit with
          | Some init_expr -> Printf.sprintf "(void*)(long)(%s)" init_expr
          | None ->
              static_record_literal_field_error value.bsv_box.box_value.loc)
      | _ ->
          Core_error.errorf Core_error.Emit value.bsv_box.box_value.loc
            ~hint:
              "Static tuple primitive slots must be compile-time literal \
               values so they can be represented as C static initializers."
            "cannot emit primitive tuple slot as a static constant")
  | BoxPointer ->
      let init_expr =
        emit_static_value_initializer ctx ~path_c
          ~ty:value.bsv_box.box_source_ty value.bsv_box.box_value
      in
      Printf.sprintf "(void*)%s" init_expr
  | BoxVoid -> "(void*)0"
  | BoxFloat | BoxFloat32 | BoxFloat16 -> (
      match
        c_static_float_box_initializer value.bsv_box.box_kind
          value.bsv_box.box_value
      with
      | Some init_expr -> init_expr
      | None ->
          Core_error.errorf Core_error.Emit value.bsv_box.box_value.loc
            ~hint:
              "Static tuple floating-point slots must be compile-time literals \
               so they can be represented as runtime box bit patterns."
            "cannot emit floating-point tuple slot as a static constant")
  | BoxInt128 | BoxUInt128 | BoxStruct _ ->
      Core_error.errorf Core_error.Emit value.bsv_box.box_value.loc
        ~hint:
          "This tuple element would need a runtime box. Static tuple emission \
           currently supports pointer slots, primitive literal slots, \
           floating-point literal slots, and void slots only."
        "cannot emit tuple slot as a static constant"

and emit_static_tuple_object (ctx : Core_emit_context.t) ~path_c
    (tc : tuple_construct) : string =
  if not (static_tuple_construct_supported ctx tc) then
    Core_error.errorf Core_error.Emit Ast.dummy_loc
      ~hint:
        "Static tuple emission currently supports pointer slots, primitive \
         literal slots, floating-point literal slots, and void slots whose \
         nested values are supported static constants."
      "cannot emit tuple as a static constant";
  let field_initializers =
    List.mapi
      (fun index value ->
        emit_static_tuple_slot_initializer ctx
          ~path_c:(static_tuple_child_path ~parent_path:path_c index)
          value)
      tc.tc_elems
  in
  let storage_name = static_tuple_global_storage_name path_c in
  let arity = List.length tc.tc_elems in
  let storage_slots = max static_tuple_min_storage_slots arity in
  emit_line ctx
    (Printf.sprintf
       "static struct { blorp_Object header; long arity; long release_mask; \
        void* elem[%d]; } %s = {"
       storage_slots storage_name);
  ctx.indent <- ctx.indent + 1;
  emit_line ctx
    ".header = { BLORP_IMMORTAL_REFCOUNT, BLORP_ALLOC_CLASS_DIRECT, 0 },";
  emit_line ctx (Printf.sprintf ".arity = %dL," arity);
  emit_line ctx (Printf.sprintf ".release_mask = %dUL," tc.tc_release_mask);
  emit_line ctx
    (Printf.sprintf ".elem = { %s }" (String.concat ", " field_initializers));
  ctx.indent <- ctx.indent - 1;
  emit_line ctx "};";
  emit ctx "\n";
  storage_name

and emit_static_record_object (ctx : Core_emit_context.t) ~path_c ~ty
    (rc : record_construct) : string =
  let type_name, record_decl =
    match static_heap_record_decl_for_type ctx ty with
    | Some record -> record
    | None ->
        Core_error.errorf Core_error.Emit Ast.dummy_loc
          ~hint:
            "Static record emission currently supports non-generic heap record \
             declarations only."
          "cannot emit `%s` as a static record" (Types.type_to_string ty)
  in
  if
    record_construct_has_erased_field rc
    || record_decl_has_erased_static_field ctx record_decl
  then
    Core_error.errorf Core_error.Emit Ast.dummy_loc
      ~hint:
        "Records with erased generic fields need release-mask-aware static \
         emission and are not enabled yet."
      "cannot emit `%s` as a static record because it has erased fields"
      type_name;
  let field_initializers =
    List.map
      (fun (fd : Ast.field_decl) ->
        let value =
          match record_construct_raw_field rc fd.field_name with
          | Some value -> value
          | None ->
              Core_error.errorf Core_error.Emit Ast.dummy_loc
                ~hint:
                  "Record construction should be validated and ordered before \
                   static emission."
                "record `%s` is missing field `%s`" type_name fd.field_name
        in
        let field_path_c =
          static_child_path ~parent_path:path_c fd.field_name
        in
        emit_static_value_initializer ctx ~path_c:field_path_c ~ty:fd.field_type
          value)
      record_decl.record_fields
  in
  let storage_name = static_record_global_storage_name path_c in
  emit_line ctx (Printf.sprintf "static %s %s = {" type_name storage_name);
  ctx.indent <- ctx.indent + 1;
  emit_line ctx "{ BLORP_IMMORTAL_REFCOUNT, BLORP_ALLOC_CLASS_DIRECT, 0 },";
  List.iteri
    (fun index init_expr ->
      let suffix =
        if index = List.length field_initializers - 1 then "" else ","
      in
      emit_line ctx (init_expr ^ suffix))
    field_initializers;
  ctx.indent <- ctx.indent - 1;
  emit_line ctx "};";
  emit ctx "\n";
  storage_name

and emit_static_union_object (ctx : Core_emit_context.t) ~path_c
    (uc : union_construct) : string =
  if not (static_union_construct_supported ctx uc) then
    Core_error.errorf Core_error.Emit Ast.dummy_loc
      ~hint:
        "Static union emission currently supports heap union constructors with \
         concrete typed payload fields whose values are themselves static \
         constants."
      "cannot emit `%s.%s` as a static union" uc.uc_type_name
      uc.uc_constructor_name;
  let variant =
    match static_union_variant_for_construct ctx uc with
    | Some variant -> variant
    | None ->
        Core_error.errorf Core_error.Emit Ast.dummy_loc
          ~hint:
            "Union constructor lookup should be registered before static \
             emission."
          "union `%s` has no constructor `%s`" uc.uc_type_name
          uc.uc_constructor_name
  in
  let field_initializers =
    List.mapi
      (fun index field_ty ->
        let arg = List.nth uc.uc_args index in
        let field_path_c =
          static_union_child_path ~parent_path:path_c variant.variant_name index
        in
        emit_static_value_initializer ctx ~path_c:field_path_c ~ty:field_ty
          arg.bsv_box.box_value)
      variant.variant_fields
  in
  let storage_name = static_union_global_storage_name path_c in
  emit_line ctx (Printf.sprintf "static %s %s = {" uc.uc_type_name storage_name);
  ctx.indent <- ctx.indent + 1;
  emit_line ctx
    ".header = { BLORP_IMMORTAL_REFCOUNT, BLORP_ALLOC_CLASS_DIRECT, 0 },";
  emit_line ctx
    (Printf.sprintf ".tag = %s," (variant_tag_c_name uc.uc_type_name variant));
  emit_line ctx
    (Printf.sprintf ".data.%s = { %s }" variant.variant_name
       (String.concat ", " field_initializers));
  ctx.indent <- ctx.indent - 1;
  emit_line ctx "};";
  emit ctx "\n";
  storage_name

let emit_static_record_global (ctx : Core_emit_context.t) (v : core_var) ~name_c
    (rc : record_construct) =
  let storage_name =
    emit_static_record_object ctx ~path_c:name_c ~ty:v.cv_ty rc
  in
  emit_line ctx
    (Printf.sprintf "static %s %s = (%s)&%s;" (type_to_c ctx v.cv_ty) name_c
       (type_to_c ctx v.cv_ty) storage_name);
  emit ctx "\n"

let emit_static_union_global (ctx : Core_emit_context.t) (v : core_var) ~name_c
    (uc : union_construct) =
  match uc.uc_representation with
  | ResultUnion _ ->
      let init_expr =
        emit_static_stack_result_initializer ctx ~path_c:name_c uc
      in
      emit_line ctx
        (Printf.sprintf "static %s %s = %s;" (type_to_c ctx v.cv_ty) name_c
           init_expr);
      emit ctx "\n"
  | GenericUnion | OptionUnion _ ->
      let storage_name = emit_static_union_object ctx ~path_c:name_c uc in
      emit_line ctx
        (Printf.sprintf "static %s %s = (%s)&%s;" (type_to_c ctx v.cv_ty) name_c
           (type_to_c ctx v.cv_ty) storage_name);
      emit ctx "\n"

let emit_static_tuple_global (ctx : Core_emit_context.t) ~name_c
    (tc : tuple_construct) =
  let storage_name = emit_static_tuple_object ctx ~path_c:name_c tc in
  emit_line ctx
    (Printf.sprintf "static blorp_Tuple* %s = (blorp_Tuple*)&%s;" name_c
       storage_name);
  emit ctx "\n"

let emit_static_list_global (ctx : Core_emit_context.t) ~name_c
    (lc : list_construct) =
  let storage_name = emit_static_list_object ctx ~path_c:name_c lc in
  emit_line ctx
    (Printf.sprintf "static blorp_List* %s = (blorp_List*)&%s;" name_c
       storage_name);
  emit ctx "\n"

type global_constant_immortalization =
  | NoImmortalizationNeeded
  | ImmortalizeConstantGraph of global_constant_immortal_plan
  | UnsupportedManagedConstant of string

and global_constant_immortal_plan =
  | ImmortalRootOnly of Ast.type_expr
  | ImmortalRecord of {
      record_ty : Ast.type_expr;
      record_fields : global_constant_record_field_plan list;
    }
  | ImmortalUnion of {
      union_ty : Ast.type_expr;
      union_type_name : string;
      union_variants : global_constant_union_variant_plan list;
    }
  | ImmortalTuple of {
      tuple_ty : Ast.type_expr;
      tuple_elements : global_constant_tuple_element_plan list;
    }
  | ImmortalStackResult of {
      result_ty : Ast.type_expr;
      ok_payload : global_constant_payload_plan option;
      err_payload : global_constant_payload_plan option;
    }
  | ImmortalList of {
      list_ty : Ast.type_expr;
      list_elem_plan : global_constant_immortal_plan option;
    }
  | ImmortalDict of {
      dict_ty : Ast.type_expr;
      dict_key_plan : global_constant_immortal_plan option;
      dict_value_plan : global_constant_immortal_plan option;
    }

and global_constant_record_field_plan = {
  gc_field_name : string;
  gc_field_plan : global_constant_immortal_plan;
}

and global_constant_tuple_element_plan = {
  gc_tuple_index : int;
  gc_tuple_plan : global_constant_immortal_plan;
}

and global_constant_union_variant_plan = {
  gc_variant : Ast.variant;
  gc_variant_fields : global_constant_union_field_plan list;
}

and global_constant_union_field_plan = {
  gc_union_field_index : int;
  gc_union_field_plan : global_constant_immortal_plan;
}

and global_constant_payload_plan = {
  gc_payload_plan : global_constant_immortal_plan;
}

type checked_global_constant_immortalization =
  | CheckedNoImmortalizationNeeded
  | CheckedImmortalizeConstantGraph of global_constant_immortal_plan

type global_constant_storage = DirectTypedStorage | VoidPointerPayload

let global_constant_unsupported_hint =
  "Use a function to construct this value at runtime, or reduce the constant \
   to supported shapes: strings, heap records, heap unions, tuples, stack \
   Result payloads, Lists, and Dicts with supported element types."

let type_param_subst params args =
  let names = Ast.type_param_names params in
  if List.length names = List.length args then Some (List.combine names args)
  else None

let apply_type_param_subst_or_original params args ty =
  match type_param_subst params args with
  | Some subst -> Codegen_types.apply_codegen_subst subst ty
  | None -> ty

let global_constant_type_string ty = Types.type_to_string (normalize_type ty)

let global_constant_list_element_type = function
  | Ast.TyNamed (("List" | "ParallelList"), [ elem ]) -> Some elem
  | _ -> None

let global_constant_dict_entry_types = function
  | Ast.TyNamed ("Dict", [ key; value ]) -> Some (key, value)
  | _ -> None

let managed_container_nested_release (ctx : Core_emit_context.t)
    (ty : Ast.type_expr) : (bool, string) result option =
  let release ty =
    try Ok (type_requires_release ctx ty)
    with Core_error.Core_error err -> Error err.msg
  in
  let boxed_release ty =
    try Ok (boxed_value_needs_release ctx ty Ast.dummy_loc)
    with Core_error.Core_error err -> Error err.msg
  in
  let named_container name checks =
    let rec combine = function
      | [] -> Ok false
      | check :: rest -> (
          match check with
          | Error msg -> Error msg
          | Ok true -> Ok true
          | Ok false -> combine rest)
    in
    Some (combine checks |> Result.map_error (fun msg -> name ^ ": " ^ msg))
  in
  match normalize_type ty with
  | Ast.TyNamed ("Dict", [ key; value ]) ->
      named_container "Dict" [ boxed_release key; boxed_release value ]
  | Ast.TyNamed ("Set", [ elem ]) ->
      named_container "Set" [ boxed_release elem ]
  | Ast.TyNamed ("Tensor", elem :: _) | Ast.TyArray (elem, _) ->
      named_container "Tensor" [ boxed_release elem ]
  | Ast.TyNamed
      ( ( "Channel" | "Task" | "Stream" | "FallibleStream" | "ResourceSource"
        | "OneShotStream" ),
        _ ) ->
      Some (Ok true)
  | Ast.TyNamed (name, _) when Type_name_metadata.is_one_shot_stream_name name
    ->
      Some (Ok true)
  | Ast.TyNamed (name, _) when Type_name_metadata.is_resource_source_name name
    ->
      Some (Ok true)
  | _ -> (
      match normalize_type ty with
      | Ast.TyNamed ("Slice", [ elem ]) ->
          named_container "Slice" [ release elem ]
      | _ -> None)

let simple_arc_global_constant_root = function
  | Ast.TyFunc _ -> true
  | Ast.TyNamed (("String" | "LiteralString" | "Bytes" | "Fixed"), _) -> true
  | _ -> false

let global_constant_plan_type = function
  | ImmortalRootOnly ty -> ty
  | ImmortalRecord { record_ty; _ } -> record_ty
  | ImmortalUnion { union_ty; _ } -> union_ty
  | ImmortalTuple { tuple_ty; _ } -> tuple_ty
  | ImmortalStackResult { result_ty; _ } -> result_ty
  | ImmortalList { list_ty; _ } -> list_ty
  | ImmortalDict { dict_ty; _ } -> dict_ty

let union_variants_for_type (ctx : Core_emit_context.t) type_name =
  match Hashtbl.find_opt ctx.reg.union_variants type_name with
  | None -> []
  | Some variants ->
      Hashtbl.fold (fun _ variant acc -> variant :: acc) variants []

let global_constant_nullary_union_singleton (ctx : Core_emit_context.t)
    (v : core_var) : bool =
  match (normalize_type v.cv_ty, v.cv_init.desc) with
  | Ast.TyNamed (type_name, _), CVar ctor_var -> (
      match Codegen_types.managed_type_info ctx.reg type_name with
      | Some { managed_kind = ManagedUnion; _ } ->
          union_variants_for_type ctx type_name
          |> List.exists (fun (variant : Ast.variant) ->
              variant.variant_fields = []
              && String.equal variant.variant_name ctor_var.vname)
      | _ -> false)
  | _ -> false

let rec build_global_constant_plan (ctx : Core_emit_context.t)
    ~(storage : global_constant_storage) ~(path : string) ~(seen : string list)
    (ty : Ast.type_expr) : (global_constant_immortal_plan, string) result =
  let ty = normalize_type ty in
  let ty_key = Types.type_to_string ty in
  if List.mem ty_key seen then
    Error
      (Printf.sprintf "%s has recursive managed type `%s`" path
         (global_constant_type_string ty))
  else if not (type_requires_release ctx ty) then
    Error
      (Printf.sprintf "%s has type `%s`, which does not need immortalization"
         path
         (global_constant_type_string ty))
  else
    match global_constant_list_element_type ty with
    | Some elem_ty -> (
        match
          build_optional_child_plan ctx ~storage:VoidPointerPayload
            ~path:(path ^ "[]") ~seen:(ty_key :: seen) elem_ty
        with
        | Error _ as err -> err
        | Ok list_elem_plan ->
            Ok (ImmortalList { list_ty = ty; list_elem_plan }))
    | None -> (
        match global_constant_dict_entry_types ty with
        | Some (key_ty, value_ty) ->
            build_dict_plan ctx ~path ~seen:(ty_key :: seen) ty key_ty value_ty
        | None -> (
            match managed_container_nested_release ctx ty with
            | Some (Ok false) -> Ok (ImmortalRootOnly ty)
            | Some (Ok true) ->
                Error
                  (Printf.sprintf
                     "%s has unsupported container type `%s` with managed \
                      contents"
                     path
                     (global_constant_type_string ty))
            | Some (Error reason) ->
                Error
                  (Printf.sprintf "could not classify container in %s: %s" path
                     reason)
            | None -> (
                match storage with
                | VoidPointerPayload when not (is_pointer_type ctx ty) ->
                    Error
                      (Printf.sprintf
                         "%s has boxed by-value payload type `%s`; this \
                          constant layout cannot be traversed safely yet"
                         path
                         (global_constant_type_string ty))
                | DirectTypedStorage | VoidPointerPayload -> (
                    match ty with
                    | ty when is_stack_result_type ctx ty -> (
                        match (storage, ty) with
                        | ( DirectTypedStorage,
                            Ast.TyNamed ("Result", [ ok_ty; err_ty ]) ) ->
                            build_result_plan ctx ~path ~seen:(ty_key :: seen)
                              ty ok_ty err_ty
                        | VoidPointerPayload, _ ->
                            Error
                              (Printf.sprintf
                                 "%s has boxed stack Result payload type `%s`; \
                                  this constant layout cannot be traversed \
                                  safely yet"
                                 path
                                 (global_constant_type_string ty))
                        | DirectTypedStorage, _ ->
                            Error
                              (Printf.sprintf
                                 "%s has unsupported Result spelling `%s`" path
                                 (global_constant_type_string ty)))
                    | Ast.TyTuple elems ->
                        build_tuple_plan ctx ~path ~seen:(ty_key :: seen) ty
                          elems
                    | Ast.TyNamed (type_name, args) -> (
                        match Hashtbl.find_opt ctx.record_decls type_name with
                        | Some record_decl when not record_decl.record_is_value
                          ->
                            build_record_plan ctx ~path ~seen:(ty_key :: seen)
                              ty record_decl args
                        | _ -> (
                            match
                              Codegen_types.managed_type_info ctx.reg type_name
                            with
                            | Some { managed_kind = ManagedUnion; _ } ->
                                build_union_plan ctx ~path
                                  ~seen:(ty_key :: seen) ty type_name
                            | Some { managed_kind = ManagedHeapRecord; _ } ->
                                Error
                                  (Printf.sprintf
                                     "%s has heap record type `%s` but no \
                                      record declaration is available for \
                                      traversal"
                                     path type_name)
                            | _ when simple_arc_global_constant_root ty ->
                                Ok (ImmortalRootOnly ty)
                            | _ when is_pointer_type ctx ty ->
                                Error
                                  (Printf.sprintf
                                     "%s has managed pointer type `%s` without \
                                      a supported constant traversal contract"
                                     path
                                     (global_constant_type_string ty))
                            | _ ->
                                Error
                                  (Printf.sprintf
                                     "%s has unsupported managed type `%s`" path
                                     (global_constant_type_string ty))))
                    | _ when simple_arc_global_constant_root ty ->
                        Ok (ImmortalRootOnly ty)
                    | _ when is_pointer_type ctx ty ->
                        Error
                          (Printf.sprintf
                             "%s has managed pointer type `%s` without a \
                              supported constant traversal contract"
                             path
                             (global_constant_type_string ty))
                    | _ ->
                        Error
                          (Printf.sprintf "%s has unsupported managed type `%s`"
                             path
                             (global_constant_type_string ty))))))

and build_optional_child_plan ctx ~storage ~path ~seen ty =
  if type_requires_release ctx ty then
    build_global_constant_plan ctx ~storage ~path ~seen ty
    |> Result.map Option.some
  else Ok None

and build_result_plan ctx ~path ~seen result_ty ok_ty err_ty =
  let build_payload label payload_ty =
    build_optional_child_plan ctx ~storage:VoidPointerPayload
      ~path:(path ^ "." ^ label)
      ~seen payload_ty
    |> Result.map (Option.map (fun gc_payload_plan -> { gc_payload_plan }))
  in
  match build_payload "Ok" ok_ty with
  | Error _ as err -> err
  | Ok ok_payload -> (
      match build_payload "Err" err_ty with
      | Error _ as err -> err
      | Ok err_payload ->
          Ok (ImmortalStackResult { result_ty; ok_payload; err_payload }))

and build_dict_plan ctx ~path ~seen dict_ty key_ty value_ty =
  let build_entry label entry_ty =
    build_optional_child_plan ctx ~storage:VoidPointerPayload
      ~path:(path ^ "." ^ label ^ "[]")
      ~seen entry_ty
  in
  match build_entry "key" key_ty with
  | Error _ as err -> err
  | Ok dict_key_plan -> (
      match build_entry "value" value_ty with
      | Error _ as err -> err
      | Ok dict_value_plan ->
          Ok (ImmortalDict { dict_ty; dict_key_plan; dict_value_plan }))

and build_tuple_plan ctx ~path ~seen tuple_ty elems =
  let rec go i = function
    | [] -> Ok []
    | elem_ty :: rest ->
        if type_requires_release ctx elem_ty then
          match
            build_global_constant_plan ctx ~storage:VoidPointerPayload
              ~path:(Printf.sprintf "%s[%d]" path i)
              ~seen elem_ty
          with
          | Error _ as err -> err
          | Ok gc_tuple_plan -> (
              match go (i + 1) rest with
              | Error _ as err -> err
              | Ok tail -> Ok ({ gc_tuple_index = i; gc_tuple_plan } :: tail))
        else go (i + 1) rest
  in
  go 0 elems
  |> Result.map (fun tuple_elements ->
      ImmortalTuple { tuple_ty; tuple_elements })

and build_record_plan ctx ~path ~seen record_ty record_decl args =
  let rec go = function
    | [] -> Ok []
    | (fd : Ast.field_decl) :: rest ->
        let field_ty =
          apply_type_param_subst_or_original record_decl.record_type_params args
            fd.field_type
        in
        if type_requires_release ctx field_ty then
          if
            Core_layout_type.record_field_uses_erased_storage ~reg:ctx.reg
              fd.field_type
          then
            Error
              (Printf.sprintf
                 "%s.%s has erased generic storage for managed type `%s`; this \
                  constant layout cannot be traversed safely yet"
                 path fd.field_name
                 (global_constant_type_string field_ty))
          else
            match
              build_global_constant_plan ctx ~storage:DirectTypedStorage
                ~path:(path ^ "." ^ fd.field_name)
                ~seen field_ty
            with
            | Error _ as err -> err
            | Ok gc_field_plan -> (
                match go rest with
                | Error _ as err -> err
                | Ok tail ->
                    Ok ({ gc_field_name = fd.field_name; gc_field_plan } :: tail)
                )
        else go rest
  in
  go record_decl.record_fields
  |> Result.map (fun record_fields ->
      ImmortalRecord { record_ty; record_fields })

and build_union_plan ctx ~path ~seen union_ty type_name =
  let field_storage =
    if Codegen_types.union_uses_typed_payload_storage ctx.reg type_name then
      DirectTypedStorage
    else VoidPointerPayload
  in
  let build_variant (variant : Ast.variant) =
    let rec go i = function
      | [] -> Ok []
      | field_ty :: rest ->
          if Codegen_types.has_type_vars field_ty then
            Error
              (Printf.sprintf
                 "%s.%s field %d has generic payload type `%s`; generic union \
                  constants cannot be traversed safely yet"
                 path variant.variant_name i
                 (global_constant_type_string field_ty))
          else if type_requires_release ctx field_ty then
            match
              build_global_constant_plan ctx ~storage:field_storage
                ~path:
                  (Printf.sprintf "%s.%s.field%d" path variant.variant_name i)
                ~seen field_ty
            with
            | Error _ as err -> err
            | Ok gc_union_field_plan -> (
                match go (i + 1) rest with
                | Error _ as err -> err
                | Ok tail ->
                    Ok
                      ({ gc_union_field_index = i; gc_union_field_plan } :: tail)
                )
          else go (i + 1) rest
    in
    go 0 variant.variant_fields
    |> Result.map (fun gc_variant_fields ->
        { gc_variant = variant; gc_variant_fields })
  in
  let rec build_all = function
    | [] -> Ok []
    | variant :: rest -> (
        match build_variant variant with
        | Error _ as err -> err
        | Ok planned -> (
            match build_all rest with
            | Error _ as err -> err
            | Ok tail -> Ok (planned :: tail)))
  in
  build_all (union_variants_for_type ctx type_name)
  |> Result.map (fun union_variants ->
      ImmortalUnion { union_ty; union_type_name = type_name; union_variants })

let global_constant_immortalization (ctx : Core_emit_context.t) (v : core_var) :
    global_constant_immortalization =
  if (not v.cv_is_const) || not (type_requires_release ctx v.cv_ty) then
    NoImmortalizationNeeded
  else if global_constant_nullary_union_singleton ctx v then
    ImmortalizeConstantGraph (ImmortalRootOnly (normalize_type v.cv_ty))
  else
    match
      build_global_constant_plan ctx ~storage:DirectTypedStorage
        ~path:(Var.to_string v.cv_name) ~seen:[] v.cv_ty
    with
    | Error reason -> UnsupportedManagedConstant reason
    | Ok plan -> ImmortalizeConstantGraph plan

let emit_make_immortal_root (ctx : Core_emit_context.t) c_expr =
  emit_line ctx (Printf.sprintf "blorp_make_immortal_constant(%s);" c_expr)

let cast_void_payload_for_type (ctx : Core_emit_context.t) ty c_expr =
  if is_pointer_type ctx ty then
    Printf.sprintf "((%s)%s)" (type_to_c ctx ty) c_expr
  else c_expr

let rec emit_immortalize_plan (ctx : Core_emit_context.t) c_expr plan : unit =
  match plan with
  | ImmortalRootOnly _ -> emit_make_immortal_root ctx c_expr
  | ImmortalRecord { record_fields; _ } ->
      emit_immortalize_record ctx c_expr record_fields
  | ImmortalUnion { union_type_name; union_variants; _ } ->
      emit_immortalize_union ctx c_expr union_type_name union_variants
  | ImmortalTuple { tuple_elements; _ } ->
      emit_immortalize_tuple ctx c_expr tuple_elements
  | ImmortalStackResult { ok_payload; err_payload; _ } ->
      emit_immortalize_stack_result ctx c_expr ok_payload err_payload
  | ImmortalList { list_elem_plan; _ } ->
      emit_immortalize_list ctx c_expr list_elem_plan
  | ImmortalDict { dict_key_plan; dict_value_plan; _ } ->
      emit_immortalize_dict ctx c_expr dict_key_plan dict_value_plan

and emit_immortalize_record ctx c_expr record_fields =
  emit_make_immortal_root ctx c_expr;
  List.iter
    (fun { gc_field_name; gc_field_plan } ->
      emit_immortalize_plan ctx
        (Printf.sprintf "%s->%s" c_expr (escape_c_ident gc_field_name))
        gc_field_plan)
    record_fields

and emit_immortalize_list ctx c_expr elem_plan =
  emit_make_immortal_root ctx c_expr;
  match elem_plan with
  | None -> ()
  | Some elem_plan ->
      let helper = global_container_element_immortalizer ctx elem_plan in
      emit_line ctx
        (Printf.sprintf "blorp_make_immortal_list_constant(%s, %s);" c_expr
           helper)

and emit_immortalize_dict ctx c_expr key_plan value_plan =
  emit_make_immortal_root ctx c_expr;
  let helper_or_null = function
    | None -> "NULL"
    | Some plan -> global_container_element_immortalizer ctx plan
  in
  match (key_plan, value_plan) with
  | None, None -> ()
  | _ ->
      emit_line ctx
        (Printf.sprintf "blorp_make_immortal_dict_constant(%s, %s, %s);" c_expr
           (helper_or_null key_plan)
           (helper_or_null value_plan))

and emit_immortalize_tuple ctx c_expr tuple_elements =
  emit_make_immortal_root ctx c_expr;
  List.iter
    (fun { gc_tuple_index; gc_tuple_plan } ->
      let bit = 1 lsl gc_tuple_index in
      let slot = Printf.sprintf "%s->elem[%d]" c_expr gc_tuple_index in
      emit_line ctx
        (Printf.sprintf "if ((%s->release_mask & %dUL) && %s) {" c_expr bit slot);
      ctx.indent <- ctx.indent + 1;
      emit_immortalize_plan ctx
        (cast_void_payload_for_type ctx
           (global_constant_plan_type gc_tuple_plan)
           slot)
        gc_tuple_plan;
      ctx.indent <- ctx.indent - 1;
      emit_line ctx "}")
    tuple_elements

and emit_immortalize_union ctx c_expr type_name union_variants =
  emit_make_immortal_root ctx c_expr;
  let field_storage =
    if Codegen_types.union_uses_typed_payload_storage ctx.reg type_name then
      DirectTypedStorage
    else VoidPointerPayload
  in
  if
    List.exists
      (fun { gc_variant_fields; _ } -> gc_variant_fields <> [])
      union_variants
  then begin
    emit_line ctx (Printf.sprintf "switch (%s->tag) {" c_expr);
    ctx.indent <- ctx.indent + 1;
    List.iter
      (fun { gc_variant = variant; gc_variant_fields } ->
        match gc_variant_fields with
        | [] -> ()
        | fields ->
            emit_line ctx
              (Printf.sprintf "case %s:" (variant_tag_c_name type_name variant));
            ctx.indent <- ctx.indent + 1;
            List.iter
              (fun { gc_union_field_index; gc_union_field_plan } ->
                let bit = 1 lsl gc_union_field_index in
                let slot =
                  Printf.sprintf "%s->data.%s.field%d" c_expr
                    variant.variant_name gc_union_field_index
                in
                let payload_expr =
                  match field_storage with
                  | DirectTypedStorage -> slot
                  | VoidPointerPayload ->
                      cast_void_payload_for_type ctx
                        (global_constant_plan_type gc_union_field_plan)
                        slot
                in
                match field_storage with
                | DirectTypedStorage ->
                    emit_immortalize_plan ctx payload_expr gc_union_field_plan
                | VoidPointerPayload ->
                    emit_line ctx
                      (Printf.sprintf "if ((%s->release_mask & %dUL) && %s) {"
                         c_expr bit slot);
                    ctx.indent <- ctx.indent + 1;
                    emit_immortalize_plan ctx payload_expr gc_union_field_plan;
                    ctx.indent <- ctx.indent - 1;
                    emit_line ctx "}")
              fields;
            emit_line ctx "break;";
            ctx.indent <- ctx.indent - 1)
      union_variants;
    emit_line ctx "default:";
    ctx.indent <- ctx.indent + 1;
    emit_line ctx "break;";
    ctx.indent <- ctx.indent - 1;
    ctx.indent <- ctx.indent - 1;
    emit_line ctx "}"
  end

and emit_immortalize_stack_result ctx c_expr ok_payload err_payload =
  let emit_payload tag field = function
    | None -> ()
    | Some { gc_payload_plan } ->
        let slot = Printf.sprintf "%s.data.%s.field0" c_expr field in
        emit_line ctx
          (Printf.sprintf "if ((%s.release_mask & 1UL) && %s.tag == %s && %s) {"
             c_expr c_expr tag slot);
        ctx.indent <- ctx.indent + 1;
        emit_immortalize_plan ctx
          (cast_void_payload_for_type ctx
             (global_constant_plan_type gc_payload_plan)
             slot)
          gc_payload_plan;
        ctx.indent <- ctx.indent - 1;
        emit_line ctx "}"
  in
  emit_payload "BLORP_TAG_OK" "Ok" ok_payload;
  emit_payload "BLORP_TAG_ERR" "Err" err_payload

and global_container_element_immortalizer ctx elem_plan =
  let elem_ty = normalize_type (global_constant_plan_type elem_plan) in
  let key = Types.type_to_string elem_ty in
  match Hashtbl.find_opt ctx.global_immortalizer_helpers key with
  | Some name -> name
  | None ->
      let id = ctx.global_immortalizer_helper_counter in
      ctx.global_immortalizer_helper_counter <- id + 1;
      let name = Printf.sprintf "__blorp_immortalize_global_elem_%d" id in
      Hashtbl.add ctx.global_immortalizer_helpers key name;
      prepare_global_constant_immortal_helpers ctx elem_plan;
      emitln ctx (Printf.sprintf "static void %s(void* value) {" name);
      ctx.indent <- ctx.indent + 1;
      emit_line ctx "if (!value) return;";
      emit_immortalize_plan ctx
        (cast_void_payload_for_type ctx elem_ty "value")
        elem_plan;
      ctx.indent <- ctx.indent - 1;
      emitln ctx "}";
      emit ctx "\n";
      name

and prepare_global_constant_immortal_helpers (ctx : Core_emit_context.t)
    (plan : global_constant_immortal_plan) : unit =
  match plan with
  | ImmortalRootOnly _ -> ()
  | ImmortalRecord { record_fields; _ } ->
      List.iter
        (fun { gc_field_plan; _ } ->
          prepare_global_constant_immortal_helpers ctx gc_field_plan)
        record_fields
  | ImmortalUnion { union_variants; _ } ->
      List.iter
        (fun { gc_variant_fields; _ } ->
          List.iter
            (fun { gc_union_field_plan; _ } ->
              prepare_global_constant_immortal_helpers ctx gc_union_field_plan)
            gc_variant_fields)
        union_variants
  | ImmortalTuple { tuple_elements; _ } ->
      List.iter
        (fun { gc_tuple_plan; _ } ->
          prepare_global_constant_immortal_helpers ctx gc_tuple_plan)
        tuple_elements
  | ImmortalStackResult { ok_payload; err_payload; _ } ->
      List.iter
        (function
          | None -> ()
          | Some { gc_payload_plan } ->
              prepare_global_constant_immortal_helpers ctx gc_payload_plan)
        [ ok_payload; err_payload ]
  | ImmortalList { list_elem_plan; _ } -> (
      match list_elem_plan with
      | None -> ()
      | Some elem_plan ->
          ignore (global_container_element_immortalizer ctx elem_plan))
  | ImmortalDict { dict_key_plan; dict_value_plan; _ } ->
      List.iter
        (function
          | None -> ()
          | Some plan -> ignore (global_container_element_immortalizer ctx plan))
        [ dict_key_plan; dict_value_plan ]

let emit_global_constant_immortal_init (ctx : Core_emit_context.t)
    (plan : checked_global_constant_immortalization) (v : core_var) : unit =
  let name = escape_c_ident (Var.to_c_name v.cv_name) in
  match plan with
  | CheckedNoImmortalizationNeeded -> ()
  | CheckedImmortalizeConstantGraph plan -> emit_immortalize_plan ctx name plan

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

let union_field_may_need_release (ctx : Core_emit_context.t)
    (field_ty : Ast.type_expr) (loc : Ast.loc) : bool =
  if Codegen_types.has_type_vars field_ty then true
  else boxed_value_needs_release ctx field_ty loc

let union_uses_typed_payload_storage (ctx : Core_emit_context.t) type_name =
  Codegen_types.union_uses_typed_payload_storage ctx.reg type_name

let union_field_storage_c_type (ctx : Core_emit_context.t) type_name field_ty =
  if union_uses_typed_payload_storage ctx type_name then type_to_c ctx field_ty
  else "void*"

let union_field_requires_destructor_release (ctx : Core_emit_context.t)
    type_name field_ty loc =
  if union_uses_typed_payload_storage ctx type_name then
    type_requires_release ctx field_ty
  else union_field_may_need_release ctx field_ty loc

let union_variant_needs_release_mask (ctx : Core_emit_context.t) type_name
    (v : Ast.variant) : bool =
  (not (union_uses_typed_payload_storage ctx type_name))
  && List.exists
       (fun field_ty -> union_field_may_need_release ctx field_ty v.variant_loc)
       v.variant_fields

let union_type_has_release_mask (ctx : Core_emit_context.t) (t : Ast.type_decl)
    : bool =
  List.exists (union_variant_needs_release_mask ctx t.type_name) t.type_variants

let union_constructor_needs_release_mask (ctx : Core_emit_context.t) type_name
    ctor_name : bool =
  match Codegen_types.lookup_union_variant ctx.reg type_name ctor_name with
  | Some variant -> union_variant_needs_release_mask ctx type_name variant
  | None -> true

let union_constructor_needs_release_mask_for_type (ctx : Core_emit_context.t)
    (result_ty : Ast.type_expr) ctor_name : bool =
  match normalize_type result_ty with
  | Ast.TyNamed (type_name, _) ->
      union_constructor_needs_release_mask ctx type_name ctor_name
  | _ -> true

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

let dict_value_needs_release ctx dict_ty loc =
  match normalize_type dict_ty with
  | Ast.TyNamed ("Dict", [ _key_ty; value_ty ]) ->
      boxed_value_needs_release ctx value_ty loc
  | _ -> false

let boxed_value_release_arg ctx ty loc =
  if boxed_value_needs_release ctx ty loc then Blorp_prepared.ElemReleaseFn
  else Blorp_prepared.NoElemRelease

let hash_container_constructor_parts ctx loc key_ty =
  let hash_fn =
    trait_method_c_name_for_type ctx ~loc "Hashable" "hash" key_ty
  in
  let equals_fn =
    trait_method_c_name_for_type ctx ~loc "Equatable" "equals" key_ty
  in
  let release_arg = boxed_value_release_arg ctx key_ty loc in
  (hash_fn, equals_fn, release_arg)

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
      match Core_emit_util.tensor_element_storage ctx tensor_ty.elem_ty with
      | Core_layout_type.TensorElementInlineStruct c_ty -> Some c_ty
      | Core_layout_type.TensorElementRawScalar _
      | Core_layout_type.TensorElementPackedBits _
      | Core_layout_type.TensorElementBoxed ->
          None)
  | None -> None

let tensor_fill_factory_uses_direct_layout ctx ty loc =
  let layout = Core_emit_util.tensor_storage_layout_of_type ctx ty loc in
  match layout.tsl_slots with
  | TensorRawScalarStorage _ | TensorPackedStorage _ -> true
  | _ -> false

let tensor_arg_element_needs_release ctx args loc =
  match args with
  | arr :: _ -> tensor_element_needs_release ctx arr.ty loc
  | [] -> false

let channel_element_type ctx ty =
  match Core_layout_type.canonical_type ~reg:ctx.reg ty with
  | Ast.TyNamed
      (("Channel" | "std/channel::Channel" | "std_channel__Channel"), [ elem ])
    ->
      Some elem
  | _ -> None

let channel_element_needs_release ctx ty loc =
  match channel_element_type ctx ty with
  | Some elem -> boxed_value_needs_release ctx elem loc
  | None -> false

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

let task_closure_env_release_mask (ctx : Core_emit_context.t)
    (captures : task_capture list) : int =
  captures
  |> List.mapi (fun i capture ->
      match capture.task_capture_kind with
      | (TaskCopyCapture | TaskMoveResourceItem)
        when capture_slot_needs_release ctx capture.task_capture_ty ->
          1 lsl i
      | TaskCopyCapture | TaskMoveResourceItem | TaskStructuredTaskBorrow -> 0)
  |> List.fold_left ( lor ) 0

let emit_task_closure_env_release_mask_stmt (ctx : Core_emit_context.t)
    (tmp : string) (captures : task_capture list) : unit =
  let mask = task_closure_env_release_mask ctx captures in
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
     §10. Concurrency emit     — [CConcurrent] / [CDetach] / [CConcurrentlyLoop] (~2490)
     §11. Collection / init    — hoisted lambdas + global init (~2643)
   ============================================================================ *)

(* --- §1. emit_intrinsic ----------------------------------------------------- *)

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
            Core_emit_util.tensor_storage_layout_of_elem ctx elem_ty loc
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
  Core_emit_intrinsic.emit ~emit_expr ~emit_stmt ~emit_boxed ~emit_boxed_storage
    ~type_to_c ctx e name args

and blorp_backend_emitters () =
  {
    Core_emit_blorp_backend.emit_expr;
    emit_stmt;
    emit_boxed_core = emit_boxed;
    emit_boxed_storage;
    type_to_c;
  }

and emit_blorp_backend ctx node =
  Core_emit_blorp_backend.emit (blorp_backend_emitters ()) ctx node

and emit_dict_construct_result ctx e ctor_arg =
  emit_blorp_backend ctx
    (DictConstructResult
       {
         ctor_arg;
         value_needs_release = dict_value_needs_release ctx e.ty e.loc;
       })

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
          emit ctx
            (Printf.sprintf
               "blorp_box_stack_result(blorp_stack_result_retain_value(%s))" tmp)
      | BoxStruct _ ->
          emit ctx (Printf.sprintf "blorp_box_struct(&%s, sizeof(%s))" tmp c_ty)
      | BoxVoid -> assert false);
      emit ctx "; })"

and emit_boxed_storage (ctx : Core_emit_context.t) (value : boxed_storage_value)
    : unit =
  emit_box_op ctx value.bsv_box

and render_expr_arg ctx value =
  Core_emit_blorp_template.render_arg ~emit_expr ctx value

and render_stmt_arg ctx value =
  Core_emit_blorp_template.render_arg ~emit_expr:emit_stmt ctx value

and render_boxed_arg ctx value =
  Core_emit_blorp_template.render_arg ~emit_expr:emit_boxed ctx value

and render_boxed_storage_arg ctx value =
  Core_emit_blorp_template.render_arg ~emit_expr:emit_boxed_storage ctx value

and constructor_argument_list args = String.concat ", " args

and constructor_mask_arg = function
  | Some mask -> [ Printf.sprintf "%dUL" mask ]
  | None -> []

and render_tuple_args ctx elems =
  elems
  |> List.map (fun value ->
      Blorp_prepared.render_tuple_arg (render_boxed_storage_arg ctx value))
  |> String.concat ""

and render_tuple_retain_statements ~tuple_tmp ~retain_mask elems =
  elems
  |> List.mapi (fun i _ ->
      if retain_mask land (1 lsl i) <> 0 then
        Some
          (Blorp_prepared.render_tuple_retain_elem ~tuple:tuple_tmp
             ~index:(string_of_int i))
      else None)
  |> List.filter_map Fun.id |> String.concat " "

and emit_unbox_op (ctx : Core_emit_context.t) (u : unbox_op) : unit =
  let c_ty = type_to_c ctx u.unbox_target_ty in
  match (u.unbox_kind, u.unbox_value.desc) with
  | UnboxStruct struct_ty, CListGet get
    when get.lg_layout.lsl_slots = ListInlineStructStorage struct_ty ->
      emit_blorp_backend ctx (ListInlineStructUnboxGet { get; struct_ty })
  | UnboxStruct struct_ty, CCall (CKBuiltin "blorp_checked_get", _, [ arr; idx ])
    ->
      emit_blorp_backend ctx
        (TensorInlineStructGetChecked { tensor = arr; index = idx; struct_ty })
  | ( UnboxStruct struct_ty,
      CCall (CKIntrinsic "tensor_get_unchecked", _, [ arr; idx ]) ) ->
      emit_blorp_backend ctx
        (TensorInlineStructGetUnchecked { tensor = arr; index = idx; struct_ty })
  | ( UnboxStruct struct_ty,
      CCall (CKBuiltin "blorp_matrix_checked_get", _, [ arr; row; col ]) ) ->
      emit_blorp_backend ctx
        (TensorInlineStructMatrixGetChecked
           { tensor = arr; row; col; struct_ty })
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

and render_dict_ctor_for_kind ctx loc = function
  | DictGeneric ->
      Blorp_prepared.render_dict_constructor Blorp_prepared.DictCtorGeneric
  | DictString ->
      Blorp_prepared.render_dict_constructor Blorp_prepared.DictCtorString
  | DictFloat ->
      Blorp_prepared.render_dict_constructor Blorp_prepared.DictCtorFloat
  | DictCustom key_ty ->
      let hash_fn, equals_fn, key_release =
        hash_container_constructor_parts ctx loc key_ty
      in
      Blorp_prepared.render_dict_constructor
        (Blorp_prepared.DictCtorCustom { hash_fn; equals_fn; key_release })

and emit_dict_construct ctx e dc =
  let ctor_arg = render_dict_ctor_for_kind ctx e.loc dc.dc_constructor in
  emit_blorp_backend ctx
    (DictConstructStorage
       {
         ctor_arg;
         value_needs_release = dc.dc_value_needs_release;
         force_wrapper = false;
         entries = dc.dc_entries;
       })

and set_ctor_for_kind ctx loc = function
  | SetGeneric -> Blorp_prepared.SetCtorGeneric
  | SetString -> Blorp_prepared.SetCtorString
  | SetFloat -> Blorp_prepared.SetCtorFloat
  | SetCustom elem_ty ->
      let hash_fn, equals_fn, elem_release =
        hash_container_constructor_parts ctx loc elem_ty
      in
      Blorp_prepared.SetCtorCustom { hash_fn; equals_fn; elem_release }

and emit_set_alloc ctx loc kind =
  emit_blorp_backend ctx
    (Core_emit_blorp_backend.SetAlloc (set_ctor_for_kind ctx loc kind))

and emit_tuple_construct ctx tc =
  let arity = string_of_int (List.length tc.tc_elems) in
  let args = render_tuple_args ctx tc.tc_elems in
  if tc.tc_release_mask = 0 then
    emit ctx (Blorp_prepared.render_tuple_construct ~arity ~args)
  else
    let temp_seed = string_of_int (Core_emit_context.fresh_temp ctx) in
    let tuple = Blorp_prepared.render_tuple_name temp_seed in
    let retain_statements =
      render_tuple_retain_statements ~tuple_tmp:tuple
        ~retain_mask:tc.tc_retain_mask tc.tc_elems
    in
    emit ctx
      (Blorp_prepared.render_tuple_construct_with_rc ~tuple ~arity ~args
         ~retain_statements
         ~release_mask:(string_of_int tc.tc_release_mask))

and emit_record_construct ctx rc =
  let field_args =
    List.map
      (function
        | RecordRawField (_, value) -> render_expr_arg ctx value
        | RecordErasedField (_, value) -> render_boxed_storage_arg ctx value)
      rc.rc_fields
  in
  let argument_list =
    constructor_argument_list
      (field_args @ constructor_mask_arg rc.rc_erased_release_mask)
  in
  emit ctx
    (Blorp_prepared.render_constructor_call
       ~callee:(Printf.sprintf "%s_make" rc.rc_type_name)
       ~argument_list)

and render_union_constructor_arg ctx type_name arg =
  if union_uses_typed_payload_storage ctx type_name then
    render_expr_arg ctx arg.bsv_box.box_value
  else render_boxed_storage_arg ctx arg

and emit_union_construct ctx uc =
  let option_constructor_abi =
    match uc.uc_representation with
    | OptionUnion layout ->
        Some (Core_layout_type.option_constructor_abi_of_layout layout)
    | GenericUnion | ResultUnion _ -> None
  in
  let render_nullable_managed_payload arg =
    match normalize_type arg.bsv_box.box_source_ty with
    | Ast.TyFunc _ -> render_boxed_arg ctx arg.bsv_box.box_value
    | _ -> render_expr_arg ctx arg.bsv_box.box_value
  in
  match (uc.uc_representation, uc.uc_args) with
  | ResultUnion result_layout, [ arg ] ->
      let abi =
        Core_layout_type.stack_result_constructor_abi_of_layout result_layout
      in
      emit ctx
        (Blorp_prepared.render_stack_result_payload
           ~result_type:abi.src_result_c_type ~tag:(string_of_int uc.uc_tag)
           ~field:uc.uc_constructor_name
           ~payload:(render_boxed_storage_arg ctx arg)
           ~release_mask:(string_of_int uc.uc_release_mask))
  | ResultUnion _, _ ->
      Core_error.errorf Core_error.Emit Ast.dummy_loc
        ~hint:"stack Result constructors are represented as tag + one payload"
        "invalid stack Result constructor arity for %s" uc.uc_constructor_name
  | _ -> (
      match (option_constructor_abi, uc.uc_args) with
      | Some Core_layout_type.OptionConstructorNullableManaged, [] ->
          emit ctx (Blorp_prepared.render_constructor_nullable_none ())
      | Some Core_layout_type.OptionConstructorNullableManaged, [ arg ] ->
          emit ctx
            (Blorp_prepared.render_constructor_nullable_payload
               ~payload:(render_nullable_managed_payload arg))
      | Some Core_layout_type.OptionConstructorNullableManaged, _ ->
          Core_error.errorf Core_error.Emit Ast.dummy_loc
            ~hint:
              "nullable managed Option constructors are represented as NULL or \
               one managed payload pointer"
            "invalid nullable managed Option constructor arity for %s"
            uc.uc_constructor_name
      | Some (Core_layout_type.OptionConstructorStackInline abi), [] ->
          emit ctx
            (Blorp_prepared.render_stack_option_none ~option_type:abi.soe_c_type
               ~tag:(string_of_int uc.uc_tag) ~none_value:abi.soe_none_value)
      | Some (Core_layout_type.OptionConstructorStackInline abi), [ arg ]
        when is_void_ty arg.bsv_box.box_value.ty ->
          emit ctx
            (Blorp_prepared.render_stack_option_void_statement
               ~option_type:abi.soe_c_type ~tag:(string_of_int uc.uc_tag)
               ~statement:(render_stmt_arg ctx arg.bsv_box.box_value))
      | Some (Core_layout_type.OptionConstructorStackInline abi), [ arg ] ->
          emit ctx
            (Blorp_prepared.render_stack_option_value
               ~option_type:abi.soe_c_type ~tag:(string_of_int uc.uc_tag)
               ~value:(render_expr_arg ctx arg.bsv_box.box_value))
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
          emit ctx
            (Blorp_prepared.render_constructor_symbol
               ~name:(escape_c_ident uc.uc_c_name))
      | (Some Core_layout_type.OptionConstructorBoxedUnion | None), args ->
          let needs_release_mask =
            union_constructor_needs_release_mask ctx uc.uc_type_name
              uc.uc_constructor_name
          in
          let arg_strings =
            List.map (render_union_constructor_arg ctx uc.uc_type_name) args
          in
          let release_args =
            if needs_release_mask then
              [ Printf.sprintf "%dUL" uc.uc_release_mask ]
            else []
          in
          emit ctx
            (Blorp_prepared.render_constructor_call ~callee:uc.uc_c_name
               ~argument_list:
                 (constructor_argument_list (arg_strings @ release_args))))

and emit_union_reuse_construct ctx urc =
  match urc.urc_representation with
  | GenericUnion ->
      let needs_release_mask =
        union_constructor_needs_release_mask ctx urc.urc_type_name
          urc.urc_constructor_name
      in
      let source_arg = render_expr_arg ctx urc.urc_source in
      let arg_strings =
        List.map
          (render_union_constructor_arg ctx urc.urc_type_name)
          urc.urc_args
      in
      let release_args =
        if needs_release_mask then
          [ Printf.sprintf "%dUL" urc.urc_release_mask ]
        else []
      in
      emit ctx
        (Blorp_prepared.render_constructor_call ~callee:urc.urc_reuse_c_name
           ~argument_list:
             (constructor_argument_list
                ((source_arg :: arg_strings) @ release_args)))
  | OptionUnion _ | ResultUnion _ ->
      Core_error.errorf Core_error.Emit Ast.dummy_loc
        ~hint:"union reuse is only supported for heap-allocated generic unions"
        "unsupported union reuse constructor for %s.%s" urc.urc_type_name
        urc.urc_constructor_name

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
  | CCooperativeCheckpoint -> emit ctx "blorp_cooperative_checkpoint()"
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
      if track_cleanup then begin
        emit ctx "({";
        emitln ctx "";
        ctx.indent <- ctx.indent + 1;
        emit_indent ctx;
        emit ctx (type_to_c ctx b.bind_ty);
        emit ctx " ";
        emit ctx (escape_c_ident (Var.to_c_name b.bind_var));
        emit ctx " = ";
        (match normalize_type b.bind_ty with
        | Ast.TyFunc _ -> emit_boxed ctx rhs
        | _ -> emit_expr ctx rhs);
        emitln ctx ";";
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
        let value_arg =
          cancellation_cleanup_value_arg ctx b.bind_ty ~slot_c:var_c
            ~value_c:var_c
        in
        emit_indent ctx;
        emitln ctx (Printf.sprintf "blorp_CancelCleanupFrame %s;" frame_c);
        emit_indent ctx;
        emitln ctx
          (Printf.sprintf "blorp_task_cleanup_push(&%s, &%s, %s, %s);" frame_c
             var_c value_arg release_fn);
        if is_void_ty body.ty then begin
          emit_indent ctx;
          emit_expr ctx body;
          emitln ctx ";";
          emit_indent ctx;
          emitln ctx
            (Printf.sprintf "%s;"
               (cancellation_cleanup_pop_slot_stmt b.bind_var));
          emit_indent ctx;
          emitln ctx "(void)0;";
          ctx.indent <- ctx.indent - 1;
          emitln ctx "";
          emit_indent ctx;
          emit ctx "})"
        end
        else begin
          let result_tmp =
            Printf.sprintf "__cleanup_result_%d" (fresh_temp ctx)
          in
          emit_indent ctx;
          emitln ctx
            (Printf.sprintf "%s %s =" (type_to_c ctx body.ty) result_tmp);
          ctx.indent <- ctx.indent + 1;
          emit_indent ctx;
          emit_expr ctx body;
          emitln ctx ";";
          ctx.indent <- ctx.indent - 1;
          emit_indent ctx;
          emitln ctx
            (Printf.sprintf "%s;"
               (cancellation_cleanup_pop_slot_stmt b.bind_var));
          emit_indent ctx;
          emitln ctx (result_tmp ^ ";");
          ctx.indent <- ctx.indent - 1;
          emitln ctx "";
          emit_indent ctx;
          emit ctx "})"
        end
      end
      else begin
        emit ctx "({ ";
        emit ctx (type_to_c ctx b.bind_ty);
        emit ctx " ";
        emit ctx (escape_c_ident (Var.to_c_name b.bind_var));
        emit ctx " = ";
        (match normalize_type b.bind_ty with
        | Ast.TyFunc _ -> emit_boxed ctx rhs
        | _ -> emit_expr ctx rhs);
        emit ctx "; ";
        emit_expr ctx body;
        emit ctx "; })"
      end
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
      emit_blorp_backend ctx (TensorRawViewDecl b);
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
  | CCall (CKBuiltin "blorp_dict_new_custom", _, _) ->
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
      let key_type =
        match normalize_type e.ty with
        | TyNamed ("Dict", k :: _) -> k
        | _ ->
            Core_error.errorf Core_error.Emit e.loc
              "blorp_dict_new_custom on non-Dict type"
      in
      (* A4.2: mangle the trait-method fn-ptrs to match their
         [__def_N_] decl. [ctx.trait_impl_def_ids] is populated by
         [emit_impl] as it walks each trait method. *)
      let hash_fn, equals_fn, key_release =
        hash_container_constructor_parts ctx e.loc key_type
      in
      let ctor_arg =
        Blorp_prepared.render_dict_constructor
          (Blorp_prepared.DictCtorCustom { hash_fn; equals_fn; key_release })
      in
      emit_dict_construct_result ctx e ctor_arg
  | CCall (CKBuiltin "blorp_set_new_custom", _, _) ->
      let elem_type =
        match normalize_type e.ty with
        | TyNamed ("Set", [ elem ]) -> elem
        | _ ->
            Core_error.errorf Core_error.Emit e.loc
              "blorp_set_new_custom on non-Set type"
      in
      let hash_fn, equals_fn, elem_release =
        hash_container_constructor_parts ctx e.loc elem_type
      in
      let ctor_arg =
        Blorp_prepared.render_set_constructor
          (Blorp_prepared.SetCtorCustom { hash_fn; equals_fn; elem_release })
      in
      emit_blorp_backend ctx
        (DictConstructResult { ctor_arg; value_needs_release = false })
  | CCall (CKBuiltin "blorp_dict_with_capacity_custom", _, [ cap ]) ->
      let key_type =
        match normalize_type e.ty with
        | TyNamed ("Dict", k :: _) -> k
        | _ ->
            Core_error.errorf Core_error.Emit e.loc
              "blorp_dict_with_capacity_custom on non-Dict type"
      in
      let hash_fn, equals_fn, key_release =
        hash_container_constructor_parts ctx e.loc key_type
      in
      let ctor_arg =
        Blorp_prepared.render_dict_capacity_constructor ~emit_expr ctx
          (Blorp_prepared.DictWithCapacityCustom
             { capacity = cap; hash_fn; equals_fn; key_release })
      in
      emit_dict_construct_result ctx e ctor_arg
  | CCall (CKBuiltin "blorp_dict_new", _, []) ->
      emit_dict_construct_result ctx e
        (Blorp_prepared.render_dict_constructor Blorp_prepared.DictCtorGeneric)
  | CCall (CKBuiltin "blorp_dict_new_string", _, []) ->
      emit_dict_construct_result ctx e
        (Blorp_prepared.render_dict_constructor Blorp_prepared.DictCtorString)
  | CCall (CKBuiltin "blorp_dict_new_float", _, []) ->
      emit_dict_construct_result ctx e
        (Blorp_prepared.render_dict_constructor Blorp_prepared.DictCtorFloat)
  | CCall (CKBuiltin "blorp_dict_with_capacity", _, [ cap ]) ->
      emit_dict_construct_result ctx e
        (Blorp_prepared.render_dict_capacity_constructor ~emit_expr ctx
           (Blorp_prepared.DictWithCapacityGeneric cap))
  | CCall (CKBuiltin "blorp_dict_with_capacity_string", _, [ cap ]) ->
      emit_dict_construct_result ctx e
        (Blorp_prepared.render_dict_capacity_constructor ~emit_expr ctx
           (Blorp_prepared.DictWithCapacityString cap))
  | CCall (CKBuiltin "blorp_dict_with_capacity_float", _, [ cap ]) ->
      emit_dict_construct_result ctx e
        (Blorp_prepared.render_dict_capacity_constructor ~emit_expr ctx
           (Blorp_prepared.DictWithCapacityFloat cap))
  | CCall (CKBuiltin "blorp_list_new", _, [ cap ]) ->
      emit_blorp_backend ctx
        (ListAllocForType { ty = e.ty; loc = e.loc; capacity = cap })
  | CCall (CKBuiltin "blorp_channel_new", _, [ cap ])
    when channel_element_needs_release ctx e.ty e.loc ->
      emit_blorp_backend ctx (ChannelAllocWithElemRelease cap)
  | CCall
      ( CKBuiltin
          ("blorp_tensor3_new" | "blorp_tensor4_new" | "blorp_tensor5_new"),
        _,
        value :: dims )
    when tensor_fill_factory_uses_direct_layout ctx e.ty e.loc ->
      let layout =
        Core_emit_util.tensor_storage_layout_of_type ctx e.ty e.loc
      in
      emit_blorp_backend ctx
        (TensorDirectFillFactory { loc = e.loc; layout; value; dims })
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
      emit_blorp_backend ctx
        (TensorFillInlineStruct
           { function_name = ctor; value; dims; struct_ty = c_ty })
  | CCall
      ( CKBuiltin
          (( "blorp_vector_new_fill" | "blorp_matrix_new_fill"
           | "blorp_tensor3_new" | "blorp_tensor4_new" | "blorp_tensor5_new" )
           as ctor),
        _,
        value :: dims )
    when tensor_element_needs_release ctx e.ty e.loc ->
      let fill_value_policy =
        if boxed_expr_transfers_ownership ctx value then
          Blorp_prepared.ReleaseFillValue
        else Blorp_prepared.KeepFillValue
      in
      emit_blorp_backend ctx
        (TensorFillBoxed
           { function_name = ctor; value; dims; fill_value_policy })
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
          let strip_pointer_suffix c_ty =
            let c_ty = String.trim c_ty in
            let len = String.length c_ty in
            if len > 0 && c_ty.[len - 1] = '*' then
              String.trim (String.sub c_ty 0 (len - 1))
            else c_ty
          in
          let constructor_c_name_for_return ~contract ctor_name =
            let type_c_name = strip_pointer_suffix (type_to_c ctx e.ty) in
            let candidates =
              match normalize_type e.ty with
              | Ast.TyNamed (type_name, _) -> [ type_name; type_c_name ]
              | _ -> [ type_c_name ]
            in
            let rec find = function
              | [] ->
                  Core_error.errorf Core_error.Emit e.loc
                    ~hint:
                      (Printf.sprintf
                         "%s must return the expected std/channel union so \
                          generated C can construct `%s` from the runtime \
                          status."
                         contract ctor_name)
                    "missing channel attempt constructor `%s` during C emission"
                    ctor_name
              | type_name :: rest -> (
                  match
                    Hashtbl.find_opt ctx.constructor_c_names_by_type
                      (type_name, ctor_name)
                  with
                  | Some name -> name
                  | None -> find rest)
            in
            find candidates
          in
          let callee_is_registered_constructor ctor_name =
            match callee.desc with
            | CVar v -> Hashtbl.mem ctx.constructor_names v.vname
            | CField (_, field) -> Hashtbl.mem ctx.constructor_names field
            | _ -> Hashtbl.mem ctx.constructor_names ctor_name
          in
          let try_emit_channel_send_with_boxed_temp_cleanup () =
            let emit_retaining_send_no_timeout runtime ch value =
              let result_type = type_to_c ctx e.ty in
              emit_blorp_backend ctx
                (ChannelRetainingSend
                   (Blorp_prepared.ChannelRetainingSendNoTimeout
                      { runtime; result_type; channel = ch; value }))
            in
            let emit_retaining_send_with_timeout runtime ch value timeout =
              let result_type = type_to_c ctx e.ty in
              emit_blorp_backend ctx
                (ChannelRetainingSend
                   (Blorp_prepared.ChannelRetainingSendWithTimeout
                      { runtime; result_type; channel = ch; value; timeout }))
            in
            match (kind, args) with
            | CKBuiltin "blorp_channel_send", [ ch; value ]
              when boxed_expr_temp_needs_release ctx value ->
                emit_retaining_send_no_timeout Blorp_prepared.ChannelSendRuntime
                  ch value;
                true
            | CKBuiltin "blorp_channel_try_send", [ ch; value ]
              when boxed_expr_temp_needs_release ctx value ->
                emit_retaining_send_no_timeout
                  Blorp_prepared.ChannelTrySendRuntime ch value;
                true
            | CKBuiltin "blorp_channel_try_send_status", [ ch; value ]
              when boxed_expr_temp_needs_release ctx value ->
                emit_retaining_send_no_timeout
                  Blorp_prepared.ChannelTrySendStatusRuntime ch value;
                true
            | CKBuiltin "blorp_channel_send_timeout", [ ch; value; timeout ]
              when boxed_expr_temp_needs_release ctx value ->
                emit_retaining_send_with_timeout
                  Blorp_prepared.ChannelSendTimeoutRuntime ch value timeout;
                true
            | ( CKBuiltin "blorp_channel_send_timeout_status",
                [ ch; value; timeout ] )
              when boxed_expr_temp_needs_release ctx value ->
                emit_retaining_send_with_timeout
                  Blorp_prepared.ChannelSendTimeoutStatusRuntime ch value
                  timeout;
                true
            | _ -> false
          in
          let try_emit_channel_send_attempt () =
            let send_attempt_value value =
              if boxed_expr_temp_needs_release ctx value then
                Blorp_prepared.ChannelSendAttemptRetainedValue value
              else Blorp_prepared.ChannelSendAttemptDirectValue value
            in
            let send_attempt_constructors () =
              let constructor_c_name =
                constructor_c_name_for_return ~contract:"send attempt"
              in
              {
                Blorp_prepared.accepted = constructor_c_name "SendAccepted";
                would_block = constructor_c_name "SendWouldBlock";
                sealed = constructor_c_name "SendSealed";
                timed_out = constructor_c_name "SendTimedOut";
              }
            in
            match (kind, args, normalize_type e.ty) with
            | CKBuiltin "blorp_channel_try_send_attempt", [ ch; value ], _ ->
                emit_blorp_backend ctx
                  (ChannelSendAttempt
                     (Blorp_prepared.ChannelTrySendAttempt
                        {
                          result_type = type_to_c ctx e.ty;
                          channel = ch;
                          value = send_attempt_value value;
                          constructors = send_attempt_constructors ();
                        }));
                true
            | ( CKBuiltin "blorp_channel_send_timeout_attempt",
                [ ch; value; timeout_ms ],
                _ ) ->
                emit_blorp_backend ctx
                  (ChannelSendAttempt
                     (Blorp_prepared.ChannelSendTimeoutAttempt
                        {
                          result_type = type_to_c ctx e.ty;
                          channel = ch;
                          value = send_attempt_value value;
                          timeout = timeout_ms;
                          constructors = send_attempt_constructors ();
                        }));
                true
            | _ -> false
          in
          let try_emit_channel_recv_attempt () =
            let recv_attempt_release_policy elem_ty =
              if boxed_value_needs_release ctx elem_ty e.loc then
                Blorp_prepared.ReleaseRecvValue
              else Blorp_prepared.KeepRecvValue
            in
            let recv_attempt_constructors empty_ctor_name =
              let constructor_c_name =
                constructor_c_name_for_return ~contract:"recv attempt"
              in
              {
                Blorp_prepared.value = constructor_c_name "RecvValue";
                sealed = constructor_c_name "RecvSealed";
                empty = constructor_c_name empty_ctor_name;
              }
            in
            let recv_value_constructor_takes_release_mask () =
              union_constructor_needs_release_mask_for_type ctx e.ty "RecvValue"
            in
            match (kind, args) with
            | CKBuiltin "blorp_channel_try_recv_attempt", [ ch ] -> (
                match channel_element_type ctx ch.ty with
                | None -> false
                | Some elem_ty ->
                    emit_blorp_backend ctx
                      (ChannelRecvAttempt
                         (Blorp_prepared.ChannelTryRecvAttempt
                            {
                              result_type = type_to_c ctx e.ty;
                              channel = ch;
                              release_policy =
                                recv_attempt_release_policy elem_ty;
                              value_constructor_takes_release_mask =
                                recv_value_constructor_takes_release_mask ();
                              constructors =
                                recv_attempt_constructors "RecvWouldBlock";
                            }));
                    true)
            | CKBuiltin "blorp_channel_recv_timeout_attempt", [ ch; timeout_ms ]
              -> (
                match channel_element_type ctx ch.ty with
                | None -> false
                | Some elem_ty ->
                    emit_blorp_backend ctx
                      (ChannelRecvAttempt
                         (Blorp_prepared.ChannelRecvTimeoutAttempt
                            {
                              result_type = type_to_c ctx e.ty;
                              channel = ch;
                              timeout = timeout_ms;
                              release_policy =
                                recv_attempt_release_policy elem_ty;
                              value_constructor_takes_release_mask =
                                recv_value_constructor_takes_release_mask ();
                              constructors =
                                recv_attempt_constructors "RecvTimedOut";
                            }));
                    true)
            | _ -> false
          in
          let try_emit_stack_option_ctor () =
            let emit_some c_ty arg =
              let rendered =
                if is_void_ty arg.ty then
                  Blorp_prepared.render_stack_option_void_statement
                    ~option_type:c_ty ~tag:"BLORP_TAG_SOME"
                    ~statement:(render_stmt_arg ctx arg)
                else
                  Blorp_prepared.render_stack_option_value ~option_type:c_ty
                    ~tag:"BLORP_TAG_SOME" ~value:(render_expr_arg ctx arg)
              in
              emit ctx rendered
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
                  (Blorp_prepared.render_stack_option_none ~option_type:c_ty
                     ~tag:"BLORP_TAG_NONE"
                     ~none_value:
                       (Core_layout_type.stack_option_none_value_for_type
                          ~reg:ctx.reg e.ty));
                true
            | _ -> false
          in
          let try_emit_stack_result_ctor () =
            let result_payload_release_mask arg =
              if boxed_value_needs_release ctx arg.ty arg.loc then "1" else "0"
            in
            let emit_stack_result_ctor c_ty tag field arg =
              emit ctx
                (Blorp_prepared.render_stack_result_payload ~result_type:c_ty
                   ~tag ~field ~payload:(render_boxed_arg ctx arg)
                   ~release_mask:(result_payload_release_mask arg))
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
                emit_blorp_backend ctx
                  (TensorStackOptionVectorGet { abi; tensor = arr; index = idx });
                true
            | CKBuiltin "blorp_matrix_get_opt", [ arr; row; col ], Some abi ->
                emit_blorp_backend ctx
                  (TensorStackOptionMatrixGet { abi; tensor = arr; row; col });
                true
            | CKBuiltin "blorp_dict_get", [ dict; key ], Some abi ->
                let key_release_policy =
                  if boxed_expr_transfers_ownership ctx key then
                    Blorp_prepared.ReleaseKey
                  else Blorp_prepared.KeepKey
                in
                emit_blorp_backend ctx
                  (DictStackOptionGet { abi; dict; key; key_release_policy });
                true
            | _ -> false
          in
          if try_emit_channel_send_with_boxed_temp_cleanup () then ()
          else if try_emit_channel_send_attempt () then ()
          else if try_emit_channel_recv_attempt () then ()
          else if try_emit_stack_option_ctor () then ()
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
                let operation_error_type_name
                    (bridge : Operation_result_metadata.result_bridge) err_ty =
                  match normalize_type (expand_alias ~reg:ctx.reg err_ty) with
                  | Ast.TyNamed (name, [])
                    when List.mem name
                           bridge.Operation_result_metadata.error
                             .accepted_type_names ->
                      name
                  | Ast.TyNamed (name, []) ->
                      Core_error.errorf Core_error.Emit e.loc
                        ~hint:
                          (Printf.sprintf
                             "runtime operation `%s` is registered with a \
                              specific error bridge; add a separate operation \
                              metadata entry before using another error type"
                             bridge.builtin_name)
                        "runtime operation `%s` error payload has unsupported \
                         type `%s`"
                        bridge.builtin_name name
                  | other ->
                      Core_error.errorf Core_error.Emit e.loc
                        ~hint:
                          (Printf.sprintf
                             "runtime operation `%s` must return Result[..., \
                              E] where E matches its operation metadata"
                             bridge.builtin_name)
                        "runtime operation `%s` error payload has unsupported \
                         type `%s`"
                        bridge.builtin_name
                        (Types.type_to_string other)
                in
                let operation_error_ctor
                    (bridge : Operation_result_metadata.result_bridge) err_name
                    ctor_name =
                  match
                    Hashtbl.find_opt ctx.constructor_c_names_by_type
                      (err_name, ctor_name)
                  with
                  | Some ctor_c -> ctor_c
                  | None ->
                      Core_error.errorf Core_error.Emit e.loc
                        ~hint:
                          (Printf.sprintf
                             "constructors for runtime operation `%s` error \
                              type must be visible to the C emitter before \
                              operation result bridge emission"
                             bridge.builtin_name)
                        "missing runtime operation error constructor `%s.%s`"
                        err_name ctor_name
                in
                let emit_operation_error_case
                    (bridge : Operation_result_metadata.result_bridge) state_tmp
                    err_tmp err_name runtime_tag ctor_name =
                  emit ctx (Printf.sprintf "case %s: " runtime_tag);
                  emit ctx
                    (Printf.sprintf
                       "%s = %s((void*)%s.%s, %s.%s ? 1UL : 0UL); break; "
                       err_tmp
                       (operation_error_ctor bridge err_name ctor_name)
                       state_tmp bridge.error.detail_field state_tmp
                       bridge.error.detail_field)
                in
                let emit_operation_error_switch_cases
                    (bridge : Operation_result_metadata.result_bridge) state_tmp
                    err_tmp err_name =
                  List.iter
                    (fun {
                           Operation_result_metadata.runtime_tag;
                           constructor_name;
                         } ->
                      emit_operation_error_case bridge state_tmp err_tmp
                        err_name runtime_tag constructor_name)
                    bridge.error.cases
                in
                let try_emit_fallible_stream_result_bridge () =
                  let stream_operation_spec = function
                    | CKBuiltin name ->
                        Operation_result_metadata.find_fallible_stream_terminal
                          name
                    | _ -> None
                  in
                  let ok_payload_matches payload ok_ty =
                    match
                      (payload, normalize_type (expand_alias ~reg:ctx.reg ok_ty))
                    with
                    | ( Operation_result_metadata.StreamPayloadList,
                        Ast.TyNamed ("List", _) ) ->
                        true
                    | ( Operation_result_metadata.StreamPayloadInt,
                        Ast.TyNamed ("Int", []) ) ->
                        true
                    | ( Operation_result_metadata.StreamPayloadBool,
                        Ast.TyNamed ("Bool", []) ) ->
                        true
                    | ( Operation_result_metadata.StreamPayloadOption,
                        Ast.TyNamed ("Option", [ _ ]) ) ->
                        true
                    | Operation_result_metadata.StreamPayloadErased, _ -> true
                    | _ -> false
                  in
                  let ok_payload_release_mask payload ok_ty =
                    match payload with
                    | Operation_result_metadata.StreamPayloadList -> 1
                    | Operation_result_metadata.StreamPayloadErased
                    | Operation_result_metadata.StreamPayloadOption ->
                        if boxed_value_needs_release ctx ok_ty e.loc then 1
                        else 0
                    | Operation_result_metadata.StreamPayloadInt
                    | Operation_result_metadata.StreamPayloadBool ->
                        0
                  in
                  let emit_ok_payload op_tmp _payload =
                    emit ctx (Printf.sprintf "(void*)%s.value" op_tmp)
                  in
                  let emit_arg_list args =
                    List.iteri
                      (fun i arg ->
                        if i > 0 then emit ctx ", ";
                        emit_expr ctx arg)
                      args
                  in
                  let emit_stream_operation_args payload ok_ty args =
                    emit_arg_list args;
                    match payload with
                    | Operation_result_metadata.StreamPayloadList ->
                        let layout =
                          Core_emit_util.list_storage_layout_of_type ctx ok_ty
                            e.loc
                        in
                        let storage_mode, elem_size =
                          Blorp_prepared.list_runtime_storage_args layout
                        in
                        emit ctx
                          (Printf.sprintf ", %s, %s" storage_mode elem_size)
                    | Operation_result_metadata.StreamPayloadInt
                    | Operation_result_metadata.StreamPayloadBool
                    | Operation_result_metadata.StreamPayloadOption
                    | Operation_result_metadata.StreamPayloadErased ->
                        ()
                  in
                  let stream_error_type_name err_ty =
                    match normalize_type (expand_alias ~reg:ctx.reg err_ty) with
                    | Ast.TyNamed (name, [])
                      when List.mem name
                             Operation_result_metadata.file_error_mapping
                               .accepted_type_names ->
                        ( "BLORP_FALLIBLE_STREAM_ERROR_DOMAIN_FILE",
                          Operation_result_metadata.file_error_mapping,
                          name )
                    | Ast.TyNamed (name, [])
                      when List.mem name
                             Operation_result_metadata.udp_error_mapping
                               .accepted_type_names ->
                        ( "BLORP_FALLIBLE_STREAM_ERROR_DOMAIN_UDP",
                          Operation_result_metadata.udp_error_mapping,
                          name )
                    | Ast.TyNamed (name, [])
                      when List.mem name
                             Operation_result_metadata.tcp_error_mapping
                               .accepted_type_names ->
                        ( "BLORP_FALLIBLE_STREAM_ERROR_DOMAIN_TCP",
                          Operation_result_metadata.tcp_error_mapping,
                          name )
                    | Ast.TyNamed (name, [])
                      when List.mem name
                             Operation_result_metadata.tls_error_mapping
                               .accepted_type_names ->
                        ( "BLORP_FALLIBLE_STREAM_ERROR_DOMAIN_TLS",
                          Operation_result_metadata.tls_error_mapping,
                          name )
                    | Ast.TyNamed (name, []) ->
                        Core_error.errorf Core_error.Emit e.loc
                          ~hint:
                            "fallible stream terminal operations must return \
                             Result[..., E] where E matches a registered \
                             fallible-stream error domain"
                          "fallible stream error payload has unsupported type \
                           `%s`"
                          name
                    | other ->
                        Core_error.errorf Core_error.Emit e.loc
                          ~hint:
                            "fallible stream terminal operations must return \
                             Result[..., E]"
                          "fallible stream error payload has unsupported type \
                           `%s`"
                          (Types.type_to_string other)
                  in
                  let stream_error_ctor err_name ctor_name =
                    match
                      Hashtbl.find_opt ctx.constructor_c_names_by_type
                        (err_name, ctor_name)
                    with
                    | Some ctor_c -> ctor_c
                    | None ->
                        Core_error.errorf Core_error.Emit e.loc
                          ~hint:
                            "constructors for fallible stream error types must \
                             be visible to the C emitter before terminal \
                             operation emission"
                          "missing fallible stream error constructor `%s.%s`"
                          err_name ctor_name
                  in
                  let emit_stream_error_case op_tmp err_tmp err_name runtime_tag
                      ctor_name =
                    emit ctx (Printf.sprintf "case %s: " runtime_tag);
                    emit ctx
                      (Printf.sprintf
                         "%s = %s((void*)%s.error.detail, %s.error.detail ? \
                          1UL : 0UL); break; "
                         err_tmp
                         (stream_error_ctor err_name ctor_name)
                         op_tmp op_tmp)
                  in
                  let emit_stream_error_value domain_tag mapping op_tmp err_tmp
                      err_name =
                    emit ctx
                      (Printf.sprintf
                         "if (%s.error.domain == %s) { switch (%s.error.kind) \
                          { "
                         op_tmp domain_tag op_tmp);
                    List.iter
                      (fun {
                             Operation_result_metadata.runtime_tag;
                             constructor_name;
                           } ->
                        emit_stream_error_case op_tmp err_tmp err_name
                          runtime_tag constructor_name)
                      mapping.Operation_result_metadata.cases;
                    let ctor =
                      stream_error_ctor err_name
                        mapping.Operation_result_metadata.other_constructor
                    in
                    let detail_tmp =
                      Printf.sprintf "__stream_error_detail_%d" (fresh_temp ctx)
                    in
                    emit ctx
                      (Printf.sprintf
                         "default: %s = %s((void*)%s.error.detail, \
                          %s.error.detail ? 1UL : 0UL); break; } } else { \
                          blorp_String* %s = %s.error.detail ? %s.error.detail \
                          : blorp_string_literal(\"fallible stream error \
                          domain mismatch\"); %s = %s((void*)%s, \
                          %s.error.detail ? 1UL : 0UL); } "
                         err_tmp ctor op_tmp op_tmp detail_tmp op_tmp op_tmp
                         err_tmp ctor detail_tmp op_tmp)
                  in
                  match
                    ( stream_operation_spec kind,
                      normalize_type (expand_alias ~reg:ctx.reg e.ty) )
                  with
                  | ( Some
                        ({
                           Operation_result_metadata.runtime_c_name = op_c_name;
                           runtime_result_c_type = op_result_c;
                           payload;
                           _;
                         } :
                          Operation_result_metadata.fallible_stream_terminal),
                      Ast.TyNamed ("Result", [ ok_ty; err_ty ]) )
                    when ok_payload_matches payload ok_ty ->
                      let domain_tag, mapping, err_name =
                        stream_error_type_name err_ty
                      in
                      let result_c = type_to_c ctx e.ty in
                      let err_c = type_to_c ctx err_ty in
                      let op_tmp =
                        Printf.sprintf "__stream_op_%d" (fresh_temp ctx)
                      in
                      let result_tmp =
                        Printf.sprintf "__stream_result_%d" (fresh_temp ctx)
                      in
                      let err_tmp =
                        Printf.sprintf "__stream_error_%d" (fresh_temp ctx)
                      in
                      let stack_result =
                        Core_layout_type.stack_result_c_type ~reg:ctx.reg e.ty
                        <> None
                      in
                      emit ctx
                        (Printf.sprintf "({ %s %s = %s(" op_result_c op_tmp
                           op_c_name);
                      emit_stream_operation_args payload ok_ty args;
                      emit ctx "); ";
                      if stack_result then (
                        emit ctx
                          (Printf.sprintf
                             "%s %s; if (%s.error.domain == \
                              BLORP_FALLIBLE_STREAM_ERROR_DOMAIN_NONE) { %s = \
                              ((%s){ .tag = BLORP_TAG_OK, .release_mask = \
                              %dUL, .data.Ok.field0 = "
                             result_c result_tmp op_tmp result_tmp result_c
                             (ok_payload_release_mask payload ok_ty));
                        emit_ok_payload op_tmp payload;
                        emit ctx
                          (Printf.sprintf " }); } else { %s %s = NULL; " err_c
                             err_tmp);
                        emit_stream_error_value domain_tag mapping op_tmp
                          err_tmp err_name;
                        emit ctx
                          (Printf.sprintf
                             "%s = ((%s){ .tag = BLORP_TAG_ERR, .release_mask \
                              = 1UL, .data.Err.field0 = (void*)%s }); } %s; })"
                             result_tmp result_c err_tmp result_tmp))
                      else (
                        emit ctx
                          (Printf.sprintf
                             "%s %s = NULL; if (%s.error.domain == \
                              BLORP_FALLIBLE_STREAM_ERROR_DOMAIN_NONE) { %s = \
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
                                else { %s %s = NULL; "
                               result_tmp err_c err_tmp
                           else
                             Printf.sprintf "); } else { %s %s = NULL; " err_c
                               err_tmp);
                        emit_stream_error_value domain_tag mapping op_tmp
                          err_tmp err_name;
                        emit ctx
                          (Printf.sprintf
                             "%s = (%s)blorp_result_err((void*)%s); \
                              ((blorp_Result*)%s)->release_mask = 1UL; } %s; \
                              })"
                             result_tmp result_c err_tmp result_tmp result_tmp));
                      true
                  | _ -> false
                in
                let try_emit_operation_result_bridge () =
                  let operation_spec =
                    match kind with
                    | CKBuiltin name ->
                        Operation_result_metadata.find_result_bridge name
                    | _ -> None
                  in
                  let ok_payload_matches
                      (success : Operation_result_metadata.success_payload)
                      ok_ty =
                    Operation_result_metadata.success_payload_accepts_type
                      success
                      (normalize_type (expand_alias ~reg:ctx.reg ok_ty))
                  in
                  let payload_named_type_name ok_ty ~payload_kind =
                    match normalize_type (expand_alias ~reg:ctx.reg ok_ty) with
                    | Ast.TyNamed (name, _) -> name
                    | _ ->
                        Core_error.errorf Core_error.Emit e.loc
                          ~hint:
                            (Printf.sprintf
                               "operation-result %s payloads must bridge into \
                                a named type"
                               payload_kind)
                          "operation-result bridge expected named payload"
                  in
                  let runtime_union_constructor type_name constructor_name =
                    match
                      Hashtbl.find_opt ctx.constructor_c_names_by_type
                        (type_name, constructor_name)
                    with
                    | Some ctor_c -> ctor_c
                    | None ->
                        Core_error.errorf Core_error.Emit e.loc
                          ~hint:
                            (Printf.sprintf
                               "constructors for runtime operation `%s` \
                                success type must be visible to the C emitter \
                                before operation result bridge emission"
                               (match kind with
                               | CKBuiltin name -> name
                               | _ -> "<non-builtin>"))
                          "missing runtime operation success constructor \
                           `%s.%s`"
                          type_name constructor_name
                  in
                  let runtime_union_arg_release_bit i = function
                    | Operation_result_metadata.RuntimeOwnedField _ -> 1 lsl i
                    | Operation_result_metadata.RuntimeIntField _ -> 0
                  in
                  let runtime_union_release_mask args =
                    List.mapi
                      (fun i arg -> runtime_union_arg_release_bit i arg)
                      args
                    |> List.fold_left ( lor ) 0
                  in
                  let emit_runtime_union_arg op_tmp = function
                    | Operation_result_metadata.RuntimeOwnedField field ->
                        emit ctx (Printf.sprintf "(void*)%s.%s" op_tmp field)
                    | Operation_result_metadata.RuntimeIntField field ->
                        emit ctx
                          (Printf.sprintf "(void*)(intptr_t)%s.%s" op_tmp field)
                  in
                  let emit_runtime_union_payload op_tmp ok_ty
                      (payload :
                        Operation_result_metadata.runtime_success_payload) =
                    match payload with
                    | Operation_result_metadata.RuntimeUnion
                        { runtime_tag_field; cases } ->
                        let type_name =
                          payload_named_type_name ok_ty
                            ~payload_kind:"union-success"
                        in
                        let payload_tmp =
                          Printf.sprintf "__%s_payload_%d"
                            (match kind with
                            | CKBuiltin name ->
                                Codegen_names.sanitize_c_ident name
                            | _ -> "operation")
                            (fresh_temp ctx)
                        in
                        emit ctx
                          (Printf.sprintf
                             "({ void* %s = NULL; switch (%s.%s) { " payload_tmp
                             op_tmp runtime_tag_field);
                        List.iter
                          (fun (case :
                                 Operation_result_metadata.runtime_union_case)
                             ->
                            emit ctx
                              (Printf.sprintf "case %s: %s = " case.runtime_tag
                                 payload_tmp);
                            let ctor =
                              runtime_union_constructor type_name
                                case.constructor_name
                            in
                            (match case.args with
                            | [] -> emit ctx (Printf.sprintf "(void*)%s" ctor)
                            | args ->
                                emit ctx (Printf.sprintf "(void*)%s(" ctor);
                                List.iteri
                                  (fun i arg ->
                                    if i > 0 then emit ctx ", ";
                                    emit_runtime_union_arg op_tmp arg)
                                  args;
                                emit ctx
                                  (Printf.sprintf ", %dUL)"
                                     (runtime_union_release_mask args)));
                            emit ctx "; break; ")
                          cases;
                        emit ctx
                          (Printf.sprintf "default: %s = NULL; break; } %s; })"
                             payload_tmp payload_tmp)
                    | _ ->
                        Core_error.errorf Core_error.Emit e.loc
                          ~hint:
                            "operation-result union payload emission is only \
                             valid for RuntimeUnion payload metadata"
                          "invalid runtime union payload metadata"
                  in
                  let emit_ok_payload op_tmp ok_ty
                      (success : Operation_result_metadata.success_payload) =
                    match success.Operation_result_metadata.runtime_payload with
                    | Operation_result_metadata.RuntimeRecordFields fields ->
                        let record_name =
                          payload_named_type_name ok_ty
                            ~payload_kind:"record-success"
                        in
                        emit ctx (Printf.sprintf "(void*)%s_make(" record_name);
                        List.iteri
                          (fun i field ->
                            if i > 0 then emit ctx ", ";
                            emit ctx (Printf.sprintf "%s.%s" op_tmp field))
                          fields;
                        emit ctx ")"
                    | Operation_result_metadata.RuntimeField field ->
                        emit ctx (Printf.sprintf "(void*)%s.%s" op_tmp field)
                    | Operation_result_metadata.RuntimeNoPayload ->
                        emit ctx "NULL"
                    | Operation_result_metadata.RuntimeUnion _ as payload ->
                        emit_runtime_union_payload op_tmp ok_ty payload
                  in
                  let emit_arg_list args =
                    List.iteri
                      (fun i arg ->
                        if i > 0 then emit ctx ", ";
                        emit_expr ctx arg)
                      args
                  in
                  match
                    ( operation_spec,
                      normalize_type (expand_alias ~reg:ctx.reg e.ty) )
                  with
                  | Some bridge, Ast.TyNamed ("Result", [ ok_ty; err_ty ])
                    when ok_payload_matches bridge.success ok_ty ->
                      let err_name = operation_error_type_name bridge err_ty in
                      let result_c = type_to_c ctx e.ty in
                      let err_c = type_to_c ctx err_ty in
                      let op_tmp =
                        Printf.sprintf "__%s_op_%d" bridge.temp_prefix
                          (fresh_temp ctx)
                      in
                      let result_tmp =
                        Printf.sprintf "__%s_result_%d" bridge.temp_prefix
                          (fresh_temp ctx)
                      in
                      let err_tmp =
                        Printf.sprintf "__%s_error_%d" bridge.temp_prefix
                          (fresh_temp ctx)
                      in
                      let stack_result =
                        Core_layout_type.stack_result_c_type ~reg:ctx.reg e.ty
                        <> None
                      in
                      (match
                         ( bridge.Operation_result_metadata.result_layout_policy,
                           stack_result )
                       with
                      | Operation_result_metadata.BoxedResultOnly hint, true ->
                          Core_error.errorf Core_error.Emit e.loc
                            ~hint:
                              "either keep this result boxed or add an \
                               explicit stack-resource acquisition bridge \
                               before changing the layout policy"
                            "%s" hint
                      | Operation_result_metadata.BoxedResultOnly _, false
                      | Operation_result_metadata.DefaultResultLayout, _ ->
                          ());
                      emit ctx
                        (Printf.sprintf "({ %s %s = %s("
                           bridge.runtime_result_c_type op_tmp
                           bridge.runtime_c_name);
                      emit_arg_list args;
                      emit ctx "); ";
                      if stack_result then (
                        emit ctx
                          (Printf.sprintf
                             "%s %s; if (%s.error_kind == %s) { %s = ((%s){ \
                              .tag = BLORP_TAG_OK, .release_mask = %dUL, \
                              .data.Ok.field0 = "
                             result_c result_tmp op_tmp bridge.error.none_tag
                             result_tmp result_c bridge.success.release_mask);
                        emit_ok_payload op_tmp ok_ty bridge.success;
                        emit ctx
                          (Printf.sprintf
                             " }); } else { %s %s = NULL; switch \
                              (%s.error_kind) { "
                             err_c err_tmp op_tmp);
                        emit_operation_error_switch_cases bridge op_tmp err_tmp
                          err_name;
                        emit ctx
                          (Printf.sprintf
                             "default: %s = %s((void*)%s.%s, %s.%s ? 1UL : \
                              0UL); break; } %s = ((%s){ .tag = BLORP_TAG_ERR, \
                              .release_mask = 1UL, .data.Err.field0 = \
                              (void*)%s }); } %s; })"
                             err_tmp
                             (operation_error_ctor bridge err_name
                                bridge.error.other_constructor)
                             op_tmp bridge.error.detail_field op_tmp
                             bridge.error.detail_field result_tmp result_c
                             err_tmp result_tmp))
                      else (
                        emit ctx
                          (Printf.sprintf
                             "%s %s = NULL; if (%s.error_kind == %s) { %s = \
                              (%s)blorp_result_ok("
                             result_c result_tmp op_tmp bridge.error.none_tag
                             result_tmp result_c);
                        emit_ok_payload op_tmp ok_ty bridge.success;
                        let ok_release_mask = bridge.success.release_mask in
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
                        emit_operation_error_switch_cases bridge op_tmp err_tmp
                          err_name;
                        emit ctx
                          (Printf.sprintf
                             "default: %s = %s((void*)%s.%s, %s.%s ? 1UL : \
                              0UL); break; } %s = \
                              (%s)blorp_result_err((void*)%s); \
                              ((blorp_Result*)%s)->release_mask = 1UL; } %s; \
                              })"
                             err_tmp
                             (operation_error_ctor bridge err_name
                                bridge.error.other_constructor)
                             op_tmp bridge.error.detail_field op_tmp
                             bridge.error.detail_field result_tmp result_c
                             err_tmp result_tmp result_tmp));
                      true
                  | Some bridge, Ast.TyNamed ("Result", [ ok_ty; _ ]) ->
                      Core_error.errorf Core_error.Emit e.loc
                        ~hint:
                          (Printf.sprintf
                             "runtime operation `%s` must return Result[T, E] \
                              where T exactly matches the operation metadata; \
                              expected `%s`"
                             bridge.builtin_name
                             (Operation_result_metadata
                              .success_payload_expected_type bridge.success))
                        "runtime operation `%s` success payload has \
                         unsupported type `%s`"
                        bridge.builtin_name
                        (Types.type_to_string ok_ty)
                  | Some bridge, other ->
                      Core_error.errorf Core_error.Emit e.loc
                        ~hint:
                          (Printf.sprintf
                             "runtime operation `%s` must return Result[T, E] \
                              so the C result struct can be bridged into a \
                              Blorp Result"
                             bridge.builtin_name)
                        "runtime operation `%s` has unsupported return type \
                         `%s`"
                        bridge.builtin_name
                        (Types.type_to_string other)
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
                if try_emit_fallible_stream_result_bridge () then ()
                else if try_emit_operation_result_bridge () then ()
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
                      let union_constructor_name =
                        match callee.desc with
                        | CVar v when is_union_constructor -> Some v.vname
                        | CField (_, field) when is_union_constructor ->
                            Some field
                        | _ -> None
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
              parameter only when their declared fields may need release.
              For those variants the mask is computed at the call site rather
              than baked in because generic payload ownership depends on the
              monomorphic argument types. Bit [i] is set iff the boxed payload
              is owned ARC-managed heap storage. RC source values and boxed
              value-record structs are releasable; scalar bit-pattern boxes
              such as Float stay unowned. *)
                      let constructor_needs_release_mask =
                        match union_constructor_name with
                        | Some ctor_name ->
                            union_constructor_needs_release_mask_for_type ctx
                              e.ty ctor_name
                        | None -> false
                      in
                      if is_union_constructor && constructor_needs_release_mask
                      then begin
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
                            Core_emit_util.list_storage_layout_of_type ctx e.ty
                              e.loc
                          in
                          let storage_mode_c, elem_size_c =
                            Blorp_prepared.list_runtime_storage_args layout
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
                            Core_emit_util.tensor_storage_layout_of_type ctx
                              e.ty e.loc
                          in
                          let storage_mode_c, elem_size_c =
                            Blorp_prepared.tensor_runtime_storage_args layout
                          in
                          if args <> [] then emit ctx ", ";
                          emit ctx storage_mode_c;
                          emit ctx ", ";
                          emit ctx elem_size_c;
                          emit ctx ", ";
                          emit ctx
                            (Blorp_prepared.tensor_callback_result_encoding_arg
                               layout)
                      | _ -> ());
                      emit ctx ")";
                      if
                        boxed_result_return_cast
                        || Option.is_some builtin_return_cast
                      then emit ctx ")"
                end))
  | CTensorRawRead r -> emit_blorp_backend ctx (TensorRawRead r)
  | CTensorRawWrite w -> emit_blorp_backend ctx (TensorRawWriteExpr w)
  | CStringByteRead read -> emit_blorp_backend ctx (StringByteRead read)
  | CStringByteWrite write -> emit_blorp_backend ctx (StringByteWrite write)
  | CStringByteCopy copy -> emit_blorp_backend ctx (StringByteCopy copy)
  | CStringSetLen set_len -> emit_blorp_backend ctx (StringSetLen set_len)
  | CField (obj, name) -> (
      match normalize_type obj.ty with
      | TyTuple _ ->
          let render_read elem_access =
            match normalize_type e.ty with
            | Ast.TyNamed ("Float", []) ->
                Printf.sprintf "blorp_unbox_float(%s)" elem_access
            | Ast.TyNamed ("Float32", []) ->
                Printf.sprintf "blorp_unbox_float32(%s)" elem_access
            | Ast.TyNamed ("Float16", []) ->
                Printf.sprintf "blorp_unbox_float16(%s)" elem_access
            | Ast.TyNamed ("Int128", []) ->
                Printf.sprintf "blorp_unbox_int128(%s)" elem_access
            | Ast.TyNamed ("UInt128", []) ->
                Printf.sprintf "blorp_unbox_uint128(%s)" elem_access
            | Ast.TyNamed ("Int", [])
            | Ast.TyNamed ("Bool", [])
            | Ast.TyNamed ("Char", []) ->
                Printf.sprintf "(%s)(long)%s" (type_to_c ctx e.ty) elem_access
            | ty when Types.is_any_integer_type ty ->
                Printf.sprintf "(%s)(long)%s" (type_to_c ctx e.ty) elem_access
            | ty
              when Core_layout_type.stack_option_c_type ~reg:ctx.reg ty <> None
                   || Core_layout_type.stack_result_c_type ~reg:ctx.reg ty
                      <> None ->
                let c_ty = type_to_c ctx e.ty in
                Printf.sprintf "blorp_unbox_struct(%s, %s)" elem_access c_ty
            | ty when is_value_record_type ctx ty ->
                (* Value-record: the element is a [blorp_box_struct]-boxed
                   pointer, not a raw struct value. Cast-to-struct would
                   be invalid C; dereference past the object header. *)
                Printf.sprintf "blorp_unbox_struct(%s, %s)" elem_access
                  (value_record_storage_c_type ctx ty)
            | _ -> Printf.sprintf "(%s)%s" (type_to_c ctx e.ty) elem_access
          in
          let temp_seed = string_of_int (Core_emit_context.fresh_temp ctx) in
          let tuple = Blorp_prepared.render_tuple_name temp_seed in
          let source = render_expr_arg ctx obj in
          let element =
            Blorp_prepared.render_tuple_field_element ~tuple ~field:name
          in
          let read = render_read element in
          emit ctx
            (Blorp_prepared.render_tuple_field_access ~tuple ~source ~read)
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
  | CListConstruct lc -> emit_blorp_backend ctx (ListConstruct lc)
  | CTuple _ ->
      Core_error.errorf Core_error.Emit e.loc
        ~hint:
          "Core_codegen_prepare should rewrite CTuple into CTupleConstruct, \
           which carries explicit boxed storage and release-mask decisions."
        "unprepared CTuple reached emission"
  | CList _ ->
      Core_error.errorf Core_error.Emit e.loc
        ~hint:
          "Core_codegen_prepare should rewrite CList into CListConstruct, \
           which carries explicit list storage layout and element ownership \
           decisions."
        "unprepared CList reached emission"
  | CListAlloc alloc ->
      emit_blorp_backend ctx
        (ListAllocForLayout
           {
             layout = alloc.la_layout;
             loc = e.loc;
             capacity = alloc.la_capacity;
           })
  | CListGet get -> emit_blorp_backend ctx (ListGet get)
  | CRecordConstruct rc -> emit_record_construct ctx rc
  | CDictConstruct dc -> emit_dict_construct ctx e dc
  | CSetAlloc sa -> emit_set_alloc ctx e.loc sa.sa_constructor
  | CTensorLiteral tl ->
      emit_blorp_backend ctx (TensorLiteral { loc = e.loc; literal = tl })
  | CUnionConstruct uc -> emit_union_construct ctx uc
  | CUnionReuseConstruct urc -> emit_union_reuse_construct ctx urc
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
          let ctor_arg = render_dict_ctor_for_kind ctx e.loc ctor in
          emit_blorp_backend ctx
            (DictConstructResult
               {
                 ctor_arg;
                 value_needs_release = dict_value_needs_release ctx e.ty e.loc;
               })
      | TyNamed ("Set", [ elem ]), [] ->
          let ctor =
            Core_hash_container_layout.set_constructor_kind ~reg:ctx.reg elem
          in
          emit_set_alloc ctx e.loc ctor
      | ty, [] when is_tensor_type ctx ty -> emit ctx "blorp_vector_new(0)"
      | TyNamed ("List", _), [] ->
          emit_blorp_backend ctx
            (ListAllocForTypeCapacityArg
               { ty = e.ty; loc = e.loc; capacity_arg = "0" })
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
     OCaml still selects the key-specific constructor and renders boxed keys
     and values; the final C wrapper and insert statement shape live in the
     Blorp prepared-dict renderer. *)
  | CDict kvs ->
      let key_ty =
        match Core_layout_type.canonical_type ~reg:ctx.reg e.ty with
        | TyNamed ("Dict", key_ty :: _) -> key_ty
        | _ -> TyNamed ("Any", [])
      in
      let dict_ctor =
        Core_hash_container_layout.dict_constructor_kind ~reg:ctx.reg key_ty
      in
      let ctor_arg = render_dict_ctor_for_kind ctx e.loc dict_ctor in
      emit_blorp_backend ctx
        (DictConstructCore
           {
             ctor_arg;
             value_needs_release = dict_value_needs_release ctx e.ty e.loc;
             force_wrapper = true;
             entries = kvs;
           })
  | CVector _ ->
      Core_error.errorf Core_error.Emit e.loc
        ~hint:
          "Core_codegen_prepare should rewrite CVector into CTensorLiteral, \
           which carries the explicit tensor shape, storage layout, and \
           payload representation required by emission."
        "unprepared CVector reached emission"
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
      emit ctx "; ";
      let scrut_needs_release = match_scrutinee_needs_release ctx scrut in
      let scrut_cleanup_registered =
        scrut_needs_release
        && emit_owned_temp_cancellation_cleanup_push ctx ~slot_c:scrut_name
             ~value_c:scrut_name ~ty:scrut.ty
      in
      emit ctx (Printf.sprintf "%s %s; " result_ty_c result_name);
      emit_ctree_assign ctx scrut_name scrut.ty result_name tree;
      if scrut_cleanup_registered then
        emit ctx
          (Printf.sprintf "blorp_task_cleanup_pop_slot(&%s); " scrut_name);
      if scrut_needs_release then
        emit ctx
          (Printf.sprintf "%s; " (release_value_call ctx scrut.ty scrut_name));
      emit ctx (Printf.sprintf "%s; })" result_name)
  (* ---- Statement-level control flow in expression position ----
     These constructs don't produce values. If they show up here it's
     because lowering produced a tree we can't render as a C expression.
     Callers that have a statement context should use [emit_stmt]. *)
  | CWhile _ | CFor _ | CBreak | CContinue | CAssign _ | CResourceCleanupExit _
  | CSelect _ ->
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
  (* ---- Concurrency (expression/Core helper context) ---- *)
  | CConcurrent block ->
      emit ctx "({ ";
      emit_concurrent_block ctx block ~emit_tail:(fun ctx tail ->
          emit_expr ctx tail;
          emit ctx ";");
      emit ctx " })"
  | CConcurrentlyLoop cf ->
      emit ctx "({ ";
      begin match cf.cf_output with
      | ConcurrentlyLoopCollect ->
          (* Collecting Core form: std helpers such as [List.concurrent]
             synthesize this node and use the collected
             [List[Result[T, ConcurrencyError]]]. The result list lives in
             [__conc_results_<id>]; close the stmt-expr with that name so
             the surrounding helper binding gets the list, not [void]. *)
          let results_var =
            emit_concurrently_loop_collecting ~collect:true ctx cf
          in
          emit ctx (Printf.sprintf " %s;" results_var)
      | ConcurrentlyLoopDiscard ->
          ignore (emit_concurrently_loop_collecting ~collect:false ctx cf);
          emit ctx " (void)0;"
      end;
      emit ctx " })"
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
          emit_blorp_backend ctx
            (TensorInlineStructGetUnchecked
               { tensor = arr; index = idx; struct_ty = c_ty })
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
  emit_blorp_backend ctx (ListHandoff { result = e; handoff = h })

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
      emit_blorp_backend ctx (TensorRawViewDecl b);
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
  | CCooperativeCheckpoint -> emit_line ctx "blorp_cooperative_checkpoint();"
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
      let scrut_needs_release = match_scrutinee_needs_release ctx scrut in
      let scrut_cleanup_registered =
        scrut_needs_release
        && emit_owned_temp_cancellation_cleanup_push ctx ~slot_c:scrut_name
             ~value_c:scrut_name ~ty:scrut.ty
      in
      emit_ctree_stmt ctx scrut_name scrut.ty tree;
      if scrut_cleanup_registered then
        emit_line ctx
          (Printf.sprintf "blorp_task_cleanup_pop_slot(&%s);" scrut_name);
      if scrut_needs_release then
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
  | CConcurrent block -> emit_concurrent_block ctx block ~emit_tail:emit_stmt
  | CConcurrentlyLoop cf -> emit_concurrently_loop ctx cf
  | CDetach detach -> emit_detach_stmt ctx detach e.loc
  | CSelect select -> emit_select ctx select
  | CTensorRawWrite w ->
      emit_indent ctx;
      emit_blorp_backend ctx (TensorRawWriteStmt w);
      emitln ctx ""
  (* ---- Everything else: evaluate and discard the result ---- *)
  | CLit _ | CVar _ | CBin _ | CUn _ | CLog _ | CCall _ | CTensorRawRead _
  | CStringByteRead _ | CStringByteWrite _ | CStringByteCopy _ | CStringSetLen _
  | CField _ | CTuple _ | CTupleConstruct _ | CList _ | CListConstruct _
  | CListAlloc _ | CListGet _ | CVector _ | CTensorLiteral _ | CDict _
  | CDictConstruct _ | CSetAlloc _ | CRecord _ | CRecordConstruct _
  | CRecordUpdate _ | CRange _ | CLambda _ | CClosureCreate _ | CStringInterp _
  | CDebugBlock _ | CCast _ | CUnbox _ | CUnboxTyped _ | CBox _ | CBoxTyped _
  | CUnionConstruct _ | CUnionReuseConstruct _ | CListHandoff _ | CTailrecLoop _
  | CTailrecRecur _ ->
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
  let has_release_mask = union_type_has_release_mask ctx t in
  (* typedef struct Name { header; tag; optional release_mask; union { ... } data; } Name; *)
  emitln ctx (Printf.sprintf "typedef struct %s {" n);
  ctx.indent <- ctx.indent + 1;
  emit_line ctx "blorp_Object header;";
  emit_line ctx "int tag;";
  if has_release_mask then emit_line ctx "unsigned long release_mask;";
  emit_line ctx "union {";
  ctx.indent <- ctx.indent + 1;
  List.iter
    (fun (v : Ast.variant) ->
      if v.variant_fields <> [] then begin
        emit_indent ctx;
        emit ctx "struct { ";
        List.iteri
          (fun i ft ->
            emit ctx
              (Printf.sprintf "%s field%d; "
                 (union_field_storage_c_type ctx n ft)
                 i))
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
                  union_field_requires_destructor_release ctx n ft v.variant_loc)
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
      if has_destructor_body then begin
        emit_line ctx "switch (self->tag) {";
        ctx.indent <- ctx.indent + 1;
        List.iter
          (fun (v, rc_indices) ->
            if rc_indices <> [] then begin
              emit_line ctx (Printf.sprintf "case %s:" (variant_tag_c_name n v));
              ctx.indent <- ctx.indent + 1;
              List.iter
                (fun (i, _) ->
                  let field_c =
                    Printf.sprintf "self->data.%s.field%d" v.variant_name i
                  in
                  if union_uses_typed_payload_storage ctx n then
                    emit_line ctx
                      (Printf.sprintf "%s;"
                         (release_value_call ctx
                            (List.nth v.variant_fields i)
                            field_c))
                  else
                    emit_line ctx
                      (Printf.sprintf
                         "if ((self->release_mask & %dUL) && %s) \
                          blorp_release(%s);"
                         (1 lsl i) field_c field_c))
                rc_indices;
              emit_line ctx "break;";
              ctx.indent <- ctx.indent - 1
            end)
          rc_indices_by_variant;
        emit_line ctx "default:";
        ctx.indent <- ctx.indent + 1;
        emit_line ctx "break;";
        ctx.indent <- ctx.indent - 1;
        ctx.indent <- ctx.indent - 1;
        emit_line ctx "}"
      end;
      ctx.indent <- ctx.indent - 1;
      emitln ctx "}";
      emit ctx "\n");
  (* Constructor functions for non-empty variants.

     The release_mask is passed as a trailing parameter only for variants whose
     declared fields may need release. Generic union fields are typed [TyVar T]
     at the constructor site, where source-value ownership can differ from
     boxed-storage ownership; using a constant declaration-time mask would
     produce a destroy-time [blorp_release(42)] when [Option[Int]] is destroyed
     (the Int payload is non-null and "looks like" a heap pointer). Each call
     site already knows the real per-arg types post-mono, so the mask is
     computed there. Concrete primitive-only variants omit the parameter. *)
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
        let needs_release_mask = union_variant_needs_release_mask ctx n v in
        emit ctx (Printf.sprintf "%s* %s(" n ctor_c);
        List.iteri
          (fun i ft ->
            if i > 0 then emit ctx ", ";
            emit ctx
              (Printf.sprintf "%s field%d"
                 (union_field_storage_c_type ctx n ft)
                 i))
          v.variant_fields;
        if needs_release_mask then begin
          if v.variant_fields <> [] then emit ctx ", ";
          emit ctx "unsigned long release_mask"
        end;
        emitln ctx ") {";
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
        if needs_release_mask then
          emit_line ctx "__vc->release_mask = release_mask;"
        else if has_release_mask then emit_line ctx "__vc->release_mask = 0UL;";
        List.iteri
          (fun i _ ->
            emit_line ctx
              (Printf.sprintf "__vc->data.%s.field%d = field%d;" v.variant_name
                 i i))
          v.variant_fields;
        emit_line ctx "return __vc;";
        ctx.indent <- ctx.indent - 1;
        emitln ctx "}";
        emit ctx "\n";
        let reuse_c =
          Codegen_names.union_reuse_constructor_name ~type_name:n
            ~constructor_c_name:ctor_c
        in
        emit ctx (Printf.sprintf "static inline %s* %s(%s* __old" n reuse_c n);
        List.iteri
          (fun i ft ->
            emit ctx
              (Printf.sprintf ", %s field%d"
                 (union_field_storage_c_type ctx n ft)
                 i))
          v.variant_fields;
        if needs_release_mask then emit ctx ", unsigned long release_mask";
        emitln ctx ") {";
        ctx.indent <- ctx.indent + 1;
        emit_line ctx "if (__old && blorp_is_unique(__old)) {";
        ctx.indent <- ctx.indent + 1;
        (match destructor_name with
        | None -> ()
        | Some destroy_name ->
            emit_line ctx (Printf.sprintf "%s(__old);" destroy_name));
        emit_line ctx
          (Printf.sprintf "__old->tag = %s;" (variant_tag_c_name n v));
        if needs_release_mask then
          emit_line ctx "__old->release_mask = release_mask;"
        else if has_release_mask then emit_line ctx "__old->release_mask = 0UL;";
        List.iteri
          (fun i _ ->
            emit_line ctx
              (Printf.sprintf "__old->data.%s.field%d = field%d;" v.variant_name
                 i i))
          v.variant_fields;
        emit_line ctx "return __old;";
        ctx.indent <- ctx.indent - 1;
        emit_line ctx "}";
        emit ctx (Printf.sprintf "%s* __fresh = %s(" n ctor_c);
        List.iteri
          (fun i _ ->
            if i > 0 then emit ctx ", ";
            emit ctx (Printf.sprintf "field%d" i))
          v.variant_fields;
        if needs_release_mask then begin
          if v.variant_fields <> [] then emit ctx ", ";
          emit ctx "release_mask"
        end;
        emitln ctx ");";
        emit_line ctx "if (__old) blorp_release(__old);";
        emit_line ctx "return __fresh;";
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
  (* Primitive literals are scalar C static initializers. Immutable string
     literal globals use static Blorp string objects instead of startup
     materialization. *)
  match v.cv_init.desc with
  | CLit (Ast.LitString (text, _)) when can_emit_static_string_global v ->
      emit_static_string_global ctx ~name_c text
  | CListConstruct lc when can_emit_static_list_global ctx v ->
      emit_static_list_global ctx ~name_c lc
  | CTupleConstruct tc when can_emit_static_tuple_global ctx v ->
      emit_static_tuple_global ctx ~name_c tc
  | CRecordConstruct rc when can_emit_static_record_global ctx v ->
      emit_static_record_global ctx v ~name_c rc
  | CUnionConstruct uc when can_emit_static_union_global ctx v ->
      emit_static_union_global ctx v ~name_c uc
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
          cl_moved_captures = ca.ca_moved_captures;
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
      if Core.is_program_entrypoint f then emit_main_func ctx f body
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
            Codegen_types.register_union_variants ctx.reg t.type_name
              t.type_variants;
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
      when f.cf_body <> None
           && (not (Core.is_program_entrypoint f))
           && f.cf_type_params = [] ->
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
      | Ast.TyNamed (name, _) when Type_name_metadata.is_stream_name name ->
          emit_for_stream ctx binder iter body
      | Ast.TyNamed ("Range", []) -> emit_for_range_value ctx binder iter body
      | ty when is_resource_source_type ctx ty ->
          emit_for_resource_source ctx binder iter body
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

and emit_for_resource_source (ctx : Core_emit_context.t) (binder : loop_binder)
    (iter : core) (body : core) : unit =
  let id = fresh_temp ctx in
  let iter_c = Printf.sprintf "__resource_source_iter_%d" id in
  let raw_c = Printf.sprintf "__resource_source_value_%d" id in
  let var_c = escape_c_ident (Var.to_c_name binder.loop_var) in
  let elem_ty = binder.loop_ty in
  let iter_needs_release = boxed_expr_transfers_ownership ctx iter in
  emit_indent ctx;
  emit ctx (Printf.sprintf "blorp_ResourceSource* %s = " iter_c);
  emit_expr ctx iter;
  emitln ctx ";";
  let cleanup_registered =
    if iter_needs_release then
      emit_owned_temp_cancellation_cleanup_push ctx ~slot_c:iter_c
        ~value_c:iter_c ~ty:iter.ty
    else false
  in
  emit_line ctx (Printf.sprintf "void* %s = NULL;" raw_c);
  emit_indent ctx;
  emit ctx
    (Printf.sprintf "while (blorp_resource_source_next_raw(%s, &%s)) {" iter_c
       raw_c);
  emitln ctx "";
  ctx.indent <- ctx.indent + 1;
  emit_line ctx
    (Printf.sprintf "%s %s = (%s)%s;" (type_to_c ctx elem_ty) var_c
       (type_to_c ctx elem_ty) raw_c);
  emit_line ctx (Printf.sprintf "%s = NULL;" raw_c);
  emit_stmt ctx body;
  ctx.indent <- ctx.indent - 1;
  emit_indent ctx;
  emitln ctx "}";
  emit_line ctx (Printf.sprintf "%s = NULL;" raw_c);
  if iter_needs_release then begin
    if cleanup_registered then
      emit_line ctx (Printf.sprintf "blorp_task_cleanup_pop_slot(&%s);" iter_c);
    emit_line ctx (Printf.sprintf "%s;" (release_value_call ctx iter.ty iter_c))
  end

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
      match Core_emit_util.tensor_element_storage ctx elem_ty with
      | Core_layout_type.TensorElementInlineStruct c_ty ->
          emit_blorp_backend ctx
            (TensorInlineStructElementDecl
               { var_c; tensor_c = iter_c; index_c = idx_c; struct_ty = c_ty })
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
  let iter_needs_release = boxed_expr_transfers_ownership ctx iter in
  (* [blorp_Vector] and [blorp_List] have distinct struct layouts — Vector
     carries [elem_size] + [storage_mode] + padding between [elem_release]
     and [data[]], so [data[]] sits 8 bytes further in. Declaring a Vector
     iter as [blorp_List*] and reading [->data[0]] pulls from inside those
     extra fields and returns garbage. Pick the correct container type. *)
  let iter_c_type =
    if is_tensor_type ctx iter.ty then "blorp_Vector*" else "blorp_List*"
  in
  let is_array_iter = is_tensor_type ctx iter.ty in
  emit_blorp_backend ctx
    (Core_emit_blorp_backend.FlatIterSourceBinding
       { iter_c_type; iter_tmp = iter_c; source = iter });
  let iter_cleanup_registered =
    iter_needs_release
    && emit_owned_temp_cancellation_cleanup_push ctx ~slot_c:iter_c
         ~value_c:iter_c ~ty:iter.ty
  in
  let emit_loop emit_element_decl =
    emit_blorp_backend ctx
      (Core_emit_blorp_backend.FlatIterLoopHeader
         { length = len_c; iter_tmp = iter_c; index = idx_c });
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
        emit_blorp_backend ctx
          (ListInlineStructDynamicLoad
             {
               list_tmp = iter_c;
               idx_tmp = idx_c;
               out_tmp = var_c;
               struct_ty = c_ty;
               bounds = ListBoundsProven;
             });
        emitln ctx ""
    | ListInlineStorage width ->
        let bits_tmp = Printf.sprintf "__iter_bits_%d" (fresh_temp ctx) in
        emit_indent ctx;
        emit_blorp_backend ctx
          (ListInlineBitsLoad
             { list_tmp = iter_c; idx_tmp = idx_c; bits_tmp; width });
        emitln ctx "";
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
        emit_blorp_backend ctx
          (Core_emit_blorp_backend.FlatIterRawDataBinding
             {
               pointer_c_type = raw.tras_pointer_c_type;
               raw = raw_c;
               iter_tmp = iter_c;
             });
        emit_loop (fun () ->
            let value_c_type = type_to_c ctx elem_ty in
            emit_blorp_backend ctx
              (Core_emit_blorp_backend.FlatIterRawValueBinding
                 { value_c_type; binding = var_c; raw = raw_c; index = idx_c }))
    | None ->
        emit_loop (fun () ->
            emit_for_tensor_element_decl ctx var_c iter_c idx_c elem_ty)
  else emit_loop emit_list_element_decl;
  if iter_cleanup_registered then
    emit_line ctx (Printf.sprintf "blorp_task_cleanup_pop_slot(&%s);" iter_c);
  if iter_needs_release then
    emit_line ctx (Printf.sprintf "%s;" (release_value_call ctx iter.ty iter_c))

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
  emit_blorp_backend ctx
    (Core_emit_blorp_backend.StringIterHeader
       { iter = iter_c; source = iter; index = idx_c });
  ctx.indent <- ctx.indent + 1;
  emit_blorp_backend ctx
    (Core_emit_blorp_backend.StringIterCodepointBinding
       { binding = var_c; iter = iter_c; index = idx_c });
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
  emit_blorp_backend ctx
    (DictIterHeader { dict = iter_c; source = iter; index = idx_c });
  ctx.indent <- ctx.indent + 1;
  emit_blorp_backend ctx
    (DictIterSlotBinding { slot = slot_c; dict = iter_c; index = idx_c });
  emit_blorp_backend ctx (DictIterDeletedSlotGuard { slot = slot_c });
  (match binder_ty with
  | Ast.TyTuple [ _; _ ] ->
      emit_blorp_backend ctx
        (DictIterPairBinding { entry = var_c; dict = iter_c; slot = slot_c });
      emit_stmt ctx body;
      emit_line ctx (Printf.sprintf "blorp_release(%s);" var_c)
  | _ ->
      emit_blorp_backend ctx
        (DictIterKeyBinding
           { key_c_type = key_c; binding = var_c; dict = iter_c; slot = slot_c });
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
  emit_blorp_backend ctx
    (ChannelIterHeader { channel = iter_c; source = iter; value = raw_c });
  ctx.indent <- ctx.indent + 1;
  emit_owned_erased_value_unbox_decl ctx var_c raw_c elem_ty;
  emit_stmt ctx body;
  if type_requires_release ctx elem_ty then
    if is_stack_result_type ctx elem_ty then
      emit_line ctx
        (Printf.sprintf "%s;" (release_value_call ctx elem_ty var_c))
    else emit_blorp_backend ctx (ChannelIterReleaseObject { value = var_c });
  ctx.indent <- ctx.indent - 1;
  emit_indent ctx;
  emitln ctx "}"

and emit_select (ctx : Core_emit_context.t) (select : select_expr) : unit =
  let id = fresh_temp ctx in
  let arms_c = Printf.sprintf "__select_arms_%d" id in
  let result_c = Printf.sprintf "__select_result_%d" id in
  let arm_count = List.length select.select_arms in
  emit_line ctx "{";
  ctx.indent <- ctx.indent + 1;
  emit_blorp_backend ctx (SelectArmsDecl { arms = arms_c; arm_count });
  List.iteri
    (fun i arm ->
      match arm.select_arm_kind with
      | SelectRecv r ->
          emit_blorp_backend ctx
            (SelectRecvArm
               { arms = arms_c; index = i; channel = r.select_channel })
      | SelectSealed channel ->
          emit_blorp_backend ctx
            (SelectSealedArm { arms = arms_c; index = i; channel })
      | SelectAfter timeout ->
          emit_blorp_backend ctx
            (SelectAfterArm { arms = arms_c; index = i; timeout }))
    select.select_arms;
  emit_blorp_backend ctx
    (SelectWait { result = result_c; arms = arms_c; arm_count });
  List.iteri
    (fun i arm ->
      emit_blorp_backend ctx
        (if i = 0 then SelectFirstBranchOpen { result = result_c; index = i }
         else SelectNextBranchOpen { result = result_c; index = i });
      ctx.indent <- ctx.indent + 1;
      (match arm.select_arm_kind with
      | SelectRecv r ->
          let bind_name = Var.to_c_name r.select_bind in
          let release_fn =
            cancellation_cleanup_release_fn ctx r.select_elem_ty
          in
          let push_cleanup value_c =
            match release_fn with
            | None -> ()
            | Some fn ->
                let frame_c = Printf.sprintf "__select_cleanup_%d_%d" id i in
                let value_arg =
                  cancellation_cleanup_value_arg ctx r.select_elem_ty
                    ~slot_c:value_c ~value_c
                in
                emit_blorp_backend ctx
                  (SelectCleanupFrameDecl { frame = frame_c });
                emit_blorp_backend ctx
                  (SelectCleanupPush
                     {
                       cleanup_frame = frame_c;
                       value_slot = value_c;
                       cleanup_value = value_arg;
                       release_fn = fn;
                     })
          in
          let pop_cleanup value_c =
            match release_fn with
            | None -> ()
            | Some _ ->
                emit_blorp_backend ctx
                  (SelectCleanupPop { value_slot = value_c })
          in
          let received_value_c =
            if bind_name = "_" then Printf.sprintf "__select_ignored_%d_%d" id i
            else escape_c_ident bind_name
          in
          if bind_name <> "_" then
            emit_owned_erased_value_unbox_decl ctx (escape_c_ident bind_name)
              (Printf.sprintf "%s.value" result_c)
              r.select_elem_ty
          else if is_stack_result_type ctx r.select_elem_ty then
            emit_owned_erased_value_unbox_decl ctx received_value_c
              (Printf.sprintf "%s.value" result_c)
              r.select_elem_ty
          else if type_requires_release ctx r.select_elem_ty then
            emit_blorp_backend ctx
              (SelectReceivedValueBinding
                 { binding = received_value_c; result = result_c });
          if type_requires_release ctx r.select_elem_ty then
            push_cleanup received_value_c;
          emit_stmt ctx arm.select_arm_body;
          if type_requires_release ctx r.select_elem_ty then
            pop_cleanup received_value_c;
          if type_requires_release ctx r.select_elem_ty then
            if bind_name = "_" then
              emit_line ctx
                (Printf.sprintf "%s;"
                   (release_value_call ctx r.select_elem_ty received_value_c))
            else
              emit_line ctx
                (Printf.sprintf "%s;"
                   (release_value_call ctx r.select_elem_ty
                      (escape_c_ident bind_name)))
      | SelectSealed _ | SelectAfter _ -> emit_stmt ctx arm.select_arm_body);
      ctx.indent <- ctx.indent - 1;
      emit_line ctx "}")
    select.select_arms;
  ctx.indent <- ctx.indent - 1;
  emit_line ctx "}"

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
  emit_blorp_backend ctx
    (SetIterHeader { set = iter_c; source = iter; entry = entry_c });
  ctx.indent <- ctx.indent + 1;
  emit_unbox_decl ctx var_c
    (Blorp_prepared.render_template "backend_set_iter_entry_key" [ entry_c ])
    elem_ty;
  emit_stmt ctx body;
  ctx.indent <- ctx.indent - 1;
  emit_indent ctx;
  emitln ctx "}";
  emit_blorp_backend ctx (SetIterRelease { set = iter_c })

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
    (bindings : match_binding list) (e : core) : (var * int * core list) option
    =
  match self_tail_call_args f e with
  | None -> None
  | Some args -> (
      match tailrec_nth_opt args list_index with
      | Some { desc = CVar spread_var; _ } -> (
          match
            List.find_opt
              (fun binding ->
                Var.equal binding.mb_var spread_var
                &&
                match binding.mb_accessor with
                | AccListSpread (AccRoot, _) -> true
                | _ -> false)
              bindings
          with
          | Some { mb_accessor = AccListSpread (AccRoot, offset); _ }
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
        (fun binding -> tailrec_list_accessor_supported binding.mb_accessor)
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
        Blorp_prepared.render_tuple_field_element ~tuple:(go parent)
          ~field:(string_of_int idx)
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
          let bits_tmp = Printf.sprintf "__tailrec_bits_%d" (fresh_temp ctx) in
          emit_indent ctx;
          emit_blorp_backend ctx
            (ListInlineBitsLoad
               {
                 list_tmp = Printf.sprintf "((blorp_List*)%s)" list_name;
                 idx_tmp = idx_c;
                 bits_tmp;
                 width;
               });
          emitln ctx "";
          emit_line ctx (unbox_decl_str ctx var_c ("(void*)" ^ bits_tmp) var_ty)
      | ListInlineStructStorage c_ty ->
          emit_indent ctx;
          emit ctx (Printf.sprintf "%s %s; " c_ty var_c);
          emit_blorp_backend ctx
            (ListInlineStructDynamicLoad
               {
                 list_tmp = Printf.sprintf "((blorp_List*)%s)" list_name;
                 idx_tmp = idx_c;
                 out_tmp = var_c;
                 struct_ty = c_ty;
                 bounds = ListBoundsProven;
               });
          emitln ctx ""
      | ListPointerStorage ->
          let acc_c =
            render_tailrec_list_accessor ctx ~list_name ~cursor_name acc
          in
          emit_line ctx
            (unbox_decl_for_accessor_str ctx var_c ~scrut_ty:list_ty
               ~accessor:acc ~source:acc_c var_ty))
  | _ ->
      let acc_c =
        render_tailrec_list_accessor ctx ~list_name ~cursor_name acc
      in
      emit_line ctx
        (unbox_decl_for_accessor_str ctx var_c ~scrut_ty:list_ty ~accessor:acc
           ~source:acc_c var_ty)

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
    ~(list_index : int) ~(cursor_name : string) ~(bindings : match_binding list)
    ~(profile_name : string) ~(return_ty : Ast.type_expr) (e : core) : unit =
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
    ~(return_ty : Ast.type_expr) (bindings : match_binding list) (body : core) :
    unit =
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
    (fun binding ->
      let v = binding.mb_var in
      let acc = binding.mb_accessor in
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
      (fun i (name, ty) ->
        emit_capture_unbox ctx name ty i;
        if List.mem name cl.cl_moved_captures then begin
          emit_line ctx (Printf.sprintf "__e[%d] = NULL;" i);
          emit_cancellation_cleanup_push ctx (Var.named name) ty
        end)
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

and emit_task_closure (ctx : Core_emit_context.t) ~(loc : Ast.loc)
    ~(context : string) (lambda_name : string) (captures : task_capture list) :
    string =
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
      (fun i capture ->
        emit_indent ctx;
        emit ctx (Printf.sprintf "((void**)%s->env)[%d] = " fn_tmp i);
        (match capture.task_capture_kind with
        | TaskCopyCapture ->
            emit_capture_box ctx capture.task_capture_name
              capture.task_capture_ty
        | TaskMoveResourceItem ->
            emit ctx
              (Printf.sprintf "(void*)%s"
                 (escape_c_ident capture.task_capture_name))
        | TaskStructuredTaskBorrow ->
            Core_error.errorf Core_error.Emit loc
              ~hint:
                "Structured task borrows need explicit runtime lowering before \
                 C emission can build a closure ABI."
              "unsupported %s task capture `%s: %s` reached emit" context
              capture.task_capture_name
              (Types.type_to_string capture.task_capture_ty));
        emitln ctx ";")
      captures;
    emit_task_closure_env_release_mask_stmt ctx fn_tmp captures
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
              "This concurrency form only supports ordinary copy captures. \
               Resource item moves must stay inside resource-source `for ... \
               concurrently` lowering."
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

and emit_concurrent_limit_init (ctx : Core_emit_context.t) limit_c limit_expr :
    unit =
  emit_indent ctx;
  emit ctx
    (Printf.sprintf "long %s = blorp_concurrent_normalize_limit(" limit_c);
  emit_expr ctx limit_expr;
  emitln ctx ");"

(* --- §10. Concurrency emit ------------------------------------------------ *)

(** Emit a [concurrent:] block in statement context.

    [block.conc_bindings] carries the explicit (var, user-type, rhs)
    triples; [block.conc_body] is the tail that uses the bindings.
    [cb_ty] is [Result[T, ConcurrencyError]] — the type of the C variable
    after the task-window join helper returns the boxed task result. [cb_rhs.ty]
    is [T] (the task body's raw return type), which drives the spawned lambda's
    return type and the RC classification of what the task stores. *)
and emit_concurrent_block (ctx : Core_emit_context.t) (block : concurrent_block)
    ~(emit_tail : Core_emit_context.t -> core -> unit) : unit =
  emit_line ctx "blorp_thread_pool_ensure_initialized();";
  let window_id = fresh_temp ctx in
  let window_c = Printf.sprintf "__conc_task_window_%d" window_id in
  let window_cleanup_c =
    Printf.sprintf "__blorp_task_window_cleanup_%d" window_id
  in
  let binding_count = List.length block.conc_bindings in
  let window_capacity =
    match block.conc_max_threads with
    | Some n -> max 1 (min n binding_count)
    | None -> binding_count
  in
  emit_line ctx (Printf.sprintf "blorp_ConcurrentTaskWindow %s = {0};" window_c);
  emit_line ctx (Printf.sprintf "blorp_CancelCleanupFrame %s;" window_cleanup_c);
  emit_line ctx
    (Printf.sprintf "blorp_concurrent_task_window_begin(&%s, &%s, %d);" window_c
       window_cleanup_c window_capacity);
  let emit_join_binding (cb : conc_binding) slot timeout_c =
    let var_c = escape_c_ident (Var.to_c_name cb.cb_var) in
    let ty_c = type_to_c ctx cb.cb_ty in
    let join_call =
      Printf.sprintf "blorp_concurrent_task_window_join_release(&%s, %d, %s)"
        window_c slot timeout_c
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
  let deadline =
    if has_timeout then begin
      let deadline = Printf.sprintf "__conc_deadline_%d" conc_id in
      (match block.conc_timeout with
      | Some timeout -> emit_concurrent_deadline_init ctx deadline timeout
      | None -> ());
      Some deadline
    end
    else None
  in
  let emit_timeout_arg () =
    match deadline with
    | Some deadline ->
        let rem = Printf.sprintf "__conc_rem_%d" (fresh_temp ctx) in
        emit_concurrent_remaining_init ctx rem deadline;
        rem
    | None -> "-1"
  in
  let rec take n acc rest =
    if n <= 0 then (List.rev acc, rest)
    else
      match rest with
      | [] -> (List.rev acc, [])
      | x :: xs -> take (n - 1) (x :: acc) xs
  in
  let rec chunks acc rest =
    match rest with
    | [] -> List.rev acc
    | _ ->
        let chunk, rest' = take window_capacity [] rest in
        chunks (chunk :: acc) rest'
  in
  let emit_spawn slot (cb : conc_binding) =
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
              "Core_closure should attach task metadata to every concurrent \
               binding before emission"
            "concurrent binding reached emit without task closure metadata"
    in
    let fn_tmp = emit_conc_closure ctx lambda_name captures in
    let use_rc = type_requires_release ctx task_ret_ty in
    let spawn_helper =
      if use_rc then "blorp_concurrent_task_window_spawn_owned_rc"
      else "blorp_concurrent_task_window_spawn_owned"
    in
    emit_line ctx
      (Printf.sprintf "%s(&%s, %d, %s, BLORP_CONCURRENT_TASK_FLUSH_PERIODIC);"
         spawn_helper window_c slot fn_tmp);
    (cb, slot)
  in
  let emit_chunk chunk =
    let task_infos = List.mapi emit_spawn chunk in
    List.iter
      (fun ((cb : conc_binding), slot) ->
        let timeout_c = emit_timeout_arg () in
        emit_join_binding cb slot timeout_c)
      task_infos
  in
  List.iter emit_chunk (chunks [] block.conc_bindings);
  emit_line ctx
    (Printf.sprintf "blorp_concurrent_task_window_end(&%s);" window_c);
  (* Expression-position concurrent blocks must leave the tail value as the
     GNU statement-expression result; statement-position concurrent blocks
     intentionally discard it. *)
  emit_tail ctx block.conc_body

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

(** Emit [for v in iter concurrently(...): body] in statement context.
    Discards the per-iteration results — no list is allocated. *)
and emit_concurrently_loop (ctx : Core_emit_context.t) (cf : concurrently_loop)
    : unit =
  ignore (emit_concurrently_loop_collecting ~collect:false ctx cf)

and concurrently_loop_task_emit_plan (cf : concurrently_loop) :
    Ast.type_expr * string * task_capture list =
  match cf.cf_task with
  | Some task ->
      let c_name =
        Codegen_names.mangle_by_def_id task.tc_def_id task.tc_func
        |> escape_c_ident
      in
      (task.tc_return_ty, c_name, task.tc_captures)
  | None ->
      Core_error.errorf Core_error.Emit cf.cf_body.loc
        ~hint:
          "Core_closure should attach task metadata to every for ... \
           concurrently body before emission"
        "for ... concurrently reached emit without task closure metadata"

and concurrently_loop_emit_plan (_ctx : Core_emit_context.t)
    (cf : concurrently_loop) :
    Ast.type_expr * Ast.type_expr * string * (string * Ast.type_expr) list =
  let elem_ty =
    match (cf.cf_item_mode, normalize_type cf.cf_iter.ty) with
    | ConcurrentlyLoopCopyItem, Ast.TyNamed ("List", [ et ]) -> et
    | ConcurrentlyLoopCopyItem, ty ->
        Core_error.errorf Core_error.Emit cf.cf_iter.loc
          ~hint:
            "copy-item for ... concurrently expects a List source. \
             ResourceSource fan-out must use move-resource-item Core."
          "copy-item for ... concurrently requires List[T], got %s"
          (Types.type_to_string ty)
    | ConcurrentlyLoopMoveResourceItem _, _ ->
        Core_error.errorf Core_error.Emit cf.cf_iter.loc
          ~hint:
            "resource-source fan-out has a dedicated emitter path and must not \
             reach the list emitter plan."
          "move-resource for ... concurrently reached list emitter planning"
  in
  let task_ret_ty, lambda_name, task_captures =
    concurrently_loop_task_emit_plan cf
  in
  let captures =
    task_copy_capture_bindings_for_emit ~loc:cf.cf_body.loc
      ~context:"for ... concurrently" task_captures
  in
  (elem_ty, task_ret_ty, lambda_name, captures)

and emit_concurrently_loop_collecting_limited ~(collect : bool)
    (ctx : Core_emit_context.t) (cf : concurrently_loop) (limit_expr : core) :
    string =
  let id = fresh_temp ctx in
  let list_c = Printf.sprintf "__conc_list_%d" id in
  let len_c = Printf.sprintf "__conc_len_%d" id in
  let limit_c = Printf.sprintf "__conc_limit_%d" id in
  let window_c = Printf.sprintf "__conc_task_window_%d" id in
  let window_cleanup_c = Printf.sprintf "__blorp_task_window_cleanup_%d" id in
  let start_c = Printf.sprintf "__conc_start_%d" id in
  let window_end_c = Printf.sprintf "__conc_window_end_%d" id in
  let idx_c = Printf.sprintf "__conc_i_%d" id in
  let slot_c = Printf.sprintf "__conc_slot_%d" id in
  let results_c = Printf.sprintf "__conc_results_%d" id in
  let var_c = escape_c_ident (Var.to_c_name cf.cf_var) in
  let elem_ty, task_ret_ty, lambda_name, captures =
    concurrently_loop_emit_plan ctx cf
  in
  let iter_transfers_ownership =
    boxed_expr_transfers_ownership ctx cf.cf_iter
  in
  emit_concurrent_limit_init ctx limit_c limit_expr;
  emit_line ctx "blorp_thread_pool_ensure_initialized();";
  emit_indent ctx;
  emit ctx (Printf.sprintf "blorp_List* %s = (blorp_List*)" list_c);
  emit_expr ctx cf.cf_iter;
  emitln ctx ";";
  let iter_cleanup_registered =
    iter_transfers_ownership
    && emit_owned_temp_cancellation_cleanup_push ctx ~slot_c:list_c
         ~value_c:list_c ~ty:cf.cf_iter.ty
  in
  emit_line ctx (Printf.sprintf "long %s = %s->len;" len_c list_c);
  emit_line ctx (Printf.sprintf "blorp_ConcurrentTaskWindow %s = {0};" window_c);
  emit_line ctx (Printf.sprintf "blorp_CancelCleanupFrame %s;" window_cleanup_c);
  emit_line ctx
    (Printf.sprintf "blorp_concurrent_task_window_begin(&%s, &%s, %s);" window_c
       window_cleanup_c limit_c);
  if collect then begin
    emit_line ctx
      (Printf.sprintf "blorp_List* %s = blorp_list_new(%s);" results_c len_c);
    emit_line ctx
      (Printf.sprintf "blorp_list_init_elem_release(%s, blorp_elem_release_fn);"
         results_c);
    emit_arc_value_cleanup_push ctx results_c
  end;
  let has_timeout = cf.cf_timeout <> None in
  let deadline_c = Printf.sprintf "__conc_deadline_%d" (fresh_temp ctx) in
  if has_timeout then
    begin match cf.cf_timeout with
    | Some timeout -> emit_concurrent_deadline_init ctx deadline_c timeout
    | None -> ()
    end;
  let use_rc = type_requires_release ctx task_ret_ty in
  let spawn_helper =
    if use_rc then "blorp_concurrent_task_window_spawn_owned_rc"
    else "blorp_concurrent_task_window_spawn_owned"
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
    (Printf.sprintf "%s(&%s, %s, %s, BLORP_CONCURRENT_TASK_FLUSH_PERIODIC);"
       spawn_helper window_c slot_c fn_tmp);
  ctx.indent <- ctx.indent - 1;
  emit_indent ctx;
  emitln ctx "}";
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
      Printf.sprintf "blorp_concurrent_task_window_join_release(&%s, %s, %s)"
        window_c slot_c rem
    end
    else
      Printf.sprintf "blorp_concurrent_task_window_join_release(&%s, %s, -1)"
        window_c slot_c
  in
  if collect then begin
    emit_line ctx
      (Printf.sprintf "blorp_list_set_raw(%s, %s, (void*)(%s));" results_c idx_c
         join_call);
    emit_line ctx (Printf.sprintf "%s->len = %s + 1;" results_c idx_c)
  end
  else
    emit_line ctx
      (Printf.sprintf "blorp_release((blorp_Object*)(%s));" join_call);
  ctx.indent <- ctx.indent - 1;
  emit_indent ctx;
  emitln ctx "}";
  ctx.indent <- ctx.indent - 1;
  emit_indent ctx;
  emitln ctx "}";
  emit_line ctx
    (Printf.sprintf "blorp_concurrent_task_window_end(&%s);" window_c);
  if collect then begin
    emit_line ctx (Printf.sprintf "%s->len = %s;" results_c len_c);
    emit_line ctx (Printf.sprintf "blorp_task_cleanup_pop_slot(&%s);" results_c)
  end;
  if iter_cleanup_registered then
    emit_line ctx (Printf.sprintf "blorp_task_cleanup_pop_slot(&%s);" list_c);
  if iter_transfers_ownership then
    emit_line ctx
      (Printf.sprintf "%s;" (release_value_call ctx cf.cf_iter.ty list_c));
  results_c

and emit_concurrently_resource_source_loop_limited ~(collect : bool)
    (ctx : Core_emit_context.t) (cf : concurrently_loop) (limit_expr : core)
    (resource_ty : Ast.type_expr) : string =
  if collect then
    Core_error.errorf Core_error.Emit cf.cf_iter.loc
      ~hint:
        "Resource-source fan-out is statement-only until result collection has \
         an explicit ownership story."
      "resource-source for ... concurrently cannot collect results";
  let id = fresh_temp ctx in
  let source_c = Printf.sprintf "__conc_resource_source_%d" id in
  let limit_c = Printf.sprintf "__conc_limit_%d" id in
  let window_c = Printf.sprintf "__conc_task_window_%d" id in
  let window_cleanup_c = Printf.sprintf "__blorp_task_window_cleanup_%d" id in
  let raw_c = Printf.sprintf "__conc_resource_raw_%d" id in
  let count_c = Printf.sprintf "__conc_count_%d" id in
  let slot_c = Printf.sprintf "__conc_slot_%d" id in
  let done_c = Printf.sprintf "__conc_source_done_%d" id in
  let var_c = escape_c_ident (Var.to_c_name cf.cf_var) in
  let task_ret_ty, lambda_name, task_captures =
    concurrently_loop_task_emit_plan cf
  in
  let iter_transfers_ownership =
    boxed_expr_transfers_ownership ctx cf.cf_iter
  in
  emit_concurrent_limit_init ctx limit_c limit_expr;
  emit_line ctx "blorp_thread_pool_ensure_initialized();";
  emit_indent ctx;
  emit ctx (Printf.sprintf "blorp_ResourceSource* %s = " source_c);
  emit_expr ctx cf.cf_iter;
  emitln ctx ";";
  let iter_cleanup_registered =
    iter_transfers_ownership
    && emit_owned_temp_cancellation_cleanup_push ctx ~slot_c:source_c
         ~value_c:source_c ~ty:cf.cf_iter.ty
  in
  emit_line ctx (Printf.sprintf "blorp_ConcurrentTaskWindow %s = {0};" window_c);
  emit_line ctx (Printf.sprintf "blorp_CancelCleanupFrame %s;" window_cleanup_c);
  emit_line ctx
    (Printf.sprintf "blorp_concurrent_task_window_begin(&%s, &%s, %s);" window_c
       window_cleanup_c limit_c);
  let has_timeout = cf.cf_timeout <> None in
  let deadline_c = Printf.sprintf "__conc_deadline_%d" (fresh_temp ctx) in
  if has_timeout then
    begin match cf.cf_timeout with
    | Some timeout -> emit_concurrent_deadline_init ctx deadline_c timeout
    | None -> ()
    end;
  emit_line ctx (Printf.sprintf "bool %s = false;" done_c);
  emit_indent ctx;
  emitln ctx (Printf.sprintf "while (!%s) {" done_c);
  ctx.indent <- ctx.indent + 1;
  emit_line ctx (Printf.sprintf "long %s = 0;" count_c);
  emit_indent ctx;
  emitln ctx (Printf.sprintf "while (%s < %s) {" count_c limit_c);
  ctx.indent <- ctx.indent + 1;
  emit_line ctx (Printf.sprintf "void* %s = NULL;" raw_c);
  emit_line ctx
    (Printf.sprintf "if (!blorp_resource_source_next_raw(%s, &%s)) {" source_c
       raw_c);
  ctx.indent <- ctx.indent + 1;
  emit_line ctx (Printf.sprintf "%s = true;" done_c);
  emit_line ctx "break;";
  ctx.indent <- ctx.indent - 1;
  emit_line ctx "}";
  emit_line ctx
    (Printf.sprintf "%s %s = (%s)%s;"
       (type_to_c ctx resource_ty)
       var_c
       (type_to_c ctx resource_ty)
       raw_c);
  emit_line ctx (Printf.sprintf "%s = NULL;" raw_c);
  emit_line ctx (Printf.sprintf "long %s = %s;" slot_c count_c);
  let fn_tmp =
    emit_task_closure ctx ~loc:cf.cf_body.loc
      ~context:"resource-source for ... concurrently" lambda_name task_captures
  in
  let use_rc = type_requires_release ctx task_ret_ty in
  let spawn_helper =
    if use_rc then "blorp_concurrent_task_window_spawn_owned_rc"
    else "blorp_concurrent_task_window_spawn_owned"
  in
  emit_line ctx
    (Printf.sprintf "%s(&%s, %s, %s, BLORP_CONCURRENT_TASK_FLUSH_IMMEDIATE);"
       spawn_helper window_c slot_c fn_tmp);
  emit_line ctx (Printf.sprintf "%s++;" count_c);
  ctx.indent <- ctx.indent - 1;
  emit_line ctx "}";
  emit_indent ctx;
  emitln ctx
    (Printf.sprintf "for (long %s = 0; %s < %s; %s++) {" slot_c slot_c count_c
       slot_c);
  ctx.indent <- ctx.indent + 1;
  let join_call =
    if has_timeout then begin
      let rem = Printf.sprintf "__cf_rem_%d" (fresh_temp ctx) in
      emit_concurrent_remaining_init ctx rem deadline_c;
      Printf.sprintf "blorp_concurrent_task_window_join_release(&%s, %s, %s)"
        window_c slot_c rem
    end
    else
      Printf.sprintf "blorp_concurrent_task_window_join_release(&%s, %s, -1)"
        window_c slot_c
  in
  emit_line ctx (Printf.sprintf "blorp_release((blorp_Object*)(%s));" join_call);
  ctx.indent <- ctx.indent - 1;
  emit_line ctx "}";
  ctx.indent <- ctx.indent - 1;
  emit_line ctx "}";
  emit_line ctx
    (Printf.sprintf "blorp_concurrent_task_window_end(&%s);" window_c);
  if iter_cleanup_registered then
    emit_line ctx (Printf.sprintf "blorp_task_cleanup_pop_slot(&%s);" source_c);
  if iter_transfers_ownership then
    emit_line ctx
      (Printf.sprintf "%s;" (release_value_call ctx cf.cf_iter.ty source_c));
  "NULL"

(** Emit a concurrently-loop Core node and, when [collect] is true, return the C
    identifier holding the collected [blorp_List*] of
    [Result[T, ConcurrencyError]] entries.

    When [collect] is false (statement context), no result list is
    allocated and join return values are released individually — saves
    an allocation and avoids retaining N Results just to immediately
    drop them.

    When [collect] is true (std helper collection context), the list is
    allocated with capacity = iter length, populated in the join loop by writing
    directly into [data[i]] (each [Result*] arrives at refcount 1, so
    we take ownership without a retain), and tagged with
    [blorp_elem_release_fn] so the list's destructor releases each
    Result when the list itself goes out of scope. *)
and emit_concurrently_loop_collecting ~(collect : bool)
    (ctx : Core_emit_context.t) (cf : concurrently_loop) : string =
  match cf.cf_width with
  | ConcurrentlyLoopLimit limit -> (
      match cf.cf_item_mode with
      | ConcurrentlyLoopCopyItem ->
          emit_concurrently_loop_collecting_limited ~collect ctx cf limit
      | ConcurrentlyLoopMoveResourceItem { clmi_resource_ty; _ } ->
          emit_concurrently_resource_source_loop_limited ~collect ctx cf limit
            clmi_resource_ty)

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
    | { cd_desc = CDVar v; cd_loc; _ } :: rest -> (
        match v.cv_init.desc with
        | _ when can_emit_static_string_global v -> collect acc rest
        | _ when can_emit_static_list_global ctx v -> collect acc rest
        | _ when can_emit_static_tuple_global ctx v -> collect acc rest
        | _ when can_emit_static_record_global ctx v -> collect acc rest
        | _ when can_emit_static_union_global ctx v -> collect acc rest
        | CLit lit when is_c_static_literal lit -> collect acc rest
        | _ -> collect ((v, cd_loc) :: acc) rest)
    | { cd_desc = CDPrivate { cd_desc = CDVar v; cd_loc; _ }; _ } :: rest -> (
        match v.cv_init.desc with
        | _ when can_emit_static_string_global v -> collect acc rest
        | _ when can_emit_static_list_global ctx v -> collect acc rest
        | _ when can_emit_static_tuple_global ctx v -> collect acc rest
        | _ when can_emit_static_record_global ctx v -> collect acc rest
        | _ when can_emit_static_union_global ctx v -> collect acc rest
        | CLit lit when is_c_static_literal lit -> collect acc rest
        | _ -> collect ((v, cd_loc) :: acc) rest)
    | _ :: rest -> collect acc rest
  in
  let deferred = collect [] prog in
  let planned =
    List.map
      (fun (v, loc) ->
        let plan = global_constant_immortalization ctx v in
        match plan with
        | UnsupportedManagedConstant reason ->
            Core_error.errorf Core_error.Emit loc
              ~hint:global_constant_unsupported_hint
              "managed global constant layout cannot yet be made safely \
               immortal: %s"
              reason
        | NoImmortalizationNeeded -> (v, CheckedNoImmortalizationNeeded)
        | ImmortalizeConstantGraph plan ->
            (v, CheckedImmortalizeConstantGraph plan))
      deferred
  in
  List.iter
    (fun (_, plan) ->
      match plan with
      | CheckedImmortalizeConstantGraph plan ->
          prepare_global_constant_immortal_helpers ctx plan
      | CheckedNoImmortalizationNeeded -> ())
    planned;
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
      (fun (v, plan) ->
        let ty = v.cv_ty in
        let init = expr_with_expected_type_for_constructors ctx v.cv_init ty in
        emit_indent ctx;
        (* Global bare name — matches [emit_global_var]'s bare decl. *)
        emit ctx (escape_c_ident (Var.to_c_name v.cv_name));
        emit ctx " = ";
        emit_expr ctx init;
        emitln ctx ";";
        emit_global_constant_immortal_init ctx plan v)
      planned;
    ctx.indent <- ctx.indent - 1
  end;
  emitln ctx "}"
