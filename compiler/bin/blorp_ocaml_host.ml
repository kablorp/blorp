(** blorp OCaml host - private implementation host for commands that have not
    completed the Blorp migration. *)

open Blorp

let read_file = Modules.read_file

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


type blorp_cli_frontier =
  | BlorpCliDelegate of string list
  | BlorpCliTest of Compiler_blorp_bridge.cli_test_options
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
