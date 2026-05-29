(** Late dispatch policy for hash-backed containers.

    Dict/Set constructor selection is a runtime-layout decision: string and
    float keys use specialized runtime tables, enum keys use the generic table,
    and user nominal keys use custom Hashable/Equatable callbacks. Keep that
    rule in one place so specialization and final Core preparation cannot drift
    apart. *)

type dispatch =
  | HashString
  | HashFloat
  | HashGeneric
  | HashCustom of Ast.type_expr

let builtin_generic_name = function
  | "Int" | "Int8" | "Int16" | "Int32" | "Int64" | "Int128" | "UInt8" | "UInt16"
  | "UInt32" | "UInt64" | "UInt128" | "Bool" | "Char" | "Option" | "Result"
  | "List" | "Dict" | "Set" | "Tensor" | "Vector" | "Matrix" | "Bytes"
  | "Tuple2" | "Tuple3" | "Tuple4" | "LiteralString" | "StringSlice" ->
      true
  | _ -> false

let dispatch_for_key ~reg key_ty =
  let key_ty = Core_layout_type.canonical_type ~reg key_ty in
  match key_ty with
  | Ast.TyNamed ("String", []) -> HashString
  | Ast.TyNamed (("Float" | "Float32" | "Float16"), []) -> HashFloat
  | Ast.TyNamed (name, _) when Codegen_types.is_enum_type reg name ->
      HashGeneric
  | Ast.TyNamed (name, _) when builtin_generic_name name -> HashGeneric
  | Ast.TyNamed _ -> HashCustom key_ty
  | _ -> HashGeneric

let dict_constructor_kind_of_dispatch = function
  | HashString -> Core.DictString
  | HashFloat -> Core.DictFloat
  | HashGeneric -> Core.DictGeneric
  | HashCustom key_ty -> Core.DictCustom key_ty

let set_constructor_kind_of_dispatch = function
  | HashString -> Core.SetString
  | HashFloat -> Core.SetFloat
  | HashGeneric -> Core.SetGeneric
  | HashCustom elem_ty -> Core.SetCustom elem_ty

let dict_constructor_builtin_name_of_dispatch = function
  | HashString -> "blorp_dict_new_string"
  | HashFloat -> "blorp_dict_new_float"
  | HashGeneric -> "blorp_dict_new"
  | HashCustom _ -> "blorp_dict_new_custom"

let dict_capacity_constructor_builtin_name_of_dispatch = function
  | HashString -> "blorp_dict_with_capacity_string"
  | HashFloat -> "blorp_dict_with_capacity_float"
  | HashGeneric -> "blorp_dict_with_capacity"
  | HashCustom _ -> "blorp_dict_with_capacity_custom"

let set_constructor_builtin_name_of_dispatch = function
  | HashString -> "blorp_set_new_string"
  | HashFloat -> "blorp_set_new_float"
  | HashGeneric -> "blorp_set_new"
  | HashCustom _ -> "blorp_set_new_custom"

let dict_constructor_kind ~reg key_ty =
  dispatch_for_key ~reg key_ty |> dict_constructor_kind_of_dispatch

let set_constructor_kind ~reg elem_ty =
  dispatch_for_key ~reg elem_ty |> set_constructor_kind_of_dispatch

let dict_constructor_builtin_name ~reg key_ty =
  dispatch_for_key ~reg key_ty |> dict_constructor_builtin_name_of_dispatch

let dict_capacity_constructor_builtin_name ~reg key_ty =
  dispatch_for_key ~reg key_ty
  |> dict_capacity_constructor_builtin_name_of_dispatch

let set_constructor_builtin_name ~reg elem_ty =
  dispatch_for_key ~reg elem_ty |> set_constructor_builtin_name_of_dispatch
