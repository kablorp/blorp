open Blorp.Ast
module L = Blorp.Core_result_layout

let ty name args = TyNamed (name, args)
let result ok err = ty "Result" [ ok; err ]

let meta ?(enums = []) ?(managed = []) ?(value_records = []) ?(aliases = []) ()
    =
  let has xs name = List.exists (( = ) name) xs in
  L.metadata ~is_enum_name:(has enums) ~is_managed_name:(has managed)
    ~is_value_record_name:(has value_records)
    ~lookup_alias:(fun name -> List.assoc_opt name aliases)
    ()

let expect_known name expected actual =
  match actual with
  | L.Known layout -> Alcotest.(check bool) name true (layout = expected)
  | L.BoxedUnion _ ->
      Alcotest.failf "%s: expected known stack layout, got boxed union" name
  | L.Unknown_named unknown ->
      Alcotest.failf "%s: expected known layout, got unknown type %s" name
        unknown
  | L.Invalid_result_type msg ->
      Alcotest.failf "%s: expected known layout, got invalid Result type: %s"
        name msg

let expect_boxed name actual =
  match actual with
  | L.BoxedUnion _ -> ()
  | L.Known _ -> Alcotest.failf "%s: expected boxed Result layout" name
  | L.Unknown_named unknown ->
      Alcotest.failf "%s: expected boxed layout, got unknown type %s" name
        unknown
  | L.Invalid_result_type msg ->
      Alcotest.failf "%s: expected boxed layout, got invalid Result type: %s"
        name msg

let expect_stack_result_c_type reg name expected ty =
  Alcotest.(check (option string))
    name (Some expected)
    (Blorp.Codegen_types.stack_result_c_type ~reg ty)

let test_immediate_payloads_use_stack_layout () =
  let meta = meta ~enums:[ "Color" ] () in
  expect_known "Result[Int, Bool]" L.StackErased
    (L.classify meta (result (ty "Int" []) (ty "Bool" [])));
  expect_known "Result[Int32, UInt64]" L.StackErased
    (L.classify meta (result (ty "Int32" []) (ty "UInt64" [])));
  expect_known "Result[Color, Int]" L.StackErased
    (L.classify meta (result (ty "Color" []) (ty "Int" [])));
  expect_known "Result[..#10, Int]" L.StackErased
    (L.classify meta (result (TyRange (TyConstInt 10)) (ty "Int" [])))

let test_managed_and_wide_payloads_use_managed_stack_layout () =
  let meta = meta ~value_records:[ "Vec2" ] () in
  expect_known "Result[Int, String]" L.StackManaged
    (L.classify meta (result (ty "Int" []) (ty "String" [])));
  expect_known "Result[String, Int]" L.StackManaged
    (L.classify meta (result (ty "String" []) (ty "Int" [])));
  expect_known "Result[(Int, Int), Int]" L.StackManaged
    (L.classify meta
       (result (TyTuple [ ty "Int" []; ty "Int" [] ]) (ty "Int" [])));
  expect_known "Result[Int128, Int]" L.StackManaged
    (L.classify meta (result (ty "Int128" []) (ty "Int" [])));
  expect_known "Result[UInt128, Int]" L.StackManaged
    (L.classify meta (result (ty "UInt128" []) (ty "Int" [])));
  expect_known "Result[Vec2, Int]" L.StackManaged
    (L.classify meta (result (ty "Vec2" []) (ty "Int" [])))

let test_release_free_float_payloads_use_erased_stack_layout () =
  let meta = meta () in
  expect_known "Result[Float, Int]" L.StackErased
    (L.classify meta (result (ty "Float" []) (ty "Int" [])));
  expect_known "Result[Float32, Bool]" L.StackErased
    (L.classify meta (result (ty "Float32" []) (ty "Bool" [])))

let test_generic_payloads_stay_boxed () =
  let meta = meta () in
  expect_boxed "Result[T, Int]"
    (L.classify meta (result (TyVar "T") (ty "Int" [])));
  expect_boxed "Result[Int, T]"
    (L.classify meta (result (ty "Int" []) (TyVar "T")))

let test_aliases_are_resolved_before_classification () =
  let aliases =
    [
      ("Count", ([], ty "Int" []));
      ("Text", ([], ty "String" []));
      ("CountResult", ([], result (ty "Count" []) (ty "Bool" [])));
    ]
  in
  let meta = meta ~aliases () in
  expect_known "Result[Count, Bool]" L.StackErased
    (L.classify meta (result (ty "Count" []) (ty "Bool" [])));
  expect_known "CountResult" L.StackErased
    (L.classify meta (ty "CountResult" []));
  expect_known "Result[Text, Bool]" L.StackManaged
    (L.classify meta (result (ty "Text" []) (ty "Bool" [])))

let test_codegen_stack_result_c_type_is_explicit () =
  let reg = Blorp.Codegen_types.create_registry () in
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
  expect_stack_result_c_type reg "Result[Int, Bool]" "blorp_StackResult"
    (result (ty "Int" []) (ty "Bool" []));
  expect_stack_result_c_type reg "Result[Color, Int]" "blorp_StackResult"
    (result (ty "Color" []) (ty "Int" []));
  expect_stack_result_c_type reg "Result[Int, String]" "blorp_StackResult"
    (result (ty "Int" []) (ty "String" []))

let suite =
  [
    ( "classification",
      [
        Alcotest.test_case "immediate payloads use stack layout" `Quick
          test_immediate_payloads_use_stack_layout;
        Alcotest.test_case "managed and wide payloads use managed stack layout"
          `Quick test_managed_and_wide_payloads_use_managed_stack_layout;
        Alcotest.test_case "release-free float payloads use erased stack layout"
          `Quick test_release_free_float_payloads_use_erased_stack_layout;
        Alcotest.test_case "generic payloads stay boxed" `Quick
          test_generic_payloads_stay_boxed;
        Alcotest.test_case "aliases are resolved before classification" `Quick
          test_aliases_are_resolved_before_classification;
      ] );
    ( "codegen",
      [
        Alcotest.test_case "stack Result C type is explicit" `Quick
          test_codegen_stack_result_c_type_is_explicit;
      ] );
  ]
