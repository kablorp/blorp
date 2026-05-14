(** Late Core layout facts.

    Semantic types should be preserved through frontend and Core semantic
    passes. This module is the codegen-side boundary that translates semantic
    types into explicit runtime representation facts. Records are private so
    callers can inspect layout facts but cannot manufacture inconsistent
    storage/ownership combinations. *)

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

type source_value_layout = private {
  sv_semantic : Ast.type_expr;
  sv_loc : Ast.loc;
  sv_ownership : source_value_ownership;
  sv_release_path : source_value_release_path;
}

type source_value_layout_classification =
  | SourceValueKnown of source_value_layout
  | SourceValueUnknownNamed of string
  | SourceValueInvalid of string

type tensor_raw_scalar_abi = private {
  tras_c_type : string;
  tras_pointer_c_type : string;
  tras_storage_mode : string;
  tras_elem_size : string;
}

type tensor_runtime_read_helper = private {
  trrh_value_ty : Ast.type_expr;
  trrh_c_helper : string;
}

type tensor_fast_numeric_access = private {
  tfna_storage_pred_intr : string;
  tfna_raw_kind : Core.tensor_unboxed_scalar;
}

type tensor_numeric_access = private {
  tna_value_ty : Ast.type_expr;
  tna_get_intrinsic : string;
  tna_fast_access : tensor_fast_numeric_access option;
}

type tensor_checked_get_access = private {
  tcga_value_ty : Ast.type_expr;
  tcga_get_intrinsic : string;
}

type tensor_to_string_runtime = private
  | TensorToStringFloat
  | TensorToStringFloat32
  | TensorToStringFloat16
  | TensorToStringBool
  | TensorToStringEnum of string
  | TensorToStringInt

type primitive_inline_width = private
  | PrimitiveInlineBits of Core.inline_storage_width
  | PrimitiveNotInlineBits

type inline_struct_kind = InlineValueRecord | InlineStackOption

type inline_struct_storage = private
  | InlineStruct of {
      inline_struct_kind : inline_struct_kind;
      inline_struct_c_type : string;
    }
  | NotInlineStruct

type value_record_layout = private { vrl_name : string; vrl_c_type : string }

type stack_option_emit_abi = private {
  soe_c_type : string;
  soe_none_value : string;
}

type option_constructor_abi = private
  | OptionConstructorStackInline of stack_option_emit_abi
  | OptionConstructorNullableManaged
  | OptionConstructorBoxedUnion
  | OptionConstructorUnavailable of string

type option_erasure_layout = private
  | OptionErasureStackValue
  | OptionErasureNullableManagedPointer
  | OptionErasureBoxedUnion of string
  | OptionErasureUnknownPayload of string
  | OptionErasureInvalid of string

type generated_stack_option_payload_storage = private
  | GeneratedStackOptionInt128
  | GeneratedStackOptionUInt128
  | GeneratedStackOptionLong
  | GeneratedStackOptionValueRecord of string

type generated_stack_option_get_abi = private {
  gsog_option_c_type : string;
  gsog_payload_c_type : string;
  gsog_none_value : string;
  gsog_payload_storage : generated_stack_option_payload_storage;
}

type option_payload_runtime_abi = private
  | OptionPayloadPrimitiveStack of string
  | OptionPayloadNullableManaged
  | OptionPayloadBoxedUnion
  | OptionPayloadNoSpecialization

type option_equality_abi = private
  | OptionEqualityStackInline of { oeq_option_c_type : string }
  | OptionEqualityNullableString
  | OptionEqualityBoxedUnionRuntime of string
  | OptionEqualityUnavailable of string

type stack_result_constructor_abi = private { src_result_c_type : string }

type list_element_storage = private
  | ListElementInlineBits of Core.inline_storage_width
  | ListElementInlineStruct of string
  | ListElementPointer

type list_type = private { list_elem_ty : Ast.type_expr }
type set_type = private { set_elem_ty : Ast.type_expr }

type dict_type = private {
  dict_key_ty : Ast.type_expr;
  dict_value_ty : Ast.type_expr;
}

type tensor_element_storage = private
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

type t = private {
  semantic : Ast.type_expr;
  loc : Ast.loc;
  storage : storage;
  source_rc : source_rc;
}

val classify_erased_storage :
  ?phase:Core_error.phase_tag ->
  reg:Codegen_types.registry ->
  Ast.type_expr ->
  Ast.loc ->
  t

val box_kind : t -> Core.box_kind
val unbox_kind : t -> Core.unbox_kind

val box_kind_of_type :
  ?phase:Core_error.phase_tag ->
  reg:Codegen_types.registry ->
  Ast.type_expr ->
  Ast.loc ->
  Core.box_kind

val unbox_kind_of_type :
  ?phase:Core_error.phase_tag ->
  reg:Codegen_types.registry ->
  Ast.type_expr ->
  Ast.loc ->
  Core.unbox_kind

val storage_release : t -> storage_release

val storage_release_or_error :
  ?phase:Core_error.phase_tag -> t -> storage_release_capability

val storage_requires_release_or_error : ?phase:Core_error.phase_tag -> t -> bool

val boxed_storage_requires_release_or_error :
  ?phase:Core_error.phase_tag ->
  reg:Codegen_types.registry ->
  Ast.type_expr ->
  Ast.loc ->
  bool

val record_destructor_policy :
  ?phase:Core_error.phase_tag ->
  reg:Codegen_types.registry ->
  Ast.record_decl ->
  Codegen_types.managed_destructor

val union_destructor_policy :
  ?phase:Core_error.phase_tag ->
  reg:Codegen_types.registry ->
  Ast.type_decl ->
  Codegen_types.managed_destructor

val tensor_raw_scalar_abi : Core.tensor_unboxed_scalar -> tensor_raw_scalar_abi

(* Raw scalar value ABI used by tensor read/write intrinsics. This is not the
   same decision as tensor element storage layout: a value type can have a raw
   scalar read ABI even when a particular tensor producer stores that type in a
   packed or boxed representation. *)
val tensor_raw_scalar_kind_of_type :
  reg:Codegen_types.registry ->
  Ast.type_expr ->
  Core.tensor_unboxed_scalar option

val tensor_raw_scalar_accepts_type :
  reg:Codegen_types.registry ->
  Core.tensor_unboxed_scalar ->
  Ast.type_expr ->
  bool

(* Runtime scalar reader used by tensor/list for-in fallback loops. This is a
   value-ABI decision, not proof that the producer has direct raw storage. *)
val tensor_runtime_read_helper_of_type :
  reg:Codegen_types.registry ->
  Ast.type_expr ->
  tensor_runtime_read_helper option

(* Numeric tensor access facts used by synthesized vector/tensor loops. This is
   a semantic-element classification plus the safe runtime getter and optional
   typed raw-storage fast path. It is deliberately narrower than
   [tensor_runtime_read_helper_of_type]: reductions currently synthesize only
   Int, Float, Float32, and Float16. *)
val tensor_numeric_access_of_type :
  reg:Codegen_types.registry -> Ast.type_expr -> tensor_numeric_access option

(* Scalar Core getter selected for bounds-proven tensor checked-get
   specialization. This preserves the late-layout decision about which
   element types can use a typed runtime read after the bounds proof has
   removed Option construction. *)
val tensor_checked_get_access_of_type :
  reg:Codegen_types.registry ->
  Ast.type_expr ->
  tensor_checked_get_access option

val tensor_to_string_runtime_of_elem_type :
  reg:Codegen_types.registry -> Ast.type_expr -> tensor_to_string_runtime

val tensor_raw_scalar_abi_of_layout :
  Core.tensor_storage_layout -> tensor_raw_scalar_abi option

val inline_width_for_enum_info :
  Codegen_types.enum_info -> Core.inline_storage_width

type enum_inline_width =
  | EnumInlineBits of Core.inline_storage_width
  | NotInlineEnum

val enum_inline_width :
  ?reg:Codegen_types.registry -> Ast.type_expr -> enum_inline_width

val canonical_type :
  ?reg:Codegen_types.registry -> Ast.type_expr -> Ast.type_expr

val c_type : reg:Codegen_types.registry -> Ast.type_expr -> string
val is_pointer_type : reg:Codegen_types.registry -> Ast.type_expr -> bool

val record_field_uses_erased_storage :
  reg:Codegen_types.registry -> Ast.type_expr -> bool

val classify_source_value_layout_of_metadata :
  ?loc:Ast.loc ->
  Core_type_layout.metadata ->
  Ast.type_expr ->
  source_value_layout_classification

val classify_source_value_layout_of_type :
  reg:Codegen_types.registry ->
  Ast.type_expr ->
  Ast.loc ->
  source_value_layout_classification

val source_value_layout_of_metadata :
  ?phase:Core_error.phase_tag ->
  ?loc:Ast.loc ->
  Core_type_layout.metadata ->
  Ast.type_expr ->
  source_value_layout

val source_value_layout_of_type :
  ?phase:Core_error.phase_tag ->
  reg:Codegen_types.registry ->
  Ast.type_expr ->
  Ast.loc ->
  source_value_layout

val source_value_requires_release : source_value_layout -> bool
val source_value_requires_retain : source_value_layout -> bool
val source_value_release_path : source_value_layout -> source_value_release_path

val source_value_requires_release_or_error :
  ?phase:Core_error.phase_tag ->
  reg:Codegen_types.registry ->
  Ast.type_expr ->
  Ast.loc ->
  bool

val source_value_requires_retain_or_error :
  ?phase:Core_error.phase_tag ->
  reg:Codegen_types.registry ->
  Ast.type_expr ->
  Ast.loc ->
  bool

val boxed_storage_scalar_kind :
  ?reg:Codegen_types.registry -> Ast.type_expr -> boxed_storage_scalar_kind

val hash_key_pointer_argument :
  ?reg:Codegen_types.registry -> Ast.type_expr -> pointer_argument_layout

val boxed_storage_value_pointer_argument :
  ?reg:Codegen_types.registry -> Ast.type_expr -> pointer_argument_layout

val hash_probe_layout :
  ?reg:Codegen_types.registry -> Ast.type_expr -> hash_probe_layout

val primitive_inline_width : Ast.type_expr -> primitive_inline_width

val inline_struct_storage :
  ?reg:Codegen_types.registry -> Ast.type_expr -> inline_struct_storage

val value_record_layout_of_type :
  ?reg:Codegen_types.registry -> Ast.type_expr -> value_record_layout option

val value_record_c_type :
  ?reg:Codegen_types.registry -> Ast.type_expr -> string option

val list_element_storage :
  ?reg:Codegen_types.registry -> Ast.type_expr -> list_element_storage

val list_type : ?reg:Codegen_types.registry -> Ast.type_expr -> list_type option
val set_type : ?reg:Codegen_types.registry -> Ast.type_expr -> set_type option
val dict_type : ?reg:Codegen_types.registry -> Ast.type_expr -> dict_type option

val tensor_element_storage :
  ?reg:Codegen_types.registry -> Ast.type_expr -> tensor_element_storage

val list_storage_layout_of_elem :
  ?reg:Codegen_types.registry ->
  Ast.type_expr ->
  Ast.loc ->
  Core.list_storage_layout

val list_storage_layout_of_type :
  ?reg:Codegen_types.registry ->
  Ast.type_expr ->
  Ast.loc ->
  Core.list_storage_layout

val tensor_storage_layout_of_elem :
  ?reg:Codegen_types.registry ->
  Ast.type_expr ->
  Ast.loc ->
  Core.tensor_storage_layout

val tensor_storage_layout_of_type :
  ?reg:Codegen_types.registry ->
  Ast.type_expr ->
  Ast.loc ->
  Core.tensor_storage_layout

val option_layout_or_error :
  ?phase:Core_error.phase_tag ->
  reg:Codegen_types.registry ->
  Ast.type_expr ->
  Ast.loc ->
  Core_option_layout.layout

val option_erasure_layout_of_type :
  reg:Codegen_types.registry -> Ast.type_expr -> option_erasure_layout

val nullable_managed_option_payload_type :
  reg:Codegen_types.registry -> Ast.type_expr -> Ast.type_expr option

val is_nullable_managed_option :
  reg:Codegen_types.registry -> Ast.type_expr -> bool

val option_constructor_abi_of_layout :
  Core_option_layout.layout -> option_constructor_abi

val generated_stack_option_get_abi :
  reg:Codegen_types.registry ->
  Ast.type_expr ->
  generated_stack_option_get_abi option

val generated_stack_option_payload_from_erased :
  generated_stack_option_get_abi -> string -> string

val option_payload_runtime_abi :
  reg:Codegen_types.registry -> Ast.type_expr -> option_payload_runtime_abi

val option_type_runtime_abi :
  reg:Codegen_types.registry ->
  Ast.type_expr ->
  option_payload_runtime_abi option

val option_equality_abi :
  reg:Codegen_types.registry -> Ast.type_expr -> option_equality_abi

val stack_option_none_value_for_type :
  reg:Codegen_types.registry -> Ast.type_expr -> string

val stack_option_c_type :
  reg:Codegen_types.registry -> Ast.type_expr -> string option

val stack_result_c_type :
  reg:Codegen_types.registry -> Ast.type_expr -> string option

val is_stack_option_type : reg:Codegen_types.registry -> Ast.type_expr -> bool
val is_stack_result_type : reg:Codegen_types.registry -> Ast.type_expr -> bool

val stack_result_layout :
  reg:Codegen_types.registry ->
  Ast.type_expr ->
  Core_result_layout.layout option

val stack_result_constructor_abi_of_layout :
  Core_result_layout.layout -> stack_result_constructor_abi

val source_pointer_storage_policy_or_error :
  ?phase:Core_error.phase_tag -> t -> Core.container_storage_policy

val erased_box_storage_policy_or_error :
  ?phase:Core_error.phase_tag -> t -> Core.container_storage_policy
