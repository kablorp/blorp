(** Tests for Core_list_layout: the single source of truth for List[T]
    storage layout selection. *)

open Blorp.Ast
open Blorp.Core

let loc =
  { line = 1; column = 1; end_line = 1; end_column = 1; loc_file = None }

let ty name args = TyNamed (name, args)
let list_ty elem = ty "List" [ elem ]
let ty_int = ty "Int" []
let ty_string = ty "String" []
let ty_void = ty "Void" []
let mk desc ty = { desc; ty; loc }
let cint n = mk (CLit (LitInt (Int64.of_int n))) ty_int
let cvar name ty = mk (CVar (Var.named name)) ty

let layout_width = function
  | { lsl_slots = ListPointerStorage; _ } -> 0
  | { lsl_slots = ListInlineStorage width; _ } ->
      inline_storage_width_bytes width
  | { lsl_slots = ListInlineStructStorage _; _ } -> 0

let expect_width ?reg name expected_width ty =
  Alcotest.(check int)
    name expected_width
    (layout_width (Blorp.Core_list_layout.layout_of_type ?reg ty loc))

let variant name tag =
  {
    variant_name = name;
    variant_fields = [];
    variant_tag = tag;
    variant_loc = loc;
    variant_def_id = None;
  }

let register_enum reg name max_tag =
  Blorp.Codegen_types.register_enum_type reg name
    [ variant "Zero" 0; variant "Max" max_tag ]

let test_primitive_and_dim_layout_widths () =
  let cases =
    [
      ("Bool", ty "Bool" [], 1);
      ("Char", ty "Char" [], 4);
      ("Int8", ty "Int8" [], 1);
      ("UInt8", ty "UInt8" [], 1);
      ("Int16", ty "Int16" [], 2);
      ("UInt16", ty "UInt16" [], 2);
      ("Int32", ty "Int32" [], 4);
      ("UInt32", ty "UInt32" [], 4);
      ("Float32", ty "Float32" [], 4);
      ("Int", ty_int, 8);
      ("Int64", ty "Int64" [], 8);
      ("UInt64", ty "UInt64" [], 8);
      ("Float", ty "Float" [], 8);
      ("Float16", ty "Float16" [], 2);
      ("range", TyRange (TyConstInt 16), 8);
      ("const dim", TyConstInt 16, 8);
      ("dim var", TyVar "#N", 8);
      ("dim op", TyDimOp (DimAdd, TyVar "#N", TyConstInt 1), 8);
    ]
  in
  List.iter
    (fun (name, elem_ty, width) -> expect_width name width (list_ty elem_ty))
    cases

let test_pointer_fallbacks_are_deliberate () =
  let cases =
    [
      ("String", ty_string);
      ("tuple", TyTuple [ ty_int; ty_int ]);
      ( "function",
        TyFunc { params = [ ty_int ]; return = ty_int; is_pure = true } );
      ("type var", TyVar "T");
      ("unknown named", ty "UserRecord" []);
      ("non-list", ty "Set" [ ty_int ]);
    ]
  in
  List.iter
    (fun (name, ty) ->
      let ty = if name = "non-list" then ty else list_ty ty in
      expect_width name 0 ty)
    cases

let test_enum_layout_widths_from_registry () =
  let reg = Blorp.Codegen_types.create_registry () in
  let cases =
    [
      ("Tiny", 0xFF, 1);
      ("Small", 0xFFFF, 2);
      ("Medium", 0xFFFF_FFFF, 4);
      ("Large", 0x1_0000_0000, 8);
    ]
  in
  List.iter
    (fun (name, max_tag, width) ->
      register_enum reg name max_tag;
      expect_width ~reg name width (list_ty (ty name [])))
    cases

let test_registry_aliases_are_expanded_before_layout () =
  let reg = Blorp.Codegen_types.create_registry () in
  register_enum reg "Tiny" 3;
  Hashtbl.replace reg.type_aliases "Count" ([], ty_int);
  Hashtbl.replace reg.type_aliases "CountList" ([], list_ty (ty "Count" []));
  Hashtbl.replace reg.type_aliases "TinyAlias" ([], ty "Tiny" []);
  Hashtbl.replace reg.type_aliases "Name" ([], ty_string);
  expect_width ~reg "primitive alias" 8 (list_ty (ty "Count" []));
  expect_width ~reg "outer list alias" 8 (ty "CountList" []);
  expect_width ~reg "enum alias" 1 (list_ty (ty "TinyAlias" []));
  expect_width ~reg "managed alias" 0 (list_ty (ty "Name" []))

let test_descriptor_distinguishes_slot_shape_from_element_value_layout () =
  let reg = Blorp.Codegen_types.create_registry () in
  let maybe_int = ty "Option" [ ty_int ] in
  let list_maybe_int = list_ty maybe_int in
  let layout = Blorp.Core_list_layout.layout_of_type ~reg list_maybe_int loc in
  Alcotest.(check bool)
    "stack option uses inline struct slots" true
    (layout.lsl_slots = ListInlineStructStorage "blorp_StackOption_Int");
  Alcotest.(check (option string))
    "element type is retained" (Some "Option[Int]")
    (Option.map Blorp.Types.type_to_string layout.lsl_elem_ty);
  Alcotest.(check bool)
    "source value layout is stack option struct" true
    (layout.lsl_value_layout = ListElementStackStruct "blorp_StackOption_Int");
  Alcotest.(check bool)
    "inline stack option storage needs no release" true
    (storage_policy_release layout.lsl_policy = StorageNoRelease)

let test_value_record_layout_uses_inline_struct_storage () =
  let reg = Blorp.Codegen_types.create_registry () in
  Hashtbl.replace reg.value_records "Point" ();
  let point_ty = ty "Point" [] in
  let layout =
    Blorp.Core_list_layout.layout_of_type ~reg (list_ty point_ty) loc
  in
  Alcotest.(check bool)
    "value record list uses inline struct slots" true
    (layout.lsl_slots = ListInlineStructStorage "Point");
  Alcotest.(check bool)
    "value record list values are stack structs" true
    (layout.lsl_value_layout = ListElementStackStruct "Point");
  Alcotest.(check bool)
    "inline value records need no release" true
    (storage_policy_release layout.lsl_policy = StorageNoRelease)

let test_descriptor_records_inline_scalar_policies () =
  let layout = Blorp.Core_list_layout.layout_of_type (list_ty ty_int) loc in
  Alcotest.(check bool)
    "Int list uses inline slots" true
    (layout.lsl_slots = ListInlineStorage InlineBytes8);
  Alcotest.(check bool)
    "Int list value layout is inline bits" true
    (layout.lsl_value_layout = ListElementInlineBits InlineBytes8);
  Alcotest.(check bool)
    "inline ints require no release" true
    (storage_policy_release layout.lsl_policy = StorageNoRelease);
  Alcotest.(check bool)
    "inline ints use bitwise equality policy" true
    (storage_policy_equality layout.lsl_policy = StorageEqualityBits)

let test_descriptor_records_managed_pointer_policies () =
  let layout = Blorp.Core_list_layout.layout_of_type (list_ty ty_string) loc in
  Alcotest.(check bool)
    "String list uses pointer slots" true
    (layout.lsl_slots = ListPointerStorage);
  Alcotest.(check bool)
    "String list value layout is managed pointer" true
    (layout.lsl_value_layout = ListElementPointer);
  Alcotest.(check bool)
    "managed pointer elements are ARC retained" true
    (storage_policy_retain layout.lsl_policy = StorageArcRetain);
  Alcotest.(check bool)
    "managed pointer elements are ARC released" true
    (storage_policy_release layout.lsl_policy = StorageArcRelease)

let test_descriptor_records_boxed_value_storage_policies () =
  let ty_int128 = ty "Int128" [] in
  let layout = Blorp.Core_list_layout.layout_of_type (list_ty ty_int128) loc in
  Alcotest.(check bool)
    "wide integers use pointer slots until inline wide slots exist" true
    (layout.lsl_slots = ListPointerStorage);
  Alcotest.(check bool)
    "source value is boxed for pointer storage" true
    (layout.lsl_value_layout = ListElementBoxedValue);
  Alcotest.(check bool)
    "boxed wide integer source values are not ARC retained" true
    (storage_policy_retain layout.lsl_policy = StorageNoRetain);
  Alcotest.(check bool)
    "boxed wide integer slots are ARC released" true
    (storage_policy_release layout.lsl_policy = StorageArcRelease)

let test_annotate_program_relays_registered_layouts () =
  let reg = Blorp.Codegen_types.create_registry () in
  register_enum reg "Tiny" 3;
  let tiny_ty = ty "Tiny" [] in
  let list_tiny = list_ty tiny_ty in
  let stale_literal =
    mk (CList { ll_layout = list_pointer_storage (); ll_elems = [] }) list_tiny
  in
  let stale_alloc =
    mk
      (CListAlloc { la_layout = list_pointer_storage (); la_capacity = cint 4 })
      list_tiny
  in
  let stale_handoff =
    mk
      (CListHandoff
         {
           lh_mode = BorrowFresh;
           lh_layout = list_pointer_storage ();
           lh_source = cvar "src" list_tiny;
           lh_source_var = Var.named "src";
           lh_source_ty = list_tiny;
           lh_result_ty = list_tiny;
           lh_capacity = cint 4;
           lh_result_var = Var.named "result";
           lh_len_var = Var.named "n";
           lh_out_var = Var.named "out";
           lh_body = mk CVoid ty_void;
           lh_write_order = ForwardCompacting;
         })
      list_tiny
  in
  let assert_inline_byte name expr =
    match (Blorp.Core_list_layout.annotate_expr ~reg expr).desc with
    | CList lit -> Alcotest.(check int) name 1 (layout_width lit.ll_layout)
    | CListAlloc alloc ->
        Alcotest.(check int) name 1 (layout_width alloc.la_layout)
    | CListHandoff handoff ->
        Alcotest.(check int) name 1 (layout_width handoff.lh_layout)
    | _ -> Alcotest.failf "%s: expected list layout node" name
  in
  assert_inline_byte "literal" stale_literal;
  assert_inline_byte "alloc" stale_alloc;
  assert_inline_byte "handoff" stale_handoff

let suite =
  [
    ( "layout",
      [
        Alcotest.test_case "primitive and dim widths" `Quick
          test_primitive_and_dim_layout_widths;
        Alcotest.test_case "pointer fallbacks" `Quick
          test_pointer_fallbacks_are_deliberate;
        Alcotest.test_case "enum widths" `Quick
          test_enum_layout_widths_from_registry;
        Alcotest.test_case "registry aliases" `Quick
          test_registry_aliases_are_expanded_before_layout;
        Alcotest.test_case "stack option descriptor" `Quick
          test_descriptor_distinguishes_slot_shape_from_element_value_layout;
        Alcotest.test_case "value record inline struct descriptor" `Quick
          test_value_record_layout_uses_inline_struct_storage;
        Alcotest.test_case "inline scalar descriptor" `Quick
          test_descriptor_records_inline_scalar_policies;
        Alcotest.test_case "managed pointer descriptor" `Quick
          test_descriptor_records_managed_pointer_policies;
        Alcotest.test_case "boxed value descriptor" `Quick
          test_descriptor_records_boxed_value_storage_policies;
        Alcotest.test_case "annotation relayouts nodes" `Quick
          test_annotate_program_relays_registered_layouts;
      ] );
  ]
