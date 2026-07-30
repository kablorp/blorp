(** Private post-tuple-SROA Core to pre-DCE Core worker.

    This is the one temporary OCaml boundary between the Blorp-owned frontend
    and backend. The protocol is phase-specific: callers supply Blorp-owned
    post-tuple-SROA Core, and successful requests return the Core program
    immediately before Blorp-owned DCE. This module does not read source files,
    interpret CLI arguments, emit C, write artifacts, or execute child
    processes. *)

let schema_version = 13
let protocol_domain = "compiler_semantic_middle"
let request_kind = "compile_pre_dce"
let core_phase = "post_tuple_sroa"

type capability =
  | PostTupleSroaCore
  | PreDceCore

type protocol_error = { code : string; message : string }

type request = {
  target_path : string;
  target_module : string;
  core : Core.core_program;
  foreign_includes : string list;
  union_payload_storage : (string * Codegen_types.union_payload_storage) list;
  next_def_id : int;
  require_main : bool;
  check_invariants : bool;
}

type diagnostic = {
  code : string;
  message : string;
  path : string option;
  line : int;
  column : int;
  help : string option;
}

type response =
  | Compiled of { core : Lsp_json.json }
  | Failed of diagnostic list

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

let rec decode_list decode = function
  | [] -> Ok []
  | item :: rest ->
      let* item = decode item in
      let* rest = decode_list decode rest in
      Ok (item :: rest)

let capability_name = function
  | PostTupleSroaCore -> "core_post_tuple_sroa"
  | PreDceCore -> "core_pre_dce"

let supported_capabilities = [ PostTupleSroaCore; PreDceCore ]

let decode_capability = function
  | Lsp_json.String "core_post_tuple_sroa" -> Ok PostTupleSroaCore
  | Lsp_json.String "core_pre_dce" -> Ok PreDceCore
  | Lsp_json.String name ->
      protocol_error "unsupported_capability"
        ("unsupported semantic-middle capability `" ^ name ^ "`")
  | _ ->
      protocol_error "invalid_field"
        "field `required_capabilities` must contain strings"

let require_supported_capabilities capabilities =
  match
    List.find_opt
      (fun required -> not (List.mem required capabilities))
      supported_capabilities
  with
  | Some missing ->
      protocol_error "missing_capability"
        ("missing required semantic-middle capability `"
        ^ capability_name missing ^ "`")
  | None -> Ok ()

let variant_matches ~name ~tag ~payload_type_parameter
    (variant : Ast.variant) =
  let payload_matches =
    match (variant.variant_fields, payload_type_parameter) with
    | [ Ast.TyVar actual ], Some expected -> String.equal actual expected
    | [], None -> true
    | _ -> false
  in
  String.equal variant.variant_name name
  && variant.variant_tag = tag
  && payload_matches

let is_runtime_abi_union union_payload_storage (type_decl : Ast.type_decl) =
  let has_erased_payload =
    List.assoc_opt type_decl.type_name union_payload_storage
    = Some Codegen_types.ErasedUnionPayloadStorage
  in
  if type_decl.type_is_enum || not has_erased_payload then false
  else
    match
      ( type_decl.type_name,
        Ast.type_param_names type_decl.type_params,
        type_decl.type_variants )
    with
    | "Option", [ "T" ], [ some_variant; none_variant ] ->
        variant_matches ~name:"Some" ~tag:0
          ~payload_type_parameter:(Some "T") some_variant
        && variant_matches ~name:"None" ~tag:1 ~payload_type_parameter:None
             none_variant
    | "Result", [ "T"; "E" ], [ ok_variant; error_variant ] ->
        variant_matches ~name:"Ok" ~tag:0 ~payload_type_parameter:(Some "T")
          ok_variant
        && variant_matches ~name:"Err" ~tag:1
             ~payload_type_parameter:(Some "E") error_variant
    | _ -> false

let impl_is_generic (impl : Core.core_impl) =
  Codegen_types.has_type_vars impl.ci_for_type
  || List.exists
       (fun (method_func : Core.core_func) -> method_func.cf_type_params <> [])
       impl.ci_methods

let rec unprojected_generic_decl union_payload_storage (decl : Core.core_decl) =
  match decl.cd_desc with
  | Core.CDFunc func when func.cf_type_params <> [] ->
      Some ("generic function `" ^ func.cf_name ^ "`")
  | Core.CDType type_decl
    when type_decl.type_params <> []
         && not (is_runtime_abi_union union_payload_storage type_decl) ->
      Some ("generic type `" ^ type_decl.type_name ^ "`")
  | Core.CDRecord record_decl when record_decl.record_type_params <> [] ->
      Some ("generic record `" ^ record_decl.record_name ^ "`")
  | Core.CDImpl impl when impl_is_generic impl ->
      Some ("generic impl `" ^ impl.ci_trait ^ "`")
  | Core.CDPrivate inner -> unprojected_generic_decl union_payload_storage inner
  | _ -> None

let rec first_unprojected_generic_decl union_payload_storage = function
  | [] -> None
  | decl :: rest -> (
      match unprojected_generic_decl union_payload_storage decl with
      | Some _ as violation -> violation
      | None -> first_unprojected_generic_decl union_payload_storage rest)

let validate_runtime_projection union_payload_storage program =
  match first_unprojected_generic_decl union_payload_storage program with
  | Some declaration ->
      protocol_error "invalid_post_tuple_sroa_core"
        ("Blorp semantic-middle projection retained " ^ declaration)
  | None -> Ok ()

let post_tuple_sroa_invariant_message target_path (violation : Core_error.t) =
  let loc = violation.loc in
  let path = Option.value loc.loc_file ~default:target_path in
  let location =
    if loc.line <= 0 then path
    else Printf.sprintf "%s:%d:%d" path loc.line loc.column
  in
  let hint =
    Option.fold ~none:"" ~some:(fun value -> " (" ^ value ^ ")") violation.hint
  in
  Printf.sprintf "post-tuple-SROA Core invariant failed at %s: %s%s" location
    violation.msg hint

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
      match Core_post_tuple_sroa_json.decode_program core_json with
      | Ok decoded -> Ok decoded
      | Error error ->
          protocol_error "invalid_post_tuple_sroa_core"
            (Core_post_tuple_sroa_json.decode_error_to_string error)
    in
    let* () =
      validate_runtime_projection decoded.union_payload_storage decoded.core
    in
    let* next_def_id = int_field "next_def_id" value in
    let* require_main = bool_field "require_main" value in
    let* check_invariants = bool_field "check_invariants" value in
    let* capability_values = array_field "required_capabilities" value in
    let* validated_capabilities =
      decode_list decode_capability capability_values
    in
    let* () = require_supported_capabilities validated_capabilities in
    (* A post-tuple-SROA handoff must satisfy every durable contract established by
       the earlier Blorp-owned stages, not only the Match-specific contract.
       Synth rechecks debug, desugar, and monomorphization invariants while
       intentionally allowing mutable locals introduced by synthesis. *)
    let post_tuple_sroa_violations =
      Core_invariants.run_for_stage Core_stage.Synth decoded.core
      @ Core_invariants.run_for_stage Core_stage.Match decoded.core
    in
    (match post_tuple_sroa_violations with
    | violation :: _ ->
        protocol_error "invalid_post_tuple_sroa_core"
          (post_tuple_sroa_invariant_message target_path violation)
    | [] ->
        Ok
          {
            target_path;
            target_module;
            core = decoded.core;
            foreign_includes = decoded.foreign_includes;
            union_payload_storage = decoded.union_payload_storage;
            next_def_id;
            require_main;
            check_invariants;
          })

let program_has_top_level_main program =
  List.exists
    (fun decl ->
      match decl.Core.cd_desc with
      | Core.CDFunc func -> Core.is_program_entrypoint func
      | _ -> false)
    program

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
    try
      let reg = Codegen_types.create_registry () in
      Core_registry.register_types
        ~union_payload_storage_overrides:request.union_payload_storage reg
        request.core;
      let on_stage =
        Core_pipeline.make_stage_hook ~check_invariants:request.check_invariants
          ~user:(fun _ _ -> ())
      in
      let backend_input =
        Core_pipeline.run_core_passes_from_post_tuple_sroa ~on_stage ~reg
          request.core
      in
      (match
         Core_emit_blorp_c.program_json
           ~foreign_includes:request.foreign_includes ~reg
           backend_input.blorp_tail_input
       with
      | Ok core -> Compiled { core }
      | Error error ->
          Failed
            [
              failure_diagnostic ~path:request.target_path "core_projection"
                (Core_emit_blorp_c.unsupported_to_string error);
            ])
    with
    | Core_error.Core_error error ->
        Failed [ diagnostic_of_core_error request.target_path error ]

let run_request request =
  let session = Session.create () in
  Session.with_current session (fun () ->
      Session.reserve_def_id_floor session request.next_def_id;
      run_request_in_session request)

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
  match response with
  | Compiled { core } -> envelope "compiled" [ ("core", core) ]
  | Failed diagnostics ->
      envelope "failed"
        [ ("diagnostics", Lsp_json.Array (List.map diagnostic_json diagnostics)) ]
