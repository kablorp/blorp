(** blorp CLI - Unified command-line interface

    Usage:
      blorp compile program.brp          # Compile to C and binary
      blorp compile --no-emit program.brp # Type check only
      blorp compile --ast program.brp    # Show AST only
      blorp run program.brp              # Compile and run
      blorp run --release program.brp    # Compile and run optimized
      blorp run --profile program.brp    # Run with profiling
      blorp check src/                   # Type check all .brp files in directory
      blorp test tests/test.brp          # Run a single test
      blorp test tests/                  # Run all tests in directory
      blorp purify program.brp           # Automatically mark pure functions
*)

open Blorp
module StringMap = Map.Make (String)
module IntSet = Set.Make (Int)
module IntMap = Map.Make (Int)

type purify_func_key = string * int * int * int * int * string option

module PurifyFuncKey = struct
  type t = purify_func_key

  let compare = compare
end

module PurifyFuncKeySet = Set.Make (PurifyFuncKey)

type purify_candidate = {
  candidate_id : int;
  candidate_name : string;
  candidate_key : purify_func_key;
  candidate_signature : Typecheck.checked_func_signature;
  candidate_func : Ast.func_decl;
  candidate_body : Ast.expr;
}

let purify_func_key ~name (loc : Ast.loc) =
  (name, loc.line, loc.column, loc.end_line, loc.end_column, loc.loc_file)

let read_file = Modules.read_file
let extract_directory = Modules.extract_directory
let init_module_paths = Modules.init_module_paths

(** Format a list of pipeline errors for display *)
let format_pipeline_errors ~file errors = Diagnostics.format_errors ~file errors

(** Parse a blorp file and return the AST (for --ast mode only) *)
let parse_file filename =
  let input = read_file filename in
  let base_dir = extract_directory filename in
  init_module_paths base_dir;
  match Modules.parse_source input with
  | Ok program -> Ok (program, base_dir)
  | Error err -> Error (Diagnostics.format_error ~file:filename err)

let type_expr_to_string = Types.type_to_string

let func_to_string depth func =
  let indent = String.make (depth * 2) ' ' in
  let name_str =
    match func.Ast.func_name with Some n -> n | None -> "<lambda>"
  in
  let pure_str = if func.Ast.func_is_pure then " [pure]" else "" in
  let tailrec_str =
    if func.Ast.func_is_tailrec then " [@tail_recursive]" else ""
  in
  let ret_str =
    match func.Ast.func_return_type with
    | Some t -> " -> " ^ type_expr_to_string t
    | None -> ""
  in
  Printf.sprintf "%sFunc %s%s%s%s" indent name_str pure_str tailrec_str ret_str

let decl_to_string d =
  match d.Ast.decl_desc with
  | Ast.DFunc f -> func_to_string 0 f
  | Ast.DType t ->
      Printf.sprintf "Union %s[%s] with %d variants" t.Ast.type_name
        (String.concat ", " (Ast.type_param_names t.Ast.type_params))
        (List.length t.Ast.type_variants)
  | Ast.DRecord r ->
      let keyword = if r.Ast.record_is_value then "Struct" else "Record" in
      Printf.sprintf "%s %s[%s] with %d fields" keyword r.Ast.record_name
        (String.concat ", " (Ast.type_param_names r.Ast.record_type_params))
        (List.length r.Ast.record_fields)
  | Ast.DVar v ->
      let name = match v.Ast.var_name with Some n -> n | None -> "_" in
      let prefix = if v.Ast.var_is_mutable then "var " else "" in
      Printf.sprintf "%s%s" prefix name
  | Ast.DImport i -> Printf.sprintf "Import %s" i.Ast.import_module
  | Ast.DPrivate _ -> "Private"
  | Ast.DTrait t -> Printf.sprintf "Trait %s" t.Ast.trait_name
  | Ast.DImpl i ->
      Printf.sprintf "Impl %s for %s" i.Ast.impl_trait
        (type_expr_to_string i.Ast.impl_for_type)
  | Ast.DTypeAlias a -> Printf.sprintf "TypeAlias %s" a.Ast.alias_name

let program_to_string prog = String.concat "\n" (List.map decl_to_string prog)

(** Resolve timeout: CLI flag overrides env vars, checked in order. *)
let resolve_timeout_from_env env_names cli_timeout =
  match cli_timeout with
  | Some _ -> cli_timeout
  | None ->
      List.find_map
        (fun name -> Option.bind (Sys.getenv_opt name) int_of_string_opt)
        env_names

let resolve_timeout cli_timeout =
  resolve_timeout_from_env [ "BLORP_TIMEOUT" ] cli_timeout

let resolve_test_timeout cli_timeout =
  resolve_timeout_from_env [ "BLORP_TEST_TIMEOUT"; "BLORP_TIMEOUT" ] cli_timeout

let resolve_sanitize cli_sanitize =
  cli_sanitize || Sys.getenv_opt "BLORP_SANITIZE" = Some "1"

let resolve_leak_check cli_leak_check =
  cli_leak_check || Sys.getenv_opt "BLORP_LEAK_CHECK" = Some "1"

let resolve_no_format cli_no_format =
  cli_no_format || Sys.getenv_opt "BLORP_NO_FORMAT" = Some "1"

(** Auto-format a .brp file in place before compilation.
    Uses the format cache to skip already-formatted files.
    Does NOT format std library files. *)
let auto_format_user_file filename =
  (* Skip std library files *)
  let is_std =
    Modules.is_path_under_dir
      ~dir:(Filename.concat (Sys.getcwd ()) "std")
      filename
  in
  if not is_std then Fmt.auto_format filename

(** Purify a file by automatically marking eligible functions as 'pure'. *)
let purify_file ?(dry_run = false) ?(verbose = false) filename =
  let source = read_file filename in
  match Pipeline.typecheck_module_only_typed ~filename ~source with
  | Error errors ->
      prerr_endline (format_pipeline_errors ~file:filename errors);
      -1
  | Ok (state, typed_analysis_program) -> (
      let analysis_program = Typed_ast.program_ast typed_analysis_program in
      let env = Typecheck.get_state_env state in
      let module_aliases = Typecheck.get_state_module_aliases state in

      let rec collect_funcs acc (decls : Ast.program) =
        List.fold_left
          (fun acc decl ->
            match decl.Ast.decl_desc with
            | Ast.DFunc f -> (f, decl.Ast.decl_loc) :: acc
            | Ast.DPrivate inner -> collect_funcs acc [ inner ]
            | _ -> acc)
          acc decls
      in
      let funcs = collect_funcs [] analysis_program |> List.rev in

      let with_pure_assumptions candidates env =
        List.fold_left
          (fun acc candidate ->
            let sig_ = candidate.candidate_signature in
            Env.add_func acc candidate.candidate_name sig_.cfs_func_type
              ~callable_id:candidate.candidate_id
              ~type_params:sig_.cfs_effective_type_params
              ~param_names:sig_.cfs_param_names ~purity:Env.Pure
              ~origin:sig_.cfs_origin ?module_path:sig_.cfs_module_path
              ~dim_constraints:sig_.cfs_dim_constraints
              ?loop_producer:sig_.cfs_loop_producer
              ~debug_only:sig_.cfs_debug_only ())
          env candidates
      in

      let add_func_params env func =
        List.fold_left
          (fun acc (p : Ast.param) ->
            match (p.Ast.param_name, p.Ast.param_type) with
            | Some name, Some ty -> Env.add_var acc name ty ()
            | _ -> acc)
          env func.Ast.func_params
      in

      let has_global_mutation body func =
        let is_param name =
          List.exists
            (fun (p : Ast.param) -> p.Ast.param_name = Some name)
            func.Ast.func_params
        in
        let rec walk expr =
          match expr.Ast.expr_desc with
          | Ast.EAssign (name, _) -> (
              match Env.lookup env name with
              | Some { kind = Env.VarSymbol { mutability = Env.Mutable; _ }; _ }
                when not (is_param name) ->
                  true
              | _ -> List.exists walk (Ast.expr_children expr))
          | _ -> List.exists walk (Ast.expr_children expr)
        in
        walk body
      in

      let has_impure_callback_param func =
        List.exists
          (fun (p : Ast.param) ->
            match p.Ast.param_type with
            | Some ty -> Env.is_impure_function_type env ty
            | _ -> false)
          func.Ast.func_params
      in

      let name_counts =
        List.fold_left
          (fun counts ((func : Ast.func_decl), _) ->
            match func.Ast.func_name with
            | Some name ->
                let count =
                  match StringMap.find_opt name counts with
                  | Some count -> count
                  | None -> 0
                in
                StringMap.add name (count + 1) counts
            | None -> counts)
          StringMap.empty funcs
      in
      let has_unique_name name =
        match StringMap.find_opt name name_counts with
        | Some 1 -> true
        | _ -> false
      in

      let local_candidates =
        List.fold_right
          (fun ((func : Ast.func_decl), loc) acc ->
            match
              (func.Ast.func_name, Ast.func_body_expr_opt func.Ast.func_body)
            with
            | Some name, Some body
              when has_unique_name name
                   && (not func.Ast.func_is_pure)
                   && (not (Ast.func_has_builtin_body func))
                   && (not (Ast.func_is_foreign func))
                   && (not (has_impure_callback_param func))
                   && (not (has_global_mutation body func))
                   && not (Typecheck.has_concurrency body) -> (
                match
                  ( Typecheck.get_state_func_callable_id state ~name ~loc,
                    Typecheck.checked_func_signature_of_func state func )
                with
                | Some id, Some signature ->
                    {
                      candidate_id = id;
                      candidate_name = name;
                      candidate_key = purify_func_key ~name loc;
                      candidate_signature = signature;
                      candidate_func = func;
                      candidate_body = body;
                    }
                    :: acc
                | _ -> acc)
            | _ -> acc)
          funcs []
      in
      let local_candidate_ids =
        List.fold_left
          (fun ids candidate -> IntSet.add candidate.candidate_id ids)
          IntSet.empty local_candidates
      in
      let local_candidate_id_list = IntSet.elements local_candidate_ids in
      let local_candidate_key_by_id =
        List.fold_left
          (fun keys candidate ->
            IntMap.add candidate.candidate_id candidate.candidate_key keys)
          IntMap.empty local_candidates
      in
      let local_candidate_id_by_name =
        List.fold_left
          (fun ids candidate ->
            StringMap.add candidate.candidate_name candidate.candidate_id ids)
          StringMap.empty local_candidates
      in

      let collect_local_calls body =
        Purity_analysis.collect_matching_calls
          ~match_call:(fun name callee loc _args ->
            if Purity_analysis.is_module_qualified_call callee module_aliases
            then []
            else
              match StringMap.find_opt name local_candidate_id_by_name with
              | Some id -> [ Purity_analysis.call_ref ~called_id:id name loc ]
              | None -> [])
          ~match_resolved_call:(fun resolved _callee loc _args ->
            match Ast.resolved_call_concrete_callable_id resolved with
            | Some id when IntSet.mem id local_candidate_ids ->
                Some [ Purity_analysis.call_ref ~called_id:id "<local>" loc ]
            | Some _ | None -> Some [])
          ~enter_lambda:(fun func -> func.Ast.func_is_pure)
          body
        |> List.fold_left
             (fun ids (call : Purity_analysis.call_ref) ->
               match call.called_id with
               | Some id -> IntSet.add id ids
               | None -> ids)
             IntSet.empty
      in

      let dependency_map =
        List.fold_left
          (fun deps candidate ->
            IntMap.add candidate.candidate_id
              (collect_local_calls candidate.candidate_body)
              deps)
          IntMap.empty local_candidates
      in

      let has_external_blocker candidate =
        let test_env = env |> with_pure_assumptions local_candidates in
        let test_env = add_func_params test_env candidate.candidate_func in
        Typecheck.collect_impure_calls ~prefer_env_purity:true ~strict:true
          ~assume_pure_callable_ids:local_candidate_id_list test_env
          module_aliases candidate.candidate_body
        <> []
      in

      let externally_viable =
        List.fold_left
          (fun acc candidate ->
            if has_external_blocker candidate then acc
            else IntSet.add candidate.candidate_id acc)
          IntSet.empty local_candidates
      in

      let rec prune_by_dependencies viable =
        let next =
          IntSet.filter
            (fun id ->
              let deps =
                match IntMap.find_opt id dependency_map with
                | Some deps -> deps
                | None -> IntSet.empty
              in
              IntSet.for_all (fun dep -> IntSet.mem dep viable) deps)
            viable
        in
        if IntSet.equal next viable then viable else prune_by_dependencies next
      in
      let purifiable_ids = prune_by_dependencies externally_viable in
      let purifiable_keys =
        IntSet.fold
          (fun id keys ->
            match IntMap.find_opt id local_candidate_key_by_id with
            | Some key -> PurifyFuncKeySet.add key keys
            | None -> keys)
          purifiable_ids PurifyFuncKeySet.empty
      in
      let ordered_names =
        local_candidates
        |> List.filter_map (fun candidate ->
            if IntSet.mem candidate.candidate_id purifiable_ids then
              Some candidate.candidate_name
            else None)
      in

      match ordered_names with
      | [] ->
          if verbose then
            Printf.printf "No functions to purify in %s.\n" filename;
          0
      | names -> (
          if dry_run then begin
            Printf.printf
              "[DRY-RUN] Functions that could be purified in %s: %s\n" filename
              (String.concat ", " names);
            List.length names
          end
          else
            match Modules.parse_source ~filename source with
            | Error err ->
                prerr_endline (format_pipeline_errors ~file:filename [ err ]);
                -1
            | Ok source_program -> (
                let comments = Lexer.get_comments () in
                let rec purify_decl decl =
                  match decl.Ast.decl_desc with
                  | Ast.DFunc f ->
                      let f =
                        match f.Ast.func_name with
                        | Some name
                          when PurifyFuncKeySet.mem
                                 (purify_func_key ~name decl.Ast.decl_loc)
                                 purifiable_keys ->
                            { f with Ast.func_is_pure = true }
                        | _ -> f
                      in
                      { decl with Ast.decl_desc = Ast.DFunc f }
                  | Ast.DPrivate inner ->
                      {
                        decl with
                        Ast.decl_desc = Ast.DPrivate (purify_decl inner);
                      }
                  | _ -> decl
                in
                let new_program = List.map purify_decl source_program in
                match
                  Fmt.format_program_with_comments ~comments new_program
                with
                | Error msg ->
                    prerr_endline msg;
                    -1
                | Ok formatted -> (
                    match
                      Pipeline.typecheck_module_only_typed ~filename
                        ~source:formatted
                    with
                    | Error errors ->
                        prerr_endline
                          (format_pipeline_errors ~file:filename errors);
                        -1
                    | Ok _ ->
                        let oc = open_out filename in
                        output_string oc formatted;
                        close_out oc;
                        Printf.printf "Purified %d function(s) in %s\n"
                          (List.length names) filename;
                        List.length names))))

type compile_opts = {
  no_emit : bool;
  ast_only : bool;
      (** Legacy --ast: prints AST and exits (no typecheck, no emit) *)
  dump_ast : bool;  (** --dump-ast: prints AST and continues compiling *)
  dump_typed_ast : bool;
      (** --dump-typed-ast: prints typed AST and continues compiling *)
  debug : bool;
  output : string option;
  no_format : bool;
  embed_runtime : bool;
  dump_core_after : Blorp.Core_stage.t list;
      (** --dump-core / --dump-core-after=STAGE[,STAGE…]; repeatable *)
  stop_after : Blorp.Core_stage.t option;  (** --stop-after=STAGE *)
  dump_file : string option;  (** --dump-core-file=PATH; stderr if None *)
  time_phases : bool;  (** --time-phases (per-phase timing) *)
  check_invariants : bool;  (** --check-invariants (Phase 2.2) *)
}
(** Options for the [compile] subcommand. *)

let default_compile_opts =
  {
    no_emit = false;
    ast_only = false;
    dump_ast = false;
    dump_typed_ast = false;
    debug = false;
    output = None;
    no_format = false;
    embed_runtime = true;
    dump_core_after = [];
    stop_after = None;
    dump_file = None;
    time_phases = false;
    check_invariants = false;
  }

(** Open the dump channel based on [opts.dump_file]. Caller must close. *)
let open_dump_channel opts =
  match opts.dump_file with
  | Some path -> (open_out path, true)
  | None -> (stderr, false)

type obs = {
  callback : Blorp.Core_pipeline.on_stage_callback option;
  frontend_callback : (Blorp.Pipeline.frontend_phase -> unit) option;
  profiler : Blorp.Core_profile.t option;
  cleanup : unit -> unit;  (** closes the dump channel if one was opened *)
}
(** Composite observability handle: the stage callback, optional profiler
    for summary reporting, and a cleanup thunk that must run on every
    exit path (success, stop, or error). *)

let obs_none =
  {
    callback = None;
    frontend_callback = None;
    profiler = None;
    cleanup = (fun () -> ());
  }

(** Best-effort short git SHA for dump provenance (Phase 0.5.6). Returns
    the output of [git rev-parse --short HEAD] if the repo is accessible,
    else ["unknown"]. Never raises — provenance is nice-to-have. *)
let dump_git_sha () =
  try
    let ic = Unix.open_process_in "git rev-parse --short HEAD 2>/dev/null" in
    let line = try input_line ic with End_of_file -> "" in
    match Unix.close_process_in ic with
    | Unix.WEXITED 0 when String.length line > 0 -> line
    | _ -> "unknown"
  with _ -> "unknown"

(** Build a composite stage callback that may dump, stop, and/or profile.
    Returns [obs_none] if no observability options are active (so the
    pipeline skips the hook overhead entirely). [source_file] is the
    path compiled, used only for the dump header (Phase 0.5.6). The
    returned [cleanup] must be called on every exit path; callers
    typically wrap their compile invocation in
    [Fun.protect ~finally:obs.cleanup]. *)
let build_on_stage ?source_file opts : obs =
  let profiler =
    if opts.time_phases then Some (Blorp.Core_profile.create ()) else None
  in
  let frontend_callback =
    Option.map
      (fun p phase ->
        Blorp.Core_profile.on_label p
          (Blorp.Pipeline.frontend_phase_to_string phase))
      profiler
  in
  match (opts.dump_core_after, opts.stop_after, profiler) with
  | [], None, None -> obs_none
  | _ ->
      let ch, should_close = open_dump_channel opts in
      let closed = ref false in
      let close_once () =
        if should_close && not !closed then begin
          closed := true;
          close_out_noerr ch
        end
      in
      let header_emitted = ref false in
      let emit_header_once () =
        if (not !header_emitted) && opts.dump_core_after <> [] then begin
          header_emitted := true;
          let file = Option.value source_file ~default:"<stdin>" in
          Printf.fprintf ch "-- blorp %s-%s %s\n" Blorp.Version.version
            (dump_git_sha ()) file;
          flush ch
        end
      in
      let cb stage prog =
        (match profiler with
        | Some p -> Blorp.Core_profile.on_stage p stage prog
        | None -> ());
        if List.exists (fun s -> s = stage) opts.dump_core_after then begin
          emit_header_once ();
          Printf.fprintf ch "===== after %s =====\n%s"
            (Blorp.Core_stage.to_string stage)
            (Blorp.Core.pp_program_indented prog);
          flush ch
        end;
        match opts.stop_after with
        | Some s when s = stage ->
            raise (Blorp.Core_pipeline.Stopped_after stage)
        | _ -> ()
      in
      { callback = Some cb; frontend_callback; profiler; cleanup = close_once }

let check_file_with_opts opts filename =
  if not opts.no_format then auto_format_user_file filename;
  if opts.ast_only then
    begin match parse_file filename with
    | Error msg ->
        prerr_endline msg;
        1
    | Ok (program, _) ->
        print_endline (program_to_string program);
        0
    end
  else
    let source = read_file filename in
    init_module_paths (extract_directory filename);
    if opts.dump_ast then
      begin match parse_file filename with
      | Error msg -> prerr_endline msg
      | Ok (program, _) -> print_endline (program_to_string program)
      end;
    if opts.dump_typed_ast then (
      match
        Pipeline.typecheck_only_typed ~filename ~source ~debug:opts.debug ()
      with
      | Error errors ->
          prerr_endline (format_pipeline_errors ~file:filename errors);
          1
      | Ok typed_program ->
          print_endline (Typed_ast_debug.format_program typed_program);
          print_endline "Type checking succeeded.";
          0)
    else
      match Pipeline.typecheck_only ~filename ~source ~debug:opts.debug () with
      | Error errors ->
          prerr_endline (format_pipeline_errors ~file:filename errors);
          1
      | Ok _program ->
          print_endline "Type checking succeeded.";
          0

let compile_file_with_opts opts filename =
  if opts.no_emit then check_file_with_opts opts filename
  else begin
    if not opts.no_format then auto_format_user_file filename;
    if opts.ast_only then
      begin match parse_file filename with
      | Error msg ->
          prerr_endline msg;
          1
      | Ok (program, _) ->
          print_endline (program_to_string program);
          0
      end
    else
      let source = read_file filename in
      init_module_paths (extract_directory filename);
      (* --dump-ast prints the parsed AST before any further work, then
         continues with the rest of the pipeline. Unlike --ast (which stops
         after parse), it's non-destructive and composes with --dump-core,
         --time-phases, etc. *)
      if opts.dump_ast then
        begin match parse_file filename with
        | Error msg -> prerr_endline msg
        | Ok (program, _) -> print_endline (program_to_string program)
        end;
      let obs = build_on_stage ~source_file:filename opts in
      let print_profile () =
        match obs.profiler with
        | Some p -> prerr_string (Blorp.Core_profile.format p)
        | None -> ()
      in
      Fun.protect ~finally:obs.cleanup (fun () ->
          let result =
            match
              Pipeline.compile ~debug:opts.debug ?on_stage:obs.callback
                ~check_invariants:opts.check_invariants
                ~embed_runtime:opts.embed_runtime
                ?on_frontend_phase:obs.frontend_callback ~filename ~source ()
            with
            | Error errors ->
                prerr_endline (format_pipeline_errors ~file:filename errors);
                1
            | Ok (Pipeline.Stopped_at s) ->
                Printf.eprintf "stopped after %s\n"
                  (Blorp.Core_stage.to_string s);
                0
            | Ok (Pipeline.Compiled { typed_program; c_code; _ }) ->
                if opts.dump_typed_ast then
                  print_endline (Typed_ast_debug.format_program typed_program);
                let base = Filename.remove_extension filename in
                let c_file =
                  match opts.output with Some o -> o | None -> base ^ ".c"
                in
                let oc = open_out c_file in
                Fun.protect
                  ~finally:(fun () -> close_out oc)
                  (fun () -> output_string oc c_code);
                Printf.printf "Generated %s\n" c_file;
                0
          in
          print_profile ();
          result)
  end

(** Compile and run a blorp file *)
let run_file ?(profile = false) ?(debug = false) ?(sanitize = false)
    ?(leak_check = false) ?(run_mode = Compile_profile.Fast) ~timeout
    ?(no_format = false) ?(user_args = []) filename =
  Test_runner.with_run_artifacts (fun () ->
      if not no_format then auto_format_user_file filename;
      let source = read_file filename in
      init_module_paths (extract_directory filename);
      let opt = Compile_profile.opt_level_for_run ~sanitize run_mode in
      let precompiled = Test_runner.precompile_runtime ~sanitize ~opt () in
      let embed_runtime = precompiled = None in
      match
        Pipeline.compile ~profile ~debug ~embed_runtime ~filename ~source ()
      with
      | Error errors ->
          prerr_endline (format_pipeline_errors ~file:filename errors);
          1
      | Ok (Pipeline.Stopped_at _) ->
          (* Unreachable: `blorp run` doesn't wire observability flags. *)
          assert false
      | Ok (Pipeline.Compiled { c_code; link_flags; include_dirs; _ }) ->
          let compilation_dir = Test_runner.run_compilation_dir () in
          let bin_file = Filename.concat compilation_dir "program.bin" in

          let raylib_flags =
            if Test_runner.has_raylib_import () then
              Test_runner.raylib_linker_flags ()
            else ""
          in
          let header_file =
            Option.map (fun p -> p.Test_runner.header_file) precompiled
          in
          let pch_file =
            Option.bind precompiled (fun p -> p.Test_runner.pch_file)
          in
          let cc_args =
            [ "-" ^ opt; "-fwrapv"; "-pipe" ]
            @ (if Lazy.force Test_runner.cc_is_clang && Sys.os_type = "Unix"
               then [ "-Wl,-stack_size,0x1000000" ]
               else [])
            @ (if sanitize then [] else [ "-w" ])
            @ List.concat_map (fun dir -> [ "-I"; dir ]) include_dirs
            @ (match pch_file with
              | Some pch_f ->
                  if Lazy.force Test_runner.cc_is_clang then
                    [ "-include-pch"; pch_f ]
                  else [ "-include"; pch_f ]
              | None -> (
                  match header_file with
                  | Some h -> [ "-include"; h ]
                  | None -> []))
            @ (match precompiled with
              | Some p -> [ p.Test_runner.runtime_obj ]
              | None -> [])
            @ [ "-lm"; "-lpthread" ]
            @ (if sanitize then Test_runner.sanitize_cc_args else [])
            @ (if raylib_flags = "" then []
               else String.split_on_char ' ' (String.trim raylib_flags))
            @ Ffi_boundary.link_flags_cc_args link_flags
          in
          let cc_result, cc_output =
            Test_runner.compile_c_from_stdin c_code bin_file cc_args
          in
          if cc_result <> 0 then begin
            let msg =
              "Internal error: generated C code failed to compile.\n"
              ^ "This is a compiler bug. The C compiler said:\n  "
              ^ String.concat "\n  "
                  (String.split_on_char '\n' (String.trim cc_output))
            in
            prerr_endline
              (Diagnostics.format_diagnostic ~file:filename ~loc:Ast.dummy_loc
                 ~severity:Error ~message:msg);
            1
          end
          else begin
            if leak_check then Unix.putenv "BLORP_LEAK_CHECK" "strict";
            let result =
              Test_runner.run_process_timeout ~timeout bin_file user_args
            in
            if result = 124 then begin
              let secs = match timeout with Some s -> s | None -> 0 in
              Printf.eprintf "Timed out after %ds\n" secs;
              result
            end
            else result
          end)

(** Print usage *)
let usage () =
  print_endline "blorp - Blorp Compiler";
  print_endline "";
  print_endline "Usage: blorp <command> [options] [args]";
  print_endline "";
  print_endline "Commands:";
  print_endline "  check      Parse, import, and type check .brp files";
  print_endline "  compile    Compile a .brp file to C";
  print_endline "  run        Compile and run a .brp file";
  print_endline "  test       Run tests (file or directory)";
  print_endline "  format     Format source files";
  print_endline "  lsp        Start LSP server";
  print_endline "  repl       Interactive REPL";
  print_endline "  purify     Automatically mark pure functions";
  print_endline "";
  print_endline "Flags:";
  print_endline "  --version  Show version";
  print_endline "  --help     Show this help";
  print_endline "";
  print_endline
    "Run 'blorp <command> --help' for details on a specific command.";
  print_endline "";
  print_endline "Project config:";
  print_endline
    "  blorp.toml          Optional project config; [std].path sets std \
     directory";
  print_endline "";
  print_endline "Environment:";
  print_endline
    "  BLORP_STD=<path>      Use std directory (--std-dir overrides; beats \
     blorp.toml)";
  print_endline "  BLORP_TIMEOUT=N       Default timeout (CLI flag overrides)";
  print_endline
    "  BLORP_TEST_TIMEOUT=N  Default test timeout (test --timeout overrides)";
  print_endline "  BLORP_SANITIZE=1      Enable sanitizers (CLI flag overrides)";
  print_endline
    "  BLORP_LEAK_CHECK=1    Enable leak reporting (CLI flag overrides)";
  print_endline
    "  BLORP_THREADS=N       Runtime worker thread pool size (run --threads \
     overrides)";
  print_endline
    "  BLORP_NO_FORMAT=1     Skip auto-formatting (CLI flag overrides)"

type repl_cli_action =
  | ReplHelp
  | ReplRun of { repl_debug : bool }
  | ReplArgError of string

type lsp_cli_action = LspHelp | LspRun | LspArgError of string
type format_cli_mode = FormatWrite | FormatCheck of { show_diff : bool }

type format_cli_action =
  | FormatHelp
  | FormatFiles of { mode : format_cli_mode; paths : string list }
  | FormatEmitProgramJson of string
  | FormatArgError of string

type format_parse_state =
  | FormatSourceState of { mode : format_cli_mode; paths_rev : string list }
  | FormatProgramJsonState of { paths_rev : string list }

let repl_usage () =
  print_endline "Usage: blorp repl [options]";
  print_endline "";
  print_endline "Options:";
  print_endline "  --debug      Enable debug functions";
  print_endline "  --help, -h   Show this help"

let lsp_usage () =
  print_endline "Usage: blorp lsp";
  print_endline "";
  print_endline "Starts the Language Server Protocol server over stdin/stdout.";
  print_endline "";
  print_endline "Options:";
  print_endline "  --help, -h   Show this help"

let format_usage () =
  print_endline "Usage: blorp format [options] <file.brp|dir>";
  print_endline "";
  print_endline "Options:";
  print_endline "  --check        Check if file is formatted (exit 1 if not)";
  print_endline
    "  --diff         Show diff for unformatted files (implies --check)";
  print_endline
    "  --emit-program-json Print formatter full-program JSON for one file \
     (internal)";
  print_endline "";
  print_endline "Accepts files or directories (recursively finds .brp files)."

let parse_repl_cli_args args =
  let rec loop debug = function
    | [] -> ReplRun { repl_debug = debug }
    | ("--help" | "-h") :: _ -> ReplHelp
    | "--debug" :: rest -> loop true rest
    | arg :: _ -> ReplArgError (Printf.sprintf "Unknown repl option: %s" arg)
  in
  loop false args

let parse_lsp_cli_args = function
  | [] -> LspRun
  | [ "--help" ] | [ "-h" ] -> LspHelp
  | arg :: _ -> LspArgError (Printf.sprintf "Unknown lsp option: %s" arg)

let format_state_add_path path = function
  | FormatSourceState { mode; paths_rev } ->
      FormatSourceState { mode; paths_rev = path :: paths_rev }
  | FormatProgramJsonState { paths_rev } ->
      FormatProgramJsonState { paths_rev = path :: paths_rev }

let parse_format_cli_args args =
  let rec loop state = function
    | [] -> (
        match state with
        | FormatSourceState { mode; paths_rev } -> (
            match List.rev paths_rev with
            | [] ->
                FormatArgError
                  "no files specified. Usage: blorp format [--check] \
                   <file.brp|dir>"
            | paths -> FormatFiles { mode; paths })
        | FormatProgramJsonState { paths_rev } -> (
            match List.rev paths_rev with
            | [ filename ] -> FormatEmitProgramJson filename
            | _ ->
                FormatArgError
                  "--emit-program-json accepts exactly one .brp file"))
    | ("--help" | "-h") :: _ -> FormatHelp
    | "--check" :: rest -> (
        match state with
        | FormatSourceState { mode; paths_rev } ->
            let mode =
              match mode with
              | FormatWrite -> FormatCheck { show_diff = false }
              | FormatCheck _ -> mode
            in
            loop (FormatSourceState { mode; paths_rev }) rest
        | FormatProgramJsonState _ ->
            FormatArgError "--emit-program-json cannot be combined with --check"
        )
    | "--diff" :: rest -> (
        match state with
        | FormatSourceState { paths_rev; _ } ->
            loop
              (FormatSourceState
                 { mode = FormatCheck { show_diff = true }; paths_rev })
              rest
        | FormatProgramJsonState _ ->
            FormatArgError "--emit-program-json cannot be combined with --diff")
    | "--emit-program-json" :: rest -> (
        match state with
        | FormatSourceState { mode = FormatWrite; paths_rev } ->
            loop (FormatProgramJsonState { paths_rev }) rest
        | FormatSourceState { mode = FormatCheck _; _ } ->
            FormatArgError
              "--emit-program-json cannot be combined with --check or --diff"
        | FormatProgramJsonState _ ->
            FormatArgError "--emit-program-json was specified more than once")
    | option :: _ when String.starts_with ~prefix:"-" option ->
        FormatArgError (Printf.sprintf "unknown format option: %s" option)
    | file :: rest -> loop (format_state_add_path file state) rest
  in
  loop (FormatSourceState { mode = FormatWrite; paths_rev = [] }) args

(** Recursively collect .brp files from paths (files or directories) *)
let rec collect_brp_files path =
  if Sys.is_directory path then
    let files = try Sys.readdir path with _ -> [||] in
    Array.to_list files |> List.sort String.compare
    |> List.map (fun f -> Filename.concat path f)
    |> List.map collect_brp_files |> List.flatten
  else if Filename.check_suffix path ".brp" then [ path ]
  else []

let expand_check_path path =
  if Sys.is_directory path then collect_brp_files path else [ path ]

let check_paths_with_opts opts paths =
  let files = List.concat_map expand_check_path paths in
  if files = [] then begin
    prerr_endline "Error: no .brp files found";
    1
  end
  else
    let multiple = match files with [ _ ] -> false | _ -> true in
    let failed = ref false in
    List.iter
      (fun file ->
        if multiple then Printf.printf "Checking %s\n" file;
        if check_file_with_opts opts file <> 0 then failed := true)
      files;
    if !failed then 1 else 0

(** Main entry point *)
let () =
  try
    let args = Array.to_list Sys.argv |> List.tl in

    match args with
    | [] ->
        usage ();
        exit 1
    | [ "--help" ] | [ "-h" ] ->
        usage ();
        exit 0
    | [ "--version" ] | [ "-v" ] ->
        Printf.printf "%s\n" (Version.describe ());
        exit 0
    | "lsp" :: rest -> (
        match parse_lsp_cli_args rest with
        | LspHelp ->
            lsp_usage ();
            exit 0
        | LspRun -> Lsp_server.run ()
        | LspArgError msg ->
            prerr_endline ("Error: " ^ msg);
            lsp_usage ();
            exit 1)
    | "repl" :: rest -> (
        match parse_repl_cli_args rest with
        | ReplHelp ->
            repl_usage ();
            exit 0
        | ReplRun { repl_debug } ->
            Repl.run ~debug:repl_debug;
            exit 0
        | ReplArgError msg ->
            prerr_endline ("Error: " ^ msg);
            repl_usage ();
            exit 1)
    | "format" :: rest ->
        let action = parse_format_cli_args rest in
        begin match action with
        | FormatHelp ->
            format_usage ();
            exit 0
        | FormatArgError msg ->
            Printf.eprintf "Error: %s\n" msg;
            exit 1
        | FormatEmitProgramJson filename -> (
            match Fmt.format_program_json_file filename with
            | Ok json ->
                print_endline json;
                exit 0
            | Error msg ->
                Printf.eprintf "%s: %s\n" filename msg;
                exit 1)
        | FormatFiles { mode; paths } ->
            let files = List.map collect_brp_files paths |> List.flatten in
            if files = [] then begin
              Printf.eprintf "Error: no .brp files found\n";
              exit 1
            end;
            let check, fmt_mode =
              match mode with
              | FormatWrite -> (false, Fmt.Write)
              | FormatCheck { show_diff } -> (true, Fmt.Check { show_diff })
            in
            begin match
              Fmt.format_files_with_blorp_renderer ~mode:fmt_mode files
            with
            | Error msg ->
                prerr_endline msg;
                exit 1
            | Ok results ->
                let had_error = ref false in
                List.iter
                  (fun result ->
                    match result with
                    | Fmt.Unchanged file when check ->
                        Printf.printf "%s: ok\n" file
                    | Fmt.WouldChange { file; diff } when check ->
                        Printf.printf "%s: needs formatting\n" file;
                        Option.iter print_string diff;
                        had_error := true
                    | Fmt.Unchanged _ | Fmt.Written _ | Fmt.WouldChange _ -> ())
                  results;
                if !had_error then exit 1
            end
        end
    | "check" :: rest -> (
        let rec parse_check_args args opts std_dir files =
          match args with
          | [] -> (opts, std_dir, List.rev files)
          | "--help" :: _ | "-h" :: _ ->
              print_endline "Usage: blorp check [options] <file.brp|dir> [...]";
              print_endline "";
              print_endline "Options:";
              print_endline
                "  --dump-ast                Print AST summary and continue \
                 checking";
              print_endline
                "  --dump-typed-ast          Print typed AST and continue \
                 checking";
              print_endline "  --debug                   Enable debug functions";
              print_endline "  --no-format               Skip auto-formatting";
              print_endline
                "  --std-dir <d>             Use std library from directory";
              print_endline "";
              print_endline
                "Accepts files or directories (recursively finds .brp files).";
              exit 0
          | "--dump-ast" :: rest ->
              parse_check_args rest { opts with dump_ast = true } std_dir files
          | "--dump-typed-ast" :: rest ->
              parse_check_args rest
                { opts with dump_typed_ast = true }
                std_dir files
          | "--debug" :: rest ->
              parse_check_args rest { opts with debug = true } std_dir files
          | "--no-format" :: rest ->
              parse_check_args rest { opts with no_format = true } std_dir files
          | "--std-dir" :: dir :: rest ->
              parse_check_args rest opts (Some dir) files
          | file :: rest -> parse_check_args rest opts std_dir (file :: files)
        in
        let base_opts = { default_compile_opts with no_emit = true } in
        let opts, std_dir, files = parse_check_args rest base_opts None [] in
        let opts = { opts with no_format = resolve_no_format opts.no_format } in
        (match std_dir with
        | Some dir -> Modules.set_std_override dir
        | None -> ());
        match files with
        | [] ->
            prerr_endline "Error: No input file specified";
            exit 1
        | paths -> exit (check_paths_with_opts opts paths))
    | "compile" :: rest -> (
        let parse_stage_arg flag value =
          match Blorp.Core_stage.of_string value with
          | Ok s -> s
          | Error msg ->
              Printf.eprintf "%s: %s\n" flag msg;
              exit 1
        in
        let parse_stage_list_arg flag value =
          match Blorp.Core_stage.of_string_list value with
          | Ok ss -> ss
          | Error msg ->
              Printf.eprintf "%s: %s\n" flag msg;
              exit 1
        in
        let split_eq s =
          match String.index_opt s '=' with
          | Some i ->
              Some
                ( String.sub s 0 i,
                  String.sub s (i + 1) (String.length s - i - 1) )
          | None -> None
        in
        let rec parse_compile_args args opts std_dir files =
          match args with
          | [] -> (opts, std_dir, List.rev files)
          | "--help" :: _ | "-h" :: _ ->
              print_endline "Usage: blorp compile [options] <file.brp>";
              print_endline "";
              print_endline "Options:";
              print_endline
                "  --ast                     Print AST and exit (no typecheck, \
                 no emit)";
              print_endline
                "  --dump-ast                Print AST summary and continue \
                 compiling";
              print_endline
                "  --dump-typed-ast          Print typed AST and continue \
                 compiling";
              print_endline
                "  --dump-core               Dump Core IR at the final stage";
              print_endline "  --dump-core-after=STAGE[,STAGE…]";
              print_endline
                "                            Dump Core IR after the given \
                 stage(s);";
              print_endline
                "                            repeatable and comma-separated \
                 both work";
              print_endline
                "  --dump-core-file=PATH     Redirect --dump-core output to \
                 PATH";
              print_endline
                "  --stop-after=STAGE        Stop after the given stage \
                 (implies no emit)";
              print_endline
                "                            STAGE: lower, debug, desugar, \
                 mono, synth, match,";
              print_endline
                "                                   trait_resolve, resolve, \
                 std_inline, tailrec, fusion,";
              print_endline
                "                                   specialize, dce, perceus, \
                 reuse, closure, final";
              print_endline
                "  --time-phases             Print per-phase compiler wall \
                 time to stderr";
              print_endline
                "  --check-invariants        Run post-stage IR invariant \
                 checks (slower; use for debugging)";
              print_endline "  --debug                   Enable debug functions";
              print_endline "  --no-format               Skip auto-formatting";
              print_endline
                "  --no-embed-runtime        Emit C that expects an external \
                 runtime declaration/header";
              print_endline
                "  --std-dir <d>             Use std library from directory";
              print_endline "  -o <file>                 Output C file path";
              exit 0
          | "--no-emit" :: rest ->
              prerr_endline
                "Warning: 'blorp compile --no-emit' is deprecated, use 'blorp \
                 check <file.brp>'";
              parse_compile_args rest { opts with no_emit = true } std_dir files
          | "--check" :: rest ->
              prerr_endline
                "Warning: 'blorp compile --check' is deprecated, use 'blorp \
                 check <file.brp>'";
              parse_compile_args rest { opts with no_emit = true } std_dir files
          | "--ast" :: rest ->
              parse_compile_args rest
                { opts with ast_only = true }
                std_dir files
          | "--dump-ast" :: rest ->
              parse_compile_args rest
                { opts with dump_ast = true }
                std_dir files
          | "--dump-typed-ast" :: rest ->
              parse_compile_args rest
                { opts with dump_typed_ast = true }
                std_dir files
          | "--dump-core" :: rest ->
              parse_compile_args rest
                {
                  opts with
                  dump_core_after =
                    Blorp.Core_stage.Final :: opts.dump_core_after;
                }
                std_dir files
          | arg :: rest
            when match split_eq arg with
                 | Some ("--dump-core-after", _) -> true
                 | _ -> false ->
              let _, v = Option.get (split_eq arg) in
              let ss = parse_stage_list_arg "--dump-core-after" v in
              parse_compile_args rest
                { opts with dump_core_after = opts.dump_core_after @ ss }
                std_dir files
          | "--dump-core-after" :: v :: rest ->
              let ss = parse_stage_list_arg "--dump-core-after" v in
              parse_compile_args rest
                { opts with dump_core_after = opts.dump_core_after @ ss }
                std_dir files
          | arg :: rest
            when match split_eq arg with
                 | Some ("--stop-after", _) -> true
                 | _ -> false ->
              let _, v = Option.get (split_eq arg) in
              let s = parse_stage_arg "--stop-after" v in
              parse_compile_args rest
                { opts with stop_after = Some s }
                std_dir files
          | "--stop-after" :: v :: rest ->
              let s = parse_stage_arg "--stop-after" v in
              parse_compile_args rest
                { opts with stop_after = Some s }
                std_dir files
          | arg :: rest
            when match split_eq arg with
                 | Some ("--dump-core-file", _) -> true
                 | _ -> false ->
              let _, v = Option.get (split_eq arg) in
              parse_compile_args rest
                { opts with dump_file = Some v }
                std_dir files
          | "--dump-core-file" :: v :: rest ->
              parse_compile_args rest
                { opts with dump_file = Some v }
                std_dir files
          | "--time-phases" :: rest ->
              parse_compile_args rest
                { opts with time_phases = true }
                std_dir files
          | "--check-invariants" :: rest ->
              parse_compile_args rest
                { opts with check_invariants = true }
                std_dir files
          | "--profile" :: rest ->
              prerr_endline
                "Warning: --profile on 'compile' is deprecated — use \
                 --time-phases. ('blorp run --profile' is unchanged and times \
                 the generated program.)";
              parse_compile_args rest
                { opts with time_phases = true }
                std_dir files
          | "--debug" :: rest ->
              parse_compile_args rest { opts with debug = true } std_dir files
          | "--no-format" :: rest ->
              parse_compile_args rest
                { opts with no_format = true }
                std_dir files
          | "--no-embed-runtime" :: rest ->
              parse_compile_args rest
                { opts with embed_runtime = false }
                std_dir files
          | "--core-emit" :: rest ->
              prerr_endline
                "Warning: --core-emit is deprecated (core-emit is the only \
                 pipeline)";
              parse_compile_args rest opts std_dir files
          | "--std-dir" :: dir :: rest ->
              parse_compile_args rest opts (Some dir) files
          | "-o" :: o :: rest ->
              parse_compile_args rest
                { opts with output = Some o }
                std_dir files
          | file :: rest -> parse_compile_args rest opts std_dir (file :: files)
        in
        let opts, std_dir, files =
          parse_compile_args rest default_compile_opts None []
        in
        (* --stop-after=S auto-enables --dump-core-after=S unless the user
         asked for a different dump target. The 95% case: if you're
         stopping the pipeline, you want to see what got produced. *)
        let opts =
          match (opts.stop_after, opts.dump_core_after) with
          | Some s, [] -> { opts with dump_core_after = [ s ] }
          | _ -> opts
        in
        let opts = { opts with no_format = resolve_no_format opts.no_format } in
        (match std_dir with
        | Some dir -> Modules.set_std_override dir
        | None -> ());
        match files with
        | [ file ] -> exit (compile_file_with_opts opts file)
        | [] ->
            prerr_endline "Error: No input file specified";
            exit 1
        | _ ->
            prerr_endline "Error: Multiple input files not supported";
            exit 1)
    | "run" :: rest -> (
        let rec parse_run_args args profile debug sanitize leak_check release
            no_format timeout threads std_dir files user_args =
          match args with
          | [] ->
              ( profile,
                debug,
                sanitize,
                leak_check,
                release,
                no_format,
                timeout,
                threads,
                std_dir,
                List.rev files,
                List.rev user_args )
          | "--help" :: _ | "-h" :: _ ->
              print_endline "Usage: blorp run [options] <file.brp> [-- args...]";
              print_endline "";
              print_endline "Options:";
              print_endline "  --profile      Run with profiling";
              print_endline "  --release      Compile generated C with -O2";
              print_endline "  --debug        Enable debug functions";
              print_endline
                "  --sanitize     Compile with AddressSanitizer + UBSan";
              print_endline "  --leak-check   Report leaked objects on exit";
              print_endline "  --no-format    Skip auto-formatting";
              print_endline "  --timeout N    Kill after N seconds";
              print_endline "  --threads N    Set max thread pool size";
              print_endline "  --std-dir <d>  Use std library from directory";
              exit 0
          | "--" :: rest ->
              ( profile,
                debug,
                sanitize,
                leak_check,
                release,
                no_format,
                timeout,
                threads,
                std_dir,
                List.rev files,
                rest )
          | "--profile" :: rest ->
              parse_run_args rest true debug sanitize leak_check release
                no_format timeout threads std_dir files user_args
          | "--release" :: rest ->
              parse_run_args rest profile debug sanitize leak_check true
                no_format timeout threads std_dir files user_args
          | "--debug" :: rest ->
              parse_run_args rest profile true sanitize leak_check release
                no_format timeout threads std_dir files user_args
          | "--sanitize" :: rest ->
              parse_run_args rest profile debug true leak_check release
                no_format timeout threads std_dir files user_args
          | "--leak-check" :: rest ->
              parse_run_args rest profile debug sanitize true release no_format
                timeout threads std_dir files user_args
          | "--no-format" :: rest ->
              parse_run_args rest profile debug sanitize leak_check release true
                timeout threads std_dir files user_args
          | "--std-dir" :: dir :: rest ->
              parse_run_args rest profile debug sanitize leak_check release
                no_format timeout threads (Some dir) files user_args
          | "--timeout" :: n :: rest -> (
              match int_of_string_opt n with
              | Some v ->
                  parse_run_args rest profile debug sanitize leak_check release
                    no_format (Some v) threads std_dir files user_args
              | None ->
                  prerr_endline "Error: --timeout requires an integer";
                  exit 1)
          | "--threads" :: n :: rest -> (
              match int_of_string_opt n with
              | Some v ->
                  parse_run_args rest profile debug sanitize leak_check release
                    no_format timeout (Some v) std_dir files user_args
              | None ->
                  prerr_endline "Error: --threads requires an integer";
                  exit 1)
          | file :: rest ->
              parse_run_args rest profile debug sanitize leak_check release
                no_format timeout threads std_dir (file :: files) user_args
        in
        let ( profile,
              debug,
              cli_sanitize,
              cli_leak_check,
              cli_release,
              cli_no_format,
              cli_timeout,
              cli_threads,
              std_dir,
              files,
              user_args ) =
          parse_run_args rest false false false false false false None None None
            [] []
        in
        let timeout = resolve_timeout cli_timeout in
        let sanitize = resolve_sanitize cli_sanitize in
        let leak_check = resolve_leak_check cli_leak_check in
        let no_format = resolve_no_format cli_no_format in
        let run_mode =
          if cli_release then Compile_profile.Release else Compile_profile.Fast
        in
        (match std_dir with
        | Some dir -> Modules.set_std_override dir
        | None -> ());
        (match cli_threads with
        | Some n -> Unix.putenv "BLORP_THREADS" (string_of_int n)
        | None -> ());
        match files with
        | [ file ] ->
            exit
              (run_file ~profile ~debug ~sanitize ~leak_check ~timeout ~run_mode
                 ~no_format ~user_args file)
        | [] ->
            prerr_endline "Error: No input file specified";
            exit 1
        | _ ->
            prerr_endline "Error: Multiple input files not supported";
            exit 1)
    | "test" :: rest -> (
        let rec parse_test_args args profile debug sanitize leak_check no_format
            timeout jobs repeat mode cache std_dir paths =
          match args with
          | [] ->
              ( profile,
                debug,
                sanitize,
                leak_check,
                no_format,
                timeout,
                jobs,
                repeat,
                mode,
                cache,
                std_dir,
                List.rev paths )
          | "--help" :: _ | "-h" :: _ ->
              print_endline
                "Usage: blorp test [options] <file.brp | directory> ...";
              print_endline "";
              print_endline "Options:";
              print_endline "  --profile      Run with profiling";
              print_endline "  --debug        Enable debug functions";
              print_endline "  --sanitize     Run with AddressSanitizer + UBSan";
              print_endline "  --leak-check   Report leaked objects on exit";
              print_endline
                "  --timeout N    Kill each test after N seconds (default: \
                 BLORP_TEST_TIMEOUT, BLORP_TIMEOUT, or 30; 0 disables)";
              print_endline
                "  --repeat N     Run selected tests N times; disables result \
                 caching for this run";
              print_endline "  -j N           Run tests with N parallel workers";
              print_endline "  --doc          Run only doctests";
              print_endline "  --suite        Run only TestSuite tests";
              print_endline "  --no-format    Skip auto-formatting before test";
              print_endline "  --no-cache     Disable test result caching";
              print_endline "  --std-dir <d>  Use std library from directory";
              exit 0
          | "--profile" :: rest ->
              parse_test_args rest true debug sanitize leak_check no_format
                timeout jobs repeat mode cache std_dir paths
          | "--debug" :: rest ->
              parse_test_args rest profile true sanitize leak_check no_format
                timeout jobs repeat mode cache std_dir paths
          | "--sanitize" :: rest ->
              parse_test_args rest profile debug true leak_check no_format
                timeout jobs repeat mode cache std_dir paths
          | "--leak-check" :: rest ->
              parse_test_args rest profile debug sanitize true no_format timeout
                jobs repeat mode cache std_dir paths
          | "--no-cache" :: rest ->
              parse_test_args rest profile debug sanitize leak_check no_format
                timeout jobs repeat mode false std_dir paths
          | "--no-format" :: rest ->
              parse_test_args rest profile debug sanitize leak_check true
                timeout jobs repeat mode cache std_dir paths
          | "--batch" :: _ ->
              prerr_endline
                "Error: --batch has been removed; blorp test now chooses the \
                 fast test path automatically.";
              exit 1
          | "--warmup-only" :: _ ->
              (* Pre-warm the precompiled runtime cache, then exit *)
              Test_runner.with_run_artifacts (fun () ->
                  ignore (Test_runner.precompile_runtime ()));
              exit 0
          | "--doc" :: rest ->
              parse_test_args rest profile debug sanitize leak_check no_format
                timeout jobs repeat Test_runner.DocOnly cache std_dir paths
          | "--suite" :: rest ->
              parse_test_args rest profile debug sanitize leak_check no_format
                timeout jobs repeat Test_runner.SuiteOnly cache std_dir paths
          | "--std-dir" :: dir :: rest ->
              parse_test_args rest profile debug sanitize leak_check no_format
                timeout jobs repeat mode cache (Some dir) paths
          | "--timeout" :: n :: rest -> (
              match int_of_string_opt n with
              | Some v ->
                  parse_test_args rest profile debug sanitize leak_check
                    no_format (Some v) jobs repeat mode cache std_dir paths
              | None ->
                  prerr_endline "Error: --timeout requires an integer";
                  exit 1)
          | [ "--repeat" ] ->
              prerr_endline "Error: --repeat requires a value";
              exit 1
          | "--repeat" :: n :: rest -> (
              match int_of_string_opt n with
              | Some v when v > 0 ->
                  parse_test_args rest profile debug sanitize leak_check
                    no_format timeout jobs v mode cache std_dir paths
              | _ ->
                  prerr_endline "Error: --repeat requires a positive integer";
                  exit 1)
          | [ "-j" ] ->
              prerr_endline "Error: -j requires a value";
              exit 1
          | "-j" :: n :: rest -> (
              match int_of_string_opt n with
              | Some v ->
                  parse_test_args rest profile debug sanitize leak_check
                    no_format timeout v repeat mode cache std_dir paths
              | None ->
                  prerr_endline "Error: -j requires an integer";
                  exit 1)
          | path :: rest ->
              parse_test_args rest profile debug sanitize leak_check no_format
                timeout jobs repeat mode cache std_dir (path :: paths)
        in
        let ( profile,
              debug,
              cli_sanitize,
              cli_leak_check,
              cli_no_format,
              cli_timeout,
              jobs,
              repeat,
              mode,
              cache,
              std_dir,
              paths ) =
          parse_test_args rest false false false false false None 0 1
            Test_runner.TestAll true None []
        in
        let timeout =
          match resolve_test_timeout cli_timeout with
          | Some _ as timeout -> timeout
          | None -> Some 30
        in
        let sanitize = resolve_sanitize cli_sanitize in
        let leak_check = resolve_leak_check cli_leak_check in
        let no_format = resolve_no_format cli_no_format in
        (* Auto-format test files before running *)
        if not no_format then
          List.iter
            (fun path ->
              if Sys.is_directory path then
                Array.iter
                  (fun f ->
                    if Filename.check_suffix f ".brp" then
                      auto_format_user_file (Filename.concat path f))
                  (Sys.readdir path)
              else auto_format_user_file path)
            paths;
        (match std_dir with
        | Some dir -> Modules.set_std_override dir
        | None -> ());
        match paths with
        | [ path ] ->
            exit
              (Test_runner.run_tests ~profile ~debug ~sanitize ~leak_check ~mode
                 ~timeout ~jobs ~cache ~repeat path)
        | [] ->
            prerr_endline "Error: No test path specified";
            exit 1
        | _ ->
            exit
              (Test_runner.run_tests_paths ~profile ~debug ~sanitize ~leak_check
                 ~mode ~timeout ~jobs ~cache ~repeat paths))
    | "purify" :: rest -> (
        let rec parse_purify_args args dry_run verbose files =
          match args with
          | [] -> (dry_run, verbose, List.rev files)
          | "--help" :: _ | "-h" :: _ ->
              print_endline "Usage: blorp purify [options] <file.brp|dir>";
              print_endline "";
              print_endline "Options:";
              print_endline
                "  --dry-run      Show which functions would be purified \
                 without modifying the file";
              print_endline
                "  --verbose, -v  Show detailed purification progress";
              exit 0
          | "--dry-run" :: rest -> parse_purify_args rest true verbose files
          | "--verbose" :: rest | "-v" :: rest ->
              parse_purify_args rest dry_run true files
          | file :: rest ->
              parse_purify_args rest dry_run verbose (file :: files)
        in
        let dry_run, verbose, paths = parse_purify_args rest false false [] in
        let all_files = List.map collect_brp_files paths |> List.flatten in
        match all_files with
        | [] ->
            prerr_endline "Error: No input files specified";
            exit 1
        | files ->
            let results = List.map (purify_file ~dry_run ~verbose) files in
            let total_purified =
              List.fold_left (fun acc r -> acc + max 0 r) 0 results
            in
            let files_modified =
              List.filter (fun r -> r > 0) results |> List.length
            in
            if
              (not dry_run)
              && (files_modified > 1
                 || (files_modified = 1 && List.length files > 1))
            then
              Printf.printf
                "Total: Purified %d function(s) across %d file(s).\n"
                total_purified files_modified;
            let exit_code =
              if List.exists (fun r -> r < 0) results then 1 else 0
            in
            exit exit_code)
    | _ ->
        prerr_endline "Error: Unknown command";
        usage ();
        exit 1
  with
  | Sys_error msg ->
      Printf.eprintf "Error: %s\n" msg;
      exit 1
  | Failure msg ->
      Printf.eprintf "Internal error: %s\n" msg;
      exit 1
  | exn ->
      Printf.eprintf
        "Internal compiler error: %s\nThis is a bug in the blorp compiler.\n"
        (Printexc.to_string exn);
      exit 2
