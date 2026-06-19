(** Single JSON transfer point for Blorp-owned compiler snippets, policies, and
    downstream compile artifacts.

    Renderer JSON requests are served by [compiler/blorp/compiler_bridge.brp]
    through the hidden bridge command. The manifest helpers left in this module
    are a temporary bootstrap path for hot in-process emission call sites. *)

let schema_version = 1
let domain = "compiler"

let static_constant_renderer = "static_constant"
let intrinsic_renderer = "intrinsic"
let prepared_backend_renderer = "prepared_backend"
let prepared_list_renderer = "prepared_list"
let prepared_tensor_renderer = "prepared_tensor"
let prepared_constructor_renderer = "prepared_constructor"
let prepared_tuple_renderer = "prepared_tuple"
let core_fairness_renderer = "core_fairness"
let language_surface_renderer = "language_surface"

let ( let* ) result f =
  match result with Ok value -> f value | Error _ as error -> error

let compile_source_action = "compile_source"

type render_item = { item_op : string; item_args : string list }

type command_compile_result = {
  command_c_code : string;
  command_link_flags : string list;
  command_include_dirs : string list;
}

let rec find_upwards start name =
  let candidate = Filename.concat start name in
  if Sys.file_exists candidate && not (Sys.is_directory candidate) then
    Some candidate
  else
    let parent = Filename.dirname start in
    if parent = start then None else find_upwards parent name

let read_file path =
  let channel = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr channel)
    (fun () ->
      let len = in_channel_length channel in
      really_input_string channel len)

let compiler_lib_file name =
  Filename.concat (Filename.concat "compiler" "lib") name

let template_manifest_tsv filename =
  let rel = compiler_lib_file filename in
  let starts = [ Sys.getcwd (); Filename.dirname Sys.executable_name ] in
  let rec find = function
    | [] ->
        invalid_arg
          (Printf.sprintf "cannot locate Blorp template manifest %s" rel)
    | start :: rest -> (
        match find_upwards start rel with
        | Some path -> read_file path
        | None -> find rest)
  in
  find starts

let static_constant_manifest =
  Core_emit_blorp_template.create ~label:"static constant"
    (template_manifest_tsv "core_emit_blorp_static_constant_templates.tsv")

let intrinsic_manifest =
  Core_emit_blorp_template.create ~initial_size:64 ~label:"codegen intrinsic"
    (template_manifest_tsv "core_emit_blorp_intrinsic_templates.tsv")

let prepared_backend_manifest =
  Core_emit_blorp_template.create ~label:"codegen prepared backend"
    (template_manifest_tsv "core_emit_blorp_prepared_backend_templates.tsv")

let prepared_list_manifest =
  Core_emit_blorp_template.create ~label:"codegen prepared list"
    (template_manifest_tsv "core_emit_blorp_prepared_list_templates.tsv")

let prepared_tensor_manifest =
  Core_emit_blorp_template.create ~label:"codegen prepared tensor"
    (template_manifest_tsv "core_emit_blorp_prepared_tensor_templates.tsv")

let prepared_constructor_manifest =
  Core_emit_blorp_template.create ~label:"codegen prepared constructor"
    (template_manifest_tsv "core_emit_blorp_prepared_constructor_templates.tsv")

let prepared_tuple_manifest =
  Core_emit_blorp_template.create ~label:"codegen prepared tuple"
    (template_manifest_tsv "core_emit_blorp_prepared_tuple_templates.tsv")

let manifest_for_renderer = function
  | renderer when renderer = static_constant_renderer -> Ok static_constant_manifest
  | renderer when renderer = intrinsic_renderer -> Ok intrinsic_manifest
  | renderer when renderer = prepared_backend_renderer -> Ok prepared_backend_manifest
  | renderer when renderer = prepared_list_renderer -> Ok prepared_list_manifest
  | renderer when renderer = prepared_tensor_renderer -> Ok prepared_tensor_manifest
  | renderer when renderer = prepared_constructor_renderer ->
      Ok prepared_constructor_manifest
  | renderer when renderer = prepared_tuple_renderer -> Ok prepared_tuple_manifest
  | renderer ->
      Error ("unsupported_renderer", "unsupported Blorp renderer: " ^ renderer)

let json_string s = Lsp_json.String s

let error_response code message =
  Lsp_json.to_string
    (Lsp_json.Object
       [
         ("schema", Lsp_json.Int schema_version);
         ("ok", Lsp_json.Bool false);
         ( "error",
           Lsp_json.Object
             [ ("code", Lsp_json.String code); ("message", Lsp_json.String message) ]
         );
       ])

let error_response_with_fields code message fields =
  Lsp_json.to_string
    (Lsp_json.Object
       [
         ("schema", Lsp_json.Int schema_version);
         ("ok", Lsp_json.Bool false);
         ( "error",
           Lsp_json.Object
             (("code", Lsp_json.String code)
             :: ("message", Lsp_json.String message)
             :: fields) );
       ])

let success_response fields =
  Lsp_json.to_string
    (Lsp_json.Object
       (("schema", Lsp_json.Int schema_version)
       :: ("ok", Lsp_json.Bool true)
       :: fields))

let string_field name = function
  | Lsp_json.Object fields -> (
      match List.assoc_opt name fields with
      | Some (Lsp_json.String value) -> Ok value
      | Some _ -> Error ("invalid_request", "field `" ^ name ^ "` must be a string")
      | None -> Error ("invalid_request", "missing string field `" ^ name ^ "`"))
  | _ -> Error ("invalid_request", "bridge request must be a JSON object")

let int_field name = function
  | Lsp_json.Object fields -> (
      match List.assoc_opt name fields with
      | Some (Lsp_json.Int value) -> Ok value
      | Some _ -> Error ("invalid_request", "field `" ^ name ^ "` must be an integer")
      | None -> Error ("invalid_request", "missing integer field `" ^ name ^ "`"))
  | _ -> Error ("invalid_request", "bridge request must be a JSON object")

let bool_field name = function
  | Lsp_json.Object fields -> (
      match List.assoc_opt name fields with
      | Some (Lsp_json.Bool value) -> Ok value
      | Some _ -> Error ("invalid_response", "field `" ^ name ^ "` must be a boolean")
      | None -> Error ("invalid_response", "missing boolean field `" ^ name ^ "`"))
  | _ -> Error ("invalid_response", "bridge response must be a JSON object")

let string_response_field name = function
  | Lsp_json.Object fields -> (
      match List.assoc_opt name fields with
      | Some (Lsp_json.String value) -> Ok value
      | Some _ -> Error ("invalid_response", "field `" ^ name ^ "` must be a string")
      | None -> Error ("invalid_response", "missing string field `" ^ name ^ "`"))
  | _ -> Error ("invalid_response", "bridge response must be a JSON object")

let string_list_response_field name = function
  | Lsp_json.Object fields -> (
      match List.assoc_opt name fields with
      | Some (Lsp_json.Array values) ->
          let rec collect acc = function
            | [] -> Ok (List.rev acc)
            | Lsp_json.String value :: rest -> collect (value :: acc) rest
            | _ ->
                Error
                  ( "invalid_response",
                    "field `" ^ name ^ "` must be an array of strings" )
          in
          collect [] values
      | Some _ -> Error ("invalid_response", "field `" ^ name ^ "` must be an array")
      | None -> Error ("invalid_response", "missing array field `" ^ name ^ "`"))
  | _ -> Error ("invalid_response", "bridge response must be a JSON object")

let error_message_response_field = function
  | Lsp_json.Object fields -> (
      match List.assoc_opt "error" fields with
      | Some (Lsp_json.Object error_fields) -> (
          match List.assoc_opt "message" error_fields with
          | Some (Lsp_json.String message) -> Ok message
          | Some _ -> Error ("invalid_response", "error.message must be a string")
          | None -> Error ("invalid_response", "missing error.message"))
      | Some _ -> Error ("invalid_response", "error must be an object")
      | None -> Error ("invalid_response", "missing error object"))
  | _ -> Error ("invalid_response", "bridge response must be a JSON object")

let render_item_json (op, args) =
  Lsp_json.Object
    [
      ("op", Lsp_json.String op);
      ("args", Lsp_json.Array (List.map json_string args));
    ]

let render_many_request_json ~renderer items =
  Lsp_json.to_string
    (Lsp_json.Object
       [
         ("schema", Lsp_json.Int schema_version);
         ("domain", Lsp_json.String domain);
         ("action", Lsp_json.String "render_many");
         ("renderer", Lsp_json.String renderer);
         ("args", Lsp_json.Array []);
         ("items", Lsp_json.Array (List.map render_item_json items));
       ])

let compile_source_request_json ~filename ~source ~debug ~embed_runtime
    ~require_main ~profile ~check_invariants () =
  Lsp_json.to_string
    (Lsp_json.Object
       [
         ("schema", Lsp_json.Int schema_version);
         ("domain", Lsp_json.String domain);
         ("action", Lsp_json.String compile_source_action);
         ("filename", Lsp_json.String filename);
         ("source", Lsp_json.String source);
         ("debug", Lsp_json.Bool debug);
         ("embed_runtime", Lsp_json.Bool embed_runtime);
         ("require_main", Lsp_json.Bool require_main);
         ("profile", Lsp_json.Bool profile);
         ("check_invariants", Lsp_json.Bool check_invariants);
       ])

let parse_response_json response_json =
  try Ok (Lsp_json.parse response_json)
  with Lsp_json.Parse_error message -> Error ("invalid_response", message)

let response_result response_json success =
  let* response = parse_response_json response_json in
  let* ok = bool_field "ok" response in
  if ok then success response
  else
    let* message = error_message_response_field response in
    Error ("bridge_error", message)

let render_exn ~renderer ~op args =
  match manifest_for_renderer renderer with
  | Ok manifest -> Core_emit_blorp_template.render_exn manifest op args
  | Error (_, message) -> invalid_arg message

let render_many_response_field = function
  | Lsp_json.Object fields -> (
      match List.assoc_opt "items" fields with
      | Some (Lsp_json.Array values) ->
          let parse_item = function
            | Lsp_json.Object item_fields -> (
                match
                  ( List.assoc_opt "op" item_fields,
                    List.assoc_opt "text" item_fields )
                with
                | Some (Lsp_json.String op), Some (Lsp_json.String text) ->
                    Ok (op, text)
                | _ ->
                    Error
                      ( "invalid_response",
                        "render_many items must contain string op and text" ))
            | _ ->
                Error
                  ("invalid_response", "render_many items must be JSON objects")
          in
          let rec collect acc = function
            | [] -> Ok (List.rev acc)
            | value :: rest ->
                let* item = parse_item value in
                collect (item :: acc) rest
          in
          collect [] values
      | Some _ -> Error ("invalid_response", "field `items` must be an array")
      | None -> Error ("invalid_response", "missing array field `items`"))
  | _ -> Error ("invalid_response", "bridge response must be a JSON object")

let command_compile_result_response_field response =
  let* c_code = string_response_field "c_code" response in
  let* link_flags = string_list_response_field "link_flags" response in
  let* include_dirs = string_list_response_field "include_dirs" response in
  Ok { command_c_code = c_code; command_link_flags = link_flags; command_include_dirs = include_dirs }

let render_many_exn ~renderer items =
  match manifest_for_renderer renderer with
  | Ok manifest ->
      List.map
        (fun (op, args) -> (op, Core_emit_blorp_template.render_exn manifest op args))
        items
  | Error (_, message) -> invalid_arg message

let language_surface_bootstrap_rows =
  [
    ( "language_lsp_completion_keywords",
      "func;pure;var;union;record;void;while;for;in;if;else;and;or;not;match;True;False;break;continue;debug;struct;enum;with;resource;foreign;private;builtin;concurrent;concurrently;detach;select;into;from;after;sealed;import;as;trait;implements;Self;type;alias;where"
    );
    ( "language_prelude_method_type_imports",
      "option:Option;result:Result;bool:Bool;char:Char;bytes:Bytes;string:String;list:List;list:ParallelList;parallel_list:ParallelList;vector:ParallelVector;parallel_vector:ParallelVector;matrix:ParallelMatrix;parallel_matrix:ParallelMatrix;range:Range;dict:Dict;set:Set;file:FileReader;file:FileWriter;file:FileAppender;file:FileReadWriter;file:FileReadAppender"
    );
  ]

let core_fairness_bootstrap_rows =
  [
    ("fairness_body_checkpoint", "true");
    ("fairness_body_seq_checkpoint", "true");
    ("fairness_body_other", "false");
  ]

let render_zero_arg_bootstrap_item ~label ~rows op args =
  if args <> [] then
    invalid_arg
      (Printf.sprintf "%s %s expected 0 arg(s), got %d" label op
         (List.length args));
  match List.assoc_opt op rows with
  | Some text -> (op, text)
  | None -> invalid_arg ("unsupported " ^ label ^ ": " ^ op)

let render_many_for_renderer_helper_exn ~renderer items =
  if String.equal renderer language_surface_renderer then
    List.map
      (fun (op, args) ->
        render_zero_arg_bootstrap_item ~label:"language surface op"
          ~rows:language_surface_bootstrap_rows op args)
      items
  else if String.equal renderer core_fairness_renderer then
    List.map
      (fun (op, args) ->
        render_zero_arg_bootstrap_item ~label:"fairness op"
          ~rows:core_fairness_bootstrap_rows op args)
      items
  else render_many_exn ~renderer items

let command_child_env = "BLORP_COMPILER_BRIDGE_CHILD"
let renderer_bridge_helper_env = "BLORP_COMPILER_RENDERER_HELPER"
let renderer_bridge_source_env = "BLORP_COMPILER_BRIDGE_RENDERER_SOURCE"
let renderer_bridge_source_name = "compiler/blorp/compiler_bridge_cli.brp"
let renderer_bridge_timeout_seconds = 20
let renderer_bridge_cache : (string * string * string) option ref = ref None
let bridge_temp_retry_limit = 32

let running_inside_renderer_bridge_helper () =
  match Sys.getenv_opt renderer_bridge_helper_env with Some "1" -> true | _ -> false

let read_all_fd fd =
  let buf = Buffer.create 4096 in
  let bytes = Bytes.create 4096 in
  let rec loop () =
    match Unix.read fd bytes 0 4096 with
    | 0 -> ()
    | n ->
        Buffer.add_subbytes buf bytes 0 n;
        loop ()
    | exception Unix.Unix_error (Unix.EINTR, _, _) -> loop ()
  in
  loop ();
  Buffer.contents buf

let read_file_if_exists path =
  if not (Sys.file_exists path) then ""
  else
    let channel = open_in_bin path in
    Fun.protect
      ~finally:(fun () -> close_in_noerr channel)
      (fun () ->
        let len = in_channel_length channel in
        really_input_string channel len)

let rec waitpid_retry pid =
  try snd (Unix.waitpid [] pid)
  with Unix.Unix_error (Unix.EINTR, _, _) -> waitpid_retry pid

let exit_code_of_status = function
  | Unix.WEXITED code -> code
  | Unix.WSIGNALED signal -> 128 + signal
  | Unix.WSTOPPED _ -> 128

let rec remove_path_noerr path =
  try
    match (Unix.lstat path).Unix.st_kind with
    | Unix.S_DIR ->
        Sys.readdir path
        |> Array.iter (fun name ->
               remove_path_noerr (Filename.concat path name));
        Unix.rmdir path
    | _ -> Sys.remove path
  with _ -> ()

let bridge_temp_path prefix suffix =
  Filename.concat (Filename.get_temp_dir_name ())
    (Printf.sprintf "%s%d-%d%s" prefix (Unix.getpid ())
       (Random.bits () land 0x3fffffff)
       suffix)

let rec create_bridge_temp_file prefix suffix attempts_left =
  let path = bridge_temp_path prefix suffix in
  try
    let fd =
      Unix.openfile path [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_EXCL ] 0o600
    in
    (path, fd)
  with Unix.Unix_error (Unix.EEXIST, _, _) when attempts_left > 0 ->
    create_bridge_temp_file prefix suffix (attempts_left - 1)

let write_temp_request request_json =
  let path, fd =
    create_bridge_temp_file "blorp-compiler-bridge-" ".json"
      bridge_temp_retry_limit
  in
  let channel = Unix.out_channel_of_descr fd in
  Fun.protect
    ~finally:(fun () -> close_out_noerr channel)
    (fun () -> output_string channel request_json);
  path

let run_process_capture ?(env = []) prog args =
  let read_fd, write_fd = Unix.pipe () in
  let stderr_path, stderr_fd =
    create_bridge_temp_file "blorp-compiler-bridge-stderr-" ".log"
      bridge_temp_retry_limit
  in
  match Unix.fork () with
  | 0 ->
      (try
         Unix.dup2 write_fd Unix.stdout;
         Unix.dup2 stderr_fd Unix.stderr;
         Unix.close read_fd;
         Unix.close write_fd;
         Unix.close stderr_fd;
         Unix.putenv command_child_env "1";
         List.iter (fun (name, value) -> Unix.putenv name value) env;
         Unix.execvp prog (Array.of_list (prog :: args))
       with _ -> Unix._exit 127)
  | pid ->
      Unix.close write_fd;
      Unix.close stderr_fd;
      let output = read_all_fd read_fd in
      Unix.close read_fd;
      let status = waitpid_retry pid in
      let stderr_output = read_file_if_exists stderr_path in
      (try Sys.remove stderr_path with _ -> ());
      (exit_code_of_status status, output, stderr_output)

let default_command_program () =
  match Sys.getenv_opt "BLORP_COMPILER_BRIDGE_BIN" with
  | Some path when path <> "" -> path
  | _ -> (
      let exe = Sys.executable_name in
      let exe_base = Filename.basename exe in
      if
        (String.equal exe_base "blorp" || String.equal exe_base "blorp.exe")
        && Sys.file_exists exe
      then exe
      else
        match find_upwards (Sys.getcwd ()) "blorp" with
        | Some path -> path
        | None -> exe)

let renderer_bridge_source_path () =
  match Sys.getenv_opt renderer_bridge_source_env with
  | Some path when path <> "" -> path
  | _ -> (
      match find_upwards (Sys.getcwd ()) renderer_bridge_source_name with
      | Some path -> path
      | None -> renderer_bridge_source_name)

let renderer_bridge_temp_dir_retry_limit = 32

let rec create_renderer_bridge_temp_dir attempts_left =
  let marker =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "blorp-renderer-bridge-%d-%d" (Unix.getpid ())
         (Random.bits () land 0x3fffffff))
  in
  try
    Unix.mkdir marker 0o700;
    marker
  with
  | Unix.Unix_error (Unix.EEXIST, _, _) when attempts_left > 0 ->
      create_renderer_bridge_temp_dir (attempts_left - 1)
  | exn ->
      remove_path_noerr marker;
      raise exn

let compile_renderer_bridge_binary ~program ~source_path =
  let temp_dir = create_renderer_bridge_temp_dir renderer_bridge_temp_dir_retry_limit in
  let c_path = Filename.concat temp_dir "bridge.c" in
  let bin_path = Filename.concat temp_dir "bridge.bin" in
  let keep_temp_dir = ref false in
  Fun.protect
    ~finally:(fun () ->
      (try Sys.remove c_path with _ -> ());
      if not !keep_temp_dir then remove_path_noerr temp_dir)
    (fun () ->
      let compile_code, compile_output, compile_stderr =
        run_process_capture program
          ~env:[ (renderer_bridge_helper_env, "1") ]
          [ "compile"; "--no-format"; "-o"; c_path; source_path ]
      in
      if compile_code <> 0 then
        Error
          (Printf.sprintf "failed to compile Blorp renderer bridge: %s"
             (String.trim (compile_output ^ compile_stderr)))
      else
        let cc_code, cc_output, cc_stderr =
          run_process_capture "cc"
            [ "-O0"; "-fwrapv"; "-pipe"; "-w"; c_path; "-lm"; "-lpthread"; "-o"; bin_path ]
        in
        if cc_code <> 0 then
          Error
            (Printf.sprintf "failed to build Blorp renderer bridge binary: %s"
               (String.trim (cc_output ^ cc_stderr)))
        else (
          keep_temp_dir := true;
          Ok bin_path))

let renderer_bridge_binary ?program () =
  let program = Option.value program ~default:(default_command_program ()) in
  let source_path = renderer_bridge_source_path () in
  match !renderer_bridge_cache with
  | Some (cached_program, cached_source, cached_binary)
    when String.equal cached_program program
         && String.equal cached_source source_path
         && Sys.file_exists cached_binary ->
      Ok cached_binary
  | _ -> (
      match compile_renderer_bridge_binary ~program ~source_path with
      | Ok binary ->
          renderer_bridge_cache := Some (program, source_path, binary);
          Ok binary
      | Error _ as error -> error)

let run_renderer_request_via_blorp ?program request_json =
  match renderer_bridge_binary ?program () with
  | Error message -> error_response "bridge_command_failed" message
  | Ok bridge_binary ->
      let request_path = write_temp_request request_json in
      Fun.protect
        ~finally:(fun () -> try Sys.remove request_path with _ -> ())
        (fun () ->
          let exit_code, output, stderr_output =
            run_process_capture bridge_binary [ request_path ]
          in
          if exit_code = 0 then output
          else
            error_response "bridge_command_failed"
              (Printf.sprintf "Blorp renderer bridge command exited %d: %s"
                 exit_code
                 (String.trim (output ^ stderr_output))))

let run_request_via_command ?program request_json =
  let program = Option.value program ~default:(default_command_program ()) in
  let request_path = write_temp_request request_json in
  Fun.protect
    ~finally:(fun () -> try Sys.remove request_path with _ -> ())
    (fun () ->
      let exit_code, output, stderr_output =
        run_process_capture program [ "__compiler-bridge"; request_path ]
      in
      if exit_code = 0 then output
      else
        error_response "bridge_command_failed"
          (Printf.sprintf "Blorp compiler bridge command exited %d: %s"
             exit_code
             (String.trim (output ^ stderr_output))))

let compile_source_via_command ?program ~filename ~source ~debug ~embed_runtime
    ~require_main ~profile ~check_invariants () =
  let request_json =
    compile_source_request_json ~filename ~source ~debug ~embed_runtime
      ~require_main ~profile ~check_invariants ()
  in
  let response_json = run_request_via_command ?program request_json in
  response_result response_json command_compile_result_response_field

let render_many_via_command_exn ?program ~renderer items =
  if running_inside_renderer_bridge_helper () then
    render_many_for_renderer_helper_exn ~renderer items
  else
    let response_json =
      run_renderer_request_via_blorp ?program (render_many_request_json ~renderer items)
    in
    match response_result response_json render_many_response_field with
    | Ok rendered -> rendered
    | Error (_, message) -> invalid_arg message

let parse_colon_pair_exn ~label entry =
  try
    let index = String.index entry ':' in
    let left = String.sub entry 0 index in
    let right =
      String.sub entry (index + 1) (String.length entry - index - 1)
    in
    if String.equal left "" || String.equal right "" then
      invalid_arg ("invalid " ^ label ^ " entry: " ^ entry)
    else (left, right)
  with Not_found -> invalid_arg ("invalid " ^ label ^ " entry: " ^ entry)

let names ~renderer =
  match manifest_for_renderer renderer with
  | Ok manifest -> Core_emit_blorp_template.names manifest
  | Error (_, message) -> invalid_arg message

let arity ~renderer ~op =
  match manifest_for_renderer renderer with
  | Ok manifest -> (
      match Core_emit_blorp_template.find manifest op with
      | Some { Core_emit_blorp_template.arity; _ } -> Some arity
      | None -> None)
  | Error _ -> None

let emit ctx ~renderer ~op args =
  Core_emit_context.emit ctx (render_exn ~renderer ~op args)
