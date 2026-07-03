(** Unified compilation pipeline for blorp.

    Encapsulates the full parse → load modules → typecheck → codegen flow
    into a single function, eliminating duplication across CLI commands.

    Callers are responsible for:
    - Reading the source file
    - Calling [Modules.init_module_paths] / [Modules.reset] as needed
    - Formatting and reporting the returned errors *)

open Ast

type compile_result = {
  program : program;
  typed_program : Typed_ast.program;
  c_code : string;
  link_flags : string list;
  include_dirs : string list;
}
(** Result of a successful compilation *)

type frontend_phase = Parse | ModuleLoad | ModuleTypecheck | MainTypecheck

let frontend_phase_to_string = function
  | Parse -> "parse"
  | ModuleLoad -> "module_load"
  | ModuleTypecheck -> "module_typecheck"
  | MainTypecheck -> "main_typecheck"

let bridge_can_read_matching_source ~filename source =
  try
    Sys.file_exists filename
    && (not (Sys.is_directory filename))
    && String.equal (Modules.read_file filename) source
  with Sys_error _ -> false

(** Outcome of [compile]. See [pipeline.mli] for rationale. *)
type compile_outcome = Compiled of compile_result | Stopped_at of Core_stage.t

type source_kind = User_source | Generated_test_harness

(** Return module loading errors in chronological (load) order.
    [Modules.load_errors] stores them newest-first; reverse here so the
    pipeline surfaces them in the order they occurred. *)
let module_load_errors () = List.rev (Modules.get_load_errors ())

let target_module_name filename =
  Option.value ~default:"" (Modules.module_name_for_source_file filename)

let program_has_top_level_main (program : Ast.program) : bool =
  List.exists
    (fun decl ->
      match decl.decl_desc with
      | DFunc { func_name = Some "main"; _ } -> true
      | _ -> false)
    program

let missing_main_error ~filename =
  {
    message = "cannot run source file without a main function";
    loc = Ast.point_loc_in ~file:filename ~line:1 ~column:1;
    phase = TypeCheck;
    kind = OtherError;
    notes =
      [
        "Runnable Blorp programs need a top-level `main` entry point.";
        "Use `blorp check` for library-style files that only define helpers.";
      ];
    help =
      Some
        "Add `func main(args: List[String]) -> Int:` and return an exit code, \
         or `func main(args: List[String]):` for an implicit zero exit.";
  }

(** Parse source and load imports. Shared by [typecheck_only] and [compile]. *)
let load_modules_after_parse ?on_frontend_phase ~filename program =
  let record phase =
    match on_frontend_phase with Some f -> f phase | None -> ()
  in
  record Parse;
  let base_dir = Modules.extract_directory filename in
  let _ = Modules.load_imports program base_dir in
  record ModuleLoad;
  let mod_errors = module_load_errors () in
  if mod_errors <> [] then Error mod_errors else Ok (program, base_dir)

let load_modules_after_preloaded_graph ?on_frontend_phase ~filename ~program
    graph =
  let record phase =
    match on_frontend_phase with Some f -> f phase | None -> ()
  in
  record Parse;
  Modules.load_preloaded_module_graph ~target_path:filename graph;
  record ModuleLoad;
  let mod_errors = module_load_errors () in
  if mod_errors <> [] then Error mod_errors
  else Ok (program, Modules.extract_directory filename)

let parse_and_load_modules ?on_frontend_phase ?(source_kind = User_source)
    ~filename source =
  let record phase =
    match on_frontend_phase with Some f -> f phase | None -> ()
  in
  let bridge_read_file =
    match source_kind with
    | User_source -> bridge_can_read_matching_source ~filename source
    | Generated_test_harness -> false
  in
  match Modules.parse_typecheck_source ~filename ~bridge_read_file source with
  | Error err ->
      record Parse;
      Error [ err ]
  | Ok program ->
      load_modules_after_parse ?on_frontend_phase ~filename program

let fresh_builtins_env () = Env_builtins.with_builtins (Env.empty ())

type unused_import_check_scope =
  | Explicit_target of { module_name : string; source_kind : source_kind }
  | Loaded_dependency of Session.module_origin

let is_prelude_reexport_module = function
  | "std/prelude" | "prelude" -> true
  | _ -> false

let should_check_unused_imports = function
  | Explicit_target { source_kind = Generated_test_harness; _ } -> false
  | Explicit_target { module_name; source_kind = User_source } ->
      not (is_prelude_reexport_module module_name)
  | Loaded_dependency Session.User_module -> true
  | Loaded_dependency
      ( Session.Stdlib_module | Session.Package_module _
      | Session.Native_package_module _ ) ->
      false

let unused_import_errors ~scope program =
  if should_check_unused_imports scope then Unused_imports.errors program
  else []

type loaded_module_typecheck_result =
  | LoadedModuleTyped of {
      typed_decls : Typed_ast.program;
      import_bindings : Session.import_binding list;
    }
  | LoadedModuleErrors of Ast.compiler_error list

(** Type-check a single loaded module and format the errors the pipeline should
    surface. Shared by full compilation and analysis-only entry points so tools
    like [purify] do not silently proceed with an invalid dependency graph. *)
let typecheck_loaded_module ?(debug = false) ?(allow_debug_only_calls = false)
    (m : Modules.loaded_module) =
  let state, typed_decls, errors =
    match
      Typecheck.typecheck_module_with_state_typed ~module_origin:m.origin
        ~allow_debug_only_calls ~module_name:m.name (fresh_builtins_env ())
        m.decls
    with
    | Ok (state, typed_decls) -> (state, Some typed_decls, [])
    | Error (state, errors) -> (state, None, errors)
  in
  if debug && errors <> [] then begin
    Printf.eprintf "[module-typecheck] %s: %d error(s)\n%!" m.name
      (List.length errors);
    List.iter
      (fun (e : Ast.compiler_error) ->
        Printf.eprintf "  - [L%d] %s\n%!" e.loc.line e.message)
      errors
  end;
  (* Module typechecking is authoritative. Do not suppress errors here based on
     transitive export tables: a name exported by an imported module is not
     necessarily visible as a bare identifier, especially for qualified imports.
     If Typecheck reports an error, the module must not reach Core lowering. *)
  let formatted_errors =
    if errors = [] then []
    else begin
      (* Deduplicate by identifier name — report one error per undefined name *)
      let seen = Hashtbl.create 4 in
      let deduped =
        List.filter
          (fun (e : Ast.compiler_error) ->
            if Hashtbl.mem seen e.message then false
            else (
              Hashtbl.replace seen e.message ();
              true))
          errors
      in
      let mod_base = Filename.basename m.name in
      let mod_file =
        if String.length m.path > 0 && m.path.[0] <> '<' then m.path
        else mod_base ^ ".brp"
      in
      List.map
        (fun (e : Ast.compiler_error) ->
          (* Generate context-appropriate help based on error kind *)
          let help =
            match e.kind with
            | Ast.UndefinedIdent name -> (
                let source_module =
                  List.find_map
                    (fun (other : Modules.loaded_module) ->
                      if
                        List.exists
                          (fun (n, _) -> n = name)
                          other.Modules.exports
                      then Some (Filename.basename other.Modules.name)
                      else None)
                    (Modules.get_all_modules ())
                in
                match source_module with
                | Some src ->
                    Printf.sprintf "Add to imports in '%s': import: %s: %s"
                      mod_base src name
                | None -> Printf.sprintf "Check imports in '%s'" mod_base)
            | Ast.NotExported (name, _mod) -> (
                let source =
                  List.find_map
                    (fun (other : Modules.loaded_module) ->
                      if
                        List.exists
                          (fun (n, _) -> n = name)
                          other.Modules.exports
                      then Some (Filename.basename other.Modules.name)
                      else None)
                    (Modules.get_all_modules ())
                in
                match source with
                | Some src ->
                    Printf.sprintf
                      "'%s' is not in this module. Try: import: %s: %s" name src
                      name
                | None -> Printf.sprintf "Check imports in '%s'" mod_base)
            | _ -> Printf.sprintf "Check imports in '%s'" mod_base
          in
          {
            e with
            message =
              Printf.sprintf "%s\n   --> %s:%d" e.message mod_file e.loc.line;
            notes = [];
            help = Some help;
          })
        deduped
    end
  in
  let import_errors =
    if formatted_errors = [] then
      unused_import_errors ~scope:(Loaded_dependency m.origin) m.decls
    else []
  in
  let import_bindings = List.rev state.Typecheck.import_bindings in
  match (typed_decls, formatted_errors, import_errors) with
  | Some typed_decls, [], [] ->
      LoadedModuleTyped { typed_decls; import_bindings }
  | None, _ :: _, _ | Some _, _ :: _, _ -> LoadedModuleErrors formatted_errors
  | Some _, [], _ :: _ -> LoadedModuleErrors import_errors
  | None, [], _ ->
      LoadedModuleErrors
        [
          {
            message =
              "internal typecheck error: module typecheck reported success but \
               did not produce a typed AST";
            loc = Ast.dummy_loc;
            phase = TypeCheck;
            kind = OtherError;
            notes = [];
            help =
              Some
                "This is a compiler bug: loaded modules must only enter the \
                 typed cache after typed-AST validation succeeds.";
          };
        ]

(** Ensure all loaded modules have typed ASTs (type-check if not cached). *)
let ensure_modules_typed ?(debug = false) ?(allow_debug_only_calls = false) () =
  let module_errors = ref [] in
  let attempted = Hashtbl.create 16 in
  let rec loop () =
    let pending =
      List.filter
        (fun (m : Modules.loaded_module) ->
          Modules.get_typed_decls m.name = None
          && not (Hashtbl.mem attempted m.name))
        (Modules.get_all_modules ())
    in
    match pending with
    | [] -> ()
    | _ ->
        List.iter
          (fun (m : Modules.loaded_module) ->
            Hashtbl.replace attempted m.name ();
            match typecheck_loaded_module ~debug ~allow_debug_only_calls m with
            | LoadedModuleTyped { typed_decls; import_bindings } ->
                Modules.set_typed_decls m.name typed_decls;
                Modules.set_typed_import_bindings m.name import_bindings
            | LoadedModuleErrors errors ->
                module_errors := errors @ !module_errors)
          pending;
        loop ()
  in
  loop ();
  List.rev !module_errors

(* Two source-level impls from different modules overlap iff they'd emit
   the same C symbol. [Typecheck.try_add_source_impl] catches overlaps
   within a single compilation unit, but each [check_modules] iteration
   runs with a fresh env — so two unrelated modules could each declare
   [implements Equatable for Int] without either seeing the other.
   Do a final pairwise pass on everything collected here. *)
let check_cross_module_coherence (env : Env.env)
    (collected : (string * Env.impl_instance) list) : Ast.compiler_error list =
  let errs = ref [] in
  let rec pairs = function
    | [] | [ _ ] -> ()
    | (mod_a, a) :: rest ->
        List.iter
          (fun (mod_b, b) ->
            if mod_a <> mod_b && Typecheck.impls_overlap a b then
              errs :=
                Typecheck.build_conflict_error env
                  (match a.ii_loc with Some l -> l | None -> Ast.dummy_loc)
                  ~candidate:a ~existing:b
                :: !errs)
          rest;
        pairs rest
  in
  pairs collected;
  List.rev !errs

(** Type-check all loaded modules and return their errors. Historically this
    discarded purity/type-mismatch errors as "likely false positives from
    the incomplete builtins-only env", but the 28 hidden errors identified
    in 2026-04-15 instrumentation were all genuine bugs (fixed in the same
    batch: missing [T]/[#N] type params on tensor signatures, bare
    constructor imports, [encode_frame] purity miscoding). The filter now
    surfaces all errors from module bodies.

    Also runs a final pairwise coherence pass across source-level impls
    from every typechecked module so overlaps that span modules (two
    unrelated modules both declaring [implements X for T]) are rejected
    here rather than leaking to the C linker. *)
let check_modules ?(debug = false) ?(allow_debug_only_calls = false) () =
  let module_errors = ref [] in
  let all_source_impls = ref [] in
  let attempted = Hashtbl.create 16 in
  let collect_impl m local_type_names d =
    match d.Ast.decl_desc with
    | Ast.DImpl impl ->
        let impl =
          {
            impl with
            impl_for_type =
              Types.qualify_module_local_types ~module_path:m.Modules.name
                local_type_names impl.impl_for_type;
          }
        in
        Some (Typecheck.make_impl_instance ~loc:d.decl_loc impl)
    | _ -> None
  in
  List.iter
    (fun (m : Modules.loaded_module) ->
      match Modules.get_typed_decls m.name with
      | Some _ ->
          if debug then Printf.eprintf "[check_modules] %s: CACHED\n%!" m.name
      | None -> ())
    (Modules.get_all_modules ());
  let rec loop () =
    let pending =
      List.filter
        (fun (m : Modules.loaded_module) ->
          Modules.get_typed_decls m.name = None
          && not (Hashtbl.mem attempted m.name))
        (Modules.get_all_modules ())
    in
    match pending with
    | [] -> ()
    | _ ->
        List.iter
          (fun (m : Modules.loaded_module) ->
            Hashtbl.replace attempted m.name ();
            if debug then
              Printf.eprintf "[check_modules] %s: checking...\n%!" m.name;
            let module_result =
              typecheck_loaded_module ~debug ~allow_debug_only_calls m
            in
            (* Collect the impls this module directly declares — NOT those
             inherited via [register_module_impls] for imports. Walking
             [state.env.impls] would double-count: an impl imported by both
             module A and module B would appear in both states and match
             itself as a spurious cross-module conflict. Private impls are
             intentionally skipped: they're module-local and never collide
             across modules at link time because the C symbols aren't
             exported. *)
            let local_type_names =
              Module_type_identity.local_type_names_from_decls m.decls
            in
            List.iter
              (fun d ->
                match collect_impl m local_type_names d with
                | Some ii ->
                    all_source_impls := (m.name, ii) :: !all_source_impls
                | None -> ())
              m.decls;
            match module_result with
            | LoadedModuleTyped { typed_decls; import_bindings } ->
                Modules.set_typed_decls m.name typed_decls;
                Modules.set_typed_import_bindings m.name import_bindings
            | LoadedModuleErrors errors ->
                module_errors := errors @ !module_errors)
          pending;
        loop ()
  in
  loop ();
  (* Cross-module coherence pass. Runs after all modules typechecked so
     we see every source-level impl at once. Uses a builtins-only env
     for trait-name qualification ([Env.format_trait_name] in
     [describe_impl]) — stdlib traits are present there, which covers
     the common case of two modules conflicting on e.g. [Equatable for
     Int]. *)
  let env_for_diag = fresh_builtins_env () in
  let cross_module_errs =
    check_cross_module_coherence env_for_diag !all_source_impls
  in
  List.rev (List.rev_append cross_module_errs !module_errors)

(** Phase 2.1: each top-level [Pipeline] entry point runs in its own
    [Session.t] so two compiles in a single process can't leak state
    (module_cache, prelude_modules_loaded, load_errors, search_paths,
    fresh-name counters) into each other. The CLI's pre-call
    [init_module_paths] writes to the long-lived process-default
    session and is harmless (the new session re-inits its own paths). *)
let with_fresh_session ?configure_session (filename : string) (k : unit -> 'a) :
    'a =
  let parent = Session.current () in
  let sess = Session.create () in
  (match (parent.Session.std_override_active, parent.std_override_dir) with
  | true, Some dir -> Modules.set_std_override ~sess dir
  | _ -> ());
  Session.with_current sess (fun () ->
      Modules.init_module_paths (Modules.extract_directory filename);
      Option.iter (fun configure -> configure sess) configure_session;
      k ())

let typecheck_loaded_program ~source_kind ~filename ~program ?(debug = false) ()
    =
  (* Type-check loaded modules and surface genuine errors *)
  let module_errors = check_modules ~debug ~allow_debug_only_calls:debug () in
  if module_errors <> [] then Error module_errors
  else
    let module_origin = Modules.module_origin_for_source_file filename in
    let module_name = target_module_name filename in
    match
      Typecheck.typecheck_typed ~module_origin ~module_name
        ~allow_debug_only_calls:debug program
    with
    | Error errors -> Error errors
    | Ok typed_program ->
        let import_errors =
          unused_import_errors
            ~scope:(Explicit_target { module_name; source_kind })
            program
        in
        if import_errors <> [] then Error import_errors else Ok typed_program

let typecheck_only_typed_impl ~source_kind ~filename ~source ?(debug = false) ()
    =
  with_fresh_session filename (fun () ->
      match parse_and_load_modules ~source_kind ~filename source with
      | Error _ as e -> e
      | Ok (program, _base_dir) ->
          typecheck_loaded_program ~source_kind ~filename ~program ~debug ())

let preload_cli_parsed_sources = function
  | [] -> ()
  | sources -> Modules.preload_parsed_sources sources

let typecheck_only_typed_parsed ~filename ~program
    ?(preloaded_parsed_sources = []) ?preloaded_module_graph ?(debug = false)
    () =
  with_fresh_session filename (fun () ->
      let loaded =
        match preloaded_module_graph with
        | Some graph ->
            load_modules_after_preloaded_graph ~filename ~program graph
        | None ->
            preload_cli_parsed_sources preloaded_parsed_sources;
            load_modules_after_parse ~filename program
      in
      match loaded with
      | Error _ as e -> e
      | Ok (program, _base_dir) ->
          typecheck_loaded_program ~source_kind:User_source ~filename ~program
            ~debug ())

let typecheck_only_typed ~filename ~source ?(debug = false) () =
  typecheck_only_typed_impl ~source_kind:User_source ~filename ~source ~debug ()

let typecheck_only ~filename ~source ?(debug = false) () =
  match typecheck_only_typed ~filename ~source ~debug () with
  | Ok typed_program -> Ok (Typed_ast.program_ast typed_program)
  | Error _ as e -> e

let typecheck_only_parsed ~filename ~program ?preloaded_parsed_sources
    ?preloaded_module_graph ?(debug = false) () =
  match
    typecheck_only_typed_parsed ~filename ~program
      ?preloaded_parsed_sources ?preloaded_module_graph ~debug ()
  with
  | Ok typed_program -> Ok (Typed_ast.program_ast typed_program)
  | Error _ as e -> e

(** Parse and type-check a module, returning the final state and typed program. *)
let typecheck_module_only_typed_impl ?configure_session ~filename ~source () =
  with_fresh_session ?configure_session filename (fun () ->
      match parse_and_load_modules ~filename source with
      | Error _ as e -> e
      | Ok (program, _base_dir) -> (
          (* Load dependencies but only type-check the target module *)
          let module_errors = ensure_modules_typed () in
          if module_errors <> [] then Error module_errors
          else
            let env = fresh_builtins_env () in
            let module_origin =
              Modules.module_origin_for_source_file filename
            in
            let module_name = target_module_name filename in
            match
              Typecheck.typecheck_module_with_state_typed ~module_origin
                ~module_name env program
            with
            | Error (_state, errors) -> Error errors
            | Ok (state, typed_program) ->
                let import_errors =
                  unused_import_errors
                    ~scope:
                      (Explicit_target
                         { module_name; source_kind = User_source })
                    program
                in
                if import_errors <> [] then Error import_errors
                else Ok (state, typed_program)))

let typecheck_module_only_typed ~filename ~source =
  typecheck_module_only_typed_impl ~filename ~source ()

let typecheck_source_package_module_only_typed ~source_package ~filename ~source
    =
  let configure_session sess =
    Modules.add_source_package ~sess source_package
  in
  typecheck_module_only_typed_impl ~configure_session ~filename ~source ()

let typecheck_module_only ~filename ~source =
  match typecheck_module_only_typed ~filename ~source with
  | Ok (state, typed_program) -> Ok (state, Typed_ast.program_ast typed_program)
  | Error _ as e -> e

let compile_loaded_program ~source_kind ?(debug = false)
    ?allow_debug_only_calls ?retain_debug_blocks ?(embed_runtime = true)
    ?(require_main = false) ?(profile = false) ?on_frontend_phase ?on_stage
    ?on_stage_event ?on_stage_json ?tail_observation_stages
    ?(check_invariants = false) ~filename ~program () =
  let allow_debug_only_calls =
    Option.value allow_debug_only_calls ~default:debug
  in
  let retain_debug_blocks = Option.value retain_debug_blocks ~default:debug in
  let record_frontend phase =
    match on_frontend_phase with Some f -> f phase | None -> ()
  in
  (* Type-check all loaded modules and surface genuine errors *)
  let module_errors = check_modules ~debug ~allow_debug_only_calls () in
  record_frontend ModuleTypecheck;
  if module_errors <> [] then Error module_errors
  else
    let module_origin = Modules.module_origin_for_source_file filename in
    let module_name = target_module_name filename in
    match
      Typecheck.typecheck_with_state_typed ~module_origin
        ~allow_debug_only_calls ~module_name program
    with
    | Error blocking_errors ->
        record_frontend MainTypecheck;
        Error blocking_errors
    | Ok (main_state, typed_program) -> (
        record_frontend MainTypecheck;
        let import_errors =
          unused_import_errors
            ~scope:(Explicit_target { module_name; source_kind })
            program
        in
        if import_errors <> [] then Error import_errors
        else if require_main && not (program_has_top_level_main program) then
          Error [ missing_main_error ~filename ]
        else
          try
            let c_code, link_flags, include_dirs =
              Core_pipeline.compile_typed_with_modules
                ~main_import_bindings:
                  (List.rev main_state.Typecheck.import_bindings)
                ~embed_runtime ~profile ~debug:retain_debug_blocks ?on_stage
                ?on_stage_event ?on_stage_json ?tail_observation_stages
                ~check_invariants typed_program
            in
            Ok
              (Compiled
                 { program; typed_program; c_code; link_flags; include_dirs })
          with
          (* [Core_pipeline.Stopped_after] is raised by a caller-supplied
             [on_stage] callback to request early termination from
             [--stop-after=<stage>]. Convert to a tagged outcome so callers
             pattern-match instead of handling an out-of-band exception. *)
          | Core_pipeline.Stopped_after s -> Ok (Stopped_at s)
          | Core_error.Core_error { phase; msg; loc; hint } ->
              let hint_str =
                match hint with Some h -> " (hint: " ^ h ^ ")" | None -> ""
              in
              let tag = Core_error.phase_tag_to_string phase in
              Error
                [
                  {
                    message = Printf.sprintf "[%s] %s%s" tag msg hint_str;
                    loc;
                    phase = Codegen;
                    kind = OtherError;
                    notes = [];
                    help = None;
                  };
                ]
          | Failure msg ->
              Error
                [
                  {
                    message = "(internal error) " ^ msg;
                    loc = Ast.dummy_loc;
                    phase = Codegen;
                    kind = OtherError;
                    notes = [];
                    help = None;
                  };
                ])

(** Compile a source file through all phases.
    Returns either the compiled result or a list of errors.

    [embed_runtime] — when [true] (the default), the generated C embeds
    the full runtime. When [false], the caller is expected to link a
    precompiled runtime object. *)
let compile_impl ~source_kind ?(debug = false) ?allow_debug_only_calls
    ?retain_debug_blocks ?(embed_runtime = true) ?(require_main = false)
    ?(profile = false) ?on_frontend_phase ?on_stage ?on_stage_event
    ?on_stage_json ?tail_observation_stages ?(check_invariants = false)
    ~filename ~source () =
  with_fresh_session filename (fun () ->
      match parse_and_load_modules ?on_frontend_phase ~source_kind ~filename source with
      | Error _ as e -> e
      | Ok (program, _base_dir) ->
          compile_loaded_program ~source_kind ~debug ?allow_debug_only_calls
            ?retain_debug_blocks ~embed_runtime ~require_main ~profile
            ?on_frontend_phase ?on_stage ?on_stage_event ?on_stage_json
            ?tail_observation_stages ~check_invariants ~filename ~program ())

let compile_parsed ?debug ?allow_debug_only_calls ?retain_debug_blocks
    ?embed_runtime ?require_main ?profile ?on_frontend_phase ?on_stage
    ?on_stage_event ?on_stage_json ?tail_observation_stages
    ?check_invariants ~filename ~program ?(preloaded_parsed_sources = [])
    ?preloaded_module_graph () =
  with_fresh_session filename (fun () ->
      let loaded =
        match preloaded_module_graph with
        | Some graph ->
            load_modules_after_preloaded_graph ?on_frontend_phase ~filename
              ~program graph
        | None ->
            preload_cli_parsed_sources preloaded_parsed_sources;
            load_modules_after_parse ?on_frontend_phase ~filename program
      in
      match loaded with
      | Error _ as e -> e
      | Ok (program, _base_dir) ->
          compile_loaded_program ~source_kind:User_source ?debug
            ?allow_debug_only_calls ?retain_debug_blocks ?embed_runtime
            ?require_main ?profile ?on_frontend_phase ?on_stage ?on_stage_event
            ?on_stage_json ?tail_observation_stages ?check_invariants ~filename
            ~program ())

let compile ?debug ?allow_debug_only_calls ?retain_debug_blocks ?embed_runtime
    ?require_main ?profile ?on_frontend_phase ?on_stage ?on_stage_event
    ?on_stage_json ?tail_observation_stages ?check_invariants ~filename ~source
    () =
  compile_impl ~source_kind:User_source ?debug ?allow_debug_only_calls
    ?retain_debug_blocks ?embed_runtime ?require_main ?profile
    ?on_frontend_phase ?on_stage ?on_stage_event ?on_stage_json
    ?tail_observation_stages ?check_invariants ~filename ~source ()

let compile_generated_test_harness ?debug ?allow_debug_only_calls
    ?retain_debug_blocks ?embed_runtime ~filename ~source () =
  compile_impl ~source_kind:Generated_test_harness ?debug
    ?allow_debug_only_calls ?retain_debug_blocks ?embed_runtime ~filename
    ~source ()
