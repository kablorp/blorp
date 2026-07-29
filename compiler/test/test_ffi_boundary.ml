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

let expect_metadata_ok name errors =
  Alcotest.(check int) name 0 (List.length errors)

let expect_metadata_error name expected errors =
  let actual =
    match errors with
    | err :: _ -> Blorp.Ffi_boundary.metadata_validation_error_to_string err
    | [] -> "<no error>"
  in
  Alcotest.(check string) name expected actual

let foreign ?(includes = []) ?(links = []) name : foreign_func =
  {
    foreign_name = name;
    foreign_includes = includes;
    foreign_link_flags = links;
  }

let test_metadata_accepts_narrow_forms () =
  let open Blorp.Ffi_boundary in
  expect_metadata_ok "valid metadata"
    (validate_metadata
       (foreign
          ~includes:[ "sqlite_ffi.h"; "net/dns_ffi.h" ]
          ~links:
            [
              (None, "-lsqlite3");
              (Some "linux", "-lssl -lcrypto");
              ( Some "macos",
                "-I/opt/homebrew/opt/openssl@3/include \
                 -L/opt/homebrew/opt/openssl@3/lib -framework CoreFoundation" );
            ]
          "sqlite_open_v2"))

let test_metadata_rejects_bad_c_name () =
  let open Blorp.Ffi_boundary in
  expect_metadata_error "bad C name"
    "Invalid foreign C function name \"puts;system\": must contain only ASCII \
     letters, digits, and underscores"
    (validate_metadata (foreign "puts;system"))

let test_metadata_rejects_bad_include () =
  let open Blorp.Ffi_boundary in
  expect_metadata_error "bad include"
    "Invalid foreign include path \"../native.h\": must not contain empty, \
     '.', or '..' path segments"
    (validate_metadata (foreign ~includes:[ "../native.h" ] "native_call"))

let test_metadata_rejects_bad_link_token () =
  let open Blorp.Ffi_boundary in
  expect_metadata_error "bad link token"
    "Invalid foreign link flag \"-Wl,@evil\": unsupported token \"-Wl,@evil\"; \
     allowed forms are -lNAME, -LDIR, -IDIR, -framework NAME, and -pthread"
    (validate_metadata (foreign ~links:[ (None, "-Wl,@evil") ] "native_call"))

let test_metadata_rejects_bad_link_character () =
  let open Blorp.Ffi_boundary in
  expect_metadata_error "bad link character"
    "Invalid foreign link flag \"-lssl;touch\": library names may contain only \
     ASCII letters, digits, '.', '_', '-', and '+'"
    (validate_metadata (foreign ~links:[ (None, "-lssl;touch") ] "native_call"))

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
    ( "metadata",
      [
        Alcotest.test_case "accepts narrow forms" `Quick
          test_metadata_accepts_narrow_forms;
        Alcotest.test_case "rejects bad C name" `Quick
          test_metadata_rejects_bad_c_name;
        Alcotest.test_case "rejects bad include" `Quick
          test_metadata_rejects_bad_include;
        Alcotest.test_case "rejects bad link token" `Quick
          test_metadata_rejects_bad_link_token;
        Alcotest.test_case "rejects bad link character" `Quick
          test_metadata_rejects_bad_link_character;
      ] );
  ]
