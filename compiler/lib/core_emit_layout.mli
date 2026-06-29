(** Leaf layout helpers shared by the Core -> JSON projector and Blorp-owned
    prepared renderers. *)

val list_runtime_storage_args : Core.list_storage_layout -> string * string
(** C runtime storage-mode and element-size arguments for a prepared list
    layout. This is data projection, not C statement/expression emission. *)

val tensor_element_storage_for_reg :
  reg:Codegen_types.registry ->
  Ast.type_expr ->
  Core_layout_type.tensor_element_storage

val tensor_storage_layout_of_type_for_reg :
  reg:Codegen_types.registry ->
  Ast.type_expr ->
  Ast.loc ->
  Core.tensor_storage_layout

val c_type_for_reg : reg:Codegen_types.registry -> Ast.type_expr -> string
