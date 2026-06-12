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
open Core_emit_context
open Core_emit_util
module List_emit = Core_emit_list_intrinsic

let emit_tensor_alloc_ctor ~emit_expr ctx (layout : tensor_storage_layout) size
    =
  let emit_size () = emit_expr ctx size in
  match layout.tsl_slots with
  | TensorRawScalarStorage TensorInt64Elements ->
      emit ctx "blorp_vector_new_i64(";
      emit_size ();
      emit ctx ")"
  | TensorRawScalarStorage TensorFloat64Elements ->
      emit ctx "blorp_vector_new_f64(";
      emit_size ();
      emit ctx ")"
  | TensorRawScalarStorage TensorFloat32Elements ->
      emit ctx "blorp_vector_new_f32(";
      emit_size ();
      emit ctx ")"
  | TensorPackedStorage width ->
      emit ctx "blorp_vector_new_packed(";
      emit_size ();
      emit ctx (Printf.sprintf ", %d)" (Core.inline_storage_width_bytes width))
  | TensorInlineStructStorage c_ty ->
      emit ctx "blorp_vector_new_sized(";
      emit_size ();
      emit ctx (Printf.sprintf ", sizeof(%s))" c_ty)
  | TensorWordStorage | TensorBoxedStorage ->
      emit ctx "blorp_vector_new(";
      emit_size ();
      emit ctx ")"

let emit_tensor_alloc ~emit_expr ctx e size =
  let layout =
    Core_layout_type.tensor_storage_layout_of_type ~reg:ctx.reg e.ty e.loc
  in
  if
    tensor_storage_layout_requires_release_or_error ~phase:Core_error.Emit
      ~loc:e.loc layout
  then (
    let tmp = Printf.sprintf "__tensor_alloc_%d" (fresh_temp ctx) in
    emit ctx (Printf.sprintf "({ blorp_Vector* %s = " tmp);
    emit_tensor_alloc_ctor ~emit_expr ctx layout size;
    emit ctx
      (Printf.sprintf
         "; blorp_vector_init_elem_release(%s, blorp_elem_release_fn); %s; })"
         tmp tmp))
  else emit_tensor_alloc_ctor ~emit_expr ctx layout size

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
      let id = fresh_temp ctx in
      let s_tmp = Printf.sprintf "__string_find_src_%d" id in
      let byte_tmp = Printf.sprintf "__string_find_byte_%d" id in
      let start_tmp = Printf.sprintf "__string_find_start_%d" id in
      emit ctx (Printf.sprintf "({ blorp_String* %s = (blorp_String*)" s_tmp);
      emit_expr ctx s;
      emit ctx (Printf.sprintf "; long %s = " byte_tmp);
      emit_expr ctx byte;
      emit ctx (Printf.sprintf "; long %s = " start_tmp);
      emit_expr ctx start;
      emit ctx
        (Printf.sprintf "; blorp_string_find_byte_from(%s, %s, %s); })" s_tmp
           byte_tmp start_tmp)
  | "string_copy_bytes", [ dst; dst_pos; src; src_pos; len ] ->
      (* Bulk byte copy. Callers prove bounds, nonnegative length, and
         non-overlap before constructing this intrinsic; zero-length copies are
         skipped. *)
      let id = fresh_temp ctx in
      let dst_tmp = Printf.sprintf "__string_copy_dst_%d" id in
      let dst_pos_tmp = Printf.sprintf "__string_copy_dst_pos_%d" id in
      let src_tmp = Printf.sprintf "__string_copy_src_%d" id in
      let src_pos_tmp = Printf.sprintf "__string_copy_src_pos_%d" id in
      let len_tmp = Printf.sprintf "__string_copy_len_%d" id in
      emit ctx (Printf.sprintf "({ blorp_String* %s = (blorp_String*)" dst_tmp);
      emit_expr ctx dst;
      emit ctx (Printf.sprintf "; long %s = " dst_pos_tmp);
      emit_expr ctx dst_pos;
      emit ctx (Printf.sprintf "; blorp_String* %s = (blorp_String*)" src_tmp);
      emit_expr ctx src;
      emit ctx (Printf.sprintf "; long %s = " src_pos_tmp);
      emit_expr ctx src_pos;
      emit ctx (Printf.sprintf "; long %s = " len_tmp);
      emit_expr ctx len;
      emit ctx
        (Printf.sprintf
           "; if (%s > 0) { memcpy(%s->data + %s, %s->data + %s, (size_t)%s); \
            } (void)0; })"
           len_tmp dst_tmp dst_pos_tmp src_tmp src_pos_tmp len_tmp)
  | "string_set_len", [ s; n ] ->
      (* s->len = n; s->data[n] = '\0' (null-terminate) *)
      emit ctx "({ blorp_String* __sl = (blorp_String*)";
      emit_expr ctx s;
      emit ctx "; long __sn = ";
      emit_expr ctx n;
      emit ctx "; __sl->len = __sn; __sl->data[__sn] = '\\0'; (void)0; })"
  (* ---- Set primitives ---- *)
  | "set_retain_key_for", [ s; key ] ->
      emit ctx "({ blorp_Set* __rts = (blorp_Set*)";
      emit_expr ctx s;
      emit ctx "; void* __rtk = (void*)";
      emit_expr ctx key;
      emit ctx
        "; if (__rts->key_release && __rtk) blorp_retain(__rtk); (void)0; })"
  (* ---- Dict primitives ---- *)
  | "dict_retain_key_for", [ d; key ] ->
      emit ctx "({ blorp_Dict* __rtd = (blorp_Dict*)";
      emit_expr ctx d;
      emit ctx "; void* __rtk = (void*)";
      emit_expr ctx key;
      emit ctx
        "; if (__rtd->key_release && __rtk) blorp_retain(__rtk); (void)0; })"
  | "dict_retain_value_for", [ d; value ] ->
      emit ctx "({ blorp_Dict* __rtd = (blorp_Dict*)";
      emit_expr ctx d;
      emit ctx "; void* __rtv = (void*)";
      emit_expr ctx value;
      emit ctx
        "; if (__rtd->value_release && __rtv) blorp_retain(__rtv); (void)0; })"
  | "dict_release_value_for", [ d; value ] ->
      emit ctx "({ blorp_Dict* __rtd = (blorp_Dict*)";
      emit_expr ctx d;
      emit ctx "; void* __rv = (void*)";
      emit_expr ctx value;
      emit ctx
        "; if (__rtd->value_release && __rv) __rtd->value_release(__rv); \
         (void)0; })"
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
  | "tensor_alloc", [ size ] -> emit_tensor_alloc ~emit_expr ctx e size
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
