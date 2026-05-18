(** blorp CLI - Unified command-line interface

    Usage:
      blorp compile program.brp          # Compile to C and binary
      blorp check program.brp            # Type check only
      blorp compile --ast program.brp    # Show AST only
      blorp run program.brp arg1 arg2    # Compile and run with arguments
      blorp run --profile program.brp    # Run with profiling
      blorp check src/                   # Type check all .brp files in directory
      blorp test tests/test.brp          # Run a single test
      blorp test tests/                  # Run all tests in directory
      blorp purify program.brp           # Automatically mark pure functions
*)

open Blorp

let version = Version.version
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
  let tailrec_str = if func.Ast.func_is_tailrec then " [@tailrec]" else "" in
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
  | Ast.DNewType n -> Printf.sprintf "NewType %s" n.Ast.new_type_name

let program_to_string prog = String.concat "\n" (List.map decl_to_string prog)

let removed_compile_option flag replacement =
  Printf.eprintf "Error: '%s' has been removed; use '%s'.\n" flag replacement;
  exit 1

let write_file_atomic filename contents =
  let dir = Filename.dirname filename in
  let base = Filename.basename filename in
  let mode = try (Unix.stat filename).Unix.st_perm with _ -> 0o644 in
  let tmp, oc =
    Filename.open_temp_file ~temp_dir:dir ("." ^ base ^ ".") ".tmp"
  in
  let closed = ref false in
  let close () =
    if not !closed then begin
      closed := true;
      close_out oc
    end
  in
  try
    output_string oc contents;
    close ();
    Unix.chmod tmp mode;
    Unix.rename tmp filename
  with exn ->
    if not !closed then close_out_noerr oc;
    (try Sys.remove tmp with _ -> ());
    raise exn

(** Auto-format a .brp file in place before compilation.
    Uses the format cache to skip already-formatted files.
    Does NOT format std library files. *)
let auto_format_user_file filename =
  (* Skip std library files *)
  let abs = try Unix.realpath filename with _ -> filename in
  let is_std =
    try
      let std_dir = Unix.realpath (Filename.concat (Sys.getcwd ()) "std") in
      String.length abs >= String.length std_dir
      && String.sub abs 0 (String.length std_dir) = std_dir
    with _ -> false
  in
  if not is_std then Fmt.auto_format filename

(** Purify a file by automatically marking eligible functions as 'pure'.
    Repeats up to 5 times to catch newly eligible functions. *)
let purify_file ?(dry_run = false) ?(verbose = false) filename =
  let total_purified = ref 0 in
  let rec iterate count =
    if count >= 5 then begin
      if not dry_run then
        Printf.printf "Reached maximum purification iterations (5) for %s.\n"
          filename;
      !total_purified
    end
    else begin
      let source = read_file filename in
      match Pipeline.typecheck_module_only ~filename ~source with
      | Error errors ->
          prerr_endline (format_pipeline_errors ~file:filename errors);
          -1
      | Ok (state, program) ->
          let env = Typecheck.get_state_env state in
          let module_aliases = Typecheck.get_state_module_aliases state in
          let purifiable = ref [] in

          let is_purifiable (func : Ast.func_decl) =
            if
              func.Ast.func_is_pure
              || Ast.func_has_builtin_body func
              || Ast.func_is_foreign func
            then false
            else
              match func.Ast.func_body with
              | Ast.FuncNoBody | Ast.FuncBuiltinBody _ | Ast.FuncForeign _ ->
                  false
              | Ast.FuncBodyExpr body ->
                  (* Reject functions that take non-pure callback parameters.
                   Calling a non-pure callback is inherently impure — the function
                   cannot be pure regardless of its body. *)
                  let has_impure_callback_param =
                    List.exists
                      (fun (p : Ast.param) ->
                        match p.Ast.param_type with
                        | Some ty -> Env.is_impure_function_type env ty
                        | _ -> false)
                      func.Ast.func_params
                  in
                  if has_impure_callback_param then false
                  else begin
                    (* To handle recursion, we assume the function itself is pure during body analysis *)
                    let test_env =
                      match func.Ast.func_name with
                      | Some name -> (
                          match Env.get_func_info env name with
                          | Some (ty, params, _) ->
                              Env.add_func env name ty ~type_params:params
                                ~purity:Env.Pure ()
                          | None -> env)
                      | None -> env
                    in
                    (* Build env with function params so collect_impure_calls can check them *)
                    let test_env =
                      List.fold_left
                        (fun acc (p : Ast.param) ->
                          match (p.Ast.param_name, p.Ast.param_type) with
                          | Some name, Some ty -> Env.add_var acc name ty ()
                          | _ -> acc)
                        test_env func.Ast.func_params
                    in
                    let impure_calls =
                      Typecheck.collect_impure_calls ~strict:true test_env
                        module_aliases body
                    in
                    if impure_calls <> [] then
                      false
                      (* Reject functions with concurrent:/concurrent for (spawns threads) *)
                    else if Typecheck.has_concurrency body then false
                    else true
                  end
          in

          (* Find functions to purify *)
          let rec find_decls = function
            | [] -> ()
            | decl :: rest ->
                (match decl.Ast.decl_desc with
                | Ast.DFunc f ->
                    if is_purifiable f then purifiable := f :: !purifiable
                | _ -> ());
                find_decls rest
          in
          find_decls program;

          if !purifiable = [] then begin
            if count = 0 then (
              if verbose then
                Printf.printf "No functions to purify in %s.\n" filename)
            else if not dry_run then
              if verbose then
                Printf.printf
                  "Purification complete after %d iterations for %s.\n" count
                  filename
              else
                Printf.printf "Purified %d function(s) in %s\n" !total_purified
                  filename;
            !total_purified
          end
          else begin
            let names =
              List.filter_map (fun f -> f.Ast.func_name) !purifiable
            in
            total_purified := !total_purified + List.length !purifiable;
            if dry_run then begin
              Printf.printf
                "[DRY-RUN] Iteration %d: Functions that could be purified in \
                 %s: %s\n"
                (count + 1) filename
                (String.concat ", " (List.rev names));
              !total_purified
              (* Stop after one iteration in dry-run to avoid confusing output *)
            end
            else begin
              if verbose then
                Printf.printf
                  "Iteration %d: Purifying %d function(s) in %s: %s\n"
                  (count + 1) (List.length !purifiable) filename
                  (String.concat ", " (List.rev names));

              (* Apply purification to AST *)
              let purify_func f =
                if
                  List.exists
                    (fun p -> p.Ast.func_name = f.Ast.func_name)
                    !purifiable
                then { f with Ast.func_is_pure = true }
                else f
              in
              let new_program =
                List.map
                  (fun decl ->
                    match decl.Ast.decl_desc with
                    | Ast.DFunc f ->
                        { decl with decl_desc = Ast.DFunc (purify_func f) }
                    | Ast.DPrivate ({ Ast.decl_desc = Ast.DFunc f; _ } as d) ->
                        {
                          decl with
                          decl_desc =
                            Ast.DPrivate
                              { d with decl_desc = Ast.DFunc (purify_func f) };
                        }
                    | _ -> decl)
                  program
              in

              (* Generate new source using the formatter's printer *)
              let doc = Fmt_printer.print_program new_program in
              let formatted = Fmt_layout.layout doc in

              write_file_atomic filename formatted;

              iterate (count + 1)
            end
          end
    end
  in
  iterate 0

type compile_opts = {
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
  check_invariants : bool;  (** --check-invariants *)
}
(** Options for the [compile] subcommand. *)

let default_compile_opts =
  {
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

(** Best-effort short git SHA for dump provenance. Returns
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
    path compiled, used only for the dump header. The returned [cleanup]
    must be called on every exit path; callers typically wrap their compile
    invocation in [Fun.protect ~finally:obs.cleanup]. *)
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
              Printf.eprintf "stopped after %s\n" (Blorp.Core_stage.to_string s);
              0
          | Ok (Pipeline.Compiled { typed_program; c_code; _ }) ->
              if opts.dump_typed_ast then
                print_endline (Typed_ast_debug.format_program typed_program);
              let base = Filename.remove_extension filename in
              let c_file =
                match opts.output with Some o -> o | None -> base ^ ".c"
              in
              write_file_atomic c_file c_code;
              Printf.printf "Generated %s\n" c_file;
              0
        in
        print_profile ();
        result)

(** Compile and run a blorp file *)
let run_file ?(profile = false) ?(debug = false) ?(sanitize = false)
    ?(leak_check = false) ~timeout ?(no_format = false) ?(user_args = [])
    filename =
  Test_runner.with_run_artifacts (fun () ->
      if not no_format then auto_format_user_file filename;
      let source = read_file filename in
      init_module_paths (extract_directory filename);
      let opt = if sanitize then "O0" else "O2" in
      let precompiled =
        Test_runner.precompile_runtime ~sanitize ~leak_check ~opt ()
      in
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
            @ (if leak_check then [ "-DBLORP_RUNTIME_LEAK_CHECK_STRICT=1" ]
               else [])
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
            @ List.concat_map
                (fun s -> String.split_on_char ' ' (String.trim s))
                link_flags
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
            let run_child () =
              Test_runner.run_process_timeout ~timeout bin_file user_args
            in
            let result =
              if sanitize then Test_runner.with_sanitizer_runtime_env run_child
              else run_child ()
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
    "  BLORP_THREADS=N      Override generated-program worker threads"

type repl_cli_action =
  | ReplHelp
  | ReplRun of { repl_debug : bool }
  | ReplArgError of string

type lsp_cli_action = LspHelp | LspRun | LspArgError of string

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
        Printf.printf "blorp %s (OCaml)\n" version;
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
        let rec parse_format_args args check diff files =
          match args with
          | [] -> (check, diff, List.rev files)
          | "--help" :: _ | "-h" :: _ ->
              print_endline "Usage: blorp format [options] <file.brp|dir>";
              print_endline "";
              print_endline "Options:";
              print_endline
                "  --check        Check if file is formatted (exit 1 if not)";
              print_endline
                "  --diff         Show diff for unformatted files (with \
                 --check)";
              print_endline "";
              print_endline
                "Accepts files or directories (recursively finds .brp files).";
              exit 0
          | "--check" :: rest -> parse_format_args rest true diff files
          | "--diff" :: rest -> parse_format_args rest check true files
          | file :: rest -> parse_format_args rest check diff (file :: files)
        in
        let check, diff, paths = parse_format_args rest false false [] in
        if paths = [] then begin
          Printf.eprintf
            "Error: no files specified. Usage: blorp format [--check] \
             <file.brp|dir>\n";
          exit 1
        end;
        let files = List.map collect_brp_files paths |> List.flatten in
        if files = [] then begin
          Printf.eprintf "Error: no .brp files found\n";
          exit 1
        end;
        let had_error = ref false in
        List.iter
          (fun filename ->
            if check && diff then
              begin match Fmt.format_check_diff filename with
              | Ok None -> Printf.printf "%s: ok\n" filename
              | Ok (Some diff_text) ->
                  Printf.printf "%s: needs formatting\n%s" filename diff_text;
                  had_error := true
              | Error msg ->
                  Printf.eprintf "%s: %s\n" filename msg;
                  had_error := true
              end
            else
              begin match Fmt.format_file ~check filename with
              | Ok true -> if check then Printf.printf "%s: ok\n" filename
              | Ok false ->
                  Printf.printf "%s: needs formatting\n" filename;
                  had_error := true
              | Error msg ->
                  Printf.eprintf "%s: %s\n" filename msg;
                  had_error := true
              end)
          files;
        if !had_error then exit 1
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
        let opts, std_dir, files =
          parse_check_args rest default_compile_opts None []
        in
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
                "                            STAGE: lower, desugar, mono, \
                 synth, match,";
              print_endline
                "                                   trait_resolve, resolve, \
                 tailrec, fusion,";
              print_endline
                "                                   specialize, perceus, \
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
          | "--no-emit" :: _ ->
              removed_compile_option "blorp compile --no-emit"
                "blorp check <file.brp>"
          | "--check" :: _ ->
              removed_compile_option "blorp compile --check"
                "blorp check <file.brp>"
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
          | "--profile" :: _ ->
              removed_compile_option "blorp compile --profile"
                "blorp compile --time-phases <file.brp>"
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
          | "--core-emit" :: _ ->
              removed_compile_option "blorp compile --core-emit"
                "blorp compile <file.brp>"
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
        let rec parse_run_args args profile debug sanitize leak_check no_format
            timeout threads std_dir files user_args =
          match args with
          | [] ->
              ( profile,
                debug,
                sanitize,
                leak_check,
                no_format,
                timeout,
                threads,
                std_dir,
                List.rev files,
                List.rev user_args )
          | "--help" :: _ | "-h" :: _ ->
              print_endline "Usage: blorp run [options] <file.brp> [args...]";
              print_endline "";
              print_endline
                "Arguments after <file.brp> are passed to the program. Put \
                 blorp run options before the file.";
              print_endline "";
              print_endline "Options:";
              print_endline "  --profile      Run with profiling";
              print_endline "  --debug        Enable debug functions";
              print_endline
                "  --sanitize     Compile with AddressSanitizer + UBSan";
              print_endline "  --leak-check   Report leaked objects on exit";
              print_endline "  --no-format    Skip auto-formatting";
              print_endline "  --timeout N    Kill after N seconds";
              print_endline "  --threads N    Set max thread pool size";
              print_endline "  --std-dir <d>  Use std library from directory";
              exit 0
          | "--" :: file :: rest when files = [] ->
              ( profile,
                debug,
                sanitize,
                leak_check,
                no_format,
                timeout,
                threads,
                std_dir,
                [ file ],
                rest )
          | "--" :: rest ->
              ( profile,
                debug,
                sanitize,
                leak_check,
                no_format,
                timeout,
                threads,
                std_dir,
                List.rev files,
                rest )
          | "--profile" :: rest ->
              parse_run_args rest true debug sanitize leak_check no_format
                timeout threads std_dir files user_args
          | "--debug" :: rest ->
              parse_run_args rest profile true sanitize leak_check no_format
                timeout threads std_dir files user_args
          | "--sanitize" :: rest ->
              parse_run_args rest profile debug true leak_check no_format
                timeout threads std_dir files user_args
          | "--leak-check" :: rest ->
              parse_run_args rest profile debug sanitize true no_format timeout
                threads std_dir files user_args
          | "--no-format" :: rest ->
              parse_run_args rest profile debug sanitize leak_check true timeout
                threads std_dir files user_args
          | "--std-dir" :: dir :: rest ->
              parse_run_args rest profile debug sanitize leak_check no_format
                timeout threads (Some dir) files user_args
          | "--timeout" :: n :: rest -> (
              match int_of_string_opt n with
              | Some v ->
                  parse_run_args rest profile debug sanitize leak_check
                    no_format (Some v) threads std_dir files user_args
              | None ->
                  prerr_endline "Error: --timeout requires an integer";
                  exit 1)
          | "--threads" :: n :: rest -> (
              match int_of_string_opt n with
              | Some v ->
                  parse_run_args rest profile debug sanitize leak_check
                    no_format timeout (Some v) std_dir files user_args
              | None ->
                  prerr_endline "Error: --threads requires an integer";
                  exit 1)
          | file :: rest ->
              let user_args =
                match rest with "--" :: args -> args | args -> args
              in
              ( profile,
                debug,
                sanitize,
                leak_check,
                no_format,
                timeout,
                threads,
                std_dir,
                [ file ],
                user_args )
        in
        let ( profile,
              debug,
              cli_sanitize,
              cli_leak_check,
              cli_no_format,
              cli_timeout,
              cli_threads,
              std_dir,
              files,
              user_args ) =
          parse_run_args rest false false false false false None None None [] []
        in
        let timeout = cli_timeout in
        let sanitize = cli_sanitize in
        let leak_check = cli_leak_check in
        let no_format = cli_no_format in
        (match std_dir with
        | Some dir -> Modules.set_std_override dir
        | None -> ());
        (match cli_threads with
        | Some n -> Unix.putenv "BLORP_THREADS" (string_of_int n)
        | None -> ());
        match files with
        | [ file ] ->
            exit
              (run_file ~profile ~debug ~sanitize ~leak_check ~timeout
                 ~no_format ~user_args file)
        | [] ->
            prerr_endline "Error: No input file specified";
            exit 1
        | _ ->
            prerr_endline "Error: Multiple input files not supported";
            exit 1)
    | "test" :: rest -> (
        let rec parse_test_args args profile debug sanitize leak_check no_format
            timeout jobs mode cache std_dir paths =
          match args with
          | [] ->
              ( profile,
                debug,
                sanitize,
                leak_check,
                no_format,
                timeout,
                jobs,
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
                "  --timeout N    Kill each test after N seconds (default: 30, \
                 0 disables)";
              print_endline "  -j N           Run tests with N parallel workers";
              print_endline "  --doc          Run only doctests";
              print_endline "  --suite        Run only TestSuite tests";
              print_endline "  --no-format    Skip auto-formatting before test";
              print_endline "  --no-cache     Disable test result caching";
              print_endline "  --std-dir <d>  Use std library from directory";
              exit 0
          | "--profile" :: rest ->
              parse_test_args rest true debug sanitize leak_check no_format
                timeout jobs mode cache std_dir paths
          | "--debug" :: rest ->
              parse_test_args rest profile true sanitize leak_check no_format
                timeout jobs mode cache std_dir paths
          | "--sanitize" :: rest ->
              parse_test_args rest profile debug true leak_check no_format
                timeout jobs mode cache std_dir paths
          | "--leak-check" :: rest ->
              parse_test_args rest profile debug sanitize true no_format timeout
                jobs mode cache std_dir paths
          | "--no-cache" :: rest ->
              parse_test_args rest profile debug sanitize leak_check no_format
                timeout jobs mode false std_dir paths
          | "--no-format" :: rest ->
              parse_test_args rest profile debug sanitize leak_check true
                timeout jobs mode cache std_dir paths
          | "--doc" :: rest ->
              parse_test_args rest profile debug sanitize leak_check no_format
                timeout jobs Test_runner.DocOnly cache std_dir paths
          | "--suite" :: rest ->
              parse_test_args rest profile debug sanitize leak_check no_format
                timeout jobs Test_runner.SuiteOnly cache std_dir paths
          | "--std-dir" :: dir :: rest ->
              parse_test_args rest profile debug sanitize leak_check no_format
                timeout jobs mode cache (Some dir) paths
          | "--timeout" :: n :: rest -> (
              match int_of_string_opt n with
              | Some v ->
                  parse_test_args rest profile debug sanitize leak_check
                    no_format (Some v) jobs mode cache std_dir paths
              | None ->
                  prerr_endline "Error: --timeout requires an integer";
                  exit 1)
          | [ "-j" ] ->
              prerr_endline "Error: -j requires a value";
              exit 1
          | "-j" :: n :: rest -> (
              match int_of_string_opt n with
              | Some v ->
                  parse_test_args rest profile debug sanitize leak_check
                    no_format timeout v mode cache std_dir paths
              | None ->
                  prerr_endline "Error: -j requires an integer";
                  exit 1)
          | path :: rest ->
              parse_test_args rest profile debug sanitize leak_check no_format
                timeout jobs mode cache std_dir (path :: paths)
        in
        let ( profile,
              debug,
              cli_sanitize,
              cli_leak_check,
              cli_no_format,
              cli_timeout,
              jobs,
              mode,
              cache,
              std_dir,
              paths ) =
          parse_test_args rest false false false false false None 0
            Test_runner.TestAll true None []
        in
        let timeout =
          match cli_timeout with
          | Some _ as timeout -> timeout
          | None -> Some 30
        in
        let sanitize = cli_sanitize in
        let leak_check = cli_leak_check in
        let no_format = cli_no_format in
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
                 ~timeout ~jobs ~cache path)
        | [] ->
            prerr_endline "Error: No test path specified";
            exit 1
        | _ ->
            exit
              (Test_runner.run_tests_paths ~profile ~debug ~sanitize ~leak_check
                 ~mode ~timeout ~jobs ~cache paths))
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
