(** C emission helpers for list intrinsics.

    The top-level intrinsic dispatcher owns name/arity routing. This module
    owns the list storage-layout details so inline, struct-inline, and pointer
    storage paths stay in one place. *)

open Core
open Core_emit_context
open Core_emit_util

type store_runtime = ListSetRaw | ListHandoffSetOwned

let store_runtime_fn = function
  | ListSetRaw -> "blorp_list_set_raw"
  | ListHandoffSetOwned -> "blorp_list_handoff_set_owned"

let emit_runtime_store ~(emit_expr : Core_emit_context.t -> core -> unit)
    ~(emit_boxed : Core_emit_context.t -> core -> unit)
    (ctx : Core_emit_context.t) store_fn lst idx val_ =
  let store_fn_c = store_runtime_fn store_fn in
  emit ctx (Printf.sprintf "%s((blorp_List*)" store_fn_c);
  emit_expr ctx lst;
  emit ctx ", ";
  emit_expr ctx idx;
  emit ctx ", (void*)";
  emit_boxed ctx val_;
  emit ctx ")"

let emit_boxed_struct_temp (ctx : Core_emit_context.t) tmp c_ty value_ty =
  if Core_layout_type.is_stack_result_type ~reg:ctx.reg value_ty then
    emit ctx (Printf.sprintf "blorp_box_stack_result(%s)" tmp)
  else emit ctx (Printf.sprintf "blorp_box_struct(&%s, sizeof(%s))" tmp c_ty)

let emit_store ~(emit_expr : Core_emit_context.t -> core -> unit)
    ~(emit_boxed : Core_emit_context.t -> core -> unit)
    (ctx : Core_emit_context.t) store_fn lst idx val_ =
  let layout = list_storage_layout_of_type ctx lst.ty lst.loc in
  match layout.lsl_slots with
  | ListInlineStructStorage c_ty ->
      let list_tmp = Printf.sprintf "__list_store_%d" (fresh_temp ctx) in
      let idx_tmp = Printf.sprintf "__list_store_idx_%d" (fresh_temp ctx) in
      let tmp = Printf.sprintf "__list_elem_%d" (fresh_temp ctx) in
      emit ctx (Printf.sprintf "({ blorp_List* %s = (blorp_List*)" list_tmp);
      emit_expr ctx lst;
      emit ctx (Printf.sprintf "; long %s = " idx_tmp);
      emit_expr ctx idx;
      emit ctx (Printf.sprintf "; %s %s = " c_ty tmp);
      emit_expr ctx val_;
      emit ctx
        (Printf.sprintf
           "; if (%s && %s->storage_mode == BLORP_LIST_STORAGE_INLINE && \
            %s->elem_size == (int16_t)sizeof(%s)) { \
            blorp_list_set_raw_copy(%s, %s, &%s); } else { %s((blorp_List*)%s, \
            %s, (void*)"
           list_tmp list_tmp list_tmp c_ty list_tmp idx_tmp tmp
           (store_runtime_fn store_fn)
           list_tmp idx_tmp);
      emit_boxed_struct_temp ctx tmp c_ty val_.ty;
      emit ctx "); } })"
  | ListInlineStorage width ->
      let width_bytes = inline_storage_width_bytes width in
      let list_tmp = Printf.sprintf "__list_store_%d" (fresh_temp ctx) in
      let idx_tmp = Printf.sprintf "__list_store_idx_%d" (fresh_temp ctx) in
      let bits_tmp = Printf.sprintf "__list_store_bits_%d" (fresh_temp ctx) in
      emit ctx (Printf.sprintf "({ blorp_List* %s = (blorp_List*)" list_tmp);
      emit_expr ctx lst;
      emit ctx (Printf.sprintf "; long %s = " idx_tmp);
      emit_expr ctx idx;
      emit ctx (Printf.sprintf "; uintptr_t %s = (uintptr_t)" bits_tmp);
      emit_boxed ctx val_;
      emit ctx
        (Printf.sprintf "; memcpy((char*)%s->data + %s * %d, &%s, %d); })"
           list_tmp idx_tmp width_bytes bits_tmp width_bytes)
  | ListPointerStorage ->
      emit_runtime_store ~emit_expr ~emit_boxed ctx store_fn lst idx val_

let emit_pointer_swap_slots ctx ~list_tmp ~i_tmp ~j_tmp =
  let tmp = Printf.sprintf "__list_swap_tmp_%d" (fresh_temp ctx) in
  emit ctx
    (Printf.sprintf
       "void* %s = blorp_list_get(%s, %s); blorp_list_set_raw(%s, %s, \
        blorp_list_get(%s, %s)); blorp_list_set_raw(%s, %s, %s);"
       tmp list_tmp i_tmp list_tmp i_tmp list_tmp j_tmp list_tmp j_tmp tmp)

let emit_swap_slots ~(emit_expr : Core_emit_context.t -> core -> unit)
    (ctx : Core_emit_context.t) lst i j =
  let layout = list_storage_layout_of_type ctx lst.ty lst.loc in
  let list_tmp = Printf.sprintf "__list_swap_%d" (fresh_temp ctx) in
  let i_tmp = Printf.sprintf "__list_swap_i_%d" (fresh_temp ctx) in
  let j_tmp = Printf.sprintf "__list_swap_j_%d" (fresh_temp ctx) in
  emit ctx (Printf.sprintf "({ blorp_List* %s = (blorp_List*)" list_tmp);
  emit_expr ctx lst;
  emit ctx (Printf.sprintf "; long %s = " i_tmp);
  emit_expr ctx i;
  emit ctx (Printf.sprintf "; long %s = " j_tmp);
  emit_expr ctx j;
  emit ctx
    (Printf.sprintf "; if (__builtin_expect(%s && %s != %s, 1)) { " list_tmp
       i_tmp j_tmp);
  (match layout.lsl_slots with
  | ListInlineStructStorage _ ->
      let base_tmp = Printf.sprintf "__list_swap_base_%d" (fresh_temp ctx) in
      let size_tmp = Printf.sprintf "__list_swap_size_%d" (fresh_temp ctx) in
      let a_tmp = Printf.sprintf "__list_swap_a_%d" (fresh_temp ctx) in
      let b_tmp = Printf.sprintf "__list_swap_b_%d" (fresh_temp ctx) in
      let bytes_tmp = Printf.sprintf "__list_swap_bytes_%d" (fresh_temp ctx) in
      emit ctx
        (Printf.sprintf
           "if (%s->storage_mode == BLORP_LIST_STORAGE_INLINE) { char* %s = \
            (char*)%s->data; size_t %s = (size_t)%s->elem_size; void* %s = %s \
            + %s * %s; void* %s = %s + %s * %s; unsigned char %s[%s]; \
            memcpy(%s, %s, %s); memcpy(%s, %s, %s); memcpy(%s, %s, %s); } else \
            { "
           list_tmp base_tmp list_tmp size_tmp list_tmp a_tmp base_tmp i_tmp
           size_tmp b_tmp base_tmp j_tmp size_tmp bytes_tmp size_tmp bytes_tmp
           a_tmp size_tmp a_tmp b_tmp size_tmp b_tmp bytes_tmp size_tmp);
      emit_pointer_swap_slots ctx ~list_tmp ~i_tmp ~j_tmp;
      emit ctx " }"
  | ListInlineStorage width ->
      let width_bytes = inline_storage_width_bytes width in
      let base_tmp = Printf.sprintf "__list_swap_base_%d" (fresh_temp ctx) in
      let tmp = Printf.sprintf "__list_swap_bits_%d" (fresh_temp ctx) in
      emit ctx
        (Printf.sprintf
           "char* %s = (char*)%s->data; uintptr_t %s = 0; memcpy(&%s, %s + %s \
            * %d, %d); memcpy(%s + %s * %d, %s + %s * %d, %d); memcpy(%s + %s \
            * %d, &%s, %d);"
           base_tmp list_tmp tmp tmp base_tmp i_tmp width_bytes width_bytes
           base_tmp i_tmp width_bytes base_tmp j_tmp width_bytes width_bytes
           base_tmp j_tmp width_bytes tmp width_bytes)
  | ListPointerStorage -> emit_pointer_swap_slots ctx ~list_tmp ~i_tmp ~j_tmp);
  emit ctx " } })"
