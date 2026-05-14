(** Static tensor type facts for late Core passes. *)

type floating_scalar = Float64 | Float32

type t = {
  semantic_ty : Ast.type_expr;
  elem_ty : Ast.type_expr;
  dims : Ast.type_expr list;
}

let normalize_type ~reg ty =
  Codegen_types.expand_alias ~reg ty |> Codegen_types.normalize_type

let of_type ~reg ty =
  let semantic_ty = normalize_type ~reg ty in
  match Types.array_parts semantic_ty with
  | Some (elem_ty, dims) -> Some { semantic_ty; elem_ty; dims }
  | None -> None

let of_core ~reg (expr : Core.core) = of_type ~reg expr.ty
let is_type ~reg ty = Option.is_some (of_type ~reg ty)

let same_static_shape left right =
  List.length left.dims = List.length right.dims
  && List.for_all2 Types.types_equal left.dims right.dims

let floating_scalar_of_type ~reg ty =
  match normalize_type ~reg ty with
  | Ast.TyNamed ("Float", []) -> Some Float64
  | Ast.TyNamed ("Float32", []) -> Some Float32
  | _ -> None

let floating_scalar_of_tensor tensor =
  match tensor.elem_ty with
  | Ast.TyNamed ("Float", []) -> Some Float64
  | Ast.TyNamed ("Float32", []) -> Some Float32
  | _ -> None
