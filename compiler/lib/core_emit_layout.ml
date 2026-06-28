(** Leaf layout helpers shared by Core emit utilities and Blorp-owned prepared
    renderers.

    This module intentionally depends only on layout/type facts, not on
    [Core_emit_util] or backend emission modules. Keeping it low in the
    dependency graph lets the single Blorp backend facade depend on prepared
    renderers without creating cycles through shared emitter utilities. *)

let list_storage_layout_of_type (ctx : Core_emit_context.t)
    (list_ty : Ast.type_expr) (loc : Ast.loc) : Core.list_storage_layout =
  Core_layout_type.list_storage_layout_of_type ~reg:ctx.reg list_ty loc

let list_storage_mode_pointer_arg = "BLORP_LIST_STORAGE_POINTER"
let list_storage_mode_inline_arg = "BLORP_LIST_STORAGE_INLINE"
let list_element_size_pointer_arg = "sizeof(void*)"

let list_runtime_storage_args (layout : Core.list_storage_layout) :
    string * string =
  match layout.lsl_slots with
  | Core.ListPointerStorage ->
      (list_storage_mode_pointer_arg, list_element_size_pointer_arg)
  | Core.ListInlineStorage width ->
      ( list_storage_mode_inline_arg,
        string_of_int (Core.inline_storage_width_bytes width) )
  | Core.ListInlineStructStorage c_ty ->
      (list_storage_mode_inline_arg, Printf.sprintf "sizeof(%s)" c_ty)

let tensor_element_storage (ctx : Core_emit_context.t) elem_ty =
  Core_layout_type.tensor_element_storage ~reg:ctx.reg elem_ty

let tensor_element_storage_for_reg ~reg elem_ty =
  Core_layout_type.tensor_element_storage ~reg elem_ty

let tensor_storage_layout_of_type (ctx : Core_emit_context.t)
    (tensor_ty : Ast.type_expr) (loc : Ast.loc) : Core.tensor_storage_layout =
  Core_layout_type.tensor_storage_layout_of_type ~reg:ctx.reg tensor_ty loc

let tensor_storage_layout_of_type_for_reg ~reg tensor_ty loc =
  Core_layout_type.tensor_storage_layout_of_type ~reg tensor_ty loc

let c_type_for_reg ~reg ty = Core_layout_type.c_type ~reg ty

let tensor_storage_layout_of_elem (ctx : Core_emit_context.t)
    (elem_ty : Ast.type_expr) (loc : Ast.loc) : Core.tensor_storage_layout =
  Core_layout_type.tensor_storage_layout_of_elem ~reg:ctx.reg elem_ty loc
