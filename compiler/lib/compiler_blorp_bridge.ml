(** Single JSON transfer point for Blorp-owned compiler snippets, policies, and
    downstream compile artifacts.

    OCaml may keep typed convenience wrappers around renderer operations, but
    those wrappers must cross this module. This module owns the JSON envelope,
    dispatches to the checked-in Blorp-generated manifests, and returns JSON
    responses that callers decode back into OCaml values. *)

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

type action = Render | RenderMany | ListOps | TemplateArity

let compile_source_action = "compile_source"

type render_item = { item_op : string; item_args : string list }

type command_compile_result = {
  command_c_code : string;
  command_link_flags : string list;
  command_include_dirs : string list;
}

type request = {
  action : action;
  renderer : string;
  op : string option;
  args : string list;
  items : render_item list;
}

let static_constant_manifest =
  Core_emit_blorp_template.create ~label:"static constant"
    Core_emit_blorp_static_constant_templates.tsv

let intrinsic_manifest =
  Core_emit_blorp_template.create ~initial_size:64 ~label:"codegen intrinsic"
    Core_emit_blorp_intrinsic_templates.tsv

let prepared_backend_manifest =
  Core_emit_blorp_template.create ~label:"codegen prepared backend"
    Core_emit_blorp_prepared_backend_templates.tsv

let prepared_list_manifest =
  Core_emit_blorp_template.create ~label:"codegen prepared list"
    Core_emit_blorp_prepared_list_templates.tsv

let prepared_tensor_manifest =
  Core_emit_blorp_template.create ~label:"codegen prepared tensor"
    Core_emit_blorp_prepared_tensor_templates.tsv

let prepared_constructor_manifest =
  Core_emit_blorp_template.create ~label:"codegen prepared constructor"
    Core_emit_blorp_prepared_constructor_templates.tsv

let prepared_tuple_manifest =
  Core_emit_blorp_template.create ~label:"codegen prepared tuple"
    Core_emit_blorp_prepared_tuple_templates.tsv

let core_fairness_manifest =
  Core_emit_blorp_template.create ~label:"Core fairness policy"
    Core_fairness_blorp_policy_templates.tsv

let language_surface_manifest =
  Core_emit_blorp_template.create ~label:"language surface"
    Language_surface_blorp_templates.tsv

let manifest_for_renderer = function
  | renderer when renderer = static_constant_renderer -> Ok static_constant_manifest
  | renderer when renderer = intrinsic_renderer -> Ok intrinsic_manifest
  | renderer when renderer = prepared_backend_renderer -> Ok prepared_backend_manifest
  | renderer when renderer = prepared_list_renderer -> Ok prepared_list_manifest
  | renderer when renderer = prepared_tensor_renderer -> Ok prepared_tensor_manifest
  | renderer when renderer = prepared_constructor_renderer ->
      Ok prepared_constructor_manifest
  | renderer when renderer = prepared_tuple_renderer -> Ok prepared_tuple_manifest
  | renderer when renderer = core_fairness_renderer -> Ok core_fairness_manifest
  | renderer when renderer = language_surface_renderer ->
      Ok language_surface_manifest
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

let optional_string_field name = function
  | Lsp_json.Object fields -> (
      match List.assoc_opt name fields with
      | None -> Ok None
      | Some (Lsp_json.String value) -> Ok (Some value)
      | Some _ -> Error ("invalid_request", "field `" ^ name ^ "` must be a string"))
  | _ -> Error ("invalid_request", "bridge request must be a JSON object")

let int_field name = function
  | Lsp_json.Object fields -> (
      match List.assoc_opt name fields with
      | Some (Lsp_json.Int value) -> Ok value
      | Some _ -> Error ("invalid_request", "field `" ^ name ^ "` must be an integer")
      | None -> Error ("invalid_request", "missing integer field `" ^ name ^ "`"))
  | _ -> Error ("invalid_request", "bridge request must be a JSON object")

let optional_string_list_field name = function
  | Lsp_json.Object fields -> (
      match List.assoc_opt name fields with
      | None -> Ok []
      | Some (Lsp_json.Array values) ->
          let rec collect acc = function
            | [] -> Ok (List.rev acc)
            | Lsp_json.String value :: rest -> collect (value :: acc) rest
            | _ ->
                Error
                  ( "invalid_request",
                    "field `" ^ name ^ "` must be an array of strings" )
          in
          collect [] values
      | Some _ -> Error ("invalid_request", "field `" ^ name ^ "` must be an array"))
  | _ -> Error ("invalid_request", "bridge request must be a JSON object")

let action_of_string = function
  | "render" -> Ok Render
  | "render_many" -> Ok RenderMany
  | "list_ops" -> Ok ListOps
  | "template_arity" -> Ok TemplateArity
  | action ->
      Error ("unsupported_action", "unsupported Blorp bridge action: " ^ action)

let render_item_of_json = function
  | Lsp_json.Object fields as json ->
      let* item_op = string_field "op" json in
      let args =
        match List.assoc_opt "args" fields with
        | None -> Ok []
        | Some _ -> optional_string_list_field "args" json
      in
      let* item_args = args in
      Ok { item_op; item_args }
  | _ -> Error ("invalid_request", "render_many items must be JSON objects")

let optional_render_items_field name = function
  | Lsp_json.Object fields -> (
      match List.assoc_opt name fields with
      | None -> Ok []
      | Some (Lsp_json.Array values) ->
          let rec collect acc = function
            | [] -> Ok (List.rev acc)
            | value :: rest ->
                let* item = render_item_of_json value in
                collect (item :: acc) rest
          in
          collect [] values
      | Some _ -> Error ("invalid_request", "field `" ^ name ^ "` must be an array"))
  | _ -> Error ("invalid_request", "bridge request must be a JSON object")

let parse_request json =
  let* schema = int_field "schema" json in
  if schema <> schema_version then
    Error
      ( "unsupported_schema",
        Printf.sprintf "unsupported Blorp bridge schema: %d" schema )
  else
    let* request_domain = string_field "domain" json in
    if request_domain <> domain then
      Error
        ( "unsupported_domain",
          "unsupported Blorp bridge domain: " ^ request_domain )
    else
      let* action_text = string_field "action" json in
      let* action = action_of_string action_text in
      let* renderer = string_field "renderer" json in
      let* op = optional_string_field "op" json in
      let* args = optional_string_list_field "args" json in
      let* items = optional_render_items_field "items" json in
      Ok { action; renderer; op; args; items }

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

let int_response_field name = function
  | Lsp_json.Object fields -> (
      match List.assoc_opt name fields with
      | Some (Lsp_json.Int value) -> Ok value
      | Some _ -> Error ("invalid_response", "field `" ^ name ^ "` must be an integer")
      | None -> Error ("invalid_response", "missing integer field `" ^ name ^ "`"))
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

let request_json ~action ~renderer ?op ?(args = []) () =
  let fields =
    [
      ("schema", Lsp_json.Int schema_version);
      ("domain", Lsp_json.String domain);
      ("action", Lsp_json.String action);
      ("renderer", Lsp_json.String renderer);
      ("args", Lsp_json.Array (List.map json_string args));
    ]
  in
  let fields =
    match op with None -> fields | Some op -> ("op", Lsp_json.String op) :: fields
  in
  Lsp_json.to_string (Lsp_json.Object fields)

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

let required_op request =
  match request.op with
  | Some op -> Ok op
  | None -> Error ("invalid_request", "missing string field `op`")

let render_request request =
  let* op = required_op request in
  let* manifest = manifest_for_renderer request.renderer in
  let text = Core_emit_blorp_template.render_exn manifest op request.args in
  Ok (success_response [ ("text", Lsp_json.String text) ])

let render_many_request request =
  let* manifest = manifest_for_renderer request.renderer in
  let render_item item =
    let text =
      Core_emit_blorp_template.render_exn manifest item.item_op item.item_args
    in
    Lsp_json.Object
      [
        ("op", Lsp_json.String item.item_op);
        ("text", Lsp_json.String text);
      ]
  in
  Ok
    (success_response
       [ ("items", Lsp_json.Array (List.map render_item request.items)) ])

let list_ops_request request =
  let* manifest = manifest_for_renderer request.renderer in
  let names = Core_emit_blorp_template.names manifest in
  Ok
    (success_response [ ("names", Lsp_json.Array (List.map json_string names)) ])

let arity_request request =
  let* op = required_op request in
  let* manifest = manifest_for_renderer request.renderer in
  match Core_emit_blorp_template.find manifest op with
  | Some template -> Ok (success_response [ ("arity", Lsp_json.Int template.arity) ])
  | None -> Error ("unsupported_op", "unsupported Blorp renderer op: " ^ op)

let render_request_json request_json =
  try
    let result =
      let* request = Lsp_json.parse request_json |> parse_request in
      match request.action with
      | Render -> render_request request
      | RenderMany -> render_many_request request
      | ListOps -> list_ops_request request
      | TemplateArity -> arity_request request
    in
    match result with
    | Ok response -> response
    | Error (code, message) -> error_response code message
  with
  | Lsp_json.Parse_error message -> error_response "invalid_json" message
  | Invalid_argument message -> error_response "render_error" message

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
  let response_json =
    render_request_json
      (request_json ~action:"render" ~renderer ~op ~args ())
  in
  match response_result response_json (string_response_field "text") with
  | Ok text -> text
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
  let response_json =
    render_request_json (render_many_request_json ~renderer items)
  in
  match response_result response_json render_many_response_field with
  | Ok rendered -> rendered
  | Error (_, message) -> invalid_arg message

let command_child_env = "BLORP_COMPILER_BRIDGE_CHILD"

let running_inside_bridge_child () =
  match Sys.getenv_opt command_child_env with Some "1" -> true | _ -> false

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

let write_temp_request request_json =
  let path =
    Filename.temp_file "blorp-compiler-bridge-" ".json"
  in
  let channel = open_out_bin path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr channel)
    (fun () -> output_string channel request_json);
  path

let run_process_capture prog args =
  let read_fd, write_fd = Unix.pipe () in
  let stderr_path = Filename.temp_file "blorp-compiler-bridge-stderr-" ".log" in
  let stderr_fd =
    Unix.openfile stderr_path [ Unix.O_WRONLY; Unix.O_TRUNC ] 0o600
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

let rec find_upwards start name =
  let candidate = Filename.concat start name in
  if Sys.file_exists candidate && not (Sys.is_directory candidate) then
    Some candidate
  else
    let parent = Filename.dirname start in
    if parent = start then None else find_upwards parent name

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
  if running_inside_bridge_child () then render_many_exn ~renderer items
  else
    let response_json =
      run_request_via_command ?program (render_many_request_json ~renderer items)
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
  let response_json =
    render_request_json (request_json ~action:"list_ops" ~renderer ())
  in
  match response_result response_json (string_list_response_field "names") with
  | Ok names -> names
  | Error (_, message) -> invalid_arg message

let arity ~renderer ~op =
  let response_json =
    render_request_json
      (request_json ~action:"template_arity" ~renderer ~op ())
  in
  match response_result response_json (int_response_field "arity") with
  | Ok arity -> Some arity
  | Error _ -> None

let emit ctx ~renderer ~op args =
  Core_emit_context.emit ctx (render_exn ~renderer ~op args)
