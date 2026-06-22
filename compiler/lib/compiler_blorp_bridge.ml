(** Single JSON transfer point for Blorp-owned compiler snippets, policies, and
    downstream compile artifacts.

    Renderer JSON requests are served by [compiler/blorp/compiler_bridge.brp]
    through the hidden bridge command. The manifest helpers left in this module
    are temporary migration debt: the compiled helper still needs a fallback
    while it bootstraps itself. *)

let schema_version = 1
let domain = "compiler"
let intrinsic_renderer = "intrinsic"
let prepared_backend_renderer = "prepared_backend"
let prepared_list_renderer = "prepared_list"
let prepared_tensor_renderer = "prepared_tensor"
let prepared_constructor_renderer = "prepared_constructor"
let prepared_tuple_renderer = "prepared_tuple"
let core_error_renderer = "core_error"
let core_fairness_renderer = "core_fairness"
let core_profile_renderer = "core_profile"
let core_stage_renderer = "core_stage"
let core_trait_resolve_renderer = "core_trait_resolve"
let language_surface_renderer = "language_surface"

let ( let* ) result f =
  match result with Ok value -> f value | Error _ as error -> error

type renderer_template_info = {
  renderer_template_name : string;
  renderer_template_arity : int;
}

let rec find_upwards start name =
  let candidate = Filename.concat start name in
  if Sys.file_exists candidate && not (Sys.is_directory candidate) then
    Some candidate
  else
    let parent = Filename.dirname start in
    if parent = start then None else find_upwards parent name

let find_upwards_from starts name =
  let rec find = function
    | [] -> None
    | start :: rest -> (
        match find_upwards start name with
        | Some path -> Some path
        | None -> find rest)
  in
  find starts

let read_file path =
  let channel = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr channel)
    (fun () ->
      let len = in_channel_length channel in
      really_input_string channel len)

let write_file path contents =
  let channel = open_out_bin path in
  Fun.protect
    ~finally:(fun () -> close_out channel)
    (fun () -> output_string channel contents)

let rec ensure_dir path =
  if path = "" || path = Filename.current_dir_name then ()
  else if Sys.file_exists path then
    if Sys.is_directory path then ()
    else invalid_arg (Printf.sprintf "cache path is not a directory: %s" path)
  else begin
    let parent = Filename.dirname path in
    if parent <> path then ensure_dir parent;
    try Unix.mkdir path 0o700
    with Unix.Unix_error (Unix.EEXIST, _, _) ->
      if not (Sys.file_exists path && Sys.is_directory path) then
        invalid_arg (Printf.sprintf "cache path is not a directory: %s" path)
  end

let file_digest path =
  try Digest.to_hex (Digest.file path)
  with _ -> Digest.to_hex (Digest.string path)

let string_digest text = Digest.to_hex (Digest.string text)

let string_starts_with ~prefix value =
  let prefix_len = String.length prefix in
  String.length value >= prefix_len && String.sub value 0 prefix_len = prefix

let string_ends_with ~suffix value =
  let suffix_len = String.length suffix in
  let value_len = String.length value in
  value_len >= suffix_len
  && String.sub value (value_len - suffix_len) suffix_len = suffix

let relative_to ~root path =
  let prefix = Filename.concat root "" in
  if string_starts_with ~prefix path then
    String.sub path (String.length prefix)
      (String.length path - String.length prefix)
  else Filename.basename path

let bridge_source_tree_digest source_path =
  let root = Filename.dirname source_path in
  let rec collect dir =
    Sys.readdir dir |> Array.to_list |> List.sort String.compare
    |> List.fold_left
         (fun acc name ->
           let path = Filename.concat dir name in
           if Sys.is_directory path then
             if String.equal name "tests" then acc else collect path @ acc
           else if string_ends_with ~suffix:".brp" name then path :: acc
           else acc)
         []
  in
  let files = collect root |> List.sort String.compare in
  let buf = Buffer.create 4096 in
  List.iter
    (fun path ->
      let rel = relative_to ~root path in
      let contents = read_file path in
      Buffer.add_string buf (string_of_int (String.length rel));
      Buffer.add_char buf ':';
      Buffer.add_string buf rel;
      Buffer.add_char buf '\000';
      Buffer.add_string buf (string_of_int (String.length contents));
      Buffer.add_char buf ':';
      Buffer.add_string buf contents;
      Buffer.add_char buf '\000')
    files;
  string_digest (Buffer.contents buf)

let compiler_lib_file name =
  Filename.concat (Filename.concat "compiler" "lib") name

let template_manifest_tsv filename =
  let rel = compiler_lib_file filename in
  let starts = [ Sys.getcwd (); Filename.dirname Sys.executable_name ] in
  match find_upwards_from starts rel with
  | Some path -> read_file path
  | None ->
      invalid_arg
        (Printf.sprintf "cannot locate Blorp template manifest %s" rel)

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
  | renderer when renderer = intrinsic_renderer -> Ok intrinsic_manifest
  | renderer when renderer = prepared_backend_renderer ->
      Ok prepared_backend_manifest
  | renderer when renderer = prepared_list_renderer -> Ok prepared_list_manifest
  | renderer when renderer = prepared_tensor_renderer ->
      Ok prepared_tensor_manifest
  | renderer when renderer = prepared_constructor_renderer ->
      Ok prepared_constructor_manifest
  | renderer when renderer = prepared_tuple_renderer ->
      Ok prepared_tuple_manifest
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
             [
               ("code", Lsp_json.String code);
               ("message", Lsp_json.String message);
             ] );
       ])

let bool_field name = function
  | Lsp_json.Object fields -> (
      match List.assoc_opt name fields with
      | Some (Lsp_json.Bool value) -> Ok value
      | Some _ ->
          Error ("invalid_response", "field `" ^ name ^ "` must be a boolean")
      | None ->
          Error ("invalid_response", "missing boolean field `" ^ name ^ "`"))
  | _ -> Error ("invalid_response", "bridge response must be a JSON object")

let string_response_field name = function
  | Lsp_json.Object fields -> (
      match List.assoc_opt name fields with
      | Some (Lsp_json.String value) -> Ok value
      | Some _ ->
          Error ("invalid_response", "field `" ^ name ^ "` must be a string")
      | None -> Error ("invalid_response", "missing string field `" ^ name ^ "`")
      )
  | _ -> Error ("invalid_response", "bridge response must be a JSON object")

let error_message_response_field = function
  | Lsp_json.Object fields -> (
      match List.assoc_opt "error" fields with
      | Some (Lsp_json.Object error_fields) -> (
          match List.assoc_opt "message" error_fields with
          | Some (Lsp_json.String message) -> Ok message
          | Some _ ->
              Error ("invalid_response", "error.message must be a string")
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

let render_request_json ~renderer ~op args =
  Lsp_json.to_string
    (Lsp_json.Object
       [
         ("schema", Lsp_json.Int schema_version);
         ("domain", Lsp_json.String domain);
         ("action", Lsp_json.String "render");
         ( "payload",
           Lsp_json.Object
             [
               ("renderer", Lsp_json.String renderer);
               ("op", Lsp_json.String op);
               ("args", Lsp_json.Array (List.map json_string args));
             ] );
       ])

let render_many_request_json ~renderer items =
  Lsp_json.to_string
    (Lsp_json.Object
       [
         ("schema", Lsp_json.Int schema_version);
         ("domain", Lsp_json.String domain);
         ("action", Lsp_json.String "render_many");
         ( "payload",
           Lsp_json.Object
             [
               ("renderer", Lsp_json.String renderer);
               ("items", Lsp_json.Array (List.map render_item_json items));
             ] );
       ])

let emit_c_request_json core_json =
  Lsp_json.to_string
    (Lsp_json.Object
       [
         ("schema", Lsp_json.Int schema_version);
         ("domain", Lsp_json.String domain);
         ("action", Lsp_json.String "emit_c");
         ("payload", Lsp_json.Object [ ("core", core_json) ]);
       ])

let renderer_templates_request_json ~renderer =
  Lsp_json.to_string
    (Lsp_json.Object
       [
         ("schema", Lsp_json.Int schema_version);
         ("domain", Lsp_json.String domain);
         ("action", Lsp_json.String "renderer_templates");
         ("payload", Lsp_json.Object [ ("renderer", Lsp_json.String renderer) ]);
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

let render_response_field response = string_response_field "text" response

let json_response_field name = function
  | Lsp_json.Object fields -> (
      match List.assoc_opt name fields with
      | Some value -> Ok value
      | None -> Error ("invalid_response", "missing JSON field `" ^ name ^ "`"))
  | _ -> Error ("invalid_response", "bridge response must be a JSON object")

let int_response_field name = function
  | Lsp_json.Object fields -> (
      match List.assoc_opt name fields with
      | Some (Lsp_json.Int value) -> Ok value
      | Some (Lsp_json.Float value) ->
          if not (Float.is_finite value) then
            Error
              ( "invalid_response",
                "field `" ^ name ^ "` must be an exact integer" )
          else
            let truncated = int_of_float value in
            if Float.equal value (float_of_int truncated) then Ok truncated
            else
              Error
                ( "invalid_response",
                  "field `" ^ name ^ "` must be an exact integer" )
      | Some _ ->
          Error ("invalid_response", "field `" ^ name ^ "` must be an integer")
      | None ->
          Error ("invalid_response", "missing integer field `" ^ name ^ "`"))
  | _ -> Error ("invalid_response", "bridge response must be a JSON object")

let renderer_templates_response_field = function
  | Lsp_json.Object fields -> (
      match List.assoc_opt "items" fields with
      | Some (Lsp_json.Array values) ->
          let parse_item = function
            | Lsp_json.Object item_fields as item ->
                let* op =
                  match List.assoc_opt "op" item_fields with
                  | Some (Lsp_json.String op) -> Ok op
                  | _ ->
                      Error
                        ( "invalid_response",
                          "renderer template items must contain string op" )
                in
                let* arity = int_response_field "arity" item in
                if arity < 0 then
                  Error
                    ( "invalid_response",
                      "renderer template arity must be non-negative" )
                else
                  Ok
                    {
                      renderer_template_name = op;
                      renderer_template_arity = arity;
                    }
            | _ ->
                Error
                  ( "invalid_response",
                    "renderer template items must be JSON objects" )
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

type c_artifact = {
  c_code : string;
  link_flags : string list;
  include_dirs : string list;
}

let string_array_field name = function
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
      | Some _ ->
          Error
            ( "invalid_response",
              "field `" ^ name ^ "` must be an array of strings" )
      | None -> Error ("invalid_response", "missing array field `" ^ name ^ "`")
      )
  | _ -> Error ("invalid_response", "bridge response must be a JSON object")

let c_artifact_response_field response =
  let* artifact = json_response_field "artifact" response in
  let* c_code = string_response_field "c_code" artifact in
  let* link_flags = string_array_field "link_flags" artifact in
  let* include_dirs = string_array_field "include_dirs" artifact in
  Ok { c_code; link_flags; include_dirs }

let render_many_exn ~renderer items =
  match manifest_for_renderer renderer with
  | Ok manifest ->
      List.map
        (fun (op, args) ->
          (op, Core_emit_blorp_template.render_exn manifest op args))
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
    ( "language_prelude_ufcs_modules",
      "option;result;bool;char;bytes;string;list;parallel_list;vector;parallel_vector;matrix;parallel_matrix;range;dict;set;file"
    );
  ]

let core_fairness_bootstrap_rows =
  [
    ("fairness_body_checkpoint", "true");
    ("fairness_body_seq_checkpoint", "true");
    ("fairness_body_other", "false");
  ]

let zero_arg_bootstrap_template_infos rows =
  List.map
    (fun (name, _text) ->
      { renderer_template_name = name; renderer_template_arity = 0 })
    rows

let renderer_template_infos_for_helper_exn ~renderer =
  if String.equal renderer language_surface_renderer then
    zero_arg_bootstrap_template_infos language_surface_bootstrap_rows
  else if String.equal renderer core_fairness_renderer then
    zero_arg_bootstrap_template_infos core_fairness_bootstrap_rows
  else
    match manifest_for_renderer renderer with
    | Ok manifest ->
        Lazy.force manifest.Core_emit_blorp_template.templates
        |> List.map (fun template ->
            {
              renderer_template_name = template.Core_emit_blorp_template.name;
              renderer_template_arity = template.Core_emit_blorp_template.arity;
            })
    | Error (_, message) -> invalid_arg message

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

let renderer_bridge_helper_env = "BLORP_COMPILER_RENDERER_HELPER"
let renderer_bridge_source_env = "BLORP_COMPILER_BRIDGE_RENDERER_SOURCE"
let renderer_bridge_cache_dir_env = "BLORP_COMPILER_BRIDGE_CACHE_DIR"
let renderer_bridge_source_name = "compiler/blorp/compiler_bridge_cli.brp"

let renderer_bridge_cache :
    (string * string * string * string * string) option ref =
  ref None

let render_command_cache : (string, string) Hashtbl.t = Hashtbl.create 512

let renderer_template_infos_cache :
    (string, renderer_template_info list) Hashtbl.t =
  Hashtbl.create 16

let bridge_temp_retry_limit = 32

let running_inside_renderer_bridge_helper () =
  match Sys.getenv_opt renderer_bridge_helper_env with
  | Some "1" -> true
  | _ -> false

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
  Filename.concat
    (Filename.get_temp_dir_name ())
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
  | 0 -> (
      try
        Unix.dup2 write_fd Unix.stdout;
        Unix.dup2 stderr_fd Unix.stderr;
        Unix.close read_fd;
        Unix.close write_fd;
        Unix.close stderr_fd;
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
        let starts = [ Sys.getcwd (); Filename.dirname exe ] in
        match find_upwards_from starts "blorp" with
        | Some path -> path
        | None ->
            invalid_arg
              "cannot locate blorp compiler bridge binary; set \
               BLORP_COMPILER_BRIDGE_BIN")

let renderer_bridge_source_path () =
  match Sys.getenv_opt renderer_bridge_source_env with
  | Some path when path <> "" -> path
  | _ -> (
      let starts = [ Sys.getcwd (); Filename.dirname Sys.executable_name ] in
      match find_upwards_from starts renderer_bridge_source_name with
      | Some path -> path
      | None ->
          invalid_arg
            (Printf.sprintf "cannot locate Blorp renderer bridge source %s"
               renderer_bridge_source_name))

let renderer_bridge_temp_dir_retry_limit = 32

type renderer_bridge_cache_parts = {
  bridge_key : string;
  bridge_source_digest : string;
  bridge_program_digest : string;
  bridge_cc_digest : string;
  bridge_os : string;
}

let renderer_bridge_cc_identity =
  lazy
    (let code, output, stderr_output =
       run_process_capture "cc" [ "--version" ]
     in
     String.concat "\000" [ string_of_int code; output; stderr_output ])

let renderer_bridge_cache_root () =
  let root =
    match Sys.getenv_opt renderer_bridge_cache_dir_env with
    | Some path when path <> "" -> path
    | _ ->
        let home =
          match Sys.getenv_opt "HOME" with Some path -> path | None -> "/tmp"
        in
        Filename.concat home ".cache/blorp/compiler-bridge"
  in
  ensure_dir root;
  root

let renderer_bridge_cache_parts ~program ~source_path =
  let source_digest = bridge_source_tree_digest source_path in
  let program_digest = file_digest program in
  let cc_digest = string_digest (Lazy.force renderer_bridge_cc_identity) in
  let os = Sys.os_type in
  let bridge_key =
    string_digest
      (String.concat "\000"
         [
           "compiler-renderer-bridge-cache-v1";
           source_digest;
           program_digest;
           cc_digest;
           os;
         ])
  in
  {
    bridge_key;
    bridge_source_digest = source_digest;
    bridge_program_digest = program_digest;
    bridge_cc_digest = cc_digest;
    bridge_os = os;
  }

let renderer_bridge_cache_dir cache_root key =
  Filename.concat cache_root ("compiler-renderer-bridge-" ^ key)

let renderer_bridge_bin_path dir = Filename.concat dir "bridge.bin"
let renderer_bridge_c_path dir = Filename.concat dir "bridge.c"
let renderer_bridge_manifest_path dir = Filename.concat dir "MANIFEST"
let renderer_bridge_ready_path dir = Filename.concat dir "READY"

let renderer_bridge_manifest parts ~binary_path =
  String.concat "\n"
    [
      "compiler-renderer-bridge-cache-v1";
      "key=" ^ parts.bridge_key;
      "source=" ^ parts.bridge_source_digest;
      "program=" ^ parts.bridge_program_digest;
      "cc=" ^ parts.bridge_cc_digest;
      "os=" ^ parts.bridge_os;
      "bridge.bin=" ^ file_digest binary_path;
      "";
    ]

let renderer_bridge_cache_verified parts dir =
  let binary_path = renderer_bridge_bin_path dir in
  Sys.file_exists (renderer_bridge_ready_path dir)
  && Sys.file_exists binary_path
  &&
    try
      read_file (renderer_bridge_manifest_path dir)
      = renderer_bridge_manifest parts ~binary_path
    with _ -> false

let write_renderer_bridge_cache_markers parts dir =
  let binary_path = renderer_bridge_bin_path dir in
  write_file
    (renderer_bridge_manifest_path dir)
    (renderer_bridge_manifest parts ~binary_path);
  write_file (renderer_bridge_ready_path dir) "ready\n"

let rec create_renderer_bridge_stage_dir cache_root attempts_left =
  let marker =
    Filename.concat cache_root
      (Printf.sprintf ".compiler-renderer-bridge-stage-%d-%d" (Unix.getpid ())
         (Random.bits () land 0x3fffffff))
  in
  try
    Unix.mkdir marker 0o700;
    marker
  with
  | Unix.Unix_error (Unix.EEXIST, _, _) when attempts_left > 0 ->
      create_renderer_bridge_stage_dir cache_root (attempts_left - 1)
  | exn ->
      remove_path_noerr marker;
      raise exn

let publish_renderer_bridge_cache_dir parts ~stage_dir ~final_dir =
  let rec publish attempts =
    if renderer_bridge_cache_verified parts final_dir then begin
      remove_path_noerr stage_dir;
      Ok (renderer_bridge_bin_path final_dir)
    end
    else if Sys.file_exists final_dir && attempts < 2 then begin
      remove_path_noerr final_dir;
      publish (attempts + 1)
    end
    else
      try
        Unix.rename stage_dir final_dir;
        if renderer_bridge_cache_verified parts final_dir then
          Ok (renderer_bridge_bin_path final_dir)
        else begin
          remove_path_noerr final_dir;
          Error "published Blorp renderer bridge cache did not verify"
        end
      with
      | Unix.Unix_error ((Unix.EEXIST | Unix.ENOTEMPTY), _, _) when attempts < 2
        ->
          publish (attempts + 1)
      | exn ->
          remove_path_noerr stage_dir;
          Error
            (Printf.sprintf "failed to publish Blorp renderer bridge cache: %s"
               (Printexc.to_string exn))
  in
  publish 0

let compile_renderer_bridge_binary ~program ~source_path ~cache_root parts =
  let final_dir = renderer_bridge_cache_dir cache_root parts.bridge_key in
  if renderer_bridge_cache_verified parts final_dir then
    Ok (renderer_bridge_bin_path final_dir)
  else
    let stage_dir =
      create_renderer_bridge_stage_dir cache_root
        renderer_bridge_temp_dir_retry_limit
    in
    let c_path = renderer_bridge_c_path stage_dir in
    let bin_path = renderer_bridge_bin_path stage_dir in
    Fun.protect
      ~finally:(fun () -> try Sys.remove c_path with _ -> ())
      (fun () ->
        let compile_code, compile_output, compile_stderr =
          run_process_capture program
            ~env:[ (renderer_bridge_helper_env, "1") ]
            [ "compile"; "--no-format"; "-o"; c_path; source_path ]
        in
        if compile_code <> 0 then begin
          remove_path_noerr stage_dir;
          Error
            (Printf.sprintf "failed to compile Blorp renderer bridge: %s"
               (String.trim (compile_output ^ compile_stderr)))
        end
        else
          let cc_code, cc_output, cc_stderr =
            run_process_capture "cc"
              [
                "-O0";
                "-fwrapv";
                "-pipe";
                "-w";
                c_path;
                "-lm";
                "-lpthread";
                "-o";
                bin_path;
              ]
          in
          if cc_code <> 0 then begin
            remove_path_noerr stage_dir;
            Error
              (Printf.sprintf "failed to build Blorp renderer bridge binary: %s"
                 (String.trim (cc_output ^ cc_stderr)))
          end
          else begin
            (try Sys.remove c_path with _ -> ());
            write_renderer_bridge_cache_markers parts stage_dir;
            publish_renderer_bridge_cache_dir parts ~stage_dir ~final_dir
          end)

let renderer_bridge_binary () =
  let program = default_command_program () in
  let source_path = renderer_bridge_source_path () in
  let cache_root = renderer_bridge_cache_root () in
  match !renderer_bridge_cache with
  | Some (cached_program, cached_source, cached_root, _cached_key, cached_binary)
    when String.equal cached_program program
         && String.equal cached_source source_path
         && String.equal cached_root cache_root
         && Sys.file_exists cached_binary ->
      Ok cached_binary
  | _ -> (
      let cache_parts = renderer_bridge_cache_parts ~program ~source_path in
      match
        compile_renderer_bridge_binary ~program ~source_path ~cache_root
          cache_parts
      with
      | Ok binary ->
          renderer_bridge_cache :=
            Some
              (program, source_path, cache_root, cache_parts.bridge_key, binary);
          Ok binary
      | Error _ as error -> error)

let run_renderer_request_via_blorp request_json =
  match renderer_bridge_binary () with
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

let render_cache_key ~renderer ~op args =
  let buf = Buffer.create 128 in
  let add_part part =
    Buffer.add_string buf (string_of_int (String.length part));
    Buffer.add_char buf ':';
    Buffer.add_string buf part;
    Buffer.add_char buf ';'
  in
  add_part renderer;
  add_part op;
  List.iter add_part args;
  Buffer.contents buf

let renderer_template_infos_exn ~renderer =
  if running_inside_renderer_bridge_helper () then
    renderer_template_infos_for_helper_exn ~renderer
  else
    match Hashtbl.find_opt renderer_template_infos_cache renderer with
    | Some infos -> infos
    | None -> (
        let response_json =
          run_renderer_request_via_blorp
            (renderer_templates_request_json ~renderer)
        in
        match
          response_result response_json renderer_templates_response_field
        with
        | Ok infos ->
            Hashtbl.replace renderer_template_infos_cache renderer infos;
            infos
        | Error (_, message) -> invalid_arg message)

let renderer_template_arity_opt_exn ~renderer ~op =
  renderer_template_infos_exn ~renderer
  |> List.find_opt (fun info -> String.equal info.renderer_template_name op)
  |> Option.map (fun info -> info.renderer_template_arity)

let render_via_command_exn ~renderer ~op args =
  if running_inside_renderer_bridge_helper () then
    match render_many_for_renderer_helper_exn ~renderer [ (op, args) ] with
    | [ (_, text) ] -> text
    | _ ->
        invalid_arg
          ("invalid renderer helper response for " ^ renderer ^ ":" ^ op)
  else
    let cache_key = render_cache_key ~renderer ~op args in
    match Hashtbl.find_opt render_command_cache cache_key with
    | Some text -> text
    | None -> (
        let response_json =
          run_renderer_request_via_blorp
            (render_request_json ~renderer ~op args)
        in
        match response_result response_json render_response_field with
        | Ok text ->
            Hashtbl.replace render_command_cache cache_key text;
            text
        | Error (_, message) -> invalid_arg message)

let render_many_via_command_exn ~renderer items =
  if running_inside_renderer_bridge_helper () then
    render_many_for_renderer_helper_exn ~renderer items
  else
    let response_json =
      run_renderer_request_via_blorp (render_many_request_json ~renderer items)
    in
    match response_result response_json render_many_response_field with
    | Ok rendered -> rendered
    | Error (_, message) -> invalid_arg message

let emit_c_artifact_exn core_json =
  let response_json =
    run_renderer_request_via_blorp (emit_c_request_json core_json)
  in
  match response_result response_json c_artifact_response_field with
  | Ok artifact -> artifact
  | Error (_, message) -> invalid_arg message

let render_core_stage_unknown_error original normalized =
  render_via_command_exn ~renderer:core_stage_renderer
    ~op:"core_stage_unknown_error" [ original; normalized ]

let render_core_trait_resolve_no_impl_hint ~method_name ~type_name ~candidates =
  render_via_command_exn ~renderer:core_trait_resolve_renderer
    ~op:"core_trait_resolve_no_impl_hint"
    [ method_name; type_name; String.concat ";" candidates ]

let render_core_profile_format serialized_entries =
  render_via_command_exn ~renderer:core_profile_renderer
    ~op:"core_profile_format" [ serialized_entries ]

let render_core_error_format ~phase ~message ~line ~column ~hint =
  let hint_kind, hint_text =
    match hint with Some text -> ("some", text) | None -> ("none", "")
  in
  render_via_command_exn ~renderer:core_error_renderer ~op:"core_error_format"
    [
      phase;
      message;
      string_of_int line;
      string_of_int column;
      hint_kind;
      hint_text;
    ]

let () =
  Core_stage.set_unknown_stage_error_renderer render_core_stage_unknown_error;
  Core_error.set_formatter render_core_error_format
