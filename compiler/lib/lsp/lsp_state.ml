(** LSP document state management and analysis pipeline.

    Tracks open documents, runs the compiler pipeline on changes,
    and publishes diagnostics. Position lookup and hover info
    are in Lsp_position and Lsp_hover respectively. *)

open Ast
open Lsp_json

(* ============================================================================
   Document state
   ============================================================================ *)

type document = {
  uri : string;
  version : int;
  text : string;
  session : Session.t;
  mutable diagnostics : compiler_error list;
  mutable parse_errors : string list;
  mutable source_program : program option;
  mutable program : program option;
  mutable typed_program : Typed_ast.program option;
  mutable env : Env.env option;
  mutable module_aliases : (string * string) list;
}

type client_capabilities = {
  definition_link_support : bool;
  declaration_link_support : bool;
  type_definition_link_support : bool;
}

let default_client_capabilities =
  {
    definition_link_support = false;
    declaration_link_support = false;
    type_definition_link_support = false;
  }

type state = {
  documents : (string, document) Hashtbl.t;
  mutable initialized : bool;
  mutable client_capabilities : client_capabilities;
}

let create () : state =
  {
    documents = Hashtbl.create 16;
    initialized = false;
    client_capabilities = default_client_capabilities;
  }

let create_document ?session ~uri ~version ~text () : document =
  {
    uri;
    version;
    text;
    session = Option.value session ~default:(Session.create ());
    diagnostics = [];
    parse_errors = [];
    source_program = None;
    program = None;
    typed_program = None;
    env = None;
    module_aliases = [];
  }

let with_document_session doc f = Session.with_current doc.session f

let get_nested path json =
  List.fold_left
    (fun current key ->
      match current with Some json -> get key json | None -> None)
    (Some json) path

let link_support_capability method_name params =
  match
    get_nested
      [ "capabilities"; "textDocument"; method_name; "linkSupport" ]
      params
  with
  | Some (Bool true) -> true
  | _ -> false

let client_capabilities_of_initialize_params params =
  {
    definition_link_support = link_support_capability "definition" params;
    declaration_link_support = link_support_capability "declaration" params;
    type_definition_link_support =
      link_support_capability "typeDefinition" params;
  }

let find_document state uri = Hashtbl.find_opt state.documents uri

let clear_analysis_state doc =
  doc.parse_errors <- [];
  doc.source_program <- None;
  doc.program <- None;
  doc.typed_program <- None;
  doc.env <- None;
  doc.module_aliases <- []

let module_aliases_of_program (program : program) =
  (* Qualified imports always expose a module name/alias. Selective imports
     expose a qualifier only when the import has an explicit alias, as in
     `option as O: Option`. *)
  List.filter_map
    (fun (d : decl) ->
      match d.decl_desc with
      | DImport { import_module; import_symbols; import_alias; _ } -> (
          match (import_alias, import_symbols) with
          | Some alias, _ -> Some (alias, import_module)
          | None, None -> Some (Filename.basename import_module, import_module)
          | None, Some _ -> None)
      | _ -> None)
    program

(* ============================================================================
   Analysis pipeline — reuses the existing compiler pipeline
   ============================================================================ *)

let init_module_paths = Modules.init_module_paths

let target_module_name path =
  Option.value ~default:"" (Modules.std_module_name_for_source_file path)

let timed f =
  let start = Unix.gettimeofday () in
  let result = f () in
  (result, (Unix.gettimeofday () -. start) *. 1000.0)

let slow_analysis_log_threshold_ms = 100.0

let lsp_profile_enabled () =
  match Sys.getenv_opt "BLORP_LSP_PROFILE" with
  | Some ("1" | "true" | "TRUE" | "yes" | "YES") -> true
  | _ -> false

let log_analysis_timing ~path ~reset_ms ~parse_ms ~load_ms ~module_check_ms
    ~typecheck_ms ~prune_ms ~total_ms =
  if total_ms >= slow_analysis_log_threshold_ms || lsp_profile_enabled () then
    Printf.eprintf
      "[blorp-lsp] analyze path=%s reset=%.1fms parse=%.1fms load=%.1fms \
       module_check=%.1fms typecheck=%.1fms prune=%.1fms total=%.1fms\n\
       %!"
      path reset_ms parse_ms load_ms module_check_ms typecheck_ms prune_ms
      total_ms

(** Run the full analysis pipeline on a document.
    Collects parse errors, type errors, and module errors. *)
let analyze (_state : state) (doc : document) : unit =
  with_document_session doc (fun () ->
      let total_start = Unix.gettimeofday () in
      let reset_ms = ref 0.0 in
      let parse_ms = ref 0.0 in
      let load_ms = ref 0.0 in
      let module_check_ms = ref 0.0 in
      let typecheck_ms = ref 0.0 in
      let prune_ms = ref 0.0 in
      let path = Lsp_protocol.uri_to_path doc.uri in
      let base_dir = Filename.dirname path in
      let base_dir = if base_dir = "" then "." else base_dir in

      (* Reset the active graph, but keep source-stamped parsed modules. Each
         filesystem cache hit validates the current source hash before reuse. *)
      let (), elapsed =
        timed (fun () -> Modules.reset ())
      in
      reset_ms := elapsed;

      (* Phase 1: Parse *)
      let parse_result, elapsed =
        timed (fun () ->
            match
              Modules.parse_raw_source_artifact ~filename:path doc.text
            with
            | Ok artifact -> Ok artifact
            | Error err -> Error [ err ])
      in
      parse_ms := elapsed;

      (match parse_result with
      | Error errs ->
          clear_analysis_state doc;
          doc.diagnostics <- errs;
          doc.parse_errors <- List.map (fun e -> e.message) errs;
          let (), elapsed =
            timed (fun () -> Modules.prune_parse_cache_to_loaded_modules ())
          in
          prune_ms := elapsed
      | Ok artifact ->
          let program = artifact.Modules.source_artifact_program in
          let surface = artifact.Modules.source_artifact_surface in
          doc.parse_errors <- [];
          doc.source_program <- Some program;
          doc.program <- Some program;
          doc.typed_program <- None;
          doc.module_aliases <- [];

          (* Phase 2: Load modules *)
          init_module_paths base_dir;
          let module_origin = Modules.module_origin_for_source_file path in
          let module_name = target_module_name path in
          let _modules, elapsed =
            timed (fun () -> Modules.load_imports ?surface program base_dir)
          in
          load_ms := elapsed;
          let module_errors = List.rev (Modules.get_load_errors ()) in
          let module_type_errors, elapsed =
            timed (fun () ->
                if module_errors = [] then Pipeline.check_modules () else [])
          in
          module_check_ms := elapsed;

          (* Phase 3: Type check. Keep the parsed AST only on error; successful
             analysis stores the validated typed compatibility view for hover and
             definition lookup. *)
          let (type_errors, env), elapsed =
            timed (fun () ->
                if module_errors <> [] || module_type_errors <> [] then
                  ([], None)
                else
                  match
                    Typecheck.typecheck_with_env_typed ~module_origin
                      ~module_name program
                  with
                  | Ok (typed_program, env) ->
                      doc.typed_program <- Some typed_program;
                      doc.program <- Some (Typed_ast.program_ast typed_program);
                      ([], Some env)
                  | Error (errors, env) ->
                      doc.typed_program <- None;
                      (errors, Some env))
          in
          typecheck_ms := elapsed;
          doc.env <- env;
          doc.diagnostics <- module_errors @ module_type_errors @ type_errors;
          doc.module_aliases <- module_aliases_of_program program;
          let (), elapsed =
            timed (fun () -> Modules.prune_parse_cache_to_loaded_modules ())
          in
          prune_ms := elapsed);
      let total_ms = (Unix.gettimeofday () -. total_start) *. 1000.0 in
      log_analysis_timing ~path ~reset_ms:!reset_ms ~parse_ms:!parse_ms
        ~load_ms:!load_ms ~module_check_ms:!module_check_ms
        ~typecheck_ms:!typecheck_ms ~prune_ms:!prune_ms ~total_ms)

(* ============================================================================
   Diagnostics publishing
   ============================================================================ *)

(** Build the diagnostics JSON for a document *)
let get_diagnostics_json doc : json =
  let diags =
    List.map Lsp_protocol.compiler_error_to_diagnostic doc.diagnostics
  in
  Lsp_protocol.publish_diagnostics ~uri:doc.uri ~diagnostics:diags
