(** Intrinsic emission for the C backend — extracted from
    [core_emit.ml] in Phase 5.1.

    The [emit] function below holds the big pattern-match that
    dispatches on intrinsic name ([list_len], [dict_get], [tensor_*],
    [string_*], etc.) and expands each to structured C. Taking the
    emitter partners as labeled callbacks breaks the mutual-recursion
    barrier with [core_emit.ml] without requiring first-class modules
    or recursive modules.

    Current callback set: [~emit_expr], [~emit_stmt], [~emit_boxed].
    [emit_stmt] is threaded defensively — today no intrinsic arm
    emits statement context, but widening the signature preemptively
    avoids a migration at every call site the first time one does
    (e.g. a future [panic] or [assert_shape] intrinsic that emits an
    [abort()] statement). Dead-for-now callbacks are named with
    [_ =] suppressions so the ignore is visible in the file.

    Every sub-expression callsite inside the match body flows through
    the [emit_expr] callback, which the main [core_emit.ml] passes as
    its own [and emit_expr] reference. The callbacks bind to
    top-level rec definitions — zero closure allocation per dispatch,
    one indirect call per sub-expr. *)

open Core
open Core_emit_util
module List_emit = Core_emit_list_intrinsic

let emit ~(emit_expr : Core_emit_context.t -> core -> unit)
    ~(emit_stmt : Core_emit_context.t -> core -> unit)
    ~(emit_boxed : Core_emit_context.t -> core -> unit)
    (ctx : Core_emit_context.t) (e : core) (name : string) (args : core list) :
    unit =
  let _ = emit_stmt in
  (* reserved — see file header *)
  match (name, args) with
  | _ when Core_emit_blorp_intrinsic.emit ~emit_expr ctx name args -> ()
  (* ---- List primitives ---- *)
  | "list_set", [ lst; idx; val_ ] ->
      (* Layout-aware unchecked store. Mutates in place, returns void. *)
      List_emit.emit_store ~emit_expr ~emit_boxed ctx List_emit.ListSetRaw lst
        idx val_
  | "list_set_owned", [ lst; idx; val_ ] ->
      (* Layout-aware unchecked transfer into initialized storage. *)
      List_emit.emit_store ~emit_expr ~emit_boxed ctx List_emit.ListSetRaw lst
        idx val_
  | "list_handoff_set_owned", [ lst; idx; val_ ] ->
      (* Handoff write: transfer a freshly owned value into [idx]. The runtime
         helper releases old reused slots and leaves fresh builder writes alone. *)
      List_emit.emit_store ~emit_expr ~emit_boxed ctx
        List_emit.ListHandoffSetOwned lst idx val_
  | "list_handoff_set_source_slot", [ result; out_idx; source; source_idx ] ->
      (* Handoff write from an existing source slot. The runtime moves the slot
         when handoff reuse succeeds and retains it when writing to a fresh
         result, so source aliases are never misclassified as owned temporaries. *)
      Core_emit_blorp_prepared_list.emit_handoff_set_source_slot ~emit_expr ctx
        result out_idx source source_idx
  | "list_copy_span_uninit", [ dst; dst_start; src; src_start; count ] ->
      (* Bulk copy into uninitialized list storage. The helper retains copied
         pointer elements only when the destination storage owns elements. *)
      Core_emit_blorp_prepared_list.emit_copy_span_uninit ~emit_expr ctx dst
        dst_start src src_start count
  | "list_swap_slots", [ lst; i; j ] ->
      (* Layout-aware unchecked swap. The operation only rearranges initialized
         slots, so it does not retain or release elements. *)
      List_emit.emit_swap_slots ~emit_expr ctx lst i j
  | "list_alloc", [ _ ] ->
      Core_error.errorf Core_error.Emit e.loc
        ~hint:
          "Core_specialize should rewrite list_alloc intrinsics into \
           CListAlloc nodes before emission so the storage layout is explicit \
           in Core IR."
        "layout-free list_alloc intrinsic reached C emitter"
  | "list_ensure_unique", [ lst ] ->
      (* COW check: if shared, copy; if unique, return as-is.
         blorp_list_cow(list) *)
      Core_emit_blorp_prepared_list.emit_ensure_unique ~emit_expr ctx lst
  | "list_ensure_capacity", [ lst; cap ] ->
      (* COW + grow: ensure list has capacity >= cap.
         blorp_list_ensure_capacity(list, cap) *)
      Core_emit_blorp_prepared_list.emit_ensure_capacity ~emit_expr ctx lst cap
  | "list_reuse_alloc", [ lst; cap ] ->
      (* Consume a dead list owner and return an empty list allocation.
         blorp_list_reuse_alloc(list, cap) *)
      let layout = list_storage_layout_of_type ctx e.ty e.loc in
      if
        list_storage_layout_requires_release_or_error ~phase:Core_error.Emit
          ~loc:e.loc layout
      then
        Core_emit_blorp_prepared_list.emit_reuse_alloc_with_release ~emit_expr
          ctx lst cap
      else Core_emit_blorp_prepared_list.emit_reuse_alloc ~emit_expr ctx lst cap
  | "list_retain_for", [ lst; value ] ->
      (* Retain a value being stored into list, if list has elem_release. *)
      let layout = list_storage_layout_of_type ctx lst.ty lst.loc in
      if
        list_storage_layout_requires_retain_or_error ~phase:Core_error.Emit
          ~loc:lst.loc layout
      then
        Core_emit_blorp_prepared_list.emit_retain_for ~emit_expr ~emit_boxed ctx
          lst value
      else Core_emit_blorp_prepared_list.emit_retain_for_noop ctx
  (* ---- String primitives ---- *)
  | "string_find_byte_from", [ s; byte; start ] ->
      (* Find a byte via memchr. Returns -1 for not found or invalid start. *)
      Core_emit_blorp_prepared_string.emit_find_byte_from ~emit_expr ctx s byte
        start
  | "string_copy_bytes", [ dst; dst_pos; src; src_pos; len ] ->
      (* Raw final Core should normally be rewritten to CStringByteCopy by
         Core_codegen_prepare; this arm keeps the registry/emitter contract
         total and delegates the fallback shape to the Blorp renderer. *)
      Core_emit_blorp_prepared_string.emit_byte_copy_intrinsic ~emit_expr ctx
        dst dst_pos src src_pos len
  | "string_set_len", [ s; n ] ->
      (* Raw final Core should normally be rewritten to CStringSetLen by
         Core_codegen_prepare; this arm keeps the registry/emitter contract
         total and delegates the fallback shape to the Blorp renderer. *)
      Core_emit_blorp_prepared_string.emit_set_len_intrinsic ~emit_expr ctx s n
  (* ---- Tensor/Vector primitives ---- *)
  | "tensor_is_word_storage", [ t ] ->
      Core_emit_blorp_prepared_tensor.emit_word_storage_check ~emit_expr ctx t
  | "tensor_is_f64_storage", [ t ] ->
      Core_emit_blorp_prepared_tensor.emit_f64_storage_check ~emit_expr ctx t
  | "tensor_is_f32_storage", [ t ] ->
      Core_emit_blorp_prepared_tensor.emit_f32_storage_check ~emit_expr ctx t
  | "tensor_is_i64_storage", [ t ] ->
      Core_emit_blorp_prepared_tensor.emit_i64_storage_check ~emit_expr ctx t
  | "tensor_get_unchecked", [ t; idx ] -> (
      (* Direct data[idx] access — bounds proven safe at compile time. *)
      match Core_layout_type.tensor_element_storage ~reg:ctx.reg e.ty with
      | Core_layout_type.TensorElementInlineStruct c_ty ->
          Core_emit_blorp_prepared_tensor.emit_inline_struct_get_unchecked
            ~emit_expr ctx t idx ~struct_ty:c_ty
      | Core_layout_type.TensorElementRawScalar _
      | Core_layout_type.TensorElementPackedBits _
      | Core_layout_type.TensorElementBoxed ->
          Core_emit_blorp_prepared_tensor.emit_data_pointer_get_unchecked
            ~emit_expr ctx t idx)
  | "tensor_get_f64_raw_unchecked", [ t; idx ] ->
      Core_emit_blorp_prepared_tensor.emit_f64_raw_get_unchecked ~emit_expr ctx
        t idx
  | "tensor_get_f32_raw_unchecked", [ t; idx ] ->
      Core_emit_blorp_prepared_tensor.emit_f32_raw_get_unchecked ~emit_expr ctx
        t idx
  | "tensor_alloc", [ size ] ->
      Core_emit_blorp_prepared_tensor.emit_alloc ~emit_expr ctx e size
  | _ ->
      if Core_intrinsic_registry.is_known name then
        Core_error.errorf Core_error.Emit e.loc
          ~hint:
            "the registry lists this intrinsic but emit_intrinsic has no match \
             clause for this arity — add one or remove the registry entry"
          "intrinsic %S is registered but emitter doesn't handle %d args" name
          (List.length args)
      else
        Core_error.errorf Core_error.Emit e.loc
          ~hint:
            "register the intrinsic in Core_intrinsic_registry or fix the \
             caller to use an existing intrinsic name"
          "unknown intrinsic %S" name
