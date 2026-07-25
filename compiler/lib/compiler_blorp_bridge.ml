(** Single JSON transfer point for Blorp-owned compiler policies, parser
    artifacts, and downstream compile artifacts.

    Renderer JSON requests are served by [compiler/blorp/src/stage_12_cli/compiler_bridge.brp]
    through the hidden bridge command. During a cold bridge-helper compile,
    helper mode serves only the narrow OCaml callers that still need static
    table rows before the helper binary exists. *)

let schema_version = 1
let domain = "compiler"
let core_fairness_renderer = "core_fairness"
let core_stage_renderer = "core_stage"
let core_trait_resolve_renderer = "core_trait_resolve"
let language_surface_renderer = "language_surface"

let ( let* ) result f =
  match result with Ok value -> f value | Error _ as error -> error

type parsed_source_phase =
  | RawParsedProgram
  | TypecheckSourceProgram

let parsed_source_phase_name = function
  | RawParsedProgram -> "raw_parse"
  | TypecheckSourceProgram -> "typecheck_source"

let parsed_source_phase_of_string = function
  | "raw_parse" -> Ok RawParsedProgram
  | "typecheck_source" -> Ok TypecheckSourceProgram
  | other ->
      Error ("invalid_response", "unsupported parser AST phase `" ^ other ^ "`")

type collected_comment = {
  cc_text : string;
  cc_line : int;
  cc_col : int;
  cc_trailing : bool;
}

type parsed_source = {
  parsed_program : Ast.program;
  parsed_comments : collected_comment list;
  parsed_phase : parsed_source_phase;
  parsed_module_surface : Module_surface.t option;
}

type parse_source_response =
  | ParsedSource of parsed_source
  | ParseSourceDiagnostics of Ast.compiler_error list

type typechecked_source = {
  typechecked_program : Typed_ast.program;
  typechecked_errors : string list;
  typechecked_import_bindings : Session.import_binding list;
  typechecked_ctfe_evaluated_by_blorp : bool;
  typechecked_comments : collected_comment list;
  typechecked_phase : parsed_source_phase;
  typechecked_module_surface : Module_surface.t option;
}

type typechecked_graph_source = {
  typechecked_graph_path : string;
  typechecked_graph_module_name : string;
  typechecked_graph_artifact : typechecked_source;
}

type typechecked_graph = {
  typechecked_graph_modules : typechecked_graph_source list;
  typechecked_graph_target : typechecked_graph_source;
}

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

type cli_source_override = {
  cli_source_path : string;
  cli_source_module_name : string;
  cli_source_text : string;
}

type cli_frontend_delegation_io =
  | CliFrontendBatchDelegation
  | CliFrontendTerminalDelegation

type cli_frontend_sanitizer_mode =
  | CliFrontendSanitizeOff
  | CliFrontendSanitizeAddressUndefined
  | CliFrontendSanitizeUndefined

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

type cli_frontend_module_origin =
  | CliFrontendUserModule
  | CliFrontendStdModule
  | CliFrontendSourcePackageModule of string
  | CliFrontendPkgModule of string

type typecheck_import_module = {
  typecheck_import_path : string;
  typecheck_import_module_name : string;
  typecheck_import_module_path : string;
  typecheck_import_text : string;
  typecheck_import_origin : cli_frontend_module_origin;
}

type typecheck_resolved_import = {
  typecheck_resolved_import_from_path : string;
  typecheck_resolved_import_from_module : string;
  typecheck_resolved_import_path : string;
  typecheck_resolved_import_module : string;
}

type cli_frontend_source_package = {
  cli_frontend_source_package_alias : string;
  cli_frontend_source_package_name : string;
  cli_frontend_source_package_root : string;
  cli_frontend_source_package_source_dir : string;
  cli_frontend_source_package_exports : string list;
}

type cli_frontend_graph_context = {
  cli_frontend_context_std_dir : string option;
  cli_frontend_context_source_packages : cli_frontend_source_package list;
  cli_frontend_context_package_roots : string list;
}

type cli_frontend_graph_source = {
  cli_frontend_graph_path : string;
  cli_frontend_graph_module_name : string;
  cli_frontend_graph_source_text : string;
  cli_frontend_graph_parsed_response : parse_source_response;
  cli_frontend_graph_origin : cli_frontend_module_origin;
}

type cli_frontend_import_edge = {
  cli_frontend_import_from_path : string;
  cli_frontend_import_from_module : string;
  cli_frontend_import_path : string;
  cli_frontend_import_resolved_path : string option;
  cli_frontend_import_resolved_module : string option;
  cli_frontend_import_resolved_origin : cli_frontend_module_origin option;
}

type cli_frontend_module_graph = {
  cli_frontend_graph_args : string list;
  cli_frontend_graph_compile_options : cli_compile_options;
  cli_frontend_graph_context : cli_frontend_graph_context;
  cli_frontend_graph_roots : cli_frontend_graph_source list;
  cli_frontend_graph_modules : cli_frontend_graph_source list;
  cli_frontend_graph_imports : cli_frontend_import_edge list;
  cli_frontend_graph_diagnostics : string list;
}

type cli_run_handled_result = {
  cli_run_status : int;
  cli_run_stdout : string;
  cli_run_stderr : string;
}

type cli_run_result =
  | CliRunHandled of cli_run_handled_result
  | CliRunFrontendModuleGraph of cli_frontend_module_graph
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

let existing_directory path =
  try Sys.file_exists path && Sys.is_directory path with _ -> false

let labeled_relative_to ~root ~label path =
  let rel = relative_to ~root path in
  if label = "" then rel else Filename.concat label rel

let compiler_bridge_source_root source_path =
  let source_dir = Filename.dirname source_path in
  let src_dir = Filename.dirname source_dir in
  let blorp_dir = Filename.dirname src_dir in
  let compiler_dir = Filename.dirname blorp_dir in
  if
    String.equal (Filename.basename src_dir) "src"
    && String.equal (Filename.basename blorp_dir) "blorp"
    && String.equal (Filename.basename compiler_dir) "compiler"
  then src_dir
  else source_dir

(* Bridge helper binaries are compiled as normal Blorp programs. Their cache key
   must include source roots that can affect generated C, not just the helper
   entrypoint: std edits can change imported library code, and
   [compiler/blorp/src/stage_11_format/compiler_format_projection.brp] imports self-hosted formatter
   modules from [tools/formatter]. *)
let compiler_bridge_extra_source_roots source_root =
  let blorp_dir = Filename.dirname source_root in
  let compiler_dir = Filename.dirname blorp_dir in
  let workspace_root = Filename.dirname compiler_dir in
  let std_root = Filename.concat workspace_root "std" in
  let formatter_root = Filename.concat workspace_root "tools/formatter" in
  if
    String.equal (Filename.basename source_root) "src"
    && String.equal (Filename.basename blorp_dir) "blorp"
    && String.equal (Filename.basename compiler_dir) "compiler"
  then
    let roots = [] in
    let roots =
      if existing_directory std_root then ("std", std_root) :: roots else roots
    in
    let roots =
      if existing_directory formatter_root then
        ("tools/formatter", formatter_root) :: roots
      else roots
    in
    List.rev roots
  else []

let bridge_source_tree_digest source_path =
  let root = compiler_bridge_source_root source_path in
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
  let buf = Buffer.create 4096 in
  let add_root ~label source_root =
    let files = collect source_root |> List.sort String.compare in
    List.iter
      (fun path ->
        let rel = labeled_relative_to ~root:source_root ~label path in
        let contents = read_file path in
        Buffer.add_string buf (string_of_int (String.length rel));
        Buffer.add_char buf ':';
        Buffer.add_string buf rel;
        Buffer.add_char buf '\000';
        Buffer.add_string buf (string_of_int (String.length contents));
        Buffer.add_char buf ':';
        Buffer.add_string buf contents;
        Buffer.add_char buf '\000')
      files
  in
  add_root ~label:"compiler/blorp" root;
  List.iter
    (fun (label, source_root) -> add_root ~label source_root)
    (compiler_bridge_extra_source_roots root);
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

let emit_core_c_request_json ?(profile = false) core_json =
  Lsp_json.to_string
    (Lsp_json.Object
       [
         ("schema", Lsp_json.Int schema_version);
         ("domain", Lsp_json.String domain);
         ("action", Lsp_json.String "emit_core_c");
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

let parse_source_request_json_at_phase ~phase ~path ~module_name ~text =
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
               ( "ast_phase",
                 Lsp_json.String (parsed_source_phase_name phase) );
             ] );
       ])

let parse_source_file_request_json_at_phase ~phase ~path ~module_name =
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
               ( "ast_phase",
                 Lsp_json.String (parsed_source_phase_name phase) );
             ] );
       ])

let parse_source_batch_item_json ?(phase = RawParsedProgram) item =
  Lsp_json.Object
    [
      ("path", Lsp_json.String item.batch_parse_path);
      ("module", Lsp_json.String item.batch_parse_module_name);
      ("text", Lsp_json.String item.batch_parse_text);
      ("ast_phase", Lsp_json.String (parsed_source_phase_name phase));
    ]

let parse_sources_request_json ?(phase = RawParsedProgram) items =
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
                 Lsp_json.Array
                   (List.map (parse_source_batch_item_json ~phase) items) );
             ] );
       ])

let cli_frontend_module_origin_json = function
  | CliFrontendUserModule -> Lsp_json.Object [ ("kind", Lsp_json.String "user") ]
  | CliFrontendStdModule -> Lsp_json.Object [ ("kind", Lsp_json.String "std") ]
  | CliFrontendSourcePackageModule package ->
      Lsp_json.Object
        [
          ("kind", Lsp_json.String "source_package");
          ("package", Lsp_json.String package);
        ]
  | CliFrontendPkgModule package ->
      Lsp_json.Object
        [
          ("kind", Lsp_json.String "pkg"); ("package", Lsp_json.String package);
        ]

let typecheck_import_module_json item =
  Lsp_json.Object
    [
      ("path", Lsp_json.String item.typecheck_import_path);
      ("module", Lsp_json.String item.typecheck_import_module_name);
      ("module_path", Lsp_json.String item.typecheck_import_module_path);
      ("text", Lsp_json.String item.typecheck_import_text);
      ( "origin",
        cli_frontend_module_origin_json item.typecheck_import_origin );
    ]

let typecheck_resolved_import_json item =
  Lsp_json.Object
    [
      ("from_path", Lsp_json.String item.typecheck_resolved_import_from_path);
      ("from_module", Lsp_json.String item.typecheck_resolved_import_from_module);
      ("import_path", Lsp_json.String item.typecheck_resolved_import_path);
      ("resolved_module", Lsp_json.String item.typecheck_resolved_import_module);
    ]

let typecheck_resolved_imports_field resolved_imports =
  match resolved_imports with
  | [] -> []
  | _ ->
      [
        ( "resolved_imports",
          Lsp_json.Array
            (List.map typecheck_resolved_import_json resolved_imports) );
      ]

let typecheck_graph_request_json_with_policy ~resolved_imports
    ~allow_debug_only_calls ~target ~modules ~module_targets =
  let payload_fields =
    [
      ("target", typecheck_import_module_json target);
      ( "modules",
        Lsp_json.Array (List.map typecheck_import_module_json modules) );
      ( "module_targets",
        Lsp_json.Array (List.map (fun path -> Lsp_json.String path) module_targets)
      );
      ("include_comments", Lsp_json.Bool false);
      ("allow_debug_only_calls", Lsp_json.Bool allow_debug_only_calls);
    ]
    @ typecheck_resolved_imports_field resolved_imports
  in
  Lsp_json.to_string
    (Lsp_json.Object
       [
         ("schema", Lsp_json.Int schema_version);
         ("domain", Lsp_json.String domain);
         ("action", Lsp_json.String "typecheck_graph");
         ("payload", Lsp_json.Object payload_fields);
       ])

let cli_run_request_json ?version ?source args =
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
    @ (match source with
      | Some source ->
          [
            ( "source",
              Lsp_json.Object
                [
                  ("path", Lsp_json.String source.cli_source_path);
                  ("module", Lsp_json.String source.cli_source_module_name);
                  ("text", Lsp_json.String source.cli_source_text);
                ] );
          ]
      | None -> [])
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

let array_response_field (name : string) (value : Lsp_json.json) :
    (Lsp_json.json list, string * string) result =
  match json_response_field name value with
  | Error _ as error -> error
  | Ok (Lsp_json.Array items) -> Ok items
  | Ok _ -> Error ("invalid_response", "field `" ^ name ^ "` must be an array")

let array_response_field_map (name : string)
    (decode : Lsp_json.json -> ('a, string * string) result)
    (value : Lsp_json.json) : ('a list, string * string) result =
  let* items = array_response_field name value in
  let rec collect acc = function
    | [] -> Ok (List.rev acc)
    | item :: rest ->
        let* decoded = decode item in
        collect (decoded :: acc) rest
  in
  collect [] items

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
      Ok { cc_text; cc_line; cc_col; cc_trailing }
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

let parsed_source_phase_response_field artifact =
  match optional_json_response_field "ast_phase" artifact with
  | Error _ as error -> error
  | Ok None -> Ok RawParsedProgram
  | Ok (Some (Lsp_json.String phase)) -> parsed_source_phase_of_string phase
  | Ok (Some _) ->
      Error ("invalid_response", "field `ast_phase` must be a string")

let module_surface_symbol_kind_field value =
  let* kind = string_response_field "kind" value in
  match Module_surface.symbol_kind_of_string kind with
  | Ok kind -> Ok kind
  | Error message -> Error ("invalid_response", message)

let module_surface_symbol_source_field value =
  let* kind = string_response_field "kind" value in
  let* decl_index = int_response_field "decl_index" value in
  match kind with
  | "decl" -> Ok (Module_surface.Decl decl_index)
  | "trait_method" ->
      let* method_index = int_response_field "method_index" value in
      Ok (Module_surface.TraitMethod (decl_index, method_index))
  | "impl_method" ->
      let* method_index = int_response_field "method_index" value in
      Ok (Module_surface.ImplMethod (decl_index, method_index))
  | "private_decl" -> Ok (Module_surface.PrivateDecl decl_index)
  | "private_trait_method" ->
      let* method_index = int_response_field "method_index" value in
      Ok (Module_surface.PrivateTraitMethod (decl_index, method_index))
  | "private_impl_method" ->
      let* method_index = int_response_field "method_index" value in
      Ok (Module_surface.PrivateImplMethod (decl_index, method_index))
  | other ->
      Error
        ( "invalid_response",
          "unsupported module surface symbol source kind `" ^ other ^ "`" )

let module_surface_symbol_field = function
  | Lsp_json.Object _ as value ->
      let* name = string_response_field "name" value in
      let* kind = module_surface_symbol_kind_field value in
      let* source = json_response_field "source" value in
      let* source = module_surface_symbol_source_field source in
      Ok { Module_surface.name; kind; source }
  | _ ->
      Error ("invalid_response", "module surface symbols must be JSON objects")

let module_surface_import_field = function
  | Lsp_json.Object _ as value ->
      let* module_path = string_response_field "module_path" value in
      Ok { Module_surface.module_path }
  | _ ->
      Error ("invalid_response", "module surface imports must be JSON objects")

let module_surface_field value =
  let* kind = string_response_field "kind" value in
  if kind <> "module_surface" then
    Error
      ( "invalid_response",
        "expected module_surface, got `" ^ kind ^ "`" )
  else
    let* module_name = string_response_field "module" value in
    let* imports =
      array_response_field_map "imports" module_surface_import_field value
    in
    let* exports =
      array_response_field_map "exports" module_surface_symbol_field value
    in
    let* private_names =
      array_response_field_map "private_names" module_surface_symbol_field value
    in
    let* private_traits = string_array_field "private_traits" value in
    Ok
      {
        Module_surface.module_name;
        imports;
        exports;
        private_names;
        private_traits;
      }

let module_surface_artifact_field artifact =
  match optional_json_response_field "module_surface" artifact with
  | Error _ as error -> error
  | Ok None | Ok (Some Lsp_json.Null) -> Ok None
  | Ok (Some surface) ->
      let* decoded = module_surface_field surface in
      Ok (Some decoded)

let parsed_ast_artifact_field artifact =
  let* parsed_phase = parsed_source_phase_response_field artifact in
  let* comments = parse_comments_response_field artifact in
  let* parsed_module_surface = module_surface_artifact_field artifact in
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
            (ParsedSource
               {
                 parsed_program = program;
                 parsed_comments = comments;
                 parsed_phase;
                 parsed_module_surface;
               })
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
  array_response_field_map "sources" parse_source_batch_item_response artifact

let parse_sources_response_json response_json =
  response_result response_json parse_sources_response_field

let require_typecheck_source_phase artifact =
  let* phase = parsed_source_phase_response_field artifact in
  match phase with
  | TypecheckSourceProgram -> Ok phase
  | RawParsedProgram ->
      Error
        ( "invalid_response",
          "typecheck_source artifact must have ast_phase typecheck_source" )

let import_binding_response_field = function
  | Lsp_json.Object _ as value ->
      let* local_name = string_response_field "local_name" value in
      let* module_path = string_response_field "module_path" value in
      let* original_name = optional_string_response_field "original_name" value in
      Ok Session.{ local_name; module_path; original_name }
  | _ ->
      Error
        ("invalid_response", "import_bindings items must be JSON objects")

let typechecked_ctfe_status_field artifact =
  let* status = optional_json_response_field "ctfe_status" artifact in
  match status with
  | None -> Ok false
  | Some (Lsp_json.String "evaluated") -> Ok true
  | Some (Lsp_json.String "not_run") -> Ok false
  | Some (Lsp_json.String other) ->
      Error
        ( "invalid_response",
          "unsupported ctfe_status `" ^ other ^ "`" )
  | Some _ ->
      Error ("invalid_response", "field `ctfe_status` must be a string")

let typechecked_source_artifact_field artifact =
  let* typechecked_phase = require_typecheck_source_phase artifact in
  let* typechecked_comments = parse_comments_response_field artifact in
  let* typechecked_module_surface = module_surface_artifact_field artifact in
  let* typechecked_errors = string_array_field "type_errors" artifact in
  let* typechecked_import_bindings =
    array_response_field_map "import_bindings" import_binding_response_field
      artifact
  in
  let* typechecked_ctfe_evaluated_by_blorp = typechecked_ctfe_status_field artifact in
  let* typed_program_json = json_response_field "typed_program" artifact in
  match Typed_ast_json.decode_typed_program typed_program_json with
  | Ok typechecked_program ->
      Ok
        {
          typechecked_program;
          typechecked_errors;
          typechecked_import_bindings;
          typechecked_ctfe_evaluated_by_blorp;
          typechecked_comments;
          typechecked_phase;
          typechecked_module_surface;
        }
  | Error err ->
      (* Error artifacts may include a best-effort typed tree that failed
         validation while the typechecker was collecting diagnostics. Surface
         the diagnostics first; successful artifacts must still decode fully. *)
      if typechecked_errors <> [] then
        Ok
          {
            typechecked_program = Typed_ast.make_program [];
            typechecked_errors;
            typechecked_import_bindings;
            typechecked_ctfe_evaluated_by_blorp = false;
            typechecked_comments;
            typechecked_phase;
            typechecked_module_surface;
          }
      else
        Error
          ( "invalid_response",
            Typed_ast_json.decode_error_to_string err )

let typechecked_graph_source_artifact_field artifact =
  let* typechecked_graph_path = string_response_field "path" artifact in
  let* typechecked_graph_module_name = string_response_field "module" artifact in
  let* typechecked_graph_artifact = typechecked_source_artifact_field artifact in
  Ok
    {
      typechecked_graph_path;
      typechecked_graph_module_name;
      typechecked_graph_artifact;
    }

let typecheck_graph_source_response_json response_json =
  response_result response_json (fun response ->
      let* artifact = json_response_field "artifact" response in
      typechecked_graph_source_artifact_field artifact)

(** Decode the line protocol after the typecheck helper has exited. Only one
    serialized artifact is retained at a time; decoded module artifacts remain
    live because the semantic middle consumes the complete typed graph. *)
let typecheck_graph_stream_response_channel ~module_count channel =
  let rec next_nonempty_line () =
    match input_line channel with
    | line when String.trim line = "" -> next_nonempty_line ()
    | line -> Some line
    | exception End_of_file -> None
  in
  let rec decode_remaining count =
    match next_nonempty_line () with
    | Some line ->
        let* _ = typecheck_graph_source_response_json line in
        decode_remaining (count + 1)
    | None -> Ok count
  in
  let rec decode_modules remaining decoded_count acc =
    if remaining = 0 then
      match next_nonempty_line () with
      | None ->
          Error
            ( "invalid_response",
              "typecheck_graph returned no target artifact, expected one target" )
      | Some target_line ->
          let* target = typecheck_graph_source_response_json target_line in
          let* trailing_count = decode_remaining 0 in
          if trailing_count = 0 then
            Ok
              {
                typechecked_graph_modules = List.rev acc;
                typechecked_graph_target = target;
              }
          else
            Error
              ( "invalid_response",
                Printf.sprintf
                  "typecheck_graph returned %d trailing artifacts after the target"
                  trailing_count )
    else
      match next_nonempty_line () with
      | Some line ->
          let* source = typecheck_graph_source_response_json line in
          decode_modules (remaining - 1) (decoded_count + 1) (source :: acc)
      | None ->
          Error
            ( "invalid_response",
              Printf.sprintf
                "typecheck_graph returned %d artifacts, expected %d modules and one target"
                decoded_count module_count )
  in
  decode_modules module_count 0 []

let require_compile_frontend_command = function
  | "compile" -> Ok ()
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
    }

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

let cli_frontend_module_origin_field origin =
  let* kind = string_response_field "kind" origin in
  match kind with
  | "user" -> Ok CliFrontendUserModule
  | "std" -> Ok CliFrontendStdModule
  | "source_package" ->
      let* package_alias = string_response_field "package" origin in
      Ok (CliFrontendSourcePackageModule package_alias)
  | "pkg" ->
      let* package_id = string_response_field "package" origin in
      Ok (CliFrontendPkgModule package_id)
  | other ->
      Error
        ( "invalid_response",
          "unsupported frontend module origin `" ^ other ^ "`" )

let optional_cli_frontend_module_origin_field name value =
  match optional_json_response_field name value with
  | Error _ as error -> error
  | Ok None | Ok (Some Lsp_json.Null) -> Ok None
  | Ok (Some origin) ->
      let* decoded = cli_frontend_module_origin_field origin in
      Ok (Some decoded)

let cli_frontend_source_package_field (package : Lsp_json.json) :
    (cli_frontend_source_package, string * string) result =
  let* cli_frontend_source_package_alias =
    string_response_field "alias" package
  in
  let* cli_frontend_source_package_name = string_response_field "name" package in
  let* cli_frontend_source_package_root = string_response_field "root" package in
  let* cli_frontend_source_package_source_dir =
    string_response_field "source_dir" package
  in
  let* cli_frontend_source_package_exports =
    string_array_field "exports" package
  in
  Ok
    {
      cli_frontend_source_package_alias;
      cli_frontend_source_package_name;
      cli_frontend_source_package_root;
      cli_frontend_source_package_source_dir;
      cli_frontend_source_package_exports;
    }

let cli_frontend_source_package_list_field (name : string)
    (value : Lsp_json.json) :
    (cli_frontend_source_package list, string * string) result =
  array_response_field_map name cli_frontend_source_package_field value

let cli_frontend_graph_context_field (artifact : Lsp_json.json) :
    (cli_frontend_graph_context, string * string) result =
  let* context = json_response_field "context" artifact in
  let* cli_frontend_context_std_dir =
    optional_string_response_field "std_dir" context
  in
  let* cli_frontend_context_source_packages =
    cli_frontend_source_package_list_field "source_packages" context
  in
  let* cli_frontend_context_package_roots =
    string_array_field "package_roots" context
  in
  Ok
    {
      cli_frontend_context_std_dir;
      cli_frontend_context_source_packages;
      cli_frontend_context_package_roots;
    }

let cli_frontend_graph_source_field (source : Lsp_json.json) :
    (cli_frontend_graph_source, string * string) result =
  let* cli_frontend_graph_path = string_response_field "path" source in
  let* cli_frontend_graph_module_name = string_response_field "module" source in
  let* cli_frontend_graph_source_text =
    string_response_field "source_text" source
  in
  let* parsed_source = json_response_field "parsed_source" source in
  let* parsed_source_phase = parsed_source_phase_response_field parsed_source in
  let* () =
    match parsed_source_phase with
    | TypecheckSourceProgram -> Ok ()
    | RawParsedProgram ->
        Error
          ( "invalid_response",
            "frontend module graph source must be typecheck_source, got raw_parse"
          )
  in
  let* cli_frontend_graph_parsed_response =
    parsed_ast_artifact_field parsed_source
  in
  let* () =
    match cli_frontend_graph_parsed_response with
    | ParsedSource { parsed_module_surface = Some _; _ }
    | ParseSourceDiagnostics _ ->
        Ok ()
    | ParsedSource { parsed_module_surface = None; _ } ->
        Error
          ( "invalid_response",
            "frontend module graph source must include module_surface" )
  in
  let* origin = json_response_field "origin" source in
  let* cli_frontend_graph_origin = cli_frontend_module_origin_field origin in
  Ok
    {
      cli_frontend_graph_path;
      cli_frontend_graph_module_name;
      cli_frontend_graph_source_text;
      cli_frontend_graph_parsed_response;
      cli_frontend_graph_origin;
    }

let cli_frontend_graph_source_list_field (name : string)
    (artifact : Lsp_json.json) :
    (cli_frontend_graph_source list, string * string) result =
  array_response_field_map name cli_frontend_graph_source_field artifact

let cli_frontend_import_edge_field (edge : Lsp_json.json) :
    (cli_frontend_import_edge, string * string) result =
  let* cli_frontend_import_from_path = string_response_field "from_path" edge in
  let* cli_frontend_import_from_module =
    string_response_field "from_module" edge
  in
  let* cli_frontend_import_path = string_response_field "import_path" edge in
  let* cli_frontend_import_resolved_path =
    optional_string_response_field "resolved_path" edge
  in
  let* cli_frontend_import_resolved_module =
    optional_string_response_field "resolved_module" edge
  in
  let* cli_frontend_import_resolved_origin =
    optional_cli_frontend_module_origin_field "resolved_origin" edge
  in
  Ok
    {
      cli_frontend_import_from_path;
      cli_frontend_import_from_module;
      cli_frontend_import_path;
      cli_frontend_import_resolved_path;
      cli_frontend_import_resolved_module;
      cli_frontend_import_resolved_origin;
    }

let cli_frontend_import_edges_field (artifact : Lsp_json.json) :
    (cli_frontend_import_edge list, string * string) result =
  array_response_field_map "imports" cli_frontend_import_edge_field artifact

let cli_frontend_graph_diagnostics_field artifact =
  string_array_field "diagnostics" artifact

let cli_frontend_graph_contains_source sources path module_name =
  List.exists
    (fun source ->
      source.cli_frontend_graph_path = path
      && source.cli_frontend_graph_module_name = module_name)
    sources

let validate_cli_frontend_import_edges ~sources edges =
  let validate_edge edge =
    match
      ( edge.cli_frontend_import_resolved_path,
        edge.cli_frontend_import_resolved_module )
    with
    | None, None -> Ok ()
    | Some path, Some module_name ->
        if cli_frontend_graph_contains_source sources path module_name then Ok ()
        else
          Error
            ( "invalid_response",
              "frontend import edge resolved to `" ^ module_name ^ "` at `"
              ^ path ^ "` but that source is absent from the graph" )
    | _ ->
        Error
          ( "invalid_response",
            "frontend import edge must provide both resolved_path and \
             resolved_module, or neither" )
  in
  let rec loop = function
    | [] -> Ok ()
    | edge :: rest ->
        let* () = validate_edge edge in
        loop rest
  in
  loop edges

let cli_frontend_module_graph_response_field artifact =
  let* command_text = string_response_field "command" artifact in
  let* () = require_compile_frontend_command command_text in
  let* cli_frontend_graph_args = string_array_field "args" artifact in
  let* () =
    validate_cli_artifact_command "frontend_module_graph" command_text
      cli_frontend_graph_args
  in
  let* options = json_response_field "options" artifact in
  let* cli_frontend_graph_compile_options =
    decode_cli_compile_options options
  in
  let* cli_frontend_graph_context =
    cli_frontend_graph_context_field artifact
  in
  let* cli_frontend_graph_roots =
    cli_frontend_graph_source_list_field "roots" artifact
  in
  let* cli_frontend_graph_modules =
    cli_frontend_graph_source_list_field "modules" artifact
  in
  let* cli_frontend_graph_imports = cli_frontend_import_edges_field artifact in
  let* cli_frontend_graph_diagnostics =
    cli_frontend_graph_diagnostics_field artifact
  in
  let* () =
    validate_cli_frontend_import_edges
      ~sources:(cli_frontend_graph_roots @ cli_frontend_graph_modules)
      cli_frontend_graph_imports
  in
  Ok
    (CliRunFrontendModuleGraph
       {
         cli_frontend_graph_args;
         cli_frontend_graph_compile_options;
         cli_frontend_graph_context;
         cli_frontend_graph_roots;
         cli_frontend_graph_modules;
         cli_frontend_graph_imports;
         cli_frontend_graph_diagnostics;
       })

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
  | "frontend_module_graph" -> cli_frontend_module_graph_response_field artifact
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

let language_surface_bootstrap_rows = Language_surface_data.rows

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
let prepared_typecheck_bridge_bin_env = "BLORP_COMPILER_TYPECHECK_BRIDGE_BIN"
let require_prepared_bridge_env = "BLORP_COMPILER_REQUIRE_PREPARED_BRIDGE"
let capture_emit_core_request_env = "BLORP_COMPILER_CAPTURE_EMIT_CORE_REQUEST"
let capture_typecheck_graph_request_env =
  "BLORP_COMPILER_CAPTURE_TYPECHECK_GRAPH_REQUEST"
let renderer_bridge_source_name = "compiler/blorp/src/stage_12_cli/compiler_bridge_cli.brp"
let parser_bridge_source_name = "compiler/blorp/src/stage_12_cli/compiler_parser_bridge_cli.brp"
let typecheck_bridge_source_name =
  "compiler/blorp/src/stage_12_cli/compiler_typecheck_bridge_cli.brp"
let bridge_helper_compile_env =
  [
    (renderer_bridge_helper_env, "1");
    (* Only pinned external bootstrap binaries read this retired selector.
       Current compiler sessions do not use it, but direct bootstrap-binary
       helper builds still need to stay on the bootstrap's built-in parser. *)
    ("BLORP_FRONTEND_PARSER", "ocaml");
  ]

let parser_bridge_helper_compile_env = bridge_helper_compile_env
let typecheck_bridge_helper_compile_env = bridge_helper_compile_env

let renderer_bridge_cache :
    (string * string * string * string * string) option ref =
  ref None

let parser_bridge_cache :
    (string * string * string * string * string) option ref =
  ref None

let typecheck_bridge_cache :
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

let read_file_excerpt_if_exists path =
  if not (Sys.file_exists path) then ""
  else
    let channel = open_in_bin path in
    Fun.protect
      ~finally:(fun () -> close_in_noerr channel)
      (fun () ->
        let len = in_channel_length channel in
        let excerpt_len = min len bridge_error_excerpt_limit in
        let excerpt = really_input_string channel excerpt_len in
        if excerpt_len = len then excerpt
        else
          excerpt
          ^ Printf.sprintf "... <truncated %d bytes>" (len - excerpt_len))

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
  try
    Fun.protect
      ~finally:(fun () -> close_out_noerr channel)
      (fun () -> output_string channel request_json);
    path
  with exn ->
    (try Sys.remove path with _ -> ());
    raise exn

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
let bridge_helper_compile_unset_env =
  [
    compiler_bridge_bin_env;
    prepared_renderer_bridge_bin_env;
    prepared_parser_bridge_bin_env;
    prepared_typecheck_bridge_bin_env;
    "BLORP_OCAML_HOST_BIN";
    "BLORP_OCAML_MIDDLE_BIN";
  ]

type bridge_helper_compiler_source =
  | PinnedBootstrapScript
  | ExplicitBootstrapOverride

type bridge_helper_compiler = {
  helper_compiler_path : string;
  helper_compiler_source : bridge_helper_compiler_source;
}

let existing_executable_candidates prog =
  executable_candidates prog |> List.filter Sys.file_exists

let file_identity path =
  try
    let st = Unix.stat path in
    Some (st.Unix.st_dev, st.Unix.st_ino)
  with _ -> None

let same_file left right =
  match (file_identity left, file_identity right) with
  | Some left_id, Some right_id -> left_id = right_id
  | _ -> false

let explicit_override_is_current_executable path =
  let current_candidates = existing_executable_candidates Sys.executable_name in
  let override_candidates = existing_executable_candidates path in
  List.exists
    (fun override ->
      List.exists (fun current -> same_file override current) current_candidates)
    override_candidates

let validate_explicit_bridge_helper_override path =
  if explicit_override_is_current_executable path then
    Error
      (Printf.sprintf
         "%s must point to a bootstrap-capable Blorp compiler, not the current \
          compiler executable `%s`. Provide prepared helper binaries with %s, \
          %s, and %s, or unset %s to use %s."
         compiler_bridge_bin_env path prepared_renderer_bridge_bin_env
         prepared_parser_bridge_bin_env prepared_typecheck_bridge_bin_env
         compiler_bridge_bin_env
         compiler_bootstrap_script_name)
  else Ok ()

let locate_bridge_helper_compiler ?(bridge_bin = Sys.getenv_opt compiler_bridge_bin_env)
    starts =
  match bridge_bin with
  | Some path when path <> "" ->
      let* () = validate_explicit_bridge_helper_override path in
      Ok
        {
          helper_compiler_path = path;
          helper_compiler_source = ExplicitBootstrapOverride;
        }
  | _ -> (
      match find_upwards_from starts compiler_bootstrap_script_name with
      | Some path ->
          Ok
            {
              helper_compiler_path = path;
              helper_compiler_source = PinnedBootstrapScript;
            }
      | None ->
          Error
            (Printf.sprintf
               "cannot locate pinned Blorp compiler bootstrap %s; set %s to a \
                bootstrap-capable blorp binary"
               compiler_bootstrap_script_name compiler_bridge_bin_env))

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
      (Process_status.exit_code status, output, stderr_output)

type completed_file_process = {
  process_exit_code : int;
  process_stdout_path : string;
  process_stdout_bytes : int;
  process_stderr_output : string;
  process_stderr_bytes : int;
}

let close_fd_noerr fd = try Unix.close fd with _ -> ()

let close_owned_fd fd =
  match !fd with
  | Some value ->
      fd := None;
      close_fd_noerr value
  | None -> ()

let with_process_stdout_file ?(env = []) ?(unset_env = []) prog args consume =
  let stdout_path, stdout_fd_value =
    create_bridge_temp_file "blorp-compiler-bridge-stdout-" ".jsonl"
      bridge_temp_retry_limit
  in
  let stderr_path, stderr_fd_value =
    try
      create_bridge_temp_file "blorp-compiler-bridge-stderr-" ".log"
        bridge_temp_retry_limit
    with exn ->
      close_fd_noerr stdout_fd_value;
      (try Sys.remove stdout_path with _ -> ());
      raise exn
  in
  let stdout_fd = ref (Some stdout_fd_value) in
  let stderr_fd = ref (Some stderr_fd_value) in
  Fun.protect
    ~finally:(fun () ->
      close_owned_fd stdout_fd;
      close_owned_fd stderr_fd;
      (try Sys.remove stdout_path with _ -> ());
      (try Sys.remove stderr_path with _ -> ()))
    (fun () ->
      match Unix.fork () with
      | 0 -> (
          try
            Unix.dup2 stdout_fd_value Unix.stdout;
            Unix.dup2 stderr_fd_value Unix.stderr;
            Unix.close stdout_fd_value;
            Unix.close stderr_fd_value;
            exec_program prog args (child_environment ~env ~unset_env)
          with _ -> Unix._exit 127)
      | pid ->
          close_owned_fd stdout_fd;
          close_owned_fd stderr_fd;
          let status = waitpid_retry pid in
          let stdout_bytes = (Unix.stat stdout_path).Unix.st_size in
          let stderr_bytes = (Unix.stat stderr_path).Unix.st_size in
          let stderr_output = read_file_excerpt_if_exists stderr_path in
          consume
            {
              process_exit_code = Process_status.exit_code status;
              process_stdout_path = stdout_path;
              process_stdout_bytes = stdout_bytes;
              process_stderr_output = stderr_output;
              process_stderr_bytes = stderr_bytes;
            })

let default_bridge_helper_compiler () =
  let starts = [ Sys.getcwd (); Filename.dirname Sys.executable_name ] in
  locate_bridge_helper_compiler starts

let parser_bridge_helper_compiler () =
  let starts = [ Sys.getcwd (); Filename.dirname Sys.executable_name ] in
  locate_bridge_helper_compiler starts

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

let typecheck_bridge_source_path () =
  let starts = [ Sys.getcwd (); Filename.dirname Sys.executable_name ] in
  match find_upwards_from starts typecheck_bridge_source_name with
  | Some path -> path
  | None ->
      invalid_arg
        (Printf.sprintf "cannot locate Blorp typecheck bridge source %s"
           typecheck_bridge_source_name)

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

let generated_c_tag_identifiers c_code =
  let marker = "TAG_" in
  let marker_len = String.length marker in
  let len = String.length c_code in
  let rec identifier_end index =
    if index < len && is_ident_char c_code.[index] then identifier_end (index + 1)
    else index
  in
  let rec scan index found =
    if index + marker_len > len then List.sort_uniq String.compare found
    else if string_starts_with_at c_code index marker then
      let stop = identifier_end (index + marker_len) in
      scan stop (String.sub c_code index (stop - index) :: found)
    else scan (index + 1) found
  in
  scan 0 []

let string_ends_with value suffix =
  let value_len = String.length value in
  let suffix_len = String.length suffix in
  suffix_len <= value_len
  && String.equal (String.sub value (value_len - suffix_len) suffix_len) suffix

let generated_c_missing_enum_patterns c_code variant_defs =
  let variants =
    variant_defs
    |> List.filter_map (fun (variant, definition) ->
           Option.map (fun _ -> variant) definition)
    |> List.sort (fun left right ->
           Int.compare (String.length right) (String.length left))
  in
  generated_c_tag_identifiers c_code
  |> List.filter_map (fun tag_name ->
         match
           List.find_opt
             (fun variant -> string_ends_with tag_name ("_" ^ variant))
             variants
         with
         | None -> None
         | Some variant ->
             let tag_prefix_len = String.length tag_name - String.length variant in
             let tag_prefix = String.sub tag_name 0 tag_prefix_len in
             let type_name =
               String.sub tag_prefix 4 (String.length tag_prefix - 5)
             in
             let struct_decl = "typedef struct " ^ type_name in
             if string_contains_substring c_code struct_decl then None
             else Some (type_name, tag_prefix))
  |> List.sort_uniq compare

let generated_c_with_stack_enum_payload_patterns c_code =
  let variant_defs = generated_c_variant_defs c_code in
  let patterns = generated_c_missing_enum_patterns c_code variant_defs in
  List.fold_left
    (fun code (type_name, tag_prefix) ->
      rewrite_casted_enum_tag_checks code ~type_name ~tag_prefix variant_defs)
    c_code patterns

let generated_c_with_bootstrap_compatibility c_code =
  c_code
  |> generated_c_with_forward_typedefs
  |> generated_c_with_stack_enum_payload_patterns

let apply_generated_c_bootstrap_compatibility path =
  let original = read_file path in
  let rewritten = generated_c_with_bootstrap_compatibility original in
  if not (String.equal original rewritten) then write_file path rewritten

let compile_bridge_binary_in_stage ~compiler ~source_path ~compile_env ~stage_dir
    ~bin_path =
  let program = compiler.helper_compiler_path in
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
          ~unset_env:bridge_helper_compile_unset_env
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

let copy_binary_to_path ~source_path ~dest_path =
  let dest_dir = Filename.dirname dest_path in
  ensure_dir dest_dir;
  let temp_path =
    Filename.concat dest_dir
      (Printf.sprintf ".%s.%d-%d.tmp" (Filename.basename dest_path)
         (Unix.getpid ())
         (Random.bits () land 0x3fffffff))
  in
  let published = ref false in
  try
    Fun.protect
      ~finally:(fun () ->
        if not !published then try Sys.remove temp_path with _ -> ())
      (fun () ->
        let input_channel = open_in_bin source_path in
        Fun.protect
          ~finally:(fun () -> close_in_noerr input_channel)
          (fun () ->
            let output_channel = open_out_bin temp_path in
            Fun.protect
              ~finally:(fun () -> close_out_noerr output_channel)
              (fun () ->
                let buffer = Bytes.create 65536 in
                let rec copy_loop () =
                  match
                    input input_channel buffer 0 (Bytes.length buffer)
                  with
                  | 0 -> ()
                  | count ->
                      output output_channel buffer 0 count;
                      copy_loop ()
                in
                copy_loop ()));
        Unix.chmod temp_path 0o755;
        Unix.rename temp_path dest_path;
        published := true;
        Ok dest_path)
  with exn ->
    Error
      (Printf.sprintf "failed to copy prepared Blorp bridge helper %s to %s: %s"
         source_path dest_path (Printexc.to_string exn))

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

let compile_renderer_bridge_binary ~compiler ~source_path ~cache_root
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
      compile_bridge_binary_in_stage ~compiler ~source_path ~compile_env
        ~stage_dir ~bin_path
    with
    | Error message ->
        remove_path_noerr stage_dir;
        Error message
    | Ok _ ->
        write_renderer_bridge_cache_markers parts stage_dir;
        publish_renderer_bridge_cache_dir parts ~stage_dir ~final_dir)

let bridge_binary_for_source cache_ref ~compiler ~source_path ~compile_env =
  let cache_root = renderer_bridge_cache_root () in
  let program = compiler.helper_compiler_path in
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
        compile_renderer_bridge_binary ~compiler ~source_path ~cache_root
          ~compile_env cache_parts
      with
      | Ok binary ->
          cache_ref :=
            Some
              (program, source_path, cache_root, cache_parts.bridge_key, binary);
          Ok binary
      | Error _ as error -> error)

let prepared_bridge_sibling_name env_name =
  if String.equal env_name prepared_renderer_bridge_bin_env then
    Some "blorp-compiler-renderer"
  else if String.equal env_name prepared_parser_bridge_bin_env then
    Some "blorp-compiler-parser"
  else if String.equal env_name prepared_typecheck_bridge_bin_env then
    Some "blorp-compiler-typecheck"
  else None

let executable_candidate_can_run path =
  try
    if Sys.is_directory path then false
    else (
      Unix.access path [ Unix.X_OK ];
      true)
  with Sys_error _ | Unix.Unix_error _ -> false

let prepared_bridge_sibling_candidates ~current_executable env_name =
  match prepared_bridge_sibling_name env_name with
  | None -> []
  | Some name -> (
      let resolved_current =
        if String.contains current_executable '/' then Some current_executable
        else
          executable_candidates current_executable
          |> List.find_opt executable_candidate_can_run
      in
      match resolved_current with
      | Some current -> [ Filename.concat (Filename.dirname current) name ]
      | None -> [])

let prepared_bridge_binary_from_env
    ?(current_executable = Sys.executable_name) env_name =
  match Sys.getenv_opt env_name with
  | Some path when path <> "" ->
      if Sys.file_exists path && not (Sys.is_directory path) then Some (Ok path)
      else
        Some
          (Error
             (Printf.sprintf
                "%s points to missing Blorp bridge helper binary: %s" env_name
                path))
  | _ ->
      prepared_bridge_sibling_candidates ~current_executable env_name
      |> List.find_opt (fun path ->
             Sys.file_exists path && not (Sys.is_directory path))
      |> Option.map (fun path -> Ok path)

let prepared_bridge_required () =
  match Sys.getenv_opt require_prepared_bridge_env with Some "1" -> true | _ -> false

let bridge_stats_enabled () =
  match Sys.getenv_opt "BLORP_COMPILER_BRIDGE_STATS" with
  | Some ("1" | "true" | "TRUE" | "yes" | "YES") -> true
  | _ -> false

let bridge_request_action request_json =
  match Lsp_json.parse request_json with
  | Lsp_json.Object fields -> (
      match List.assoc_opt "action" fields with
      | Some (Lsp_json.String action) -> action
      | _ -> "unknown")
  | _ -> "unknown"
  | exception Lsp_json.Parse_error _ -> "unknown"

let log_bridge_stats ~action ~bridge_binary ~request_bytes ~stdout_bytes
    ~stderr_bytes ~duration_ms ~exit_code =
  Printf.eprintf
    "BLORP_BRIDGE_STATS action=%s helper=%s request_bytes=%d stdout_bytes=%d \
     stderr_bytes=%d duration_ms=%d exit=%d\n\
     %!"
    action (Filename.basename bridge_binary) request_bytes stdout_bytes
    stderr_bytes duration_ms exit_code

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
      let* compiler = default_bridge_helper_compiler () in
      bridge_binary_for_source renderer_bridge_cache ~compiler
        ~source_path:(renderer_bridge_source_path ())
        ~compile_env:bridge_helper_compile_env

let parser_bridge_binary () =
  match prepared_bridge_binary_from_env prepared_parser_bridge_bin_env with
  | Some result -> result
  | None when prepared_bridge_required () ->
      missing_prepared_bridge_error prepared_parser_bridge_bin_env
  | None ->
      let* compiler = parser_bridge_helper_compiler () in
      bridge_binary_for_source parser_bridge_cache ~compiler
        ~source_path:(parser_bridge_source_path ())
        ~compile_env:parser_bridge_helper_compile_env

let typecheck_bridge_binary () =
  match prepared_bridge_binary_from_env prepared_typecheck_bridge_bin_env with
  | Some result -> result
  | None when prepared_bridge_required () ->
      missing_prepared_bridge_error prepared_typecheck_bridge_bin_env
  | None ->
      let* compiler = parser_bridge_helper_compiler () in
      bridge_binary_for_source typecheck_bridge_cache ~compiler
        ~source_path:(typecheck_bridge_source_path ())
        ~compile_env:typecheck_bridge_helper_compile_env

type prepared_bridge_binaries = {
  prepared_renderer_bridge_bin : string;
  prepared_parser_bridge_bin : string;
  prepared_typecheck_bridge_bin : string;
}

let prepare_bridge_binaries ~out_dir =
  ensure_dir out_dir;
  let* compiler = default_bridge_helper_compiler () in
  let renderer_bin = Filename.concat out_dir "compiler_renderer_bridge.bin" in
  let parser_bin = Filename.concat out_dir "compiler_parser_bridge.bin" in
  let typecheck_bin = Filename.concat out_dir "compiler_typecheck_bridge.bin" in
  let* cached_renderer_path =
    bridge_binary_for_source renderer_bridge_cache ~compiler
      ~source_path:(renderer_bridge_source_path ())
      ~compile_env:bridge_helper_compile_env
  in
  let* cached_parser_path =
    bridge_binary_for_source parser_bridge_cache ~compiler
      ~source_path:(parser_bridge_source_path ())
      ~compile_env:parser_bridge_helper_compile_env
  in
  let* cached_typecheck_path =
    bridge_binary_for_source typecheck_bridge_cache ~compiler
      ~source_path:(typecheck_bridge_source_path ())
      ~compile_env:typecheck_bridge_helper_compile_env
  in
  let* renderer_path =
    copy_binary_to_path ~source_path:cached_renderer_path
      ~dest_path:renderer_bin
  in
  let* parser_path =
    copy_binary_to_path ~source_path:cached_parser_path ~dest_path:parser_bin
  in
  let* typecheck_path =
    copy_binary_to_path ~source_path:cached_typecheck_path
      ~dest_path:typecheck_bin
  in
  Ok
    {
      prepared_renderer_bridge_bin = renderer_path;
      prepared_parser_bridge_bin = parser_path;
      prepared_typecheck_bridge_bin = typecheck_path;
    }

type bridge_request_stats = {
  request_action : string;
  request_bytes : int;
}

type prepared_bridge_request = {
  request_path : string;
  request_stats : bridge_request_stats option;
  request_error_excerpt : string;
}

let prepare_bridge_request ~stats_enabled request_json =
  let request_stats =
    if stats_enabled then
      Some
        {
          request_action = bridge_request_action request_json;
          request_bytes = String.length request_json;
        }
    else None
  in
  let request_error_excerpt = bridge_error_excerpt request_json in
  let request_path = write_temp_request request_json in
  {
    request_path;
    request_stats;
    request_error_excerpt;
  }

let with_resolved_prepared_bridge_request
    ?(release_host_heap_before_run = false) bridge_binary request run =
  Fun.protect
    ~finally:(fun () -> try Sys.remove request.request_path with _ -> ())
    (fun () ->
      (* The Core emitter builds an independent Blorp representation of a
         compiler-sized request. Release dead frontend and OCaml Core heap
         chunks before resolving or starting that helper so both compilers do
         not consume physical memory concurrently on a cold cache. *)
      if release_host_heap_before_run then Gc.compact ();
      match bridge_binary () with
      | Error message -> Error ("bridge_command_failed", message)
      | Ok bridge_binary -> run bridge_binary)

let log_prepared_bridge_stats request ~bridge_binary ~stdout_bytes ~stderr_bytes
    ~started_at ~exit_code =
  Option.iter
    (fun stats ->
      log_bridge_stats ~action:stats.request_action ~bridge_binary
        ~request_bytes:stats.request_bytes ~stdout_bytes ~stderr_bytes
        ~duration_ms:
          (int_of_float ((Unix.gettimeofday () -. started_at) *. 1000.0))
        ~exit_code)
    request.request_stats

let bridge_process_failure_message request ~exit_code ~stdout ~stderr =
  Printf.sprintf "Blorp bridge command exited %d: %s\nrequest: %s" exit_code
    (String.trim (stdout ^ stderr))
    request.request_error_excerpt

let run_prepared_bridge_request ?(release_host_heap_before_run = false)
    bridge_binary request =
  match
    with_resolved_prepared_bridge_request ~release_host_heap_before_run
      bridge_binary request (fun bridge_binary ->
        let started_at = Unix.gettimeofday () in
        let exit_code, output, stderr_output =
          run_process_capture bridge_binary ~unset_env:[ "BLORP_LEAK_CHECK" ]
            [ request.request_path ]
        in
        log_prepared_bridge_stats request ~bridge_binary
          ~stdout_bytes:(String.length output)
          ~stderr_bytes:(String.length stderr_output) ~started_at ~exit_code;
        if exit_code = 0 then Ok output
        else
          Error
            ( "bridge_command_failed",
              bridge_process_failure_message request ~exit_code ~stdout:output
                ~stderr:stderr_output ))
  with
  | Ok output -> output
  | Error (code, message) -> error_response code message

let typecheck_graph_response_file ~module_count path =
  let channel = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr channel)
    (fun () -> typecheck_graph_stream_response_channel ~module_count channel)

let run_prepared_typecheck_graph_request ~module_count bridge_binary request =
  with_resolved_prepared_bridge_request bridge_binary request
    (fun bridge_binary ->
      let started_at = Unix.gettimeofday () in
      with_process_stdout_file bridge_binary
        ~unset_env:[ "BLORP_LEAK_CHECK" ]
        [ request.request_path ] (fun completed ->
          log_prepared_bridge_stats request ~bridge_binary
            ~stdout_bytes:completed.process_stdout_bytes
            ~stderr_bytes:completed.process_stderr_bytes ~started_at
            ~exit_code:completed.process_exit_code;
          if completed.process_exit_code = 0 then
            typecheck_graph_response_file ~module_count
              completed.process_stdout_path
          else
            Error
              ( "bridge_command_failed",
                bridge_process_failure_message request
                  ~exit_code:completed.process_exit_code
                  ~stdout:
                    (read_file_excerpt_if_exists completed.process_stdout_path)
                  ~stderr:completed.process_stderr_output )))

let run_request_via_blorp_binary ?release_host_heap_before_run bridge_binary
    request_json =
  let stats_enabled = bridge_stats_enabled () in
  run_prepared_bridge_request ?release_host_heap_before_run bridge_binary
    (prepare_bridge_request ~stats_enabled request_json)

let run_renderer_request_via_blorp ?release_host_heap_before_run request_json =
  run_request_via_blorp_binary ?release_host_heap_before_run
    renderer_bridge_binary request_json

let run_parser_request_via_blorp request_json =
  run_request_via_blorp_binary parser_bridge_binary request_json

let run_typecheck_graph_request_via_blorp ~module_count request_json =
  let stats_enabled = bridge_stats_enabled () in
  run_prepared_typecheck_graph_request ~module_count typecheck_bridge_binary
    (prepare_bridge_request ~stats_enabled request_json)

let run_cli_request_via_blorp ?version ?source args =
  run_parser_request_via_blorp (cli_run_request_json ?version ?source args)

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

let emit_core_c_artifact_exn ?(profile = false) core_json =
  let request_json = emit_core_c_request_json ~profile core_json in
  match Sys.getenv_opt capture_emit_core_request_env with
  | Some capture_path when not (String.equal capture_path "") ->
      write_file capture_path request_json;
      invalid_arg
        (Printf.sprintf
           "captured emit_core_c request at %s; renderer was not started because \
            %s is set"
           capture_path capture_emit_core_request_env)
  | _ ->
      let response_json =
        run_renderer_request_via_blorp ~release_host_heap_before_run:true
          request_json
      in
      (match response_result response_json c_artifact_response_field with
      | Ok artifact -> artifact
      | Error (_, message) -> invalid_arg message)

let run_core_pipeline_core_json_exn ~stage core_json =
  let response_json =
    run_renderer_request_via_blorp
      (run_core_pipeline_request_json ~stage core_json)
  in
  match response_result response_json (json_response_field "core") with
  | Ok transformed_core -> transformed_core
  | Error (_, message) -> invalid_arg message

let parse_source_via_command_at_phase ~phase ~path ~module_name ~text =
  let response_json =
    run_parser_request_via_blorp
      (parse_source_request_json_at_phase ~phase ~path ~module_name ~text)
  in
  parse_source_response_json response_json

let parse_sources_via_command ?(phase = RawParsedProgram) items =
  let response_json =
    run_parser_request_via_blorp (parse_sources_request_json ~phase items)
  in
  parse_sources_response_json response_json

let parse_source_file_via_command_at_phase ~phase ~path ~module_name =
  let response_json =
    run_parser_request_via_blorp
      (parse_source_file_request_json_at_phase ~phase ~path ~module_name)
  in
  parse_source_response_json response_json

let typecheck_graph_via_command_with_policy ~resolved_imports
    ~allow_debug_only_calls ~target ~modules ~module_targets =
  let request_json =
    typecheck_graph_request_json_with_policy ~resolved_imports
      ~allow_debug_only_calls ~target ~modules ~module_targets
  in
  match Sys.getenv_opt capture_typecheck_graph_request_env with
  | Some capture_path when not (String.equal capture_path "") ->
      write_file capture_path request_json;
      invalid_arg
        (Printf.sprintf
           "captured typecheck_graph request at %s; typecheck helper was not \
            started because %s is set"
           capture_path capture_typecheck_graph_request_env)
  | _ ->
      run_typecheck_graph_request_via_blorp
        ~module_count:(List.length module_targets) request_json

let cli_run_via_command ?version ?source args =
  run_cli_request_via_blorp ?version ?source args |> cli_run_response_json

let cli_run_source_via_command ~path ~module_name ~text args =
  cli_run_via_command
    ~source:
      {
        cli_source_path = path;
        cli_source_module_name = module_name;
        cli_source_text = text;
      }
    args

let render_core_stage_unknown_error original normalized =
  render_via_command_exn ~renderer:core_stage_renderer
    ~op:"core_stage_unknown_error" [ original; normalized ]

let render_core_trait_resolve_no_impl_hint ~method_name ~type_name ~candidates =
  render_via_command_exn ~renderer:core_trait_resolve_renderer
    ~op:"core_trait_resolve_no_impl_hint"
    [ method_name; type_name; String.concat ";" candidates ]

let () =
  Core_stage.set_unknown_stage_error_renderer render_core_stage_unknown_error
