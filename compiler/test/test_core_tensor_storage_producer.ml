module P = Blorp.Core_tensor_storage_producer
open Blorp.Core

let string_of_rule rule =
  P.fold_storage_rule rule
    ~known_result:(fun () -> "known-result")
    ~preserves_arg:(fun index -> Printf.sprintf "preserves-arg%d" index)

let rule_for_builtin name =
  Option.map P.storage_rule (P.of_call_kind (CKBuiltin name))

let check_rule name expected =
  Alcotest.(check (option string))
    name (Some expected)
    (Option.map string_of_rule (rule_for_builtin name))

let check_no_rule name =
  Alcotest.(check (option string))
    name None
    (Option.map string_of_rule (rule_for_builtin name))

let test_known_result_layout_producers () =
  check_rule "blorp_vector_new_i64" "known-result";
  check_rule "blorp_vector_new_fill_f32" "known-result";
  check_rule "blorp_matrix_new_fill_f64" "known-result";
  check_rule "blorp_tensor_new_packed" "known-result";
  check_rule "blorp_tensor_matmul_float32" "known-result";
  check_rule "blorp_simd_vector_add_f64" "known-result"

let test_preserving_producers_name_source_argument () =
  check_rule "blorp_assert_shape" "preserves-arg0";
  check_rule "blorp_tensor_slice_row" "preserves-arg0";
  check_rule "blorp_vector_abs" "preserves-arg0";
  check_rule "blorp_vector_scalar_op_float_cow" "preserves-arg1";
  check_rule "blorp_vector_op_cow" "preserves-arg2"

let test_unknown_runtime_calls_do_not_imply_storage () =
  check_no_rule "blorp_vector_new_fill";
  check_no_rule "blorp_vector_get_opt";
  check_no_rule "user_defined_tensor_func"

let preserved_source_index name =
  match rule_for_builtin name with
  | Some rule ->
      P.fold_storage_rule rule
        ~known_result:(fun () -> None)
        ~preserves_arg:(fun index -> Some index)
  | None -> None

let test_only_builtin_calls_can_be_tensor_producers () =
  Alcotest.(check bool)
    "user call" true
    (Option.is_none (P.of_call_kind (CKUser ("make_tensor", None))));
  Alcotest.(check bool)
    "foreign call" true
    (Option.is_none
       (P.of_call_kind
          (CKForeign
             { fc_c_name = "c_tensor"; fc_arg_passing = ForeignBorrowArgs })));
  Alcotest.(check bool)
    "intrinsic call" true
    (Option.is_none (P.of_call_kind (CKIntrinsic "tensor_alloc")))

let test_source_arg_index_is_explicit () =
  Alcotest.(check (option int))
    "arg0" (Some 0)
    (preserved_source_index "blorp_assert_shape");
  Alcotest.(check (option int))
    "arg1" (Some 1)
    (preserved_source_index "blorp_vector_scalar_op_float_cow");
  Alcotest.(check (option int))
    "arg2" (Some 2)
    (preserved_source_index "blorp_vector_op_cow")

let suite =
  [
    ( "storage_contracts",
      [
        Alcotest.test_case "known result layout producers" `Quick
          test_known_result_layout_producers;
        Alcotest.test_case "preserving producers name source argument" `Quick
          test_preserving_producers_name_source_argument;
        Alcotest.test_case "unknown calls have no storage contract" `Quick
          test_unknown_runtime_calls_do_not_imply_storage;
        Alcotest.test_case "only builtin calls can be tensor producers" `Quick
          test_only_builtin_calls_can_be_tensor_producers;
        Alcotest.test_case "source arg index" `Quick
          test_source_arg_index_is_explicit;
      ] );
  ]
