(** Representation policy for [Option[T]].

    This module only classifies representation. Lowering, Perceus, and C
    emission consume this policy in later slices; they should not infer option
    layout from scattered type-name checks. *)

type scalar_payload =
  | ScalarVoid
  | ScalarInt
  | ScalarSizedInt of string
  | ScalarInt128
  | ScalarUInt128
  | ScalarFloat
  | ScalarFloat32
  | ScalarFloat16
  | ScalarBool
  | ScalarChar
  | ScalarEnum of string
  | ScalarRange

type boxed_reason =
  | GenericPayload
  | NullableUnsafePayload
  | NestedOptionPayload
  | NestedResultPayload
  | UnsupportedPayload of string

type layout =
  | StackScalar of scalar_payload
  | StackValueRecord of string
  | NullableManagedPointer
  | BoxedUnion of boxed_reason

(** Runtime-declared primitive stack option structs. This is intentionally
    narrower than [StackScalar]: Int128/UInt128, enums, ranges, and value
    records use generated C structs rather than runtime-declared primitive ABI
    names. *)
type primitive_stack_abi =
  | StackOptionVoid
  | StackOptionInt
  | StackOptionInt8
  | StackOptionInt16
  | StackOptionInt32
  | StackOptionInt64
  | StackOptionUInt8
  | StackOptionUInt16
  | StackOptionUInt32
  | StackOptionUInt64
  | StackOptionFloat
  | StackOptionBool
  | StackOptionChar
  | StackOptionFloat32
  | StackOptionFloat16

type classification =
  | Known of layout
  | Unknown_named of string
  | Invalid_option_type of string

type primitive_stack_abi_info = {
  c_type : string;
  runtime_suffix : string;
  payload_c_type : string;
}

let primitive_stack_abi_of_scalar = function
  | ScalarVoid -> Some StackOptionVoid
  | ScalarInt -> Some StackOptionInt
  | ScalarSizedInt "Int8" -> Some StackOptionInt8
  | ScalarSizedInt "Int16" -> Some StackOptionInt16
  | ScalarSizedInt "Int32" -> Some StackOptionInt32
  | ScalarSizedInt "Int64" -> Some StackOptionInt64
  | ScalarSizedInt "UInt8" -> Some StackOptionUInt8
  | ScalarSizedInt "UInt16" -> Some StackOptionUInt16
  | ScalarSizedInt "UInt32" -> Some StackOptionUInt32
  | ScalarSizedInt "UInt64" -> Some StackOptionUInt64
  | ScalarFloat -> Some StackOptionFloat
  | ScalarBool -> Some StackOptionBool
  | ScalarChar -> Some StackOptionChar
  | ScalarFloat32 -> Some StackOptionFloat32
  | ScalarFloat16 -> Some StackOptionFloat16
  | ScalarSizedInt _ | ScalarInt128 | ScalarUInt128 | ScalarEnum _ | ScalarRange
    ->
      None

let primitive_stack_abi_of_layout = function
  | StackScalar scalar -> primitive_stack_abi_of_scalar scalar
  | StackValueRecord _ | NullableManagedPointer | BoxedUnion _ -> None

let primitive_stack_abi_info abi =
  let c_type, runtime_suffix, payload_c_type =
    match abi with
    | StackOptionVoid -> ("blorp_StackOption_Void", "void", "long")
    | StackOptionInt -> ("blorp_StackOption_Int", "int", "long")
    | StackOptionInt8 -> ("blorp_StackOption_Int8", "int8", "int8_t")
    | StackOptionInt16 -> ("blorp_StackOption_Int16", "int16", "int16_t")
    | StackOptionInt32 -> ("blorp_StackOption_Int32", "int32", "int32_t")
    | StackOptionInt64 -> ("blorp_StackOption_Int64", "int64", "long")
    | StackOptionUInt8 -> ("blorp_StackOption_UInt8", "uint8", "uint8_t")
    | StackOptionUInt16 -> ("blorp_StackOption_UInt16", "uint16", "uint16_t")
    | StackOptionUInt32 -> ("blorp_StackOption_UInt32", "uint32", "uint32_t")
    | StackOptionUInt64 -> ("blorp_StackOption_UInt64", "uint64", "uint64_t")
    | StackOptionFloat -> ("blorp_StackOption_Float", "float", "double")
    | StackOptionBool -> ("blorp_StackOption_Bool", "bool", "long")
    | StackOptionChar -> ("blorp_StackOption_Char", "char", "int32_t")
    | StackOptionFloat32 -> ("blorp_StackOption_Float32", "f32", "float")
    | StackOptionFloat16 -> ("blorp_StackOption_Float16", "f16", "_Float16")
  in
  { c_type; runtime_suffix; payload_c_type }

let c_type_of_primitive_stack_abi abi = (primitive_stack_abi_info abi).c_type

let runtime_suffix_of_primitive_stack_abi abi =
  (primitive_stack_abi_info abi).runtime_suffix

let payload_c_type_of_primitive_stack_abi abi =
  (primitive_stack_abi_info abi).payload_c_type

let apply_alias_subst = Core_type_layout.apply_alias_subst

let rec expand_aliases (meta : Core_type_layout.metadata) seen ty =
  let ty = Core_type_layout.normalize_for_ownership ty in
  match ty with
  | Ast.TyNamed (name, args) -> (
      let args = List.map (expand_aliases meta seen) args in
      match meta.lookup_alias name with
      | Some (params, target) when not (List.mem name seen) ->
          if List.length params = List.length args then
            expand_aliases meta (name :: seen)
              (apply_alias_subst params args target)
          else Ast.TyNamed (name, args)
      | Some _ -> Ast.TyNamed (name, args)
      | None -> Ast.TyNamed (name, args))
  | Ast.TyArray (elem, dims) ->
      Ast.TyArray
        (expand_aliases meta seen elem, List.map (expand_aliases meta seen) dims)
  | Ast.TyTuple elems -> Ast.TyTuple (List.map (expand_aliases meta seen) elems)
  | Ast.TyFunc f ->
      Ast.TyFunc
        {
          f with
          params = List.map (expand_aliases meta seen) f.params;
          return = expand_aliases meta seen f.return;
        }
  | Ast.TyRange inner -> Ast.TyRange (expand_aliases meta seen inner)
  | Ast.TyDimOp (op, a, b) ->
      Ast.TyDimOp (op, expand_aliases meta seen a, expand_aliases meta seen b)
  | ty -> ty

let is_type_parameter = function
  | Ast.TyVar _ | Ast.TySelf -> true
  | Ast.TyNamed (name, []) when Types.is_type_param_name name -> true
  | _ -> false

let scalar_payload_of_type meta ty =
  match ty with
  | Ast.TyNamed ("Void", []) -> Some ScalarVoid
  | Ast.TyNamed ("Int", []) -> Some ScalarInt
  | Ast.TyNamed ("Int128", []) -> Some ScalarInt128
  | Ast.TyNamed ("UInt128", []) -> Some ScalarUInt128
  | Ast.TyNamed ("Float", []) -> Some ScalarFloat
  | Ast.TyNamed ("Float32", []) -> Some ScalarFloat32
  | Ast.TyNamed ("Float16", []) -> Some ScalarFloat16
  | Ast.TyNamed ("Bool", []) -> Some ScalarBool
  | Ast.TyNamed ("Char", []) -> Some ScalarChar
  | Ast.TyNamed (name, []) when List.mem name Types.all_int_type_names ->
      Some (ScalarSizedInt name)
  | Ast.TyNamed (name, _) when meta.Core_type_layout.is_enum_name name ->
      Some (ScalarEnum name)
  | Ast.TyRange _ -> Some ScalarRange
  | _ -> None

let string_of_type ty = Types.type_to_string ty

let classify_expanded_payload meta payload_ty =
  match scalar_payload_of_type meta payload_ty with
  | Some scalar -> Known (StackScalar scalar)
  | None -> (
      match payload_ty with
      | Ast.TyNamed ("Option", [ _ ]) -> Known (BoxedUnion NestedOptionPayload)
      | Ast.TyNamed ("Option", args) ->
          Invalid_option_type
            (Printf.sprintf "Option expects 1 argument, got %d"
               (List.length args))
      | ty when Core_type_layout.is_stack_result_type meta ty ->
          Known (BoxedUnion NestedResultPayload)
      | Ast.TyNamed ("Ptr", []) -> Known (BoxedUnion NullableUnsafePayload)
      | ty when is_type_parameter ty -> Known (BoxedUnion GenericPayload)
      | Ast.TyNamed (name, _)
        when meta.Core_type_layout.is_value_record_name name ->
          Known (StackValueRecord name)
      | ty -> (
          match Core_type_layout.classify meta ty with
          | Core_type_layout.Known layout -> (
              match layout.ownership with
              | Core_type_layout.Managed -> Known NullableManagedPointer
              | Core_type_layout.Unmanaged ->
                  Known (BoxedUnion (UnsupportedPayload (string_of_type ty))))
          | Core_type_layout.Unknown_named name -> Unknown_named name
          | Core_type_layout.Invalid_value_type msg -> Invalid_option_type msg))

let classify_payload meta payload_ty =
  classify_expanded_payload meta (expand_aliases meta [] payload_ty)

let classify (meta : Core_type_layout.metadata) (option_ty : Ast.type_expr) :
    classification =
  match expand_aliases meta [] option_ty with
  | Ast.TyNamed ("Option", [ payload_ty ]) ->
      classify_expanded_payload meta payload_ty
  | Ast.TyNamed ("Option", args) ->
      Invalid_option_type
        (Printf.sprintf "Option expects 1 argument, got %d" (List.length args))
  | ty ->
      Invalid_option_type
        (Printf.sprintf "expected Option[T], got %s" (string_of_type ty))

let nullable_managed_payload_type (meta : Core_type_layout.metadata)
    (option_ty : Ast.type_expr) : Ast.type_expr option =
  match expand_aliases meta [] option_ty with
  | Ast.TyNamed ("Option", [ payload_ty ]) -> (
      match classify_expanded_payload meta payload_ty with
      | Known NullableManagedPointer -> Some payload_ty
      | Known (StackScalar _ | StackValueRecord _ | BoxedUnion _)
      | Unknown_named _ | Invalid_option_type _ ->
          None)
  | _ -> None
