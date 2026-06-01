(** Late Core layout facts. *)

type source_rc = SourceNonRc | SourceManaged | SourceUnknown of string

type storage_release =
  | StorageNoRelease
  | StorageArcRelease
  | StorageReleaseUnknown of string

type storage_release_capability = StorageReleaseNotNeeded | StorageReleaseArc

type erased_storage =
  | ErasedFloat
  | ErasedFloat32
  | ErasedFloat16
  | ErasedInt128
  | ErasedUInt128
  | ErasedPointer
  | ErasedPrim
  | ErasedStruct of string

type storage = Erased of erased_storage
type source_value_ownership = SourceValueManaged | SourceValueUnmanaged

type source_value_release_path =
  | SourceValueNoRelease
  | SourceValueArcReleaseOnly
  | SourceValueArcReleaseWithDestructor

type source_value_layout = {
  sv_semantic : Ast.type_expr;
  sv_loc : Ast.loc;
  sv_ownership : source_value_ownership;
  sv_release_path : source_value_release_path;
}

type source_value_layout_classification =
  | SourceValueKnown of source_value_layout
  | SourceValueUnknownNamed of string
  | SourceValueInvalid of string

type tensor_raw_scalar_abi = {
  tras_c_type : string;
  tras_pointer_c_type : string;
  tras_storage_mode : string;
  tras_elem_size : string;
}

type tensor_runtime_read_helper = {
  trrh_value_ty : Ast.type_expr;
  trrh_c_helper : string;
}

type tensor_fast_numeric_access = {
  tfna_storage_pred_intr : string;
  tfna_raw_kind : Core.tensor_unboxed_scalar;
}

type tensor_numeric_access = {
  tna_value_ty : Ast.type_expr;
  tna_get_intrinsic : string;
  tna_fast_access : tensor_fast_numeric_access option;
}

type tensor_checked_get_access = {
  tcga_value_ty : Ast.type_expr;
  tcga_get_intrinsic : string;
}

type tensor_to_string_runtime =
  | TensorToStringFloat
  | TensorToStringFloat32
  | TensorToStringFloat16
  | TensorToStringBool
  | TensorToStringEnum of string
  | TensorToStringInt

type primitive_inline_width =
  | PrimitiveInlineBits of Core.inline_storage_width
  | PrimitiveNotInlineBits

type inline_struct_kind = InlineValueRecord | InlineStackOption

type inline_struct_storage =
  | InlineStruct of {
      inline_struct_kind : inline_struct_kind;
      inline_struct_c_type : string;
    }
  | NotInlineStruct

type value_record_layout = { vrl_name : string; vrl_c_type : string }
type stack_option_emit_abi = { soe_c_type : string; soe_none_value : string }

type option_constructor_abi =
  | OptionConstructorStackInline of stack_option_emit_abi
  | OptionConstructorNullableManaged
  | OptionConstructorBoxedUnion
  | OptionConstructorUnavailable of string

type option_erasure_layout =
  | OptionErasureStackValue
  | OptionErasureNullableManagedPointer
  | OptionErasureBoxedUnion of string
  | OptionErasureUnknownPayload of string
  | OptionErasureInvalid of string

type generated_stack_option_payload_storage =
  | GeneratedStackOptionInt128
  | GeneratedStackOptionUInt128
  | GeneratedStackOptionLong
  | GeneratedStackOptionValueRecord of string

type generated_stack_option_get_abi = {
  gsog_option_c_type : string;
  gsog_payload_c_type : string;
  gsog_none_value : string;
  gsog_payload_storage : generated_stack_option_payload_storage;
}

type option_payload_runtime_abi =
  | OptionPayloadPrimitiveStack of string
  | OptionPayloadNullableManaged
  | OptionPayloadBoxedUnion
  | OptionPayloadNoSpecialization

type option_equality_abi =
  | OptionEqualityStackInline of { oeq_option_c_type : string }
  | OptionEqualityNullableString
  | OptionEqualityBoxedUnionRuntime of string
  | OptionEqualityUnavailable of string

type stack_result_constructor_abi = { src_result_c_type : string }

type list_element_storage =
  | ListElementInlineBits of Core.inline_storage_width
  | ListElementInlineStruct of string
  | ListElementPointer

type list_type = { list_elem_ty : Ast.type_expr }
type set_type = { set_elem_ty : Ast.type_expr }
type dict_type = { dict_key_ty : Ast.type_expr; dict_value_ty : Ast.type_expr }

type tensor_element_storage =
  | TensorElementRawScalar of Core.tensor_unboxed_scalar
  | TensorElementPackedBits of Core.inline_storage_width
  | TensorElementInlineStruct of string
  | TensorElementBoxed

type boxed_storage_scalar_kind =
  | BoxedStorageInlineScalar
  | BoxedStorageArcBoxedScalar
  | BoxedStorageNonScalar

type pointer_argument_layout =
  | PointerArgumentIdentity
  | PointerArgumentBox
  | PointerArgumentCast

type hash_probe_layout = HashProbeImmediate | HashProbeDispatched

type enum_inline_width =
  | EnumInlineBits of Core.inline_storage_width
  | NotInlineEnum

type t = {
  semantic : Ast.type_expr;
  loc : Ast.loc;
  storage : storage;
  source_rc : source_rc;
}

let inline_width_for_enum_info (info : Codegen_types.enum_info) =
  if info.enum_max_tag <= 0xFF then Core.InlineBytes1
  else if info.enum_max_tag <= 0xFFFF then Core.InlineBytes2
  else if Int64.of_int info.enum_max_tag <= 0xFFFF_FFFFL then Core.InlineBytes4
  else Core.InlineBytes8

let canonical_type ?reg ty =
  let expanded =
    match reg with Some reg -> Codegen_types.expand_alias ~reg ty | None -> ty
  in
  Codegen_types.normalize_type expanded

let c_type ~reg ty = Codegen_types.type_to_c ~reg (canonical_type ~reg ty)
let is_pointer_type ~reg ty = Codegen_types.is_pointer_type ~reg ty

let record_field_uses_erased_storage ~reg ty =
  Codegen_types.has_type_vars ty && c_type ~reg ty = "void*"

let registry_or_empty = function
  | Some reg -> reg
  | None -> Codegen_types.create_registry ()

let source_value_ownership_of_layout
    (layout : Core_type_layout.ownership_layout) =
  match layout.ownership with
  | Core_type_layout.Managed -> SourceValueManaged
  | Core_type_layout.Unmanaged -> SourceValueUnmanaged

let conservative_release_path_of_ownership = function
  | Core_type_layout.Managed -> SourceValueArcReleaseWithDestructor
  | Core_type_layout.Unmanaged -> SourceValueNoRelease

let source_value_layout_of_ownership_layout ?release_path loc ty
    (layout : Core_type_layout.ownership_layout) =
  let release_path =
    match release_path with
    | Some path -> path
    | None -> conservative_release_path_of_ownership layout.ownership
  in
  {
    sv_semantic = Codegen_types.normalize_type ty;
    sv_loc = loc;
    sv_ownership = source_value_ownership_of_layout layout;
    sv_release_path = release_path;
  }

let classify_source_value_layout_of_metadata ?(loc = Ast.dummy_loc)
    (meta : Core_type_layout.metadata) (ty : Ast.type_expr) :
    source_value_layout_classification =
  match Core_type_layout.classify meta ty with
  | Core_type_layout.Known layout ->
      SourceValueKnown (source_value_layout_of_ownership_layout loc ty layout)
  | Core_type_layout.Unknown_named name -> SourceValueUnknownNamed name
  | Core_type_layout.Invalid_value_type msg -> SourceValueInvalid msg

let runtime_builtin_arc_release_only = function
  | "String" | "Bytes" | "Fixed" | "MemStats" | "SchedulerStats"
  | "ConcurrencyError" ->
      true
  | name when Type_name_metadata.is_resource_source_name name -> true
  | _ -> false

let source_release_path_of_named_type ~reg name =
  match Codegen_types.managed_type_info reg name with
  | Some { destructor = Codegen_types.ArcReleaseOnly; _ } ->
      SourceValueArcReleaseOnly
  | Some
      {
        destructor =
          ( Codegen_types.GeneratedDestructor _
          | Codegen_types.RuntimeDestructor _ );
        _;
      } ->
      SourceValueArcReleaseWithDestructor
  | None when runtime_builtin_arc_release_only name -> SourceValueArcReleaseOnly
  | None -> SourceValueArcReleaseWithDestructor

let source_release_path_of_type ~reg ty
    (layout : Core_type_layout.ownership_layout) =
  match layout.ownership with
  | Core_type_layout.Unmanaged -> SourceValueNoRelease
  | Core_type_layout.Managed -> (
      match canonical_type ~reg ty with
      | Ast.TyNamed (name, _) -> source_release_path_of_named_type ~reg name
      | _ -> SourceValueArcReleaseWithDestructor)

let classify_source_value_layout_of_type ~(reg : Codegen_types.registry) ty loc
    =
  let meta = Core_type_layout.metadata_for_registry reg in
  match Core_type_layout.classify meta ty with
  | Core_type_layout.Known layout ->
      SourceValueKnown
        (source_value_layout_of_ownership_layout loc ty layout
           ~release_path:(source_release_path_of_type ~reg ty layout))
  | Core_type_layout.Unknown_named name -> SourceValueUnknownNamed name
  | Core_type_layout.Invalid_value_type msg -> SourceValueInvalid msg

let source_value_layout_of_metadata
    ?(phase = Core_error.Other "layout_type_source_value")
    ?(loc = Ast.dummy_loc) (meta : Core_type_layout.metadata)
    (ty : Ast.type_expr) : source_value_layout =
  let layout = Core_type_layout.layout_or_error ~phase ~loc meta ty in
  source_value_layout_of_ownership_layout loc ty layout

let source_value_layout_of_type
    ?(phase = Core_error.Other "layout_type_source_value")
    ~(reg : Codegen_types.registry) ty loc =
  match classify_source_value_layout_of_type ~reg ty loc with
  | SourceValueKnown layout -> layout
  | SourceValueUnknownNamed name ->
      Core_error.errorf phase loc
        ~hint:
          "register the type as a record, value struct, enum, union, builtin \
           runtime type, or explicit unmanaged FFI type before ownership \
           analysis"
        "ownership classifier has no layout for type %s" name
  | SourceValueInvalid msg ->
      Core_error.errorf phase loc
        ~hint:"only runtime value types may participate in ownership analysis"
        "%s" msg

let source_value_requires_release layout =
  match layout.sv_release_path with
  | SourceValueArcReleaseOnly | SourceValueArcReleaseWithDestructor -> true
  | SourceValueNoRelease -> false

let source_value_requires_retain layout =
  match layout.sv_ownership with
  | SourceValueManaged -> true
  | SourceValueUnmanaged -> false

let source_value_release_path layout = layout.sv_release_path

let source_value_requires_release_or_error ?phase ~reg ty loc =
  source_value_layout_of_type ?phase ~reg ty loc
  |> source_value_requires_release

let source_value_requires_retain_or_error ?phase ~reg ty loc =
  source_value_layout_of_type ?phase ~reg ty loc |> source_value_requires_retain

let boxed_storage_scalar_kind ?reg ty =
  let ty = canonical_type ?reg ty in
  if Core_type_layout.is_arc_boxed_storage_value_type ty then
    BoxedStorageArcBoxedScalar
  else if Core_type_layout.is_boxed_storage_release_free_value_type ty then
    BoxedStorageInlineScalar
  else BoxedStorageNonScalar

let inline_struct_storage ?reg ty =
  let reg = registry_or_empty reg in
  let ty = canonical_type ~reg ty in
  match Codegen_types.inline_value_record_c_type ~reg ty with
  | Some c_ty ->
      InlineStruct
        { inline_struct_kind = InlineValueRecord; inline_struct_c_type = c_ty }
  | None -> (
      match Codegen_types.stack_option_c_type ~reg ty with
      | Some c_ty ->
          InlineStruct
            {
              inline_struct_kind = InlineStackOption;
              inline_struct_c_type = c_ty;
            }
      | None -> NotInlineStruct)

let value_record_layout_of_type ?reg ty =
  let reg = registry_or_empty reg in
  match canonical_type ~reg ty with
  | Ast.TyNamed (name, []) when Hashtbl.mem reg.value_records name ->
      Some
        {
          vrl_name = name;
          vrl_c_type = Codegen_types.type_to_c ~reg (Ast.TyNamed (name, []));
        }
  | _ -> None

let value_record_c_type ?reg ty =
  Option.map
    (fun (layout : value_record_layout) -> layout.vrl_c_type)
    (value_record_layout_of_type ?reg ty)

let enum_inline_width ?reg ty =
  match reg with
  | None -> NotInlineEnum
  | Some reg -> (
      match canonical_type ~reg ty with
      | Ast.TyNamed (name, _) -> (
          match Codegen_types.enum_info reg name with
          | Some info -> EnumInlineBits (inline_width_for_enum_info info)
          | None -> NotInlineEnum)
      | _ -> NotInlineEnum)

let scalar_or_enum_requires_pointer_box ?reg ty =
  match boxed_storage_scalar_kind ?reg ty with
  | BoxedStorageInlineScalar | BoxedStorageArcBoxedScalar -> true
  | BoxedStorageNonScalar -> (
      match enum_inline_width ?reg ty with
      | EnumInlineBits _ -> true
      | NotInlineEnum -> false)

let hash_key_pointer_argument ?reg ty =
  match canonical_type ?reg ty with
  | Ast.TyNamed (("Ptr" | "Void"), _) -> PointerArgumentIdentity
  | Ast.TyVar _ | Ast.TySelf -> PointerArgumentBox
  | ty when scalar_or_enum_requires_pointer_box ?reg ty -> PointerArgumentBox
  | _ -> PointerArgumentCast

let boxed_storage_value_pointer_argument ?reg ty =
  match canonical_type ?reg ty with
  | Ast.TyNamed (("Ptr" | "Void"), _) -> PointerArgumentIdentity
  | Ast.TyVar _ | Ast.TySelf -> PointerArgumentBox
  | ty when scalar_or_enum_requires_pointer_box ?reg ty -> PointerArgumentBox
  | ty -> (
      match inline_struct_storage ?reg ty with
      | InlineStruct { inline_struct_kind = InlineValueRecord; _ } ->
          PointerArgumentBox
      | InlineStruct { inline_struct_kind = InlineStackOption; _ }
      | NotInlineStruct ->
          PointerArgumentCast)

let hash_probe_layout ?reg ty =
  match canonical_type ?reg ty with
  | Ast.TyNamed (("Int128" | "UInt128"), []) -> HashProbeDispatched
  | Ast.TyNamed (("Int" | "Bool" | "Char"), []) -> HashProbeImmediate
  | Ast.TyRange _ -> HashProbeImmediate
  | ty when Types.is_any_integer_type ty -> HashProbeImmediate
  | ty -> (
      match enum_inline_width ?reg ty with
      | EnumInlineBits _ -> HashProbeImmediate
      | NotInlineEnum -> HashProbeDispatched)

let primitive_inline_width ty =
  match Codegen_types.normalize_type ty with
  | Ast.TyNamed ("Bool", []) -> PrimitiveInlineBits Core.InlineBytes1
  | Ast.TyNamed ("Char", []) -> PrimitiveInlineBits Core.InlineBytes4
  | Ast.TyNamed ("Int8", []) | Ast.TyNamed ("UInt8", []) ->
      PrimitiveInlineBits Core.InlineBytes1
  | Ast.TyNamed ("Int16", []) | Ast.TyNamed ("UInt16", []) ->
      PrimitiveInlineBits Core.InlineBytes2
  | Ast.TyNamed ("Int32", [])
  | Ast.TyNamed ("UInt32", [])
  | Ast.TyNamed ("Float32", []) ->
      PrimitiveInlineBits Core.InlineBytes4
  | Ast.TyNamed ("Int", [])
  | Ast.TyNamed ("Int64", [])
  | Ast.TyNamed ("UInt64", [])
  | Ast.TyNamed ("Float", []) ->
      PrimitiveInlineBits Core.InlineBytes8
  | Ast.TyNamed ("Float16", []) -> PrimitiveInlineBits Core.InlineBytes2
  | Ast.TyRange _ -> PrimitiveInlineBits Core.InlineBytes8
  | ty when Types.Dim.is_value_dim ty -> PrimitiveInlineBits Core.InlineBytes8
  | _ -> PrimitiveNotInlineBits

let list_element_storage ?reg elem_ty =
  let elem_ty = canonical_type ?reg elem_ty in
  match primitive_inline_width elem_ty with
  | PrimitiveInlineBits width -> ListElementInlineBits width
  | PrimitiveNotInlineBits -> (
      match elem_ty with
      | Ast.TyNamed (_, _) -> (
          match enum_inline_width ?reg elem_ty with
          | EnumInlineBits width -> ListElementInlineBits width
          | NotInlineEnum -> (
              match inline_struct_storage ?reg elem_ty with
              | InlineStruct { inline_struct_c_type; _ } ->
                  ListElementInlineStruct inline_struct_c_type
              | NotInlineStruct -> ListElementPointer))
      | _ -> ListElementPointer)

let list_type ?reg ty =
  match canonical_type ?reg ty with
  | Ast.TyNamed ("List", [ elem ]) -> Some { list_elem_ty = elem }
  | _ -> None

let set_type ?reg ty =
  match canonical_type ?reg ty with
  | Ast.TyNamed ("Set", [ elem ]) -> Some { set_elem_ty = elem }
  | _ -> None

let dict_type ?reg ty =
  match canonical_type ?reg ty with
  | Ast.TyNamed ("Dict", [ key; value ]) ->
      Some { dict_key_ty = key; dict_value_ty = value }
  | _ -> None

let tensor_element_storage ?reg elem_ty =
  let elem_ty = canonical_type ?reg elem_ty in
  match inline_struct_storage ?reg elem_ty with
  | InlineStruct
      { inline_struct_kind = InlineValueRecord; inline_struct_c_type = c_ty } ->
      TensorElementInlineStruct c_ty
  | InlineStruct { inline_struct_kind = InlineStackOption; _ } | NotInlineStruct
    -> (
      match Core.tensor_unboxed_scalar_of_type elem_ty with
      | Some scalar -> TensorElementRawScalar scalar
      | None -> (
          match elem_ty with
          | Ast.TyNamed ("Bool", []) ->
              TensorElementPackedBits Core.InlineBytes1
          | Ast.TyNamed (_, _) -> (
              match enum_inline_width ?reg elem_ty with
              | EnumInlineBits width -> TensorElementPackedBits width
              | NotInlineEnum -> TensorElementBoxed)
          | _ -> TensorElementBoxed))

let tensor_raw_scalar_abi = function
  | Core.TensorFloat64Elements ->
      {
        tras_c_type = "double";
        tras_pointer_c_type = "double*";
        tras_storage_mode = "BLORP_VECTOR_STORAGE_F64";
        tras_elem_size = "sizeof(double)";
      }
  | Core.TensorFloat32Elements ->
      {
        tras_c_type = "float";
        tras_pointer_c_type = "float*";
        tras_storage_mode = "BLORP_VECTOR_STORAGE_F32";
        tras_elem_size = "sizeof(float)";
      }
  | Core.TensorInt64Elements ->
      {
        tras_c_type = "long";
        tras_pointer_c_type = "long*";
        tras_storage_mode = "BLORP_VECTOR_STORAGE_I64";
        tras_elem_size = "sizeof(long)";
      }

let tensor_raw_scalar_kind_of_type ~reg ty =
  match canonical_type ~reg ty with
  | Ast.TyNamed ("Float", []) -> Some Core.TensorFloat64Elements
  | Ast.TyNamed ("Float32", []) -> Some Core.TensorFloat32Elements
  | Ast.TyNamed (("Int" | "Bool" | "Char"), []) | Ast.TyRange _ ->
      Some Core.TensorInt64Elements
  | _ -> None

let tensor_raw_scalar_accepts_type ~reg kind ty =
  match tensor_raw_scalar_kind_of_type ~reg ty with
  | Some actual -> actual = kind
  | None -> false

let tensor_runtime_read_helper_of_type ~reg ty =
  let ty = canonical_type ~reg ty in
  let helper =
    match ty with
    | Ast.TyNamed ("Float", []) -> Some "blorp_vector_read_f64"
    | Ast.TyNamed ("Float32", []) -> Some "blorp_vector_read_f32"
    | Ast.TyNamed ("Float16", []) -> Some "blorp_vector_read_f16"
    | Ast.TyNamed (("Int" | "Bool" | "Char"), []) | Ast.TyRange _ ->
        Some "blorp_vector_read_i64"
    | ty when Types.Dim.is_value_dim ty -> Some "blorp_vector_read_i64"
    | ty when Types.is_any_integer_type ty -> Some "blorp_vector_read_i64"
    | Ast.TyNamed (name, _) -> (
        match Codegen_types.enum_info reg name with
        | Some _ -> Some "blorp_vector_read_i64"
        | None -> None)
    | _ -> None
  in
  Option.map (fun trrh_c_helper -> { trrh_value_ty = ty; trrh_c_helper }) helper

let tensor_numeric_access_of_type ~reg ty =
  let ty = canonical_type ~reg ty in
  match ty with
  | Ast.TyNamed ("Float", []) ->
      Some
        {
          tna_value_ty = ty;
          tna_get_intrinsic = "tensor_get_f64";
          tna_fast_access =
            Some
              {
                tfna_storage_pred_intr = "tensor_is_f64_storage";
                tfna_raw_kind = Core.TensorFloat64Elements;
              };
        }
  | Ast.TyNamed ("Float32", []) ->
      Some
        {
          tna_value_ty = ty;
          tna_get_intrinsic = "tensor_get_f32";
          tna_fast_access =
            Some
              {
                tfna_storage_pred_intr = "tensor_is_f32_storage";
                tfna_raw_kind = Core.TensorFloat32Elements;
              };
        }
  | Ast.TyNamed ("Float16", []) ->
      Some
        {
          tna_value_ty = ty;
          tna_get_intrinsic = "tensor_get_f16";
          tna_fast_access = None;
        }
  | Ast.TyNamed ("Int", []) ->
      Some
        {
          tna_value_ty = ty;
          tna_get_intrinsic = "tensor_get_i64";
          tna_fast_access =
            Some
              {
                tfna_storage_pred_intr = "tensor_is_i64_storage";
                tfna_raw_kind = Core.TensorInt64Elements;
              };
        }
  | _ -> None

let tensor_checked_get_access_of_type ~reg ty =
  let ty = canonical_type ~reg ty in
  let get_intrinsic =
    match tensor_raw_scalar_kind_of_type ~reg ty with
    | Some Core.TensorFloat64Elements -> Some "tensor_get_f64"
    | Some Core.TensorFloat32Elements -> Some "tensor_get_f32"
    | Some Core.TensorInt64Elements -> Some "tensor_get_i64"
    | None -> (
        match ty with
        | Ast.TyNamed ("Float16", []) -> Some "tensor_get_f16"
        | _ -> (
            match enum_inline_width ~reg ty with
            | EnumInlineBits _ -> Some "tensor_get_i64"
            | NotInlineEnum -> None))
  in
  Option.map
    (fun tcga_get_intrinsic -> { tcga_value_ty = ty; tcga_get_intrinsic })
    get_intrinsic

let tensor_to_string_runtime_of_elem_type ~reg elem_ty =
  match canonical_type ~reg elem_ty with
  | Ast.TyNamed ("Float32", _) -> TensorToStringFloat32
  | Ast.TyNamed ("Float16", _) -> TensorToStringFloat16
  | Ast.TyNamed ("Float", _) -> TensorToStringFloat
  | Ast.TyNamed ("Bool", _) -> TensorToStringBool
  | Ast.TyNamed (name, _) when Hashtbl.mem reg.Codegen_types.enum_types name ->
      TensorToStringEnum name
  | _ -> TensorToStringInt

let tensor_raw_scalar_abi_of_layout (layout : Core.tensor_storage_layout) =
  match layout.tsl_slots with
  | Core.TensorRawScalarStorage kind -> Some (tensor_raw_scalar_abi kind)
  | _ -> None

let source_rc_of_layout = function
  | Core_type_layout.Managed -> SourceManaged
  | Core_type_layout.Unmanaged -> SourceNonRc

let source_rc_for_type ~reg ty =
  let meta = Core_type_layout.metadata_for_registry reg in
  match Core_type_layout.classify meta ty with
  | Core_type_layout.Known layout -> source_rc_of_layout layout.ownership
  | Core_type_layout.Unknown_named name -> SourceUnknown name
  | Core_type_layout.Invalid_value_type msg -> SourceUnknown msg

let storage_release_for_erased_storage ~source_rc = function
  | ErasedFloat | ErasedFloat32 | ErasedFloat16 | ErasedPrim -> StorageNoRelease
  | ErasedInt128 | ErasedUInt128 | ErasedStruct _ -> StorageArcRelease
  | ErasedPointer -> (
      match source_rc with
      | SourceManaged -> StorageArcRelease
      | SourceNonRc -> StorageNoRelease
      | SourceUnknown msg -> StorageReleaseUnknown msg)

let storage_type ~reg ty = canonical_type ~reg ty

let erased_storage ?(phase = Core_error.Other "layout_type")
    ~(reg : Codegen_types.registry) ty loc : erased_storage =
  let nty = storage_type ~reg ty in
  match Codegen_types.stack_option_c_type ~reg nty with
  | Some c_ty -> ErasedStruct c_ty
  | None -> (
      match Codegen_types.stack_result_c_type ~reg nty with
      | Some c_ty -> ErasedStruct c_ty
      | None -> (
          match nty with
          | Ast.TyNamed ("Float", []) -> ErasedFloat
          | Ast.TyNamed ("Float32", []) -> ErasedFloat32
          | Ast.TyNamed ("Float16", []) -> ErasedFloat16
          | Ast.TyNamed ("Int128", []) -> ErasedInt128
          | Ast.TyNamed ("UInt128", []) -> ErasedUInt128
          | Ast.TyNamed ("Int", [])
          | Ast.TyNamed ("Bool", [])
          | Ast.TyNamed ("Char", [])
          | Ast.TyRange _ ->
              ErasedPrim
          | ty when Types.Dim.is_value_dim ty -> ErasedPrim
          | ty when Types.is_any_integer_type ty -> ErasedPrim
          | Ast.TyNamed (name, _) when Codegen_types.is_enum_type reg name ->
              ErasedPrim
          | Ast.TyVarDims _ ->
              Core_error.errorf phase loc
                ~hint:
                  "variadic dimension packs are type-level only; they must be \
                   resolved to a concrete runtime scalar before codegen"
                "cannot classify variadic dimension pack for erased storage"
          | Ast.TyNamed (name, _)
            when Hashtbl.mem reg.Codegen_types.value_records name ->
              ErasedStruct name
          | ty when Codegen_types.is_pointer_type ~reg ty -> ErasedPointer
          | _ -> ErasedPointer))

let classify_erased_storage
    ?(phase = Core_error.Other "layout_type_erased_storage")
    ~(reg : Codegen_types.registry) ty loc : t =
  let semantic = Codegen_types.normalize_type ty in
  let storage = erased_storage ~phase ~reg semantic loc in
  let source_rc = source_rc_for_type ~reg semantic in
  { semantic; loc; storage = Erased storage; source_rc }

let storage_release layout =
  match layout.storage with
  | Erased storage ->
      storage_release_for_erased_storage ~source_rc:layout.source_rc storage

let storage_release_or_error ?(phase = Core_error.Other "layout_type") layout =
  match storage_release layout with
  | StorageNoRelease -> StorageReleaseNotNeeded
  | StorageArcRelease -> StorageReleaseArc
  | StorageReleaseUnknown reason ->
      Core_error.errorf phase layout.loc
        ~hint:
          "register the type before it crosses erased storage, or reject it \
           before Core layout classification"
        "unknown erased-storage release policy: %s" reason

let storage_requires_release_or_error ?phase layout =
  match storage_release_or_error ?phase layout with
  | StorageReleaseNotNeeded -> false
  | StorageReleaseArc -> true

let boxed_storage_requires_release_or_error
    ?(phase = Core_error.Other "layout_type_erased_storage") ~reg ty loc =
  classify_erased_storage ~phase ~reg ty loc
  |> storage_requires_release_or_error ~phase

let generated_destructor_name name = name ^ "_destroy"

let record_destructor_policy ?(phase = Core_error.Other "layout_type") ~reg r =
  let needs_destructor =
    List.exists
      (fun (fd : Ast.field_decl) ->
        source_value_requires_release_or_error ~phase ~reg fd.field_type
          fd.field_loc)
      r.Ast.record_fields
  in
  if needs_destructor then
    Codegen_types.GeneratedDestructor (generated_destructor_name r.record_name)
  else Codegen_types.ArcReleaseOnly

let union_destructor_policy ?(phase = Core_error.Other "layout_type") ~reg t =
  let needs_destructor =
    List.exists
      (fun (v : Ast.variant) ->
        List.exists
          (fun field_ty ->
            boxed_storage_requires_release_or_error ~phase ~reg field_ty
              v.variant_loc)
          v.variant_fields)
      t.Ast.type_variants
  in
  if needs_destructor then
    Codegen_types.GeneratedDestructor (generated_destructor_name t.type_name)
  else Codegen_types.ArcReleaseOnly

let source_pointer_storage_policy_or_error
    ?(phase = Core_error.Other "layout_type") layout =
  match layout.source_rc with
  | SourceManaged -> Core.StoragePolicyManagedPointer
  | SourceNonRc -> Core.StoragePolicyUnmanagedBits
  | SourceUnknown reason ->
      Core_error.errorf phase layout.loc
        ~hint:
          "register the type before it is used as pointer-backed container \
           storage"
        "unknown source pointer storage policy: %s" reason

let erased_box_storage_policy_or_error ?(phase = Core_error.Other "layout_type")
    layout =
  match storage_release_or_error ~phase layout with
  | StorageReleaseNotNeeded -> Core.StoragePolicyUnmanagedBits
  | StorageReleaseArc -> Core.StoragePolicyOwnedErasedBox

let container_storage_policy_for_ownership_or_error ~phase layout ownership =
  match ownership with
  | Core_type_layout.Managed ->
      source_pointer_storage_policy_or_error ~phase layout
  | Core_type_layout.Unmanaged ->
      erased_box_storage_policy_or_error ~phase layout

let list_inline_descriptor elem_ty width =
  Core.list_storage_layout ~elem_ty
    ~value_layout:(Core.ListElementInlineBits width)
    ~policy:Core.StoragePolicyUnmanagedBits (Core.ListInlineStorage width)

let list_inline_struct_descriptor elem_ty c_ty =
  Core.list_storage_layout ~elem_ty
    ~value_layout:(Core.ListElementStackStruct c_ty)
    ~policy:Core.StoragePolicyUnmanagedBits (Core.ListInlineStructStorage c_ty)

let list_pointer_descriptor ~elem_ty ~value_layout ~policy =
  Core.list_pointer_storage ~elem_ty ~value_layout ~policy ()

let list_pointer_descriptor_for_elem ?reg elem_ty loc =
  let reg = registry_or_empty reg in
  let meta = Core_type_layout.metadata_for_registry reg in
  let phase = Core_error.Other "list_layout" in
  match Core_type_layout.classify meta elem_ty with
  | Core_type_layout.Known layout ->
      let late_layout = classify_erased_storage ~phase ~reg elem_ty loc in
      let value_layout =
        match layout.ownership with
        | Core_type_layout.Managed -> Core.ListElementPointer
        | Core_type_layout.Unmanaged -> Core.ListElementBoxedValue
      in
      let policy =
        container_storage_policy_for_ownership_or_error ~phase late_layout
          layout.ownership
      in
      list_pointer_descriptor ~elem_ty ~value_layout ~policy
  | Core_type_layout.Unknown_named name ->
      list_pointer_descriptor ~elem_ty
        ~value_layout:(Core.ListElementUnknownValue name)
        ~policy:(Core.StoragePolicyUnknown ("unknown type " ^ name))
  | Core_type_layout.Invalid_value_type msg ->
      list_pointer_descriptor ~elem_ty
        ~value_layout:(Core.ListElementUnknownValue msg)
        ~policy:(Core.StoragePolicyUnknown msg)

let list_storage_layout_of_elem ?reg elem_ty loc =
  let elem_ty = canonical_type ?reg elem_ty in
  match list_element_storage ?reg elem_ty with
  | ListElementInlineBits width -> list_inline_descriptor elem_ty width
  | ListElementInlineStruct c_ty -> list_inline_struct_descriptor elem_ty c_ty
  | ListElementPointer -> list_pointer_descriptor_for_elem ?reg elem_ty loc

let list_storage_layout_of_type ?reg list_ty loc =
  match canonical_type ?reg list_ty with
  | Ast.TyNamed (("List" | "ParallelList"), [ elem_ty ]) ->
      list_storage_layout_of_elem ?reg elem_ty loc
  | _ -> Core.list_pointer_storage ()

let tensor_descriptor ~elem_ty ~slots ~value_layout ~policy =
  Core.tensor_storage_layout ~elem_ty ~value_layout ~policy slots

let boxed_tensor_descriptor_for_elem ?reg elem_ty loc =
  let reg = registry_or_empty reg in
  let meta = Core_type_layout.metadata_for_registry reg in
  let phase = Core_error.Other "tensor_layout" in
  match Core_type_layout.classify meta elem_ty with
  | Core_type_layout.Known layout ->
      let late_layout = classify_erased_storage ~phase ~reg elem_ty loc in
      let value_layout =
        match layout.ownership with
        | Core_type_layout.Managed -> Core.TensorValueBoxedPointer
        | Core_type_layout.Unmanaged -> Core.TensorValueBoxedValue
      in
      let policy =
        container_storage_policy_for_ownership_or_error ~phase late_layout
          layout.ownership
      in
      tensor_descriptor ~elem_ty ~slots:Core.TensorBoxedStorage ~value_layout
        ~policy
  | Core_type_layout.Unknown_named name ->
      tensor_descriptor ~elem_ty ~slots:Core.TensorBoxedStorage
        ~value_layout:(Core.TensorValueUnknown name)
        ~policy:(Core.StoragePolicyUnknown ("unknown type " ^ name))
  | Core_type_layout.Invalid_value_type msg ->
      tensor_descriptor ~elem_ty ~slots:Core.TensorBoxedStorage
        ~value_layout:(Core.TensorValueUnknown msg)
        ~policy:(Core.StoragePolicyUnknown msg)

let tensor_storage_layout_of_elem ?reg elem_ty loc =
  let elem_ty = canonical_type ?reg elem_ty in
  match tensor_element_storage ?reg elem_ty with
  | TensorElementRawScalar scalar ->
      Core.tensor_raw_scalar_storage ~elem_ty scalar
  | TensorElementPackedBits width -> Core.tensor_packed_storage ~elem_ty width
  | TensorElementInlineStruct c_ty ->
      Core.tensor_inline_struct_storage ~elem_ty c_ty
  | TensorElementBoxed -> boxed_tensor_descriptor_for_elem ?reg elem_ty loc

let tensor_storage_layout_of_type ?reg tensor_ty loc =
  let effective_reg = registry_or_empty reg in
  match Core_tensor_type.of_type ~reg:effective_reg tensor_ty with
  | Some tensor_ty ->
      tensor_storage_layout_of_elem ~reg:effective_reg tensor_ty.elem_ty loc
  | None -> boxed_tensor_descriptor_for_elem ~reg:effective_reg tensor_ty loc

let option_layout_or_error ?(phase = Core_error.Other "layout_type_option") ~reg
    ty loc =
  match
    Core_option_layout.classify (Core_type_layout.metadata_for_registry reg) ty
  with
  | Core_option_layout.Known layout -> layout
  | Core_option_layout.Unknown_named name ->
      Core_error.errorf phase loc
        ~hint:
          "register the payload type before final Core preparation so Option \
           layout is explicit"
        "cannot choose Option representation for unknown payload type `%s`" name
  | Core_option_layout.Invalid_option_type msg ->
      Core_error.errorf phase loc
        ~hint:"Option constructors must have a fully resolved Option[T] result"
        "%s" msg

let classify_option_layout ~reg ty =
  Core_option_layout.classify (Core_type_layout.metadata_for_registry reg) ty

let describe_option_boxed_reason = function
  | Core_option_layout.GenericPayload -> "generic Option payload"
  | Core_option_layout.NullableUnsafePayload ->
      "nullable unsafe pointer payload"
  | Core_option_layout.NestedOptionPayload -> "nested Option payload"
  | Core_option_layout.NestedResultPayload -> "nested Result payload"
  | Core_option_layout.UnsupportedPayload ty ->
      "unsupported Option payload " ^ ty

let option_erasure_layout_of_type ~reg ty =
  match classify_option_layout ~reg ty with
  | Core_option_layout.Known
      (Core_option_layout.StackScalar _ | Core_option_layout.StackValueRecord _)
    ->
      OptionErasureStackValue
  | Core_option_layout.Known Core_option_layout.NullableManagedPointer ->
      OptionErasureNullableManagedPointer
  | Core_option_layout.Known (Core_option_layout.BoxedUnion reason) ->
      OptionErasureBoxedUnion (describe_option_boxed_reason reason)
  | Core_option_layout.Unknown_named name -> OptionErasureUnknownPayload name
  | Core_option_layout.Invalid_option_type msg -> OptionErasureInvalid msg

let nullable_managed_option_payload_type ~reg ty =
  Core_option_layout.nullable_managed_payload_type
    (Core_type_layout.metadata_for_registry reg)
    ty

let is_nullable_managed_option ~reg ty =
  nullable_managed_option_payload_type ~reg ty <> None

let primitive_stack_option_zero_literal = function
  | Core_option_layout.StackOptionVoid -> "0"
  | Core_option_layout.StackOptionInt -> "0L"
  | Core_option_layout.StackOptionInt8 | Core_option_layout.StackOptionInt16
  | Core_option_layout.StackOptionInt32 | Core_option_layout.StackOptionInt64
  | Core_option_layout.StackOptionUInt8 | Core_option_layout.StackOptionUInt16
  | Core_option_layout.StackOptionUInt32 | Core_option_layout.StackOptionUInt64
  | Core_option_layout.StackOptionFloat | Core_option_layout.StackOptionBool
  | Core_option_layout.StackOptionChar | Core_option_layout.StackOptionFloat32
  | Core_option_layout.StackOptionFloat16 ->
      "0"

let stack_option_emit_abi_of_layout = function
  | Core_option_layout.StackScalar scalar -> (
      match Core_option_layout.primitive_stack_abi_of_scalar scalar with
      | Some primitive ->
          Some
            {
              soe_c_type =
                Core_option_layout.c_type_of_primitive_stack_abi primitive;
              soe_none_value = primitive_stack_option_zero_literal primitive;
            }
      | None -> (
          match scalar with
          | Core_option_layout.ScalarInt128 ->
              Some
                {
                  soe_c_type = "blorp_StackOption_Int128";
                  soe_none_value = "0";
                }
          | Core_option_layout.ScalarUInt128 ->
              Some
                {
                  soe_c_type = "blorp_StackOption_UInt128";
                  soe_none_value = "0";
                }
          | Core_option_layout.ScalarRange ->
              Some
                { soe_c_type = "blorp_StackOption_Range"; soe_none_value = "0" }
          | Core_option_layout.ScalarEnum name ->
              Some
                {
                  soe_c_type =
                    Codegen_types.generated_stack_option_c_type_name name;
                  soe_none_value = "0";
                }
          | _ -> None))
  | Core_option_layout.StackValueRecord name ->
      Some
        {
          soe_c_type = Codegen_types.generated_stack_option_c_type_name name;
          soe_none_value = "{0}";
        }
  | Core_option_layout.NullableManagedPointer | Core_option_layout.BoxedUnion _
    ->
      None

let stack_option_scalar_payload_str = function
  | Core_option_layout.ScalarVoid -> "Void"
  | Core_option_layout.ScalarInt -> "Int"
  | Core_option_layout.ScalarSizedInt name -> name
  | Core_option_layout.ScalarInt128 -> "Int128"
  | Core_option_layout.ScalarUInt128 -> "UInt128"
  | Core_option_layout.ScalarFloat -> "Float"
  | Core_option_layout.ScalarFloat32 -> "Float32"
  | Core_option_layout.ScalarFloat16 -> "Float16"
  | Core_option_layout.ScalarBool -> "Bool"
  | Core_option_layout.ScalarChar -> "Char"
  | Core_option_layout.ScalarEnum name -> Printf.sprintf "enum %s" name
  | Core_option_layout.ScalarRange -> "Range"

let option_constructor_abi_of_layout layout =
  match stack_option_emit_abi_of_layout layout with
  | Some abi -> OptionConstructorStackInline abi
  | None -> (
      match layout with
      | Core_option_layout.NullableManagedPointer ->
          OptionConstructorNullableManaged
      | Core_option_layout.BoxedUnion _ -> OptionConstructorBoxedUnion
      | Core_option_layout.StackScalar scalar ->
          OptionConstructorUnavailable
            (Printf.sprintf
               "stack Option constructor ABI unavailable for scalar payload %s"
               (stack_option_scalar_payload_str scalar))
      | Core_option_layout.StackValueRecord name ->
          OptionConstructorUnavailable
            (Printf.sprintf
               "stack Option constructor ABI unavailable for value record %s"
               name))

let generated_stack_option_payload_type ~reg ty =
  match canonical_type ~reg ty with
  | Ast.TyNamed ("Option", [ payload_ty ]) -> Some payload_ty
  | _ -> None

let generated_stack_option_abi_from_layout ~reg ty layout =
  match stack_option_emit_abi_of_layout layout with
  | None -> None
  | Some abi -> (
      let make payload_c_type payload_storage =
        Some
          {
            gsog_option_c_type = abi.soe_c_type;
            gsog_payload_c_type = payload_c_type;
            gsog_none_value = abi.soe_none_value;
            gsog_payload_storage = payload_storage;
          }
      in
      match layout with
      | Core_option_layout.StackScalar Core_option_layout.ScalarInt128 ->
          make "__int128" GeneratedStackOptionInt128
      | Core_option_layout.StackScalar Core_option_layout.ScalarUInt128 ->
          make "unsigned __int128" GeneratedStackOptionUInt128
      | Core_option_layout.StackScalar Core_option_layout.ScalarRange
      | Core_option_layout.StackScalar (Core_option_layout.ScalarEnum _) ->
          make "long" GeneratedStackOptionLong
      | Core_option_layout.StackValueRecord _ -> (
          match generated_stack_option_payload_type ~reg ty with
          | Some payload_ty ->
              let payload_c_type = c_type ~reg payload_ty in
              make payload_c_type
                (GeneratedStackOptionValueRecord payload_c_type)
          | None -> None)
      | Core_option_layout.StackScalar _
      | Core_option_layout.NullableManagedPointer
      | Core_option_layout.BoxedUnion _ ->
          None)

let generated_stack_option_get_abi ~reg ty =
  match classify_option_layout ~reg ty with
  | Core_option_layout.Known layout ->
      generated_stack_option_abi_from_layout ~reg ty layout
  | Core_option_layout.Unknown_named _
  | Core_option_layout.Invalid_option_type _ ->
      None

let generated_stack_option_payload_from_erased abi raw =
  match abi.gsog_payload_storage with
  | GeneratedStackOptionInt128 -> Printf.sprintf "blorp_unbox_int128(%s)" raw
  | GeneratedStackOptionUInt128 -> Printf.sprintf "blorp_unbox_uint128(%s)" raw
  | GeneratedStackOptionLong -> Printf.sprintf "(long)%s" raw
  | GeneratedStackOptionValueRecord c_type ->
      Printf.sprintf "blorp_unbox_struct(%s, %s)" raw c_type

let option_payload_runtime_abi ~reg payload_ty =
  match
    Core_option_layout.classify
      (Core_type_layout.metadata_for_registry reg)
      (Ast.TyNamed ("Option", [ payload_ty ]))
  with
  | Core_option_layout.Known layout -> (
      match Core_option_layout.primitive_stack_abi_of_layout layout with
      | Some primitive ->
          OptionPayloadPrimitiveStack
            (Core_option_layout.runtime_suffix_of_primitive_stack_abi primitive)
      | None -> (
          match layout with
          | Core_option_layout.NullableManagedPointer ->
              OptionPayloadNullableManaged
          | Core_option_layout.BoxedUnion _ -> OptionPayloadBoxedUnion
          | Core_option_layout.StackScalar _
          | Core_option_layout.StackValueRecord _ ->
              OptionPayloadNoSpecialization))
  | Core_option_layout.Unknown_named _
  | Core_option_layout.Invalid_option_type _ ->
      OptionPayloadNoSpecialization

let option_type_runtime_abi ~reg ty =
  match canonical_type ~reg ty with
  | Ast.TyNamed ("Option", [ payload ]) ->
      Some (option_payload_runtime_abi ~reg payload)
  | _ -> None

let option_equality_abi ~reg ty =
  let ty = canonical_type ~reg ty in
  match ty with
  | Ast.TyNamed ("Option", [ payload_ty ]) -> (
      let payload_ty = canonical_type ~reg payload_ty in
      match classify_option_layout ~reg ty with
      | Core_option_layout.Known layout -> (
          match layout with
          | Core_option_layout.StackScalar _ -> (
              match stack_option_emit_abi_of_layout layout with
              | Some abi ->
                  OptionEqualityStackInline
                    { oeq_option_c_type = abi.soe_c_type }
              | None ->
                  OptionEqualityUnavailable
                    "stack Option equality has no concrete C ABI")
          | Core_option_layout.StackValueRecord _ ->
              OptionEqualityUnavailable
                "stack value-record Option equality needs payload trait \
                 dispatch"
          | Core_option_layout.NullableManagedPointer -> (
              match payload_ty with
              | Ast.TyNamed (("String" | "LiteralString"), _) ->
                  OptionEqualityNullableString
              | _ ->
                  OptionEqualityUnavailable
                    "nullable managed Option equality needs a payload-specific \
                     equality helper")
          | Core_option_layout.BoxedUnion _ ->
              let fn =
                match payload_ty with
                | Ast.TyNamed (("String" | "LiteralString"), _) ->
                    "blorp_option_eq_string"
                | Ast.TyNamed ("Float", _) -> "blorp_option_eq_float"
                | _ -> "blorp_option_eq"
              in
              OptionEqualityBoxedUnionRuntime fn)
      | Core_option_layout.Unknown_named name ->
          OptionEqualityUnavailable
            (Printf.sprintf "unknown Option payload type `%s`" name)
      | Core_option_layout.Invalid_option_type msg ->
          OptionEqualityUnavailable msg)
  | _ ->
      OptionEqualityUnavailable
        (Printf.sprintf "expected Option[T], got %s" (Types.type_to_string ty))

let stack_option_none_value_for_type ~reg ty =
  match Codegen_types.expand_alias ~reg ty with
  | Ast.TyNamed ("Option", [ Ast.TyNamed (name, []) ])
    when Hashtbl.mem reg.value_records name ->
      "{0}"
  | _ -> "0"

let stack_option_c_type ~reg ty = Codegen_types.stack_option_c_type ~reg ty
let stack_result_c_type ~reg ty = Codegen_types.stack_result_c_type ~reg ty
let is_stack_option_type ~reg ty = stack_option_c_type ~reg ty <> None
let is_stack_result_type ~reg ty = stack_result_c_type ~reg ty <> None

let stack_result_layout ~reg ty =
  Core_type_layout.stack_result_layout
    (Core_type_layout.metadata_for_registry reg)
    ty

let stack_result_constructor_abi_of_layout = function
  | Core_result_layout.StackErased | Core_result_layout.StackManaged ->
      { src_result_c_type = "blorp_StackResult" }

let box_kind layout =
  match Codegen_types.normalize_type layout.semantic with
  | Ast.TyNamed ("Void", []) -> Core.BoxVoid
  | _ -> (
      match layout.storage with
      | Erased ErasedFloat -> Core.BoxFloat
      | Erased ErasedFloat32 -> Core.BoxFloat32
      | Erased ErasedFloat16 -> Core.BoxFloat16
      | Erased ErasedInt128 -> Core.BoxInt128
      | Erased ErasedUInt128 -> Core.BoxUInt128
      | Erased ErasedPointer -> Core.BoxPointer
      | Erased ErasedPrim -> Core.BoxPrim
      | Erased (ErasedStruct c_ty) -> Core.BoxStruct c_ty)

let unbox_kind layout =
  match layout.storage with
  | Erased ErasedFloat -> Core.UnboxFloat
  | Erased ErasedFloat32 -> Core.UnboxFloat32
  | Erased ErasedFloat16 -> Core.UnboxFloat16
  | Erased ErasedInt128 -> Core.UnboxInt128
  | Erased ErasedUInt128 -> Core.UnboxUInt128
  | Erased ErasedPointer -> Core.UnboxPointer
  | Erased ErasedPrim -> Core.UnboxPrim
  | Erased (ErasedStruct c_ty) -> Core.UnboxStruct c_ty

let box_kind_of_type ?(phase = Core_error.Other "layout_type_box_kind") ~reg ty
    loc =
  classify_erased_storage ~phase ~reg ty loc |> box_kind

let unbox_kind_of_type ?(phase = Core_error.Other "layout_type_unbox_kind") ~reg
    ty loc =
  classify_erased_storage ~phase ~reg ty loc |> unbox_kind
