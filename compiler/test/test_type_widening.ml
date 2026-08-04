(** Unit tests for explicit type widening decisions. *)

open Blorp.Ast
open Blorp.Types

let check_true msg b = Alcotest.(check bool) msg true b

let test_mutable_binding_slot_preserves_semantic_type () =
  let slot = Blorp.Type_widening.mutable_binding_slot (TyConstInt 1) in
  check_true "semantic type remains singleton"
    (types_equal (Blorp.Type_widening.semantic_type slot) (TyConstInt 1));
  check_true "value type widens to Int"
    (types_equal (Blorp.Type_widening.value_type slot) ty_int);
  match Blorp.Type_widening.decision slot with
  | Blorp.Type_widening.Widen { from_ty; to_ty; reason } ->
      check_true "decision source is singleton"
        (types_equal from_ty (TyConstInt 1));
      check_true "decision target is Int" (types_equal to_ty ty_int);
      check_true "reason retained" (reason = Blorp.Type_widening.MutableBinding)
  | Blorp.Type_widening.Keep _ ->
      Alcotest.fail "expected singleton int widening"

let test_non_singleton_value_type_is_kept () =
  let slot = Blorp.Type_widening.mutable_binding_slot ty_int in
  check_true "semantic type is Int"
    (types_equal (Blorp.Type_widening.semantic_type slot) ty_int);
  check_true "value type is Int"
    (types_equal (Blorp.Type_widening.value_type slot) ty_int);
  match Blorp.Type_widening.decision slot with
  | Blorp.Type_widening.Keep ty ->
      check_true "kept decision carries value type" (types_equal ty ty_int)
  | Blorp.Type_widening.Widen _ -> Alcotest.fail "did not expect widening"

let test_numeric_operand_slot_preserves_semantic_type () =
  let semantic_ty = TyRange (TyConstInt 4) in
  let slot = Blorp.Type_widening.numeric_operand_slot Add semantic_ty in
  check_true "semantic type remains range"
    (types_equal (Blorp.Type_widening.semantic_type slot) semantic_ty);
  check_true "value type is Int"
    (types_equal (Blorp.Type_widening.value_type slot) ty_int);
  match Blorp.Type_widening.decision slot with
  | Blorp.Type_widening.Widen { from_ty; to_ty; reason } ->
      check_true "range retained as source" (types_equal from_ty semantic_ty);
      check_true "range lifted to Int" (types_equal to_ty ty_int);
      check_true "numeric reason retained"
        (reason = Blorp.Type_widening.NumericOperator Add)
  | Blorp.Type_widening.Keep _ -> Alcotest.fail "expected range-to-Int widening"

let test_method_receiver_slot_preserves_semantic_type () =
  let slot = Blorp.Type_widening.method_receiver_slot (TyConstInt 1) in
  check_true "semantic singleton retained"
    (types_equal (Blorp.Type_widening.semantic_type slot) (TyConstInt 1));
  check_true "value type widens to Int"
    (types_equal (Blorp.Type_widening.value_type slot) ty_int);
  match Blorp.Type_widening.decision slot with
  | Blorp.Type_widening.Widen { reason; _ } ->
      check_true "method receiver reason retained"
        (reason = Blorp.Type_widening.MethodReceiver)
  | Blorp.Type_widening.Keep _ ->
      Alcotest.fail "expected method receiver widening"

let test_variadic_dimension_pack_is_kept () =
  let ty = TyVarDims "#Ds" in
  let slot = Blorp.Type_widening.numeric_operand_slot Add ty in
  check_true "semantic type is pack"
    (types_equal (Blorp.Type_widening.semantic_type slot) ty);
  check_true "value type is pack"
    (types_equal (Blorp.Type_widening.value_type slot) ty);
  match Blorp.Type_widening.decision slot with
  | Blorp.Type_widening.Keep kept_ty ->
      check_true "kept decision carries pack type" (types_equal kept_ty ty)
  | Blorp.Type_widening.Widen _ ->
      Alcotest.fail "variadic dim packs are not scalar int values"

let test_scalar_int_value_type_lifts_only_scalar_dims () =
  check_true "singleton int is scalar Int value"
    (types_equal
       (Blorp.Type_widening.scalar_int_value_type (TyConstInt 3))
       ty_int);
  check_true "range is scalar Int value"
    (types_equal
       (Blorp.Type_widening.scalar_int_value_type (TyRange (TyConstInt 8)))
       ty_int);
  check_true "variadic dim pack is not scalar"
    (types_equal
       (Blorp.Type_widening.scalar_int_value_type (TyVarDims "#Ds"))
       (TyVarDims "#Ds"))

let test_argument_slot_only_widens_open_value_metas () =
  let sess = Blorp.Session.create () in
  Blorp.Session.with_current sess (fun () ->
      let value_meta = Blorp.Types.fresh_meta ~origin:"T" () in
      let dim_meta = Blorp.Types.fresh_meta ~origin:"#N" () in
      let value_slot =
        Blorp.Type_widening.argument_slot ~param_ty:value_meta
          ~arg_ty:(TyConstInt 1)
      in
      let dim_slot =
        Blorp.Type_widening.argument_slot ~param_ty:dim_meta
          ~arg_ty:(TyConstInt 1)
      in
      check_true "value meta argument widens singleton"
        (types_equal (Blorp.Type_widening.value_type value_slot) ty_int);
      check_true "dimension meta argument keeps singleton proof"
        (types_equal (Blorp.Type_widening.value_type dim_slot) (TyConstInt 1)))

let test_argument_target_slot_preserves_semantic_type () =
  let slot =
    Blorp.Type_widening.argument_target_slot ~param_ty:ty_int (TyConstInt 1)
  in
  check_true "semantic singleton retained"
    (types_equal (Blorp.Type_widening.semantic_type slot) (TyConstInt 1));
  check_true "value type uses parameter target"
    (types_equal (Blorp.Type_widening.value_type slot) ty_int);
  match Blorp.Type_widening.decision slot with
  | Blorp.Type_widening.Widen { reason; _ } ->
      check_true "argument reason retained"
        (reason = Blorp.Type_widening.ArgumentSlot)
  | Blorp.Type_widening.Keep _ ->
      Alcotest.fail "expected target argument widening"

let test_argument_target_slot_keeps_type_variable_targets () =
  let semantic_ty = ty_char in
  let slot =
    Blorp.Type_widening.argument_target_slot ~param_ty:(TyVar "T") semantic_ty
  in
  check_true "semantic char retained"
    (types_equal (Blorp.Type_widening.semantic_type slot) semantic_ty);
  check_true "value type stays concrete"
    (types_equal (Blorp.Type_widening.value_type slot) semantic_ty);
  match Blorp.Type_widening.decision slot with
  | Blorp.Type_widening.Keep kept_ty ->
      check_true "kept decision carries semantic type"
        (types_equal kept_ty semantic_ty)
  | Blorp.Type_widening.Widen _ ->
      Alcotest.fail "type variable targets should not erase argument type"

let test_argument_target_slot_keeps_incompatible_concrete_targets () =
  let semantic_ty = ty_string in
  let slot =
    Blorp.Type_widening.argument_target_slot ~param_ty:ty_int semantic_ty
  in
  check_true "semantic string retained"
    (types_equal (Blorp.Type_widening.semantic_type slot) semantic_ty);
  check_true "value type stays string"
    (types_equal (Blorp.Type_widening.value_type slot) semantic_ty);
  match Blorp.Type_widening.decision slot with
  | Blorp.Type_widening.Keep kept_ty ->
      check_true "kept decision carries semantic type"
        (types_equal kept_ty semantic_ty)
  | Blorp.Type_widening.Widen _ ->
      Alcotest.fail "incompatible targets should remain type mismatches"

let test_collection_element_slot_records_collection_kind () =
  let slot =
    Blorp.Type_widening.collection_element_slot Blorp.Type_widening.ListLiteral
      (TyConstInt 1)
  in
  match Blorp.Type_widening.decision slot with
  | Blorp.Type_widening.Widen { reason; _ } ->
      check_true "collection kind retained"
        (reason
       = Blorp.Type_widening.CollectionElement Blorp.Type_widening.ListLiteral)
  | Blorp.Type_widening.Keep _ ->
      Alcotest.fail "expected list element singleton widening"

let test_collection_element_target_slot_preserves_target_type () =
  let slot =
    Blorp.Type_widening.collection_element_target_slot
      Blorp.Type_widening.VectorLiteral
      ~target_ty:(TyNamed ("Int32", []))
      (TyConstInt 1)
  in
  check_true "semantic singleton retained"
    (types_equal (Blorp.Type_widening.semantic_type slot) (TyConstInt 1));
  check_true "value type uses collection target"
    (types_equal (Blorp.Type_widening.value_type slot) (TyNamed ("Int32", [])));
  match Blorp.Type_widening.decision slot with
  | Blorp.Type_widening.Widen { reason; _ } ->
      check_true "collection kind retained"
        (reason
       = Blorp.Type_widening.CollectionElement Blorp.Type_widening.VectorLiteral
        )
  | Blorp.Type_widening.Keep _ ->
      Alcotest.fail "expected target collection element widening"

let test_bitwise_operand_target_slot_preserves_target_type () =
  let slot =
    Blorp.Type_widening.bitwise_operand_target_slot
      ~target_ty:(TyNamed ("UInt8", []))
      (TyConstInt 1)
  in
  check_true "semantic singleton retained"
    (types_equal (Blorp.Type_widening.semantic_type slot) (TyConstInt 1));
  check_true "value type uses bitwise target"
    (types_equal (Blorp.Type_widening.value_type slot) (TyNamed ("UInt8", [])));
  match Blorp.Type_widening.decision slot with
  | Blorp.Type_widening.Widen { reason; _ } ->
      check_true "bitwise reason retained"
        (reason = Blorp.Type_widening.BitwiseOperator)
  | Blorp.Type_widening.Keep _ ->
      Alcotest.fail "expected target bitwise operand widening"

let suite =
  [
    ( "decisions",
      [
        Alcotest.test_case "mutable binding slot preserves semantic type" `Quick
          test_mutable_binding_slot_preserves_semantic_type;
        Alcotest.test_case "non-singleton value type is kept" `Quick
          test_non_singleton_value_type_is_kept;
        Alcotest.test_case "numeric operand slot preserves semantic type" `Quick
          test_numeric_operand_slot_preserves_semantic_type;
        Alcotest.test_case "method receiver slot preserves semantic type" `Quick
          test_method_receiver_slot_preserves_semantic_type;
        Alcotest.test_case "variadic dimension pack is kept" `Quick
          test_variadic_dimension_pack_is_kept;
        Alcotest.test_case "scalar int value type is explicit" `Quick
          test_scalar_int_value_type_lifts_only_scalar_dims;
        Alcotest.test_case "argument slot respects dimension metas" `Quick
          test_argument_slot_only_widens_open_value_metas;
        Alcotest.test_case "argument target slot uses parameter type" `Quick
          test_argument_target_slot_preserves_semantic_type;
        Alcotest.test_case "argument target slot keeps type variables" `Quick
          test_argument_target_slot_keeps_type_variable_targets;
        Alcotest.test_case "argument target slot keeps incompatible targets"
          `Quick test_argument_target_slot_keeps_incompatible_concrete_targets;
        Alcotest.test_case "collection element slot records collection kind"
          `Quick test_collection_element_slot_records_collection_kind;
        Alcotest.test_case "collection element target slot uses target type"
          `Quick test_collection_element_target_slot_preserves_target_type;
        Alcotest.test_case "bitwise target slot uses target type" `Quick
          test_bitwise_operand_target_slot_preserves_target_type;
      ] );
  ]
