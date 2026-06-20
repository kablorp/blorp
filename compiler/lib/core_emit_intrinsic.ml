(** Intrinsic emission for the C backend — extracted from
    [core_emit.ml] in Phase 5.1.

    The [emit] function below holds the big pattern-match that
    dispatches on intrinsic name ([list_len], [dict_get], [tensor_*],
    [string_*], etc.) and expands each to structured C. Taking the
    emitter partners as labeled callbacks breaks the mutual-recursion
    barrier with [core_emit.ml] without requiring first-class modules
    or recursive modules.

    Current callback set: [~emit_expr], [~emit_stmt], [~emit_boxed],
    [~emit_boxed_storage], [~type_to_c]. These callbacks are bundled
    once for the Blorp backend bridge so migrated intrinsic arms share
    one typed handoff point.

    Every sub-expression callsite inside the match body flows through
    the [emit_expr] callback, which the main [core_emit.ml] passes as
    its own [and emit_expr] reference. The callbacks bind to
    top-level rec definitions — zero closure allocation per dispatch,
    one indirect call per sub-expr. *)

open Core

let emit ~(emit_expr : Core_emit_context.t -> core -> unit)
    ~(emit_stmt : Core_emit_context.t -> core -> unit)
    ~(emit_boxed : Core_emit_context.t -> core -> unit)
    ~(emit_boxed_storage : Core_emit_context.t -> boxed_storage_value -> unit)
    ~(type_to_c : Core_emit_context.t -> Ast.type_expr -> string)
    (ctx : Core_emit_context.t) (e : core) (name : string) (args : core list) :
    unit =
  if Core_emit_blorp_backend.emit_simple_intrinsic ~emit_expr ctx name args then
    ()
  else
    let emit_backend node =
      Core_emit_blorp_backend.emit
        {
          emit_expr;
          emit_stmt;
          emit_boxed_core = emit_boxed;
          emit_boxed_storage;
          type_to_c;
        }
        ctx node
    in
    match (name, args) with
    (* ---- List primitives ---- *)
    | "list_set", [ lst; idx; val_ ] ->
        (* Layout-aware unchecked store. Mutates in place, returns void. *)
        emit_backend
          (ListStore
             {
               runtime = Core_emit_blorp_prepared_backend.ListSetRaw;
               list = lst;
               index = idx;
               value = val_;
             })
    | "list_set_owned", [ lst; idx; val_ ] ->
        (* Layout-aware unchecked transfer into initialized storage. *)
        emit_backend
          (ListStore
             {
               runtime = Core_emit_blorp_prepared_backend.ListSetRaw;
               list = lst;
               index = idx;
               value = val_;
             })
    | "list_handoff_set_owned", [ lst; idx; val_ ] ->
        (* Handoff write: transfer a freshly owned value into [idx]. The runtime
         helper releases old reused slots and leaves fresh builder writes alone. *)
        emit_backend
          (ListStore
             {
               runtime = Core_emit_blorp_prepared_backend.ListHandoffSetOwned;
               list = lst;
               index = idx;
               value = val_;
             })
    | "list_handoff_set_source_slot", [ result; out_idx; source; source_idx ] ->
        (* Handoff write from an existing source slot. The runtime moves the slot
         when handoff reuse succeeds and retains it when writing to a fresh
         result, so source aliases are never misclassified as owned temporaries. *)
        emit_backend
          (ListHandoffSetSourceSlot
             { result; out_index = out_idx; source; source_index = source_idx })
    | "list_copy_span_uninit", [ dst; dst_start; src; src_start; count ] ->
        (* Bulk copy into uninitialized list storage. The helper retains copied
         pointer elements only when the destination storage owns elements. *)
        emit_backend
          (ListCopySpanUninit { dst; dst_start; src; src_start; count })
    | "list_swap_slots", [ lst; i; j ] ->
        (* Layout-aware unchecked swap. The operation only rearranges initialized
         slots, so it does not retain or release elements. *)
        emit_backend
          (ListSwapSlots { list = lst; left_index = i; right_index = j })
    | "list_alloc", [ _ ] ->
        Core_error.errorf Core_error.Emit e.loc
          ~hint:
            "Core_specialize should rewrite list_alloc intrinsics into \
             CListAlloc nodes before emission so the storage layout is \
             explicit in Core IR."
          "layout-free list_alloc intrinsic reached C emitter"
    | "list_ensure_unique", [ lst ] ->
        (* COW check: if shared, copy; if unique, return as-is.
         blorp_list_cow(list) *)
        emit_backend (ListEnsureUnique lst)
    | "list_ensure_capacity", [ lst; cap ] ->
        (* COW + grow: ensure list has capacity >= cap.
         blorp_list_ensure_capacity(list, cap) *)
        emit_backend (ListEnsureCapacity { list = lst; capacity = cap })
    | "list_reuse_alloc", [ lst; cap ] ->
        (* Consume a dead list owner and return an empty list allocation.
         blorp_list_reuse_alloc(list, cap) *)
        emit_backend
          (ListReuseAllocForResult { result = e; list = lst; capacity = cap })
    | "list_retain_for", [ lst; value ] ->
        (* Retain a value being stored into list, if list has elem_release. *)
        emit_backend (ListRetainForStorage { list = lst; value })
    (* ---- String primitives ---- *)
    | "string_find_byte_from", [ s; byte; start ] ->
        (* Find a byte via memchr. Returns -1 for not found or invalid start. *)
        emit_backend (StringFindByteFrom { source = s; byte; start })
    | "string_copy_bytes", [ dst; dst_pos; src; src_pos; len ] ->
        (* Raw final Core should normally be rewritten to CStringByteCopy by
         Core_codegen_prepare; this arm keeps the registry/emitter contract
         total and delegates the fallback shape to the Blorp renderer. *)
        emit_backend
          (StringByteCopyIntrinsic { dst; dst_pos; src; src_pos; len })
    | "string_set_len", [ s; n ] ->
        (* Raw final Core should normally be rewritten to CStringSetLen by
         Core_codegen_prepare; this arm keeps the registry/emitter contract
         total and delegates the fallback shape to the Blorp renderer. *)
        emit_backend (StringSetLenIntrinsic { target = s; len = n })
    (* ---- Tensor/Vector primitives ---- *)
    | "tensor_is_word_storage", [ t ] ->
        emit_backend
          (TensorStorageCheck { check = TensorWordStorageCheck; tensor = t })
    | "tensor_is_f64_storage", [ t ] ->
        emit_backend
          (TensorStorageCheck { check = TensorF64StorageCheck; tensor = t })
    | "tensor_is_f32_storage", [ t ] ->
        emit_backend
          (TensorStorageCheck { check = TensorF32StorageCheck; tensor = t })
    | "tensor_is_i64_storage", [ t ] ->
        emit_backend
          (TensorStorageCheck { check = TensorI64StorageCheck; tensor = t })
    | "tensor_get_unchecked", [ t; idx ] ->
        (* Direct data[idx] access — bounds proven safe at compile time. *)
        emit_backend
          (TensorGetUnchecked { result = e; tensor = t; index = idx })
    | "tensor_get_f64_raw_unchecked", [ t; idx ] ->
        emit_backend (TensorF64RawGetUnchecked { tensor = t; index = idx })
    | "tensor_get_f32_raw_unchecked", [ t; idx ] ->
        emit_backend (TensorF32RawGetUnchecked { tensor = t; index = idx })
    | "tensor_alloc", [ size ] ->
        emit_backend (TensorAlloc { result = e; size })
    | _ ->
        if Core_intrinsic_registry.is_known name then
          Core_error.errorf Core_error.Emit e.loc
            ~hint:
              "the registry lists this intrinsic but emit_intrinsic has no \
               match clause for this arity — add one or remove the registry \
               entry"
            "intrinsic %S is registered but emitter doesn't handle %d args" name
            (List.length args)
        else
          Core_error.errorf Core_error.Emit e.loc
            ~hint:
              "register the intrinsic in Core_intrinsic_registry or fix the \
               caller to use an existing intrinsic name"
            "unknown intrinsic %S" name
