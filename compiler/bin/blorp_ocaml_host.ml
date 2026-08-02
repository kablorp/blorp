(** blorp OCaml host - private implementation host for commands that have not
    completed the Blorp migration. *)

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

let write_file path contents =
  let channel = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr channel)
    (fun () -> output_string channel contents)

let run_compiler_bridge_prepare_command args =
  match args with
  | [ out_dir ] -> (
      match Compiler_blorp_bridge.prepare_parser_bridge_binary ~out_dir with
      | Ok parser_path ->
          Printf.printf "%s=%s\n"
            Compiler_blorp_bridge.prepared_parser_bridge_bin_env
            parser_path;
          0
      | Error message ->
          prerr_endline ("Error: " ^ message);
          1)
  | _ ->
      prerr_endline "Usage: blorp __compiler-bridge-prepare <out-dir>";
      1

(** Format a list of pipeline errors for display *)
let format_pipeline_errors ~file errors = Diagnostics.format_errors ~file errors

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

type blorp_cli_frontier =
  | BlorpCliDelegate of string list
  | BlorpCliTest of Compiler_blorp_bridge.cli_test_options
  | BlorpCliPurify of Compiler_blorp_bridge.cli_purify_options
  | BlorpCliRepl of Compiler_blorp_bridge.cli_repl_options
  | BlorpCliLsp of Compiler_blorp_bridge.cli_lsp_options
  | BlorpCliPackage of Compiler_blorp_bridge.cli_package_options

let cli_frontier_of_cli_run_result = function
  | Compiler_blorp_bridge.CliRunHandled result ->
      print_string result.Compiler_blorp_bridge.cli_run_stdout;
      prerr_string result.Compiler_blorp_bridge.cli_run_stderr;
      exit result.Compiler_blorp_bridge.cli_run_status
  | Compiler_blorp_bridge.CliRunSourceCommand ->
      prerr_endline
        "Internal error: a source compile plan reached the OCaml tool host";
      exit 1
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

let sanitizer_mode_of_cli_frontend =
  let open Compiler_blorp_bridge in
  function
  | CliFrontendSanitizeOff -> Test_runner.SanitizerOff
  | CliFrontendSanitizeAddressUndefined ->
      Test_runner.SanitizerAddressUndefined
  | CliFrontendSanitizeUndefined -> Test_runner.SanitizerUndefinedOnly

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

let warmup_test_artifacts ~compiler_path =
  Test_runner.with_run_artifacts (fun () ->
      Test_runner.with_production_compiler ~compiler_path (fun () ->
          let output_path =
            Test_runner.run_artifact_path ~kind:"test-warmup"
              ~prefix:"program" ~suffix:".bin"
          in
          match
            Test_runner.compile_source_to_executable ~debug:true
              ~logical_path:"__test_warmup__.brp"
              ~source:"func main(args: List[String]) -> Int:\n\t0\n"
              ~output_path ()
          with
          | Ok () -> 0
          | Error detail ->
              Printf.eprintf "Error: test compiler warmup failed: %s\n" detail;
              1))

let run_test_from_frontier_options
    (options : Compiler_blorp_bridge.cli_test_options) =
  match options with
  | Compiler_blorp_bridge.CliTestWarmupOnlyOptions options ->
      warmup_test_artifacts
        ~compiler_path:options.cli_test_compiler_path
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
            ~repeat:options.cli_test_repeat
            ~compiler_path:options.cli_test_compiler_path
            ?std_dir:options.cli_test_std_dir path
      | [] ->
          prerr_endline "Error: No test path specified";
          1
      | paths ->
          Test_runner.run_tests_paths ~profile:options.cli_test_profile
            ~debug:options.cli_test_debug ~sanitizer_mode ~leak_check ~mode
            ~timeout ~jobs:options.cli_test_jobs ~cache:options.cli_test_cache
            ~repeat:options.cli_test_repeat
            ~compiler_path:options.cli_test_compiler_path
            ?std_dir:options.cli_test_std_dir paths

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
  | "__compiler-bridge-prepare" :: _
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
  | "__compiler-bridge-prepare" :: rest ->
      exit (run_compiler_bridge_prepare_command rest)
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
  | BlorpCliTest options -> run_test_from_frontier_options options
  | BlorpCliPurify options -> run_purify_from_frontier_options options
  | BlorpCliRepl options ->
      Repl.run ~debug:options.Compiler_blorp_bridge.cli_repl_debug
        ~compiler_path:options.cli_repl_compiler_path;
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
