open Blorp.Ast

let ty name args = TyNamed (name, args)

let meta ?(managed = []) ?(value_records = []) ?(enums = []) ?(aliases = []) ()
    =
  let has xs name = List.exists (( = ) name) xs in
  Blorp.Core_type_layout.metadata ~is_managed_name:(has managed)
    ~is_value_record_name:(has value_records) ~is_enum_name:(has enums)
    ~lookup_alias:(fun name -> List.assoc_opt name aliases)
    ()

let expect_policy name expected actual =
  Alcotest.(check bool) name true (actual = expected)

let test_default_string_and_bytes_copy () =
  let metadata = meta () in
  let open Blorp.Ffi_boundary in
  expect_policy "String copies" (DefensiveCopy string_copy_spec)
    (classify_arg ~metadata ~mode:DefaultCopyMode (ty "String" []));
  expect_policy "LiteralString copies as String"
    (DefensiveCopy string_copy_spec)
    (classify_arg ~metadata ~mode:DefaultCopyMode (ty "LiteralString" []));
  expect_policy "Bytes copies" (DefensiveCopy bytes_copy_spec)
    (classify_arg ~metadata ~mode:DefaultCopyMode (ty "Bytes" []))

let test_default_alias_to_string_copies () =
  let metadata = meta ~aliases:[ ("SafeText", ([], ty "String" [])) ] () in
  let open Blorp.Ffi_boundary in
  expect_policy "alias to String copies" (DefensiveCopy string_copy_spec)
    (classify_arg ~metadata ~mode:DefaultCopyMode (ty "SafeText" []))

let test_default_unmanaged_and_enum_pass_by_value () =
  let metadata = meta ~enums:[ "Color" ] () in
  let open Blorp.Ffi_boundary in
  expect_policy "Int scalar" ScalarByValue
    (classify_arg ~metadata ~mode:DefaultCopyMode (ty "Int" []));
  expect_policy "enum scalar" ScalarByValue
    (classify_arg ~metadata ~mode:DefaultCopyMode (ty "Color" []))

let test_default_managed_rejects () =
  let metadata = meta ~managed:[ "Message" ] () in
  let open Blorp.Ffi_boundary in
  expect_policy "List managed" (RejectedDefault ManagedValue)
    (classify_arg ~metadata ~mode:DefaultCopyMode (ty "List" [ ty "Int" [] ]));
  expect_policy "user union managed" (RejectedDefault ManagedValue)
    (classify_arg ~metadata ~mode:DefaultCopyMode (ty "Message" []))

let test_explicit_borrow_overrides_default_rejection () =
  let metadata = meta ~managed:[ "Message" ] () in
  let open Blorp.Ffi_boundary in
  expect_policy "borrowed list" ExplicitBorrow
    (classify_arg ~metadata ~mode:ExplicitBorrowMode
       (ty "List" [ ty "Int" [] ]));
  expect_policy "borrowed user union" ExplicitBorrow
    (classify_arg ~metadata ~mode:ExplicitBorrowMode (ty "Message" []))

let suite =
  [
    ( "classify_arg",
      [
        Alcotest.test_case "default String/Bytes copy" `Quick
          test_default_string_and_bytes_copy;
        Alcotest.test_case "default alias to String copies" `Quick
          test_default_alias_to_string_copies;
        Alcotest.test_case "default unmanaged/enum by value" `Quick
          test_default_unmanaged_and_enum_pass_by_value;
        Alcotest.test_case "default managed rejects" `Quick
          test_default_managed_rejects;
        Alcotest.test_case "explicit borrow overrides" `Quick
          test_explicit_borrow_overrides_default_rejection;
      ] );
  ]
