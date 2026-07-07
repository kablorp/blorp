(** Tests for Core_ownership call contracts. *)

open Blorp.Core_ownership
open Blorp.Core

let check_contract label expected actual =
  (match actual with
  | Some contract -> (
      match validate_contract contract with
      | [] -> ()
      | violations ->
          Alcotest.failf "%s has invalid ownership contract: %s" label
            (String.concat "; "
               (List.map string_of_contract_violation violations)))
  | None -> ());
  Alcotest.(check bool) label true (actual = Some expected)

let check_strategy label expected actual =
  Alcotest.(check bool) label true (actual = Some expected)

let check_single_violation label expected actual =
  Alcotest.(check bool) label true (actual = [ expected ])

let test_arg_mode_semantics () =
  let check label expected actual =
    Alcotest.(check bool) label expected actual
  in
  check "Borrow preserves caller" true (arg_preserves_caller Borrow);
  check "Retain preserves caller" true (arg_preserves_caller Retain);
  check "Consume consumes caller" true (arg_consumes_caller Consume);
  check "CowConsume consumes caller" true (arg_consumes_caller CowConsume);
  check "Transfer consumes caller" true (arg_consumes_caller Transfer);
  check "Borrow may alias result" true (arg_allows_borrowed_result_alias Borrow);
  check "Retain may alias result" true (arg_allows_borrowed_result_alias Retain);
  check "Transfer may not alias result" false
    (arg_allows_borrowed_result_alias Transfer)

let test_alias_contract_must_reference_existing_arg () =
  let contract = { args = [ Borrow ]; result = ReturnAliasOfArg 1 } in
  check_single_violation "alias index in range"
    (Alias_index_out_of_range { index = 1; arg_count = 1 })
    (validate_contract contract);
  Alcotest.(check bool)
    "contract not well-formed" false
    (contract_is_well_formed contract)

let test_alias_contract_must_reference_preserved_arg () =
  let check mode =
    let contract = { args = [ mode ]; result = ReturnAliasOfArg 0 } in
    check_single_violation
      ("alias rejects " ^ string_of_arg_mode mode)
      (Alias_of_consumed_arg { index = 0; mode })
      (validate_contract contract)
  in
  List.iter check [ Consume; CowConsume; Transfer ]

let test_valid_alias_contract_is_well_formed () =
  let borrowed = { args = [ Borrow; Consume ]; result = ReturnAliasOfArg 0 } in
  let retained = { args = [ Retain ]; result = ReturnAliasOfArg 0 } in
  Alcotest.(check bool) "borrowed alias" true (contract_is_well_formed borrowed);
  Alcotest.(check bool) "retained alias" true (contract_is_well_formed retained)

let test_borrowed_result_must_have_preserved_anchor () =
  let invalid = { args = [ Consume; Transfer ]; result = ReturnBorrowed } in
  let valid = { args = [ Consume; Borrow ]; result = ReturnBorrowed } in
  check_single_violation "borrowed result anchor"
    Borrowed_result_without_preserved_arg
    (validate_contract invalid);
  Alcotest.(check bool)
    "borrowed result with anchor" true
    (contract_is_well_formed valid)

let test_list_len_borrows () =
  check_contract "list_len"
    { args = [ Borrow ]; result = ReturnPrimitive }
    (intrinsic_contract "list_len" 1)

let test_math_round_intrinsic_borrows () =
  check_contract "math_round"
    { args = [ Borrow ]; result = ReturnPrimitive }
    (intrinsic_contract "math_round" 1)

let test_list_get_returns_alias () =
  check_contract "list_get"
    { args = [ Borrow; Borrow ]; result = ReturnAliasOfArg 0 }
    (intrinsic_contract "list_get" 2)

let test_list_get_unchecked_returns_alias () =
  check_contract "list_get_unchecked"
    { args = [ Borrow; Borrow ]; result = ReturnAliasOfArg 0 }
    (intrinsic_contract "list_get_unchecked" 2)

let test_list_ensure_capacity_cow_consumes () =
  check_contract "list_ensure_capacity"
    { args = [ CowConsume; Borrow ]; result = ReturnOwned }
    (intrinsic_contract "list_ensure_capacity" 2)

let test_list_reuse_alloc_cow_consumes () =
  check_contract "list_reuse_alloc"
    { args = [ CowConsume; Borrow ]; result = ReturnOwned }
    (intrinsic_contract "list_reuse_alloc" 2)

let test_hash_collection_reuse_alloc_cow_consumes () =
  check_contract "set_reuse_alloc"
    { args = [ CowConsume; Borrow ]; result = ReturnOwned }
    (intrinsic_contract "set_reuse_alloc" 2);
  check_contract "dict_reuse_alloc"
    { args = [ CowConsume; Borrow ]; result = ReturnOwned }
    (intrinsic_contract "dict_reuse_alloc" 2)

let test_list_append_owned_transfers_element () =
  check_contract "blorp_list_append_owned"
    { args = [ CowConsume; Transfer ]; result = ReturnOwned }
    (builtin_contract "blorp_list_append_owned" 2)

let test_list_append_retains_element () =
  check_contract "blorp_list_append"
    { args = [ CowConsume; Retain ]; result = ReturnOwned }
    (builtin_contract "blorp_list_append" 2)

let test_list_new_allocates_owned_list () =
  check_contract "blorp_list_new"
    { args = [ Borrow ]; result = ReturnOwned }
    (builtin_contract "blorp_list_new" 1)

let test_channel_new_allocates_owned_channel () =
  check_contract "blorp_channel_new"
    { args = [ Borrow ]; result = ReturnOwned }
    (builtin_contract "blorp_channel_new" 1)

let test_channel_send_status_retains_payloads () =
  check_contract "blorp_channel_try_send_status"
    { args = [ Borrow; Retain ]; result = ReturnPrimitive }
    (builtin_contract "blorp_channel_try_send_status" 2);
  check_contract "blorp_channel_send_timeout_status"
    { args = [ Borrow; Retain; Borrow ]; result = ReturnPrimitive }
    (builtin_contract "blorp_channel_send_timeout_status" 3)

let test_channel_send_attempt_retains_payloads () =
  check_contract "blorp_channel_try_send_attempt"
    { args = [ Borrow; Retain ]; result = ReturnOwned }
    (builtin_contract "blorp_channel_try_send_attempt" 2);
  check_contract "blorp_channel_send_timeout_attempt"
    { args = [ Borrow; Retain; Borrow ]; result = ReturnOwned }
    (builtin_contract "blorp_channel_send_timeout_attempt" 3)

let test_channel_try_recv_attempt_borrows_channel () =
  check_contract "blorp_channel_try_recv_attempt"
    { args = [ Borrow ]; result = ReturnOwned }
    (builtin_contract "blorp_channel_try_recv_attempt" 1)

let test_channel_recv_timeout_attempt_borrows_channel () =
  check_contract "blorp_channel_recv_timeout_attempt"
    { args = [ Borrow; Borrow ]; result = ReturnOwned }
    (builtin_contract "blorp_channel_recv_timeout_attempt" 2)

let check_consuming_finalizer name =
  check_contract name
    { args = [ Consume ]; result = ReturnVoid }
    (builtin_contract name 1)

let test_file_close_finalizers_consume_handles () =
  List.iter check_consuming_finalizer
    [
      "blorp_file_close_reader";
      "blorp_file_close_writer";
      "blorp_file_close_appender";
      "blorp_file_close_read_writer";
      "blorp_file_close_read_appender";
    ]

let test_tcp_close_finalizers_consume_handles () =
  List.iter check_consuming_finalizer
    [ "blorp_tcp_close_listener"; "blorp_tcp_close_stream" ]

let test_directory_close_finalizer_consumes_handle () =
  check_consuming_finalizer "blorp_dir_close"

let test_network_close_finalizers_consume_handles () =
  List.iter check_consuming_finalizer
    [
      "blorp_tls_close_session";
      "blorp_websocket_close_session";
      "blorp_udp_close_socket";
    ]

let test_tcp_connection_sources_borrow_listener () =
  let expected = { args = [ Borrow ]; result = ReturnOwned } in
  check_contract "blorp_tcp_connections_stop_on_error_raw" expected
    (builtin_contract "blorp_tcp_connections_stop_on_error_raw" 1);
  check_contract "blorp_tcp_connections_continue_on_error_raw" expected
    (builtin_contract "blorp_tcp_connections_continue_on_error_raw" 1)

let test_tcp_value_helpers_have_runtime_contracts () =
  check_contract "blorp_tcp_ipv4_raw"
    { args = [ Borrow; Borrow; Borrow; Borrow ]; result = ReturnOwned }
    (builtin_contract "blorp_tcp_ipv4_raw" 4);
  List.iter
    (fun name ->
      check_contract name
        { args = [ Borrow ]; result = ReturnOwned }
        (builtin_contract name 1))
    [
      "blorp_tcp_parse_ip_raw";
      "blorp_tcp_dns_name_raw";
      "blorp_tcp_interface_scope_raw";
      "blorp_tcp_port_raw";
      "blorp_tcp_ip_text_raw";
      "blorp_tcp_dns_name_text_raw";
      "blorp_tcp_interface_scope_text_raw";
    ];
  check_contract "blorp_tcp_port_value_raw"
    { args = [ Borrow ]; result = ReturnPrimitive }
    (builtin_contract "blorp_tcp_port_value_raw" 1)

let test_network_capability_queries_return_primitives () =
  let expected = { args = []; result = ReturnPrimitive } in
  check_contract "blorp_tls_native_available_raw" expected
    (builtin_contract "blorp_tls_native_available_raw" 0);
  check_contract "blorp_websocket_native_available_raw" expected
    (builtin_contract "blorp_websocket_native_available_raw" 0)

let test_scheduler_runtime_builtins_have_contracts () =
  check_contract "blorp_sleep"
    { args = [ Borrow ]; result = ReturnVoid }
    (builtin_contract "blorp_sleep" 1);
  check_contract "blorp_yield_now"
    { args = []; result = ReturnVoid }
    (builtin_contract "blorp_yield_now" 0);
  check_contract "blorp_test_cancel_after_parked"
    { args = [ Borrow ]; result = ReturnPrimitive }
    (builtin_contract "blorp_test_cancel_after_parked" 1);
  List.iter
    (fun name ->
      check_contract name
        { args = []; result = ReturnPrimitive }
        (builtin_contract name 0))
    [
      "blorp_test_task_window_pending_cleanup_probe";
      "blorp_test_task_join_slot_probe";
      "blorp_test_fiber_created_schedule_probe";
      "blorp_test_timer_waiter_identity_probe";
      "blorp_test_wait_ready_to_park_probe";
      "blorp_test_fiber_lifecycle_ready_to_park_probe";
      "blorp_test_fiber_cancel_before_park_probe";
      "blorp_test_current_timer_wait_install_probe";
      "blorp_test_timeout_arithmetic_probe";
      "blorp_test_cooperative_checkpoint_probe";
      "blorp_test_tls_state_probe";
      "blorp_test_websocket_state_probe";
    ]

let test_time_runtime_builtins_have_contracts () =
  List.iter
    (fun name ->
      check_contract name
        { args = []; result = ReturnPrimitive }
        (builtin_contract name 0))
    [ "blorp_now_us"; "blorp_time_now" ];
  List.iter
    (fun name ->
      check_contract name
        { args = [ Borrow ]; result = ReturnPrimitive }
        (builtin_contract name 1))
    [
      "blorp_time_to_year";
      "blorp_time_to_month";
      "blorp_time_to_day";
      "blorp_time_to_hour";
      "blorp_time_to_minute";
      "blorp_time_to_second";
      "blorp_time_to_weekday";
      "blorp_time_from_iso";
      "blorp_time_parse_rfc3339";
    ];
  check_contract "blorp_time_from_parts"
    {
      args = [ Borrow; Borrow; Borrow; Borrow; Borrow; Borrow ];
      result = ReturnPrimitive;
    }
    (builtin_contract "blorp_time_from_parts" 6);
  check_contract "blorp_time_format"
    { args = [ Borrow; Borrow ]; result = ReturnOwned }
    (builtin_contract "blorp_time_format" 2);
  check_contract "blorp_time_parse"
    { args = [ Borrow; Borrow ]; result = ReturnPrimitive }
    (builtin_contract "blorp_time_parse" 2)

let test_memory_runtime_builtins_have_contracts () =
  check_contract "blorp_get_mem_stats"
    { args = []; result = ReturnOwned }
    (builtin_contract "blorp_get_mem_stats" 0);
  check_contract "blorp_reset_mem_stats"
    { args = []; result = ReturnVoid }
    (builtin_contract "blorp_reset_mem_stats" 0);
  check_contract "blorp_print_live_object_summary"
    { args = []; result = ReturnVoid }
    (builtin_contract "blorp_print_live_object_summary" 0)

let test_process_signal_runtime_builtins_have_contracts () =
  List.iter
    (fun name ->
      check_contract name
        { args = []; result = ReturnPrimitive }
        (builtin_contract name 0))
    [
      "blorp_signal_hangup";
      "blorp_signal_interrupt";
      "blorp_signal_terminate";
      "blorp_signal_user1";
      "blorp_signal_user2";
    ];
  check_contract "blorp_signal_on"
    { args = [ Borrow; Retain ]; result = ReturnVoid }
    (builtin_contract "blorp_signal_on" 2);
  check_contract "blorp_signal_received"
    { args = [ Borrow ]; result = ReturnPrimitive }
    (builtin_contract "blorp_signal_received" 1);
  check_contract "blorp_signal_raise"
    { args = [ Borrow ]; result = ReturnVoid }
    (builtin_contract "blorp_signal_raise" 1)

let test_random_runtime_builtins_have_contracts () =
  check_contract "blorp_seed_random"
    { args = [ Borrow ]; result = ReturnVoid }
    (builtin_contract "blorp_seed_random" 1);
  check_contract "blorp_random_int"
    { args = [ Borrow; Borrow ]; result = ReturnPrimitive }
    (builtin_contract "blorp_random_int" 2);
  check_contract "blorp_random_float"
    { args = []; result = ReturnPrimitive }
    (builtin_contract "blorp_random_float" 0);
  check_contract "blorp_crypto_random_bytes"
    { args = [ Borrow ]; result = ReturnOwned }
    (builtin_contract "blorp_crypto_random_bytes" 1)

let test_hash_runtime_builtins_have_contracts () =
  List.iter
    (fun name ->
      check_contract name
        { args = [ Borrow ]; result = ReturnPrimitive }
        (builtin_contract name 1))
    [
      "blorp_hash";
      "blorp_hash_int";
      "blorp_hash_string";
      "blorp_hash_float";
      "blorp_hash_bytes";
      "blorp_crc32";
      "blorp_crc32_bytes";
    ];
  check_contract "blorp_hash_combine"
    { args = [ Borrow; Borrow ]; result = ReturnPrimitive }
    (builtin_contract "blorp_hash_combine" 2);
  List.iter
    (fun name ->
      check_contract name
        { args = [ Borrow ]; result = ReturnOwned }
        (builtin_contract name 1))
    [
      "blorp_sha256";
      "blorp_md5";
      "blorp_sha1";
      "blorp_sha512";
      "blorp_sha256_bytes";
      "blorp_md5_bytes";
      "blorp_sha1_bytes";
      "blorp_sha512_bytes";
    ];
  check_contract "blorp_hmac_sha256"
    { args = [ Borrow; Borrow ]; result = ReturnOwned }
    (builtin_contract "blorp_hmac_sha256" 2)

let test_regex_runtime_builtins_have_contracts () =
  List.iter
    (fun name ->
      check_contract name
        { args = [ Borrow; Borrow ]; result = ReturnOwned }
        (builtin_contract name 2))
    [ "blorp_regex_test"; "blorp_regex_find"; "blorp_regex_find_all" ];
  check_contract "blorp_regex_replace_all"
    { args = [ Borrow; Borrow; Borrow ]; result = ReturnOwned }
    (builtin_contract "blorp_regex_replace_all" 3)

let test_checked_numeric_option_builtins_return_stack_options () =
  let expected = { args = [ Borrow; Borrow ]; result = ReturnPrimitive } in
  check_contract "blorp_option_div_int" expected
    (builtin_contract "blorp_option_div_int" 2);
  check_contract "blorp_option_mod_int" expected
    (builtin_contract "blorp_option_mod_int" 2)

let test_console_io_runtime_builtins_return_owned_strings () =
  List.iter
    (fun name ->
      check_contract name
        { args = []; result = ReturnOwned }
        (builtin_contract name 0))
    [ "blorp_read_all"; "blorp_read_line"; "blorp_read_line_or_empty" ];
  List.iter
    (fun name ->
      check_contract name
        { args = [ Borrow ]; result = ReturnOwned }
        (builtin_contract name 1))
    [ "blorp_input"; "blorp_input_or_empty" ]

let test_scalar_math_passthrough_builtins_return_primitives () =
  List.iter
    (fun name ->
      check_contract name
        { args = [ Borrow ]; result = ReturnPrimitive }
        (builtin_contract name 1))
    [
      "sqrt";
      "sin";
      "cos";
      "tan";
      "floor";
      "ceil";
      "asin";
      "acos";
      "atan";
      "sinh";
      "cosh";
      "tanh";
      "asinh";
      "acosh";
      "atanh";
      "exp";
      "exp2";
      "log";
      "log2";
      "log10";
      "log1p";
      "expm1";
      "cbrt";
      "trunc";
    ];
  List.iter
    (fun name ->
      check_contract name
        { args = [ Borrow; Borrow ]; result = ReturnPrimitive }
        (builtin_contract name 2))
    [ "pow"; "atan2"; "hypot"; "fmod"; "copysign" ];
  check_contract "fma"
    { args = [ Borrow; Borrow; Borrow ]; result = ReturnPrimitive }
    (builtin_contract "fma" 3)

let test_scalar_runtime_builtins_return_primitives () =
  List.iter
    (fun name ->
      check_contract name
        { args = [ Borrow ]; result = ReturnPrimitive }
        (builtin_contract name 1))
    [
      "blorp_abs";
      "blorp_float_abs";
      "blorp_round";
      "blorp_is_nan";
      "blorp_is_inf";
      "blorp_is_finite";
      "blorp_black_box_int";
      "blorp_black_box_float";
    ];
  List.iter
    (fun name ->
      check_contract name
        { args = [ Borrow; Borrow ]; result = ReturnPrimitive }
        (builtin_contract name 2))
    [ "blorp_min"; "blorp_max"; "blorp_float_min"; "blorp_float_max" ];
  List.iter
    (fun name ->
      check_contract name
        { args = []; result = ReturnPrimitive }
        (builtin_contract name 0))
    [ "blorp_infinity"; "blorp_neg_infinity"; "blorp_nan_value" ]

let test_operation_result_bridges_use_manifested_ownership () =
  let arg_mode_of_runtime_ownership = function
    | Blorp.Operation_result_metadata.ArgBorrow -> Borrow
    | Blorp.Operation_result_metadata.ArgRetain -> Retain
    | Blorp.Operation_result_metadata.ArgConsume -> Consume
    | Blorp.Operation_result_metadata.ArgCowConsume -> CowConsume
    | Blorp.Operation_result_metadata.ArgTransfer -> Transfer
  in
  List.iter
    (fun (bridge : Blorp.Operation_result_metadata.result_bridge) ->
      let expected =
        {
          args = List.map arg_mode_of_runtime_ownership bridge.arguments;
          result = ReturnOwned;
        }
      in
      check_contract bridge.builtin_name expected
        (builtin_contract bridge.builtin_name (List.length bridge.arguments)))
    Blorp.Operation_result_metadata.result_bridges

let test_fallible_stream_sources_use_manifested_ownership () =
  let arg_mode_of_runtime_ownership = function
    | Blorp.Operation_result_metadata.ArgBorrow -> Borrow
    | Blorp.Operation_result_metadata.ArgRetain -> Retain
    | Blorp.Operation_result_metadata.ArgConsume -> Consume
    | Blorp.Operation_result_metadata.ArgCowConsume -> CowConsume
    | Blorp.Operation_result_metadata.ArgTransfer -> Transfer
  in
  List.iter
    (fun (source : Blorp.Operation_result_metadata.fallible_stream_source) ->
      let expected =
        {
          args = List.map arg_mode_of_runtime_ownership source.arguments;
          result = ReturnOwned;
        }
      in
      check_contract source.builtin_name expected
        (builtin_contract source.builtin_name (List.length source.arguments)))
    Blorp.Operation_result_metadata.fallible_stream_sources

let test_fallible_stream_terminals_use_manifested_ownership () =
  let arg_mode_of_runtime_ownership = function
    | Blorp.Operation_result_metadata.ArgBorrow -> Borrow
    | Blorp.Operation_result_metadata.ArgRetain -> Retain
    | Blorp.Operation_result_metadata.ArgConsume -> Consume
    | Blorp.Operation_result_metadata.ArgCowConsume -> CowConsume
    | Blorp.Operation_result_metadata.ArgTransfer -> Transfer
  in
  List.iter
    (fun (terminal : Blorp.Operation_result_metadata.fallible_stream_terminal)
       ->
      let expected =
        {
          args = List.map arg_mode_of_runtime_ownership terminal.arguments;
          result = ReturnOwned;
        }
      in
      let arity = List.length terminal.arguments in
      check_contract terminal.builtin_name expected
        (builtin_contract terminal.builtin_name arity);
      let entry =
        List.find
          (fun entry -> entry.builtin_name = terminal.builtin_name)
          builtin_contract_table
      in
      Alcotest.(check (list int))
        (terminal.builtin_name ^ " void boxed args")
        terminal.void_boxed_args entry.builtin_void_boxed_args)
    Blorp.Operation_result_metadata.fallible_stream_terminals

let test_fixed_constructors_allocate_owned_fixed () =
  let expected = { args = [ Borrow; Borrow; Borrow ]; result = ReturnOwned } in
  check_contract "blorp_fixed_new" expected
    (builtin_contract "blorp_fixed_new" 3);
  check_contract "blorp_fixed_from_int" expected
    (builtin_contract "blorp_fixed_from_int" 3);
  check_contract "blorp_fixed_to_string"
    { args = [ Borrow ]; result = ReturnOwned }
    (builtin_contract "blorp_fixed_to_string" 1)

let test_custom_dict_set_constructors_synthesize_callbacks_in_codegen () =
  check_contract "blorp_dict_new_custom"
    { args = []; result = ReturnOwned }
    (builtin_contract "blorp_dict_new_custom" 0);
  check_contract "blorp_set_new_custom"
    { args = []; result = ReturnOwned }
    (builtin_contract "blorp_set_new_custom" 0)

let test_dict_with_capacity_allocates_owned_dict () =
  let expected = { args = [ Borrow ]; result = ReturnOwned } in
  List.iter
    (fun name -> check_contract name expected (builtin_contract name 1))
    [
      "blorp_dict_with_capacity";
      "blorp_dict_with_capacity_string";
      "blorp_dict_with_capacity_float";
      "blorp_dict_with_capacity_custom";
    ]

let test_dict_remove_cow_consumes_dict () =
  check_contract "blorp_dict_remove"
    { args = [ CowConsume; Borrow ]; result = ReturnOwned }
    (builtin_contract "blorp_dict_remove" 2)

let test_dict_insert_retains_payloads () =
  check_contract "blorp_dict_insert"
    { args = [ CowConsume; Retain; Retain ]; result = ReturnOwned }
    (builtin_contract "blorp_dict_insert" 3)

let test_dict_get_nullable_borrows_dict_and_key () =
  check_contract "blorp_dict_get_nullable"
    { args = [ Borrow; Borrow ]; result = ReturnOwned }
    (builtin_contract "blorp_dict_get_nullable" 2)

let test_vector_get_nullable_borrows_vector_and_index () =
  check_contract "blorp_vector_get_nullable"
    { args = [ Borrow; Borrow ]; result = ReturnOwned }
    (builtin_contract "blorp_vector_get_nullable" 2)

let test_vector_get_or_returns_borrowed_value () =
  check_contract "blorp_vector_get_or"
    { args = [ Borrow; Borrow; Borrow ]; result = ReturnBorrowed }
    (builtin_contract "blorp_vector_get_or" 3)

let test_legacy_vector_set_borrows_value () =
  check_contract "blorp_vector_set"
    { args = [ Borrow; Borrow; Borrow ]; result = ReturnVoid }
    (builtin_contract "blorp_vector_set" 3)

let test_matrix_get_nullable_borrows_matrix_and_indices () =
  check_contract "blorp_matrix_get_nullable"
    { args = [ Borrow; Borrow; Borrow ]; result = ReturnOwned }
    (builtin_contract "blorp_matrix_get_nullable" 3)

let test_dict_slot_writes_transfer_payloads () =
  check_contract "dict_set_key_at"
    { args = [ Borrow; Borrow; Transfer ]; result = ReturnVoid }
    (intrinsic_contract "dict_set_key_at" 3);
  check_contract "dict_set_value_at"
    { args = [ Borrow; Borrow; Transfer ]; result = ReturnVoid }
    (intrinsic_contract "dict_set_value_at" 3)

let test_dict_retain_release_helpers () =
  check_contract "dict_retain_key_for"
    { args = [ Borrow; Retain ]; result = ReturnVoid }
    (intrinsic_contract "dict_retain_key_for" 2);
  check_contract "dict_retain_value_for"
    { args = [ Borrow; Retain ]; result = ReturnVoid }
    (intrinsic_contract "dict_retain_value_for" 2);
  check_contract "dict_release_value_for"
    { args = [ Borrow; Borrow ]; result = ReturnVoid }
    (intrinsic_contract "dict_release_value_for" 2)

let test_list_set_owned_transfers_element () =
  check_contract "list_set_owned"
    { args = [ Borrow; Borrow; Transfer ]; result = ReturnVoid }
    (intrinsic_contract "list_set_owned" 3)

let test_list_handoff_set_owned_transfers_element () =
  check_contract "list_handoff_set_owned"
    { args = [ Borrow; Borrow; Transfer ]; result = ReturnVoid }
    (intrinsic_contract "list_handoff_set_owned" 3)

let test_list_handoff_set_source_slot_borrows_source () =
  check_contract "list_handoff_set_source_slot"
    { args = [ Borrow; Borrow; Borrow; Borrow ]; result = ReturnVoid }
    (intrinsic_contract "list_handoff_set_source_slot" 4)

let test_list_swap_slots_borrows_list_and_indices () =
  check_contract "list_swap_slots"
    { args = [ Borrow; Borrow; Borrow ]; result = ReturnVoid }
    (intrinsic_contract "list_swap_slots" 3)

let test_list_retain_for_retains_value () =
  check_contract "list_retain_for"
    { args = [ Borrow; Retain ]; result = ReturnVoid }
    (intrinsic_contract "list_retain_for" 2)

let test_set_add_retains_key () =
  check_contract "blorp_set_add"
    { args = [ CowConsume; Retain ]; result = ReturnOwned }
    (builtin_contract "blorp_set_add" 2)

let test_set_alloc_entry_transfers_key () =
  check_contract "set_alloc_entry"
    { args = [ Transfer ]; result = ReturnOwned }
    (intrinsic_contract "set_alloc_entry" 1)

let test_set_retain_key_for_retains_key () =
  check_contract "set_retain_key_for"
    { args = [ Borrow; Retain ]; result = ReturnVoid }
    (intrinsic_contract "set_retain_key_for" 2)

let test_string_concat_many_consumes_parts () =
  check_contract "blorp_string_concat_many"
    { args = [ Borrow; Consume; Consume; Consume ]; result = ReturnOwned }
    (builtin_contract "blorp_string_concat_many" 4)

let test_string_eq_borrows () =
  check_contract "blorp_string_eq"
    { args = [ Borrow; Borrow ]; result = ReturnPrimitive }
    (builtin_contract "blorp_string_eq" 2)

let test_unicode_case_borrows_and_returns_owned () =
  let expected = { args = [ Borrow ]; result = ReturnOwned } in
  check_contract "blorp_upper" expected (builtin_contract "blorp_upper" 1);
  check_contract "blorp_lower" expected (builtin_contract "blorp_lower" 1)

let test_utf8_runtime_builtins_borrow_inputs_and_return_owned () =
  let expected = { args = [ Borrow ]; result = ReturnOwned } in
  check_contract "blorp_encode_utf8" expected
    (builtin_contract "blorp_encode_utf8" 1);
  check_contract "blorp_decode_utf8" expected
    (builtin_contract "blorp_decode_utf8" 1);
  check_contract "blorp_decode_utf8_nullable" expected
    (builtin_contract "blorp_decode_utf8_nullable" 1)

let test_string_find_byte_from_borrows () =
  check_contract "string_find_byte_from"
    { args = [ Borrow; Borrow; Borrow ]; result = ReturnPrimitive }
    (intrinsic_contract "string_find_byte_from" 3)

let test_string_copy_bytes_borrows () =
  check_contract "string_copy_bytes"
    { args = [ Borrow; Borrow; Borrow; Borrow; Borrow ]; result = ReturnVoid }
    (intrinsic_contract "string_copy_bytes" 5)

let test_checked_get_borrows_and_aliases () =
  check_contract "blorp_checked_get"
    { args = [ Borrow; Borrow ]; result = ReturnAliasOfArg 0 }
    (builtin_contract "blorp_checked_get" 2);
  check_contract "blorp_checked_slice"
    { args = [ Borrow; Borrow; Borrow ]; result = ReturnOwned }
    (builtin_contract "blorp_checked_slice" 3)

let test_checked_set_cow_consumes_collection () =
  check_contract "blorp_checked_set"
    { args = [ CowConsume; Borrow; Borrow ]; result = ReturnOwned }
    (builtin_contract "blorp_checked_set" 3);
  check_contract "blorp_matrix_checked_set"
    { args = [ CowConsume; Borrow; Borrow; Borrow ]; result = ReturnOwned }
    (builtin_contract "blorp_matrix_checked_set" 4)

let test_matrix_option_set_cow_consumes_collection () =
  let expected =
    { args = [ CowConsume; Borrow; Borrow; Borrow ]; result = ReturnOwned }
  in
  check_contract "blorp_matrix_set_opt" expected
    (builtin_contract "blorp_matrix_set_opt" 4);
  check_contract "blorp_matrix_set_opt_nullable" expected
    (builtin_contract "blorp_matrix_set_opt_nullable" 4)

let test_vector_arithmetic_borrows_inputs () =
  check_contract "blorp_vector_op"
    { args = [ Borrow; Borrow; Borrow; Borrow ]; result = ReturnOwned }
    (builtin_contract "blorp_vector_op" 4);
  check_contract "blorp_vector_scalar_op_float"
    { args = [ Borrow; Borrow; Borrow ]; result = ReturnOwned }
    (builtin_contract "blorp_vector_scalar_op_float" 3);
  check_contract "blorp_vector_eq"
    { args = [ Borrow; Borrow; Borrow ]; result = ReturnPrimitive }
    (builtin_contract "blorp_vector_eq" 3)

let test_tensor_linear_algebra_borrows_inputs () =
  let owned_binary_with_dims names =
    List.iter
      (fun name ->
        check_contract name
          {
            args = [ Borrow; Borrow; Borrow; Borrow; Borrow ];
            result = ReturnOwned;
          }
          (builtin_contract name 5))
      names
  in
  let owned_binary names =
    List.iter
      (fun name ->
        check_contract name
          { args = [ Borrow; Borrow; Borrow; Borrow ]; result = ReturnOwned }
          (builtin_contract name 4))
      names
  in
  owned_binary_with_dims
    [
      "blorp_tensor_matrix_multiply_int";
      "blorp_tensor_matrix_multiply_float";
      "blorp_tensor_matrix_multiply_float16";
      "blorp_tensor_matrix_multiply_float32";
    ];
  owned_binary
    [
      "blorp_tensor_matrix_vector_multiply_int";
      "blorp_tensor_matrix_vector_multiply_float";
      "blorp_tensor_matrix_vector_multiply_float16";
      "blorp_tensor_matrix_vector_multiply_float32";
      "blorp_tensor_transposed_matrix_vector_multiply_float";
      "blorp_tensor_transposed_matrix_vector_multiply_float16";
      "blorp_tensor_transposed_matrix_vector_multiply_float32";
      "blorp_tensor_transposed_matrix_vector_multiply_int";
      "blorp_tensor_outer_int";
      "blorp_tensor_outer_float";
      "blorp_tensor_outer_float16";
      "blorp_tensor_outer_float32";
    ];
  check_contract "blorp_tensor_transpose"
    { args = [ Borrow; Borrow; Borrow ]; result = ReturnOwned }
    (builtin_contract "blorp_tensor_transpose" 3);
  check_contract "blorp_tensor_slice_row"
    { args = [ Borrow; Borrow; Borrow; Borrow ]; result = ReturnOwned }
    (builtin_contract "blorp_tensor_slice_row" 4)

let test_vector_specialized_reads_borrow_inputs () =
  let owned_unary =
    [
      "blorp_vector_abs";
      "blorp_vector_exp";
      "blorp_vector_exp_float16";
      "blorp_vector_exp_float32";
      "blorp_vector_log";
      "blorp_vector_log_float16";
      "blorp_vector_log_float32";
      "blorp_vector_sqrt";
      "blorp_vector_sqrt_float16";
      "blorp_vector_sqrt_float32";
    ]
  in
  List.iter
    (fun name ->
      check_contract name
        { args = [ Borrow ]; result = ReturnOwned }
        (builtin_contract name 1))
    owned_unary;
  List.iter
    (fun name ->
      check_contract name
        { args = [ Borrow ]; result = ReturnPrimitive }
        (builtin_contract name 1))
    [
      "blorp_vector_max_float";
      "blorp_vector_max_float16";
      "blorp_vector_max_float32";
      "blorp_vector_max_int";
      "blorp_vector_min_float";
      "blorp_vector_min_float16";
      "blorp_vector_min_float32";
      "blorp_vector_min_int";
      "blorp_vector_norm";
      "blorp_vector_norm_float16";
      "blorp_vector_norm_float32";
    ];
  check_contract "blorp_vector_cross_float"
    { args = [ Borrow; Borrow ]; result = ReturnOwned }
    (builtin_contract "blorp_vector_cross_float" 2);
  check_contract "blorp_vector_zip"
    { args = [ Borrow; Borrow ]; result = ReturnOwned }
    (builtin_contract "blorp_vector_zip" 2)

let test_to_string_runtime_builtins_borrow_inputs () =
  List.iter
    (fun name ->
      check_contract name
        { args = [ Borrow ]; result = ReturnOwned }
        (builtin_contract name 1))
    [
      "blorp_to_string";
      "blorp_int128_to_string";
      "blorp_uint128_to_string";
      "blorp_float_to_string";
      "blorp_float16_to_string";
      "blorp_float32_to_string";
      "blorp_bool_to_string";
      "blorp_bool_to_string_long";
      "blorp_bytes_to_string";
      "blorp_list_to_string_bool";
      "blorp_list_to_string_cb";
      "blorp_list_to_string_float";
      "blorp_list_to_string_float16";
      "blorp_list_to_string_float32";
      "blorp_list_to_string_int";
      "blorp_list_to_string_string";
      "blorp_vector_to_string_bool";
      "blorp_vector_to_string_float";
      "blorp_vector_to_string_float16";
      "blorp_vector_to_string_float32";
      "blorp_vector_to_string_int";
    ]

let test_generated_enum_vector_to_string_contract () =
  check_contract "blorp_vector_to_string___tests__Base"
    { args = [ Borrow ]; result = ReturnOwned }
    (builtin_contract "blorp_vector_to_string___tests__Base" 1);
  Alcotest.(check bool)
    "generated vector to_string rejects wrong arity" true
    (Option.is_none (builtin_contract "blorp_vector_to_string___tests__Base" 2))

let test_format_float_borrows_inputs_and_returns_owned () =
  check_contract "blorp_format_float"
    { args = [ Borrow; Borrow ]; result = ReturnOwned }
    (builtin_contract "blorp_format_float" 2)

let test_conversion_runtime_builtins_return_primitives () =
  List.iter
    (fun name ->
      check_contract name
        { args = [ Borrow ]; result = ReturnPrimitive }
        (builtin_contract name 1))
    [
      "blorp_to_int";
      "blorp_to_float";
      "blorp_to_int8";
      "blorp_to_int16";
      "blorp_to_int32";
      "blorp_to_int128";
      "blorp_to_uint8";
      "blorp_to_uint16";
      "blorp_to_uint32";
      "blorp_to_uint64";
      "blorp_to_uint128";
    ]

let test_debug_log_runtime_builtins_borrow_messages () =
  List.iter
    (fun name ->
      check_contract name
        { args = [ Borrow ]; result = ReturnVoid }
        (builtin_contract name 1))
    [
      "blorp_debug_log_msg";
      "blorp_debug_info";
      "blorp_debug_warn";
      "blorp_debug_error";
    ]

let test_vmap_parallel_borrows_with_result_ownership_flag () =
  check_contract "blorp_matrix_map_indexed"
    { args = [ Borrow; Borrow; Borrow ]; result = ReturnOwned }
    (builtin_contract "blorp_matrix_map_indexed" 3);
  check_contract "blorp_matrix_zip_map"
    { args = [ Borrow; Borrow; Borrow; Borrow ]; result = ReturnOwned }
    (builtin_contract "blorp_matrix_zip_map" 4);
  check_contract "blorp_vmap_indexed_parallel"
    { args = [ Borrow; Borrow; Borrow ]; result = ReturnOwned }
    (builtin_contract "blorp_vmap_indexed_parallel" 3);
  check_contract "blorp_mzip_indexed_parallel"
    { args = [ Borrow; Borrow; Borrow; Borrow ]; result = ReturnOwned }
    (builtin_contract "blorp_mzip_indexed_parallel" 4);
  check_contract "blorp_mmap_flat_indexed_parallel"
    { args = [ Borrow; Borrow; Borrow ]; result = ReturnOwned }
    (builtin_contract "blorp_mmap_flat_indexed_parallel" 3)

let test_list_parallel_borrows_with_result_ownership_flag () =
  check_contract "blorp_zip_parallel"
    { args = [ Borrow; Borrow; Borrow; Borrow ]; result = ReturnOwned }
    (builtin_contract "blorp_zip_parallel" 4)

let test_fold_consumes_accumulator_and_borrows_collection () =
  check_contract "blorp_fold_parallel"
    { args = [ Borrow; Consume; Borrow; Borrow ]; result = ReturnOwned }
    (builtin_contract "blorp_fold_parallel" 4)

let test_sequential_list_hofs_have_no_runtime_contracts () =
  let calls =
    [
      ("blorp_list_map", 2);
      ("blorp_list_filter", 2);
      ("blorp_list_filter_map", 2);
      ("blorp_list_fold_left", 4);
      ("blorp_list_fold_right", 4);
      ("blorp_list_for_each", 2);
      ("blorp_list_any", 2);
      ("blorp_list_all", 2);
      ("blorp_list_flat_map", 2);
    ]
  in
  List.iter
    (fun (name, arity) ->
      Alcotest.(check bool) name true (builtin_contract name arity = None))
    calls

let test_set_contains_has_no_runtime_contract () =
  Alcotest.(check bool)
    "blorp_set_contains" true
    (builtin_contract "blorp_set_contains" 2 = None)

let test_list_append_cow_strategy () =
  check_strategy "list append strategy"
    {
      receiver = CowConsumeReceiver;
      result_collection =
        ReuseReceiver
          { cow_boundary = "list_ensure_capacity"; reserve_for_len = None };
      element_storage = RetainInputElement;
    }
    (collection_strategy ~module_path:"std/list" ~func_name:"append")

let test_list_map_fresh_strategy () =
  check_strategy "list map strategy"
    {
      receiver = BorrowReceiver;
      result_collection =
        AllocateFresh
          { alloc = "list_alloc"; growth = None; reserve_for_len = None };
      element_storage = TransferProducedElement;
    }
    (collection_strategy ~module_path:"std/list" ~func_name:"map")

let test_list_enumerate_fresh_strategy () =
  check_strategy "list enumerate strategy"
    {
      receiver = BorrowReceiver;
      result_collection =
        AllocateFresh
          { alloc = "list_alloc"; growth = None; reserve_for_len = None };
      element_storage = TransferProducedElement;
    }
    (collection_strategy ~module_path:"std/list" ~func_name:"enumerate")

let test_list_zip_fresh_strategy () =
  check_strategy "list zip strategy"
    {
      receiver = BorrowReceiver;
      result_collection =
        AllocateFresh
          { alloc = "list_alloc"; growth = None; reserve_for_len = None };
      element_storage = TransferProducedElement;
    }
    (collection_strategy ~module_path:"std/list" ~func_name:"zip")

let test_list_filter_fresh_retain_strategy () =
  check_strategy "list filter strategy"
    {
      receiver = BorrowReceiver;
      result_collection =
        AllocateFresh
          { alloc = "list_alloc"; growth = None; reserve_for_len = None };
      element_storage = RetainBorrowedElement;
    }
    (collection_strategy ~module_path:"std/list" ~func_name:"filter")

let test_list_unzip_fresh_retain_strategy () =
  check_strategy "list unzip strategy"
    {
      receiver = BorrowReceiver;
      result_collection =
        AllocateFresh
          { alloc = "list_alloc"; growth = None; reserve_for_len = None };
      element_storage = RetainBorrowedElement;
    }
    (collection_strategy ~module_path:"std/list" ~func_name:"unzip")

let test_list_cleanup_builder_strategies () =
  let fresh_list element_storage =
    {
      receiver = BorrowReceiver;
      result_collection =
        AllocateFresh
          { alloc = "list_alloc"; growth = None; reserve_for_len = None };
      element_storage;
    }
  in
  List.iter
    (fun name ->
      check_strategy
        ("list " ^ name ^ " fresh retain-borrowed strategy")
        (fresh_list RetainBorrowedElement)
        (collection_strategy ~module_path:"std/list" ~func_name:name))
    [ "concat"; "take"; "drop"; "flatten"; "unique" ];
  check_strategy "list repeat fresh retain-input strategy"
    (fresh_list RetainInputElement)
    (collection_strategy ~module_path:"std/list" ~func_name:"repeat");
  check_strategy "list range fresh produced-element strategy"
    (fresh_list TransferProducedElement)
    (collection_strategy ~module_path:"std/list" ~func_name:"range")

let test_list_intersperse_mixed_retain_strategy () =
  check_strategy "list intersperse fresh mixed-retain strategy"
    {
      receiver = BorrowReceiver;
      result_collection =
        AllocateFresh
          { alloc = "list_alloc"; growth = None; reserve_for_len = None };
      element_storage = RetainInputAndBorrowedElements;
    }
    (collection_strategy ~module_path:"std/list" ~func_name:"intersperse")

let test_list_windows_fresh_nested_strategy () =
  check_strategy "list windows fresh nested strategy"
    {
      receiver = BorrowReceiver;
      result_collection =
        AllocateFresh
          { alloc = "list_alloc"; growth = None; reserve_for_len = None };
      element_storage = TransferProducedElement;
    }
    (collection_strategy ~module_path:"std/list" ~func_name:"windows")

let test_list_chunks_fresh_nested_strategy () =
  check_strategy "list chunks fresh nested strategy"
    {
      receiver = BorrowReceiver;
      result_collection =
        AllocateFresh
          { alloc = "list_alloc"; growth = None; reserve_for_len = None };
      element_storage = TransferProducedElement;
    }
    (collection_strategy ~module_path:"std/list" ~func_name:"chunks")

let test_list_flat_map_dynamic_growth_strategy () =
  check_strategy "list flat_map strategy"
    {
      receiver = BorrowReceiver;
      result_collection =
        AllocateFresh
          {
            alloc = "list_alloc";
            growth = Some "list_ensure_capacity";
            reserve_for_len = None;
          };
      element_storage = RetainBorrowedElement;
    }
    (collection_strategy ~module_path:"std/list" ~func_name:"flat_map")

let test_list_fold_left_no_collection_result_strategy () =
  check_strategy "list fold_left strategy"
    {
      receiver = BorrowReceiver;
      result_collection = NoCollectionResult;
      element_storage = NoElementStorage;
    }
    (collection_strategy ~module_path:"std/list" ~func_name:"fold_left")

let test_list_count_no_collection_result_strategy () =
  check_strategy "list count strategy"
    {
      receiver = BorrowReceiver;
      result_collection = NoCollectionResult;
      element_storage = NoElementStorage;
    }
    (collection_strategy ~module_path:"std/list" ~func_name:"count")

let test_set_add_cow_mutator_strategy () =
  check_strategy "set add strategy"
    {
      receiver = CowConsumeReceiver;
      result_collection =
        ReuseReceiver { cow_boundary = "set_cow"; reserve_for_len = None };
      element_storage = RetainInputElement;
    }
    (collection_strategy ~module_path:"std/set" ~func_name:"add")

let test_set_map_fresh_strategy () =
  check_strategy "set map strategy"
    {
      receiver = BorrowReceiver;
      result_collection =
        AllocateFresh
          {
            alloc = "blorp_set_new";
            growth = None;
            reserve_for_len = Some "set_reserve_for_len";
          };
      element_storage = TransferProducedElement;
    }
    (collection_strategy ~module_path:"std/set" ~func_name:"map")

let test_set_combine_reuses_left_strategy () =
  check_strategy "set combine strategy"
    {
      receiver = CowConsumeReceiver;
      result_collection =
        ReuseReceiver
          {
            cow_boundary = "set_cow";
            reserve_for_len = Some "set_reserve_for_len";
          };
      element_storage = RetainBorrowedElement;
    }
    (collection_strategy ~module_path:"std/set" ~func_name:"combine")

let test_dict_set_cow_mutator_strategy () =
  check_strategy "dict set strategy"
    {
      receiver = CowConsumeReceiver;
      result_collection =
        ReuseReceiver { cow_boundary = "dict_cow"; reserve_for_len = None };
      element_storage = RetainInputElement;
    }
    (collection_strategy ~module_path:"std/dict" ~func_name:"set")

let test_dict_keys_fresh_strategy () =
  check_strategy "dict keys strategy"
    {
      receiver = BorrowReceiver;
      result_collection =
        AllocateFresh
          { alloc = "list_alloc"; growth = None; reserve_for_len = None };
      element_storage = RetainBorrowedElement;
    }
    (collection_strategy ~module_path:"std/dict" ~func_name:"keys")

let test_dict_entries_fresh_strategy () =
  check_strategy "dict entries strategy"
    {
      receiver = BorrowReceiver;
      result_collection =
        AllocateFresh
          { alloc = "list_alloc"; growth = None; reserve_for_len = None };
      element_storage = TransferProducedElement;
    }
    (collection_strategy ~module_path:"std/dict" ~func_name:"entries")

let test_dict_get_or_no_collection_result_strategy () =
  check_strategy "dict get_or strategy"
    {
      receiver = BorrowReceiver;
      result_collection = NoCollectionResult;
      element_storage = NoElementStorage;
    }
    (collection_strategy ~module_path:"std/dict" ~func_name:"get_or")

let test_call_kind_dispatches_intrinsic () =
  check_contract "call kind intrinsic"
    { args = [ CowConsume ]; result = ReturnOwned }
    (contract_for_call_kind (CKIntrinsic "dict_cow") ~arg_count:1)

let test_unknown_call_has_no_contract () =
  Alcotest.(check bool)
    "unknown" true
    (contract_for_call_kind (CKUser ("f", None)) ~arg_count:2 = None)

let test_builtin_contract_table_has_no_duplicate_names () =
  let names =
    List.map (fun entry -> entry.builtin_name) builtin_contract_table
  in
  let sorted = List.sort String.compare names in
  let rec duplicates = function
    | a :: b :: rest when a = b -> a :: duplicates (b :: rest)
    | _ :: rest -> duplicates rest
    | [] -> []
  in
  Alcotest.(check (list string))
    "duplicate builtin contract names" [] (duplicates sorted)

let test_builtin_contract_table_entries_are_well_formed () =
  let check entry =
    List.iter
      (fun arity ->
        match builtin_contract entry.builtin_name arity with
        | Some contract -> (
            match validate_contract contract with
            | [] -> ()
            | violations ->
                Alcotest.failf "%s/%d has invalid contract: %s"
                  entry.builtin_name arity
                  (String.concat "; "
                     (List.map string_of_contract_violation violations)))
        | None ->
            Alcotest.failf "%s/%d is listed but has no contract"
              entry.builtin_name arity)
      (builtin_contract_sample_arities entry)
  in
  List.iter check builtin_contract_table

let test_builtin_contract_table_void_boxed_args_are_supported () =
  let check entry =
    let positions = entry.builtin_void_boxed_args in
    let sorted = List.sort_uniq Int.compare positions in
    Alcotest.(check (list int))
      (entry.builtin_name ^ " has normalized void* ABI arg positions")
      sorted positions;
    List.iter
      (fun pos ->
        if pos < 0 then
          Alcotest.failf "%s has negative void* ABI arg position %d"
            entry.builtin_name pos)
      positions;
    match positions with
    | [] -> ()
    | _ ->
        let max_position = List.fold_left max 0 positions in
        let supported =
          builtin_contract_spec_has_arg_position entry.builtin_spec max_position
        in
        Alcotest.(check bool)
          (Printf.sprintf "%s has a contract arity covering void* ABI arg %d"
             entry.builtin_name max_position)
          true supported
  in
  List.iter check builtin_contract_table

let test_builtin_contract_table_rejects_unsupported_arities () =
  let check name arity =
    Alcotest.(check bool)
      (Printf.sprintf "%s/%d rejected" name arity)
      true
      (builtin_contract name arity = None)
  in
  check "blorp_string_eq" 3;
  check "blorp_map_parallel" 4;
  check "blorp_string_concat_many" 0

let find_project_file rel =
  let rec search dir depth =
    let candidate = Filename.concat dir rel in
    if Sys.file_exists candidate then candidate
    else if depth = 0 then
      Alcotest.failf "Cannot locate %s from CWD=%s" rel (Sys.getcwd ())
    else
      let parent = Filename.dirname dir in
      if parent = dir then
        Alcotest.failf "Cannot locate %s from CWD=%s" rel (Sys.getcwd ())
      else search parent (depth - 1)
  in
  search (Sys.getcwd ()) 12

let read_file path =
  let ic = open_in path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () -> really_input_string ic (in_channel_length ic))

let rec ml_files_under dir =
  Sys.readdir dir |> Array.to_list
  |> List.concat_map (fun name ->
      let path = Filename.concat dir name in
      if Sys.is_directory path then ml_files_under path
      else if Filename.check_suffix path ".ml" then [ path ]
      else [])

let ckbuiltin_literals content =
  let needle = "CKBuiltin \"" in
  let needle_len = String.length needle in
  let content_len = String.length content in
  let rec scan from acc =
    if from + needle_len > content_len then acc
    else if String.sub content from needle_len = needle then
      let start = from + needle_len in
      let stop =
        try String.index_from content start '"' with Not_found -> content_len
      in
      let name = String.sub content start (stop - start) in
      scan (stop + 1) (name :: acc)
    else scan (from + 1) acc
  in
  scan 0 []

let test_generated_ckbuiltins_have_explicit_ownership_coverage () =
  let lib_dir = find_project_file "compiler/lib" in
  let names =
    ml_files_under lib_dir
    |> List.concat_map (fun path -> ckbuiltin_literals (read_file path))
    |> List.sort_uniq String.compare
  in
  let uncovered =
    List.filter_map
      (fun name ->
        match builtin_ownership_coverage name with
        | Some _ -> None
        | None -> Some name)
      names
  in
  Alcotest.(check (list string))
    "generated CKBuiltin names without ownership coverage" [] uncovered

let suite =
  [
    ( "mode_semantics",
      [
        Alcotest.test_case "arg_mode_semantics" `Quick test_arg_mode_semantics;
        Alcotest.test_case "alias_contract_must_reference_existing_arg" `Quick
          test_alias_contract_must_reference_existing_arg;
        Alcotest.test_case "alias_contract_must_reference_preserved_arg" `Quick
          test_alias_contract_must_reference_preserved_arg;
        Alcotest.test_case "valid_alias_contract_is_well_formed" `Quick
          test_valid_alias_contract_is_well_formed;
        Alcotest.test_case "borrowed_result_must_have_preserved_anchor" `Quick
          test_borrowed_result_must_have_preserved_anchor;
      ] );
    ( "contracts",
      [
        Alcotest.test_case "list_len_borrows" `Quick test_list_len_borrows;
        Alcotest.test_case "list_get_returns_alias" `Quick
          test_list_get_returns_alias;
        Alcotest.test_case "list_get_unchecked_returns_alias" `Quick
          test_list_get_unchecked_returns_alias;
        Alcotest.test_case "list_ensure_capacity_cow_consumes" `Quick
          test_list_ensure_capacity_cow_consumes;
        Alcotest.test_case "list_reuse_alloc_cow_consumes" `Quick
          test_list_reuse_alloc_cow_consumes;
        Alcotest.test_case "hash_collection_reuse_alloc_cow_consumes" `Quick
          test_hash_collection_reuse_alloc_cow_consumes;
        Alcotest.test_case "list_append_owned_transfers_element" `Quick
          test_list_append_owned_transfers_element;
        Alcotest.test_case "list_append_retains_element" `Quick
          test_list_append_retains_element;
        Alcotest.test_case "list_new_allocates_owned_list" `Quick
          test_list_new_allocates_owned_list;
        Alcotest.test_case "channel_new_allocates_owned_channel" `Quick
          test_channel_new_allocates_owned_channel;
        Alcotest.test_case "channel_send_status_retains_payloads" `Quick
          test_channel_send_status_retains_payloads;
        Alcotest.test_case "channel_send_attempt_retains_payloads" `Quick
          test_channel_send_attempt_retains_payloads;
        Alcotest.test_case "channel_try_recv_attempt_borrows_channel" `Quick
          test_channel_try_recv_attempt_borrows_channel;
        Alcotest.test_case "channel_recv_timeout_attempt_borrows_channel" `Quick
          test_channel_recv_timeout_attempt_borrows_channel;
        Alcotest.test_case "file_close_finalizers_consume_handles" `Quick
          test_file_close_finalizers_consume_handles;
        Alcotest.test_case "tcp_close_finalizers_consume_handles" `Quick
          test_tcp_close_finalizers_consume_handles;
        Alcotest.test_case "directory_close_finalizer_consumes_handle" `Quick
          test_directory_close_finalizer_consumes_handle;
        Alcotest.test_case "network_close_finalizers_consume_handles" `Quick
          test_network_close_finalizers_consume_handles;
        Alcotest.test_case "tcp_connection_sources_borrow_listener" `Quick
          test_tcp_connection_sources_borrow_listener;
        Alcotest.test_case "tcp_value_helpers_have_runtime_contracts" `Quick
          test_tcp_value_helpers_have_runtime_contracts;
        Alcotest.test_case "network_capability_queries_return_primitives" `Quick
          test_network_capability_queries_return_primitives;
        Alcotest.test_case "scheduler_runtime_builtins_have_contracts" `Quick
          test_scheduler_runtime_builtins_have_contracts;
        Alcotest.test_case "time_runtime_builtins_have_contracts" `Quick
          test_time_runtime_builtins_have_contracts;
        Alcotest.test_case "memory_runtime_builtins_have_contracts" `Quick
          test_memory_runtime_builtins_have_contracts;
        Alcotest.test_case "process_signal_runtime_builtins_have_contracts"
          `Quick test_process_signal_runtime_builtins_have_contracts;
        Alcotest.test_case "random_runtime_builtins_have_contracts" `Quick
          test_random_runtime_builtins_have_contracts;
        Alcotest.test_case "hash_runtime_builtins_have_contracts" `Quick
          test_hash_runtime_builtins_have_contracts;
        Alcotest.test_case "regex_runtime_builtins_have_contracts" `Quick
          test_regex_runtime_builtins_have_contracts;
        Alcotest.test_case
          "checked_numeric_option_builtins_return_stack_options" `Quick
          test_checked_numeric_option_builtins_return_stack_options;
        Alcotest.test_case "console_io_runtime_builtins_return_owned_strings"
          `Quick test_console_io_runtime_builtins_return_owned_strings;
        Alcotest.test_case "scalar_math_passthrough_builtins_return_primitives"
          `Quick test_scalar_math_passthrough_builtins_return_primitives;
        Alcotest.test_case "scalar_runtime_builtins_return_primitives" `Quick
          test_scalar_runtime_builtins_return_primitives;
        Alcotest.test_case "operation_result_bridges_use_manifested_ownership"
          `Quick test_operation_result_bridges_use_manifested_ownership;
        Alcotest.test_case "fallible_stream_sources_use_manifested_ownership"
          `Quick test_fallible_stream_sources_use_manifested_ownership;
        Alcotest.test_case "fallible_stream_terminals_use_manifested_ownership"
          `Quick test_fallible_stream_terminals_use_manifested_ownership;
        Alcotest.test_case "fixed_constructors_allocate_owned_fixed" `Quick
          test_fixed_constructors_allocate_owned_fixed;
        Alcotest.test_case
          "custom_dict_set_constructors_synthesize_callbacks_in_codegen" `Quick
          test_custom_dict_set_constructors_synthesize_callbacks_in_codegen;
        Alcotest.test_case "dict_with_capacity_allocates_owned_dict" `Quick
          test_dict_with_capacity_allocates_owned_dict;
        Alcotest.test_case "dict_remove_cow_consumes_dict" `Quick
          test_dict_remove_cow_consumes_dict;
        Alcotest.test_case "dict_insert_retains_payloads" `Quick
          test_dict_insert_retains_payloads;
        Alcotest.test_case "dict_get_nullable_borrows_dict_and_key" `Quick
          test_dict_get_nullable_borrows_dict_and_key;
        Alcotest.test_case "vector_get_nullable_borrows_vector_and_index" `Quick
          test_vector_get_nullable_borrows_vector_and_index;
        Alcotest.test_case "vector_get_or_returns_borrowed_value" `Quick
          test_vector_get_or_returns_borrowed_value;
        Alcotest.test_case "legacy_vector_set_borrows_value" `Quick
          test_legacy_vector_set_borrows_value;
        Alcotest.test_case "matrix_get_nullable_borrows_matrix_and_indices"
          `Quick test_matrix_get_nullable_borrows_matrix_and_indices;
        Alcotest.test_case "dict_slot_writes_transfer_payloads" `Quick
          test_dict_slot_writes_transfer_payloads;
        Alcotest.test_case "dict_retain_release_helpers" `Quick
          test_dict_retain_release_helpers;
        Alcotest.test_case "list_set_owned_transfers_element" `Quick
          test_list_set_owned_transfers_element;
        Alcotest.test_case "list_handoff_set_owned_transfers_element" `Quick
          test_list_handoff_set_owned_transfers_element;
        Alcotest.test_case "list_handoff_set_source_slot_borrows_source" `Quick
          test_list_handoff_set_source_slot_borrows_source;
        Alcotest.test_case "list_swap_slots_borrows_list_and_indices" `Quick
          test_list_swap_slots_borrows_list_and_indices;
        Alcotest.test_case "list_retain_for_retains_value" `Quick
          test_list_retain_for_retains_value;
        Alcotest.test_case "set_add_retains_key" `Quick test_set_add_retains_key;
        Alcotest.test_case "set_alloc_entry_transfers_key" `Quick
          test_set_alloc_entry_transfers_key;
        Alcotest.test_case "set_retain_key_for_retains_key" `Quick
          test_set_retain_key_for_retains_key;
        Alcotest.test_case "string_concat_many_consumes_parts" `Quick
          test_string_concat_many_consumes_parts;
        Alcotest.test_case "string_eq_borrows" `Quick test_string_eq_borrows;
        Alcotest.test_case "unicode_case_borrows_and_returns_owned" `Quick
          test_unicode_case_borrows_and_returns_owned;
        Alcotest.test_case
          "utf8_runtime_builtins_borrow_inputs_and_return_owned" `Quick
          test_utf8_runtime_builtins_borrow_inputs_and_return_owned;
        Alcotest.test_case "string_find_byte_from_borrows" `Quick
          test_string_find_byte_from_borrows;
        Alcotest.test_case "string_copy_bytes_borrows" `Quick
          test_string_copy_bytes_borrows;
        Alcotest.test_case "checked_get_borrows_and_aliases" `Quick
          test_checked_get_borrows_and_aliases;
        Alcotest.test_case "checked_set_cow_consumes_collection" `Quick
          test_checked_set_cow_consumes_collection;
        Alcotest.test_case "matrix_option_set_cow_consumes_collection" `Quick
          test_matrix_option_set_cow_consumes_collection;
        Alcotest.test_case "vector_arithmetic_borrows_inputs" `Quick
          test_vector_arithmetic_borrows_inputs;
        Alcotest.test_case "tensor_linear_algebra_borrows_inputs" `Quick
          test_tensor_linear_algebra_borrows_inputs;
        Alcotest.test_case "vector_specialized_reads_borrow_inputs" `Quick
          test_vector_specialized_reads_borrow_inputs;
        Alcotest.test_case "math_round_intrinsic_borrows" `Quick
          test_math_round_intrinsic_borrows;
        Alcotest.test_case "to_string_runtime_builtins_borrow_inputs" `Quick
          test_to_string_runtime_builtins_borrow_inputs;
        Alcotest.test_case "generated_enum_vector_to_string_contract" `Quick
          test_generated_enum_vector_to_string_contract;
        Alcotest.test_case "format_float_borrows_inputs_and_returns_owned"
          `Quick test_format_float_borrows_inputs_and_returns_owned;
        Alcotest.test_case "conversion_runtime_builtins_return_primitives"
          `Quick test_conversion_runtime_builtins_return_primitives;
        Alcotest.test_case "debug_log_runtime_builtins_borrow_messages" `Quick
          test_debug_log_runtime_builtins_borrow_messages;
        Alcotest.test_case "vmap_parallel_borrows_with_result_ownership_flag"
          `Quick test_vmap_parallel_borrows_with_result_ownership_flag;
        Alcotest.test_case "list_parallel_borrows_with_result_ownership_flag"
          `Quick test_list_parallel_borrows_with_result_ownership_flag;
        Alcotest.test_case "fold_consumes_accumulator_and_borrows_collection"
          `Quick test_fold_consumes_accumulator_and_borrows_collection;
        Alcotest.test_case "sequential_list_hofs_have_no_runtime_contracts"
          `Quick test_sequential_list_hofs_have_no_runtime_contracts;
        Alcotest.test_case "set_contains_has_no_runtime_contract" `Quick
          test_set_contains_has_no_runtime_contract;
        Alcotest.test_case "call_kind_dispatches_intrinsic" `Quick
          test_call_kind_dispatches_intrinsic;
        Alcotest.test_case "unknown_call_has_no_contract" `Quick
          test_unknown_call_has_no_contract;
        Alcotest.test_case "builtin_contract_table_has_no_duplicate_names"
          `Quick test_builtin_contract_table_has_no_duplicate_names;
        Alcotest.test_case "builtin_contract_table_entries_are_well_formed"
          `Quick test_builtin_contract_table_entries_are_well_formed;
        Alcotest.test_case
          "builtin_contract_table_void_boxed_args_are_supported" `Quick
          test_builtin_contract_table_void_boxed_args_are_supported;
        Alcotest.test_case "builtin_contract_table_rejects_unsupported_arities"
          `Quick test_builtin_contract_table_rejects_unsupported_arities;
        Alcotest.test_case
          "generated_ckbuiltins_have_explicit_ownership_coverage" `Quick
          test_generated_ckbuiltins_have_explicit_ownership_coverage;
      ] );
    ( "collection_strategies",
      [
        Alcotest.test_case "list_append_cow_strategy" `Quick
          test_list_append_cow_strategy;
        Alcotest.test_case "list_map_fresh_strategy" `Quick
          test_list_map_fresh_strategy;
        Alcotest.test_case "list_enumerate_fresh_strategy" `Quick
          test_list_enumerate_fresh_strategy;
        Alcotest.test_case "list_zip_fresh_strategy" `Quick
          test_list_zip_fresh_strategy;
        Alcotest.test_case "list_filter_fresh_retain_strategy" `Quick
          test_list_filter_fresh_retain_strategy;
        Alcotest.test_case "list_unzip_fresh_retain_strategy" `Quick
          test_list_unzip_fresh_retain_strategy;
        Alcotest.test_case "list_cleanup_builder_strategies" `Quick
          test_list_cleanup_builder_strategies;
        Alcotest.test_case "list_intersperse_mixed_retain_strategy" `Quick
          test_list_intersperse_mixed_retain_strategy;
        Alcotest.test_case "list_windows_fresh_nested_strategy" `Quick
          test_list_windows_fresh_nested_strategy;
        Alcotest.test_case "list_chunks_fresh_nested_strategy" `Quick
          test_list_chunks_fresh_nested_strategy;
        Alcotest.test_case "list_flat_map_dynamic_growth_strategy" `Quick
          test_list_flat_map_dynamic_growth_strategy;
        Alcotest.test_case "list_fold_left_no_collection_result_strategy" `Quick
          test_list_fold_left_no_collection_result_strategy;
        Alcotest.test_case "list_count_no_collection_result_strategy" `Quick
          test_list_count_no_collection_result_strategy;
        Alcotest.test_case "set_add_cow_mutator_strategy" `Quick
          test_set_add_cow_mutator_strategy;
        Alcotest.test_case "set_map_fresh_strategy" `Quick
          test_set_map_fresh_strategy;
        Alcotest.test_case "set_combine_reuses_left_strategy" `Quick
          test_set_combine_reuses_left_strategy;
        Alcotest.test_case "dict_set_cow_mutator_strategy" `Quick
          test_dict_set_cow_mutator_strategy;
        Alcotest.test_case "dict_keys_fresh_strategy" `Quick
          test_dict_keys_fresh_strategy;
        Alcotest.test_case "dict_entries_fresh_strategy" `Quick
          test_dict_entries_fresh_strategy;
        Alcotest.test_case "dict_get_or_no_collection_result_strategy" `Quick
          test_dict_get_or_no_collection_result_strategy;
      ] );
  ]
