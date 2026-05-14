(** Static tensor type facts for late Core passes.

    This module is a narrow boundary for tensor/vector/matrix type
    normalization used by Core optimization and layout-adjacent passes. It does
    not decide runtime storage layout; [Core_layout_type] owns that. *)

type floating_scalar = Float64 | Float32

type t = private {
  semantic_ty : Ast.type_expr;
  elem_ty : Ast.type_expr;
  dims : Ast.type_expr list;
}

val of_type : reg:Codegen_types.registry -> Ast.type_expr -> t option
val of_core : reg:Codegen_types.registry -> Core.core -> t option
val is_type : reg:Codegen_types.registry -> Ast.type_expr -> bool
val same_static_shape : t -> t -> bool

val floating_scalar_of_type :
  reg:Codegen_types.registry -> Ast.type_expr -> floating_scalar option

val floating_scalar_of_tensor : t -> floating_scalar option
