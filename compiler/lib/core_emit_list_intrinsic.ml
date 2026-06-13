(** C emission helpers for list intrinsics.

    The top-level intrinsic dispatcher owns name/arity routing. This module
    owns the list storage-layout details so inline, struct-inline, and pointer
    storage paths stay in one place. *)

open Core
open Core_emit_util

type store_runtime = ListSetRaw | ListHandoffSetOwned

let emit_pointer_store ~(emit_expr : Core_emit_context.t -> core -> unit)
    ~(emit_boxed : Core_emit_context.t -> core -> unit)
    (ctx : Core_emit_context.t) store_runtime lst idx val_ =
  match store_runtime with
  | ListSetRaw ->
      Core_emit_blorp_prepared_list.emit_pointer_set_raw_store ~emit_expr
        ~emit_boxed ctx lst idx val_
  | ListHandoffSetOwned ->
      Core_emit_blorp_prepared_list.emit_pointer_handoff_set_owned_store
        ~emit_expr ~emit_boxed ctx lst idx val_

let emit_inline_struct_store ~(emit_expr : Core_emit_context.t -> core -> unit)
    (ctx : Core_emit_context.t) store_runtime lst idx val_ ~struct_ty =
  match store_runtime with
  | ListSetRaw ->
      Core_emit_blorp_prepared_list.emit_inline_struct_set_raw_store ~emit_expr
        ctx lst idx val_ ~struct_ty
  | ListHandoffSetOwned ->
      Core_emit_blorp_prepared_list.emit_inline_struct_handoff_set_owned_store
        ~emit_expr ctx lst idx val_ ~struct_ty

let emit_store ~(emit_expr : Core_emit_context.t -> core -> unit)
    ~(emit_boxed : Core_emit_context.t -> core -> unit)
    (ctx : Core_emit_context.t) store_runtime lst idx val_ =
  let layout = list_storage_layout_of_type ctx lst.ty lst.loc in
  match layout.lsl_slots with
  | ListInlineStructStorage c_ty ->
      emit_inline_struct_store ~emit_expr ctx store_runtime lst idx val_
        ~struct_ty:c_ty
  | ListInlineStorage width ->
      Core_emit_blorp_prepared_list.emit_inline_bits_store ~emit_expr
        ~emit_boxed ctx lst idx val_ width
  | ListPointerStorage ->
      emit_pointer_store ~emit_expr ~emit_boxed ctx store_runtime lst idx val_

let emit_swap_slots ~(emit_expr : Core_emit_context.t -> core -> unit)
    (ctx : Core_emit_context.t) lst i j =
  let layout = list_storage_layout_of_type ctx lst.ty lst.loc in
  match layout.lsl_slots with
  | ListInlineStructStorage _ ->
      Core_emit_blorp_prepared_list.emit_inline_struct_swap ~emit_expr ctx lst i
        j
  | ListInlineStorage width ->
      Core_emit_blorp_prepared_list.emit_inline_bits_swap ~emit_expr ctx lst i j
        width
  | ListPointerStorage ->
      Core_emit_blorp_prepared_list.emit_pointer_swap ~emit_expr ctx lst i j
