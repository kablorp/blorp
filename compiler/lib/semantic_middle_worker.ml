(** Private prepared-Core to pre-DCE Core worker.

    This is the one temporary OCaml boundary between the Blorp-owned frontend
    and backend. The protocol is phase-specific: callers supply lowered,
    flattened, FFI-annotated, list-layout-annotated Core, and successful
    requests return the Core program immediately
    before Blorp-owned DCE. This module does not read source files, interpret
    CLI arguments, emit C, write artifacts, or execute child processes. *)

let schema_version = 2
let protocol_domain = "compiler_semantic_middle"
let request_kind = "compile_pre_dce"
let core_phase = "prepared"

type stage = Core_stage.t

type capability =
  | PreparedCore
  | PreDceCore
  | RenderedStageObservations

type protocol_error = { code : string; message : string }

type request = {
  target_path : string;
  target_module : string;
  core : Core.core_program;
  foreign_includes : string list;
  next_def_id : int;
  import_bindings : Session.import_binding list;
  module_imports : (string * Session.import_binding list) list;
  debug : bool;
  require_main : bool;
  check_invariants : bool;
  observations : stage list;
  stop_after : stage option;
}

type observation = { stage : stage; rendered : string }

type diagnostic = {
  code : string;
  message : string;
  path : string option;
  line : int;
  column : int;
  help : string option;
}

type response =
  | Compiled of {
      core : Lsp_json.json;
      observations : observation list;
    }
  | Stopped of {
      stage : stage;
      rendered : string;
      observations : observation list;
    }
  | Failed of diagnostic list

exception Stopped_with_snapshot of stage * string

let ( let* ) = Result.bind

let protocol_error code message = Error { code; message }

let field name = function
  | Lsp_json.Object fields -> (
      match List.assoc_opt name fields with
      | Some value -> Ok value
      | None -> protocol_error "missing_field" ("missing field `" ^ name ^ "`"))
  | _ -> protocol_error "invalid_request" "request must be a JSON object"

let string_field name value =
  let* value = field name value in
  match value with
  | Lsp_json.String text -> Ok text
  | _ ->
      protocol_error "invalid_field" ("field `" ^ name ^ "` must be a string")

let int_field name value =
  let* value = field name value in
  match value with
  | Lsp_json.Int number -> Ok number
  | _ ->
      protocol_error "invalid_field" ("field `" ^ name ^ "` must be an integer")

let bool_field name value =
  let* value = field name value in
  match value with
  | Lsp_json.Bool flag -> Ok flag
  | _ ->
      protocol_error "invalid_field" ("field `" ^ name ^ "` must be a boolean")

let array_field name value =
  let* value = field name value in
  match value with
  | Lsp_json.Array items -> Ok items
  | _ ->
      protocol_error "invalid_field" ("field `" ^ name ^ "` must be an array")

let optional_string_field name value =
  let* value = field name value in
  match value with
  | Lsp_json.Null -> Ok None
  | Lsp_json.String text -> Ok (Some text)
  | _ ->
      protocol_error "invalid_field"
        ("field `" ^ name ^ "` must be a string or null")

let rec decode_list decode = function
  | [] -> Ok []
  | item :: rest ->
      let* item = decode item in
      let* rest = decode_list decode rest in
      Ok (item :: rest)

let semantic_middle_stage = function
  | ( Core_stage.Lower | Core_stage.Debug | Core_stage.Desugar | Core_stage.Mono
    | Core_stage.Synth | Core_stage.Match | Core_stage.TraitResolve
    | Core_stage.Resolve | Core_stage.StdInline | Core_stage.Tailrec
    | Core_stage.Fusion ) as stage ->
      Some stage
  | Core_stage.Specialize | Core_stage.Dce | Core_stage.ConsumeSpecialize | Core_stage.Perceus
  | Core_stage.Reuse | Core_stage.Closure | Core_stage.Final ->
      None

let stage_name = Core_stage.to_string

let capability_name = function
  | PreparedCore -> "core_pre_middle"
  | PreDceCore -> "core_pre_dce"
  | RenderedStageObservations -> "rendered_stage_observations"

let supported_capabilities =
  [ PreparedCore; PreDceCore; RenderedStageObservations ]

let decode_capability = function
  | Lsp_json.String "core_pre_middle" -> Ok PreparedCore
  | Lsp_json.String "core_pre_dce" -> Ok PreDceCore
  | Lsp_json.String "rendered_stage_observations" ->
      Ok RenderedStageObservations
  | Lsp_json.String name ->
      protocol_error "unsupported_capability"
        ("unsupported semantic-middle capability `" ^ name ^ "`")
  | _ ->
      protocol_error "invalid_field"
        "field `required_capabilities` must contain strings"

let decode_stage = function
  | Lsp_json.String name -> (
      match Core_stage.of_string name with
      | Ok stage -> (
          match semantic_middle_stage stage with
          | Some stage -> Ok stage
          | None ->
              protocol_error "unsupported_stage"
                ("stage `" ^ name ^ "` is outside the semantic middle"))
      | Error _ ->
          protocol_error "unsupported_stage" ("unknown stage `" ^ name ^ "`"))
  | _ -> protocol_error "invalid_field" "stage names must be strings"

let decode_import_binding value =
  let* local_name = string_field "local_name" value in
  let* module_path = string_field "module_path" value in
  let* original_name = optional_string_field "original_name" value in
  Ok { Session.local_name; module_path; original_name }

let decode_module_imports value =
  let* module_name = string_field "module" value in
  let* import_binding_values = array_field "import_bindings" value in
  let* import_bindings = decode_list decode_import_binding import_binding_values in
  Ok (module_name, import_bindings)

let require_equal ~code ~field_name ~expected actual =
  if String.equal actual expected then Ok ()
  else
    protocol_error code
      (Printf.sprintf "field `%s` must be `%s`, got `%s`" field_name expected
         actual)

let decode_request value =
  let* schema = int_field "schema" value in
  if schema <> schema_version then
    protocol_error "unsupported_schema"
      (Printf.sprintf "unsupported semantic-middle schema %d" schema)
  else
    let* domain = string_field "domain" value in
    let* () =
      require_equal ~code:"unsupported_domain" ~field_name:"domain"
        ~expected:protocol_domain domain
    in
    let* kind = string_field "kind" value in
    let* () =
      require_equal ~code:"unsupported_kind" ~field_name:"kind"
        ~expected:request_kind kind
    in
    let* phase = string_field "core_phase" value in
    let* () =
      require_equal ~code:"unsupported_core_phase" ~field_name:"core_phase"
        ~expected:core_phase phase
    in
    let* target_path = string_field "target_path" value in
    let* target_module = string_field "target_module" value in
    let* core_json = field "core" value in
    let* decoded =
      match Core_pre_middle_json.decode_program core_json with
      | Ok decoded -> Ok decoded
      | Error error ->
          protocol_error "invalid_pre_middle_core"
            (Core_pre_middle_json.decode_error_to_string error)
    in
    let* next_def_id = int_field "next_def_id" value in
    let* import_binding_values = array_field "import_bindings" value in
    let* import_bindings = decode_list decode_import_binding import_binding_values in
    let* module_import_values = array_field "module_imports" value in
    let* module_imports = decode_list decode_module_imports module_import_values in
    let* debug = bool_field "debug" value in
    let* require_main = bool_field "require_main" value in
    let* check_invariants = bool_field "check_invariants" value in
    let* capability_values = array_field "required_capabilities" value in
    let* _validated_capabilities =
      decode_list decode_capability capability_values
    in
    let* observation_values = array_field "observations" value in
    let* observations = decode_list decode_stage observation_values in
    let* stop_after_json = field "stop_after" value in
    let* stop_after =
      match stop_after_json with
      | Lsp_json.Null -> Ok None
      | value ->
          let* stage = decode_stage value in
          Ok (Some stage)
    in
    Ok
      {
        target_path;
        target_module;
        core = decoded.core;
        foreign_includes = decoded.foreign_includes;
        next_def_id;
        import_bindings;
        module_imports;
        debug;
        require_main;
        check_invariants;
        observations;
        stop_after;
      }

let program_has_top_level_main program =
  List.exists
    (fun decl ->
      match decl.Core.cd_desc with
      | Core.CDFunc func -> Core.is_program_entrypoint func
      | _ -> false)
    program

let render_core program =
  match program with [] -> "<empty Core program>" | _ -> Core.pp_program_indented program

let diagnostic_of_core_error target_path (error : Core_error.t) =
  let path =
    match error.loc.Ast.loc_file with
    | Some _ as path -> path
    | None -> Some target_path
  in
  {
    code = Core_error.phase_tag_to_string error.phase;
    message = error.msg;
    path;
    line = error.loc.line;
    column = error.loc.column;
    help = error.hint;
  }

let failure_diagnostic ?path code message =
  { code; message; path; line = 0; column = 0; help = None }

let run_request_in_session request =
  if request.require_main && not (program_has_top_level_main request.core) then
    Failed
      [
        {
          code = "missing_main";
          message = "cannot compile runnable source without a main function";
          path = Some request.target_path;
          line = 1;
          column = 1;
          help =
            Some
              "Add a top-level `main` function, or use a check-only command for library source.";
        };
      ]
  else
    let observations_rev = ref [] in
    let requested stage = List.exists (( = ) stage) request.observations in
    let on_stage stage program =
      let should_observe = requested stage in
      let should_stop = request.stop_after = Some stage in
      if should_observe || should_stop then (
        let rendered = render_core program in
        if should_observe then
          observations_rev := { stage; rendered } :: !observations_rev;
        if should_stop then raise (Stopped_with_snapshot (stage, rendered)))
    in
    try
      let reg = Codegen_types.create_registry () in
      Core_registry.register_types reg request.core;
      let import_aliases, module_imports =
        Core_imports.tables_of_bindings
          ~main_import_bindings:request.import_bindings request.module_imports
      in
      let on_stage =
        Core_pipeline.make_stage_hook ~check_invariants:request.check_invariants
          ~user:on_stage
      in
      let backend_input =
        Core_pipeline.run_core_passes ~on_stage
          ~reg ~import_aliases ~module_imports ~debug:request.debug request.core
      in
      let observations = List.rev !observations_rev in
      (match
         Core_emit_blorp_c.program_json
           ~foreign_includes:request.foreign_includes ~reg
           backend_input.blorp_tail_input
       with
      | Ok core -> Compiled { core; observations }
      | Error error ->
          Failed
            [
              failure_diagnostic ~path:request.target_path "core_projection"
                (Core_emit_blorp_c.unsupported_to_string error);
            ])
    with
    | Stopped_with_snapshot (stage, rendered) ->
        Stopped
          { stage; rendered; observations = List.rev !observations_rev }
    | Core_error.Core_error error ->
        Failed [ diagnostic_of_core_error request.target_path error ]

let run_request request =
  let session = Session.create () in
  Session.with_current session (fun () ->
      Session.reset_core_counters session;
      Session.reserve_def_id_floor session request.next_def_id;
      run_request_in_session request)

let observation_json observation =
  Lsp_json.Object
    [
      ("stage", Lsp_json.String (stage_name observation.stage));
      ("rendered", Lsp_json.String observation.rendered);
    ]

let diagnostic_json diagnostic =
  Lsp_json.Object
    [
      ("code", Lsp_json.String diagnostic.code);
      ("message", Lsp_json.String diagnostic.message);
      ( "path",
        match diagnostic.path with
        | Some path -> Lsp_json.String path
        | None -> Lsp_json.Null );
      ("line", Lsp_json.Int diagnostic.line);
      ("column", Lsp_json.Int diagnostic.column);
      ( "help",
        match diagnostic.help with
        | Some help -> Lsp_json.String help
        | None -> Lsp_json.Null );
    ]

let response_json response =
  let envelope kind fields =
    Lsp_json.Object
      (("schema", Lsp_json.Int schema_version)
      :: ("domain", Lsp_json.String protocol_domain)
      :: ("kind", Lsp_json.String kind)
      :: ( "capabilities",
           Lsp_json.Array
             (List.map
                (fun capability -> Lsp_json.String (capability_name capability))
                supported_capabilities) )
      :: fields)
  in
  let observations_json observations =
    Lsp_json.Array (List.map observation_json observations)
  in
  match response with
  | Compiled { core; observations } ->
      envelope "compiled"
        [ ("core", core); ("observations", observations_json observations) ]
  | Stopped { stage; rendered; observations } ->
      envelope "stopped"
        [
          ("stage", Lsp_json.String (stage_name stage));
          ("rendered", Lsp_json.String rendered);
          ("observations", observations_json observations);
        ]
  | Failed diagnostics ->
      envelope "failed"
        [ ("diagnostics", Lsp_json.Array (List.map diagnostic_json diagnostics)) ]
