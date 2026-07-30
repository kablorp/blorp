(** Type-level facts that compiler phases need for policy decisions.

    This module is intentionally data-oriented: phases should ask for explicit
    type properties instead of guessing from scattered string checks. *)

open Ast

type recursion_storage = Inline_recursion | Heap_indirected_recursion

type constructor_space =
  | Open_scalar_space
  | Sequence_space
  | Closed_nominal_space

let string_member name names = List.exists (String.equal name) names

let heap_indirected_names =
  [
    "Option";
    "List";
    "Dict";
    "Set";
    "Bytes";
    "Tensor";
    "Vector";
    "Matrix";
    "Channel";
  ]

let recursion_storage_of_name name =
  if string_member name heap_indirected_names then Heap_indirected_recursion
  else Inline_recursion

let is_heap_indirected_name name =
  match recursion_storage_of_name name with
  | Heap_indirected_recursion -> true
  | Inline_recursion -> false

let primitive_homes =
  [
    ("Int", "std/int");
    ("Int8", "std/int8");
    ("Int16", "std/int16");
    ("Int32", "std/int32");
    ("Int64", "std/int64");
    ("Int128", "std/int128");
    ("UInt8", "std/uint8");
    ("UInt16", "std/uint16");
    ("UInt32", "std/uint32");
    ("UInt64", "std/uint64");
    ("UInt128", "std/uint128");
    ("Float", "std/float");
    ("Float32", "std/float32");
    ("Float16", "std/float16");
    ("Bool", "std/bool");
    ("Char", "std/char");
    ("String", "std/string");
    ("StringSlice", "std/slice");
    ("Bytes", "std/bytes");
    ("Fixed", "std/fixed");
    ("List", "std/list");
    ("Dict", "std/dict");
    ("Set", "std/set");
    ("Tensor", "std/tensor");
    ("Vector", "std/tensor");
    ("Matrix", "std/tensor");
    ("Option", "std/option");
    ("Result", "std/result");
  ]

let primitive_home_for_name name = List.assoc_opt name primitive_homes

let primitive_home (ty : type_expr) : string option =
  match Codegen_types.normalize_type ty with
  | TyTuple _ -> Some "std/tuple"
  | TyArray _ -> Some "std/tensor"
  | TyNamed (name, _) -> primitive_home_for_name name
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

let open_scalar_names =
  [ "Float"; "Float32"; "Float16"; "String"; "Char" ] @ Types.all_int_type_names

let constructor_space_of_name name =
  if String.equal name "List" then Sequence_space
  else if string_member name open_scalar_names then Open_scalar_space
  else Closed_nominal_space

let is_open_exhaustiveness_scalar_name name =
  match constructor_space_of_name name with
  | Open_scalar_space -> true
  | Sequence_space | Closed_nominal_space -> false
