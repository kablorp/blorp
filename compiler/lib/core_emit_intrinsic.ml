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
  (* ---- List primitives ---- *)
  | "elem_release_fn", [] -> emit ctx "((void*)blorp_elem_release_fn)"
  | "list_len", [ lst ] ->
      (* list->len *)
      emit ctx "((blorp_List*)";
      emit_expr ctx lst;
      emit ctx ")->len"
  | "list_capacity", [ lst ] ->
      (* list->capacity *)
      emit ctx "((blorp_List*)";
      emit_expr ctx lst;
      emit ctx ")->capacity"
  | "list_get", [ lst; idx ] ->
      (* Layout-aware unchecked get. Returns a void* storage value. *)
      emit ctx "blorp_list_get((blorp_List*)";
      emit_expr ctx lst;
      emit ctx ", ";
      emit_expr ctx idx;
      emit ctx ")"
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
      emit ctx "blorp_list_handoff_set_source_slot((blorp_List*)";
      emit_expr ctx result;
      emit ctx ", ";
      emit_expr ctx out_idx;
      emit ctx ", (blorp_List*)";
      emit_expr ctx source;
      emit ctx ", ";
      emit_expr ctx source_idx;
      emit ctx ")"
  | "list_copy_span_uninit", [ dst; dst_start; src; src_start; count ] ->
      (* Bulk copy into uninitialized list storage. The helper retains copied
         pointer elements only when the destination storage owns elements. *)
      emit ctx "blorp_list_copy_span_uninit((blorp_List*)";
      emit_expr ctx dst;
      emit ctx ", ";
      emit_expr ctx dst_start;
      emit ctx ", (blorp_List*)";
      emit_expr ctx src;
      emit ctx ", ";
      emit_expr ctx src_start;
      emit ctx ", ";
      emit_expr ctx count;
      emit ctx ")"
  | "list_swap_slots", [ lst; i; j ] ->
      (* Layout-aware unchecked swap. The operation only rearranges initialized
         slots, so it does not retain or release elements. *)
      List_emit.emit_swap_slots ~emit_expr ctx lst i j
  | "list_set_len", [ lst; n ] ->
      (* list->len = n — mutates in place *)
      emit ctx "(((blorp_List*)";
      emit_expr ctx lst;
      emit ctx ")->len = ";
      emit_expr ctx n;
      emit ctx ")"
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
      let list_tmp = Printf.sprintf "__list_unique_%d" (fresh_temp ctx) in
      emit ctx (Printf.sprintf "({ blorp_List* %s = (blorp_List*)" list_tmp);
      emit_expr ctx lst;
      emit ctx
        (Printf.sprintf
           "; (__builtin_expect(%s && blorp_is_unique(%s), 1) ? %s : \
            blorp_list_cow(%s)); })"
           list_tmp list_tmp list_tmp list_tmp)
  | "list_ensure_capacity", [ lst; cap ] ->
      (* COW + grow: ensure list has capacity >= cap.
         blorp_list_ensure_capacity(list, cap) *)
      let list_tmp = Printf.sprintf "__list_cap_%d" (fresh_temp ctx) in
      let cap_tmp = Printf.sprintf "__list_cap_min_%d" (fresh_temp ctx) in
      emit ctx (Printf.sprintf "({ blorp_List* %s = (blorp_List*)" list_tmp);
      emit_expr ctx lst;
      emit ctx (Printf.sprintf "; long %s = " cap_tmp);
      emit_expr ctx cap;
      emit ctx
        (Printf.sprintf
           "; (__builtin_expect(%s && blorp_is_unique(%s) && %s->capacity >= \
            %s, 1) ? %s : blorp_list_ensure_capacity(%s, %s)); })"
           list_tmp list_tmp list_tmp cap_tmp list_tmp list_tmp cap_tmp)
  | "list_reuse_alloc", [ lst; cap ] ->
      (* Consume a dead list owner and return an empty list allocation.
         blorp_list_reuse_alloc(list, cap) *)
      let layout = list_storage_layout_of_type ctx e.ty e.loc in
      if
        list_storage_layout_requires_release_or_error ~phase:Core_error.Emit
          ~loc:e.loc layout
      then begin
        let tmp = Printf.sprintf "__lst_%d" (fresh_temp ctx) in
        emit ctx
          (Printf.sprintf "({ blorp_List* %s = blorp_list_reuse_alloc(" tmp);
        emit_expr ctx lst;
        emit ctx ", ";
        emit_expr ctx cap;
        emit ctx
          (Printf.sprintf
             "); blorp_list_init_elem_release(%s, blorp_elem_release_fn); %s; \
              })"
             tmp tmp)
      end
      else begin
        emit ctx "blorp_list_reuse_alloc(";
        emit_expr ctx lst;
        emit ctx ", ";
        emit_expr ctx cap;
        emit ctx ")"
      end
  | "list_reverse_owned", [ lst ] ->
      emit ctx "blorp_list_reverse_owned((blorp_List*)";
      emit_expr ctx lst;
      emit ctx ")"
  | "list_release_elem", [ lst; idx ] ->
      (* Release element at index if list has pointer-backed elem_release. *)
      emit ctx "blorp_list_release_elem((blorp_List*)";
      emit_expr ctx lst;
      emit ctx ", ";
      emit_expr ctx idx;
      emit ctx ")"
  | "list_retain_for", [ lst; value ] ->
      (* Retain a value being stored into list, if list has elem_release. *)
      let layout = list_storage_layout_of_type ctx lst.ty lst.loc in
      if
        list_storage_layout_requires_retain_or_error ~phase:Core_error.Emit
          ~loc:lst.loc layout
      then begin
        emit ctx "blorp_list_retain_for((blorp_List*)";
        emit_expr ctx lst;
        emit ctx ", (void*)";
        emit_boxed ctx value;
        emit ctx ")"
      end
      else emit ctx "((void)0)"
  | "list_set_elem_release", [ lst; fn ] ->
      emit ctx "(((blorp_List*)";
      emit_expr ctx lst;
      emit ctx ")->elem_release = (void(*)(void*))";
      emit_expr ctx fn;
      emit ctx ")"
  (* ---- String primitives ---- *)
  | "string_len", [ s ] ->
      emit ctx "((blorp_String*)";
      emit_expr ctx s;
      emit ctx ")->len"
  | "string_get_byte", [ s; idx ] ->
      (* s->data[idx] as unsigned char → Int *)
      emit ctx "(long)(unsigned char)((blorp_String*)";
      emit_expr ctx s;
      emit ctx ")->data[";
      emit_expr ctx idx;
      emit ctx "]"
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
  | "string_alloc", [ cap ] ->
      (* Allocate fresh empty string with given byte capacity. *)
      emit ctx "blorp_string_alloc(";
      emit_expr ctx cap;
      emit ctx ")"
  | "string_set_byte", [ s; idx; byte ] ->
      (* s->data[idx] = (char)byte *)
      emit ctx "(((blorp_String*)";
      emit_expr ctx s;
      emit ctx ")->data[";
      emit_expr ctx idx;
      emit ctx "] = (char)";
      emit_expr ctx byte;
      emit ctx ")"
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
  | "string_ensure_unique", [ s ] ->
      (* COW check: copy if shared/immortal, return as-is if unique. *)
      emit ctx "blorp_string_cow(";
      emit_expr ctx s;
      emit ctx ")"
  | "string_ensure_capacity", [ s; cap ] ->
      (* COW + grow: ensure unique string with capacity >= cap bytes. *)
      emit ctx "blorp_string_ensure_capacity(";
      emit_expr ctx s;
      emit ctx ", ";
      emit_expr ctx cap;
      emit ctx ")"
  (* ---- Bytes primitives ---- *)
  | "bytes_len", [ b ] ->
      emit ctx "((blorp_Bytes*)";
      emit_expr ctx b;
      emit ctx ")->len"
  | "bytes_get", [ b; idx ] ->
      emit ctx "(long)((blorp_Bytes*)";
      emit_expr ctx b;
      emit ctx ")->data[";
      emit_expr ctx idx;
      emit ctx "]"
  | "bytes_set", [ b; idx; val_ ] ->
      emit ctx "(((blorp_Bytes*)";
      emit_expr ctx b;
      emit ctx ")->data[";
      emit_expr ctx idx;
      emit ctx "] = (unsigned char)";
      emit_expr ctx val_;
      emit ctx ")"
  | "bytes_alloc", [ cap ] ->
      emit ctx "blorp_bytes_alloc(";
      emit_expr ctx cap;
      emit ctx ")"
  | "bytes_set_len", [ b; n ] ->
      emit ctx "(((blorp_Bytes*)";
      emit_expr ctx b;
      emit ctx ")->len = ";
      emit_expr ctx n;
      emit ctx ")"
  | "bytes_cow", [ b ] ->
      emit ctx "blorp_bytes_cow(";
      emit_expr ctx b;
      emit ctx ")"
  (* ---- Bitwise primitives ---- *)
  | "bit_and", [ a; b ] ->
      emit ctx "(";
      emit_expr ctx a;
      emit ctx " & ";
      emit_expr ctx b;
      emit ctx ")"
  | "bit_or", [ a; b ] ->
      emit ctx "(";
      emit_expr ctx a;
      emit ctx " | ";
      emit_expr ctx b;
      emit ctx ")"
  | "bit_xor", [ a; b ] ->
      emit ctx "(";
      emit_expr ctx a;
      emit ctx " ^ ";
      emit_expr ctx b;
      emit ctx ")"
  | "bit_not", [ a ] ->
      emit ctx "(~";
      emit_expr ctx a;
      emit ctx ")"
  | "shift_left", [ a; n ] ->
      emit ctx "((long)(";
      emit_expr ctx a;
      emit ctx " << (";
      emit_expr ctx n;
      emit ctx " & 63)))"
  | "shift_right", [ a; n ] ->
      emit ctx "((long)(";
      emit_expr ctx a;
      emit ctx " >> (";
      emit_expr ctx n;
      emit ctx " & 63)))"
  (* ---- Dict primitives ---- *)
  | "dict_len", [ d ] ->
      emit ctx "((blorp_Dict*)";
      emit_expr ctx d;
      emit ctx ")->size"
  (* ---- Set primitives ---- *)
  | "set_len", [ s ] ->
      emit ctx "((blorp_Set*)";
      emit_expr ctx s;
      emit ctx ")->size"
  | "set_capacity", [ s ] ->
      emit ctx "((blorp_Set*)";
      emit_expr ctx s;
      emit ctx ")->capacity"
  | "set_mask", [ s ] ->
      emit ctx "((blorp_Set*)";
      emit_expr ctx s;
      emit ctx ")->mask"
  | "set_set_len", [ s; n ] ->
      emit ctx "(((blorp_Set*)";
      emit_expr ctx s;
      emit ctx ")->size = ";
      emit_expr ctx n;
      emit ctx ")"
  | "set_bucket", [ s; idx ] ->
      emit ctx "((void*)((blorp_Set*)";
      emit_expr ctx s;
      emit ctx ")->buckets[";
      emit_expr ctx idx;
      emit ctx "])"
  | "set_set_bucket", [ s; idx; entry ] ->
      emit ctx "(((blorp_Set*)";
      emit_expr ctx s;
      emit ctx ")->buckets[";
      emit_expr ctx idx;
      emit ctx "] = (blorp_SetEntry*)";
      emit_expr ctx entry;
      emit ctx ")"
  | "set_first", [ s ] ->
      emit ctx "((void*)((blorp_Set*)";
      emit_expr ctx s;
      emit ctx ")->first)"
  | "set_last", [ s ] ->
      emit ctx "((void*)((blorp_Set*)";
      emit_expr ctx s;
      emit ctx ")->last)"
  | "set_set_first", [ s; e ] ->
      emit ctx "(((blorp_Set*)";
      emit_expr ctx s;
      emit ctx ")->first = (blorp_SetEntry*)";
      emit_expr ctx e;
      emit ctx ")"
  | "set_set_last", [ s; e ] ->
      emit ctx "(((blorp_Set*)";
      emit_expr ctx s;
      emit ctx ")->last = (blorp_SetEntry*)";
      emit_expr ctx e;
      emit ctx ")"
  | "set_entry_key", [ e ] ->
      emit ctx "((blorp_SetEntry*)";
      emit_expr ctx e;
      emit ctx ")->key"
  | "set_entry_next", [ e ] ->
      emit ctx "((void*)((blorp_SetEntry*)";
      emit_expr ctx e;
      emit ctx ")->next)"
  | "set_entry_set_next", [ e; n ] ->
      emit ctx "(((blorp_SetEntry*)";
      emit_expr ctx e;
      emit ctx ")->next = (blorp_SetEntry*)";
      emit_expr ctx n;
      emit ctx ")"
  | "set_entry_prev_order", [ e ] ->
      emit ctx "((void*)((blorp_SetEntry*)";
      emit_expr ctx e;
      emit ctx ")->prev_order)"
  | "set_entry_next_order", [ e ] ->
      emit ctx "((void*)((blorp_SetEntry*)";
      emit_expr ctx e;
      emit ctx ")->next_order)"
  | "set_entry_set_prev_order", [ e; p ] ->
      emit ctx "(((blorp_SetEntry*)";
      emit_expr ctx e;
      emit ctx ")->prev_order = (blorp_SetEntry*)";
      emit_expr ctx p;
      emit ctx ")"
  | "set_entry_set_next_order", [ e; n ] ->
      emit ctx "(((blorp_SetEntry*)";
      emit_expr ctx e;
      emit ctx ")->next_order = (blorp_SetEntry*)";
      emit_expr ctx n;
      emit ctx ")"
  | "set_hash", [ s; key ] ->
      emit ctx "((long)((blorp_Set*)";
      emit_expr ctx s;
      emit ctx ")->hash_fn(";
      emit_expr ctx key;
      emit ctx "))"
  | "set_eq", [ s; k1; k2 ] ->
      emit ctx "((long)((blorp_Set*)";
      emit_expr ctx s;
      emit ctx ")->eq_fn(";
      emit_expr ctx k1;
      emit ctx ", ";
      emit_expr ctx k2;
      emit ctx "))"
  | "set_hash_immediate", [ key ] ->
      emit ctx "blorp_hash_int((long)(intptr_t)";
      emit_expr ctx key;
      emit ctx ")"
  | "set_eq_immediate", [ k1; k2 ] ->
      emit ctx "((long)(";
      emit_expr ctx k1;
      emit ctx " == ";
      emit_expr ctx k2;
      emit ctx "))"
  | "set_retain_key_for", [ s; key ] ->
      emit ctx "({ blorp_Set* __rts = (blorp_Set*)";
      emit_expr ctx s;
      emit ctx "; void* __rtk = (void*)";
      emit_expr ctx key;
      emit ctx
        "; if (__rts->key_release && __rtk) blorp_retain(__rtk); (void)0; })"
  | "set_alloc", [ cap ] ->
      emit ctx "blorp_set_alloc(";
      emit_expr ctx cap;
      emit ctx ")"
  | "set_alloc_entry", [ key ] ->
      emit ctx "blorp_set_alloc_entry(";
      emit_expr ctx key;
      emit ctx ")"
  | "set_free_entry", [ s; e ] ->
      emit ctx "blorp_set_free_entry((blorp_Set*)";
      emit_expr ctx s;
      emit ctx ", (blorp_SetEntry*)";
      emit_expr ctx e;
      emit ctx ")"
  | "set_cow", [ s ] ->
      emit ctx "blorp_set_cow((blorp_Set*)";
      emit_expr ctx s;
      emit ctx ")"
  | "set_reuse_alloc", [ s; cap ] ->
      emit ctx "blorp_set_reuse_alloc((blorp_Set*)";
      emit_expr ctx s;
      emit ctx ", ";
      emit_expr ctx cap;
      emit ctx ")"
  | "set_resize", [ s; cap ] ->
      emit ctx "blorp_set_resize_to((blorp_Set*)";
      emit_expr ctx s;
      emit ctx ", ";
      emit_expr ctx cap;
      emit ctx ")"
  | "set_reserve_for_len", [ s; len ] ->
      emit ctx "blorp_set_reserve_for_len((blorp_Set*)";
      emit_expr ctx s;
      emit ctx ", ";
      emit_expr ctx len;
      emit ctx ")"
  (* ---- Dict primitives ---- *)
  | "dict_capacity", [ d ] ->
      emit ctx "((blorp_Dict*)";
      emit_expr ctx d;
      emit ctx ")->capacity"
  | "dict_mask", [ d ] ->
      emit ctx "((blorp_Dict*)";
      emit_expr ctx d;
      emit ctx ")->mask"
  | "dict_grow_at", [ d ] ->
      emit ctx "((blorp_Dict*)";
      emit_expr ctx d;
      emit ctx ")->grow_at"
  | "dict_set_len", [ d; n ] ->
      emit ctx "(((blorp_Dict*)";
      emit_expr ctx d;
      emit ctx ")->size = ";
      emit_expr ctx n;
      emit ctx ")"
  | "dict_key_at", [ d; idx ] ->
      emit ctx "((blorp_Dict*)";
      emit_expr ctx d;
      emit ctx ")->keys[";
      emit_expr ctx idx;
      emit ctx "]"
  | "dict_value_at", [ d; idx ] ->
      emit ctx "((blorp_Dict*)";
      emit_expr ctx d;
      emit ctx ")->values[";
      emit_expr ctx idx;
      emit ctx "]"
  | "dict_set_key_at", [ d; idx; k ] ->
      emit ctx "(((blorp_Dict*)";
      emit_expr ctx d;
      emit ctx ")->keys[";
      emit_expr ctx idx;
      emit ctx "] = ";
      emit_expr ctx k;
      emit ctx ")"
  | "dict_set_value_at", [ d; idx; v ] ->
      emit ctx "(((blorp_Dict*)";
      emit_expr ctx d;
      emit ctx ")->values[";
      emit_expr ctx idx;
      emit ctx "] = ";
      emit_expr ctx v;
      emit ctx ")"
  | "dict_meta_get", [ d; idx ] ->
      emit ctx "((long)((blorp_Dict*)";
      emit_expr ctx d;
      emit ctx ")->meta[";
      emit_expr ctx idx;
      emit ctx "])"
  | "dict_meta_set", [ d; idx; v ] ->
      emit ctx "(((blorp_Dict*)";
      emit_expr ctx d;
      emit ctx ")->meta[";
      emit_expr ctx idx;
      emit ctx "] = (uint8_t)";
      emit_expr ctx v;
      emit ctx ")"
  | "dict_order_get", [ d; i ] ->
      emit ctx "((blorp_Dict*)";
      emit_expr ctx d;
      emit ctx ")->order[";
      emit_expr ctx i;
      emit ctx "]"
  | "dict_order_set", [ d; i; v ] ->
      emit ctx "(((blorp_Dict*)";
      emit_expr ctx d;
      emit ctx ")->order[";
      emit_expr ctx i;
      emit ctx "] = ";
      emit_expr ctx v;
      emit ctx ")"
  | "dict_order_len", [ d ] ->
      emit ctx "((blorp_Dict*)";
      emit_expr ctx d;
      emit ctx ")->order_len"
  | "dict_set_order_len", [ d; n ] ->
      emit ctx "(((blorp_Dict*)";
      emit_expr ctx d;
      emit ctx ")->order_len = ";
      emit_expr ctx n;
      emit ctx ")"
  | "dict_order_index_get", [ d; slot ] ->
      emit ctx "((blorp_Dict*)";
      emit_expr ctx d;
      emit ctx ")->order_index[";
      emit_expr ctx slot;
      emit ctx "]"
  | "dict_order_index_set", [ d; slot; v ] ->
      emit ctx "(((blorp_Dict*)";
      emit_expr ctx d;
      emit ctx ")->order_index[";
      emit_expr ctx slot;
      emit ctx "] = ";
      emit_expr ctx v;
      emit ctx ")"
  | "dict_key_release_fn", [ d ] ->
      emit ctx "((void*)((blorp_Dict*)";
      emit_expr ctx d;
      emit ctx ")->key_release)"
  | "dict_value_release_fn", [ d ] ->
      emit ctx "((void*)((blorp_Dict*)";
      emit_expr ctx d;
      emit ctx ")->value_release)"
  | "dict_hash", [ d; key ] ->
      emit ctx "((long)((blorp_Dict*)";
      emit_expr ctx d;
      emit ctx ")->hash_fn(";
      emit_expr ctx key;
      emit ctx "))"
  | "dict_eq", [ d; k1; k2 ] ->
      emit ctx "((long)((blorp_Dict*)";
      emit_expr ctx d;
      emit ctx ")->eq_fn(";
      emit_expr ctx k1;
      emit ctx ", ";
      emit_expr ctx k2;
      emit ctx "))"
  | "dict_hash_immediate", [ key ] ->
      emit ctx "blorp_hash_int((long)(intptr_t)";
      emit_expr ctx key;
      emit ctx ")"
  | "dict_eq_immediate", [ k1; k2 ] ->
      emit ctx "((long)(";
      emit_expr ctx k1;
      emit ctx " == ";
      emit_expr ctx k2;
      emit ctx "))"
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
  | "dict_alloc", [ cap ] ->
      emit ctx "blorp_dict_alloc(";
      emit_expr ctx cap;
      emit ctx ")"
  | "dict_cow", [ d ] ->
      emit ctx "blorp_dict_cow((blorp_Dict*)";
      emit_expr ctx d;
      emit ctx ")"
  | "dict_reuse_alloc", [ d; cap ] ->
      emit ctx "blorp_dict_reuse_alloc((blorp_Dict*)";
      emit_expr ctx d;
      emit ctx ", ";
      emit_expr ctx cap;
      emit ctx ")"
  | "dict_resize", [ d; cap ] ->
      emit ctx "blorp_dict_resize_to((blorp_Dict*)";
      emit_expr ctx d;
      emit ctx ", ";
      emit_expr ctx cap;
      emit ctx ")"
  (* ---- Slice primitives ---- *)
  | "slice_source", [ s ] ->
      emit ctx "((void*)((blorp_StringSlice*)";
      emit_expr ctx s;
      emit ctx ")->source)"
  | "slice_start", [ s ] ->
      emit ctx "((blorp_StringSlice*)";
      emit_expr ctx s;
      emit ctx ")->start"
  | "slice_len", [ s ] ->
      emit ctx "((blorp_StringSlice*)";
      emit_expr ctx s;
      emit ctx ")->len"
  | "slice_alloc", [ src; start; len ] ->
      emit ctx "blorp_slice_alloc(";
      emit_expr ctx src;
      emit ctx ", ";
      emit_expr ctx start;
      emit ctx ", ";
      emit_expr ctx len;
      emit ctx ")"
  (* ---- Tensor/Vector primitives ---- *)
  | "tensor_len", [ t ] ->
      emit ctx "((blorp_Vector*)";
      emit_expr ctx t;
      emit ctx ")->len"
  | "tensor_capacity", [ t ] ->
      emit ctx "((blorp_Vector*)";
      emit_expr ctx t;
      emit ctx ")->capacity"
  | "tensor_is_word_storage", [ t ] ->
      let vec_tmp = Printf.sprintf "__tensor_layout_%d" (fresh_temp ctx) in
      emit ctx (Printf.sprintf "({ blorp_Vector* %s = (blorp_Vector*)" vec_tmp);
      emit_expr ctx t;
      emit ctx
        (Printf.sprintf
           "; %s && %s->storage_mode == BLORP_VECTOR_STORAGE_POINTER && \
            %s->elem_size == (int16_t)sizeof(void*) && %s->elem_release == \
            NULL; })"
           vec_tmp vec_tmp vec_tmp vec_tmp)
  | "tensor_is_f64_storage", [ t ] ->
      let vec_tmp = Printf.sprintf "__tensor_layout_%d" (fresh_temp ctx) in
      emit ctx (Printf.sprintf "({ blorp_Vector* %s = (blorp_Vector*)" vec_tmp);
      emit_expr ctx t;
      emit ctx
        (Printf.sprintf
           "; %s && %s->storage_mode == BLORP_VECTOR_STORAGE_F64 && \
            %s->elem_size == (int16_t)sizeof(double); })"
           vec_tmp vec_tmp vec_tmp)
  | "tensor_is_f32_storage", [ t ] ->
      let vec_tmp = Printf.sprintf "__tensor_layout_%d" (fresh_temp ctx) in
      emit ctx (Printf.sprintf "({ blorp_Vector* %s = (blorp_Vector*)" vec_tmp);
      emit_expr ctx t;
      emit ctx
        (Printf.sprintf
           "; %s && %s->storage_mode == BLORP_VECTOR_STORAGE_F32 && \
            %s->elem_size == (int16_t)sizeof(float); })"
           vec_tmp vec_tmp vec_tmp)
  | "tensor_is_i64_storage", [ t ] ->
      let vec_tmp = Printf.sprintf "__tensor_layout_%d" (fresh_temp ctx) in
      emit ctx (Printf.sprintf "({ blorp_Vector* %s = (blorp_Vector*)" vec_tmp);
      emit_expr ctx t;
      emit ctx
        (Printf.sprintf
           "; %s && %s->storage_mode == BLORP_VECTOR_STORAGE_I64 && \
            %s->elem_size == (int16_t)sizeof(long); })"
           vec_tmp vec_tmp vec_tmp)
  | "tensor_is_unique", [ t ] ->
      emit ctx "blorp_is_unique((blorp_Vector*)";
      emit_expr ctx t;
      emit ctx ")"
  | "tensor_get_unchecked", [ t; idx ] -> (
      (* Direct data[idx] access — bounds proven safe at compile time. *)
      match Core_layout_type.tensor_element_storage ~reg:ctx.reg e.ty with
      | Core_layout_type.TensorElementInlineStruct c_ty ->
          let vec_tmp = Printf.sprintf "__tgu_vec_%d" (fresh_temp ctx) in
          let idx_tmp = Printf.sprintf "__tgu_idx_%d" (fresh_temp ctx) in
          let out_tmp = Printf.sprintf "__tgu_out_%d" (fresh_temp ctx) in
          emit ctx
            (Printf.sprintf "({ blorp_Vector* %s = (blorp_Vector*)" vec_tmp);
          emit_expr ctx t;
          emit ctx (Printf.sprintf "; long %s = " idx_tmp);
          emit_expr ctx idx;
          emit ctx
            (Printf.sprintf
               "; %s %s; if (__builtin_expect(%s->storage_mode == \
                BLORP_VECTOR_STORAGE_INLINE && %s->elem_size == sizeof(%s), \
                1)) { memcpy(&%s, (char*)%s->data + %s * sizeof(%s), \
                sizeof(%s)); } else { void* __raw = %s->data[%s]; %s = \
                blorp_unbox_struct(__raw, %s); } %s; })"
               c_ty out_tmp vec_tmp vec_tmp c_ty out_tmp vec_tmp idx_tmp c_ty
               c_ty vec_tmp idx_tmp out_tmp c_ty out_tmp)
      | Core_layout_type.TensorElementRawScalar _
      | Core_layout_type.TensorElementPackedBits _
      | Core_layout_type.TensorElementBoxed ->
          emit ctx "((blorp_Vector*)";
          emit_expr ctx t;
          emit ctx ")->data[";
          emit_expr ctx idx;
          emit ctx "]")
  | "tensor_get_i64_word_unchecked", [ t; idx ] ->
      emit ctx "((long)(intptr_t)((blorp_Vector*)";
      emit_expr ctx t;
      emit ctx ")->data[";
      emit_expr ctx idx;
      emit ctx "])"
  | "tensor_get_i64_raw_unchecked", [ t; idx ] ->
      emit ctx "((long*)((blorp_Vector*)";
      emit_expr ctx t;
      emit ctx ")->data)[";
      emit_expr ctx idx;
      emit ctx "]"
  | "tensor_get_f64_raw_unchecked", [ t; idx ] ->
      let vec_tmp = Printf.sprintf "__tensor_raw_vec_%d" (fresh_temp ctx) in
      let idx_tmp = Printf.sprintf "__tensor_raw_idx_%d" (fresh_temp ctx) in
      let raw_tmp = Printf.sprintf "__tensor_raw_%d" (fresh_temp ctx) in
      emit ctx (Printf.sprintf "({ blorp_Vector* %s = (blorp_Vector*)" vec_tmp);
      emit_expr ctx t;
      emit ctx (Printf.sprintf "; long %s = " idx_tmp);
      emit_expr ctx idx;
      emit ctx
        (Printf.sprintf
           "; double %s; memcpy(&%s, (char*)%s->data + %s * sizeof(double), \
            sizeof(double)); %s; })"
           raw_tmp raw_tmp vec_tmp idx_tmp raw_tmp)
  | "tensor_get_f32_raw_unchecked", [ t; idx ] ->
      let vec_tmp = Printf.sprintf "__tensor_raw_vec_%d" (fresh_temp ctx) in
      let idx_tmp = Printf.sprintf "__tensor_raw_idx_%d" (fresh_temp ctx) in
      let raw_tmp = Printf.sprintf "__tensor_raw_%d" (fresh_temp ctx) in
      emit ctx (Printf.sprintf "({ blorp_Vector* %s = (blorp_Vector*)" vec_tmp);
      emit_expr ctx t;
      emit ctx (Printf.sprintf "; long %s = " idx_tmp);
      emit_expr ctx idx;
      emit ctx
        (Printf.sprintf
           "; float %s; memcpy(&%s, (char*)%s->data + %s * sizeof(float), \
            sizeof(float)); %s; })"
           raw_tmp raw_tmp vec_tmp idx_tmp raw_tmp)
  | "tensor_get_f64", [ t; idx ] ->
      emit ctx "blorp_vector_read_f64((blorp_Vector*)";
      emit_expr ctx t;
      emit ctx ", ";
      emit_expr ctx idx;
      emit ctx ")"
  | "tensor_get_f32", [ t; idx ] ->
      emit ctx "blorp_vector_read_f32((blorp_Vector*)";
      emit_expr ctx t;
      emit ctx ", ";
      emit_expr ctx idx;
      emit ctx ")"
  | "tensor_get_f16", [ t; idx ] ->
      emit ctx "blorp_vector_read_f16((blorp_Vector*)";
      emit_expr ctx t;
      emit ctx ", ";
      emit_expr ctx idx;
      emit ctx ")"
  | "tensor_set_f64", [ t; idx; v ] ->
      emit ctx "blorp_vector_write_f64((blorp_Vector*)";
      emit_expr ctx t;
      emit ctx ", ";
      emit_expr ctx idx;
      emit ctx ", ";
      emit_expr ctx v;
      emit ctx ")"
  | "tensor_set_f32", [ t; idx; v ] ->
      emit ctx "blorp_vector_write_f32((blorp_Vector*)";
      emit_expr ctx t;
      emit ctx ", ";
      emit_expr ctx idx;
      emit ctx ", ";
      emit_expr ctx v;
      emit ctx ")"
  | "tensor_set_f16", [ t; idx; v ] ->
      emit ctx "blorp_vector_write_f16((blorp_Vector*)";
      emit_expr ctx t;
      emit ctx ", ";
      emit_expr ctx idx;
      emit ctx ", ";
      emit_expr ctx v;
      emit ctx ")"
  | "tensor_get_i64", [ t; idx ] ->
      emit ctx "blorp_vector_read_i64((blorp_Vector*)";
      emit_expr ctx t;
      emit ctx ", ";
      emit_expr ctx idx;
      emit ctx ")"
  | "tensor_set_i64", [ t; idx; v ] ->
      emit ctx "blorp_vector_write_i64((blorp_Vector*)";
      emit_expr ctx t;
      emit ctx ", ";
      emit_expr ctx idx;
      emit ctx ", ";
      emit_expr ctx v;
      emit ctx ")"
  | "tensor_alloc", [ size ] -> emit_tensor_alloc ~emit_expr ctx e size
  (* ---- Fixed primitives ---- *)
  | "fixed_value", [ f ] ->
      emit ctx "((blorp_Fixed*)";
      emit_expr ctx f;
      emit ctx ")->value"
  | "fixed_scale", [ f ] ->
      emit ctx "(long)((blorp_Fixed*)";
      emit_expr ctx f;
      emit ctx ")->scale"
  | "fixed_precision", [ f ] ->
      emit ctx "(long)((blorp_Fixed*)";
      emit_expr ctx f;
      emit ctx ")->precision"
  (* ---- Math intrinsics ---- *)
  (* Unary: emit as bare C math function call *)
  | ( ( "math_sin" | "math_cos" | "math_tan" | "math_asin" | "math_acos"
      | "math_atan" | "math_sinh" | "math_cosh" | "math_tanh" | "math_asinh"
      | "math_acosh" | "math_atanh" | "math_exp" | "math_exp2" | "math_expm1"
      | "math_log" | "math_log2" | "math_log10" | "math_log1p" | "math_sqrt"
      | "math_cbrt" | "math_floor" | "math_ceil" | "math_trunc" ),
      [ x ] ) ->
      (* Strip "math_" prefix to get the C function name *)
      let c_name = String.sub name 5 (String.length name - 5) in
      emit ctx c_name;
      emit ctx "(";
      emit_expr ctx x;
      emit ctx ")"
  (* Binary *)
  | ( ("math_pow" | "math_atan2" | "math_hypot" | "math_fmod" | "math_copysign"),
      [ x; y ] ) ->
      let c_name = String.sub name 5 (String.length name - 5) in
      emit ctx c_name;
      emit ctx "(";
      emit_expr ctx x;
      emit ctx ", ";
      emit_expr ctx y;
      emit ctx ")"
  (* Ternary *)
  | "math_fma", [ x; y; z ] ->
      emit ctx "fma(";
      emit_expr ctx x;
      emit ctx ", ";
      emit_expr ctx y;
      emit ctx ", ";
      emit_expr ctx z;
      emit ctx ")"
  (* Constants — inline, no function call *)
  | "math_infinity", [] -> emit ctx "(1.0/0.0)"
  | "math_neg_infinity", [] -> emit ctx "(-1.0/0.0)"
  | "math_nan", [] -> emit ctx "(0.0/0.0)"
  (* Classification — C macros *)
  | "math_is_nan", [ x ] ->
      emit ctx "isnan(";
      emit_expr ctx x;
      emit ctx ")"
  | "math_is_inf", [ x ] ->
      emit ctx "isinf(";
      emit_expr ctx x;
      emit ctx ")"
  | "math_is_finite", [ x ] ->
      emit ctx "isfinite(";
      emit_expr ctx x;
      emit ctx ")"
  | "fixed_alloc", [ v; s; p ] ->
      emit ctx "blorp_fixed_raw(";
      emit_expr ctx v;
      emit ctx ", (int)";
      emit_expr ctx s;
      emit ctx ", (int)";
      emit_expr ctx p;
      emit ctx ")"
  | "fixed_pow10", [ n ] ->
      emit ctx "blorp_pow10((int)";
      emit_expr ctx n;
      emit ctx ")"
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
