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

val canonical_type :
  reg:Codegen_types.registry -> Ast.type_expr -> Ast.type_expr

val boxed_storage_needs_release :
  reg:Codegen_types.registry -> Ast.type_expr -> Ast.loc -> bool

val release_policy_tag :
  reg:Codegen_types.registry -> Ast.type_expr -> string

val retain_policy_tag : reg:Codegen_types.registry -> Ast.type_expr -> string

val union_field_release_policy_tag :
  reg:Codegen_types.registry ->
  Codegen_types.union_payload_storage ->
  Ast.type_expr ->
  Ast.loc ->
  string

val make_box_op :
  reg:Codegen_types.registry ->
  Core.core ->
  Ast.type_expr ->
  Core.box_op

val boxed_expr_transfers_ownership :
  reg:Codegen_types.registry -> Core.core -> bool

val boxed_storage_value :
  reg:Codegen_types.registry -> Core.core -> Core.boxed_storage_value

val dict_value_needs_release :
  reg:Codegen_types.registry -> Ast.type_expr -> Ast.loc -> bool
