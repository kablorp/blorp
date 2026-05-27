(** Non-recursive helpers used by the [Core_emit] mutual-recursion
    block. Phase 5.1 step 1 extraction.

    Every function here is a pure helper that neither takes nor calls
    into the main [emit_expr]/[emit_stmt]/[emit_intrinsic] chain in
    [core_emit.ml]. Adding a new helper that DOES call into that chain
    means it belongs inside [core_emit.ml]'s rec block, not here. *)

val is_pointer_type : Core_emit_context.t -> Ast.type_expr -> bool
(** Is a type represented as a heap pointer (not a scalar)? *)

val type_to_c : Core_emit_context.t -> Ast.type_expr -> string
(** Render a blorp type as a C type string. *)

val nullable_managed_option_payload_type :
  Core_emit_context.t -> Ast.type_expr -> Ast.type_expr option
(** If the type is represented as nullable managed [Option[T]], return the
    normalized payload type [T]. *)

val is_nullable_managed_option : Core_emit_context.t -> Ast.type_expr -> bool
(** Is this type represented as a nullable managed pointer Option? *)

val value_record_c_type : Core_emit_context.t -> Ast.type_expr -> string option
(** If the type is a by-value record, return its emitted C type. *)

val value_record_layout :
  Core_emit_context.t ->
  Ast.type_expr ->
  Core_layout_type.value_record_layout option
(** If the type is a by-value record, return its layout identity. *)

val is_value_record_type : Core_emit_context.t -> Ast.type_expr -> bool
(** Is this type represented as a by-value record? *)

val value_record_storage_c_type : Core_emit_context.t -> Ast.type_expr -> string
(** Return the value-record C type when applicable, otherwise [type_to_c]. *)

val emit_binop : Core_emit_context.t -> Ast.binop -> unit
(** Emit a binary operator symbol to the context's buffer. *)

val emit_logop : Core_emit_context.t -> Ast.logop -> unit
(** Emit a logical operator symbol (`&&` / `||`) to the buffer. *)

val not_yet : string -> Ast.loc -> 'a
(** Raise [Core_error] for an unimplemented form with location info. *)

val has_type_vars : Ast.type_expr -> bool
(** Does this type contain any type variables? (Re-export of
    [Codegen_types.has_type_vars].) *)

val is_void_ty : Ast.type_expr -> bool
(** Is this type [Void]? *)

(** Classification of a Core value for boxing into [void*]. *)
type box_kind = Core.box_kind =
  | BoxFloat
  | BoxFloat32
  | BoxFloat16
  | BoxInt128
  | BoxUInt128
  | BoxVoid
  | BoxPointer
  | BoxPrim
  | BoxStruct of string

val classify_for_boxing :
  Core_emit_context.t -> Ast.type_expr -> Ast.loc -> box_kind
(** Classify a type for void* boxing. Raises [Core_error] if the type
    is a type-level dim expression (TyDimOp / TyVarDims / TyConstInt)
    that accidentally reached a value position. *)

type inline_storage_width = Core.inline_storage_width =
  | InlineBytes1
  | InlineBytes2
  | InlineBytes4
  | InlineBytes8

val inline_storage_width_bytes : inline_storage_width -> int

type list_storage_slot_layout = Core.list_storage_slot_layout =
  | ListPointerStorage
  | ListInlineStorage of inline_storage_width
  | ListInlineStructStorage of string

type storage_ownership = Core.storage_ownership =
  | StorageManaged
  | StorageUnmanaged
  | StorageUnknownOwnership of string

type storage_retain_policy = Core.storage_retain_policy =
  | StorageNoRetain
  | StorageArcRetain
  | StorageUnknownRetain of string

type storage_release_policy = Core.storage_release_policy =
  | StorageNoRelease
  | StorageArcRelease
  | StorageUnknownRelease of string

type storage_equality_policy = Core.storage_equality_policy =
  | StorageEqualityBits
  | StorageEqualityPointer
  | StorageUnknownEquality of string

type container_storage_policy = Core.container_storage_policy =
  | StoragePolicyUnmanagedBits
  | StoragePolicyManagedPointer
  | StoragePolicyOwnedErasedBox
  | StoragePolicyUnknown of string

type list_element_value_layout = Core.list_element_value_layout =
  | ListElementPointer
  | ListElementInlineBits of inline_storage_width
  | ListElementStackStruct of string
  | ListElementBoxedValue
  | ListElementUnknownValue of string

type list_storage_layout = Core.list_storage_layout = {
  lsl_slots : list_storage_slot_layout;
  lsl_elem_ty : Ast.type_expr option;
  lsl_value_layout : list_element_value_layout;
  lsl_policy : container_storage_policy;
}

val list_storage_layout_of_type :
  Core_emit_context.t -> Ast.type_expr -> Ast.loc -> list_storage_layout
(** Runtime storage layout for [List[T]]. Pointer storage is the generic
    managed/reference representation. Inline storage uses one of the
    supported primitive widths, making invalid element widths
    unrepresentable in the emitter. *)

module StringSet : Set.S with type elt = string
(** Internal string-keyed collections used by the free-variable
    collection pass below. Exposed so other passes can share the
    value-type choice without redefining. *)

module StringMap : Map.S with type key = string

val collect_free_vars : Core.core -> (string * Ast.type_expr) list
(** Collect (name, type) pairs for every free variable in a Core
    expression. Result is sorted by name. *)

val collect_free_vars_filtered :
  Core_emit_context.t -> Core.core -> (string * Ast.type_expr) list
(** Like [collect_free_vars] but filters constructor names (they're
    `#define` macros, not capturable variables), module-alias sentinels
    ([TyNamed "Module"]), and UFCS-mangled function names. *)

val emit_box_to_void :
  ?loc:Ast.loc -> Core_emit_context.t -> string -> Ast.type_expr -> unit
(** Box a C expression to [void*] for storage in generic containers,
    closure environments, or variant fields. *)

val unbox_decl_str :
  ?loc:Ast.loc ->
  Core_emit_context.t ->
  string ->
  string ->
  Ast.type_expr ->
  string
(** Generate the unbox declaration string for a given type. Single
    source of truth for void* → typed variable declaration. *)

val unbox_decl_for_accessor_str :
  Core_emit_context.t ->
  string ->
  scrut_ty:Ast.type_expr ->
  accessor:Core.accessor ->
  source:string ->
  Ast.type_expr ->
  string
(** Generate a binding declaration for a pattern accessor. Uses direct scalar
    field access for primitive stack [Option[T]] payloads and [unbox_decl_str]
    for erased [void*] storage. *)

val emit_unbox_decl :
  Core_emit_context.t -> string -> string -> Ast.type_expr -> unit
(** Emit [unbox_decl_str] as an indented line. *)

val emit_capture_box : Core_emit_context.t -> string -> Ast.type_expr -> unit
(** Box a capture value — delegates to [emit_box_to_void]. *)

val emit_capture_unbox :
  Core_emit_context.t -> string -> Ast.type_expr -> int -> unit
(** Unbox a capture from the environment array [__e[idx]]. *)

val type_requires_release : Core_emit_context.t -> Ast.type_expr -> bool
(** Does this type need a generated release operation when ownership is
    consumed?
    Unknown named types are compiler invariant violations. *)

val type_requires_retain : Core_emit_context.t -> Ast.type_expr -> bool
(** Does this type need a generated retain operation when ownership is
    shared?
    Unknown named types are compiler invariant violations. *)

val retain_value_call : Core_emit_context.t -> Ast.type_expr -> string -> string
(** Render the type-aware retain call for a C value expression. *)

val release_value_call :
  Core_emit_context.t -> Ast.type_expr -> string -> string
(** Render the type-aware release call for a C value expression. *)

val cancellation_cleanup_release_fn :
  Core_emit_context.t -> Ast.type_expr -> string option
(** Runtime cleanup callback for a cancellable owned local of this type, if the
    value can be safely stored in a cancellation-cleanup frame. *)

val boxed_value_needs_release :
  Core_emit_context.t -> Ast.type_expr -> Ast.loc -> bool
(** Does a boxed value of this type need release ownership when stored
    in containers or variant fields? *)

val list_element_needs_release :
  Core_emit_context.t -> Ast.type_expr -> Ast.loc -> bool
(** Does a List[T] need elem_release metadata for boxed T elements? *)

val render_accessor : Core_emit_context.t -> string -> Core.accessor -> string
(** Resolve an [accessor] path to a C expression string rooted at
    [scrut_name]. Casts intermediate void* values through the correct
    union type when accessing nested variant fields. *)

val render_accessor_typed :
  Core_emit_context.t -> string -> Ast.type_expr -> Core.accessor -> string
(** Like [render_accessor], but uses the root scrutinee type for
    representation-specific accessors such as primitive stack [Option[T]]. *)

val collect_var_types : Core.core -> (string, Ast.type_expr) Hashtbl.t
(** Collect (variable name → type) pairs for every [CVar] in an
    expression. Used by pattern-match emission to recover the type of
    a binding at its use site. *)

val find_var_type : string -> (string, Ast.type_expr) Hashtbl.t -> Ast.type_expr
(** Look up a variable's type in a [collect_var_types] map. Falls
    back to [TyVar "?"] when the name isn't recorded — intentional:
    the caller knows its own usage pattern and accepts the
    placeholder when the lookup is advisory. *)

val accessor_is_enum :
  Core_emit_context.t -> Ast.type_expr -> Core.accessor -> bool
(** True if the value at [acc] (starting from a root of type
    [scrut_ty]) is an enum-tagged scalar [long] — used by
    pattern-match emission to decide between [acc == Ctor] (enums)
    and [acc->tag == TAG_Ctor] (unions). *)

val tag_test_str :
  Core_emit_context.t ->
  Ast.type_expr ->
  Core.accessor ->
  string ->
  string ->
  string
(** Format a tag-equality test for a pattern-match decision tree. *)

val emit_lit_cmp : Core_emit_context.t -> string -> Ast.literal -> unit
(** Emit a comparison of [scrut_expr] against [lit]. Strings use
    [blorp_string_eq_cstr]; other literals use C [==]. *)
