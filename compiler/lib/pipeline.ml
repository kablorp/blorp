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

let bridge_module_origin_of_session_origin = function
  | Session.User_module -> Compiler_blorp_bridge.CliFrontendUserModule
  | Session.Stdlib_module -> Compiler_blorp_bridge.CliFrontendStdModule
  | Session.Native_package_module package ->
      Compiler_blorp_bridge.CliFrontendPkgModule
        (Session.package_id_name package)
  | Session.Package_module package ->
      Compiler_blorp_bridge.CliFrontendSourcePackageModule
        (Session.package_id_name package)

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

(** Load imports from an already parsed program without a preloaded frontend
    graph.

    This is the legacy compatibility path for direct source/tooling entry
    points that do not yet have a Blorp-discovered import closure. Normal CLI
    compile/check/run paths should pass a [preloaded_module_graph] and use the
    single frontend graph handoff instead. *)
let load_modules_after_parse_with_legacy_imports ?on_frontend_phase ?surface
    ~filename program =
  let record phase =
    match on_frontend_phase with Some f -> f phase | None -> ()
  in
  record Parse;
  let base_dir = Modules.extract_directory filename in
  let _ = Modules.load_imports ?surface program base_dir in
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

let bridge_error ~filename ?(phase = Ast.TypeCheck) message =
  {
    message;
    loc = Ast.point_loc_in ~file:filename ~line:1 ~column:1;
    phase;
    kind = Ast.OtherError;
    notes = [];
    help = None;
  }

let bridge_errors ~filename errors =
  List.map (bridge_error ~filename) errors

let find_graph_source graph ~path ~module_name =
  List.find_opt
    (fun source ->
      String.equal source.Modules.preload_path path
      && String.equal source.preload_module_name module_name)
    graph.Modules.preload_graph_sources

let find_first_graph_source_for_path graph path =
  List.find_opt
    (fun source -> String.equal source.Modules.preload_path path)
    graph.Modules.preload_graph_sources

let string_starts_with ~prefix text =
  let prefix_len = String.length prefix in
  String.length text >= prefix_len
  && String.sub text 0 prefix_len = prefix

let string_ends_with ~suffix text =
  let suffix_len = String.length suffix in
  let text_len = String.length text in
  text_len >= suffix_len
  && String.sub text (text_len - suffix_len) suffix_len = suffix

let embedded_std_name_from_path path =
  let prefix = "<embedded:" in
  if string_starts_with ~prefix path && string_ends_with ~suffix:">" path then
    let start = String.length prefix in
    Some (String.sub path start (String.length path - start - 1))
  else None

let embedded_std_source_for_loaded_module (m : Modules.loaded_module) =
  match Embedded_std.find m.name with
  | Some _ as source -> source
  | None ->
      let std_name =
        if string_starts_with ~prefix:"std/" m.name then m.name
        else "std/" ^ m.name
      in
      (match Embedded_std.find std_name with
      | Some _ as source -> source
      | None -> (
          match embedded_std_name_from_path m.path with
          | Some embedded_name -> Embedded_std.find embedded_name
          | None -> None))

let loaded_module_source_text_for_bridge graph (m : Modules.loaded_module) =
  match find_graph_source graph ~path:m.path ~module_name:m.name with
  | Some source -> Some source.Modules.preload_source
  | None -> (
      match embedded_std_source_for_loaded_module m with
      | Some source -> Some source
      | None -> (
          try Some (Modules.read_file m.path) with Sys_error _ -> None))

let typecheck_import_module_for_loaded_module graph (m : Modules.loaded_module)
    =
  Option.map
    (fun source ->
      {
        Compiler_blorp_bridge.typecheck_import_path = m.path;
        typecheck_import_module_name = m.name;
        typecheck_import_module_path = m.name;
        typecheck_import_text = source;
        typecheck_import_origin =
          bridge_module_origin_of_session_origin m.origin;
      })
    (loaded_module_source_text_for_bridge graph m)

let typecheck_import_modules_for_loaded_modules ?exclude_path ?exclude_module
    graph =
  let seen = Hashtbl.create 64 in
  let excluded (m : Modules.loaded_module) =
    match (exclude_path, exclude_module) with
    | Some path, Some module_name ->
        String.equal m.path path && String.equal m.name module_name
    | Some path, None -> String.equal m.path path
    | None, Some module_name -> String.equal m.name module_name
    | None, None -> false
  in
  Modules.get_all_modules ()
  |> List.fold_left
       (fun acc (m : Modules.loaded_module) ->
         if excluded m || Hashtbl.mem seen m.name then acc
         else
           match typecheck_import_module_for_loaded_module graph m with
           | None -> acc
           | Some import_module ->
               Hashtbl.add seen m.name ();
               import_module :: acc)
       []
  |> List.rev

let typecheck_resolved_imports_for_graph graph =
  graph.Modules.preload_graph_imports
  |> List.filter_map (fun edge ->
         match edge.Modules.preload_import_resolved_module with
         | Some resolved_module ->
             Some
               {
                 Compiler_blorp_bridge.typecheck_resolved_import_from_path =
                   edge.preload_import_from_path;
                 typecheck_resolved_import_from_module =
                   edge.preload_import_from_module;
                 typecheck_resolved_import_path = edge.preload_import_path;
                 typecheck_resolved_import_module = resolved_module;
               }
         | None -> None)

let typecheck_graph_source_with_blorp_bridge ~allow_debug_only_calls
    ~import_modules ~resolved_imports source =
  match
    Compiler_blorp_bridge.typecheck_source_via_command_with_imports_policy
      ~allow_debug_only_calls ~import_modules ~resolved_imports
      ~origin:
        (bridge_module_origin_of_session_origin source.Modules.preload_origin)
      ~path:source.Modules.preload_path
      ~module_name:source.preload_module_name ~text:source.preload_source
  with
  | Error (_code, message) ->
      Error
        [ bridge_error ~filename:source.preload_path ~phase:Ast.Parse message ]
  | Ok artifact -> (
      match artifact.typechecked_errors with
      | [] ->
          if artifact.typechecked_ctfe_evaluated_by_blorp then
            Ok
              ( artifact.typechecked_program,
                artifact.typechecked_import_bindings )
          else
            Error
              [
                bridge_error ~filename:source.preload_path
                  "typecheck_source bridge completed without evaluating CTFE";
              ]
      | errors -> Error (bridge_errors ~filename:source.preload_path errors))

(** Phase 2.1: each top-level [Pipeline] entry point runs in its own
    [Session.t] so two compiles/checks in a single process can't leak state
    (module_cache, prelude_modules_loaded, load_errors, search_paths,
    fresh-name counters) into each other. The CLI's pre-call
    [init_module_paths] writes to the long-lived process-default session and is
    harmless (the new session re-inits its own paths). *)
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

let typecheck_loaded_graph_modules_with_blorp_bridge
    ~allow_debug_only_calls graph =
  let errors = ref [] in
  let loaded_modules = Modules.get_all_modules () in
  loaded_modules
  |> List.iter (fun (m : Modules.loaded_module) ->
         match Modules.get_typed_decls m.name with
         | Some _ -> ()
         | None -> (
             match find_graph_source graph ~path:m.path ~module_name:m.name with
             | None -> ()
             | Some source -> (
                 let import_modules =
                   typecheck_import_modules_for_loaded_modules
                     ~exclude_path:m.path ~exclude_module:m.name graph
                 in
                 let resolved_imports = typecheck_resolved_imports_for_graph graph in
                 match
                   typecheck_graph_source_with_blorp_bridge
                     ~allow_debug_only_calls ~import_modules ~resolved_imports
                     source
                 with
                 | Ok (typed_decls, import_bindings) ->
                     Modules.set_typed_decls m.name typed_decls;
                     Modules.set_typed_import_bindings m.name import_bindings
                 | Error module_errors ->
                     errors := module_errors @ !errors)));
  match List.rev !errors with
  | _ :: _ as errors -> errors
  | [] -> []

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
  match
    Modules.parse_typecheck_source_artifact ~filename ~bridge_read_file source
  with
  | Error err ->
      record Parse;
      Error [ err ]
  | Ok artifact ->
      load_modules_after_parse_with_legacy_imports ?on_frontend_phase
        ?surface:artifact.Modules.source_artifact_surface ~filename
        artifact.source_artifact_program

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

let source_impls_from_loaded_modules () =
  let collect_impl (m : Modules.loaded_module) local_type_names d =
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
        Some (m.name, Typecheck.make_impl_instance ~loc:d.decl_loc impl)
    | _ -> None
  in
  Modules.get_all_modules ()
  |> List.concat_map (fun (m : Modules.loaded_module) ->
         let local_type_names =
           Module_type_identity.local_type_names_from_decls m.decls
         in
         List.filter_map (collect_impl m local_type_names) m.decls)

let loaded_module_coherence_errors () =
  let env_for_diag = fresh_builtins_env () in
  check_cross_module_coherence env_for_diag
    (source_impls_from_loaded_modules ())

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
  let attempted = Hashtbl.create 16 in
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
  let cross_module_errs = loaded_module_coherence_errors () in
  List.rev (List.rev_append cross_module_errs !module_errors)

type blorp_bridge_typecheck_result = {
  blorp_bridge_source_program : Ast.program;
  blorp_bridge_typed_program : Typed_ast.program;
  blorp_bridge_import_bindings : Session.import_binding list;
}

let typecheck_graph_with_blorp_bridge_policy ~debug
    ~allow_debug_only_calls
    ~on_frontend_phase ~filename ~preloaded_module_graph =
  let record_frontend phase =
    match on_frontend_phase with Some f -> f phase | None -> ()
  in
  let target_source =
    find_first_graph_source_for_path preloaded_module_graph filename
  in
  match target_source with
  | None ->
      Error
        [
          bridge_error ~filename
            "frontend module graph did not contain the target source";
        ]
  | Some target ->
      match
        load_modules_after_preloaded_graph ~filename
          ~program:target.preload_decls preloaded_module_graph
      with
      | Error _ as error ->
          record_frontend ModuleLoad;
          error
      | Ok _ ->
          record_frontend ModuleLoad;
          let module_errors =
            typecheck_loaded_graph_modules_with_blorp_bridge
              ~allow_debug_only_calls
              preloaded_module_graph
          in
          let module_errors =
            match module_errors with
            | _ :: _ -> module_errors
            | [] ->
                ensure_modules_typed ~debug ~allow_debug_only_calls ()
          in
          if module_errors <> [] then begin
              record_frontend ModuleTypecheck;
              Error module_errors
          end
          else
              match loaded_module_coherence_errors () with
              | _ :: _ as errors ->
                  record_frontend ModuleTypecheck;
                  Error errors
              | [] ->
                  record_frontend ModuleTypecheck;
                  let import_modules =
                    typecheck_import_modules_for_loaded_modules
                      ~exclude_path:target.preload_path
                      ~exclude_module:target.preload_module_name
                      preloaded_module_graph
                  in
                  let resolved_imports =
                    typecheck_resolved_imports_for_graph preloaded_module_graph
                  in
                  match
                    typecheck_graph_source_with_blorp_bridge
                      ~allow_debug_only_calls ~import_modules ~resolved_imports
                      target
                  with
                  | Error _ as error ->
                      record_frontend MainTypecheck;
                      error
                  | Ok (typed_program, import_bindings) ->
                      record_frontend MainTypecheck;
                      Ok
                        {
                          blorp_bridge_source_program = target.preload_decls;
                          blorp_bridge_typed_program = typed_program;
                          blorp_bridge_import_bindings = import_bindings;
                        }

let typecheck_only_typed_with_blorp_bridge_policy ~debug
    ~allow_debug_only_calls ~filename ~preloaded_module_graph =
  with_fresh_session filename (fun () ->
      typecheck_graph_with_blorp_bridge_policy ~debug ~allow_debug_only_calls
        ~on_frontend_phase:None ~filename ~preloaded_module_graph
      |> Result.map (fun result -> result.blorp_bridge_typed_program))

let typecheck_only_typed_with_blorp_bridge ~filename ~preloaded_module_graph =
  typecheck_only_typed_with_blorp_bridge_policy ~debug:false
    ~allow_debug_only_calls:false ~filename
    ~preloaded_module_graph

let with_reusable_typecheck_session ~(sess : Session.t) filename (k : unit -> 'a)
    : 'a =
  let parent = Session.current () in
  let inherited_std_override =
    if parent == sess then None
    else
      match (parent.Session.std_override_active, parent.std_override_dir) with
      | true, Some dir -> Some dir
      | _ -> None
  in
  Session.reset_compilation_state_preserving_parse_cache sess;
  Option.iter (Modules.set_std_override ~sess) inherited_std_override;
  Session.with_current sess (fun () ->
      Modules.init_module_paths (Modules.extract_directory filename);
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

(* Legacy direct-source/typechecking route for tooling and tests that still
   pass raw source instead of a Blorp frontend graph. Normal source-command
   checks enter through [typecheck_only_typed_with_blorp_bridge_policy]. *)
let typecheck_only_typed_impl ~source_kind ~filename ~source ?(debug = false) ()
    =
  with_fresh_session filename (fun () ->
      match parse_and_load_modules ~source_kind ~filename source with
      | Error _ as e -> e
      | Ok (program, _base_dir) ->
          typecheck_loaded_program ~source_kind ~filename ~program ~debug ())

let typecheck_only_typed ~filename ~source ?(debug = false) () =
  typecheck_only_typed_impl ~source_kind:User_source ~filename ~source ~debug ()

let typecheck_only ~filename ~source ?(debug = false) () =
  match typecheck_only_typed ~filename ~source ~debug () with
  | Ok typed_program -> Ok (Typed_ast.program_ast typed_program)
  | Error _ as e -> e

let typecheck_only_typed_reusing_session ~sess ~filename ~source
    ?(debug = false) () =
  with_reusable_typecheck_session ~sess filename (fun () ->
      match parse_and_load_modules ~source_kind:User_source ~filename source with
      | Error _ as e -> e
      | Ok (program, _base_dir) ->
          typecheck_loaded_program ~source_kind:User_source ~filename ~program
            ~debug ())

let typecheck_only_reusing_session ~sess ~filename ~source ?(debug = false) ()
    =
  match
    typecheck_only_typed_reusing_session ~sess ~filename ~source ~debug ()
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

let compile_typechecked_program ~source_kind ~retain_debug_blocks
    ~embed_runtime ~require_main ~profile ?on_stage ?on_stage_event
    ?on_stage_json ?tail_observation_stages ~check_invariants ~filename
    ~program ~typed_program ~main_import_bindings () =
  let module_name = target_module_name filename in
  let import_errors =
    unused_import_errors ~scope:(Explicit_target { module_name; source_kind })
      program
  in
  if import_errors <> [] then Error import_errors
  else if require_main && not (program_has_top_level_main program) then
    Error [ missing_main_error ~filename ]
  else
    try
      let c_code, link_flags, include_dirs =
        Core_pipeline.compile_typed_with_modules ~main_import_bindings
          ~embed_runtime ~profile ~debug:retain_debug_blocks ?on_stage
          ?on_stage_event ?on_stage_json ?tail_observation_stages
          ~check_invariants typed_program
      in
      Ok (Compiled { program; typed_program; c_code; link_flags; include_dirs })
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
          ]

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
    | Ok (main_state, typed_program) ->
        record_frontend MainTypecheck;
        compile_typechecked_program ~source_kind ~retain_debug_blocks
          ~embed_runtime ~require_main ~profile ?on_stage ?on_stage_event
          ?on_stage_json ?tail_observation_stages ~check_invariants ~filename
          ~program ~typed_program
          ~main_import_bindings:(List.rev main_state.Typecheck.import_bindings)
          ()

(** Legacy direct-source compile route for callers that still pass raw source.
    Normal source commands use [compile_preloaded_graph_with_blorp_bridge] so
    the Blorp frontend graph owns parse/module/typecheck.

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
    ?check_invariants ~filename ~program ?preloaded_module_graph () =
  with_fresh_session filename (fun () ->
      let loaded =
        match preloaded_module_graph with
        | Some graph ->
            load_modules_after_preloaded_graph ?on_frontend_phase ~filename
              ~program graph
        | None ->
            load_modules_after_parse_with_legacy_imports ?on_frontend_phase
              ~filename program
      in
      match loaded with
      | Error _ as e -> e
      | Ok (program, _base_dir) ->
          compile_loaded_program ~source_kind:User_source ?debug
            ?allow_debug_only_calls ?retain_debug_blocks ?embed_runtime
            ?require_main ?profile ?on_frontend_phase ?on_stage ?on_stage_event
            ?on_stage_json ?tail_observation_stages ?check_invariants ~filename
            ~program ())

let compile_preloaded_graph_with_blorp_bridge ?(debug = false)
    ?allow_debug_only_calls ?retain_debug_blocks ?(embed_runtime = true)
    ?(require_main = false) ?(profile = false) ?on_frontend_phase ?on_stage
    ?on_stage_event ?on_stage_json ?tail_observation_stages
    ?(check_invariants = false) ~filename ~preloaded_module_graph () =
  let retain_debug_blocks = Option.value retain_debug_blocks ~default:debug in
  with_fresh_session filename (fun () ->
      let allow_debug_only_calls =
        Option.value allow_debug_only_calls ~default:debug
      in
      match
        typecheck_graph_with_blorp_bridge_policy ~debug
          ~allow_debug_only_calls ~filename ~on_frontend_phase
          ~preloaded_module_graph
      with
      | Error _ as error -> error
      | Ok result ->
          compile_typechecked_program ~source_kind:User_source
            ~retain_debug_blocks ~embed_runtime ~require_main ~profile
            ?on_stage ?on_stage_event ?on_stage_json ?tail_observation_stages
            ~check_invariants ~filename
            ~program:result.blorp_bridge_source_program
            ~typed_program:result.blorp_bridge_typed_program
            ~main_import_bindings:result.blorp_bridge_import_bindings ())

let compile_legacy_direct_source ?debug ?allow_debug_only_calls
    ?retain_debug_blocks ?embed_runtime ?require_main ?profile
    ?on_frontend_phase ?on_stage ?on_stage_event ?on_stage_json
    ?tail_observation_stages ?check_invariants ~filename ~source () =
  compile_impl ~source_kind:User_source ?debug ?allow_debug_only_calls
    ?retain_debug_blocks ?embed_runtime ?require_main ?profile
    ?on_frontend_phase ?on_stage ?on_stage_event ?on_stage_json
    ?tail_observation_stages ?check_invariants ~filename ~source ()

let compile ?debug ?allow_debug_only_calls ?retain_debug_blocks ?embed_runtime
    ?require_main ?profile ?on_frontend_phase ?on_stage ?on_stage_event
    ?on_stage_json ?tail_observation_stages ?check_invariants ~filename ~source
    () =
  compile_legacy_direct_source ?debug ?allow_debug_only_calls
    ?retain_debug_blocks ?embed_runtime ?require_main ?profile
    ?on_frontend_phase ?on_stage ?on_stage_event ?on_stage_json
    ?tail_observation_stages ?check_invariants ~filename ~source ()

let compile_generated_test_harness ?debug ?allow_debug_only_calls
    ?retain_debug_blocks ?embed_runtime ~filename ~source () =
  compile_impl ~source_kind:Generated_test_harness ?debug
    ?allow_debug_only_calls ?retain_debug_blocks ?embed_runtime ~filename
    ~source ()
