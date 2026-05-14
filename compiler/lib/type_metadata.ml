(** Type-level facts that compiler phases need for policy decisions.

    This module is intentionally data-oriented: phases should ask for explicit
    type properties instead of guessing from scattered string checks. *)

open Ast

type recursion_storage = Inline_recursion | Heap_indirected_recursion

type constructor_space =
  | Open_scalar_space
  | Sequence_space
  | Closed_nominal_space

let recursion_storage_of_name = function
  | "Option" | "List" | "Dict" | "Set" | "Bytes" | "Tensor" | "Vector"
  | "Matrix" | "Channel" ->
      Heap_indirected_recursion
  | _ -> Inline_recursion

let is_heap_indirected_name name =
  match recursion_storage_of_name name with
  | Heap_indirected_recursion -> true
  | Inline_recursion -> false

let primitive_home (ty : type_expr) : string option =
  match Codegen_types.normalize_type ty with
  | TyTuple _ -> Some "std/tuple"
  | TyArray _ -> Some "std/tensor"
  | TyNamed (name, _) -> (
      match name with
      | "Int" -> Some "std/int"
      | "Int8" -> Some "std/int8"
      | "Int16" -> Some "std/int16"
      | "Int32" -> Some "std/int32"
      | "Int64" -> Some "std/int64"
      | "Int128" -> Some "std/int128"
      | "UInt8" -> Some "std/uint8"
      | "UInt16" -> Some "std/uint16"
      | "UInt32" -> Some "std/uint32"
      | "UInt64" -> Some "std/uint64"
      | "UInt128" -> Some "std/uint128"
      | "Float" -> Some "std/float"
      | "Float32" -> Some "std/float32"
      | "Float16" -> Some "std/float16"
      | "Bool" -> Some "std/bool"
      | "Char" -> Some "std/char"
      | "String" -> Some "std/string"
      | "StringSlice" -> Some "std/slice"
      | "Bytes" -> Some "std/bytes"
      | "Fixed" -> Some "std/fixed"
      | "List" -> Some "std/list"
      | "Dict" -> Some "std/dict"
      | "Set" -> Some "std/set"
      | "Tensor" | "Vector" | "Matrix" -> Some "std/tensor"
      | "Option" -> Some "std/option"
      | "Result" -> Some "std/result"
      | _ -> None)
  | _ -> None

let is_struct_scalar_field_type = function
  | TyNamed ("Int", [])
  | TyNamed ("Float", [])
  | TyNamed ("Bool", [])
  | TyNamed ("Char", [])
  | TyNamed ("Ptr", []) ->
      true
  | ty when Types.is_float32_type ty -> true
  | ty when Types.is_float16_type ty -> true
  | ty when Types.is_any_integer_type ty -> true
  | _ -> false

let has_native_operator_fast_path_type ty =
  match Codegen_types.normalize_type ty with
  | TyArray _ -> true
  | TyNamed (("String" | "Bool" | "Char" | "Bytes" | "Fixed"), []) -> true
  | TyNamed (("Float" | "Float32" | "Float16"), []) -> true
  | ty when Types.Dim.is_value_dim ty -> true
  | ty when Types.is_any_integer_type ty -> true
  | _ -> false

let has_builtin_to_string_fallback_type ty =
  match Codegen_types.normalize_type ty with
  | TyArray _ -> true
  | TyNamed ("String", []) -> true
  | TyNamed (("Float" | "Float32" | "Float16"), []) -> true
  | TyNamed (("Bool" | "Char" | "Bytes"), []) -> true
  | TyNamed ("List", _) -> true
  | TyNamed (("StringSlice" | "Url" | "Fixed"), []) -> true
  | ty when Types.Dim.is_value_dim ty -> true
  | ty when Types.is_any_integer_type ty -> true
  | _ -> false

let constructor_space_of_name = function
  | "List" -> Sequence_space
  | "Float" | "Float32" | "Float16" | "String" | "Char" -> Open_scalar_space
  | name when List.mem name Types.all_int_type_names -> Open_scalar_space
  | _ -> Closed_nominal_space

let is_open_exhaustiveness_scalar_name name =
  match constructor_space_of_name name with
  | Open_scalar_space -> true
  | Sequence_space | Closed_nominal_space -> false
