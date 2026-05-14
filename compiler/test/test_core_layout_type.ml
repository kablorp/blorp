(** Tests for the late Core layout classifier. *)

open Blorp.Ast

let loc =
  { line = 1; column = 1; end_line = 1; end_column = 1; loc_file = None }

let ty name args = TyNamed (name, args)
let ty_int = ty "Int" []
let ty_float = ty "Float" []
let ty_float32 = ty "Float32" []
let ty_bool = ty "Bool" []
let ty_char = ty "Char" []
let ty_string = ty "String" []
let option payload = ty "Option" [ payload ]

let variant name tag =
  {
    variant_name = name;
    variant_fields = [];
    variant_tag = tag;
    variant_loc = loc;
    variant_def_id = None;
  }

let field name field_type = { field_name = name; field_type; field_loc = loc }

let record name fields =
  {
    record_name = name;
    record_type_params = [];
    record_fields = fields;
    record_is_value = false;
    record_is_builtin = false;
  }

let union name fields =
  {
    type_name = name;
    type_params = [];
    type_variants =
      [
        {
          variant_name = "Value";
          variant_fields = fields;
          variant_tag = 0;
          variant_loc = loc;
          variant_def_id = None;
        };
      ];
    type_is_enum = false;
    type_is_builtin = false;
  }

let tensor_raw_storage expected = function
  | Blorp.Core_layout_type.TensorElementRawScalar actual -> actual = expected
  | _ -> false

let tensor_packed_storage expected = function
  | Blorp.Core_layout_type.TensorElementPackedBits actual -> actual = expected
  | _ -> false

let tensor_boxed_storage = function
  | Blorp.Core_layout_type.TensorElementBoxed -> true
  | _ -> false

let list_inline_storage expected = function
  | Blorp.Core_layout_type.ListElementInlineBits actual -> actual = expected
  | _ -> false

let list_inline_struct_storage expected = function
  | Blorp.Core_layout_type.ListElementInlineStruct actual ->
      String.equal actual expected
  | _ -> false

let list_pointer_storage = function
  | Blorp.Core_layout_type.ListElementPointer -> true
  | _ -> false

let test_source_value_layout_is_explicit () =
  let reg = Blorp.Codegen_types.create_registry () in
  Hashtbl.replace reg.value_records "Point" ();
  Hashtbl.replace reg.type_aliases "Name" ([], ty_string);
  let classify ty =
    Blorp.Core_layout_type.source_value_layout_of_type ~reg ty loc
  in
  let string_layout = classify (ty "Name" []) in
  Alcotest.(check bool)
    "managed aliases require release" true
    (Blorp.Core_layout_type.source_value_requires_release string_layout);
  Alcotest.(check bool)
    "managed aliases require retain" true
    (Blorp.Core_layout_type.source_value_requires_retain string_layout);
  let point_layout = classify (ty "Point" []) in
  Alcotest.(check bool)
    "value records are unmanaged as source values" false
    (Blorp.Core_layout_type.source_value_requires_release point_layout);
  let int_layout = classify ty_int in
  Alcotest.(check bool)
    "primitive source values are unmanaged" false
    (Blorp.Core_layout_type.source_value_requires_retain int_layout)

let test_source_value_layout_rejects_unknown_type () =
  let reg = Blorp.Codegen_types.create_registry () in
  match
    Blorp.Core_layout_type.source_value_layout_of_type ~reg (ty "Mystery" [])
      loc
  with
  | _ -> Alcotest.fail "expected unknown source value type to be rejected"
  | exception Blorp.Core_error.Core_error err ->
      Alcotest.(check bool)
        "explains unknown source value layout" true
        (String.equal err.Blorp.Core_error.msg
           "ownership classifier has no layout for type Mystery")

let test_source_value_layout_classification_is_explicit () =
  let reg = Blorp.Codegen_types.create_registry () in
  match
    Blorp.Core_layout_type.classify_source_value_layout_of_type ~reg
      (ty "Mystery" []) loc
  with
  | Blorp.Core_layout_type.SourceValueUnknownNamed "Mystery" -> ()
  | Blorp.Core_layout_type.SourceValueKnown _
  | Blorp.Core_layout_type.SourceValueUnknownNamed _
  | Blorp.Core_layout_type.SourceValueInvalid _ ->
      Alcotest.fail "expected unknown named source-value classification"

let test_source_value_release_path_is_layout_owned () =
  let open Blorp.Codegen_types in
  let reg = create_registry () in
  register_heap_record_type reg "Point" ~destructor:ArcReleaseOnly;
  register_heap_record_type reg "Named"
    ~destructor:(GeneratedDestructor "Named_destroy");
  Hashtbl.replace reg.value_records "Vec2" ();
  let release_path ty =
    Blorp.Core_layout_type.(
      source_value_layout_of_type ~reg ty loc |> source_value_release_path)
  in
  Alcotest.(check bool)
    "String uses ARC-only release" true
    (release_path ty_string = Blorp.Core_layout_type.SourceValueArcReleaseOnly);
  Alcotest.(check bool)
    "primitive records use ARC-only release" true
    (release_path (ty "Point" [])
    = Blorp.Core_layout_type.SourceValueArcReleaseOnly);
  Alcotest.(check bool)
    "records with managed fields use destructor release" true
    (release_path (ty "Named" [])
    = Blorp.Core_layout_type.SourceValueArcReleaseWithDestructor);
  Alcotest.(check bool)
    "value records need no source release" true
    (release_path (ty "Vec2" []) = Blorp.Core_layout_type.SourceValueNoRelease)

let test_boxed_storage_scalar_kind_is_explicit () =
  let reg = Blorp.Codegen_types.create_registry () in
  Hashtbl.replace reg.type_aliases "Wide" ([], ty "Int128" []);
  Alcotest.(check bool)
    "alias to Int128 is an ARC-boxed scalar" true
    (match
       Blorp.Core_layout_type.boxed_storage_scalar_kind ~reg (ty "Wide" [])
     with
    | Blorp.Core_layout_type.BoxedStorageArcBoxedScalar -> true
    | _ -> false);
  Alcotest.(check bool)
    "Int is an inline boxed scalar" true
    (match Blorp.Core_layout_type.boxed_storage_scalar_kind ty_int with
    | Blorp.Core_layout_type.BoxedStorageInlineScalar -> true
    | _ -> false);
  Alcotest.(check bool)
    "String is not a boxed scalar" true
    (match Blorp.Core_layout_type.boxed_storage_scalar_kind ty_string with
    | Blorp.Core_layout_type.BoxedStorageNonScalar -> true
    | _ -> false)

let test_destructor_policy_is_layout_owned () =
  let open Blorp.Codegen_types in
  let reg = create_registry () in
  Alcotest.(check bool)
    "primitive record is ARC-only" true
    (Blorp.Core_layout_type.record_destructor_policy ~reg
       (record "Point" [ field "x" ty_int ])
    = ArcReleaseOnly);
  Alcotest.(check bool)
    "string record has generated destructor" true
    (Blorp.Core_layout_type.record_destructor_policy ~reg
       (record "Named" [ field "name" ty_string ])
    = GeneratedDestructor "Named_destroy");
  Alcotest.(check bool)
    "generic record field has generated destructor" true
    (Blorp.Core_layout_type.record_destructor_policy ~reg
       {
         (record "Box" [ field "value" (TyVar "T") ]) with
         record_type_params = [ make_type_param "T" [] ];
       }
    = GeneratedDestructor "Box_destroy");
  Alcotest.(check bool)
    "float union boxed storage is release-free" true
    (Blorp.Core_layout_type.union_destructor_policy ~reg
       (union "FloatBox" [ ty_float ])
    = ArcReleaseOnly);
  Alcotest.(check bool)
    "int128 union boxed storage needs destructor" true
    (Blorp.Core_layout_type.union_destructor_policy ~reg
       (union "Wide" [ ty "Int128" [] ])
    = GeneratedDestructor "Wide_destroy")

let test_tensor_primitive_storage_is_explicit () =
  let open Blorp.Core_layout_type in
  Alcotest.(check bool)
    "Int tensors use raw i64 storage" true
    (tensor_raw_storage Blorp.Core.TensorInt64Elements
       (tensor_element_storage ty_int));
  Alcotest.(check bool)
    "Float tensors use raw f64 storage" true
    (tensor_raw_storage Blorp.Core.TensorFloat64Elements
       (tensor_element_storage ty_float));
  Alcotest.(check bool)
    "Float32 tensors use raw f32 storage" true
    (tensor_raw_storage Blorp.Core.TensorFloat32Elements
       (tensor_element_storage ty_float32))

let test_tensor_non_word_storage_remains_distinct () =
  let open Blorp.Core_layout_type in
  let reg = Blorp.Codegen_types.create_registry () in
  Blorp.Codegen_types.register_enum_type reg "Tiny"
    [ variant "Zero" 0; variant "One" 1 ];
  Alcotest.(check bool)
    "Bool tensors use packed bits" true
    (tensor_packed_storage Blorp.Core.InlineBytes1
       (tensor_element_storage ty_bool));
  Alcotest.(check bool)
    "Enums use packed bits from registry" true
    (tensor_packed_storage Blorp.Core.InlineBytes1
       (tensor_element_storage ~reg (ty "Tiny" [])));
  Alcotest.(check bool)
    "Stack option tensors remain boxed" true
    (tensor_boxed_storage (tensor_element_storage (option ty_int)));
  Alcotest.(check bool)
    "Managed strings remain boxed" true
    (tensor_boxed_storage (tensor_element_storage ty_string))

let test_list_element_storage_is_layout_owned () =
  let open Blorp.Core_layout_type in
  let reg = Blorp.Codegen_types.create_registry () in
  Hashtbl.replace reg.value_records "Point" ();
  Alcotest.(check bool)
    "Int lists use layout-owned inline bits" true
    (list_inline_storage Blorp.Core.InlineBytes8 (list_element_storage ty_int));
  Alcotest.(check bool)
    "value-record lists use layout-owned inline structs" true
    (list_inline_struct_storage "Point"
       (list_element_storage ~reg (ty "Point" [])));
  Alcotest.(check bool)
    "managed strings use layout-owned pointer slots" true
    (list_pointer_storage (list_element_storage ty_string))

let test_enum_inline_width_is_layout_owned () =
  let open Blorp.Core in
  let enum_info max_tag =
    {
      Blorp.Codegen_types.enum_variant_count = max_tag + 1;
      Blorp.Codegen_types.enum_max_tag = max_tag;
    }
  in
  Alcotest.(check bool)
    "1-byte enum width is layout-owned" true
    (Blorp.Core_layout_type.inline_width_for_enum_info (enum_info 0xFF)
    = InlineBytes1);
  Alcotest.(check bool)
    "2-byte enum width is layout-owned" true
    (Blorp.Core_layout_type.inline_width_for_enum_info (enum_info 0xFFFF)
    = InlineBytes2);
  Alcotest.(check bool)
    "4-byte enum width is layout-owned" true
    (Blorp.Core_layout_type.inline_width_for_enum_info (enum_info 0x1_0000)
    = InlineBytes4);
  Alcotest.(check bool)
    "8-byte enum width is layout-owned" true
    (Blorp.Core_layout_type.inline_width_for_enum_info (enum_info 0x1_0000_0000)
    = InlineBytes8)

let test_enum_inline_type_classification_is_layout_owned () =
  let open Blorp.Core in
  let open Blorp.Core_layout_type in
  let reg = Blorp.Codegen_types.create_registry () in
  Blorp.Codegen_types.register_enum_type reg "Tiny"
    [ variant "Zero" 0; variant "One" 1 ];
  Hashtbl.replace reg.type_aliases "TinyAlias" ([], ty "Tiny" []);
  Alcotest.(check bool)
    "enum type width comes from layout classifier" true
    (enum_inline_width ~reg (ty "Tiny" []) = EnumInlineBits InlineBytes1);
  Alcotest.(check bool)
    "enum alias width comes from layout classifier" true
    (enum_inline_width ~reg (ty "TinyAlias" []) = EnumInlineBits InlineBytes1);
  Alcotest.(check bool)
    "non-enum is represented explicitly" true
    (enum_inline_width ~reg ty_int = NotInlineEnum)

let test_tensor_to_string_runtime_is_layout_owned () =
  let open Blorp.Core_layout_type in
  let reg = Blorp.Codegen_types.create_registry () in
  Blorp.Codegen_types.register_enum_type reg "Tiny"
    [ variant "Zero" 0; variant "One" 1 ];
  Hashtbl.replace reg.type_aliases "TinyAlias" ([], ty "Tiny" []);
  let describe = function
    | TensorToStringFloat -> "float"
    | TensorToStringFloat32 -> "float32"
    | TensorToStringFloat16 -> "float16"
    | TensorToStringBool -> "bool"
    | TensorToStringEnum name -> "enum:" ^ name
    | TensorToStringInt -> "int"
  in
  Alcotest.(check string)
    "float32 tensor to_string runtime" "float32"
    (describe (tensor_to_string_runtime_of_elem_type ~reg ty_float32));
  Alcotest.(check string)
    "bool tensor to_string runtime" "bool"
    (describe (tensor_to_string_runtime_of_elem_type ~reg ty_bool));
  Alcotest.(check string)
    "enum alias tensor to_string runtime" "enum:Tiny"
    (describe (tensor_to_string_runtime_of_elem_type ~reg (ty "TinyAlias" [])));
  Alcotest.(check string)
    "int tensor to_string runtime" "int"
    (describe (tensor_to_string_runtime_of_elem_type ~reg ty_int))

let test_canonical_type_is_layout_owned () =
  let reg = Blorp.Codegen_types.create_registry () in
  Hashtbl.replace reg.type_aliases "Count" ([], ty_int);
  Hashtbl.replace reg.type_aliases "CountVector"
    ([], ty "Vector" [ ty "Count" []; TyConstInt 4 ]);
  let source = ty "CountVector" [] in
  let expected = ty "Tensor" [ ty_int; TyConstInt 4 ] in
  let actual = Blorp.Core_layout_type.canonical_type ~reg source in
  Alcotest.(check bool)
    "layout canonical type expands aliases and normalizes vector spelling" true
    (Blorp.Types.types_equal actual expected);
  Alcotest.(check bool)
    "array layout wrapper delegates canonicalization" true
    (Blorp.Types.types_equal
       (Blorp.Core_layout_type.canonical_type ~reg source)
       expected)

let test_list_type_is_layout_owned () =
  let reg = Blorp.Codegen_types.create_registry () in
  Hashtbl.replace reg.type_aliases "Count" ([], ty_int);
  Hashtbl.replace reg.type_aliases "Counts" ([], ty "List" [ ty "Count" [] ]);
  match Blorp.Core_layout_type.list_type ~reg (ty "Counts" []) with
  | Some info ->
      Alcotest.(check bool)
        "list aliases expose canonical element type" true
        (Blorp.Types.types_equal info.list_elem_ty ty_int)
  | None -> Alcotest.fail "expected list alias to classify as List"

let test_hash_container_layout_is_layout_owned () =
  let open Blorp.Core_layout_type in
  let reg = Blorp.Codegen_types.create_registry () in
  Hashtbl.replace reg.type_aliases "Count" ([], ty_int);
  Hashtbl.replace reg.type_aliases "Counts" ([], ty "Set" [ ty "Count" [] ]);
  Hashtbl.replace reg.type_aliases "CountDict"
    ([], ty "Dict" [ ty "Count" []; ty_string ]);
  Hashtbl.replace reg.value_records "Point" ();
  Hashtbl.replace reg.type_aliases "PointAlias" ([], ty "Point" []);
  Blorp.Codegen_types.register_enum_type reg "Tiny"
    [ variant "Zero" 0; variant "One" 1 ];
  Hashtbl.replace reg.type_aliases "TinyAlias" ([], ty "Tiny" []);
  (match set_type ~reg (ty "Counts" []) with
  | Some set_ty ->
      Alcotest.(check bool)
        "set aliases expose canonical element type" true
        (Blorp.Types.types_equal set_ty.set_elem_ty ty_int)
  | None -> Alcotest.fail "expected set alias to classify as Set");
  (match dict_type ~reg (ty "CountDict" []) with
  | Some dict_ty ->
      Alcotest.(check bool)
        "dict aliases expose canonical key type" true
        (Blorp.Types.types_equal dict_ty.dict_key_ty ty_int);
      Alcotest.(check bool)
        "dict aliases expose canonical value type" true
        (Blorp.Types.types_equal dict_ty.dict_value_ty ty_string)
  | None -> Alcotest.fail "expected dict alias to classify as Dict");
  Alcotest.(check bool)
    "alias int keys use immediate hash probing" true
    (hash_probe_layout ~reg (ty "Count" []) = HashProbeImmediate);
  Alcotest.(check bool)
    "wide integer keys stay dispatched" true
    (hash_probe_layout ~reg (ty "Int128" []) = HashProbeDispatched);
  Alcotest.(check bool)
    "enum aliases use immediate hash probing" true
    (hash_probe_layout ~reg (ty "TinyAlias" []) = HashProbeImmediate);
  Alcotest.(check bool)
    "alias int keys are boxed for void* table arguments" true
    (hash_key_pointer_argument ~reg (ty "Count" []) = PointerArgumentBox);
  Alcotest.(check bool)
    "managed keys are borrowed through casts" true
    (hash_key_pointer_argument ~reg ty_string = PointerArgumentCast);
  Alcotest.(check bool)
    "value-record values are boxed for void* table storage" true
    (boxed_storage_value_pointer_argument ~reg (ty "PointAlias" [])
    = PointerArgumentBox)

let test_record_field_erased_storage_is_layout_owned () =
  let reg = Blorp.Codegen_types.create_registry () in
  Alcotest.(check bool)
    "generic field erases through layout boundary" true
    (Blorp.Core_layout_type.record_field_uses_erased_storage ~reg (TyVar "T"));
  Alcotest.(check bool)
    "concrete primitive field is not erased" false
    (Blorp.Core_layout_type.record_field_uses_erased_storage ~reg ty_int);
  Alcotest.(check bool)
    "concrete managed field is not erased by field ABI" false
    (Blorp.Core_layout_type.record_field_uses_erased_storage ~reg ty_string)

let test_primitive_inline_width_is_layout_owned () =
  let open Blorp.Core in
  let open Blorp.Core_layout_type in
  let has_width ty expected =
    match primitive_inline_width ty with
    | PrimitiveInlineBits actual -> actual = expected
    | PrimitiveNotInlineBits -> false
  in
  let has_no_width ty =
    match primitive_inline_width ty with
    | PrimitiveInlineBits _ -> false
    | PrimitiveNotInlineBits -> true
  in
  Alcotest.(check bool)
    "Bool width is layout-owned" true
    (has_width ty_bool InlineBytes1);
  Alcotest.(check bool)
    "Char width is layout-owned" true
    (has_width ty_char InlineBytes4);
  Alcotest.(check bool)
    "Float32 width is layout-owned" true
    (has_width ty_float32 InlineBytes4);
  Alcotest.(check bool)
    "Float width is layout-owned" true
    (has_width ty_float InlineBytes8);
  Alcotest.(check bool)
    "String has no primitive inline width" true (has_no_width ty_string)

let test_inline_struct_storage_is_layout_owned () =
  let open Blorp.Core_layout_type in
  let reg = Blorp.Codegen_types.create_registry () in
  Hashtbl.replace reg.value_records "Point" ();
  Hashtbl.replace reg.type_aliases "PointAlias" ([], ty "Point" []);
  Hashtbl.replace reg.type_aliases "MaybeInt" ([], option ty_int);
  let is_value_record expected = function
    | InlineStruct
        { inline_struct_kind = InlineValueRecord; inline_struct_c_type } ->
        inline_struct_c_type = expected
    | _ -> false
  in
  let is_stack_option expected = function
    | InlineStruct
        { inline_struct_kind = InlineStackOption; inline_struct_c_type } ->
        inline_struct_c_type = expected
    | _ -> false
  in
  let is_not_inline_struct = function
    | NotInlineStruct -> true
    | InlineStruct _ -> false
  in
  Alcotest.(check bool)
    "value record inline struct is layout-owned" true
    (is_value_record "Point" (inline_struct_storage ~reg (ty "Point" [])));
  Alcotest.(check (option string))
    "value record C type is layout-owned through aliases" (Some "Point")
    (value_record_c_type ~reg (ty "PointAlias" []));
  Alcotest.(check (option string))
    "value record source name is layout-owned through aliases" (Some "Point")
    (Option.map
       (fun layout -> layout.vrl_name)
       (value_record_layout_of_type ~reg (ty "PointAlias" [])));
  Alcotest.(check bool)
    "stack option inline struct is layout-owned" true
    (is_stack_option "blorp_StackOption_Int"
       (inline_struct_storage ~reg (option ty_int)));
  Alcotest.(check bool)
    "stack option alias is layout-owned" true
    (is_stack_option "blorp_StackOption_Int"
       (inline_struct_storage ~reg (ty "MaybeInt" [])));
  Alcotest.(check bool)
    "pointer type is represented explicitly" true
    (is_not_inline_struct (inline_struct_storage ~reg ty_string))

let test_generated_stack_option_get_abi_is_layout_owned () =
  let open Blorp.Core_layout_type in
  let reg = Blorp.Codegen_types.create_registry () in
  Hashtbl.replace reg.value_records "Point" ();
  Hashtbl.replace reg.type_aliases "Wide" ([], ty "Int128" []);
  Hashtbl.replace reg.type_aliases "MaybeWide" ([], option (ty "Wide" []));
  Blorp.Codegen_types.register_enum_type reg "Tiny"
    [ variant "Zero" 0; variant "One" 1 ];
  let abi ty = generated_stack_option_get_abi ~reg ty in
  let check_abi label ty option_c payload_c none_value storage_matches =
    match abi ty with
    | Some actual ->
        Alcotest.(check string)
          (label ^ " option C type") option_c actual.gsog_option_c_type;
        Alcotest.(check string)
          (label ^ " payload C type")
          payload_c actual.gsog_payload_c_type;
        Alcotest.(check string)
          (label ^ " none value") none_value actual.gsog_none_value;
        Alcotest.(check bool)
          (label ^ " payload storage")
          true
          (storage_matches actual.gsog_payload_storage)
    | None -> Alcotest.fail (label ^ " should have generated stack Option ABI")
  in
  let is_int128 = function GeneratedStackOptionInt128 -> true | _ -> false in
  let is_uint128 = function
    | GeneratedStackOptionUInt128 -> true
    | _ -> false
  in
  let is_long = function GeneratedStackOptionLong -> true | _ -> false in
  let is_value_record expected = function
    | GeneratedStackOptionValueRecord actual -> String.equal actual expected
    | _ -> false
  in
  check_abi "Int128 alias" (ty "MaybeWide" []) "blorp_StackOption_Int128"
    "__int128" "0" is_int128;
  check_abi "UInt128"
    (option (ty "UInt128" []))
    "blorp_StackOption_UInt128" "unsigned __int128" "0" is_uint128;
  check_abi "range" (option (TyRange ty_int)) "blorp_StackOption_Range" "long"
    "0" is_long;
  check_abi "enum"
    (option (ty "Tiny" []))
    "blorp_StackOption_Tiny" "long" "0" is_long;
  check_abi "value record"
    (option (ty "Point" []))
    "blorp_StackOption_Point" "Point" "{0}" (is_value_record "Point");
  Alcotest.(check bool)
    "primitive stack Option is not a generated get ABI" true
    (abi (option ty_int) = None);
  Alcotest.(check bool)
    "nullable managed Option is not a generated get ABI" true
    (abi (option ty_string) = None)

let test_option_runtime_abi_is_layout_owned () =
  let open Blorp.Core_layout_type in
  let reg = Blorp.Codegen_types.create_registry () in
  Hashtbl.replace reg.type_aliases "MaybeText" ([], option ty_string);
  Blorp.Codegen_types.register_enum_type reg "Color"
    [ variant "Red" 0; variant "Blue" 1 ];
  let describe = function
    | OptionPayloadPrimitiveStack suffix -> "prim:" ^ suffix
    | OptionPayloadNullableManaged -> "nullable"
    | OptionPayloadBoxedUnion -> "boxed"
    | OptionPayloadNoSpecialization -> "none"
  in
  Alcotest.(check string)
    "primitive stack payload ABI" "prim:int"
    (describe (option_payload_runtime_abi ~reg ty_int));
  Alcotest.(check (option string))
    "option alias payload ABI" (Some "nullable")
    (Option.map describe (option_type_runtime_abi ~reg (ty "MaybeText" [])));
  Alcotest.(check string)
    "nested option uses boxed ABI" "boxed"
    (describe (option_payload_runtime_abi ~reg (option ty_int)));
  Alcotest.(check string)
    "generated stack enum has no specialized runtime" "none"
    (describe (option_payload_runtime_abi ~reg (ty "Color" [])));
  Alcotest.(check (option string))
    "non-option type has no option ABI" None
    (Option.map describe (option_type_runtime_abi ~reg ty_int))

let test_option_equality_abi_is_layout_owned () =
  let open Blorp.Core_layout_type in
  let reg = Blorp.Codegen_types.create_registry () in
  Hashtbl.replace reg.value_records "Point" ();
  let describe = function
    | OptionEqualityStackInline { oeq_option_c_type } ->
        "stack:" ^ oeq_option_c_type
    | OptionEqualityNullableString -> "nullable:string"
    | OptionEqualityBoxedUnionRuntime fn -> "boxed:" ^ fn
    | OptionEqualityUnavailable _ -> "unavailable"
  in
  Alcotest.(check string)
    "primitive stack Option equality is inline" "stack:blorp_StackOption_Int"
    (describe (option_equality_abi ~reg (option ty_int)));
  Alcotest.(check string)
    "nullable string Option equality uses string payload comparison"
    "nullable:string"
    (describe (option_equality_abi ~reg (option ty_string)));
  Alcotest.(check string)
    "nested option equality keeps boxed-union runtime helper"
    "boxed:blorp_option_eq"
    (describe (option_equality_abi ~reg (option (option ty_int))));
  Alcotest.(check string)
    "stack value-record Option equality does not use unsafe fallback"
    "unavailable"
    (describe (option_equality_abi ~reg (option (ty "Point" []))))

let test_option_constructor_abi_is_layout_owned () =
  let open Blorp.Core_layout_type in
  let describe = function
    | OptionConstructorStackInline abi -> "stack:" ^ abi.soe_c_type
    | OptionConstructorNullableManaged -> "nullable"
    | OptionConstructorBoxedUnion -> "boxed"
    | OptionConstructorUnavailable reason -> "unavailable:" ^ reason
  in
  Alcotest.(check string)
    "primitive stack Option constructor ABI" "stack:blorp_StackOption_Int"
    (describe
       (option_constructor_abi_of_layout
          (Blorp.Core_option_layout.StackScalar
             Blorp.Core_option_layout.ScalarInt)));
  Alcotest.(check string)
    "nullable managed Option constructor ABI" "nullable"
    (describe
       (option_constructor_abi_of_layout
          Blorp.Core_option_layout.NullableManagedPointer));
  Alcotest.(check string)
    "boxed Option constructor ABI" "boxed"
    (describe
       (option_constructor_abi_of_layout
          (Blorp.Core_option_layout.BoxedUnion
             Blorp.Core_option_layout.NestedOptionPayload)));
  let unavailable_prefix = "unavailable:stack" in
  Alcotest.(check string)
    "unsupported stack Option constructor ABI is explicit" unavailable_prefix
    (let actual =
       describe
         (option_constructor_abi_of_layout
            (Blorp.Core_option_layout.StackScalar
               (Blorp.Core_option_layout.ScalarSizedInt "Int256")))
     in
     String.sub actual 0 (String.length unavailable_prefix))

let test_option_erasure_layout_is_layout_owned () =
  let open Blorp.Core_layout_type in
  let reg = Blorp.Codegen_types.create_registry () in
  let describe = function
    | OptionErasureStackValue -> "stack"
    | OptionErasureNullableManagedPointer -> "nullable"
    | OptionErasureBoxedUnion reason -> "boxed:" ^ reason
    | OptionErasureUnknownPayload name -> "unknown:" ^ name
    | OptionErasureInvalid _ -> "invalid"
  in
  Alcotest.(check string)
    "stack Option erasure fact" "stack"
    (describe (option_erasure_layout_of_type ~reg (option ty_int)));
  Alcotest.(check string)
    "nullable Option erasure fact" "nullable"
    (describe (option_erasure_layout_of_type ~reg (option ty_string)));
  Alcotest.(check string)
    "boxed Option erasure reason" "boxed:nested Option payload"
    (describe (option_erasure_layout_of_type ~reg (option (option ty_int))));
  Alcotest.(check string)
    "non-option erasure is explicit invalid" "invalid"
    (describe (option_erasure_layout_of_type ~reg ty_int))

let test_stack_result_constructor_abi_is_layout_owned () =
  let open Blorp.Core_layout_type in
  Alcotest.(check string)
    "erased stack Result constructor C type" "blorp_StackResult"
    (stack_result_constructor_abi_of_layout Blorp.Core_result_layout.StackErased)
      .src_result_c_type;
  Alcotest.(check string)
    "managed stack Result constructor C type" "blorp_StackResult"
    (stack_result_constructor_abi_of_layout
       Blorp.Core_result_layout.StackManaged)
      .src_result_c_type

let test_tensor_layout_descriptor_records_raw_scalar_policy () =
  let open Blorp.Core in
  let layout =
    Blorp.Core_layout_type.tensor_storage_layout_of_elem ty_int loc
  in
  Alcotest.(check bool)
    "Int tensor slot layout is raw i64" true
    (layout.tsl_slots = TensorRawScalarStorage TensorInt64Elements);
  Alcotest.(check bool)
    "raw scalar tensor storage is unmanaged" true
    (storage_policy_ownership layout.tsl_policy = StorageUnmanaged);
  Alcotest.(check bool)
    "raw scalar tensor storage does not retain" true
    (storage_policy_retain layout.tsl_policy = StorageNoRetain);
  Alcotest.(check bool)
    "raw scalar tensor storage does not release" true
    (storage_policy_release layout.tsl_policy = StorageNoRelease)

let test_tensor_layout_descriptor_records_boxed_policy () =
  let open Blorp.Core in
  let layout =
    Blorp.Core_layout_type.tensor_storage_layout_of_elem ty_string loc
  in
  Alcotest.(check bool)
    "String tensor slot layout is boxed" true
    (layout.tsl_slots = TensorBoxedStorage);
  Alcotest.(check bool)
    "boxed managed tensor storage is managed" true
    (storage_policy_ownership layout.tsl_policy = StorageManaged);
  Alcotest.(check bool)
    "boxed managed tensor storage retains" true
    (storage_policy_retain layout.tsl_policy = StorageArcRetain);
  Alcotest.(check bool)
    "boxed managed tensor storage releases" true
    (storage_policy_release layout.tsl_policy = StorageArcRelease)

let test_tensor_layout_descriptor_records_value_struct_policy () =
  let open Blorp.Core in
  let reg = Blorp.Codegen_types.create_registry () in
  Hashtbl.replace reg.value_records "Point" ();
  let layout =
    Blorp.Core_layout_type.tensor_storage_layout_of_elem ~reg (ty "Point" [])
      loc
  in
  Alcotest.(check bool)
    "value record tensor slot layout is inline struct" true
    (layout.tsl_slots = TensorInlineStructStorage "Point");
  Alcotest.(check bool)
    "inline struct tensor storage is unmanaged" true
    (storage_policy_ownership layout.tsl_policy = StorageUnmanaged);
  Alcotest.(check bool)
    "inline struct tensor storage does not release" true
    (storage_policy_release layout.tsl_policy = StorageNoRelease)

let test_tensor_raw_scalar_abi_is_layout_owned () =
  let open Blorp.Core in
  let f64_layout =
    Blorp.Core_layout_type.tensor_raw_scalar_abi TensorFloat64Elements
  in
  Alcotest.(check string)
    "layout-owned f64 C type" "double" f64_layout.tras_c_type;
  Alcotest.(check string)
    "layout-owned f64 storage mode" "BLORP_VECTOR_STORAGE_F64"
    f64_layout.tras_storage_mode;
  let f64 =
    Blorp.Core_layout_type.tensor_raw_scalar_abi TensorFloat64Elements
  in
  let f32 =
    Blorp.Core_layout_type.tensor_raw_scalar_abi TensorFloat32Elements
  in
  let i64 = Blorp.Core_layout_type.tensor_raw_scalar_abi TensorInt64Elements in
  Alcotest.(check string) "f64 C type" "double" f64.tras_c_type;
  Alcotest.(check string) "f64 pointer C type" "double*" f64.tras_pointer_c_type;
  Alcotest.(check string)
    "f64 runtime storage mode" "BLORP_VECTOR_STORAGE_F64" f64.tras_storage_mode;
  Alcotest.(check string) "f64 elem size" "sizeof(double)" f64.tras_elem_size;
  Alcotest.(check string) "f32 C type" "float" f32.tras_c_type;
  Alcotest.(check string)
    "f32 runtime storage mode" "BLORP_VECTOR_STORAGE_F32" f32.tras_storage_mode;
  Alcotest.(check string) "i64 C type" "long" i64.tras_c_type;
  Alcotest.(check string)
    "i64 runtime storage mode" "BLORP_VECTOR_STORAGE_I64" i64.tras_storage_mode

let test_tensor_raw_scalar_abi_from_layout () =
  let open Blorp.Core in
  let raw_layout =
    tensor_raw_scalar_storage ~elem_ty:ty_float TensorFloat64Elements
  in
  let boxed_layout =
    tensor_storage_layout ~elem_ty:ty_string TensorBoxedStorage
  in
  let packed_layout = tensor_packed_storage ~elem_ty:ty_bool InlineBytes1 in
  Alcotest.(check bool)
    "raw layout exposes scalar ABI" true
    (match
       Blorp.Core_layout_type.tensor_raw_scalar_abi_of_layout raw_layout
     with
    | Some abi -> abi.tras_c_type = "double"
    | None -> false);
  Alcotest.(check bool)
    "boxed layout has no raw scalar ABI" true
    (Blorp.Core_layout_type.tensor_raw_scalar_abi_of_layout boxed_layout = None);
  Alcotest.(check bool)
    "packed layout has no raw scalar ABI" true
    (Blorp.Core_layout_type.tensor_raw_scalar_abi_of_layout packed_layout = None)

let test_tensor_raw_scalar_kind_for_type_is_layout_owned () =
  let open Blorp.Core in
  let reg = Blorp.Codegen_types.create_registry () in
  Hashtbl.replace reg.type_aliases "Count" ([], ty_int);
  let raw_kind ty =
    Blorp.Core_layout_type.tensor_raw_scalar_kind_of_type ~reg ty
  in
  Alcotest.(check bool)
    "Float maps to raw f64 kind" true
    (raw_kind ty_float = Some TensorFloat64Elements);
  Alcotest.(check bool)
    "Float32 maps to raw f32 kind" true
    (raw_kind ty_float32 = Some TensorFloat32Elements);
  Alcotest.(check bool)
    "Int maps to raw i64 kind" true
    (raw_kind ty_int = Some TensorInt64Elements);
  Alcotest.(check bool)
    "alias to Int maps to raw i64 kind" true
    (raw_kind (ty "Count" []) = Some TensorInt64Elements);
  Alcotest.(check bool)
    "Bool values can use the raw i64 scalar ABI" true
    (Blorp.Core_layout_type.tensor_raw_scalar_accepts_type ~reg
       TensorInt64Elements ty_bool);
  Alcotest.(check bool)
    "String has no raw scalar kind" true
    (raw_kind ty_string = None)

let test_tensor_numeric_access_is_layout_owned () =
  let open Blorp.Core in
  let reg = Blorp.Codegen_types.create_registry () in
  Hashtbl.replace reg.type_aliases "Meters" ([], ty_float);
  Hashtbl.replace reg.type_aliases "Half" ([], ty "Float16" []);
  let access ty =
    Blorp.Core_layout_type.tensor_numeric_access_of_type ~reg ty
  in
  Alcotest.(check (option string))
    "Float uses f64 runtime getter" (Some "tensor_get_f64")
    (Option.map
       (fun access -> access.Blorp.Core_layout_type.tna_get_intrinsic)
       (access ty_float));
  Alcotest.(check bool)
    "alias to Float preserves f64 raw access" true
    (match access (ty "Meters" []) with
    | Some access -> (
        Blorp.Types.types_equal access.Blorp.Core_layout_type.tna_value_ty
          ty_float
        &&
        match access.tna_fast_access with
        | Some fast ->
            fast.tfna_storage_pred_intr = "tensor_is_f64_storage"
            && fast.tfna_raw_kind = TensorFloat64Elements
        | None -> false)
    | None -> false);
  Alcotest.(check bool)
    "Float16 is numeric but has no raw view yet" true
    (match access (ty "Half" []) with
    | Some access ->
        access.tna_get_intrinsic = "tensor_get_f16"
        && Option.is_none access.tna_fast_access
    | None -> false);
  Alcotest.(check bool)
    "Bool is not a numeric tensor reduction element" true
    (Option.is_none (access ty_bool))

let test_tensor_checked_get_access_is_layout_owned () =
  let reg = Blorp.Codegen_types.create_registry () in
  Hashtbl.replace reg.type_aliases "Count" ([], ty_int);
  Hashtbl.replace reg.type_aliases "TinyAlias" ([], ty "Tiny" []);
  Blorp.Codegen_types.register_enum_type reg "Tiny"
    [ variant "Zero" 0; variant "One" 1 ];
  let access ty =
    Blorp.Core_layout_type.tensor_checked_get_access_of_type ~reg ty
  in
  let intrinsic ty =
    Option.map
      (fun access -> access.Blorp.Core_layout_type.tcga_get_intrinsic)
      (access ty)
  in
  Alcotest.(check (option string))
    "Float32 checked get uses f32 runtime getter" (Some "tensor_get_f32")
    (intrinsic ty_float32);
  Alcotest.(check (option string))
    "Float16 checked get uses f16 runtime getter" (Some "tensor_get_f16")
    (intrinsic (ty "Float16" []));
  Alcotest.(check (option string))
    "alias to Int checked get uses i64 runtime getter" (Some "tensor_get_i64")
    (intrinsic (ty "Count" []));
  Alcotest.(check (option string))
    "alias to enum checked get uses i64 runtime getter" (Some "tensor_get_i64")
    (intrinsic (ty "TinyAlias" []));
  Alcotest.(check bool)
    "managed String has no scalar checked get access" true
    (Option.is_none (access ty_string))

let test_tensor_runtime_read_helper_is_layout_owned () =
  let reg = Blorp.Codegen_types.create_registry () in
  Hashtbl.replace reg.type_aliases "Count" ([], ty_int);
  Blorp.Codegen_types.register_enum_type reg "Tiny"
    [ variant "Zero" 0; variant "One" 1 ];
  let helper_name ty =
    Option.map
      (fun helper -> helper.Blorp.Core_layout_type.trrh_c_helper)
      (Blorp.Core_layout_type.tensor_runtime_read_helper_of_type ~reg ty)
  in
  Alcotest.(check (option string))
    "Float uses f64 runtime reader" (Some "blorp_vector_read_f64")
    (helper_name ty_float);
  Alcotest.(check (option string))
    "Float32 uses f32 runtime reader" (Some "blorp_vector_read_f32")
    (helper_name ty_float32);
  Alcotest.(check (option string))
    "Float16 uses f16 runtime reader" (Some "blorp_vector_read_f16")
    (helper_name (ty "Float16" []));
  Alcotest.(check (option string))
    "alias to Int uses i64 runtime reader" (Some "blorp_vector_read_i64")
    (helper_name (ty "Count" []));
  Alcotest.(check (option string))
    "enum uses i64 runtime reader" (Some "blorp_vector_read_i64")
    (helper_name (ty "Tiny" []));
  Alcotest.(check (option string))
    "managed String has no scalar runtime reader" None (helper_name ty_string)

let suite =
  [
    ( "tensor_storage",
      [
        Alcotest.test_case "primitive tensor storage is explicit" `Quick
          test_tensor_primitive_storage_is_explicit;
        Alcotest.test_case "non-word tensor storage remains distinct" `Quick
          test_tensor_non_word_storage_remains_distinct;
        Alcotest.test_case "source value layout is explicit" `Quick
          test_source_value_layout_is_explicit;
        Alcotest.test_case "source value layout rejects unknown type" `Quick
          test_source_value_layout_rejects_unknown_type;
        Alcotest.test_case "source value classification is explicit" `Quick
          test_source_value_layout_classification_is_explicit;
        Alcotest.test_case "source value release path is layout-owned" `Quick
          test_source_value_release_path_is_layout_owned;
        Alcotest.test_case "boxed storage scalar kind is explicit" `Quick
          test_boxed_storage_scalar_kind_is_explicit;
        Alcotest.test_case "destructor policy is layout-owned" `Quick
          test_destructor_policy_is_layout_owned;
        Alcotest.test_case "list element storage is layout-owned" `Quick
          test_list_element_storage_is_layout_owned;
        Alcotest.test_case "enum inline width is layout-owned" `Quick
          test_enum_inline_width_is_layout_owned;
        Alcotest.test_case "enum inline type classification is layout-owned"
          `Quick test_enum_inline_type_classification_is_layout_owned;
        Alcotest.test_case "tensor to_string runtime is layout-owned" `Quick
          test_tensor_to_string_runtime_is_layout_owned;
        Alcotest.test_case "canonical type is layout-owned" `Quick
          test_canonical_type_is_layout_owned;
        Alcotest.test_case "list type is layout-owned" `Quick
          test_list_type_is_layout_owned;
        Alcotest.test_case "hash container layout is layout-owned" `Quick
          test_hash_container_layout_is_layout_owned;
        Alcotest.test_case "record field erased storage is layout-owned" `Quick
          test_record_field_erased_storage_is_layout_owned;
        Alcotest.test_case "primitive inline width is layout-owned" `Quick
          test_primitive_inline_width_is_layout_owned;
        Alcotest.test_case "inline struct storage is layout-owned" `Quick
          test_inline_struct_storage_is_layout_owned;
        Alcotest.test_case "generated stack Option get ABI is layout-owned"
          `Quick test_generated_stack_option_get_abi_is_layout_owned;
        Alcotest.test_case "Option runtime ABI is layout-owned" `Quick
          test_option_runtime_abi_is_layout_owned;
        Alcotest.test_case "Option equality ABI is layout-owned" `Quick
          test_option_equality_abi_is_layout_owned;
        Alcotest.test_case "Option constructor ABI is layout-owned" `Quick
          test_option_constructor_abi_is_layout_owned;
        Alcotest.test_case "Option erasure layout is layout-owned" `Quick
          test_option_erasure_layout_is_layout_owned;
        Alcotest.test_case "stack Result constructor ABI is layout-owned" `Quick
          test_stack_result_constructor_abi_is_layout_owned;
        Alcotest.test_case "tensor layout records raw scalar policy" `Quick
          test_tensor_layout_descriptor_records_raw_scalar_policy;
        Alcotest.test_case "tensor layout records boxed policy" `Quick
          test_tensor_layout_descriptor_records_boxed_policy;
        Alcotest.test_case "tensor layout records value struct policy" `Quick
          test_tensor_layout_descriptor_records_value_struct_policy;
        Alcotest.test_case "tensor raw scalar ABI is layout-owned" `Quick
          test_tensor_raw_scalar_abi_is_layout_owned;
        Alcotest.test_case "tensor raw scalar ABI from layout" `Quick
          test_tensor_raw_scalar_abi_from_layout;
        Alcotest.test_case "tensor raw scalar kind for type is layout-owned"
          `Quick test_tensor_raw_scalar_kind_for_type_is_layout_owned;
        Alcotest.test_case "tensor numeric access is layout-owned" `Quick
          test_tensor_numeric_access_is_layout_owned;
        Alcotest.test_case "tensor checked-get access is layout-owned" `Quick
          test_tensor_checked_get_access_is_layout_owned;
        Alcotest.test_case "tensor runtime read helper is layout-owned" `Quick
          test_tensor_runtime_read_helper_is_layout_owned;
      ] );
  ]
