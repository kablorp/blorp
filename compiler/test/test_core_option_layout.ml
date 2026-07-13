open Blorp.Ast
module L = Blorp.Core_option_layout

let ty name args = TyNamed (name, args)
let option elem = ty "Option" [ elem ]

let meta ?(managed = []) ?(value_records = []) ?(enums = []) ?(aliases = []) ()
    =
  let has xs name = List.exists (( = ) name) xs in
  Blorp.Core_type_layout.metadata ~is_managed_name:(has managed)
    ~is_value_record_name:(has value_records) ~is_enum_name:(has enums)
    ~lookup_alias:(fun name -> List.assoc_opt name aliases)
    ()

let expect_known name expected actual =
  match actual with
  | L.Known layout -> Alcotest.(check bool) name true (layout = expected)
  | L.Unknown_named unknown ->
      Alcotest.failf "%s: expected known layout, got unknown type %s" name
        unknown
  | L.Invalid_option_type msg ->
      Alcotest.failf "%s: expected known layout, got invalid option type: %s"
        name msg

let expect_primitive_stack_abi name expected layout =
  match L.primitive_stack_abi_of_layout layout with
  | Some actual -> Alcotest.(check bool) name true (actual = expected)
  | None -> Alcotest.failf "%s: expected primitive stack ABI" name

let expect_no_primitive_stack_abi name layout =
  match L.primitive_stack_abi_of_layout layout with
  | Some _ -> Alcotest.failf "%s: expected no primitive stack ABI" name
  | None -> ()

let expect_stack_option_c_type reg name expected ty =
  Alcotest.(check (option string))
    name (Some expected)
    (Blorp.Codegen_types.stack_option_c_type ~reg ty)

let test_primitive_options_use_stack_layout () =
  let meta = meta () in
  expect_known "Option[Void]" (L.StackScalar L.ScalarVoid)
    (L.classify meta (option (ty "Void" [])));
  expect_known "Option[Int]" (L.StackScalar L.ScalarInt)
    (L.classify meta (option (ty "Int" [])));
  expect_known "Option[Int32]" (L.StackScalar (L.ScalarSizedInt "Int32"))
    (L.classify meta (option (ty "Int32" [])));
  expect_known "Option[Float]" (L.StackScalar L.ScalarFloat)
    (L.classify meta (option (ty "Float" [])));
  expect_known "Option[Float32]" (L.StackScalar L.ScalarFloat32)
    (L.classify meta (option (ty "Float32" [])));
  expect_known "Option[Bool]" (L.StackScalar L.ScalarBool)
    (L.classify meta (option (ty "Bool" [])));
  expect_known "Option[Char]" (L.StackScalar L.ScalarChar)
    (L.classify meta (option (ty "Char" [])))

let test_wide_integer_options_use_stack_layout_not_boxed_storage () =
  let meta = meta () in
  expect_known "Option[Int128]" (L.StackScalar L.ScalarInt128)
    (L.classify meta (option (ty "Int128" [])));
  expect_known "Option[UInt128]" (L.StackScalar L.ScalarUInt128)
    (L.classify meta (option (ty "UInt128" [])))

let test_managed_non_null_payloads_use_nullable_pointer_layout () =
  let meta = meta ~managed:[ "Widget" ] () in
  expect_known "Option[String]" L.NullableManagedPointer
    (L.classify meta (option (ty "String" [])));
  expect_known "Option[List[Int]]" L.NullableManagedPointer
    (L.classify meta (option (ty "List" [ ty "Int" [] ])));
  expect_known "Option[function]" L.NullableManagedPointer
    (L.classify meta
       (option
          (TyFunc
             { params = [ ty "Int" [] ]; return = ty "Int" []; is_pure = true })));
  expect_known "Option[Widget]" L.NullableManagedPointer
    (L.classify meta (option (ty "Widget" [])))

let test_nullable_managed_payload_type_is_explicit () =
  let aliases =
    [
      ("Text", ([], ty "String" [])); ("MaybeText", ([], option (ty "Text" [])));
    ]
  in
  let meta = meta ~aliases () in
  Alcotest.(check (option string))
    "Option[String] payload" (Some "String")
    (Option.map Blorp.Types.type_to_string
       (L.nullable_managed_payload_type meta (option (ty "String" []))));
  Alcotest.(check (option string))
    "Option[Text] payload" (Some "String")
    (Option.map Blorp.Types.type_to_string
       (L.nullable_managed_payload_type meta (option (ty "Text" []))));
  Alcotest.(check (option string))
    "MaybeText payload" (Some "String")
    (Option.map Blorp.Types.type_to_string
       (L.nullable_managed_payload_type meta (ty "MaybeText" [])));
  Alcotest.(check (option string))
    "Option[Int] is not nullable managed" None
    (Option.map Blorp.Types.type_to_string
       (L.nullable_managed_payload_type meta (option (ty "Int" []))));
  Alcotest.(check (option string))
    "Option[Ptr] is not nullable managed" None
    (Option.map Blorp.Types.type_to_string
       (L.nullable_managed_payload_type meta (option (ty "Ptr" []))))

let test_value_records_and_enums_use_stack_layout () =
  let meta = meta ~value_records:[ "Vec2" ] ~enums:[ "Color" ] () in
  expect_known "Option[Vec2]" (L.StackValueRecord "Vec2")
    (L.classify meta (option (ty "Vec2" [])));
  expect_known "Option[Color]" (L.StackScalar (L.ScalarEnum "Color"))
    (L.classify meta (option (ty "Color" [])))

let test_generic_and_nullable_unsafe_payloads_stay_boxed () =
  let meta = meta () in
  expect_known "Option[T]" (L.BoxedUnion L.GenericPayload)
    (L.classify meta (option (TyVar "T")));
  expect_known "Option[Ptr]" (L.BoxedUnion L.NullableUnsafePayload)
    (L.classify meta (option (ty "Ptr" [])));
  expect_known "Option[Option[Int]]" (L.BoxedUnion L.NestedOptionPayload)
    (L.classify meta (option (option (ty "Int" []))))

let test_stack_result_payloads_stay_boxed () =
  let meta = meta ~enums:[ "ConcurrencyError" ] () in
  let result_ty = ty "Result" [ ty "Int" []; ty "ConcurrencyError" [] ] in
  expect_known "Option[Result[Int, ConcurrencyError]]"
    (L.BoxedUnion L.NestedResultPayload)
    (L.classify meta (option result_ty));
  Alcotest.(check (option string))
    "Option[stack Result] is not nullable managed" None
    (Option.map Blorp.Types.type_to_string
       (L.nullable_managed_payload_type meta (option result_ty)))

let test_aliases_are_resolved_before_classification () =
  let aliases =
    [
      ("Text", ([], ty "String" []));
      ("Count", ([], ty "Int" []));
      ("MaybeCount", ([], option (ty "Int" [])));
    ]
  in
  let meta = meta ~aliases () in
  expect_known "Option[Text]" L.NullableManagedPointer
    (L.classify meta (option (ty "Text" [])));
  expect_known "Option[Count]" (L.StackScalar L.ScalarInt)
    (L.classify meta (option (ty "Count" [])));
  expect_known "Option[MaybeCount]" (L.BoxedUnion L.NestedOptionPayload)
    (L.classify meta (option (ty "MaybeCount" [])))

let test_unknown_named_payload_fails_closed () =
  match L.classify (meta ()) (option (ty "Mystery" [])) with
  | L.Unknown_named "Mystery" -> ()
  | L.Unknown_named other -> Alcotest.failf "expected Mystery, got %s" other
  | L.Known _ -> Alcotest.fail "unknown payload must not pick an option layout"
  | L.Invalid_option_type msg ->
      Alcotest.failf "expected unknown payload, got invalid option type: %s" msg

let test_non_option_type_is_invalid () =
  match L.classify (meta ()) (ty "Int" []) with
  | L.Invalid_option_type _ -> ()
  | L.Known _ -> Alcotest.fail "non-Option type must not pick an option layout"
  | L.Unknown_named name ->
      Alcotest.failf "non-Option type should be invalid, got unknown %s" name

let test_primitive_stack_abi_is_explicit () =
  let cases =
    [
      ( "Void",
        L.StackScalar L.ScalarVoid,
        L.StackOptionVoid,
        "blorp_StackOption_Void",
        "long" );
      ( "Int",
        L.StackScalar L.ScalarInt,
        L.StackOptionInt,
        "blorp_StackOption_Int",
        "long" );
      ( "Float",
        L.StackScalar L.ScalarFloat,
        L.StackOptionFloat,
        "blorp_StackOption_Float",
        "double" );
      ( "Bool",
        L.StackScalar L.ScalarBool,
        L.StackOptionBool,
        "blorp_StackOption_Bool",
        "long" );
      ( "Char",
        L.StackScalar L.ScalarChar,
        L.StackOptionChar,
        "blorp_StackOption_Char",
        "int32_t" );
      ( "Float32",
        L.StackScalar L.ScalarFloat32,
        L.StackOptionFloat32,
        "blorp_StackOption_Float32",
        "float" );
      ( "Float16",
        L.StackScalar L.ScalarFloat16,
        L.StackOptionFloat16,
        "blorp_StackOption_Float16",
        "_Float16" );
      ( "Int8",
        L.StackScalar (L.ScalarSizedInt "Int8"),
        L.StackOptionInt8,
        "blorp_StackOption_Int8",
        "int8_t" );
      ( "Int32",
        L.StackScalar (L.ScalarSizedInt "Int32"),
        L.StackOptionInt32,
        "blorp_StackOption_Int32",
        "int32_t" );
      ( "UInt8",
        L.StackScalar (L.ScalarSizedInt "UInt8"),
        L.StackOptionUInt8,
        "blorp_StackOption_UInt8",
        "uint8_t" );
      ( "UInt64",
        L.StackScalar (L.ScalarSizedInt "UInt64"),
        L.StackOptionUInt64,
        "blorp_StackOption_UInt64",
        "uint64_t" );
    ]
  in
  List.iter
    (fun (name, layout, expected_abi, expected_c_type, expected_payload_type) ->
      expect_primitive_stack_abi name expected_abi layout;
      Alcotest.(check string)
        (name ^ " C type") expected_c_type
        (L.c_type_of_primitive_stack_abi expected_abi);
      Alcotest.(check string)
        (name ^ " payload C type") expected_payload_type
        (L.primitive_stack_abi_info expected_abi).payload_c_type)
    cases

let test_unimplemented_stack_layouts_do_not_claim_primitive_abi () =
  expect_no_primitive_stack_abi "Int128" (L.StackScalar L.ScalarInt128);
  expect_no_primitive_stack_abi "UInt128" (L.StackScalar L.ScalarUInt128);
  expect_no_primitive_stack_abi "enum" (L.StackScalar (L.ScalarEnum "Color"));
  expect_no_primitive_stack_abi "range" (L.StackScalar L.ScalarRange);
  expect_no_primitive_stack_abi "value record" (L.StackValueRecord "Vec2");
  expect_no_primitive_stack_abi "nullable pointer" L.NullableManagedPointer;
  expect_no_primitive_stack_abi "boxed" (L.BoxedUnion L.GenericPayload)

let test_generated_stack_option_c_types_are_explicit () =
  let reg = Blorp.Codegen_types.create_registry () in
  Hashtbl.replace reg.value_records "Vec2" ();
  Blorp.Codegen_types.register_enum_type reg "Color"
    [
      {
        variant_name = "Red";
        variant_fields = [];
        variant_tag = 0;
        variant_loc = dummy_loc;
        variant_def_id = None;
      };
      {
        variant_name = "Blue";
        variant_fields = [];
        variant_tag = 1;
        variant_loc = dummy_loc;
        variant_def_id = None;
      };
    ];
  expect_stack_option_c_type reg "Option[Int128]" "blorp_StackOption_Int128"
    (option (ty "Int128" []));
  expect_stack_option_c_type reg "Option[UInt128]" "blorp_StackOption_UInt128"
    (option (ty "UInt128" []));
  expect_stack_option_c_type reg "Option[..#10]" "blorp_StackOption_Range"
    (option (TyRange (TyConstInt 10)));
  expect_stack_option_c_type reg "Option[Color]" "blorp_StackOption_Color"
    (option (ty "Color" []));
  expect_stack_option_c_type reg "Option[Vec2]" "blorp_StackOption_Vec2"
    (option (ty "Vec2" []))

let suite =
  [
    ( "classification",
      [
        Alcotest.test_case "primitive options use stack layout" `Quick
          test_primitive_options_use_stack_layout;
        Alcotest.test_case
          "wide integer options use stack layout, not boxed storage" `Quick
          test_wide_integer_options_use_stack_layout_not_boxed_storage;
        Alcotest.test_case
          "managed non-null payloads use nullable pointer layout" `Quick
          test_managed_non_null_payloads_use_nullable_pointer_layout;
        Alcotest.test_case "nullable managed payload type is explicit" `Quick
          test_nullable_managed_payload_type_is_explicit;
        Alcotest.test_case "value records and enums use stack layout" `Quick
          test_value_records_and_enums_use_stack_layout;
        Alcotest.test_case "generic and nullable-unsafe payloads stay boxed"
          `Quick test_generic_and_nullable_unsafe_payloads_stay_boxed;
        Alcotest.test_case "stack Result payloads stay boxed" `Quick
          test_stack_result_payloads_stay_boxed;
        Alcotest.test_case "aliases are resolved before classification" `Quick
          test_aliases_are_resolved_before_classification;
        Alcotest.test_case "unknown named payload fails closed" `Quick
          test_unknown_named_payload_fails_closed;
        Alcotest.test_case "non-Option type is invalid" `Quick
          test_non_option_type_is_invalid;
      ] );
    ( "primitive stack ABI",
      [
        Alcotest.test_case "primitive stack ABI is explicit" `Quick
          test_primitive_stack_abi_is_explicit;
        Alcotest.test_case
          "unimplemented stack layouts do not claim primitive ABI" `Quick
          test_unimplemented_stack_layouts_do_not_claim_primitive_abi;
        Alcotest.test_case "generated stack Option C types are explicit" `Quick
          test_generated_stack_option_c_types_are_explicit;
      ] );
  ]
