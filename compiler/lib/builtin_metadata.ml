(** Typed metadata for builtins that have compiler-visible behavior.

    Keep semantic facts here instead of scattering name sets through compiler
    phases. Unknown names are treated as ordinary user/module functions. *)

type builtin_effect =
  | Impure
  | Parallel_boundary
  | Cancellation_point
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

type capability =
  | Effect of builtin_effect
  | Special_inference of special_inference

type descriptor = { name : string; capabilities : capability list }

let descriptor name capabilities =
  match capabilities with
  | [] ->
      invalid_arg ("Builtin_metadata.descriptor: " ^ name ^ " has no behavior")
  | _ -> { name; capabilities }

let effect_capability builtin_effect = Effect builtin_effect

let special_inference_capability special_inference =
  Special_inference special_inference

let effects name effects = descriptor name (List.map effect_capability effects)

let special name special_inference =
  descriptor name [ special_inference_capability special_inference ]

let effects_for_wait_behavior wait_behavior =
  let open Operation_result_metadata in
  match wait_behavior with
  | DoesNotWait -> [ Impure ]
  | ParksFiber -> [ Impure; Cancellation_point ]
  | BlocksOsWorker _ -> [ Impure; Os_worker_blocking ]

let operation_result_descriptors =
  Operation_result_metadata.result_bridges
  |> List.map (fun (bridge : Operation_result_metadata.result_bridge) ->
      let effect_list = effects_for_wait_behavior bridge.wait_behavior in
      effects bridge.builtin_name effect_list)

let fallible_stream_source_descriptors =
  Operation_result_metadata.fallible_stream_sources
  |> List.map
       (fun (source : Operation_result_metadata.fallible_stream_source) ->
         effects source.builtin_name [ Impure ])

let fallible_stream_terminal_descriptors =
  Operation_result_metadata.fallible_stream_terminals
  |> List.map
       (fun (terminal : Operation_result_metadata.fallible_stream_terminal) ->
         let effect_list = effects_for_wait_behavior terminal.wait_behavior in
         effects terminal.builtin_name effect_list)

let descriptors =
  [
    effects "print" [ Impure ];
    effects "puts" [ Impure ];
    effects "print_error" [ Impure ];
    effects "read_file" [ Impure ];
    effects "write_file" [ Impure ];
    effects "read_bytes" [ Impure ];
    effects "write_bytes" [ Impure ];
    effects "file_exists" [ Impure ];
    effects "is_directory" [ Impure ];
    effects "exec" [ Impure ];
    effects "read_line" [ Impure ];
    effects "read_line_or_empty" [ Impure ];
    effects "read_all" [ Impure ];
    effects "input" [ Impure ];
    effects "input_or_empty" [ Impure ];
    effects "seed_random" [ Impure ];
    effects "random_int" [ Impure ];
    effects "random_float" [ Impure ];
    effects "read_all_lines" [ Impure ];
    effects "write_lines" [ Impure ];
    effects "append_file" [ Impure ];
    effects "for_each_line" [ Impure ];
    effects "getcwd" [ Impure ];
    effects "mkdir" [ Impure ];
    effects "remove_file" [ Impure ];
    effects "remove_dir" [ Impure ];
    effects "rename" [ Impure ];
    effects "exec_output" [ Impure ];
    effects "now" [ Impure ];
    effects "now_us" [ Impure ];
    effects "sleep" [ Impure; Cancellation_point ];
    effects "yield_now" [ Impure; Cancellation_point ];
    effects "channel" [ Impure ];
    effects "send" [ Impure; Cancellation_point ];
    effects "recv" [ Impure; Cancellation_point ];
    effects "try_send" [ Impure ];
    effects "try_recv" [ Impure ];
    effects "try_send_attempt" [ Impure ];
    effects "try_recv_attempt" [ Impure ];
    effects "send_timeout" [ Impure; Cancellation_point ];
    effects "recv_timeout" [ Impure; Cancellation_point ];
    effects "send_timeout_attempt" [ Impure; Cancellation_point ];
    effects "recv_timeout_attempt" [ Impure; Cancellation_point ];
    effects "cancel_after_parked_for_test" [ Impure; Cancellation_point ];
    effects "tls_state_probe_for_test" [ Impure; Cancellation_point ];
    effects "websocket_state_probe_for_test" [ Impure ];
    effects "blorp_tcp_accept" [ Impure; Cancellation_point ];
    effects "blorp_tcp_connect" [ Impure; Cancellation_point ];
    effects "blorp_tcp_read" [ Impure; Cancellation_point ];
    effects "blorp_tcp_write" [ Impure; Cancellation_point ];
  ]
  @ operation_result_descriptors @ fallible_stream_source_descriptors
  @ fallible_stream_terminal_descriptors
  @ [
      effects "getenv" [ Impure ];
      effects "setenv" [ Impure ];
      effects "init_window" [ Impure ];
      effects "close_window" [ Impure ];
      effects "window_should_close" [ Impure ];
      effects "set_target_fps" [ Impure ];
      effects "get_fps" [ Impure ];
      effects "begin_drawing" [ Impure ];
      effects "end_drawing" [ Impure ];
      effects "clear_background" [ Impure ];
      effects "draw_rectangle" [ Impure ];
      effects "draw_rectangle_rec" [ Impure ];
      effects "draw_circle" [ Impure ];
      effects "draw_line" [ Impure ];
      effects "draw_text" [ Impure ];
      effects "is_key_pressed" [ Impure ];
      effects "is_key_down" [ Impure ];
      effects "get_mouse_x" [ Impure ];
      effects "get_mouse_y" [ Impure ];
      effects "is_mouse_button_pressed" [ Impure ];
      effects "is_mouse_button_down" [ Impure ];
      effects "get_frame_time" [ Impure ];
      effects "get_time" [ Impure ];
      effects "parallel" [ Parallel_boundary ];
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

let descriptor_is_inert { capabilities; _ } = capabilities = []

let inert_descriptor_names =
  descriptors
  |> List.filter_map (fun ({ name; _ } as d) ->
      if descriptor_is_inert d then Some name else None)
  |> List.sort_uniq String.compare

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
let is_registered name = Option.is_some (find name)

let capability_matches_effect builtin_effect = function
  | Effect e -> e = builtin_effect
  | Special_inference _ -> false

let has_effect name builtin_effect =
  match find name with
  | Some d ->
      List.exists (capability_matches_effect builtin_effect) d.capabilities
  | None -> false

let is_impure name = has_effect name Impure
let is_parallel_boundary name = has_effect name Parallel_boundary
let is_cancellation_point name = has_effect name Cancellation_point
let is_os_worker_blocking name = has_effect name Os_worker_blocking

let capability_special_inference = function
  | Special_inference special_inference -> Some special_inference
  | Effect _ -> None

let special_inference name =
  match find name with
  | Some d -> List.find_map capability_special_inference d.capabilities
  | None -> None
