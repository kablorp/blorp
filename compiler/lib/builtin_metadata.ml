(** Typed metadata for builtins that have compiler-visible behavior.

    Keep semantic facts here instead of scattering name sets through compiler
    phases. Unknown names are treated as ordinary user/module functions. *)

type builtin_effect =
  | Impure
  | Parallel_boundary
  | Cancellation_point
  | Fiber_parking
  | Os_worker_blocking

type special_inference =
  | Checked_get
  | Checked_set
  | Checked_slice
  | Matrix_checked_get
  | Matrix_checked_set
  | Tensor_checked_get of int
  | Tensor_checked_set of int
  | Assert_shape
  | Length_refined
  | Type_name
  | Is_heap
  | Vector_ctor
  | Matrix_ctor
  | Tensor_ctor of int
  | Bitwise

type runtime_effect =
  | Pure_metadata
  | Impure_non_waiting
  | Cancellation_checkpoint
  | Fiber_parking_wait
  | Os_worker_blocking_wait

type descriptor = {
  name : string;
  runtime_effect : runtime_effect;
  parallel_boundary : bool;
  special_inference : special_inference option;
}

let impure name =
  {
    name;
    runtime_effect = Impure_non_waiting;
    parallel_boundary = false;
    special_inference = None;
  }

let cancellation_point name =
  {
    name;
    runtime_effect = Cancellation_checkpoint;
    parallel_boundary = false;
    special_inference = None;
  }

let fiber_parking name =
  {
    name;
    runtime_effect = Fiber_parking_wait;
    parallel_boundary = false;
    special_inference = None;
  }

let os_worker_blocking name =
  {
    name;
    runtime_effect = Os_worker_blocking_wait;
    parallel_boundary = false;
    special_inference = None;
  }

let parallel_boundary name =
  {
    name;
    runtime_effect = Pure_metadata;
    parallel_boundary = true;
    special_inference = None;
  }

let special name special_inference =
  {
    name;
    runtime_effect = Pure_metadata;
    parallel_boundary = false;
    special_inference = Some special_inference;
  }

let effects_for_wait_behavior wait_behavior =
  let open Operation_result_metadata in
  match wait_behavior with
  | DoesNotWait -> impure
  | ParksFiber -> fiber_parking
  | BlocksOsWorker _ -> os_worker_blocking

let operation_result_descriptors =
  Operation_result_metadata.result_bridges
  |> List.map (fun (bridge : Operation_result_metadata.result_bridge) ->
      effects_for_wait_behavior bridge.wait_behavior bridge.builtin_name)

let fallible_stream_source_descriptors =
  Operation_result_metadata.fallible_stream_sources
  |> List.map
       (fun (source : Operation_result_metadata.fallible_stream_source) ->
         impure source.builtin_name)

let fallible_stream_terminal_descriptors =
  Operation_result_metadata.fallible_stream_terminals
  |> List.map
       (fun (terminal : Operation_result_metadata.fallible_stream_terminal) ->
         effects_for_wait_behavior terminal.wait_behavior terminal.builtin_name)

let descriptors =
  [
    impure "print";
    impure "puts";
    impure "print_error";
    impure "read_file";
    impure "write_file";
    impure "read_bytes";
    impure "write_bytes";
    impure "file_exists";
    impure "is_directory";
    impure "exec";
    impure "read_line";
    impure "read_line_or_empty";
    impure "read_all";
    impure "input";
    impure "input_or_empty";
    impure "seed_random";
    impure "random_int";
    impure "random_float";
    impure "read_all_lines";
    impure "write_lines";
    impure "append_file";
    impure "for_each_line";
    impure "getcwd";
    impure "mkdir";
    impure "remove_file";
    impure "remove_dir";
    impure "rename";
    impure "exec_output";
    impure "now";
    impure "now_us";
    fiber_parking "sleep";
    cancellation_point "yield_now";
    impure "channel";
    fiber_parking "send";
    fiber_parking "recv";
    impure "try_send";
    impure "try_recv";
    impure "try_send_attempt";
    impure "try_recv_attempt";
    fiber_parking "send_timeout";
    fiber_parking "recv_timeout";
    fiber_parking "send_timeout_attempt";
    fiber_parking "recv_timeout_attempt";
    cancellation_point "cancel_after_parked_for_test";
    impure "task_join_slot_probe_for_test";
    impure "fiber_created_schedule_probe_for_test";
    impure "timer_waiter_identity_probe_for_test";
    impure "wait_ready_to_park_probe_for_test";
    impure "fiber_lifecycle_ready_to_park_probe_for_test";
    impure "fiber_cancel_before_park_probe_for_test";
    impure "current_timer_wait_install_probe_for_test";
    impure "timeout_arithmetic_probe_for_test";
    cancellation_point "cooperative_checkpoint_probe_for_test";
    cancellation_point "tls_state_probe_for_test";
    impure "websocket_state_probe_for_test";
    fiber_parking "blorp_tcp_accept";
    fiber_parking "blorp_tcp_connect";
    fiber_parking "blorp_tcp_read";
    fiber_parking "blorp_tcp_write";
  ]
  @ operation_result_descriptors @ fallible_stream_source_descriptors
  @ fallible_stream_terminal_descriptors
  @ [
      impure "getenv";
      impure "setenv";
      impure "init_window";
      impure "close_window";
      impure "window_should_close";
      impure "set_target_fps";
      impure "get_fps";
      impure "begin_drawing";
      impure "end_drawing";
      impure "clear_background";
      impure "draw_rectangle";
      impure "draw_rectangle_rec";
      impure "draw_circle";
      impure "draw_line";
      impure "draw_text";
      impure "is_key_pressed";
      impure "is_key_down";
      impure "get_mouse_x";
      impure "get_mouse_y";
      impure "is_mouse_button_pressed";
      impure "is_mouse_button_down";
      impure "get_frame_time";
      impure "get_time";
      parallel_boundary "parallel";
      special "checked_get" Checked_get;
      special "checked_set" Checked_set;
      special "checked_slice" Checked_slice;
      special "matrix_checked_get" Matrix_checked_get;
      special "matrix_checked_set" Matrix_checked_set;
      special "tensor3_checked_get" (Tensor_checked_get 3);
      special "tensor4_checked_get" (Tensor_checked_get 4);
      special "tensor5_checked_get" (Tensor_checked_get 5);
      special "tensor3_checked_set" (Tensor_checked_set 3);
      special "tensor4_checked_set" (Tensor_checked_set 4);
      special "tensor5_checked_set" (Tensor_checked_set 5);
      special "assert_shape" Assert_shape;
      special "length" Length_refined;
      special "vector_length" Length_refined;
      special "type_name" Type_name;
      special "is_heap" Is_heap;
      special "vector" Vector_ctor;
      special "matrix" Matrix_ctor;
      special "tensor3" (Tensor_ctor 3);
      special "tensor4" (Tensor_ctor 4);
      special "tensor5" (Tensor_ctor 5);
      special "bit_and" Bitwise;
      special "bit_or" Bitwise;
      special "bit_xor" Bitwise;
      special "bit_not" Bitwise;
      special "shift_left" Bitwise;
      special "shift_right" Bitwise;
    ]

module StringMap = Map.Make (String)
module StringSet = Set.Make (String)

let add_duplicate_name (seen, duplicates) { name; _ } =
  if StringSet.mem name seen then (seen, StringSet.add name duplicates)
  else (StringSet.add name seen, duplicates)

let duplicate_names =
  let _seen, duplicates =
    List.fold_left add_duplicate_name
      (StringSet.empty, StringSet.empty)
      descriptors
  in
  StringSet.elements duplicates

let registry =
  match duplicate_names with
  | [] ->
      List.fold_left
        (fun acc d -> StringMap.add d.name d acc)
        StringMap.empty descriptors
  | names ->
      invalid_arg
        ("Builtin_metadata duplicate descriptors: " ^ String.concat ", " names)

let find name = StringMap.find_opt name registry

let has_effect name builtin_effect =
  match find name with
  | Some d -> (
      match builtin_effect with
      | Impure -> d.runtime_effect <> Pure_metadata
      | Parallel_boundary -> d.parallel_boundary
      | Cancellation_point -> (
          match d.runtime_effect with
          | Cancellation_checkpoint | Fiber_parking_wait -> true
          | Pure_metadata | Impure_non_waiting | Os_worker_blocking_wait ->
              false)
      | Fiber_parking -> d.runtime_effect = Fiber_parking_wait
      | Os_worker_blocking -> d.runtime_effect = Os_worker_blocking_wait)
  | None -> false

let is_impure name = has_effect name Impure
let is_parallel_boundary name = has_effect name Parallel_boundary

let special_inference name =
  match find name with Some d -> d.special_inference | None -> None
