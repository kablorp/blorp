open Blorp.Ast

let ty name args = TyNamed (name, args)

let meta ?(managed = []) ?(value_records = []) ?(enums = []) ?(aliases = []) ()
    =
  let has xs name = List.exists (( = ) name) xs in
  Blorp.Core_type_layout.metadata ~is_managed_name:(has managed)
    ~is_value_record_name:(has value_records) ~is_enum_name:(has enums)
    ~lookup_alias:(fun name -> List.assoc_opt name aliases)
    ()

let expect_known_layout name expected actual =
  match actual with
  | Blorp.Core_type_layout.Known layout ->
      Alcotest.(check bool) name true (layout = expected)
  | Blorp.Core_type_layout.Unknown_named unknown ->
      Alcotest.failf "%s: expected known layout, got unknown type %s" name
        unknown
  | Blorp.Core_type_layout.Invalid_value_type msg ->
      Alcotest.failf "%s: expected known layout, got invalid type: %s" name msg

let expect_release name expected meta ty =
  match Blorp.Core_type_layout.classify meta ty with
  | Blorp.Core_type_layout.Known layout ->
      Alcotest.(check bool)
        name expected
        (layout.release = Blorp.Core_type_layout.ArcRelease)
  | Blorp.Core_type_layout.Unknown_named unknown ->
      Alcotest.failf "%s: unknown type %s" name unknown
  | Blorp.Core_type_layout.Invalid_value_type message ->
      Alcotest.failf "%s: invalid type: %s" name message

let expect_retain name expected meta ty =
  match Blorp.Core_type_layout.classify meta ty with
  | Blorp.Core_type_layout.Known layout ->
      Alcotest.(check bool)
        name expected
        (layout.retain = Blorp.Core_type_layout.ArcRetain)
  | Blorp.Core_type_layout.Unknown_named unknown ->
      Alcotest.failf "%s: unknown type %s" name unknown
  | Blorp.Core_type_layout.Invalid_value_type message ->
      Alcotest.failf "%s: invalid type: %s" name message

let test_builtin_layout_is_single_source_of_truth () =
  let open Blorp.Core_type_layout in
  let check_builtin name expected =
    match builtin_layout name with
    | Some actual -> Alcotest.(check bool) name true (actual = expected)
    | None -> Alcotest.failf "expected builtin layout for %s" name
  in
  check_builtin "String"
    { ownership = Managed; retain = ArcRetain; release = ArcRelease };
  check_builtin "TcpStream"
    { ownership = Managed; retain = ArcRetain; release = ArcRelease };
  check_builtin "TcpListener"
    { ownership = Managed; retain = ArcRetain; release = ArcRelease };
  check_builtin "std/net/websocket::WebSocketSession"
    { ownership = Managed; retain = ArcRetain; release = ArcRelease };
  check_builtin "FallibleStream"
    { ownership = Managed; retain = ArcRetain; release = ArcRelease };
  check_builtin "std/stream::FallibleStream"
    { ownership = Managed; retain = ArcRetain; release = ArcRelease };
  check_builtin "Ptr"
    {
      ownership = Unmanaged;
      retain = NoRetainNeeded;
      release = NoReleaseNeeded;
    };
  check_builtin "std/fs::FileReader"
    {
      ownership = Unmanaged;
      retain = NoRetainNeeded;
      release = NoReleaseNeeded;
    };
  check_builtin "std/net/udp::UdpSocket"
    {
      ownership = Unmanaged;
      retain = NoRetainNeeded;
      release = NoReleaseNeeded;
    };
  Alcotest.(check bool)
    "unknown builtin layout" true
    (builtin_layout "UserRecord" = None)

let test_builtin_managed_type_has_arc_release () =
  let expected =
    {
      Blorp.Core_type_layout.ownership = Blorp.Core_type_layout.Managed;
      retain = Blorp.Core_type_layout.ArcRetain;
      release = Blorp.Core_type_layout.ArcRelease;
    }
  in
  expect_known_layout "String layout" expected
    (Blorp.Core_type_layout.classify (meta ()) (ty "String" []));
  expect_known_layout "TcpStream layout" expected
    (Blorp.Core_type_layout.classify (meta ()) (ty "TcpStream" []));
  expect_known_layout "TcpListener layout" expected
    (Blorp.Core_type_layout.classify (meta ()) (ty "TcpListener" []));
  expect_known_layout "WebSocketSession layout" expected
    (Blorp.Core_type_layout.classify (meta ())
       (ty "std/net/websocket::WebSocketSession" []))

let test_builtin_unmanaged_type_needs_no_release () =
  let expected =
    {
      Blorp.Core_type_layout.ownership = Blorp.Core_type_layout.Unmanaged;
      retain = Blorp.Core_type_layout.NoRetainNeeded;
      release = Blorp.Core_type_layout.NoReleaseNeeded;
    }
  in
  expect_known_layout "Int layout" expected
    (Blorp.Core_type_layout.classify (meta ()) (ty "Int" []));
  expect_known_layout "FileReader layout" expected
    (Blorp.Core_type_layout.classify (meta ()) (ty "std/fs::FileReader" []));
  expect_known_layout "UdpSocket layout" expected
    (Blorp.Core_type_layout.classify (meta ()) (ty "std/net/udp::UdpSocket" []))

let test_debug_heap_classification_uses_layout_metadata () =
  let meta =
    meta ~managed:[ "UserRecord" ] ~value_records:[ "Vec2" ] ~enums:[ "Color" ]
      ~aliases:
        [
          ("Meters", ([], ty "Float" []));
          ("VecAlias", ([], ty "Vec2" []));
          ("MaybeInt", ([], ty "Option" [ ty "Int" [] ]));
        ]
      ()
  in
  let is_heap ty =
    match Blorp.Core_type_layout.classify_debug_heap_value meta ty with
    | Blorp.Core_type_layout.DebugHeapValue -> true
    | Blorp.Core_type_layout.DebugStackValue -> false
    | Blorp.Core_type_layout.DebugHeapUnknownNamed name ->
        Alcotest.failf "unexpected unknown type in debug heap classifier: %s"
          name
    | Blorp.Core_type_layout.DebugHeapInvalidValueType msg ->
        Alcotest.failf "unexpected invalid type in debug heap classifier: %s"
          msg
  in
  Alcotest.(check bool) "Int is not heap" false (is_heap (ty "Int" []));
  Alcotest.(check bool) "Float32 is not heap" false (is_heap (ty "Float32" []));
  Alcotest.(check bool) "UInt64 is not heap" false (is_heap (ty "UInt64" []));
  Alcotest.(check bool) "enum is not heap" false (is_heap (ty "Color" []));
  Alcotest.(check bool)
    "value record is not heap" false
    (is_heap (ty "Vec2" []));
  Alcotest.(check bool)
    "alias to value record is not heap" false
    (is_heap (ty "VecAlias" []));
  Alcotest.(check bool)
    "alias to stack Option is not heap" false
    (is_heap (ty "MaybeInt" []));
  Alcotest.(check bool) "String is heap" true (is_heap (ty "String" []));
  Alcotest.(check bool)
    "List is heap" true
    (is_heap (ty "List" [ ty "Int" [] ]));
  Alcotest.(check bool)
    "heap record is heap" true
    (is_heap (ty "UserRecord" []))

let test_option_int_stack_layout_needs_no_release () =
  let expected =
    {
      Blorp.Core_type_layout.ownership = Blorp.Core_type_layout.Unmanaged;
      retain = Blorp.Core_type_layout.NoRetainNeeded;
      release = Blorp.Core_type_layout.NoReleaseNeeded;
    }
  in
  expect_known_layout "Option[Int] layout" expected
    (Blorp.Core_type_layout.classify (meta ()) (ty "Option" [ ty "Int" [] ]));
  expect_release "Option[Int] release" false (meta ())
    (ty "Option" [ ty "Int" [] ])

let test_result_int_bool_stack_layout_needs_no_source_release () =
  let result_int_bool = ty "Result" [ ty "Int" []; ty "Bool" [] ] in
  expect_release "Result[Int, Bool] source value does not require release" false
    (meta ()) result_int_bool

let test_managed_stack_result_layout_requires_source_release () =
  let result_int_string = ty "Result" [ ty "Int" []; ty "String" [] ] in
  expect_release "Result[Int, String] source value requires release" true
    (meta ()) result_int_string;
  expect_retain "Result[Int, String] source value requires retain" true
    (meta ()) result_int_string

let test_primitive_stack_options_need_no_source_release () =
  let cases =
    [
      ("Option[Float]", ty "Option" [ ty "Float" [] ]);
      ("Option[Bool]", ty "Option" [ ty "Bool" [] ]);
      ("Option[Char]", ty "Option" [ ty "Char" [] ]);
      ("Option[Float32]", ty "Option" [ ty "Float32" [] ]);
      ("Option[Float16]", ty "Option" [ ty "Float16" [] ]);
      ("Option[Int32]", ty "Option" [ ty "Int32" [] ]);
      ("Option[UInt8]", ty "Option" [ ty "UInt8" [] ]);
    ]
  in
  List.iter
    (fun (name, option_ty) ->
      expect_release
        (name ^ " source value does not require release")
        false (meta ()) option_ty)
    cases

let test_generated_stack_options_need_no_source_release () =
  let meta = meta ~value_records:[ "Vec2" ] ~enums:[ "Color" ] () in
  let cases =
    [
      ("Option[Int128]", ty "Option" [ ty "Int128" [] ]);
      ("Option[UInt128]", ty "Option" [ ty "UInt128" [] ]);
      ("Option[..#10]", ty "Option" [ TyRange (TyConstInt 10) ]);
      ("Option[Color]", ty "Option" [ ty "Color" [] ]);
      ("Option[Vec2]", ty "Option" [ ty "Vec2" [] ]);
    ]
  in
  List.iter
    (fun (name, option_ty) ->
      expect_release
        (name ^ " source value does not require release")
        false meta option_ty)
    cases

let test_option_string_stays_managed () =
  expect_release "Option[String] release" true (meta ())
    (ty "Option" [ ty "String" [] ])

let test_heap_record_with_primitive_fields_still_has_arc_release () =
  let expected =
    {
      Blorp.Core_type_layout.ownership = Blorp.Core_type_layout.Managed;
      retain = Blorp.Core_type_layout.ArcRetain;
      release = Blorp.Core_type_layout.ArcRelease;
    }
  in
  expect_known_layout "Point layout" expected
    (Blorp.Core_type_layout.classify
       (meta ~managed:[ "Point" ] ())
       (ty "Point" []))

let test_value_record_needs_no_release () =
  let expected =
    {
      Blorp.Core_type_layout.ownership = Blorp.Core_type_layout.Unmanaged;
      retain = Blorp.Core_type_layout.NoRetainNeeded;
      release = Blorp.Core_type_layout.NoReleaseNeeded;
    }
  in
  expect_known_layout "Vec2 layout" expected
    (Blorp.Core_type_layout.classify
       (meta ~value_records:[ "Vec2" ] ())
       (ty "Vec2" []))

let test_alias_inherits_release_capability () =
  let aliases =
    [ ("Text", ([], ty "String" [])); ("Count", ([], ty "Int" [])) ]
  in
  let meta = meta ~aliases () in
  expect_release "Text alias requires release" true meta (ty "Text" []);
  expect_release "Count alias does not require release" false meta
    (ty "Count" [])

let test_builtin_retain_capability_tracks_arc_layout () =
  expect_retain "String retain" true (meta ()) (ty "String" []);
  expect_retain "Int retain" false (meta ()) (ty "Int" [])

let test_registry_managed_type_requires_destructor_policy () =
  let reg = Blorp.Codegen_types.create_registry () in
  let open Blorp.Codegen_types in
  Blorp.Codegen_types.register_managed_type reg "Widget"
    { managed_kind = ManagedHeapRecord; destructor = ArcReleaseOnly };
  Alcotest.(check bool)
    "Widget is managed" true
    (Blorp.Codegen_types.is_managed_type reg "Widget");
  match Blorp.Codegen_types.managed_type_info reg "Widget" with
  | Some { managed_kind = ManagedHeapRecord; destructor = ArcReleaseOnly } -> ()
  | Some _ -> Alcotest.fail "Widget had the wrong managed type policy"
  | None -> Alcotest.fail "Widget was not registered"

let test_unknown_named_type_remains_invalid_layout () =
  let expect_unknown name =
    match Blorp.Core_type_layout.classify (meta ()) (ty name []) with
    | Unknown_named actual when String.equal actual name -> ()
    | Known _ -> Alcotest.failf "expected %s to be unknown" name
    | Unknown_named other -> Alcotest.failf "expected %s, got %s" name other
    | Invalid_value_type msg ->
        Alcotest.failf "expected unknown type, got invalid: %s" msg
  in
  expect_unknown "Mystery";
  expect_unknown "T"

let suite =
  [
    ( "classification",
      [
        Alcotest.test_case "builtin managed type has ARC release" `Quick
          test_builtin_managed_type_has_arc_release;
        Alcotest.test_case "builtin layout is single source of truth" `Quick
          test_builtin_layout_is_single_source_of_truth;
        Alcotest.test_case "builtin unmanaged type needs no release" `Quick
          test_builtin_unmanaged_type_needs_no_release;
        Alcotest.test_case "debug heap classification uses layout metadata"
          `Quick test_debug_heap_classification_uses_layout_metadata;
        Alcotest.test_case "Option[Int] stack layout needs no release" `Quick
          test_option_int_stack_layout_needs_no_release;
        Alcotest.test_case
          "Result[Int, Bool] stack layout needs no source release" `Quick
          test_result_int_bool_stack_layout_needs_no_source_release;
        Alcotest.test_case "managed stack Result layout requires source release"
          `Quick test_managed_stack_result_layout_requires_source_release;
        Alcotest.test_case "primitive stack options need no source release"
          `Quick test_primitive_stack_options_need_no_source_release;
        Alcotest.test_case "generated stack options need no source release"
          `Quick test_generated_stack_options_need_no_source_release;
        Alcotest.test_case "Option[String] stays managed" `Quick
          test_option_string_stays_managed;
        Alcotest.test_case
          "heap record with primitive fields still has ARC release" `Quick
          test_heap_record_with_primitive_fields_still_has_arc_release;
        Alcotest.test_case "value record needs no release" `Quick
          test_value_record_needs_no_release;
        Alcotest.test_case "alias inherits release capability" `Quick
          test_alias_inherits_release_capability;
        Alcotest.test_case "builtin retain capability tracks ARC layout" `Quick
          test_builtin_retain_capability_tracks_arc_layout;
        Alcotest.test_case "registry managed type requires destructor policy"
          `Quick test_registry_managed_type_requires_destructor_policy;
        Alcotest.test_case "unknown named type remains invalid layout" `Quick
          test_unknown_named_type_remains_invalid_layout;
      ] );
  ]
