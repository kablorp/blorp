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

let test_erased_storage_box_kind_is_centralized () =
  let reg = Blorp.Codegen_types.create_registry () in
  Hashtbl.replace reg.value_records "Vec2" ();
  let classify ty = Blorp.Core_layout_type.box_kind_of_type ~reg ty dummy_loc in
  Alcotest.(check bool)
    "Float boxes through float helper" true
    (classify (ty "Float" []) = Blorp.Core.BoxFloat);
  Alcotest.(check bool)
    "Option[Int] boxes through stack struct" true
    (classify (ty "Option" [ ty "Int" [] ])
    = Blorp.Core.BoxStruct "blorp_StackOption_Int");
  Alcotest.(check bool)
    "value records box through their struct type" true
    (classify (ty "Vec2" []) = Blorp.Core.BoxStruct "Vec2");
  Alcotest.(check bool)
    "managed pointers stay pointers" true
    (classify (ty "String" []) = Blorp.Core.BoxPointer);
  Alcotest.(check bool)
    "Void boxes as an explicit unit payload" true
    (classify (ty "Void" []) = Blorp.Core.BoxVoid)

let test_erased_storage_rejects_variadic_dimension_pack () =
  let reg = Blorp.Codegen_types.create_registry () in
  match
    Blorp.Core_layout_type.box_kind_of_type ~reg (TyVarDims "#Ds") dummy_loc
  with
  | _ -> Alcotest.fail "expected variadic dimension pack to be rejected"
  | exception Blorp.Core_error.Core_error err ->
      Alcotest.(check bool)
        "explains erased-storage dimension-pack rejection" true
        (String.equal err.Blorp.Core_error.msg
           "cannot classify variadic dimension pack for erased storage")

let test_layout_type_erased_storage_carries_explicit_facts () =
  let reg = Blorp.Codegen_types.create_registry () in
  Hashtbl.replace reg.value_records "Vec2" ();
  let classify ty =
    Blorp.Core_layout_type.classify_erased_storage ~reg ty dummy_loc
  in
  let float_layout = classify (ty "Float" []) in
  Alcotest.(check bool)
    "Float storage is explicit" true
    (float_layout.storage
   = Blorp.Core_layout_type.Erased Blorp.Core_layout_type.ErasedFloat);
  Alcotest.(check bool)
    "Float erased storage has no release" true
    (Blorp.Core_layout_type.storage_release float_layout
    = Blorp.Core_layout_type.StorageNoRelease);
  Alcotest.(check bool)
    "Float erased storage release capability is layout-owned" true
    (Blorp.Core_layout_type.storage_release_or_error float_layout
    = Blorp.Core_layout_type.StorageReleaseNotNeeded);
  let string_layout = classify (ty "String" []) in
  Alcotest.(check bool)
    "String stays erased pointer" true
    (string_layout.storage
   = Blorp.Core_layout_type.Erased Blorp.Core_layout_type.ErasedPointer);
  Alcotest.(check bool)
    "String source is managed" true
    (string_layout.source_rc = Blorp.Core_layout_type.SourceManaged);
  let option_layout = classify (ty "Option" [ ty "Int" [] ]) in
  Alcotest.(check bool)
    "Option[Int] erases through stack struct" true
    (option_layout.storage
   = Blorp.Core_layout_type.Erased
       (Blorp.Core_layout_type.ErasedStruct "blorp_StackOption_Int"));
  Alcotest.(check bool)
    "Option[Int] source is non-RC but erased box is RC" true
    (option_layout.source_rc = Blorp.Core_layout_type.SourceNonRc
    && Blorp.Core_layout_type.storage_release option_layout
       = Blorp.Core_layout_type.StorageArcRelease);
  Alcotest.(check bool)
    "Option[Int] erased storage release capability is layout-owned" true
    (Blorp.Core_layout_type.storage_release_or_error option_layout
    = Blorp.Core_layout_type.StorageReleaseArc);
  let vec_layout = classify (ty "Vec2" []) in
  Alcotest.(check bool)
    "value record erases through stack struct" true
    (vec_layout.storage
   = Blorp.Core_layout_type.Erased (Blorp.Core_layout_type.ErasedStruct "Vec2")
    );
  Alcotest.(check bool)
    "value record source is non-RC but erased box is RC" true
    (vec_layout.source_rc = Blorp.Core_layout_type.SourceNonRc
    && Blorp.Core_layout_type.storage_release vec_layout
       = Blorp.Core_layout_type.StorageArcRelease)

let test_layout_type_erased_storage_maps_to_core_boxing () =
  let reg = Blorp.Codegen_types.create_registry () in
  Hashtbl.replace reg.value_records "Vec2" ();
  let classify ty =
    Blorp.Core_layout_type.classify_erased_storage ~reg ty dummy_loc
  in
  let cases =
    [
      (ty "Float" [], Blorp.Core.BoxFloat, Blorp.Core.UnboxFloat);
      (ty "Int" [], Blorp.Core.BoxPrim, Blorp.Core.UnboxPrim);
      (ty "Void" [], Blorp.Core.BoxVoid, Blorp.Core.UnboxPointer);
      (ty "String" [], Blorp.Core.BoxPointer, Blorp.Core.UnboxPointer);
      (ty "Vec2" [], Blorp.Core.BoxStruct "Vec2", Blorp.Core.UnboxStruct "Vec2");
    ]
  in
  List.iter
    (fun (source_ty, box_kind, unbox_kind) ->
      let layout = classify source_ty in
      Alcotest.(check bool)
        "box kind matches Core representation" true
        (Blorp.Core_layout_type.box_kind layout = box_kind);
      Alcotest.(check bool)
        "unbox kind matches Core representation" true
        (Blorp.Core_layout_type.unbox_kind layout = unbox_kind))
    cases

let test_layout_type_expands_aliases_for_erased_storage () =
  let reg = Blorp.Codegen_types.create_registry () in
  Hashtbl.replace reg.value_records "Vec2" ();
  Hashtbl.replace reg.type_aliases "Count" ([], ty "Int" []);
  Hashtbl.replace reg.type_aliases "MaybeCount"
    ([], ty "Option" [ ty "Count" [] ]);
  Hashtbl.replace reg.type_aliases "PointAlias" ([], ty "Vec2" []);
  let classify ty =
    Blorp.Core_layout_type.classify_erased_storage ~reg ty dummy_loc
  in
  Alcotest.(check bool)
    "alias to Int erases as primitive storage" true
    (Blorp.Core_layout_type.box_kind (classify (ty "Count" []))
    = Blorp.Core.BoxPrim);
  Alcotest.(check bool)
    "alias to stack Option erases as the stack Option struct" true
    (Blorp.Core_layout_type.box_kind (classify (ty "MaybeCount" []))
    = Blorp.Core.BoxStruct "blorp_StackOption_Int");
  Alcotest.(check bool)
    "alias to value record erases as the value record struct" true
    (Blorp.Core_layout_type.box_kind (classify (ty "PointAlias" []))
    = Blorp.Core.BoxStruct "Vec2")

let test_layout_type_answers_boxed_storage_release () =
  let reg = Blorp.Codegen_types.create_registry () in
  Hashtbl.replace reg.value_records "Vec2" ();
  Hashtbl.replace reg.type_aliases "Count" ([], ty "Int" []);
  let requires_release ty =
    Blorp.Core_layout_type.boxed_storage_requires_release_or_error ~reg ty
      dummy_loc
  in
  Alcotest.(check bool)
    "primitive boxed storage does not need release" false
    (requires_release (ty "Count" []));
  Alcotest.(check bool)
    "managed pointer boxed storage needs release" true
    (requires_release (ty "String" []));
  Alcotest.(check bool)
    "value record boxed storage needs release" true
    (requires_release (ty "Vec2" []));
  Alcotest.(check bool)
    "stack Option boxed storage needs release" true
    (requires_release (ty "Option" [ ty "Int" [] ]))

let test_layout_type_rejects_unknown_boxed_storage_release () =
  let reg = Blorp.Codegen_types.create_registry () in
  match
    Blorp.Core_layout_type.boxed_storage_requires_release_or_error ~reg
      (ty "Mystery" []) dummy_loc
  with
  | _ -> Alcotest.fail "expected unknown boxed storage release to be rejected"
  | exception Blorp.Core_error.Core_error err ->
      Alcotest.(check bool)
        "explains unknown boxed storage release" true
        (String.equal err.Blorp.Core_error.msg
           "unknown erased-storage release policy: Mystery")

let test_layout_type_derives_container_storage_policies () =
  let reg = Blorp.Codegen_types.create_registry () in
  Hashtbl.replace reg.value_records "Vec2" ();
  Hashtbl.replace reg.type_aliases "Count" ([], ty "Int" []);
  let classify ty =
    Blorp.Core_layout_type.classify_erased_storage ~reg ty dummy_loc
  in
  let string_source =
    Blorp.Core_layout_type.source_pointer_storage_policy_or_error
      (classify (ty "String" []))
  in
  Alcotest.(check bool)
    "managed source pointer policy retains and releases" true
    (string_source = Blorp.Core.StoragePolicyManagedPointer);
  let primitive_box =
    Blorp.Core_layout_type.erased_box_storage_policy_or_error
      (classify (ty "Count" []))
  in
  Alcotest.(check bool)
    "primitive erased box policy is unmanaged bits" true
    (primitive_box = Blorp.Core.StoragePolicyUnmanagedBits);
  let value_box =
    Blorp.Core_layout_type.erased_box_storage_policy_or_error
      (classify (ty "Vec2" []))
  in
  Alcotest.(check bool)
    "value-record erased box policy is managed without source retain" true
    (value_box = Blorp.Core.StoragePolicyOwnedErasedBox)

let test_layout_type_rejects_variadic_dimension_pack () =
  let reg = Blorp.Codegen_types.create_registry () in
  match
    Blorp.Core_layout_type.classify_erased_storage ~reg (TyVarDims "#Ds")
      dummy_loc
  with
  | _ -> Alcotest.fail "expected variadic dimension pack to be rejected"
  | exception Blorp.Core_error.Core_error err ->
      Alcotest.(check bool)
        "explains erased-storage dimension-pack rejection" true
        (String.equal err.Blorp.Core_error.msg
           "cannot classify variadic dimension pack for erased storage")

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
        Alcotest.test_case "erased storage box kind is centralized" `Quick
          test_erased_storage_box_kind_is_centralized;
        Alcotest.test_case "erased storage rejects variadic dimension pack"
          `Quick test_erased_storage_rejects_variadic_dimension_pack;
        Alcotest.test_case "layout type carries explicit erased-storage facts"
          `Quick test_layout_type_erased_storage_carries_explicit_facts;
        Alcotest.test_case "layout type maps to Core boxing" `Quick
          test_layout_type_erased_storage_maps_to_core_boxing;
        Alcotest.test_case "layout type expands aliases for erased storage"
          `Quick test_layout_type_expands_aliases_for_erased_storage;
        Alcotest.test_case "layout type answers boxed storage release" `Quick
          test_layout_type_answers_boxed_storage_release;
        Alcotest.test_case "layout type rejects unknown boxed storage release"
          `Quick test_layout_type_rejects_unknown_boxed_storage_release;
        Alcotest.test_case "layout type derives container storage policies"
          `Quick test_layout_type_derives_container_storage_policies;
        Alcotest.test_case "layout type rejects variadic dimension pack" `Quick
          test_layout_type_rejects_variadic_dimension_pack;
      ] );
  ]
