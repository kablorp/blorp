(** Typed metadata for builtins that have compiler-visible behavior.

    Keep semantic facts here instead of scattering name sets through compiler
    phases. Unknown names are treated as ordinary user/module functions. *)

type wait_effect =
  | No_wait
  | May_park_fiber
  | May_block_thread
  (* Some calls have a blocking setup phase followed by a fiber-aware wait, e.g.
     TCP connect with inline getaddrinfo and nonblocking socket connect. *)
  | May_block_thread_and_park_fiber

type cancellation_effect = Not_cancellation_point | Cancellation_point

type impure_call_effect = {
  wait : wait_effect;
  cancellation : cancellation_effect;
}

type call_effect = Pure | Impure of impure_call_effect
type builtin_effect = Impure_call | Parallel_boundary

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
  | Call_effect of call_effect
  | Effect of builtin_effect
  | Special_inference of special_inference

type descriptor = { name : string; capabilities : capability list }

let descriptor name capabilities =
  match capabilities with
  | [] ->
      invalid_arg ("Builtin_metadata.descriptor: " ^ name ^ " has no behavior")
  | _ -> { name; capabilities }

let call_effect name call_effect = descriptor name [ Call_effect call_effect ]

let impure_call ~wait ~cancellation name =
  call_effect name (Impure { wait; cancellation })

let impure_no_wait name =
  impure_call ~wait:No_wait ~cancellation:Not_cancellation_point name

let impure_may_park name =
  impure_call ~wait:May_park_fiber ~cancellation:Cancellation_point name

let impure_may_block_thread name =
  impure_call ~wait:May_block_thread ~cancellation:Not_cancellation_point name

let impure_may_block_thread_and_park name =
  impure_call ~wait:May_block_thread_and_park_fiber
    ~cancellation:Cancellation_point name

let default_foreign_call_effect ~is_pure =
  if is_pure then Pure
  else Impure { wait = May_block_thread; cancellation = Not_cancellation_point }

let parallel_boundary name = descriptor name [ Effect Parallel_boundary ]

let special name special_inference =
  descriptor name [ Special_inference special_inference ]

let impure_no_wait_names =
  [
    "print";
    "puts";
    "err_print";
    "__print_string";
    "__puts_string";
    "__err_print_string";
    "seed_random";
    "random_int";
    "random_float";
    "now";
    "now_us";
    "now_microseconds";
    "channel";
    "try_send";
    "try_recv";
    "close";
    "getenv";
    "setenv";
    "reset_mem_stats";
    "get_scheduler_stats";
    "reset_scheduler_stats";
    "signal_on_builtin";
    "signal_raise_builtin";
    "signal_received_builtin";
    "init_window";
    "close_window";
    "window_should_close";
    "set_target_fps";
    "get_fps";
    "begin_drawing";
    "end_drawing";
    "clear_background";
    "draw_rectangle";
    "draw_rectangle_rec";
    "draw_circle";
    "draw_line";
    "draw_text";
    "is_key_pressed";
    "is_key_down";
    "get_mouse_x";
    "get_mouse_y";
    "is_mouse_button_pressed";
    "is_mouse_button_down";
    "get_frame_time";
    "get_time";
    "set_reuse_addr";
    "local_port";
  ]

let impure_may_park_names =
  [
    "sleep";
    "send";
    "recv";
    "send_timeout";
    "recv_timeout";
    "accept";
    "read";
    "write";
  ]

let impure_may_block_thread_and_park_names = [ "connect" ]

let impure_may_block_thread_names =
  [
    "read_file";
    "write_file";
    "read_bytes";
    "write_bytes";
    "file_exists";
    "list_dir";
    "is_directory";
    "exec";
    "exec_output";
    "read_line";
    "read_line_opt";
    "read_line_or_empty";
    "read_all";
    "input";
    "input_opt";
    "input_or_empty";
    "read_all_lines";
    "write_lines";
    "append_file";
    "for_each_line";
    "for_each_chunk";
    "file_size";
    "file_modified";
    "temp_dir";
    "mkstemp_path";
    "getcwd";
    "mkdir";
    "remove_file";
    "remove_dir";
    "rename";
    "crypto_random_bytes";
    "process_run";
    "process_shell";
    "listen";
    "set_timeout";
  ]

let parallel_boundary_names =
  [
    "parallel";
    "map_parallel";
    "map_indexed_parallel";
    "fold_parallel";
    "zip_parallel";
    "map_parallel_with";
    "map_indexed_parallel_with";
    "fold_parallel_with";
    "zip_parallel_with";
  ]

let descriptors =
  List.map impure_no_wait impure_no_wait_names
  @ List.map impure_may_park impure_may_park_names
  @ List.map impure_may_block_thread_and_park
      impure_may_block_thread_and_park_names
  @ List.map impure_may_block_thread impure_may_block_thread_names
  @ List.map parallel_boundary parallel_boundary_names
  @ [
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

let duplicate_names =
  let _seen, duplicates =
    List.fold_left
      (fun (seen, duplicates) { name; _ } ->
        if StringSet.mem name seen then (seen, StringSet.add name duplicates)
        else (StringSet.add name seen, duplicates))
      (StringSet.empty, StringSet.empty)
      descriptors
  in
  StringSet.elements duplicates

let inert_descriptor_names =
  descriptors
  |> List.filter_map (fun { name; capabilities } ->
      match capabilities with [] -> Some name | _ -> None)
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

let call_effect name =
  match find name with
  | Some d ->
      List.find_map
        (function
          | Call_effect call_effect -> Some call_effect
          | Effect _ | Special_inference _ -> None)
        d.capabilities
  | None -> None

let channel_stack_option_suffixes =
  [
    "int";
    "int8";
    "int16";
    "int32";
    "int64";
    "uint8";
    "uint16";
    "uint32";
    "uint64";
    "float";
    "bool";
    "char";
    "f32";
    "f16";
  ]

let channel_recv_runtime_symbols base =
  base :: (base ^ "_nullable")
  :: List.map (Printf.sprintf "%s_%s" base) channel_stack_option_suffixes

let runtime_symbols_for source_name runtime_symbols =
  List.map (fun runtime_symbol -> (runtime_symbol, source_name)) runtime_symbols

let blorp_runtime_symbols source_names =
  List.map
    (fun source_name -> ("blorp_" ^ source_name, source_name))
    source_names

let prefixed_runtime_symbols prefix source_names =
  List.map (fun source_name -> (prefix ^ source_name, source_name)) source_names

let runtime_symbol_sources =
  blorp_runtime_symbols
    [
      "append_file";
      "crypto_random_bytes";
      "exec";
      "exec_output";
      "file_exists";
      "file_modified";
      "file_size";
      "for_each_chunk";
      "for_each_line";
      "get_scheduler_stats";
      "getcwd";
      "getenv";
      "input";
      "input_or_empty";
      "is_directory";
      "list_dir";
      "mkdir";
      "mkstemp_path";
      "process_run";
      "process_shell";
      "random_float";
      "random_int";
      "read_all_lines";
      "read_bytes";
      "read_file";
      "read_line";
      "read_line_or_empty";
      "remove_dir";
      "remove_file";
      "rename";
      "reset_mem_stats";
      "reset_scheduler_stats";
      "seed_random";
      "setenv";
      "sleep";
      "temp_dir";
      "write_bytes";
      "write_file";
    ]
  @ prefixed_runtime_symbols "blorp_tcp_"
      [ "accept"; "connect"; "listen"; "read"; "set_reuse_addr"; "write" ]
  @ [
      ("blorp_tcp_close_listener", "close");
      ("blorp_tcp_close_stream", "close");
      ("blorp_tcp_local_port_listener", "local_port");
      ("blorp_tcp_local_port_stream", "local_port");
      ("blorp_tcp_set_timeout_listener", "set_timeout");
      ("blorp_tcp_set_timeout_stream", "set_timeout");
    ]
  @ [
      ("blorp_channel_new", "channel");
      ("blorp_channel_send", "send");
      ("blorp_channel_send_timeout", "send_timeout");
      ("blorp_channel_try_send", "try_send");
      ("blorp_channel_close", "close");
      ("blorp_err_print", "__err_print_string");
      ("blorp_now_us", "now_microseconds");
      ("blorp_print", "__print_string");
      ("blorp_puts", "__puts_string");
      ("blorp_signal_on", "signal_on_builtin");
      ("blorp_signal_raise", "signal_raise_builtin");
      ("blorp_signal_received", "signal_received_builtin");
      ("blorp_time_now", "now");
    ]
  @ runtime_symbols_for "recv"
      (channel_recv_runtime_symbols "blorp_channel_recv")
  @ runtime_symbols_for "try_recv"
      (channel_recv_runtime_symbols "blorp_channel_try_recv")
  @ runtime_symbols_for "recv_timeout"
      (channel_recv_runtime_symbols "blorp_channel_recv_timeout")

let runtime_symbol_registry =
  List.fold_left
    (fun acc (runtime_symbol, source_name) ->
      match call_effect source_name with
      | Some call_eff -> StringMap.add runtime_symbol call_eff acc
      | None -> acc)
    StringMap.empty runtime_symbol_sources

let call_effect_for_runtime_symbol runtime_symbol =
  StringMap.find_opt runtime_symbol runtime_symbol_registry

let call_effect_may_park_fiber = function
  | Impure { wait = May_park_fiber; _ }
  | Impure { wait = May_block_thread_and_park_fiber; _ } ->
      true
  | Pure | Impure _ -> false

let runtime_symbol_may_park_fiber runtime_symbol =
  match call_effect_for_runtime_symbol runtime_symbol with
  | Some call_effect -> call_effect_may_park_fiber call_effect
  | None -> false

let has_effect name builtin_effect =
  match builtin_effect with
  | Impure_call -> (
      match call_effect name with Some (Impure _) -> true | _ -> false)
  | Parallel_boundary -> (
      match find name with
      | Some d ->
          List.exists
            (function
              | Effect Parallel_boundary -> true
              | Effect Impure_call | Call_effect _ | Special_inference _ ->
                  false)
            d.capabilities
      | None -> false)

let is_impure name = has_effect name Impure_call
let is_parallel_boundary name = has_effect name Parallel_boundary

let special_inference name =
  match find name with
  | Some d ->
      List.find_map
        (function
          | Special_inference special_inference -> Some special_inference
          | Call_effect _ | Effect _ -> None)
        d.capabilities
  | None -> None
