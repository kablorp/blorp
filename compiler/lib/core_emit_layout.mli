(** Leaf layout helpers shared by Core emit utilities and Blorp-owned prepared
    renderers. *)

val list_storage_layout_of_type :
  Core_emit_context.t -> Ast.type_expr -> Ast.loc -> Core.list_storage_layout

val tensor_element_storage :
  Core_emit_context.t ->
  Ast.type_expr ->
  Core_layout_type.tensor_element_storage

val tensor_element_storage_for_reg :
  reg:Codegen_types.registry ->
  Ast.type_expr ->
  Core_layout_type.tensor_element_storage

val tensor_storage_layout_of_type :
  Core_emit_context.t -> Ast.type_expr -> Ast.loc -> Core.tensor_storage_layout

val tensor_storage_layout_of_type_for_reg :
  reg:Codegen_types.registry ->
  Ast.type_expr ->
  Ast.loc ->
  Core.tensor_storage_layout

val c_type_for_reg : reg:Codegen_types.registry -> Ast.type_expr -> string

val tensor_storage_layout_of_elem :
  Core_emit_context.t -> Ast.type_expr -> Ast.loc -> Core.tensor_storage_layout
