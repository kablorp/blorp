(** Single JSON transfer point for Blorp-owned compiler policies, parser
    artifacts, and downstream compile artifacts.

    Renderer JSON requests are served by [compiler/blorp/compiler_bridge.brp]
    through the hidden bridge command. During a cold bridge-helper compile,
    helper mode serves only the narrow OCaml callers that still need static
    table rows before the helper binary exists. *)

let schema_version = 1
let domain = "compiler"
let core_error_renderer = "core_error"
let core_fairness_renderer = "core_fairness"
let core_profile_renderer = "core_profile"
let core_stage_renderer = "core_stage"
let core_trait_resolve_renderer = "core_trait_resolve"
let language_surface_renderer = "language_surface"

let ( let* ) result f =
  match result with Ok value -> f value | Error _ as error -> error

type parsed_source = {
  parsed_program : Ast.program;
  parsed_comments : Parse_comments.collected_comment list;
}

type parse_source_response =
  | ParsedSource of parsed_source
  | ParseSourceDiagnostics of Ast.compiler_error list

type parse_source_batch_request = {
  batch_parse_path : string;
  batch_parse_module_name : string;
  batch_parse_text : string;
}

type parse_source_batch_response = {
  batch_parsed_path : string;
  batch_parsed_module_name : string;
  batch_parsed_response : parse_source_response;
}

type cli_frontend_command =
  | CliFrontendCheck
  | CliFrontendCompile
  | CliFrontendRun

type cli_frontend_delegation_io =
  | CliFrontendBatchDelegation
  | CliFrontendTerminalDelegation

type cli_frontend_sanitizer_mode =
  | CliFrontendSanitizeOff
  | CliFrontendSanitizeAddressUndefined
  | CliFrontendSanitizeUndefined

type cli_check_options = {
  cli_check_dump_ast : bool;
  cli_check_dump_typed_ast : bool;
  cli_check_debug : bool;
  cli_check_no_format : bool;
  cli_check_std_dir : string option;
  cli_check_paths : string list;
}

type cli_compile_options = {
  cli_compile_ast_only : bool;
  cli_compile_dump_ast : bool;
  cli_compile_dump_typed_ast : bool;
  cli_compile_dump_core_after : Core_stage.t list;
  cli_compile_dump_file : string option;
  cli_compile_stop_after : Core_stage.t option;
  cli_compile_time_phases : bool;
  cli_compile_check_invariants : bool;
  cli_compile_debug : bool;
  cli_compile_no_format : bool;
  cli_compile_embed_runtime : bool;
  cli_compile_std_dir : string option;
  cli_compile_output : string option;
  cli_compile_files : string list;
}

type cli_run_options = {
  cli_run_profile : bool;
  cli_run_debug : bool;
  cli_run_sanitizer : cli_frontend_sanitizer_mode option;
  cli_run_leak_check : bool;
  cli_run_release : bool;
  cli_run_no_format : bool;
  cli_run_timeout : int option;
  cli_run_threads : int option;
  cli_run_std_dir : string option;
  cli_run_files : string list;
  cli_run_user_args : string list;
}

type cli_test_mode =
  | CliFrontendTestAll
  | CliFrontendTestDocOnly
  | CliFrontendTestSuiteOnly

type cli_test_run_options = {
  cli_test_raw_args : string list;
  cli_test_profile : bool;
  cli_test_debug : bool;
  cli_test_sanitizer : cli_frontend_sanitizer_mode option;
  cli_test_leak_check : bool;
  cli_test_no_format : bool;
  cli_test_timeout : int option;
  cli_test_jobs : int;
  cli_test_repeat : int;
  cli_test_mode : cli_test_mode;
  cli_test_cache : bool;
  cli_test_std_dir : string option;
  cli_test_paths : string list;
}

type cli_test_options =
  | CliTestRunOptions of cli_test_run_options
  | CliTestWarmupOnlyOptions of { cli_test_warmup_raw_args : string list }

type cli_purify_options = {
  cli_purify_raw_args : string list;
  cli_purify_dry_run : bool;
  cli_purify_verbose : bool;
  cli_purify_paths : string list;
}

type cli_repl_options = {
  cli_repl_raw_args : string list;
  cli_repl_debug : bool;
}

type cli_lsp_options = { cli_lsp_raw_args : string list }

type cli_package_command =
  | CliPackageCheck of string
  | CliPackageHash of string
  | CliPackagePack of { path : string; output : string }
  | CliPackageFetchAll
  | CliPackageFetchTarget of { target : string; from : string list }
  | CliPackageVendorAll
  | CliPackageVendorTarget of { target : string; dest : string option }

type cli_package_options = {
  cli_package_raw_args : string list;
  cli_package_command : cli_package_command;
}

type cli_frontend_options =
  | CliFrontendCheckOptions of cli_check_options
  | CliFrontendCompileOptions of cli_compile_options
  | CliFrontendRunOptions of cli_run_options

type cli_frontend_parsed = {
  cli_frontend_command : cli_frontend_command;
  cli_frontend_args : string list;
  cli_frontend_options : cli_frontend_options;
  cli_frontend_path : string;
  cli_frontend_module_name : string;
  cli_frontend_source_text : string option;
  cli_frontend_parsed_response : parse_source_response;
}

type cli_check_source_batch = {
  cli_check_batch_args : string list;
  cli_check_batch_options : cli_check_options;
  cli_check_batch_sources : parse_source_batch_response list;
}

type cli_source_graph_source = {
  cli_source_graph_path : string;
  cli_source_graph_module_name : string;
  cli_source_graph_source_text : string;
  cli_source_graph_parsed_response : parse_source_response;
}

type cli_source_graph = {
  cli_source_graph_command : cli_frontend_command;
  cli_source_graph_args : string list;
  cli_source_graph_options : cli_frontend_options;
  cli_source_graph_roots : cli_source_graph_source list;
  cli_source_graph_modules : cli_source_graph_source list;
}

type cli_frontend_options_plan = {
  cli_frontend_options_command : cli_frontend_command;
  cli_frontend_options_args : string list;
  cli_frontend_options : cli_frontend_options;
}

type cli_run_handled_result = {
  cli_run_status : int;
  cli_run_stdout : string;
  cli_run_stderr : string;
}

type cli_run_result =
  | CliRunHandled of cli_run_handled_result
  | CliRunParsedSource of cli_frontend_parsed
  | CliRunParsedSourceBatch of cli_check_source_batch
  | CliRunParsedSourceGraph of cli_source_graph
  | CliRunFrontendOptions of cli_frontend_options_plan
  | CliRunTestOptions of cli_test_options
  | CliRunPurifyOptions of cli_purify_options
  | CliRunReplOptions of cli_repl_options
  | CliRunLspOptions of cli_lsp_options
  | CliRunPackageOptions of cli_package_options
  | CliRunDelegate of {
      cli_run_delegate_args : string list;
      cli_run_delegate_io : cli_frontend_delegation_io;
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

let bridge_error_excerpt_limit = 4096

let bridge_error_excerpt text =
  if String.length text <= bridge_error_excerpt_limit then text
  else
    String.sub text 0 bridge_error_excerpt_limit
    ^ Printf.sprintf "... <truncated %d bytes>"
        (String.length text - bridge_error_excerpt_limit)

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

let emit_post_closure_c_request_json ?(profile = false) core_json =
  Lsp_json.to_string
    (Lsp_json.Object
       [
         ("schema", Lsp_json.Int schema_version);
         ("domain", Lsp_json.String domain);
         ("action", Lsp_json.String "emit_post_closure_c");
         ( "payload",
           Lsp_json.Object
             [ ("core", core_json); ("profile", Lsp_json.Bool profile) ] );
       ])

let run_core_pipeline_request_json ~stage core_json =
  Lsp_json.to_string
    (Lsp_json.Object
       [
         ("schema", Lsp_json.Int schema_version);
         ("domain", Lsp_json.String domain);
         ("action", Lsp_json.String "run_core_pipeline");
         ( "payload",
           Lsp_json.Object
             [ ("stage", Lsp_json.String stage); ("core", core_json) ] );
       ])

let parse_source_request_json ~path ~module_name ~text =
  Lsp_json.to_string
    (Lsp_json.Object
       [
         ("schema", Lsp_json.Int schema_version);
         ("domain", Lsp_json.String domain);
         ("action", Lsp_json.String "parse_source");
         ( "payload",
           Lsp_json.Object
             [
               ("path", Lsp_json.String path);
               ("module", Lsp_json.String module_name);
               ("text", Lsp_json.String text);
             ] );
       ])

let parse_source_file_request_json ~path ~module_name =
  Lsp_json.to_string
    (Lsp_json.Object
       [
         ("schema", Lsp_json.Int schema_version);
         ("domain", Lsp_json.String domain);
         ("action", Lsp_json.String "parse_source");
         ( "payload",
           Lsp_json.Object
             [
               ("path", Lsp_json.String path);
               ("module", Lsp_json.String module_name);
             ] );
       ])

let parse_source_batch_item_json item =
  Lsp_json.Object
    [
      ("path", Lsp_json.String item.batch_parse_path);
      ("module", Lsp_json.String item.batch_parse_module_name);
      ("text", Lsp_json.String item.batch_parse_text);
    ]

let parse_sources_request_json items =
  Lsp_json.to_string
    (Lsp_json.Object
       [
         ("schema", Lsp_json.Int schema_version);
         ("domain", Lsp_json.String domain);
         ("action", Lsp_json.String "parse_sources");
         ( "payload",
           Lsp_json.Object
             [
               ("include_comments", Lsp_json.Bool false);
               ( "sources",
                 Lsp_json.Array (List.map parse_source_batch_item_json items) );
             ] );
       ])

let cli_run_request_json ?version args =
  let version_fields =
    match version with
    | Some value -> [ ("version", Lsp_json.String value) ]
    | None -> []
  in
  let payload_fields =
    [
      ("args", Lsp_json.Array (List.map (fun arg -> Lsp_json.String arg) args));
    ]
    @ version_fields
  in
  Lsp_json.to_string
    (Lsp_json.Object
       [
         ("schema", Lsp_json.Int schema_version);
         ("domain", Lsp_json.String domain);
         ("action", Lsp_json.String "run_cli");
         ("payload", Lsp_json.Object payload_fields);
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

let json_response_field name = function
  | Lsp_json.Object fields -> (
      match List.assoc_opt name fields with
      | Some value -> Ok value
      | None -> Error ("invalid_response", "missing JSON field `" ^ name ^ "`"))
  | _ -> Error ("invalid_response", "bridge response must be a JSON object")

let optional_json_response_field name = function
  | Lsp_json.Object fields -> Ok (List.assoc_opt name fields)
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

let int_response_field name = function
  | Lsp_json.Object fields -> (
      match List.assoc_opt name fields with
      | Some (Lsp_json.Int value) -> Ok value
      | Some (Lsp_json.Float value) -> Ok (int_of_float value)
      | Some _ ->
          Error ("invalid_response", "field `" ^ name ^ "` must be a number")
      | None -> Error ("invalid_response", "missing number field `" ^ name ^ "`")
      )
  | _ -> Error ("invalid_response", "bridge response must be a JSON object")

let bool_response_field name = function
  | Lsp_json.Object fields -> (
      match List.assoc_opt name fields with
      | Some (Lsp_json.Bool value) -> Ok value
      | Some _ ->
          Error ("invalid_response", "field `" ^ name ^ "` must be a boolean")
      | None -> Error ("invalid_response", "missing boolean field `" ^ name ^ "`")
      )
  | _ -> Error ("invalid_response", "bridge response must be a JSON object")

let optional_string_response_field name = function
  | Lsp_json.Object fields -> (
      match List.assoc_opt name fields with
      | Some Lsp_json.Null -> Ok None
      | Some (Lsp_json.String value) -> Ok (Some value)
      | Some _ ->
          Error
            ("invalid_response", "field `" ^ name ^ "` must be a string or null")
      | None ->
          Error
            ("invalid_response", "missing optional string field `" ^ name ^ "`")
      )
  | _ -> Error ("invalid_response", "bridge response must be a JSON object")

let optional_missing_string_response_field name = function
  | Lsp_json.Object fields -> (
      match List.assoc_opt name fields with
      | None | Some Lsp_json.Null -> Ok None
      | Some (Lsp_json.String value) -> Ok (Some value)
      | Some _ ->
          Error
            ("invalid_response", "field `" ^ name ^ "` must be a string or null")
      )
  | _ -> Error ("invalid_response", "bridge response must be a JSON object")

let optional_int_response_field name = function
  | Lsp_json.Object fields -> (
      match List.assoc_opt name fields with
      | Some Lsp_json.Null -> Ok None
      | Some (Lsp_json.Int value) -> Ok (Some value)
      | Some (Lsp_json.Float value) -> Ok (Some (int_of_float value))
      | Some _ ->
          Error
            ("invalid_response", "field `" ^ name ^ "` must be a number or null")
      | None ->
          Error
            ("invalid_response", "missing optional number field `" ^ name ^ "`")
      )
  | _ -> Error ("invalid_response", "bridge response must be a JSON object")

let c_artifact_response_field response =
  let* artifact = json_response_field "artifact" response in
  let* c_code = string_response_field "c_code" artifact in
  let* link_flags = string_array_field "link_flags" artifact in
  let* include_dirs = string_array_field "include_dirs" artifact in
  Ok { c_code; link_flags; include_dirs }

let compiler_error_of_parse_diagnostic
    (diagnostic : Parsed_ast_json.parsed_diagnostic) =
  {
    Ast.message = diagnostic.parsed_diagnostic_message;
    loc = diagnostic.parsed_diagnostic_span;
    phase = Ast.Parse;
    kind = Ast.OtherError;
    notes = [];
    help = diagnostic.parsed_diagnostic_help;
  }

let compiler_error_of_decode_error (err : Parsed_ast_json.decode_error) =
  match err.loc with
  | Some loc ->
      Some
        {
          Ast.message = err.message;
          loc;
          phase = Ast.Parse;
          kind = Ast.OtherError;
          notes = [];
          help = None;
        }
  | None -> None

let int_json_field name fields =
  match List.assoc_opt name fields with
  | Some (Lsp_json.Int value) -> Ok value
  | Some (Lsp_json.Float value) -> Ok (int_of_float value)
  | Some _ ->
      Error ("invalid_response", "comment field `" ^ name ^ "` must be a number")
  | None -> Error ("invalid_response", "missing comment field `" ^ name ^ "`")

let string_json_field name fields =
  match List.assoc_opt name fields with
  | Some (Lsp_json.String value) -> Ok value
  | Some _ ->
      Error ("invalid_response", "comment field `" ^ name ^ "` must be a string")
  | None -> Error ("invalid_response", "missing comment field `" ^ name ^ "`")

let bool_json_field name fields =
  match List.assoc_opt name fields with
  | Some (Lsp_json.Bool value) -> Ok value
  | Some _ ->
      Error
        ("invalid_response", "comment field `" ^ name ^ "` must be a boolean")
  | None -> Error ("invalid_response", "missing comment field `" ^ name ^ "`")

let decode_parse_comment = function
  | Lsp_json.Object fields ->
      let* cc_text = string_json_field "text" fields in
      let* cc_line = int_json_field "line" fields in
      let* cc_col = int_json_field "column" fields in
      let* cc_trailing = bool_json_field "trailing" fields in
      Ok { Parse_comments.cc_text = cc_text; cc_line; cc_col; cc_trailing }
  | _ -> Error ("invalid_response", "parse comments must be JSON objects")

let parse_comments_response_field artifact =
  let* comments = optional_json_response_field "comments" artifact in
  match comments with
  | None -> Ok []
  | Some (Lsp_json.Array values) ->
      let rec collect acc = function
        | [] -> Ok (List.rev acc)
        | value :: rest ->
            let* comment = decode_parse_comment value in
            collect (comment :: acc) rest
      in
      collect [] values
  | Some _ -> Error ("invalid_response", "field `comments` must be an array")

let parsed_ast_artifact_field artifact =
  let* comments = parse_comments_response_field artifact in
  let* parsed_ast = json_response_field "parsed_ast" artifact in
  match Parsed_ast_json.decode_parse_diagnostics parsed_ast with
  | Error err ->
      Error
        ( "invalid_response",
          Parsed_ast_json.decode_error_to_string err )
  | Ok (_ :: _ as diagnostics) ->
      Ok
        (ParseSourceDiagnostics
           (List.map compiler_error_of_parse_diagnostic diagnostics))
  | Ok [] -> (
      match Parsed_ast_json.decode_program parsed_ast with
      | Ok program ->
          Ok
            (ParsedSource { parsed_program = program; parsed_comments = comments })
      | Error err -> (
          match compiler_error_of_decode_error err with
          | Some compiler_error -> Ok (ParseSourceDiagnostics [ compiler_error ])
          | None ->
              Error
                ( "invalid_response",
                  Parsed_ast_json.decode_error_to_string err )))

let parsed_ast_response_field response =
  let* artifact = json_response_field "artifact" response in
  parsed_ast_artifact_field artifact

let parse_source_response_json response_json =
  response_result response_json parsed_ast_response_field

let parse_source_batch_item_response = function
  | Lsp_json.Object _ as item ->
      let* path = string_response_field "path" item in
      let* module_name = string_response_field "module" item in
      let* parsed_response = parsed_ast_artifact_field item in
      Ok
        {
          batch_parsed_path = path;
          batch_parsed_module_name = module_name;
          batch_parsed_response = parsed_response;
        }
  | _ -> Error ("invalid_response", "parse_sources items must be JSON objects")

let parse_sources_response_field response =
  let* artifact = json_response_field "artifact" response in
  match json_response_field "sources" artifact with
  | Error _ as error -> error
  | Ok (Lsp_json.Array values) ->
      let rec collect acc = function
        | [] -> Ok (List.rev acc)
        | value :: rest ->
            let* item = parse_source_batch_item_response value in
            collect (item :: acc) rest
      in
      collect [] values
  | Ok _ -> Error ("invalid_response", "field `sources` must be an array")

let parse_sources_response_json response_json =
  response_result response_json parse_sources_response_field

let cli_frontend_command_of_string = function
  | "check" -> Ok CliFrontendCheck
  | "compile" -> Ok CliFrontendCompile
  | "run" -> Ok CliFrontendRun
  | command ->
      Error ("invalid_response", "unsupported CLI frontend command `" ^ command ^ "`")

let validate_cli_artifact_command artifact_kind expected args =
  match args with
  | command :: _ when String.equal command expected -> Ok ()
  | command :: _ ->
      Error
        ( "invalid_response",
          "CLI " ^ artifact_kind ^ " artifact args start with `" ^ command
          ^ "`, expected `" ^ expected ^ "`" )
  | [] ->
      Error
        ( "invalid_response",
          "CLI " ^ artifact_kind ^ " artifact args must start with `"
          ^ expected ^ "`" )

let validate_cli_artifact_args_exact artifact_kind expected args =
  if args = expected then Ok ()
  else
    Error
      ( "invalid_response",
        "CLI " ^ artifact_kind ^ " artifact args do not match command payload" )

let validate_cli_artifact_subcommand artifact_kind expected args =
  match args with
  | _ :: subcommand :: _ when String.equal subcommand expected -> Ok ()
  | _ :: subcommand :: _ ->
      Error
        ( "invalid_response",
          "CLI " ^ artifact_kind ^ " artifact subcommand is `" ^ subcommand
          ^ "`, expected `" ^ expected ^ "`" )
  | _ ->
      Error
        ( "invalid_response",
          "CLI " ^ artifact_kind ^ " artifact args must include subcommand `"
          ^ expected ^ "`" )

let decode_package_pack_args_from_raw args =
  let rec loop path output = function
    | [] -> (path, output)
    | ("-o" | "--output") :: value :: rest -> loop path (Some value) rest
    | ("-o" | "--output") :: [] -> (path, None)
    | arg :: rest when string_starts_with ~prefix:"-" arg -> loop path output rest
    | arg :: rest -> loop (Some arg) output rest
  in
  match args with
  | "package" :: "pack" :: rest -> loop None None rest
  | _ -> (None, None)

let validate_cli_package_pack_args path output args =
  match decode_package_pack_args_from_raw args with
  | Some raw_path, Some raw_output
    when String.equal raw_path path && String.equal raw_output output ->
      Ok ()
  | _ ->
      Error
        ( "invalid_response",
          "CLI package pack artifact args do not match command payload" )

let cli_frontend_delegation_io_of_string = function
  | "batch" -> Ok CliFrontendBatchDelegation
  | "terminal" -> Ok CliFrontendTerminalDelegation
  | io ->
      Error ("invalid_response", "unsupported CLI frontend delegation IO `" ^ io ^ "`")

let cli_frontend_sanitizer_mode_of_string = function
  | "off" -> Ok CliFrontendSanitizeOff
  | "address_undefined" -> Ok CliFrontendSanitizeAddressUndefined
  | "undefined" -> Ok CliFrontendSanitizeUndefined
  | mode ->
      Error ("invalid_response", "unsupported CLI sanitizer mode `" ^ mode ^ "`")

let cli_test_mode_of_string = function
  | "all" -> Ok CliFrontendTestAll
  | "doc" -> Ok CliFrontendTestDocOnly
  | "suite" -> Ok CliFrontendTestSuiteOnly
  | mode ->
      Error ("invalid_response", "unsupported CLI test mode `" ^ mode ^ "`")

let optional_sanitizer_response_field name = function
  | Lsp_json.Object fields -> (
      match List.assoc_opt name fields with
      | Some Lsp_json.Null -> Ok None
      | Some (Lsp_json.String value) ->
          let* mode = cli_frontend_sanitizer_mode_of_string value in
          Ok (Some mode)
      | Some _ ->
          Error
            ("invalid_response", "field `" ^ name ^ "` must be a string or null")
      | None ->
          Error
            ("invalid_response", "missing optional sanitizer field `" ^ name ^ "`")
      )
  | _ -> Error ("invalid_response", "bridge response must be a JSON object")

let core_stage_of_cli_string field_name stage_name =
  match Core_stage.of_string stage_name with
  | Ok stage -> Ok stage
  | Error message ->
      Error
        ( "invalid_response",
          "field `" ^ field_name ^ "` has unsupported stage `" ^ stage_name
          ^ "`: " ^ message )

let core_stage_array_field name value =
  let* stage_names = string_array_field name value in
  let rec collect acc = function
    | [] -> Ok (List.rev acc)
    | stage_name :: rest ->
        let* stage = core_stage_of_cli_string name stage_name in
        collect (stage :: acc) rest
  in
  collect [] stage_names

let optional_core_stage_response_field name value =
  let* stage_name = optional_string_response_field name value in
  match stage_name with
  | None -> Ok None
  | Some stage_name ->
      let* stage = core_stage_of_cli_string name stage_name in
      Ok (Some stage)

let require_options_kind expected options =
  let* kind = string_response_field "kind" options in
  if kind = expected then Ok ()
  else
    Error
      ( "invalid_response",
        "CLI options kind `" ^ kind ^ "` did not match expected `" ^ expected
        ^ "`" )

let decode_cli_check_options options =
  let* () = require_options_kind "check" options in
  let* cli_check_dump_ast = bool_response_field "dump_ast" options in
  let* cli_check_dump_typed_ast =
    bool_response_field "dump_typed_ast" options
  in
  let* cli_check_debug = bool_response_field "debug" options in
  let* cli_check_no_format = bool_response_field "no_format" options in
  let* cli_check_std_dir = optional_string_response_field "std_dir" options in
  let* cli_check_paths = string_array_field "paths" options in
  Ok
    (CliFrontendCheckOptions
       {
         cli_check_dump_ast;
         cli_check_dump_typed_ast;
         cli_check_debug;
         cli_check_no_format;
         cli_check_std_dir;
         cli_check_paths;
       })

let decode_cli_compile_options options =
  let* () = require_options_kind "compile" options in
  let* cli_compile_ast_only = bool_response_field "ast_only" options in
  let* cli_compile_dump_ast = bool_response_field "dump_ast" options in
  let* cli_compile_dump_typed_ast =
    bool_response_field "dump_typed_ast" options
  in
  let* cli_compile_dump_core_after =
    core_stage_array_field "dump_core_after" options
  in
  let* cli_compile_dump_file =
    optional_string_response_field "dump_file" options
  in
  let* cli_compile_stop_after =
    optional_core_stage_response_field "stop_after" options
  in
  let* cli_compile_time_phases = bool_response_field "time_phases" options in
  let* cli_compile_check_invariants =
    bool_response_field "check_invariants" options
  in
  let* cli_compile_debug = bool_response_field "debug" options in
  let* cli_compile_no_format = bool_response_field "no_format" options in
  let* cli_compile_embed_runtime =
    bool_response_field "embed_runtime" options
  in
  let* cli_compile_std_dir =
    optional_string_response_field "std_dir" options
  in
  let* cli_compile_output = optional_string_response_field "output" options in
  let* cli_compile_files = string_array_field "files" options in
  Ok
    (CliFrontendCompileOptions
       {
         cli_compile_ast_only;
         cli_compile_dump_ast;
         cli_compile_dump_typed_ast;
         cli_compile_dump_core_after;
         cli_compile_dump_file;
         cli_compile_stop_after;
         cli_compile_time_phases;
         cli_compile_check_invariants;
         cli_compile_debug;
         cli_compile_no_format;
         cli_compile_embed_runtime;
         cli_compile_std_dir;
         cli_compile_output;
         cli_compile_files;
       })

let decode_cli_run_options options =
  let* () = require_options_kind "run" options in
  let* cli_run_profile = bool_response_field "profile" options in
  let* cli_run_debug = bool_response_field "debug" options in
  let* cli_run_sanitizer = optional_sanitizer_response_field "sanitizer" options in
  let* cli_run_leak_check = bool_response_field "leak_check" options in
  let* cli_run_release = bool_response_field "release" options in
  let* cli_run_no_format = bool_response_field "no_format" options in
  let* cli_run_timeout = optional_int_response_field "timeout" options in
  let* cli_run_threads = optional_int_response_field "threads" options in
  let* cli_run_std_dir = optional_string_response_field "std_dir" options in
  let* cli_run_files = string_array_field "files" options in
  let* cli_run_user_args = string_array_field "user_args" options in
  Ok
    (CliFrontendRunOptions
       {
         cli_run_profile;
         cli_run_debug;
         cli_run_sanitizer;
         cli_run_leak_check;
         cli_run_release;
         cli_run_no_format;
         cli_run_timeout;
         cli_run_threads;
         cli_run_std_dir;
         cli_run_files;
         cli_run_user_args;
       })

let decode_cli_test_run_options cli_test_raw_args options =
  let* () = require_options_kind "test" options in
  let* cli_test_profile = bool_response_field "profile" options in
  let* cli_test_debug = bool_response_field "debug" options in
  let* cli_test_sanitizer = optional_sanitizer_response_field "sanitizer" options in
  let* cli_test_leak_check = bool_response_field "leak_check" options in
  let* cli_test_no_format = bool_response_field "no_format" options in
  let* cli_test_timeout = optional_int_response_field "timeout" options in
  let* cli_test_jobs = int_response_field "jobs" options in
  let* cli_test_repeat = int_response_field "repeat" options in
  let* mode_text = string_response_field "mode" options in
  let* cli_test_mode = cli_test_mode_of_string mode_text in
  let* cli_test_cache = bool_response_field "cache" options in
  let* cli_test_std_dir = optional_string_response_field "std_dir" options in
  let* cli_test_paths = string_array_field "paths" options in
  Ok
    (CliTestRunOptions
       {
         cli_test_raw_args;
         cli_test_profile;
         cli_test_debug;
         cli_test_sanitizer;
         cli_test_leak_check;
         cli_test_no_format;
         cli_test_timeout;
         cli_test_jobs;
         cli_test_repeat;
         cli_test_mode;
         cli_test_cache;
         cli_test_std_dir;
         cli_test_paths;
       })

let decode_cli_test_options cli_test_raw_args options =
  let* kind = string_response_field "kind" options in
  match kind with
  | "test" -> decode_cli_test_run_options cli_test_raw_args options
  | "test_warmup" ->
      Ok (CliTestWarmupOnlyOptions { cli_test_warmup_raw_args = cli_test_raw_args })
  | other ->
      Error
        ( "invalid_response",
          "unsupported CLI test options kind `" ^ other ^ "`" )

let decode_cli_purify_options cli_purify_raw_args options =
  let* () = require_options_kind "purify" options in
  let* cli_purify_dry_run = bool_response_field "dry_run" options in
  let* cli_purify_verbose = bool_response_field "verbose" options in
  let* cli_purify_paths = string_array_field "paths" options in
  Ok
    {
      cli_purify_raw_args;
      cli_purify_dry_run;
      cli_purify_verbose;
      cli_purify_paths;
    }

let decode_cli_frontend_options command options =
  match command with
  | CliFrontendCheck -> decode_cli_check_options options
  | CliFrontendCompile -> decode_cli_compile_options options
  | CliFrontendRun -> decode_cli_run_options options

let cli_frontend_parsed_response_field artifact =
  let* command_text = string_response_field "command" artifact in
  let* cli_frontend_command = cli_frontend_command_of_string command_text in
  let* cli_frontend_args = string_array_field "args" artifact in
  let* () =
    validate_cli_artifact_command "parsed_source" command_text cli_frontend_args
  in
  let* options = json_response_field "options" artifact in
  let* cli_frontend_options =
    decode_cli_frontend_options cli_frontend_command options
  in
  let* source = json_response_field "source" artifact in
  let* cli_frontend_path = string_response_field "path" source in
  let* cli_frontend_module_name = string_response_field "module" source in
  let* cli_frontend_source_text =
    optional_missing_string_response_field "source_text" source
  in
  let* parsed_source = json_response_field "parsed_source" source in
  let* cli_frontend_parsed_response = parsed_ast_artifact_field parsed_source in
  Ok
    {
      cli_frontend_command;
      cli_frontend_args;
      cli_frontend_options;
      cli_frontend_path;
      cli_frontend_module_name;
      cli_frontend_source_text;
      cli_frontend_parsed_response;
    }

let cli_check_source_batch_source_response_field source =
  let* batch_parsed_path = string_response_field "path" source in
  let* batch_parsed_module_name = string_response_field "module" source in
  let* parsed_source = json_response_field "parsed_source" source in
  let* batch_parsed_response = parsed_ast_artifact_field parsed_source in
  Ok
    {
      batch_parsed_path;
      batch_parsed_module_name;
      batch_parsed_response;
    }

let cli_check_source_batch_sources_field artifact =
  match json_response_field "sources" artifact with
  | Error _ as error -> error
  | Ok (Lsp_json.Array sources) ->
      let rec collect acc = function
        | [] -> Ok (List.rev acc)
        | source :: rest ->
            let* parsed = cli_check_source_batch_source_response_field source in
            collect (parsed :: acc) rest
      in
      collect [] sources
  | Ok _ -> Error ("invalid_response", "field `sources` must be an array")

let cli_check_source_batch_response_field artifact =
  let* command_text = string_response_field "command" artifact in
  let* () =
    if String.equal command_text "check" then Ok ()
    else
      Error
        ( "invalid_response",
          "CLI parsed_source_batch artifact command is `" ^ command_text
          ^ "`, expected `check`" )
  in
  let* cli_check_batch_args = string_array_field "args" artifact in
  let* () =
    validate_cli_artifact_command "parsed_source_batch" "check"
      cli_check_batch_args
  in
  let* options = json_response_field "options" artifact in
  let* cli_frontend_options = decode_cli_check_options options in
  let* cli_check_batch_options =
    match cli_frontend_options with
    | CliFrontendCheckOptions options -> Ok options
    | _ ->
        Error
          ( "invalid_response",
            "CLI parsed_source_batch options must be check options" )
  in
  let* cli_check_batch_sources =
    cli_check_source_batch_sources_field artifact
  in
  Ok
    (CliRunParsedSourceBatch
       {
         cli_check_batch_args;
         cli_check_batch_options;
         cli_check_batch_sources;
       })

let cli_source_graph_source_field source =
  let* cli_source_graph_path = string_response_field "path" source in
  let* cli_source_graph_module_name = string_response_field "module" source in
  let* cli_source_graph_source_text =
    string_response_field "source_text" source
  in
  let* parsed_source = json_response_field "parsed_source" source in
  let* cli_source_graph_parsed_response =
    parsed_ast_artifact_field parsed_source
  in
  Ok
    {
      cli_source_graph_path;
      cli_source_graph_module_name;
      cli_source_graph_source_text;
      cli_source_graph_parsed_response;
    }

let cli_source_graph_source_list_field name artifact =
  match json_response_field name artifact with
  | Error _ as error -> error
  | Ok (Lsp_json.Array sources) ->
      let rec collect acc = function
        | [] -> Ok (List.rev acc)
        | source :: rest ->
            let* parsed = cli_source_graph_source_field source in
            collect (parsed :: acc) rest
      in
      collect [] sources
  | Ok _ -> Error ("invalid_response", "field `" ^ name ^ "` must be an array")

let cli_source_graph_response_field artifact =
  let* command_text = string_response_field "command" artifact in
  let* cli_source_graph_command =
    cli_frontend_command_of_string command_text
  in
  let* cli_source_graph_args = string_array_field "args" artifact in
  let* () =
    validate_cli_artifact_command "parsed_source_graph" command_text
      cli_source_graph_args
  in
  let* options = json_response_field "options" artifact in
  let* cli_source_graph_options =
    decode_cli_frontend_options cli_source_graph_command options
  in
  let* cli_source_graph_roots =
    cli_source_graph_source_list_field "roots" artifact
  in
  let* cli_source_graph_modules =
    cli_source_graph_source_list_field "modules" artifact
  in
  Ok
    (CliRunParsedSourceGraph
       {
         cli_source_graph_command;
         cli_source_graph_args;
         cli_source_graph_options;
         cli_source_graph_roots;
         cli_source_graph_modules;
       })

let cli_frontend_options_response_field artifact =
  let* command_text = string_response_field "command" artifact in
  let* cli_frontend_options_command =
    cli_frontend_command_of_string command_text
  in
  let* cli_frontend_options_args = string_array_field "args" artifact in
  let* () =
    validate_cli_artifact_command "frontend_options" command_text
      cli_frontend_options_args
  in
  let* options = json_response_field "options" artifact in
  let* cli_frontend_options =
    decode_cli_frontend_options cli_frontend_options_command options
  in
  Ok
    {
      cli_frontend_options_command;
      cli_frontend_options_args;
      cli_frontend_options;
    }

let cli_run_handled_response_field artifact =
  let* cli_run_status = int_response_field "status" artifact in
  let* cli_run_stdout = string_response_field "stdout" artifact in
  let* cli_run_stderr = string_response_field "stderr" artifact in
  Ok (CliRunHandled { cli_run_status; cli_run_stdout; cli_run_stderr })

let cli_run_delegate_response_field artifact =
  let* cli_run_delegate_args = string_array_field "args" artifact in
  let* io = string_response_field "io" artifact in
  let* cli_run_delegate_io = cli_frontend_delegation_io_of_string io in
  Ok (CliRunDelegate { cli_run_delegate_args; cli_run_delegate_io })

let cli_run_test_response_field artifact =
  let* cli_test_raw_args = string_array_field "args" artifact in
  let* () = validate_cli_artifact_command "test" "test" cli_test_raw_args in
  let* options = json_response_field "options" artifact in
  let* cli_test_options = decode_cli_test_options cli_test_raw_args options in
  Ok (CliRunTestOptions cli_test_options)

let cli_run_purify_response_field artifact =
  let* cli_purify_raw_args = string_array_field "args" artifact in
  let* () =
    validate_cli_artifact_command "purify" "purify" cli_purify_raw_args
  in
  let* options = json_response_field "options" artifact in
  let* cli_purify_options =
    decode_cli_purify_options cli_purify_raw_args options
  in
  Ok (CliRunPurifyOptions cli_purify_options)

let cli_run_repl_response_field artifact =
  let* cli_repl_raw_args = string_array_field "args" artifact in
  let* () = validate_cli_artifact_command "repl" "repl" cli_repl_raw_args in
  let* cli_repl_debug = bool_response_field "debug" artifact in
  Ok (CliRunReplOptions { cli_repl_raw_args; cli_repl_debug })

let cli_run_lsp_response_field artifact =
  let* cli_lsp_raw_args = string_array_field "args" artifact in
  let* () = validate_cli_artifact_args_exact "lsp" [ "lsp" ] cli_lsp_raw_args in
  Ok (CliRunLspOptions { cli_lsp_raw_args })

let cli_package_command_response_field command =
  let* kind = string_response_field "kind" command in
  match kind with
  | "check" ->
      let* path = string_response_field "path" command in
      Ok (CliPackageCheck path)
  | "hash" ->
      let* path = string_response_field "path" command in
      Ok (CliPackageHash path)
  | "pack" ->
      let* path = string_response_field "path" command in
      let* output = string_response_field "output" command in
      Ok (CliPackagePack { path; output })
  | "fetch_all" -> Ok CliPackageFetchAll
  | "fetch_target" ->
      let* target = string_response_field "target" command in
      let* from = string_array_field "from" command in
      Ok (CliPackageFetchTarget { target; from })
  | "vendor_all" -> Ok CliPackageVendorAll
  | "vendor_target" ->
      let* target = string_response_field "target" command in
      let* dest = optional_string_response_field "dest" command in
      Ok (CliPackageVendorTarget { target; dest })
  | other ->
      Error
        ( "invalid_response",
          "unsupported CLI package command kind `" ^ other ^ "`" )

let validate_cli_package_command_args command args =
  let* () = validate_cli_artifact_command "package" "package" args in
  match command with
  | CliPackageCheck path ->
      validate_cli_artifact_args_exact "package check"
        [ "package"; "check"; path ]
        args
  | CliPackageHash path ->
      validate_cli_artifact_args_exact "package hash"
        [ "package"; "hash"; path ]
        args
  | CliPackagePack { path; output } ->
      let* () = validate_cli_artifact_subcommand "package pack" "pack" args in
      validate_cli_package_pack_args path output args
  | CliPackageFetchAll ->
      validate_cli_artifact_args_exact "package fetch" [ "package"; "fetch" ] args
  | CliPackageFetchTarget { target; from } ->
      validate_cli_artifact_args_exact "package fetch"
        ([ "package"; "fetch"; target ] @ from)
        args
  | CliPackageVendorAll ->
      validate_cli_artifact_args_exact "package vendor"
        [ "package"; "vendor" ]
        args
  | CliPackageVendorTarget { target; dest } -> (
      match dest with
      | Some path ->
          validate_cli_artifact_args_exact "package vendor"
            [ "package"; "vendor"; target; path ]
            args
      | None ->
          validate_cli_artifact_args_exact "package vendor"
            [ "package"; "vendor"; target ]
            args)

let cli_run_package_response_field artifact =
  let* cli_package_raw_args = string_array_field "args" artifact in
  let* command_json = json_response_field "command" artifact in
  let* cli_package_command = cli_package_command_response_field command_json in
  let* () =
    validate_cli_package_command_args cli_package_command cli_package_raw_args
  in
  Ok (CliRunPackageOptions { cli_package_raw_args; cli_package_command })

let cli_run_response_field response =
  let* artifact = json_response_field "artifact" response in
  let* kind = string_response_field "kind" artifact in
  match kind with
  | "handled" -> cli_run_handled_response_field artifact
  | "parsed_source" ->
      let* parsed = cli_frontend_parsed_response_field artifact in
      Ok (CliRunParsedSource parsed)
  | "parsed_source_batch" -> cli_check_source_batch_response_field artifact
  | "parsed_source_graph" -> cli_source_graph_response_field artifact
  | "frontend_options" ->
      let* options = cli_frontend_options_response_field artifact in
      Ok (CliRunFrontendOptions options)
  | "delegate" -> cli_run_delegate_response_field artifact
  | "test" -> cli_run_test_response_field artifact
  | "purify" -> cli_run_purify_response_field artifact
  | "repl" -> cli_run_repl_response_field artifact
  | "lsp" -> cli_run_lsp_response_field artifact
  | "package" -> cli_run_package_response_field artifact
  | other ->
      Error ("invalid_response", "unsupported CLI run artifact kind `" ^ other ^ "`")

let cli_run_response_json response_json =
  response_result response_json cli_run_response_field

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
  else
    invalid_arg
      ("renderer " ^ renderer
     ^ " is not available while compiling the Blorp bridge helper")

let renderer_bridge_helper_env = "BLORP_COMPILER_RENDERER_HELPER"
let renderer_bridge_source_env = "BLORP_COMPILER_BRIDGE_RENDERER_SOURCE"
let renderer_bridge_cache_dir_env = "BLORP_COMPILER_BRIDGE_CACHE_DIR"
let prepared_renderer_bridge_bin_env = "BLORP_COMPILER_RENDERER_BRIDGE_BIN"
let prepared_parser_bridge_bin_env = "BLORP_COMPILER_PARSER_BRIDGE_BIN"
let require_prepared_bridge_env = "BLORP_COMPILER_REQUIRE_PREPARED_BRIDGE"
let renderer_bridge_source_name = "compiler/blorp/compiler_bridge_cli.brp"
let parser_bridge_source_name = "compiler/blorp/compiler_parser_bridge_cli.brp"
let bridge_helper_compile_env =
  [
    (renderer_bridge_helper_env, "1");
    (* Only pinned external bootstrap binaries read this retired selector.
       Current compiler sessions do not use it, but direct bootstrap-binary
       helper builds still need to stay on the bootstrap's built-in parser. *)
    ("BLORP_FRONTEND_PARSER", "ocaml");
  ]

let parser_bridge_helper_compile_env = bridge_helper_compile_env

let renderer_bridge_cache :
    (string * string * string * string * string) option ref =
  ref None

let parser_bridge_cache :
    (string * string * string * string * string) option ref =
  ref None

let render_command_cache : (string, string) Hashtbl.t = Hashtbl.create 512

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

let string_starts_with_at value index prefix =
  let prefix_len = String.length prefix in
  index >= 0
  && index + prefix_len <= String.length value
  && String.sub value index prefix_len = prefix

let string_contains_substring value needle =
  let value_len = String.length value in
  let needle_len = String.length needle in
  if needle_len = 0 then true
  else
    let rec loop index =
      index + needle_len <= value_len
      && (String.sub value index needle_len = needle || loop (index + 1))
    in
    loop 0

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

let env_binding_name binding =
  match String.index_opt binding '=' with
  | Some index -> String.sub binding 0 index
  | None -> binding

let child_environment ~env ~unset_env =
  let removed =
    List.fold_left (fun acc name -> name :: acc) [] unset_env
    |> List.sort_uniq String.compare
  in
  let replaced =
    List.map fst env |> List.sort_uniq String.compare
  in
  let should_keep binding =
    let name = env_binding_name binding in
    (not (List.mem name removed)) && not (List.mem name replaced)
  in
  let inherited = Unix.environment () |> Array.to_list |> List.filter should_keep in
  let added = List.map (fun (name, value) -> name ^ "=" ^ value) env in
  Array.of_list (inherited @ added)

let split_path value =
  let rec collect acc start index =
    if index = String.length value then
      List.rev (String.sub value start (index - start) :: acc)
    else if value.[index] = ':' then
      collect (String.sub value start (index - start) :: acc) (index + 1)
        (index + 1)
    else collect acc start (index + 1)
  in
  collect [] 0 0

let executable_candidates prog =
  if String.contains prog '/' then [ prog ]
  else
    let path = match Sys.getenv_opt "PATH" with Some value -> value | None -> "" in
    split_path path
    |> List.map (fun dir ->
           let dir = if String.equal dir "" then "." else dir in
           Filename.concat dir prog)

let exec_program prog args envp =
  let argv = Array.of_list (prog :: args) in
  let rec try_candidates = function
    | [] -> Unix.execve prog argv envp
    | candidate :: rest -> (
        try Unix.execve candidate argv envp
        with Unix.Unix_error ((Unix.ENOENT | Unix.ENOTDIR | Unix.EACCES), _, _) ->
          try_candidates rest)
  in
  try_candidates (executable_candidates prog)

let compiler_bridge_bin_env = "BLORP_COMPILER_BRIDGE_BIN"
let compiler_bootstrap_script_name = "scripts/blorp-compiler-bootstrap"

let locate_default_command_program ?(bridge_bin = Sys.getenv_opt compiler_bridge_bin_env)
    starts =
  match bridge_bin with
  | Some path when path <> "" -> Some path
  | _ -> find_upwards_from starts compiler_bootstrap_script_name

let command_program_for_parser_bridge ?(bridge_bin = Sys.getenv_opt compiler_bridge_bin_env)
    starts =
  locate_default_command_program ~bridge_bin starts

let run_process_capture ?(env = []) ?(unset_env = []) prog args =
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
        exec_program prog args (child_environment ~env ~unset_env)
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
  let starts = [ Sys.getcwd (); Filename.dirname Sys.executable_name ] in
  match locate_default_command_program starts with
  | Some path -> path
  | None ->
      invalid_arg
        (Printf.sprintf
           "cannot locate pinned Blorp compiler bootstrap %s; set %s to an \
           explicit blorp binary"
           compiler_bootstrap_script_name compiler_bridge_bin_env)

let parser_bridge_command_program () =
  let starts = [ Sys.getcwd (); Filename.dirname Sys.executable_name ] in
  match command_program_for_parser_bridge starts with
  | Some path -> path
  | None ->
      invalid_arg
        (Printf.sprintf
           "cannot locate pinned Blorp compiler bootstrap %s; set %s to an \
            explicit blorp binary"
           compiler_bootstrap_script_name compiler_bridge_bin_env)

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

let parser_bridge_source_path () =
  let starts = [ Sys.getcwd (); Filename.dirname Sys.executable_name ] in
  match find_upwards_from starts parser_bridge_source_name with
  | Some path -> path
  | None ->
      invalid_arg
        (Printf.sprintf "cannot locate Blorp parser bridge source %s"
           parser_bridge_source_name)

let renderer_bridge_temp_dir_retry_limit = 32

let renderer_bridge_stack_link_args () =
  if String.equal (Platform.current ()) "macos" then
    [ "-Wl,-stack_size,0x4000000" ]
  else []

(* The self-hosted bridge currently decodes and emits large Core JSON through
   generated recursive functions with large C stack frames. Keep the bridge
   stack explicit until those generated frames are made smaller; relying on the
   platform default stack makes Linux CI crash on large compiler/blorp payloads. *)
let renderer_bridge_stack_size_bytes = 256 * 1024 * 1024
let renderer_bridge_user_main_symbol = "__blorp_renderer_bridge_user_main"

let renderer_bridge_common_cc_flags = [ "-O0"; "-fwrapv"; "-pipe"; "-w" ]

let renderer_bridge_wrapper_source () =
  Printf.sprintf
    {c|#include <pthread.h>
#include <stddef.h>
#include <stdlib.h>

extern int %s(int argc, char **argv);

typedef struct {
    int argc;
    char **argv;
    int result;
} blorp_renderer_bridge_main_args;

static void *blorp_renderer_bridge_main_entry(void *raw) {
    blorp_renderer_bridge_main_args *args = (blorp_renderer_bridge_main_args *)raw;
    args->result = %s(args->argc, args->argv);
    return NULL;
}

int main(int argc, char **argv) {
    pthread_attr_t attr;
    pthread_t thread;
    blorp_renderer_bridge_main_args args = { argc, argv, 1 };

    if (pthread_attr_init(&attr) != 0) {
        return %s(argc, argv);
    }

    if (pthread_attr_setstacksize(&attr, (size_t)%d) != 0) {
        pthread_attr_destroy(&attr);
        return %s(argc, argv);
    }

    if (pthread_create(&thread, &attr, blorp_renderer_bridge_main_entry, &args) != 0) {
        pthread_attr_destroy(&attr);
        return %s(argc, argv);
    }

    pthread_attr_destroy(&attr);
    if (pthread_join(thread, NULL) != 0) {
        return 1;
    }
    return args.result;
}
|c}
    renderer_bridge_user_main_symbol renderer_bridge_user_main_symbol
    renderer_bridge_user_main_symbol renderer_bridge_stack_size_bytes
    renderer_bridge_user_main_symbol renderer_bridge_user_main_symbol

let renderer_bridge_compile_object_args ~c_path ~obj_path =
  renderer_bridge_common_cc_flags
  @ [
      "-Dmain=" ^ renderer_bridge_user_main_symbol;
      "-c";
      c_path;
      "-o";
      obj_path;
    ]

let renderer_bridge_link_args ~obj_path ~wrapper_path ~bin_path =
  renderer_bridge_common_cc_flags
  @ [ obj_path; wrapper_path ]
  @ renderer_bridge_stack_link_args ()
  @ [ "-lm"; "-lpthread"; "-o"; bin_path ]

type renderer_bridge_cache_parts = {
  bridge_key : string;
  bridge_entrypoint : string;
  bridge_source_digest : string;
  bridge_program_digest : string;
  bridge_cc_digest : string;
  bridge_link_args_digest : string;
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
  let entrypoint = Filename.basename source_path in
  let source_digest = bridge_source_tree_digest source_path in
  let program_digest = file_digest program in
  let cc_digest = string_digest (Lazy.force renderer_bridge_cc_identity) in
  let link_args_digest =
    renderer_bridge_stack_link_args () |> String.concat "\000" |> string_digest
  in
  let os = Sys.os_type in
  let bridge_key =
    string_digest
      (String.concat "\000"
         [
           "compiler-renderer-bridge-cache-v4";
           entrypoint;
           source_digest;
           program_digest;
           cc_digest;
           link_args_digest;
           os;
         ])
  in
  {
    bridge_key;
    bridge_entrypoint = entrypoint;
    bridge_source_digest = source_digest;
    bridge_program_digest = program_digest;
    bridge_cc_digest = cc_digest;
    bridge_link_args_digest = link_args_digest;
    bridge_os = os;
  }

let renderer_bridge_cache_dir cache_root key =
  Filename.concat cache_root ("compiler-renderer-bridge-" ^ key)

let renderer_bridge_bin_path dir = Filename.concat dir "bridge.bin"
let renderer_bridge_c_path dir = Filename.concat dir "bridge.c"
let renderer_bridge_obj_path dir = Filename.concat dir "bridge.o"
let renderer_bridge_wrapper_path dir = Filename.concat dir "bridge_main.c"
let renderer_bridge_manifest_path dir = Filename.concat dir "MANIFEST"
let renderer_bridge_ready_path dir = Filename.concat dir "READY"
let renderer_bridge_lock_path cache_root key =
  Filename.concat cache_root (".compiler-renderer-bridge-" ^ key ^ ".lock")

let renderer_bridge_manifest parts ~binary_path =
  String.concat "\n"
    [
      "compiler-renderer-bridge-cache-v4";
      "key=" ^ parts.bridge_key;
      "entrypoint=" ^ parts.bridge_entrypoint;
      "source=" ^ parts.bridge_source_digest;
      "program=" ^ parts.bridge_program_digest;
      "cc=" ^ parts.bridge_cc_digest;
      "link_args=" ^ parts.bridge_link_args_digest;
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

let generated_c_struct_typedef_name line =
  let prefix = "typedef struct " in
  if not (string_starts_with_at line 0 prefix) then None
  else
    let rest_start = String.length prefix in
    let rec find_name_end index =
      if index >= String.length line then index
      else
        match line.[index] with
        | ' ' | '\t' | '{' -> index
        | _ -> find_name_end (index + 1)
    in
    let name_end = find_name_end rest_start in
    if name_end <= rest_start then None
    else
      let name = String.sub line rest_start (name_end - rest_start) in
      if string_contains_substring name "__" then Some name
      else None

let generated_c_with_forward_typedefs c_code =
  let lines = String.split_on_char '\n' c_code in
  let names =
    List.fold_left
      (fun acc line ->
        match generated_c_struct_typedef_name line with
        | Some name -> name :: acc
        | _ -> acc)
      [] lines
    |> List.sort_uniq String.compare
  in
  if names = [] then c_code
  else
    let declarations =
      "/* Blorp bridge bootstrap compatibility: older pinned compilers can\n\
       emit mutually recursive heap type declarations before their forward\n\
       typedefs. */\n"
      ^ (names
        |> List.map (fun name -> "typedef struct " ^ name ^ " " ^ name ^ ";")
        |> String.concat "\n")
      ^ "\n\n"
    in
    declarations ^ c_code

let generated_c_variant_defs c_code =
  let add_define acc line =
    let prefix = "#define " in
    if not (string_starts_with_at line 0 prefix) then acc
    else
      let rest_start = String.length prefix in
      match String.index_from_opt line rest_start ' ' with
      | None -> acc
      | Some name_end ->
          let def_name = String.sub line rest_start (name_end - rest_start) in
          if not (string_starts_with_at def_name 0 "__def_") then acc
          else (
            match String.rindex_opt def_name '_' with
            | None -> acc
            | Some variant_start when variant_start + 1 >= String.length def_name
              ->
                acc
            | Some variant_start ->
                let variant =
                  String.sub def_name (variant_start + 1)
                    (String.length def_name - variant_start - 1)
                in
                match List.assoc_opt variant acc with
                | None -> (variant, Some def_name) :: acc
                | Some (Some existing) when String.equal existing def_name -> acc
                | Some _ ->
                    (variant, None)
                    :: List.remove_assoc variant acc)
  in
  String.split_on_char '\n' c_code
  |> List.fold_left add_define []

let is_ident_char = function
  | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' -> true
  | _ -> false

let find_casted_enum_tag_check_end c_code expr_start tag_prefix =
  let len = String.length c_code in
  let tag_marker = ")->tag == " ^ tag_prefix in
  let marker_len = String.length tag_marker in
  let rec scan index depth =
    if index + marker_len > len then None
    else
      match c_code.[index] with
      | ')' when depth = 0 && string_starts_with_at c_code index tag_marker ->
          let variant_start = index + marker_len in
          let rec variant_end cursor =
            if cursor < len && is_ident_char c_code.[cursor] then
              variant_end (cursor + 1)
            else cursor
          in
          let variant_stop = variant_end variant_start in
          if variant_stop = variant_start then None
          else
            let stop =
              if variant_stop < len && c_code.[variant_stop] = ')' then
                variant_stop + 1
              else variant_stop
            in
            Some (index, variant_start, variant_stop, stop)
      | '(' -> scan (index + 1) (depth + 1)
      | ')' when depth > 0 -> scan (index + 1) (depth - 1)
      | _ -> scan (index + 1) depth
  in
  scan expr_start 0

let rewrite_casted_enum_tag_checks c_code ~type_name ~tag_prefix variant_defs =
  let cast_prefix = "(((" ^ type_name ^ "*)" in
  let cast_prefix_len = String.length cast_prefix in
  let len = String.length c_code in
  let buffer = Buffer.create len in
  let add_original from_ until_ =
    if until_ > from_ then
      Buffer.add_substring buffer c_code from_ (until_ - from_)
  in
  let rec loop cursor search_from =
    if search_from >= len then add_original cursor len
    else
      match
        let rec find index =
          if index + cast_prefix_len > len then None
          else if string_starts_with_at c_code index cast_prefix then Some index
          else find (index + 1)
        in
        find search_from
      with
      | None -> add_original cursor len
      | Some start -> (
          let expr_start = start + cast_prefix_len in
          match find_casted_enum_tag_check_end c_code expr_start tag_prefix with
          | None -> loop cursor expr_start
          | Some (expr_end, variant_start, variant_stop, stop) -> (
              let variant =
                String.sub c_code variant_start (variant_stop - variant_start)
              in
              match List.assoc_opt variant variant_defs with
              | Some (Some def_name) ->
                  add_original cursor start;
                  Buffer.add_string buffer "((long)(long)";
                  Buffer.add_substring buffer c_code expr_start
                    (expr_end - expr_start);
                  Buffer.add_string buffer " == ";
                  Buffer.add_string buffer def_name;
                  Buffer.add_char buffer ')';
                  loop stop stop
              | _ -> loop cursor stop))
  in
  loop 0 0;
  Buffer.contents buffer

let generated_c_with_stack_enum_payload_patterns c_code =
  let variant_defs = generated_c_variant_defs c_code in
  c_code
  |> fun code ->
  rewrite_casted_enum_tag_checks code
    ~type_name:"compiler_token__CompilerSymbol"
    ~tag_prefix:"TAG_compiler_token__CompilerSymbol_" variant_defs
  |> fun code ->
  rewrite_casted_enum_tag_checks code
    ~type_name:"compiler_token__CompilerKeyword"
    ~tag_prefix:"TAG_compiler_token__CompilerKeyword_" variant_defs

let generated_c_with_bootstrap_compatibility c_code =
  c_code
  |> generated_c_with_forward_typedefs
  |> generated_c_with_stack_enum_payload_patterns

let apply_generated_c_bootstrap_compatibility path =
  let original = read_file path in
  let rewritten = generated_c_with_bootstrap_compatibility original in
  if not (String.equal original rewritten) then write_file path rewritten

let compile_bridge_binary_in_stage ~program ~source_path ~compile_env ~stage_dir
    ~bin_path =
  let c_path = renderer_bridge_c_path stage_dir in
  let obj_path = renderer_bridge_obj_path stage_dir in
  let wrapper_path = renderer_bridge_wrapper_path stage_dir in
  Fun.protect
    ~finally:(fun () ->
      List.iter
        (fun path -> try Sys.remove path with _ -> ())
        [ c_path; obj_path; wrapper_path ])
    (fun () ->
      let compile_code, compile_output, compile_stderr =
        run_process_capture program
          ~env:compile_env
          ~unset_env:
            [
              compiler_bridge_bin_env;
              prepared_renderer_bridge_bin_env;
              prepared_parser_bridge_bin_env;
            ]
          [ "compile"; "--no-format"; "-o"; c_path; source_path ]
      in
      if compile_code <> 0 then
        Error
          (Printf.sprintf "failed to compile Blorp bridge helper %s: %s"
             source_path
             (String.trim (compile_output ^ compile_stderr)))
      else
        let () = apply_generated_c_bootstrap_compatibility c_path in
        let () = write_file wrapper_path (renderer_bridge_wrapper_source ()) in
        let obj_code, obj_output, obj_stderr =
          run_process_capture "cc"
            (renderer_bridge_compile_object_args ~c_path ~obj_path)
        in
        if obj_code <> 0 then
          Error
            (Printf.sprintf
               "failed to compile Blorp bridge helper object %s: %s"
               source_path
               (String.trim (obj_output ^ obj_stderr)))
        else
          let cc_code, cc_output, cc_stderr =
            run_process_capture "cc"
              (renderer_bridge_link_args ~obj_path ~wrapper_path ~bin_path)
          in
          if cc_code <> 0 then
            Error
              (Printf.sprintf
                 "failed to link Blorp bridge helper binary %s: %s" source_path
                 (String.trim (cc_output ^ cc_stderr)))
          else Ok bin_path)

let compile_bridge_binary_to_path ~program ~source_path ~compile_env ~work_root
    ~bin_path =
  ensure_dir work_root;
  ensure_dir (Filename.dirname bin_path);
  let stage_dir =
    create_renderer_bridge_stage_dir work_root renderer_bridge_temp_dir_retry_limit
  in
  Fun.protect
    ~finally:(fun () -> remove_path_noerr stage_dir)
    (fun () ->
      let stage_bin = renderer_bridge_bin_path stage_dir in
      match
        compile_bridge_binary_in_stage ~program ~source_path ~compile_env
          ~stage_dir ~bin_path:stage_bin
      with
      | Error _ as error -> error
      | Ok _ ->
          (try Sys.remove bin_path with _ -> ());
          Unix.rename stage_bin bin_path;
          Ok bin_path)

let rec lockf_retry fd command size =
  try Unix.lockf fd command size
  with Unix.Unix_error (Unix.EINTR, _, _) -> lockf_retry fd command size

let with_renderer_bridge_cache_lock cache_root key f =
  let lock_path = renderer_bridge_lock_path cache_root key in
  let fd = Unix.openfile lock_path [ Unix.O_RDWR; Unix.O_CREAT ] 0o600 in
  Fun.protect
    ~finally:(fun () -> Unix.close fd)
    (fun () ->
      lockf_retry fd Unix.F_LOCK 0;
      Fun.protect
        ~finally:(fun () ->
          try lockf_retry fd Unix.F_ULOCK 0 with _ -> ())
        f)

let compile_renderer_bridge_binary ~program ~source_path ~cache_root
    ~compile_env parts =
  let final_dir = renderer_bridge_cache_dir cache_root parts.bridge_key in
  if renderer_bridge_cache_verified parts final_dir then
    Ok (renderer_bridge_bin_path final_dir)
  else with_renderer_bridge_cache_lock cache_root parts.bridge_key (fun () ->
    if renderer_bridge_cache_verified parts final_dir then
      Ok (renderer_bridge_bin_path final_dir)
    else
    let stage_dir =
      create_renderer_bridge_stage_dir cache_root
        renderer_bridge_temp_dir_retry_limit
    in
    let bin_path = renderer_bridge_bin_path stage_dir in
    match
      compile_bridge_binary_in_stage ~program ~source_path ~compile_env
        ~stage_dir ~bin_path
    with
    | Error message ->
        remove_path_noerr stage_dir;
        Error message
    | Ok _ ->
        write_renderer_bridge_cache_markers parts stage_dir;
        publish_renderer_bridge_cache_dir parts ~stage_dir ~final_dir)

let bridge_binary_for_source cache_ref ~program ~source_path ~compile_env =
  let cache_root = renderer_bridge_cache_root () in
  match !cache_ref with
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
          ~compile_env cache_parts
      with
      | Ok binary ->
          cache_ref :=
            Some
              (program, source_path, cache_root, cache_parts.bridge_key, binary);
          Ok binary
      | Error _ as error -> error)

let prepared_bridge_binary_from_env env_name =
  match Sys.getenv_opt env_name with
  | Some path when path <> "" ->
      if Sys.file_exists path && not (Sys.is_directory path) then Some (Ok path)
      else
        Some
          (Error
             (Printf.sprintf
                "%s points to missing Blorp bridge helper binary: %s" env_name
                path))
  | _ -> None

let prepared_bridge_required () =
  match Sys.getenv_opt require_prepared_bridge_env with Some "1" -> true | _ -> false

let missing_prepared_bridge_error env_name =
  Error
    (Printf.sprintf
       "%s=1 requires %s to point to a prepared Blorp bridge helper binary"
       require_prepared_bridge_env env_name)

let renderer_bridge_binary () =
  match prepared_bridge_binary_from_env prepared_renderer_bridge_bin_env with
  | Some result -> result
  | None when prepared_bridge_required () ->
      missing_prepared_bridge_error prepared_renderer_bridge_bin_env
  | None ->
      bridge_binary_for_source renderer_bridge_cache
        ~program:(default_command_program ())
        ~source_path:(renderer_bridge_source_path ())
        ~compile_env:bridge_helper_compile_env

let parser_bridge_binary () =
  match prepared_bridge_binary_from_env prepared_parser_bridge_bin_env with
  | Some result -> result
  | None when prepared_bridge_required () ->
      missing_prepared_bridge_error prepared_parser_bridge_bin_env
  | None ->
      bridge_binary_for_source parser_bridge_cache
        ~program:(parser_bridge_command_program ())
        ~source_path:(parser_bridge_source_path ())
        ~compile_env:parser_bridge_helper_compile_env

type prepared_bridge_binaries = {
  prepared_renderer_bridge_bin : string;
  prepared_parser_bridge_bin : string;
}

let prepare_bridge_binaries ~out_dir =
  ensure_dir out_dir;
  let program = default_command_program () in
  let renderer_bin = Filename.concat out_dir "compiler_renderer_bridge.bin" in
  let parser_bin = Filename.concat out_dir "compiler_parser_bridge.bin" in
  let* renderer_path =
    compile_bridge_binary_to_path ~program
      ~source_path:(renderer_bridge_source_path ())
      ~compile_env:bridge_helper_compile_env ~work_root:out_dir
      ~bin_path:renderer_bin
  in
  let* parser_path =
    compile_bridge_binary_to_path ~program
      ~source_path:(parser_bridge_source_path ())
      ~compile_env:parser_bridge_helper_compile_env ~work_root:out_dir
      ~bin_path:parser_bin
  in
  Ok
    {
      prepared_renderer_bridge_bin = renderer_path;
      prepared_parser_bridge_bin = parser_path;
    }

let run_request_via_blorp_binary bridge_binary request_json =
  match bridge_binary () with
  | Error message -> error_response "bridge_command_failed" message
  | Ok bridge_binary ->
      let request_path = write_temp_request request_json in
      Fun.protect
        ~finally:(fun () -> try Sys.remove request_path with _ -> ())
        (fun () ->
          let exit_code, output, stderr_output =
            run_process_capture bridge_binary ~unset_env:[ "BLORP_LEAK_CHECK" ]
              [ request_path ]
          in
          if exit_code = 0 then output
          else
            let kept_request =
              match Sys.getenv_opt "BLORP_KEEP_FAILED_BRIDGE_REQUEST" with
              | Some "1" ->
                  let kept_path = request_path ^ ".failed" in
                  write_file kept_path request_json;
                  "\nkept request: " ^ kept_path
              | _ -> ""
            in
            error_response "bridge_command_failed"
              (Printf.sprintf
                 "Blorp renderer bridge command exited %d: %s%s\nrequest: %s"
                 exit_code
                 (String.trim (output ^ stderr_output))
                 kept_request
                 (bridge_error_excerpt request_json)))

let run_renderer_request_via_blorp request_json =
  run_request_via_blorp_binary renderer_bridge_binary request_json

let run_parser_request_via_blorp request_json =
  run_request_via_blorp_binary parser_bridge_binary request_json

let run_cli_request_via_blorp ?version args =
  run_parser_request_via_blorp (cli_run_request_json ?version args)

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
            (render_many_request_json ~renderer [ (op, args) ])
        in
        match response_result response_json render_many_response_field with
        | Ok [ (_, text) ] ->
            Hashtbl.replace render_command_cache cache_key text;
            text
        | Ok _ ->
            invalid_arg
              ("invalid renderer response for single item " ^ renderer ^ ":"
             ^ op)
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

let emit_post_closure_c_artifact_exn ?(profile = false) core_json =
  let response_json =
    run_renderer_request_via_blorp
      (emit_post_closure_c_request_json ~profile core_json)
  in
  match response_result response_json c_artifact_response_field with
  | Ok artifact -> artifact
  | Error (_, message) -> invalid_arg message

let run_core_pipeline_core_json_exn ~stage core_json =
  let response_json =
    run_renderer_request_via_blorp
      (run_core_pipeline_request_json ~stage core_json)
  in
  match response_result response_json (json_response_field "core") with
  | Ok transformed_core -> transformed_core
  | Error (_, message) -> invalid_arg message

let parse_source_via_command ~path ~module_name ~text =
  let response_json =
    run_parser_request_via_blorp
      (parse_source_request_json ~path ~module_name ~text)
  in
  parse_source_response_json response_json

let parse_sources_via_command items =
  let response_json =
    run_parser_request_via_blorp (parse_sources_request_json items)
  in
  parse_sources_response_json response_json

let parse_source_file_via_command ~path ~module_name =
  let response_json =
    run_parser_request_via_blorp
      (parse_source_file_request_json ~path ~module_name)
  in
  parse_source_response_json response_json

let cli_run_via_command ?version args =
  run_cli_request_via_blorp ?version args |> cli_run_response_json

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
