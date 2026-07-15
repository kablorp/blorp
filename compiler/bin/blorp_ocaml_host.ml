(** blorp OCaml host - private command-line implementation host

    Usage:
      blorp compile program.brp          # Compile to C and binary
      blorp check program.brp            # Type check only
      blorp compile --ast program.brp    # Show AST only
      blorp run program.brp              # Compile and run
      blorp run --release program.brp    # Compile and run optimized
      blorp run --profile program.brp    # Run with profiling
      blorp check src/                   # Type check all .brp files in directory
      blorp test tests/test.brp          # Run a single test
      blorp test tests/                  # Run all tests in directory
      blorp purify program.brp           # Automatically mark pure functions
      blorp package check path/          # Validate a source package
      blorp package hash path/           # Print a source package content hash
      blorp package pack path/ -o pkg    # Write a deterministic source package artifact
*)

open Blorp
module StringMap = Map.Make (String)
module IntSet = Set.Make (Int)
module IntMap = Map.Make (Int)

type purify_candidate = {
  candidate_id : int;
  candidate_name : string;
  candidate_decl_loc : Ast.loc;
  candidate_signature : Typecheck.checked_func_signature;
  candidate_func : Ast.func_decl;
  candidate_body : Ast.expr;
}

let read_file = Modules.read_file
let extract_directory = Modules.extract_directory
let init_module_paths = Modules.init_module_paths

let write_file path contents =
  let channel = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr channel)
    (fun () -> output_string channel contents)

let read_all_channel channel =
  let buffer = Buffer.create 4096 in
  let bytes = Bytes.create 4096 in
  let rec loop () =
    match input channel bytes 0 4096 with
    | 0 -> Buffer.contents buffer
    | n ->
        Buffer.add_subbytes buffer bytes 0 n;
        loop ()
  in
  loop ()

let run_compiler_bridge_command args =
  let request_json =
    match args with
    | [] -> read_all_channel stdin
    | [ path ] -> read_file path
    | _ ->
        prerr_endline "Usage: blorp __compiler-bridge [request.json]";
        exit 1
  in
  let response_json =
    Compiler_blorp_bridge.run_renderer_request_via_blorp request_json
  in
  print_endline response_json;
  0

let run_compiler_bridge_prepare_command args =
  match args with
  | [ out_dir ] -> (
      match Compiler_blorp_bridge.prepare_bridge_binaries ~out_dir with
      | Ok prepared ->
          Printf.printf "%s=%s\n"
            Compiler_blorp_bridge.prepared_renderer_bridge_bin_env
            prepared.prepared_renderer_bridge_bin;
          Printf.printf "%s=%s\n"
            Compiler_blorp_bridge.prepared_parser_bridge_bin_env
            prepared.prepared_parser_bridge_bin;
          Printf.printf "%s=%s\n"
            Compiler_blorp_bridge.prepared_typecheck_bridge_bin_env
            prepared.prepared_typecheck_bridge_bin;
          0
      | Error message ->
          prerr_endline ("Error: " ^ message);
          1)
  | _ ->
      prerr_endline "Usage: blorp __compiler-bridge-prepare <out-dir>";
      1

(** Format a list of pipeline errors for display *)
let format_pipeline_errors ~file errors = Diagnostics.format_errors ~file errors

let finalize_cli_frontend_parsed_response = function
  | Compiler_blorp_bridge.ParseSourceDiagnostics diagnostics -> Error diagnostics
  | Compiler_blorp_bridge.ParsedSource parsed_source ->
      Ok parsed_source.Compiler_blorp_bridge.parsed_program

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

let resolve_test_timeout cli_timeout =
  resolve_timeout_from_env [ "BLORP_TEST_TIMEOUT"; "BLORP_TIMEOUT" ] cli_timeout

let parse_sanitizer_mode_source source value =
  match Test_runner.sanitizer_mode_of_string value with
  | Some mode -> mode
  | None ->
      Printf.eprintf
        "Error: %s must be one of: 0, 1, off, address, asan, undefined, ubsan\n"
        source;
      exit 1

let resolve_sanitizer_mode cli_sanitizer_mode =
  match cli_sanitizer_mode with
  | Some mode -> mode
  | None -> (
      match Sys.getenv_opt "BLORP_SANITIZE" with
      | Some value -> parse_sanitizer_mode_source "BLORP_SANITIZE" value
      | None -> Test_runner.SanitizerOff)

let resolve_leak_check cli_leak_check =
  cli_leak_check || Sys.getenv_opt "BLORP_LEAK_CHECK" = Some "1"

let resolve_no_format cli_no_format =
  cli_no_format || Sys.getenv_opt "BLORP_NO_FORMAT" = Some "1"

(** Auto-format a .brp file in place before compilation.
    Uses the Blorp-owned formatter bridge.
    Does NOT format std library files. *)
let auto_format_user_file filename =
  (* Skip std library files *)
  let is_std =
    Modules.is_path_under_dir
      ~dir:(Filename.concat (Sys.getcwd ()) "std")
      filename
  in
  if not is_std then
    match Compiler_blorp_bridge.cli_run_via_command [ "format"; filename ] with
    | Ok _ | Error _ -> ()

let line_start_offsets source =
  let starts = ref [ 0 ] in
  String.iteri
    (fun index ch ->
      if ch = '\n' then starts := (index + 1) :: !starts)
    source;
  Array.of_list (List.rev !starts)

let offset_of_loc source line_starts (loc : Ast.loc) =
  if loc.line <= 0 || loc.line > Array.length line_starts then 0
  else
    let line_start = line_starts.(loc.line - 1) in
    min (String.length source) (line_start + max 0 (loc.column - 1))

let is_identifier_char = function
  | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' -> true
  | _ -> false

let keyword_at source offset keyword =
  let source_len = String.length source in
  let keyword_len = String.length keyword in
  let next = offset + keyword_len in
  if offset < 0 || next > source_len then false
  else
    let left_boundary =
      offset = 0 || not (is_identifier_char source.[offset - 1])
    in
    let right_boundary =
      next >= source_len || not (is_identifier_char source.[next])
    in
    String.sub source offset keyword_len = keyword
    && left_boundary && right_boundary

let find_last_keyword_between source ~start ~stop keyword =
  let source_len = String.length source in
  let keyword_len = String.length keyword in
  let start = max 0 (min source_len start) in
  let stop = max start (min source_len stop) in
  let rec loop offset found =
    if offset + keyword_len > stop then found
    else
      let found =
        if keyword_at source offset keyword then Some offset else found
      in
      loop (offset + 1) found
  in
  loop start None

let purify_candidate_func_offset source line_starts candidate =
  let start = offset_of_loc source line_starts candidate.candidate_decl_loc in
  let stop = offset_of_loc source line_starts candidate.candidate_body.expr_loc in
  (* Declaration locs may start at docstrings or annotations. The body loc is
     after the header, so the last `func` keyword in this bounded range is the
     declaration keyword we need to mark pure. *)
  match find_last_keyword_between source ~start ~stop "func" with
  | Some offset -> Ok offset
  | None ->
      Error
        (Printf.sprintf
           "could not locate `func` keyword for purify candidate `%s` near \
            %d:%d"
           candidate.candidate_name candidate.candidate_decl_loc.line
           candidate.candidate_decl_loc.column)

let purify_rewrite_offsets source candidates =
  let line_starts = line_start_offsets source in
  let rec collect offsets = function
    | [] -> Ok (List.sort_uniq compare offsets |> List.rev)
    | candidate :: rest -> (
        match purify_candidate_func_offset source line_starts candidate with
        | Ok offset -> collect (offset :: offsets) rest
        | Error _ as error -> error)
  in
  collect [] candidates

let insert_pure_markers source offsets =
  List.fold_left
    (fun current offset ->
      String.sub current 0 offset
      ^ "pure "
      ^ String.sub current offset (String.length current - offset))
    source offsets

let rewrite_source_with_pure_markers source candidates =
  match purify_rewrite_offsets source candidates with
  | Error _ as error -> error
  | Ok offsets -> Ok (insert_pure_markers source offsets)

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
                      candidate_decl_loc = loc;
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
      let purifiable_candidates =
        local_candidates
        |> List.filter (fun candidate ->
               IntSet.mem candidate.candidate_id purifiable_ids)
      in
      let ordered_names =
        purifiable_candidates |> List.map (fun candidate -> candidate.candidate_name)
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
            match rewrite_source_with_pure_markers source purifiable_candidates with
            | Error message ->
                prerr_endline message;
                -1
            | Ok rewritten -> (
                match
                  Pipeline.typecheck_module_only_typed ~filename ~source:rewritten
                with
                | Error errors ->
                    prerr_endline (format_pipeline_errors ~file:filename errors);
                    -1
                | Ok _ ->
                    (* Preserve the user's source layout and comments. The full
                       formatter is available as an explicit `blorp format`
                       command; purify only needs to insert proven-safe `pure`
                       markers. *)
                    write_file filename rewritten;
                    Printf.printf "Purified %d function(s) in %s\n"
                      (List.length names) filename;
                    List.length names)))

type compile_opts = {
  no_emit : bool;
  ast_only : bool;
      (** Legacy --ast: prints AST and exits (no typecheck, no emit) *)
  dump_ast : bool;  (** --dump-ast: prints AST and continues compiling *)
  dump_typed_ast : bool;
      (** --dump-typed-ast: prints typed AST and continues compiling *)
  debug : bool;
  output : string option;
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
  core_stage_event : Blorp.Core_pipeline.on_stage_event option;
  tail_json_callback : Blorp.Core_pipeline.on_stage_json_callback option;
  tail_observation_stages : Blorp.Core_stage.t list;
  frontend_callback : (Blorp.Pipeline.frontend_phase -> unit) option;
  profiler : Blorp.Core_profile.t option;
  cleanup : unit -> unit;  (** closes the dump channel if one was opened *)
}
(** Composite observability handle: the optional program-bearing stage callback,
    optional lightweight stage event, optional profiler for summary reporting,
    and a cleanup thunk that must run on every exit path (success, stop, or
    error). *)

let obs_none =
  {
    callback = None;
    core_stage_event = None;
    tail_json_callback = None;
    tail_observation_stages = [];
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

let stop_after_requests_stage opts stage =
  match opts.stop_after with Some s -> s = stage | None -> false

let compile_opts_requests_stage opts stage =
  List.exists (fun s -> s = stage) opts.dump_core_after
  || stop_after_requests_stage opts stage

let tail_json_observation_stages opts =
  List.filter
    (fun stage ->
      Blorp.Core_pipeline.stage_observed_via_blorp_tail_json stage
      && compile_opts_requests_stage opts stage)
    Blorp.Core_stage.all

let program_callback_observation_stages opts =
  List.filter
    (fun stage ->
      compile_opts_requests_stage opts stage
      && not (Blorp.Core_pipeline.stage_observed_via_blorp_tail_json stage))
    Blorp.Core_stage.all

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
  let tail_observation_stages = tail_json_observation_stages opts in
  let program_observation_stages = program_callback_observation_stages opts in
  let frontend_callback =
    Option.map
      (fun p phase ->
        Blorp.Core_profile.on_label p
          (Blorp.Pipeline.frontend_phase_to_string phase))
      profiler
  in
  let core_stage_event = Option.map Blorp.Core_profile.on_stage_event profiler in
  let needs_program_callback = program_observation_stages <> [] in
  let needs_tail_json_callback = tail_observation_stages <> [] in
  let needs_dump_or_stop_callback =
    needs_program_callback || needs_tail_json_callback
  in
  match (needs_dump_or_stop_callback, profiler) with
  | false, None -> obs_none
  | false, Some _ ->
      {
        callback = None;
        core_stage_event;
        tail_json_callback = None;
        tail_observation_stages = [];
        frontend_callback;
        profiler;
        cleanup = (fun () -> ());
      }
  | true, _ ->
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
      let tail_cb stage json =
        if List.exists (fun s -> s = stage) opts.dump_core_after then begin
          emit_header_once ();
          Printf.fprintf ch "===== after %s =====\n%s\n"
            (Blorp.Core_stage.to_string stage)
            json;
          flush ch
        end;
        match opts.stop_after with
        | Some s when s = stage ->
            raise (Blorp.Core_pipeline.Stopped_after stage)
        | _ -> ()
      in
      {
        callback =
          (match program_observation_stages with
          | [] -> None
          | _ :: _ -> Some cb);
        core_stage_event;
        tail_json_callback =
          (match tail_observation_stages with
          | [] -> None
          | _ :: _ -> Some tail_cb);
        tail_observation_stages;
        frontend_callback;
        profiler;
        cleanup = close_once;
      }

let check_file_with_opts ~frontend_program ~preloaded_module_graph opts filename =
  if opts.ast_only then
    begin
      print_endline (program_to_string frontend_program);
      0
    end
  else begin
    init_module_paths (extract_directory filename);
    if opts.dump_ast then print_endline (program_to_string frontend_program);
    if opts.dump_typed_ast then (
      match
        Pipeline.typecheck_only_typed_with_blorp_bridge_policy
          ~debug:opts.debug ~allow_debug_only_calls:opts.debug ~filename
          ~preloaded_module_graph
      with
      | Error errors ->
          prerr_endline (format_pipeline_errors ~file:filename errors);
          1
      | Ok typed_program ->
          print_endline (Typed_ast_debug.format_program typed_program);
          print_endline "Type checking succeeded.";
          0)
    else
      match
        Pipeline.typecheck_only_typed_with_blorp_bridge_policy
          ~debug:opts.debug ~allow_debug_only_calls:opts.debug ~filename
          ~preloaded_module_graph
      with
      | Error errors ->
          prerr_endline (format_pipeline_errors ~file:filename errors);
          1
      | Ok _program ->
          print_endline "Type checking succeeded.";
          0
  end

let write_compile_output opts filename c_code =
  let base = Filename.remove_extension filename in
  let c_file = match opts.output with Some o -> o | None -> base ^ ".c" in
  let oc = open_out c_file in
  Fun.protect
    ~finally:(fun () -> close_out oc)
    (fun () -> output_string oc c_code);
  Printf.printf "Generated %s\n" c_file;
  0

let compile_file_with_opts ~frontend_program ~preloaded_module_graph opts
    filename =
  if opts.no_emit then
    check_file_with_opts ~frontend_program ~preloaded_module_graph opts filename
  else begin
    if opts.ast_only then
      begin
        print_endline (program_to_string frontend_program);
        0
      end
    else begin
      init_module_paths (extract_directory filename);
      (* --dump-ast prints the parsed AST before any further work, then
         continues with the rest of the pipeline. Unlike --ast (which stops
         after parse), it's non-destructive and composes with --dump-core,
         --time-phases, etc. *)
      if opts.dump_ast then print_endline (program_to_string frontend_program);
      let obs = build_on_stage ~source_file:filename opts in
      let print_profile () =
        match obs.profiler with
        | Some p -> prerr_string (Blorp.Core_profile.format p)
        | None -> ()
      in
      Fun.protect ~finally:obs.cleanup (fun () ->
          let result =
            match
              Pipeline.compile_preloaded_graph_with_blorp_bridge
                ~debug:opts.debug
                ?on_stage:obs.callback ?on_stage_event:obs.core_stage_event
                ?on_stage_json:obs.tail_json_callback
                ~tail_observation_stages:obs.tail_observation_stages
                ~check_invariants:opts.check_invariants
                ~embed_runtime:opts.embed_runtime
                ?on_frontend_phase:obs.frontend_callback ~filename
                ~preloaded_module_graph ()
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
                write_compile_output opts filename c_code
          in
          print_profile ();
          result)
    end
  end

let package_pin_overlap left right =
  match
    (Package_hash.validate_hash_pin left, Package_hash.validate_hash_pin right)
  with
  | Ok left, Ok right ->
      let left_len = String.length left in
      let right_len = String.length right in
      if left_len <= right_len then String.sub right 0 left_len = left
      else String.sub left 0 right_len = right
  | _ -> false

let package_config_lookup target =
  let base_dir = Sys.getcwd () in
  match Package_config.package_paths_from base_dir with
  | None -> Error "no blorp.toml found for package command"
  | Some (config_path, parsed) -> (
      match parsed.Package_config.package_errors with
      | (line, message) :: _ ->
          Error (Printf.sprintf "%s:%d: %s" config_path line message)
      | [] -> (
          let entries = parsed.Package_config.package_paths in
          match
            List.find_opt
              (fun entry -> entry.Package_config.package_alias = target)
              entries
          with
          | Some entry -> Ok (config_path, entry)
          | None -> (
              let hash_matches =
                List.filter
                  (fun entry ->
                    match entry.Package_config.package_hash_pin with
                    | Some pin -> package_pin_overlap pin target
                    | None -> false)
                  entries
              in
              match hash_matches with
              | [ entry ] -> Ok (config_path, entry)
              | [] ->
                  Error
                    (Printf.sprintf
                       "package %S is not declared in the nearest blorp.toml"
                       target)
              | matches ->
                  let aliases =
                    matches
                    |> List.map (fun entry ->
                        entry.Package_config.package_alias)
                    |> String.concat ", "
                  in
                  Error
                    (Printf.sprintf
                       "package hash %S matches multiple aliases in the \
                        nearest blorp.toml: %s"
                       target aliases))))

let package_config_hash entry =
  match entry.Package_config.package_hash_pin with
  | Some hash -> Ok hash
  | None ->
      Error
        (Printf.sprintf
           "package alias %S must define hash to use package fetch or vendor"
           entry.Package_config.package_alias)

type package_fetch_result =
  | PackageFetched of Package_cache.cached_package
  | PackageAlreadyCached of Package_cache.cached_package

let print_package_fetch_result alias = function
  | PackageFetched cached_package ->
      Printf.printf "Fetched %s\nHash %s\nCache %s\n" alias
        cached_package.Package_cache.hash cached_package.Package_cache.path
  | PackageAlreadyCached cached_package ->
      Printf.printf "Already cached %s\nHash %s\nCache %s\n" alias
        cached_package.Package_cache.hash cached_package.Package_cache.path

let package_fetch_config_entry entry =
  match (package_config_hash entry, entry.Package_config.package_from) with
  | Error msg, _ -> Error msg
  | Ok hash, _ -> (
      match Package_cache.find_cached hash with
      | Ok cached -> Ok (PackageAlreadyCached cached)
      | Error _ -> (
          match entry.Package_config.package_from with
          | [] ->
              Error
                (Printf.sprintf
                   "package alias %S has no from locations; pass locations \
                    explicitly"
                   entry.Package_config.package_alias)
          | from -> (
              match Package_cache.fetch ~expected_pin:hash from with
              | Ok cached -> Ok (PackageFetched cached)
              | Error errors -> Error (Package_cache.render_errors errors))))

let package_fetch_from_config target =
  match package_config_lookup target with
  | Error _ as err -> err
  | Ok (_, entry) -> (
      match package_fetch_config_entry entry with
      | Ok result -> Ok (entry.Package_config.package_alias, result)
      | Error _ as err -> err)

let package_fetch_explicit target from =
  match Package_hash.validate_hash_pin target with
  | Error message ->
      Error (Printf.sprintf "package hash %S is invalid: %s" target message)
  | Ok pin -> (
      match Package_cache.find_cached pin with
      | Ok cached ->
          Ok
            ( cached.Package_cache.manifest.Package_manifest.name,
              PackageAlreadyCached cached )
      | Error _ -> (
          match Package_cache.fetch ~expected_pin:pin from with
          | Ok cached ->
              Ok
                ( cached.Package_cache.manifest.Package_manifest.name,
                  PackageFetched cached )
          | Error errors -> Error (Package_cache.render_errors errors)))

let package_fetch_all_from_config () =
  let base_dir = Sys.getcwd () in
  match Package_config.package_paths_from base_dir with
  | None -> Error "no blorp.toml found for package fetch"
  | Some (config_path, parsed) -> (
      match parsed.Package_config.package_errors with
      | (line, message) :: _ ->
          Error (Printf.sprintf "%s:%d: %s" config_path line message)
      | [] -> (
          let fetched = ref [] in
          let cached = ref [] in
          let skipped_local = ref [] in
          let errors = ref [] in
          List.iter
            (fun entry ->
              match entry.Package_config.package_hash_pin with
              | None ->
                  skipped_local :=
                    entry.Package_config.package_alias :: !skipped_local
              | Some hash -> (
                  match Package_cache.find_cached hash with
                  | Ok cached_package ->
                      cached :=
                        (entry.Package_config.package_alias, cached_package)
                        :: !cached
                  | Error _ -> (
                      match entry.Package_config.package_from with
                      | [] ->
                          if entry.Package_config.package_path <> None then
                            skipped_local :=
                              entry.Package_config.package_alias
                              :: !skipped_local
                          else
                            errors :=
                              Printf.sprintf
                                "package alias %S has no from locations"
                                entry.Package_config.package_alias
                              :: !errors
                      | from -> (
                          match Package_cache.fetch ~expected_pin:hash from with
                          | Ok cached_package ->
                              fetched :=
                                ( entry.Package_config.package_alias,
                                  cached_package )
                                :: !fetched
                          | Error fetch_errors ->
                              errors :=
                                Package_cache.render_errors fetch_errors
                                :: !errors))))
            parsed.Package_config.package_paths;
          match List.rev !errors with
          | error :: rest -> Error (String.concat "\n" (error :: rest))
          | [] ->
              Ok (List.rev !fetched, List.rev !cached, List.rev !skipped_local))
      )

let package_config_command_error config_path (line, message) =
  Error (Printf.sprintf "%s:%d: %s" config_path line message)

type package_vendor_result =
  | PackageVendored of { name : string; hash : string; path : string }
  | PackageAlreadyVendored of { name : string; hash : string; path : string }

let package_local_hash path =
  match Package_check.check path with
  | Error errors -> Error (Package_check.render_errors errors)
  | Ok checked -> (
      match
        Package_hash.hash_checked_package ~root:path
          ~source_files:checked.Package_check.source_files
      with
      | Ok hash -> Ok hash
      | Error errors -> Error (Package_hash.render_errors errors))

let package_existing_vendor ~pin ~dest =
  if not (Sys.file_exists dest) then Ok None
  else
    match package_local_hash dest with
    | Error message ->
        Error
          (Printf.sprintf
             "vendor destination %S already exists but is not a valid package:\n\
              %s"
             dest message)
    | Ok actual ->
        if Package_hash.hash_matches_pin ~pin actual then Ok (Some actual)
        else
          Error
            (Printf.sprintf
               "vendor destination %S already exists but has the wrong hash\n\
                Expected %s\n\
                Found %s"
               dest pin actual)

let package_vendor_cached ~name ~pin ~dest =
  match Package_cache.vendor ~pin ~dest with
  | Ok cached ->
      Ok
        (PackageVendored { name; hash = cached.Package_cache.hash; path = dest })
  | Error errors -> Error (Package_cache.render_errors errors)

let package_vendor_configured_alias ~config_path entry =
  match package_config_hash entry with
  | Error msg -> Error msg
  | Ok hash -> (
      let name = entry.Package_config.package_alias in
      let dest =
        Filename.concat
          (Filename.concat (Filename.dirname config_path) "vendor")
          name
      in
      match package_existing_vendor ~pin:hash ~dest with
      | Error _ as err -> err
      | Ok (Some actual) ->
          Ok (PackageAlreadyVendored { name; hash = actual; path = dest })
      | Ok None -> package_vendor_cached ~name ~pin:hash ~dest)

let print_package_vendor_result = function
  | PackageVendored { name; hash; path } ->
      Printf.printf "Vendored %s\nHash %s\nPath %s\n" name hash path
  | PackageAlreadyVendored { name; hash; path } ->
      Printf.printf "Already vendored %s\nHash %s\nPath %s\n" name hash path

let package_vendor_hash_target target dest =
  match Package_cache.vendor ~pin:target ~dest with
  | Ok cached ->
      Ok
        (PackageVendored
           {
             name = cached.Package_cache.manifest.Package_manifest.name;
             hash = cached.Package_cache.hash;
             path = dest;
           })
  | Error errors -> Error (Package_cache.render_errors errors)

let package_vendor_target target dest =
  match dest with
  | Some dest when Result.is_ok (Package_hash.validate_hash_pin target) ->
      package_vendor_hash_target target dest
  | _ -> (
      match package_config_lookup target with
      | Ok (config_path, entry) -> (
          match dest with
          | None -> package_vendor_configured_alias ~config_path entry
          | Some dest -> (
              match package_config_hash entry with
              | Error msg -> Error msg
              | Ok hash ->
                  package_vendor_cached ~name:entry.Package_config.package_alias
                    ~pin:hash ~dest))
      | Error lookup_error -> (
          match dest with
          | None -> Error lookup_error
          | Some dest -> package_vendor_hash_target target dest))

let package_vendor_all_from_config () =
  let base_dir = Sys.getcwd () in
  match Package_config.package_paths_from base_dir with
  | None -> Error "no blorp.toml found for package vendor"
  | Some (config_path, parsed) -> (
      match parsed.Package_config.package_errors with
      | err :: _ -> package_config_command_error config_path err
      | [] -> (
          let vendored = ref [] in
          let skipped_local = ref [] in
          let errors = ref [] in
          List.iter
            (fun entry ->
              match
                ( entry.Package_config.package_path,
                  entry.Package_config.package_hash_pin )
              with
              | Some _, _ | None, None ->
                  skipped_local :=
                    entry.Package_config.package_alias :: !skipped_local
              | None, Some _ -> (
                  match package_vendor_configured_alias ~config_path entry with
                  | Ok result -> vendored := result :: !vendored
                  | Error message ->
                      errors :=
                        Printf.sprintf "package alias %S:\n%s"
                          entry.Package_config.package_alias message
                        :: !errors))
            parsed.Package_config.package_paths;
          match List.rev !errors with
          | error :: rest -> Error (String.concat "\n" (error :: rest))
          | [] -> Ok (List.rev !vendored, List.rev !skipped_local)))

let rec collect_brp_files path =
  if Sys.is_directory path then
    let files = try Sys.readdir path with _ -> [||] in
    Array.to_list files |> List.sort String.compare
    |> List.map (fun f -> Filename.concat path f)
    |> List.map collect_brp_files |> List.flatten
  else if Filename.check_suffix path ".brp" then [ path ]
  else []

let print_parse_diagnostics ~file diagnostics =
  prerr_endline (format_pipeline_errors ~file diagnostics)

type blorp_cli_frontier =
  | BlorpCliDelegate of string list
  | BlorpCliCompile of
      Ast.program
      * Modules.preloaded_module_graph
      * Compiler_blorp_bridge.cli_compile_options
  | BlorpCliTest of Compiler_blorp_bridge.cli_test_options
  | BlorpCliPurify of Compiler_blorp_bridge.cli_purify_options
  | BlorpCliRepl of Compiler_blorp_bridge.cli_repl_options
  | BlorpCliLsp of Compiler_blorp_bridge.cli_lsp_options
  | BlorpCliPackage of Compiler_blorp_bridge.cli_package_options

type finalized_cli_frontend_graph_source = {
  finalized_program : Ast.program;
  finalized_preloaded_source : Modules.preloaded_parsed_source;
}

let resolved_import_module_for_source
    (imports : Compiler_blorp_bridge.cli_frontend_import_edge list)
    (source : Compiler_blorp_bridge.cli_frontend_graph_source) import_module =
  match
    List.find_opt
      (fun (edge : Compiler_blorp_bridge.cli_frontend_import_edge) ->
        String.equal edge.cli_frontend_import_from_path
          source.cli_frontend_graph_path
        && String.equal edge.cli_frontend_import_from_module
             source.cli_frontend_graph_module_name
        && String.equal edge.cli_frontend_import_path import_module)
      imports
  with
  | Some edge -> Option.value edge.cli_frontend_import_resolved_module ~default:import_module
  | None -> import_module

let rewrite_frontend_import_modules
    (imports : Compiler_blorp_bridge.cli_frontend_import_edge list)
    (source : Compiler_blorp_bridge.cli_frontend_graph_source) program =
  let rec rewrite_decl decl =
    let decl_desc =
      match decl.Ast.decl_desc with
      | Ast.DImport import_decl ->
          let import_module =
            resolved_import_module_for_source imports source
              import_decl.Ast.import_module
          in
          Ast.DImport { import_decl with Ast.import_module = import_module }
      | Ast.DPrivate inner -> Ast.DPrivate (rewrite_decl inner)
      | other -> other
    in
    { decl with Ast.decl_desc = decl_desc }
  in
  List.map rewrite_decl program

let module_origin_of_cli_frontend_module_origin =
  let open Compiler_blorp_bridge in
  function
  | CliFrontendUserModule -> Session.User_module
  | CliFrontendStdModule -> Session.Stdlib_module
  | CliFrontendPkgModule package_id -> Session.native_package_origin package_id
  | CliFrontendSourcePackageModule package_alias ->
      Session.package_origin package_alias

let finalize_cli_frontend_graph_source ~imports
    (source : Compiler_blorp_bridge.cli_frontend_graph_source) =
  match
    finalize_cli_frontend_parsed_response
      source.cli_frontend_graph_parsed_response
  with
  | Error diagnostics ->
      print_parse_diagnostics ~file:source.cli_frontend_graph_path diagnostics;
      Error ()
  | Ok program ->
      let resolved_program =
        rewrite_frontend_import_modules imports source program
      in
      Ok
        {
          finalized_program = resolved_program;
          finalized_preloaded_source =
            {
              Modules.preload_module_name =
                source.cli_frontend_graph_module_name;
              preload_path = source.cli_frontend_graph_path;
              preload_origin =
                module_origin_of_cli_frontend_module_origin
                  source.cli_frontend_graph_origin;
              preload_source = source.cli_frontend_graph_source_text;
              preload_decls = resolved_program;
              preload_surface =
                (match source.cli_frontend_graph_parsed_response with
                | Compiler_blorp_bridge.ParsedSource parsed_source ->
                    parsed_source.parsed_module_surface
                | Compiler_blorp_bridge.ParseSourceDiagnostics _ -> None);
            };
        }

let finalized_cli_frontend_graph_sources_or_exit ~imports sources =
  let rec loop acc = function
    | [] -> List.rev acc
    | source :: rest -> (
        match finalize_cli_frontend_graph_source ~imports source with
        | Ok finalized -> loop (finalized :: acc) rest
        | Error () -> exit 1)
  in
  loop [] sources

let source_package_of_cli_frontend_source_package
    (pkg : Compiler_blorp_bridge.cli_frontend_source_package) :
    Modules.source_package =
  {
    Modules.source_package_alias = pkg.cli_frontend_source_package_alias;
    source_package_name = pkg.cli_frontend_source_package_name;
    source_package_root = pkg.cli_frontend_source_package_root;
    source_package_source_dir = pkg.cli_frontend_source_package_source_dir;
    source_package_exports = pkg.cli_frontend_source_package_exports;
  }

let preloaded_graph_context_of_cli_frontend_context
    (context : Compiler_blorp_bridge.cli_frontend_graph_context) :
    Modules.preloaded_module_graph_context =
  {
    Modules.preload_graph_std_dir =
      context.cli_frontend_context_std_dir;
    preload_graph_source_packages =
      List.map source_package_of_cli_frontend_source_package
        context.cli_frontend_context_source_packages;
    preload_graph_package_roots = context.cli_frontend_context_package_roots;
  }

let apply_cli_frontend_graph_context
    (context : Compiler_blorp_bridge.cli_frontend_graph_context) =
  Option.iter Modules.set_std_override context.cli_frontend_context_std_dir;
  List.iter Modules.add_package_root context.cli_frontend_context_package_roots;
  List.iter
    (fun pkg ->
      Modules.add_source_package
        (source_package_of_cli_frontend_source_package pkg))
    context.cli_frontend_context_source_packages;
  Modules.add_search_path (Sys.getcwd ())

let preloaded_import_edge_of_cli_frontend_import
    (edge : Compiler_blorp_bridge.cli_frontend_import_edge) :
    Modules.preloaded_import_edge =
  {
    Modules.preload_import_from_path =
      edge.cli_frontend_import_from_path;
    preload_import_from_module = edge.cli_frontend_import_from_module;
    preload_import_path = edge.cli_frontend_import_path;
    preload_import_resolved_path = edge.cli_frontend_import_resolved_path;
    preload_import_resolved_module = edge.cli_frontend_import_resolved_module;
    preload_import_resolved_origin =
      Option.map module_origin_of_cli_frontend_module_origin
        edge.cli_frontend_import_resolved_origin;
  }

let preloaded_module_graph_of_cli_frontend_graph graph sources :
    Modules.preloaded_module_graph =
  {
    Modules.preload_graph_context =
      preloaded_graph_context_of_cli_frontend_context
        graph.Compiler_blorp_bridge.cli_frontend_graph_context;
    preload_graph_sources = sources;
    preload_graph_imports =
      List.map preloaded_import_edge_of_cli_frontend_import
        graph.cli_frontend_graph_imports;
  }

let cli_frontier_frontend_module_graph
    (graph : Compiler_blorp_bridge.cli_frontend_module_graph) =
  apply_cli_frontend_graph_context
    graph.Compiler_blorp_bridge.cli_frontend_graph_context;
  let imports = graph.Compiler_blorp_bridge.cli_frontend_graph_imports in
  let roots =
    finalized_cli_frontend_graph_sources_or_exit ~imports
      graph.Compiler_blorp_bridge.cli_frontend_graph_roots
  in
  let modules =
    finalized_cli_frontend_graph_sources_or_exit ~imports
      graph.Compiler_blorp_bridge.cli_frontend_graph_modules
  in
  let module_graph_sources =
    List.map
      (fun source -> source.finalized_preloaded_source)
      (roots @ modules)
  in
  let preloaded_module_graph =
    preloaded_module_graph_of_cli_frontend_graph graph module_graph_sources
  in
  let options =
    graph.Compiler_blorp_bridge.cli_frontend_graph_compile_options
  in
  match roots with
  | [ root ] ->
      BlorpCliCompile (root.finalized_program, preloaded_module_graph, options)
  | _ ->
      prerr_endline
        "Error: compile frontend module graph must contain exactly one root";
      exit 1

let cli_frontier_of_cli_run_result = function
  | Compiler_blorp_bridge.CliRunHandled result ->
      print_string result.Compiler_blorp_bridge.cli_run_stdout;
      prerr_string result.Compiler_blorp_bridge.cli_run_stderr;
      exit result.Compiler_blorp_bridge.cli_run_status
  | Compiler_blorp_bridge.CliRunFrontendModuleGraph graph ->
      cli_frontier_frontend_module_graph graph
  | Compiler_blorp_bridge.CliRunTestOptions options -> BlorpCliTest options
  | Compiler_blorp_bridge.CliRunPurifyOptions options -> BlorpCliPurify options
  | Compiler_blorp_bridge.CliRunReplOptions options -> BlorpCliRepl options
  | Compiler_blorp_bridge.CliRunLspOptions options -> BlorpCliLsp options
  | Compiler_blorp_bridge.CliRunPackageOptions options ->
      BlorpCliPackage options
  | Compiler_blorp_bridge.CliRunDelegate delegated ->
      BlorpCliDelegate delegated.cli_run_delegate_args

let set_std_override_option = function
  | Some dir -> Modules.set_std_override dir
  | None -> ()

let compile_opts_of_cli_compile
    (options : Compiler_blorp_bridge.cli_compile_options) =
  {
    default_compile_opts with
    ast_only = options.cli_compile_ast_only;
    dump_ast = options.cli_compile_dump_ast;
    dump_typed_ast = options.cli_compile_dump_typed_ast;
    dump_core_after = options.cli_compile_dump_core_after;
    dump_file = options.cli_compile_dump_file;
    stop_after = options.cli_compile_stop_after;
    time_phases = options.cli_compile_time_phases;
    check_invariants = options.cli_compile_check_invariants;
    debug = options.cli_compile_debug;
    embed_runtime = options.cli_compile_embed_runtime;
    output = options.cli_compile_output;
  }

let sanitizer_mode_of_cli_frontend =
  let open Compiler_blorp_bridge in
  function
  | CliFrontendSanitizeOff -> Test_runner.SanitizerOff
  | CliFrontendSanitizeAddressUndefined ->
      Test_runner.SanitizerAddressUndefined
  | CliFrontendSanitizeUndefined -> Test_runner.SanitizerUndefinedOnly

let run_compile_from_frontier_options ~frontend_program
    ~preloaded_module_graph
    (options : Compiler_blorp_bridge.cli_compile_options) =
  let opts = compile_opts_of_cli_compile options in
  set_std_override_option options.cli_compile_std_dir;
  match options.cli_compile_files with
  | [ file ] ->
      compile_file_with_opts ~frontend_program ~preloaded_module_graph opts file
  | [] ->
      prerr_endline "Error: No input file specified";
      1
  | _ ->
      prerr_endline "Error: Multiple input files not supported";
      1

let run_compiler_host_compile_wrapper_command args =
  match args with
  | [ "-o"; output; filename ] -> (
      match
        Compiler_blorp_bridge.cli_run_via_command ~version:(Version.describe ())
          [ "compile"; "--no-format"; "-o"; output; filename ]
      with
      | Error (_, message) ->
          prerr_endline message;
          1
      | Ok result -> (
          match cli_frontier_of_cli_run_result result with
          | BlorpCliCompile (frontend_program, preloaded_module_graph, options)
            ->
              run_compile_from_frontier_options ~frontend_program
                ~preloaded_module_graph options
          | _ ->
              prerr_endline
                "Internal error: compiler host compile wrapper expected a \
                 Blorp frontend compile graph";
              1))
  | _ ->
      prerr_endline
        "Usage: blorp __compiler-host-compile-wrapper -o <out.c> <file.brp>";
      1

let test_mode_of_cli_frontend =
  let open Compiler_blorp_bridge in
  function
  | CliFrontendTestAll -> Test_runner.TestAll
  | CliFrontendTestDocOnly -> Test_runner.DocOnly
  | CliFrontendTestSuiteOnly -> Test_runner.SuiteOnly

let auto_format_test_path path =
  if Sys.is_directory path then
    Array.iter
      (fun file ->
        if Filename.check_suffix file ".brp" then
          auto_format_user_file (Filename.concat path file))
      (Sys.readdir path)
  else auto_format_user_file path

let warmup_test_artifacts () =
  Test_runner.with_run_artifacts (fun () ->
      ignore (Test_runner.precompile_runtime ()));
  0

let run_test_from_frontier_options
    (options : Compiler_blorp_bridge.cli_test_options) =
  match options with
  | Compiler_blorp_bridge.CliTestWarmupOnlyOptions _ ->
      warmup_test_artifacts ()
  | Compiler_blorp_bridge.CliTestRunOptions options ->
      let timeout =
        match resolve_test_timeout options.cli_test_timeout with
        | Some _ as timeout -> timeout
        | None -> Some 30
      in
      let sanitizer_mode =
        options.cli_test_sanitizer
        |> Option.map sanitizer_mode_of_cli_frontend
        |> resolve_sanitizer_mode
      in
      let leak_check = resolve_leak_check options.cli_test_leak_check in
      let no_format = resolve_no_format options.cli_test_no_format in
      let mode = test_mode_of_cli_frontend options.cli_test_mode in
      if not no_format then List.iter auto_format_test_path options.cli_test_paths;
      set_std_override_option options.cli_test_std_dir;
      match options.cli_test_paths with
      | [ path ] ->
          Test_runner.run_tests ~profile:options.cli_test_profile
            ~debug:options.cli_test_debug ~sanitizer_mode ~leak_check ~mode
            ~timeout ~jobs:options.cli_test_jobs ~cache:options.cli_test_cache
            ~repeat:options.cli_test_repeat path
      | [] ->
          prerr_endline "Error: No test path specified";
          1
      | paths ->
          Test_runner.run_tests_paths ~profile:options.cli_test_profile
            ~debug:options.cli_test_debug ~sanitizer_mode ~leak_check ~mode
            ~timeout ~jobs:options.cli_test_jobs ~cache:options.cli_test_cache
            ~repeat:options.cli_test_repeat paths

let run_purify_from_frontier_options
    (options : Compiler_blorp_bridge.cli_purify_options) =
  let all_files =
    List.map collect_brp_files options.cli_purify_paths |> List.flatten
  in
  match all_files with
  | [] ->
      prerr_endline "Error: No input files specified";
      1
  | files ->
      let results =
        List.map
          (purify_file ~dry_run:options.cli_purify_dry_run
             ~verbose:options.cli_purify_verbose)
          files
      in
      let total_purified =
        List.fold_left (fun acc r -> acc + max 0 r) 0 results
      in
      let files_modified =
        List.filter (fun r -> r > 0) results |> List.length
      in
      if
        (not options.cli_purify_dry_run)
        && (files_modified > 1 || (files_modified = 1 && List.length files > 1))
      then
        Printf.printf "Total: Purified %d function(s) across %d file(s).\n"
          total_purified files_modified;
      if List.exists (fun r -> r < 0) results then 1 else 0

let run_package_from_frontier_options
    (options : Compiler_blorp_bridge.cli_package_options) =
  let open Compiler_blorp_bridge in
  match options.cli_package_command with
  | CliPackageCheck path -> (
      match Package_check.check path with
      | Ok result ->
          Printf.printf "Package %s: ok (%d source files checked)\n"
            result.Package_check.manifest.Package_manifest.name
            (List.length result.Package_check.source_files);
          0
      | Error errors ->
          prerr_endline (Package_check.render_errors errors);
          1)
  | CliPackageHash path -> (
      match Package_check.check path with
      | Error errors ->
          prerr_endline (Package_check.render_errors errors);
          1
      | Ok result -> (
          match
            Package_hash.hash_checked_package ~root:path
              ~source_files:result.Package_check.source_files
          with
          | Ok hash ->
              print_endline hash;
              0
          | Error errors ->
              prerr_endline (Package_hash.render_errors errors);
              1))
  | CliPackagePack { path; output } -> (
      match Package_check.check path with
      | Error errors ->
          prerr_endline (Package_check.render_errors errors);
          1
      | Ok result -> (
          match
            Package_artifact.write_checked_package ~root:path
              ~source_files:result.Package_check.source_files ~output
          with
          | Ok hash ->
              Printf.printf "Wrote %s\nHash %s\n" output hash;
              0
          | Error errors ->
              prerr_endline (Package_artifact.render_errors errors);
              1))
  | CliPackageFetchAll -> (
      match package_fetch_all_from_config () with
      | Ok (fetched, cached, skipped_local) ->
          List.iter
            (fun (alias, cached_package) ->
              Printf.printf "Fetched %s\nHash %s\nCache %s\n" alias
                cached_package.Package_cache.hash cached_package.Package_cache.path)
            fetched;
          List.iter
            (fun (alias, cached_package) ->
              Printf.printf "Already cached %s\nHash %s\nCache %s\n" alias
                cached_package.Package_cache.hash cached_package.Package_cache.path)
            cached;
          List.iter
            (fun alias -> Printf.printf "Skipped local package %s\n" alias)
            skipped_local;
          if fetched = [] && cached = [] && skipped_local = [] then
            print_endline "No packages declared";
          0
      | Error message ->
          prerr_endline message;
          1)
  | CliPackageFetchTarget { target; from } -> (
      let result =
        match from with
        | [] -> package_fetch_from_config target
        | _ -> package_fetch_explicit target from
      in
      match result with
      | Ok (alias, fetch_result) ->
          print_package_fetch_result alias fetch_result;
          0
      | Error message ->
          prerr_endline message;
          1)
  | CliPackageVendorAll -> (
      match package_vendor_all_from_config () with
      | Ok (vendored, skipped_local) ->
          List.iter print_package_vendor_result vendored;
          List.iter
            (fun alias -> Printf.printf "Skipped local package %s\n" alias)
            skipped_local;
          if vendored = [] && skipped_local = [] then
            print_endline "No packages declared";
          0
      | Error message ->
          prerr_endline message;
          1)
  | CliPackageVendorTarget { target; dest } -> (
      match package_vendor_target target dest with
      | Ok result ->
          print_package_vendor_result result;
          0
      | Error message ->
          prerr_endline message;
          1)

let is_internal_compiler_command = function
  | "__compiler-bridge" :: _
  | "__compiler-bridge-prepare" :: _
  | "__compiler-host-compile-wrapper" :: _
  | "__compiler-run-cli-plan" :: _ ->
      true
  | _ -> false

let apply_blorp_cli_frontier args =
  if is_internal_compiler_command args then
    BlorpCliDelegate args
  else
    match
      Compiler_blorp_bridge.cli_run_via_command ~version:(Version.describe ())
        args
    with
    | Ok result -> cli_frontier_of_cli_run_result result
    | Error (_, message) ->
        prerr_endline message;
        exit 1

let command_line_args () =
  match Array.to_list Sys.argv with _ :: args -> args | [] -> []

let rec run_delegate_command args =
  match args with
  | "__compiler-bridge" :: rest -> exit (run_compiler_bridge_command rest)
  | "__compiler-bridge-prepare" :: rest ->
      exit (run_compiler_bridge_prepare_command rest)
  | "__compiler-host-compile-wrapper" :: rest ->
      exit (run_compiler_host_compile_wrapper_command rest)
  | "__compiler-run-cli-plan" :: rest ->
      exit (run_compiler_cli_plan_command rest)
  | _ ->
      prerr_endline
        "Internal error: CLI command reached the OCaml delegate path";
      exit 1
and run_compiler_cli_plan_command args =
  match args with
  | [ path ] -> (
      match Compiler_blorp_bridge.cli_run_response_json (read_file path) with
      | Ok result -> run_frontier (cli_frontier_of_cli_run_result result)
      | Error (_, message) ->
          prerr_endline message;
          1)
  | _ ->
      prerr_endline "Usage: blorp __compiler-run-cli-plan <plan.json>";
      1
and run_frontier = function
  | BlorpCliDelegate args -> run_delegate_command args
  | BlorpCliCompile (frontend_program, preloaded_module_graph, options) ->
      run_compile_from_frontier_options ~frontend_program
        ~preloaded_module_graph options
  | BlorpCliTest options -> run_test_from_frontier_options options
  | BlorpCliPurify options -> run_purify_from_frontier_options options
  | BlorpCliRepl options ->
      Repl.run ~debug:options.Compiler_blorp_bridge.cli_repl_debug;
      0
  | BlorpCliLsp _ -> Lsp_server.run ()
  | BlorpCliPackage options -> run_package_from_frontier_options options

(** Main entry point *)
let () =
  try
    command_line_args () |> apply_blorp_cli_frontier |> run_frontier |> exit
  with
  | Sys_error msg ->
      Printf.eprintf "Error: %s\n" msg;
      exit 1
  | Failure msg ->
      Printf.eprintf "Internal error: %s\n" msg;
      exit 1
  | Invalid_argument msg
    when String.starts_with ~prefix:"Invalid BLORP_TLS_BACKEND" msg ->
      Printf.eprintf "Error: %s\n" msg;
      exit 1
  | exn ->
      Printf.eprintf
        "Internal compiler error: %s\nThis is a bug in the blorp compiler.\n"
        (Printexc.to_string exn);
      exit 2
