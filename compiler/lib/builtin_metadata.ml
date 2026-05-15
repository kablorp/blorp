(** Typed metadata for builtins that have compiler-visible behavior.

    Keep semantic facts here instead of scattering name sets through compiler
    phases. Unknown names are treated as ordinary user/module functions. *)

type wait_effect = No_wait | May_park_fiber | May_block_thread
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

let parallel_boundary name = descriptor name [ Effect Parallel_boundary ]

let special name special_inference =
  descriptor name [ Special_inference special_inference ]

let impure_no_wait_names =
  [
    "print";
    "puts";
    "println";
    "eprintln";
    "seed_random";
    "random_int";
    "random_float";
    "now";
    "now_us";
    "channel";
    "try_send";
    "try_recv";
    "close";
    "getenv";
    "setenv";
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
  [ "sleep"; "send"; "recv"; "send_timeout"; "recv_timeout" ]

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
    "getcwd";
    "mkdir";
    "remove_file";
    "remove_dir";
    "rename";
    "listen";
    "accept";
    "connect";
    "read";
    "write";
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
