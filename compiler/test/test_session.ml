(** Tests for [Session.t] — state isolation across sessions.

    These tests are the load-bearing guarantee for Phase 2.1: multiple
    [Session.create ()] calls produce mutually-independent state. If
    any of these fail, the session refactor has drifted and downstream
    features (multi-buffer LSP, parallel test compilation) will
    silently share state across what should be isolated boundaries. *)

open Blorp

(* ============================================================================
   Meta-env isolation
   ============================================================================ *)

let test_fresh_meta_counters_independent () =
  let s1 = Session.create () in
  let s2 = Session.create () in
  let _ = Types.fresh_meta ~sess:s1 () in
  let _ = Types.fresh_meta ~sess:s1 () in
  (* s1 has bumped its counter twice; s2's counter should still be 0. *)
  Alcotest.(check int) "s1 counter advanced" 2 s1.fresh_meta_counter;
  Alcotest.(check int) "s2 counter untouched" 0 s2.fresh_meta_counter

let test_meta_env_isolated () =
  let s1 = Session.create () in
  let s2 = Session.create () in
  let m1 = Types.fresh_meta ~sess:s1 ~origin:"T" () in
  match m1 with
  | TyMeta n ->
      Types.bind_meta ~sess:s1 n Types.ty_int;
      Alcotest.(check bool)
        "s1 meta looks up" true
        (Types.lookup_meta ~sess:s1 n = Some Types.ty_int);
      Alcotest.(check bool)
        "s2 meta is empty" true
        (Types.lookup_meta ~sess:s2 n = None)
  | _ -> Alcotest.fail "fresh_meta didn't return TyMeta"

let test_reset_meta_clears_only_that_session () =
  let s1 = Session.create () in
  let s2 = Session.create () in
  let _ = Types.fresh_meta ~sess:s1 () in
  let _ = Types.fresh_meta ~sess:s2 () in
  Session.reset_meta s1;
  Alcotest.(check int) "s1 reset" 0 s1.fresh_meta_counter;
  Alcotest.(check int) "s2 untouched by s1 reset" 1 s2.fresh_meta_counter

let test_parse_raw_source_uses_session_without_frontend_selector () =
  let sess = Session.create () in
  Session.with_current sess (fun () ->
      match
        Modules.parse_raw_source ~filename:"session_parse.brp"
          "func main(args: List[String]) -> Int:\n    0\n"
      with
      | Ok [ { Ast.decl_desc = Ast.DFunc { func_name = Some "main"; _ }; _ } ] ->
          ()
      | Ok _ -> Alcotest.fail "expected parsed main function"
      | Error err -> Alcotest.failf "parse failed: %s" err.Ast.message)

(* ============================================================================
   Module-cache isolation
   ============================================================================ *)

let test_module_cache_independent () =
  let s1 = Session.create () in
  let s2 = Session.create () in
  (* Manually insert into s1's module cache. s2's cache must not see it. *)
  let m : Session.loaded_module =
    {
      name = "fake/mod";
      path = "<test>";
      origin = Session.User_module;
      decls = [];
      exports = [];
      surface = None;
      typed_decls = None;
      typed_import_bindings = None;
    }
  in
  Hashtbl.add s1.module_cache "fake/mod" m;
  Alcotest.(check bool)
    "s1 finds module" true
    (Modules.find_cached ~sess:s1 "fake/mod" <> None);
  Alcotest.(check bool)
    "s2 does not find module" true
    (Modules.find_cached ~sess:s2 "fake/mod" = None)

let test_load_errors_independent () =
  let s1 = Session.create () in
  let s2 = Session.create () in
  let err : Ast.compiler_error =
    {
      message = "fake";
      loc = Ast.dummy_loc;
      phase = Ast.ModuleLoad;
      kind = Ast.OtherError;
      notes = [];
      help = None;
    }
  in
  s1.load_errors <- [ err ];
  Alcotest.(check int)
    "s1 has one error" 1
    (List.length (Modules.get_load_errors ~sess:s1 ()));
  Alcotest.(check int)
    "s2 has no errors" 0
    (List.length (Modules.get_load_errors ~sess:s2 ()))

let test_module_origin_policy_helpers () =
  let source_pkg = Session.package_origin "sqlite" in
  let native_pkg = Session.native_package_origin "sqlite" in
  Alcotest.(check bool)
    "std allows builtin" true
    (Session.module_origin_allows_builtin Session.Stdlib_module);
  Alcotest.(check bool)
    "user rejects builtin" false
    (Session.module_origin_allows_builtin Session.User_module);
  Alcotest.(check bool)
    "source pkg rejects builtin" false
    (Session.module_origin_allows_builtin source_pkg);
  Alcotest.(check bool)
    "native pkg rejects builtin" false
    (Session.module_origin_allows_builtin native_pkg);
  Alcotest.(check bool)
    "std rejects foreign" false
    (Session.module_origin_allows_foreign Session.Stdlib_module);
  Alcotest.(check bool)
    "user allows foreign" true
    (Session.module_origin_allows_foreign Session.User_module);
  Alcotest.(check bool)
    "source pkg rejects foreign" false
    (Session.module_origin_allows_foreign source_pkg);
  Alcotest.(check bool)
    "native pkg allows foreign" true
    (Session.module_origin_allows_foreign native_pkg)

let test_search_paths_independent () =
  let s1 = Session.create () in
  let s2 = Session.create () in
  Modules.add_search_path ~sess:s1 "/fake/path/s1";
  Alcotest.(check bool)
    "s1 contains path" true
    (List.mem "/fake/path/s1" s1.search_paths);
  Alcotest.(check bool)
    "s2 does not contain s1's path" false
    (List.mem "/fake/path/s1" s2.search_paths)

(* ============================================================================
   Ambient current session
   ============================================================================ *)

let test_with_current_restores_previous () =
  let outer = Session.current () in
  let inner = Session.create () in
  Session.with_current inner (fun () ->
      Alcotest.(check bool)
        "inner is current during scope" true
        (Session.current () == inner));
  Alcotest.(check bool)
    "previous restored after scope" true
    (Session.current () == outer)

let test_with_current_restores_on_exception () =
  let outer = Session.current () in
  let inner = Session.create () in
  (try Session.with_current inner (fun () -> raise Exit) with Exit -> ());
  Alcotest.(check bool)
    "previous restored even on exception" true
    (Session.current () == outer)

let test_fresh_meta_uses_ambient () =
  (* When no ~sess is passed, fresh_meta uses the ambient current session. *)
  let s = Session.create () in
  Session.with_current s (fun () ->
      let _ = Types.fresh_meta () in
      ());
  Alcotest.(check int) "ambient session's counter bumped" 1 s.fresh_meta_counter

(* ============================================================================
   assert_in_scope — debug guard for "no with_current frame is active"
   ============================================================================

   Per Phase 2.1's deferred follow-up: catch latent aliasing when per-buffer
   LSP sessions come online. When a caller forgets to wrap its work in
   [with_current], every nested [Session.current ()] call returns the
   process-wide default session — silently sharing state across what should
   be isolated boundaries. [assert_in_scope] gives that mistake a loud
   failure mode in tests / debug builds. *)

let test_assert_in_scope_raises_outside_frame () =
  Alcotest.check_raises "raises outside with_current"
    (Failure "Session.assert_in_scope: no with_current frame active") (fun () ->
      Session.assert_in_scope ())

let test_assert_in_scope_ok_inside_frame () =
  let s = Session.create () in
  Session.with_current s (fun () ->
      Session.assert_in_scope ();
      (* must not raise *)
      Alcotest.(check pass) "in scope" () ())

let test_assert_in_scope_nested_frames () =
  let outer = Session.create () in
  let inner = Session.create () in
  Session.with_current outer (fun () ->
      Session.assert_in_scope ();
      Session.with_current inner (fun () -> Session.assert_in_scope ());
      Session.assert_in_scope () (* still in outer frame *));
  (* Exited both frames; should raise again *)
  Alcotest.check_raises "raises after all frames exit"
    (Failure "Session.assert_in_scope: no with_current frame active") (fun () ->
      Session.assert_in_scope ())

(* ============================================================================
   Pipeline-level isolation
   ============================================================================

   These tests pin the contract that [Pipeline.compile_legacy_direct_source] runs in its own
   session — the caller's ambient state must be unchanged after the call,
   and a second compile must not inherit state from the first. This
   contract is the user-visible payoff of Phase 2.1: today the implicit
   ambient session is shared across all compiles in a process, leaking
   [module_cache] / [prelude_modules_loaded] / [load_errors] across what
   ought to be independent compilations. *)

let trivial_source = "func main(args: List[String]):\n    print(\"hi\")\n"

let bad_import_source =
  "import:\n\
  \    nonexistent_module_xyz: foo\n\
   func main(args: List[String]):\n\
  \    print(\"x\")\n"

let test_compile_isolates_caller_module_cache () =
  Test_helpers.with_isolated_env (fun () ->
      let outer = Session.current () in
      let starting_cache_size = Hashtbl.length outer.module_cache in
      let starting_prelude = outer.prelude_modules_loaded in
      let _ =
        Pipeline.compile_legacy_direct_source ~filename:"isolation_a.brp" ~source:trivial_source ()
      in
      Alcotest.(check int)
        "caller module_cache unchanged after Pipeline.compile_legacy_direct_source"
        starting_cache_size
        (Hashtbl.length outer.module_cache);
      Alcotest.(check bool)
        "caller prelude_modules_loaded unchanged" starting_prelude
        outer.prelude_modules_loaded)

let mentions s needle =
  let nl = String.length needle in
  let sl = String.length s in
  let rec find i =
    if i + nl > sl then false
    else if String.sub s i nl = needle then true
    else find (i + 1)
  in
  nl <= sl && find 0

let test_compile_does_not_inherit_prior_load_errors () =
  Test_helpers.with_isolated_env (fun () ->
      (* First compile has a bad import so it populates load_errors. *)
      let _ =
        Pipeline.compile_legacy_direct_source ~filename:"isolation_bad.brp" ~source:bad_import_source
          ()
      in
      (* Second compile is clean. Its errors (if any) must not mention the
       prior compile's nonexistent_module_xyz. *)
      match
        Pipeline.compile_legacy_direct_source ~filename:"isolation_good.brp" ~source:trivial_source
          ()
      with
      | Ok _ -> Alcotest.(check pass) "clean second compile" () ()
      | Error errs ->
          let stale =
            List.exists
              (fun (e : Ast.compiler_error) ->
                mentions e.message "nonexistent_module_xyz")
              errs
          in
          Alcotest.(check bool)
            "no stale load errors from prior compile" false stale)

let with_temp_dir prefix f =
  let dir = Filename.temp_file prefix "" in
  Sys.remove dir;
  Unix.mkdir dir 0o700;
  let rec remove_tree path =
    if Sys.file_exists path then
      if Sys.is_directory path then begin
        Array.iter
          (fun name -> remove_tree (Filename.concat path name))
          (Sys.readdir path);
        Unix.rmdir path
      end
      else Sys.remove path
  in
  Fun.protect
    ~finally:(fun () -> try remove_tree dir with _ -> ())
    (fun () -> f dir)

let write_file path contents =
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out oc)
    (fun () -> output_string oc contents)

let with_env name value f =
  let old = Sys.getenv_opt name in
  Unix.putenv name value;
  Fun.protect
    ~finally:(fun () ->
      match old with
      | Some v -> Unix.putenv name v
      | None -> Unix.putenv name "")
    f

let assert_std_override sess ~expected =
  Alcotest.(check bool)
    "std override active" true sess.Session.std_override_active;
  Alcotest.(check (option string))
    "std override dir" (Some expected) sess.std_override_dir;
  Alcotest.(check (option string))
    "std source dir" (Some expected)
    (Modules.std_source_dir ~sess ())

let test_blorp_toml_std_path_sets_override () =
  with_temp_dir "blorp_config_std" (fun dir ->
      write_file
        (Filename.concat dir "blorp.toml")
        "[std] # standard library override\n\
         path = \"custom_std\" # relative to blorp.toml\n";
      with_env "BLORP_STD" "" (fun () ->
          let sess = Session.create () in
          Modules.init_module_paths ~sess (Filename.concat dir "src");
          assert_std_override sess ~expected:(Filename.concat dir "custom_std")))

let test_blorp_toml_is_lower_priority_than_env () =
  with_temp_dir "blorp_config_env" (fun dir ->
      write_file
        (Filename.concat dir "blorp.toml")
        "[std]\npath = \"from_config\"\n";
      let env_std = Filename.concat dir "from_env" in
      with_env "BLORP_STD" env_std (fun () ->
          let sess = Session.create () in
          Modules.init_module_paths ~sess dir;
          assert_std_override sess ~expected:env_std))

let test_blorp_toml_does_not_replace_existing_override () =
  with_temp_dir "blorp_config_cli" (fun dir ->
      write_file
        (Filename.concat dir "blorp.toml")
        "[std]\npath = \"from_config\"\n";
      with_env "BLORP_STD" (Filename.concat dir "from_env") (fun () ->
          let cli_std = Filename.concat dir "from_cli" in
          let sess = Session.create () in
          Modules.set_std_override ~sess cli_std;
          Modules.init_module_paths ~sess dir;
          assert_std_override sess ~expected:cli_std))

let test_std_dir_is_not_guessed_without_explicit_config () =
  with_temp_dir "blorp_no_implicit_std" (fun dir ->
      Unix.mkdir (Filename.concat dir "std") 0o700;
      with_env "BLORP_STD" "" (fun () ->
          let sess = Session.create () in
          Modules.init_module_paths ~sess dir;
          Alcotest.(check bool)
            "std override inactive" false sess.std_override_active;
          Alcotest.(check (option string))
            "no std source dir" None
            (Modules.std_source_dir ~sess ());
          match Modules.load_module ~sess "std/option" dir with
          | Some m ->
              Alcotest.(check bool)
                "embedded std module" true
                (m.origin = Session.Stdlib_module);
              Alcotest.(check string)
                "embedded path" "<embedded:std/option>" m.path
          | None -> Alcotest.fail "expected embedded std/option to load"))

let test_source_origin_uses_configured_std_root () =
  with_temp_dir "blorp_source_origin" (fun dir ->
      let sess = Session.create () in
      Modules.set_std_override ~sess dir;
      let std_file = Filename.concat dir "list.brp" in
      let user_file = Filename.concat (Filename.dirname dir) "user.brp" in
      write_file std_file "";
      Alcotest.(check bool)
        "std root file is std origin" true
        (Modules.module_origin_for_source_file ~sess std_file
        = Session.Stdlib_module);
      Alcotest.(check bool)
        "outside file is user origin" true
        (Modules.module_origin_for_source_file ~sess user_file
        = Session.User_module))

let test_import_parse_error_does_not_block_sibling_import () =
  with_temp_dir "blorp_import_batch_error" (fun dir ->
      write_file
        (Filename.concat dir "sample.brp")
        "import:\n\t./bad\n\t./good\n";
      write_file (Filename.concat dir "bad.brp") "func broken(\n";
      write_file (Filename.concat dir "good.brp") "good_value = 1\n";
      let sess = Session.create () in
      Modules.init_module_paths ~sess dir;
      match Modules.load_module ~sess "sample" dir with
      | None -> Alcotest.fail "expected parent module to load"
      | Some _ ->
          Alcotest.(check bool)
            "good sibling import loaded" true
            (Option.is_some (Modules.find_cached ~sess "./good"));
          Alcotest.(check bool)
            "bad import is not cached" false
            (Option.is_some (Modules.find_cached ~sess "./bad"));
          let errors = Modules.get_load_errors ~sess () in
          Alcotest.(check bool)
            "bad import produced a diagnostic" true
            (List.exists
               (fun (err : Ast.compiler_error) ->
                 match err.loc.loc_file with
                 | Some file -> Filename.basename file = "bad.brp"
                 | None -> false)
               errors))

let test_load_imports_uses_module_surface_imports () =
  with_temp_dir "blorp_surface_imports" (fun dir ->
      write_file (Filename.concat dir "dep.brp") "dep_value = 1\n";
      let sess = Session.create () in
      Modules.init_module_paths ~sess dir;
      let surface : Module_surface.t =
        {
          module_name = "root";
          imports =
            [
              {
                module_path = "./dep";
              };
            ];
          exports = [];
          private_names = [];
          private_traits = [];
        }
      in
      let loaded = Modules.load_imports ~sess ~surface [] dir in
      Alcotest.(check bool)
        "surface import loaded dependency" true
        (Option.is_some (Modules.find_cached ~sess "./dep"));
      Alcotest.(check (list string))
        "returned loaded dependency" [ "./dep" ]
        (List.map (fun (m : Modules.loaded_module) -> m.name) loaded))

let dep_value_surface ?(name = "dep_value") () : Module_surface.t =
  {
    module_name = "./dep";
    imports = [];
    exports =
      [
        {
          name;
          kind = Module_surface.Variable;
          source = Module_surface.Decl 0;
        };
      ];
    private_names = [];
    private_traits = [];
  }

let parsed_source_for_graph_test ~path source =
  match
    Modules.parse_typecheck_source ~filename:path ~bridge_read_file:false
      source
  with
  | Ok decls -> decls
  | Error err -> Alcotest.fail ("unexpected parse error: " ^ err.message)

let graph_source_for_test ~module_name ~path ~source ?surface decls :
    Modules.preloaded_parsed_source =
  {
    Modules.preload_module_name = module_name;
    preload_path = path;
    preload_origin = Session.User_module;
    preload_source = source;
    preload_decls = decls;
    preload_surface = surface;
  }

let empty_preloaded_graph_context : Modules.preloaded_module_graph_context =
  {
    preload_graph_std_dir = None;
    preload_graph_source_packages = [];
    preload_graph_package_roots = [];
  }

let test_preloaded_module_graph_rejects_invalid_module_surface () =
  with_temp_dir "blorp_invalid_graph_surface" (fun dir ->
      let main_path = Filename.concat dir "main.brp" in
      let dep_path = Filename.concat dir "dep.brp" in
      let main_source = "import:\n    ./dep: dep_value\n" in
      let dep_source = "dep_value = 1\n" in
      write_file main_path main_source;
      write_file dep_path dep_source;
      let main_decls =
        parsed_source_for_graph_test ~path:main_path main_source
      in
      let dep_decls = parsed_source_for_graph_test ~path:dep_path dep_source in
      let graph : Modules.preloaded_module_graph =
        {
          preload_graph_context = empty_preloaded_graph_context;
          preload_graph_sources =
            [
              graph_source_for_test ~module_name:"main" ~path:main_path
                ~source:main_source main_decls;
              graph_source_for_test ~module_name:"./dep" ~path:dep_path
                ~source:dep_source
                ~surface:(dep_value_surface ~name:"wrong_name" ())
                dep_decls;
            ];
          preload_graph_imports =
            [
              {
                preload_import_from_path = main_path;
                preload_import_from_module = "main";
                preload_import_path = "./dep";
                preload_import_resolved_path = Some dep_path;
                preload_import_resolved_module = Some "./dep";
                preload_import_resolved_origin = Some Session.User_module;
              };
            ];
        }
      in
      let sess = Session.create () in
      Modules.init_module_paths ~sess dir;
      Modules.load_preloaded_module_graph ~sess ~target_path:main_path graph;
      Alcotest.(check bool)
        "invalid surface not cached" false
        (Hashtbl.mem sess.parse_cache "./dep");
      Alcotest.(check bool)
        "invalid module not loaded" false
        (Option.is_some (Modules.find_cached ~sess "./dep"));
      Alcotest.(check bool)
        "invalid surface diagnostic" true
        (List.exists
           (fun (err : Ast.compiler_error) ->
             mentions err.message "invalid module surface")
           (Modules.get_load_errors ~sess ())))

let package_name_of_origin = function
  | Session.Native_package_module id -> Some (Session.package_id_name id)
  | Session.Package_module id -> Some (Session.package_id_name id)
  | Session.Stdlib_module | Session.User_module -> None

let write_source_package root ~name ~exports files =
  write_file
    (Filename.concat root "package.toml")
    (Printf.sprintf
       "[package]\n\
        name = %S\n\n\
        [compat]\n\
        std = \"preview-1\"\n\n\
        [exports]\n\
        modules = [%s]\n"
       name
       (String.concat ", " (List.map (Printf.sprintf "%S") exports)));
  let src = Filename.concat root "src" in
  Unix.mkdir src 0o700;
  List.iter
    (fun (rel, contents) ->
      let path = Filename.concat src rel in
      let dir = Filename.dirname path in
      if not (Sys.file_exists dir) then Unix.mkdir dir 0o700;
      write_file path contents)
    files

let test_blorp_toml_source_package_alias_resolves () =
  with_temp_dir "blorp_source_package_alias" (fun dir ->
      let app_dir = Filename.concat dir "app" in
      let vendor_dir = Filename.concat dir "vendor" in
      let package_dir = Filename.concat vendor_dir "sample" in
      Unix.mkdir app_dir 0o700;
      Unix.mkdir vendor_dir 0o700;
      Unix.mkdir package_dir 0o700;
      write_file
        (Filename.concat dir "blorp.toml")
        "[packages]\nsample = { path = \"vendor/sample\" }\n";
      write_source_package package_dir ~name:"sample"
        ~exports:[ "sample"; "sample/internal" ]
        [
          ("sample.brp", "import:\n    sample/internal as Internal\n");
          ("sample/internal.brp", "pure func answer() -> Int:\n    42\n");
        ];
      let sess = Session.create () in
      Modules.init_module_paths ~sess app_dir;
      match Modules.load_module ~sess "sample" app_dir with
      | None -> Alcotest.fail "expected package alias sample to resolve"
      | Some m -> (
          Alcotest.(check string)
            "package alias path"
            (Unix.realpath (Filename.concat package_dir "src/sample.brp"))
            m.path;
          Alcotest.(check (option string))
            "package origin alias" (Some "sample")
            (package_name_of_origin m.origin);
          match Modules.load_module ~sess "sample/internal" app_dir with
          | None ->
              Alcotest.fail "expected exported package submodule to resolve"
          | Some internal ->
              Alcotest.(check string)
                "package submodule path"
                (Unix.realpath
                   (Filename.concat package_dir "src/sample/internal.brp"))
                internal.path))

let test_blorp_toml_source_package_alias_can_differ_from_package_name () =
  with_temp_dir "blorp_source_package_alias_name" (fun dir ->
      let app_dir = Filename.concat dir "app" in
      let vendor_dir = Filename.concat dir "vendor" in
      let package_dir = Filename.concat vendor_dir "sample" in
      Unix.mkdir app_dir 0o700;
      Unix.mkdir vendor_dir 0o700;
      Unix.mkdir package_dir 0o700;
      write_file
        (Filename.concat dir "blorp.toml")
        "[packages.sample_v1]\npath = \"vendor/sample\"\n";
      write_source_package package_dir ~name:"sample" ~exports:[ "sample" ]
        [ ("sample.brp", "pure func answer() -> Int:\n    42\n") ];
      let sess = Session.create () in
      Modules.init_module_paths ~sess app_dir;
      match Modules.load_module ~sess "sample_v1" app_dir with
      | None -> Alcotest.fail "expected package alias sample_v1 to resolve"
      | Some m -> (
          Alcotest.(check string)
            "package alias path"
            (Unix.realpath (Filename.concat package_dir "src/sample.brp"))
            m.path;
          Alcotest.(check (option string))
            "package origin alias" (Some "sample_v1")
            (package_name_of_origin m.origin);
          match Modules.load_module ~sess "sample" app_dir with
          | None -> Alcotest.(check pass) "package name is not root alias" () ()
          | Some _ ->
              Alcotest.fail
                "package manifest name unexpectedly resolved as root alias"))

let package_config_errors config =
  with_temp_dir "blorp_source_package_config_error" (fun dir ->
      let app_dir = Filename.concat dir "app" in
      Unix.mkdir app_dir 0o700;
      write_file (Filename.concat dir "blorp.toml") config;
      let sess = Session.create () in
      Modules.init_module_paths ~sess app_dir;
      Modules.get_load_errors ~sess ()
      |> List.map (fun e -> e.Ast.message)
      |> String.concat "\n")

let source_package_hash root =
  match Package_check.check root with
  | Error errors ->
      Alcotest.failf "package check failed:\n%s"
        (Package_check.render_errors errors)
  | Ok checked -> (
      match
        Package_hash.hash_checked_package ~root
          ~source_files:checked.Package_check.source_files
      with
      | Ok hash -> hash
      | Error errors ->
          Alcotest.failf "package hash failed:\n%s"
            (Package_hash.render_errors errors))

let test_blorp_toml_package_table_requires_path_or_hash () =
  let errors = package_config_errors "[packages.sample]\n" in
  Alcotest.(check bool)
    "package table requires path or hash" true
    (mentions errors "must define path or hash")

let test_blorp_toml_package_table_rejects_extra_keys () =
  let errors =
    package_config_errors "[packages.sample]\nurl = \"https://example\"\n"
  in
  Alcotest.(check bool)
    "package table rejects extra keys" true
    (mentions errors "unsupported key \"url\"")

let test_blorp_toml_inline_package_rejects_extra_keys () =
  let errors =
    package_config_errors
      "[packages]\n\
       sample = { path = \"vendor/sample\", url = \"https://example\" }\n"
  in
  Alcotest.(check bool)
    "inline package rejects extra keys" true
    (mentions errors "unsupported key \"url\"")

let test_blorp_toml_package_alias_parses_from () =
  with_temp_dir "blorp_source_package_from" (fun dir ->
      let app_dir = Filename.concat dir "app" in
      Unix.mkdir app_dir 0o700;
      write_file
        (Filename.concat dir "blorp.toml")
        "[packages]\n\
         sample = { hash = \"0123456789abcdef\", from = \
         [\"artifacts/sample.blorpkg\"] }\n";
      match Package_config.package_paths_from app_dir with
      | None -> Alcotest.fail "expected blorp.toml to be discovered"
      | Some (_, parsed) -> (
          Alcotest.(check int)
            "no package config errors" 0
            (List.length parsed.Package_config.package_errors);
          match parsed.Package_config.package_paths with
          | [ entry ] ->
              Alcotest.(check string)
                "alias" "sample" entry.Package_config.package_alias;
              Alcotest.(check (list string))
                "from"
                [ Filename.concat dir "artifacts/sample.blorpkg" ]
                entry.Package_config.package_from
          | _ -> Alcotest.fail "expected one package entry"))

let test_blorp_toml_package_alias_rejects_missing_export () =
  with_temp_dir "blorp_source_package_missing_export" (fun dir ->
      let app_dir = Filename.concat dir "app" in
      let vendor_dir = Filename.concat dir "vendor" in
      let package_dir = Filename.concat vendor_dir "sample" in
      Unix.mkdir app_dir 0o700;
      Unix.mkdir vendor_dir 0o700;
      Unix.mkdir package_dir 0o700;
      write_file
        (Filename.concat dir "blorp.toml")
        "[packages]\nsample = { path = \"vendor/sample\" }\n";
      write_source_package package_dir ~name:"sample"
        ~exports:[ "sample"; "sample/missing" ]
        [ ("sample.brp", "pure func answer() -> Int:\n    42\n") ];
      let sess = Session.create () in
      Modules.init_module_paths ~sess app_dir;
      let errors =
        Modules.get_load_errors ~sess ()
        |> List.map (fun e -> e.Ast.message)
        |> String.concat "\n"
      in
      Alcotest.(check bool)
        "package alias rejects missing export" true
        (mentions errors "exports module \"sample/missing\"");
      match Modules.load_module ~sess "sample" app_dir with
      | None ->
          Alcotest.(check pass) "invalid package alias not registered" () ()
      | Some _ -> Alcotest.fail "invalid package alias unexpectedly resolved")

let test_blorp_toml_package_alias_accepts_matching_hash_pin () =
  with_temp_dir "blorp_source_package_hash_pin" (fun dir ->
      let app_dir = Filename.concat dir "app" in
      let vendor_dir = Filename.concat dir "vendor" in
      let package_dir = Filename.concat vendor_dir "sample" in
      Unix.mkdir app_dir 0o700;
      Unix.mkdir vendor_dir 0o700;
      Unix.mkdir package_dir 0o700;
      write_source_package package_dir ~name:"sample" ~exports:[ "sample" ]
        [ ("sample.brp", "pure func answer() -> Int:\n    42\n") ];
      let hash_pin = String.sub (source_package_hash package_dir) 0 16 in
      write_file
        (Filename.concat dir "blorp.toml")
        (Printf.sprintf
           "[packages]\nsample = { path = \"vendor/sample\", hash = %S }\n"
           hash_pin);
      let sess = Session.create () in
      Modules.init_module_paths ~sess app_dir;
      match Modules.load_module ~sess "sample" app_dir with
      | Some _ -> Alcotest.(check pass) "matching hash pin resolves" () ()
      | None -> Alcotest.fail "matching package hash pin did not resolve")

let test_blorp_toml_package_alias_rejects_hash_mismatch () =
  with_temp_dir "blorp_source_package_hash_mismatch" (fun dir ->
      let app_dir = Filename.concat dir "app" in
      let vendor_dir = Filename.concat dir "vendor" in
      let package_dir = Filename.concat vendor_dir "sample" in
      Unix.mkdir app_dir 0o700;
      Unix.mkdir vendor_dir 0o700;
      Unix.mkdir package_dir 0o700;
      write_source_package package_dir ~name:"sample" ~exports:[ "sample" ]
        [ ("sample.brp", "pure func answer() -> Int:\n    42\n") ];
      write_file
        (Filename.concat dir "blorp.toml")
        "[packages]\n\
         sample = { path = \"vendor/sample\", hash = \"ffffffffffffffff\" }\n";
      let sess = Session.create () in
      Modules.init_module_paths ~sess app_dir;
      let errors =
        Modules.get_load_errors ~sess ()
        |> List.map (fun e -> e.Ast.message)
        |> String.concat "\n"
      in
      Alcotest.(check bool)
        "hash mismatch diagnostic" true
        (mentions errors "hash mismatch");
      match Modules.load_module ~sess "sample" app_dir with
      | None -> Alcotest.(check pass) "mismatched hash pin not registered" () ()
      | Some _ ->
          Alcotest.fail "mismatched package hash pin unexpectedly resolved")

let test_blorp_toml_hash_only_missing_cache_suggests_fetch () =
  Test_helpers.with_isolated_env (fun () ->
      with_temp_dir "blorp_source_package_missing_cache" (fun dir ->
          let app_dir = Filename.concat dir "app" in
          let cache_dir = Filename.concat dir "cache" in
          Unix.mkdir app_dir 0o700;
          Unix.mkdir cache_dir 0o700;
          with_env "BLORP_PACKAGE_CACHE" cache_dir (fun () ->
              write_file
                (Filename.concat dir "blorp.toml")
                "[packages]\n\
                 sample = { hash = \"0123456789abcdef\", from = \
                 [\"artifacts/sample.blorpkg\"] }\n";
              let sess = Session.create () in
              Modules.init_module_paths ~sess app_dir;
              let errors = Modules.get_load_errors ~sess () in
              let messages =
                errors
                |> List.map (fun e -> e.Ast.message)
                |> String.concat "\n"
              in
              let helps =
                errors
                |> List.filter_map (fun e -> e.Ast.help)
                |> String.concat "\n"
              in
              Alcotest.(check bool)
                "missing cache diagnostic names alias" true
                (mentions messages "package alias \"sample\"");
              Alcotest.(check bool)
                "missing cache diagnostic names cache" true
                (mentions messages "local package cache");
              Alcotest.(check bool)
                "missing cache diagnostic suggests fetch alias" true
                (mentions helps "blorp package fetch sample"))))

let test_source_package_alias_reports_unexported_module () =
  with_temp_dir "blorp_source_package_unexported" (fun dir ->
      let app_dir = Filename.concat dir "app" in
      let vendor_dir = Filename.concat dir "vendor" in
      let package_dir = Filename.concat vendor_dir "sample" in
      Unix.mkdir app_dir 0o700;
      Unix.mkdir vendor_dir 0o700;
      Unix.mkdir package_dir 0o700;
      write_file
        (Filename.concat dir "blorp.toml")
        "[packages]\nsample = { path = \"vendor/sample\" }\n";
      write_source_package package_dir ~name:"sample" ~exports:[ "sample" ]
        [
          ("sample.brp", "pure func answer() -> Int:\n    42\n");
          ("sample/internal.brp", "pure func hidden() -> Int:\n    7\n");
        ];
      let sess = Session.create () in
      Modules.init_module_paths ~sess app_dir;
      ignore (Modules.load_module ~sess "sample/internal" app_dir);
      let errors =
        Modules.get_load_errors ~sess ()
        |> List.map (fun e -> e.Ast.message)
        |> String.concat "\n"
      in
      Alcotest.(check bool)
        "unexported package submodule diagnostic" true
        (mentions errors
           "package alias \"sample\" does not export module \"sample/internal\""))

let test_source_package_rejects_pkg_import () =
  with_temp_dir "blorp_source_package_reject_pkg" (fun dir ->
      let app_dir = Filename.concat dir "app" in
      let vendor_dir = Filename.concat dir "vendor" in
      let package_dir = Filename.concat vendor_dir "sample" in
      Unix.mkdir app_dir 0o700;
      Unix.mkdir vendor_dir 0o700;
      Unix.mkdir package_dir 0o700;
      write_file
        (Filename.concat dir "blorp.toml")
        "[packages]\nsample = { path = \"vendor/sample\" }\n";
      write_source_package package_dir ~name:"sample" ~exports:[ "sample" ]
        [
          ( "sample.brp",
            "import:\n\
            \    pkg/crypto as Crypto\n\n\
             pure func answer() -> Int:\n\
            \    0\n" );
        ];
      let sess = Session.create () in
      Modules.init_module_paths ~sess app_dir;
      ignore (Modules.load_module ~sess "sample" app_dir);
      let errors =
        Modules.get_load_errors ~sess ()
        |> List.map (fun e -> e.Ast.message)
        |> String.concat "\n"
      in
      Alcotest.(check bool)
        "source package rejects pkg import" true
        (mentions errors "source packages cannot import pkg/... modules"))

let test_source_package_rejects_root_project_import () =
  Test_helpers.with_isolated_env (fun () ->
      with_temp_dir "blorp_source_package_reject_root_import" (fun dir ->
          let app_dir = Filename.concat dir "app" in
          let vendor_dir = Filename.concat dir "vendor" in
          let package_dir = Filename.concat vendor_dir "sample" in
          Unix.mkdir app_dir 0o700;
          Unix.mkdir vendor_dir 0o700;
          Unix.mkdir package_dir 0o700;
          write_file
            (Filename.concat dir "blorp.toml")
            "[packages]\nsample = { path = \"vendor/sample\" }\n";
          write_file
            (Filename.concat app_dir "root_helper.brp")
            "pure func answer() -> Int:\n    41\n";
          write_source_package package_dir ~name:"sample" ~exports:[ "sample" ]
            [
              ( "sample.brp",
                "import:\n\
                \    root_helper: answer\n\n\
                 pure func package_answer() -> Int:\n\
                \    answer()\n" );
            ];
          let main_path = Filename.concat app_dir "main.brp" in
          let source =
            "import:\n\
            \    sample: package_answer\n\n\
             func main(args: List[String]) -> Int:\n\
            \    package_answer()\n"
          in
          match Pipeline.typecheck_module_only ~filename:main_path ~source with
          | Ok _ ->
              Alcotest.fail
                "expected package source importing root module to fail"
          | Error errors ->
              let text =
                errors
                |> List.map (fun e -> e.Ast.message)
                |> String.concat "\n"
              in
              Alcotest.(check bool)
                "source package rejects root import" true
                (mentions text
                   "source packages may import only std modules or modules \
                    inside their own package")))

let test_source_package_rejects_other_package_alias_import () =
  Test_helpers.with_isolated_env (fun () ->
      with_temp_dir "blorp_source_package_reject_other_alias" (fun dir ->
          let app_dir = Filename.concat dir "app" in
          let vendor_dir = Filename.concat dir "vendor" in
          let sample_dir = Filename.concat vendor_dir "sample" in
          let other_dir = Filename.concat vendor_dir "other" in
          Unix.mkdir app_dir 0o700;
          Unix.mkdir vendor_dir 0o700;
          Unix.mkdir sample_dir 0o700;
          Unix.mkdir other_dir 0o700;
          write_file
            (Filename.concat dir "blorp.toml")
            "[packages]\n\
             sample = { path = \"vendor/sample\" }\n\
             other = { path = \"vendor/other\" }\n";
          write_source_package other_dir ~name:"other" ~exports:[ "other" ]
            [ ("other.brp", "pure func answer() -> Int:\n    41\n") ];
          write_source_package sample_dir ~name:"sample" ~exports:[ "sample" ]
            [
              ( "sample.brp",
                "import:\n\
                \    other: answer\n\n\
                 pure func package_answer() -> Int:\n\
                \    answer()\n" );
            ];
          let main_path = Filename.concat app_dir "main.brp" in
          let source =
            "import:\n\
            \    sample: package_answer\n\n\
             func main(args: List[String]) -> Int:\n\
            \    package_answer()\n"
          in
          match Pipeline.typecheck_module_only ~filename:main_path ~source with
          | Ok _ ->
              Alcotest.fail
                "expected package source importing another package alias to \
                 fail"
          | Error errors ->
              let text =
                errors
                |> List.map (fun e -> e.Ast.message)
                |> String.concat "\n"
              in
              Alcotest.(check bool)
                "source package rejects other package alias" true
                (mentions text
                   "source packages cannot import other package aliases")))

let test_source_package_relative_import_keeps_package_origin () =
  Test_helpers.with_isolated_env (fun () ->
      with_temp_dir "blorp_source_package_relative_origin" (fun dir ->
          let app_dir = Filename.concat dir "app" in
          let vendor_dir = Filename.concat dir "vendor" in
          let package_dir = Filename.concat vendor_dir "sample" in
          Unix.mkdir app_dir 0o700;
          Unix.mkdir vendor_dir 0o700;
          Unix.mkdir package_dir 0o700;
          write_file
            (Filename.concat dir "blorp.toml")
            "[packages]\nsample = { path = \"vendor/sample\" }\n";
          write_source_package package_dir ~name:"sample" ~exports:[ "sample" ]
            [
              ( "sample.brp",
                "import:\n\
                \    ./helper as Helper\n\n\
                 pure func answer() -> Int:\n\
                \    Helper.answer()\n" );
              ( "helper.brp",
                "foreign(include: \"math.h\"):\n\
                \    func c_abs(x: Int) -> Int = \"abs\"\n\n\
                 pure func answer() -> Int:\n\
                \    1\n" );
            ];
          let main_path = Filename.concat app_dir "main.brp" in
          let source =
            "import:\n\
            \    sample: answer\n\n\
             func main(args: List[String]) -> Int:\n\
            \    answer()\n"
          in
          match Pipeline.typecheck_module_only ~filename:main_path ~source with
          | Error errors ->
              let text =
                errors
                |> List.map (fun e -> e.Ast.message)
                |> String.concat "\n"
              in
              Alcotest.(check bool)
                "relative helper keeps package origin" true
                (mentions text
                   "'foreign' declarations cannot be used in source packages")
          | Ok _ ->
              Alcotest.fail
                "expected package-relative helper foreign declaration to fail"))

let test_pkg_root_discovered_from_base_dir () =
  with_temp_dir "blorp_pkg_root" (fun dir ->
      let pkg_root = Filename.concat dir "pkg" in
      let src_dir = Filename.concat dir "src" in
      Unix.mkdir pkg_root 0o700;
      Unix.mkdir src_dir 0o700;
      write_file
        (Filename.concat pkg_root "local_math.brp")
        "pure func double(x: Int) -> Int:\n    x * 2\n";
      let sess = Session.create () in
      Modules.init_module_paths ~sess src_dir;
      let expected_root = Unix.realpath pkg_root in
      Alcotest.(check bool)
        "package root discovered" true
        (List.mem expected_root (Modules.package_roots ~sess ())))

let test_pkg_import_resolves_with_package_origin () =
  with_temp_dir "blorp_pkg_import" (fun dir ->
      let pkg_root = Filename.concat dir "pkg" in
      let src_dir = Filename.concat dir "src" in
      Unix.mkdir pkg_root 0o700;
      Unix.mkdir src_dir 0o700;
      let pkg_file = Filename.concat pkg_root "local_math.brp" in
      write_file pkg_file "pure func double(x: Int) -> Int:\n    x * 2\n";
      let sess = Session.create () in
      Modules.init_module_paths ~sess src_dir;
      match Modules.load_module ~sess "pkg/local_math" src_dir with
      | None -> Alcotest.fail "expected pkg/local_math to resolve"
      | Some m ->
          Alcotest.(check string)
            "package module path" (Unix.realpath pkg_file) m.path;
          Alcotest.(check (option string))
            "package origin id" (Some "local_math")
            (package_name_of_origin m.origin))

let test_pkg_nested_import_uses_top_level_package_id () =
  with_temp_dir "blorp_pkg_nested" (fun dir ->
      let pkg_root = Filename.concat dir "pkg" in
      let src_dir = Filename.concat dir "src" in
      let sqlite_dir = Filename.concat pkg_root "sqlite" in
      Unix.mkdir pkg_root 0o700;
      Unix.mkdir src_dir 0o700;
      Unix.mkdir sqlite_dir 0o700;
      write_file
        (Filename.concat sqlite_dir "client.brp")
        "pure func version() -> Int:\n    1\n";
      let sess = Session.create () in
      Modules.init_module_paths ~sess src_dir;
      match Modules.load_module ~sess "pkg/sqlite/client" src_dir with
      | None -> Alcotest.fail "expected pkg/sqlite/client to resolve"
      | Some m ->
          Alcotest.(check (option string))
            "package origin id" (Some "sqlite")
            (package_name_of_origin m.origin))

let test_bare_import_does_not_resolve_package_root () =
  with_temp_dir "blorp_pkg_bare" (fun dir ->
      let pkg_root = Filename.concat dir "pkg" in
      let src_dir = Filename.concat dir "src" in
      Unix.mkdir pkg_root 0o700;
      Unix.mkdir src_dir 0o700;
      write_file
        (Filename.concat pkg_root "local_math.brp")
        "pure func double(x: Int) -> Int:\n    x * 2\n";
      let sess = Session.create () in
      Modules.init_module_paths ~sess src_dir;
      match Modules.load_module ~sess "local_math" src_dir with
      | None -> Alcotest.(check pass) "bare package miss" () ()
      | Some _ ->
          Alcotest.fail "bare import unexpectedly resolved from a package root")

let test_typecheck_module_only_reports_dependency_errors () =
  Test_helpers.with_isolated_env (fun () ->
      with_temp_dir "blorp_dep_typecheck" (fun dir ->
          let helper_path = Filename.concat dir "helper.brp" in
          write_file helper_path
            "func working() -> Int:\n\
            \    42\n\n\
             func broken() -> Int:\n\
            \    missing_dependency_name + 1\n";
          let main_path = Filename.concat dir "main.brp" in
          let source =
            "import:\n\
            \    ./helper: working\n\n\
             func main(args: List[String]) -> Int:\n\
            \    working()\n"
          in
          match Pipeline.typecheck_module_only ~filename:main_path ~source with
          | Error errors ->
              let found =
                List.exists
                  (fun (e : Ast.compiler_error) ->
                    mentions e.message
                      "Undefined identifier: missing_dependency_name")
                  errors
              in
              Alcotest.(check bool) "dependency error surfaced" true found
          | Ok _ ->
              Alcotest.fail
                "expected dependency type error from imported helper"))

let test_typecheck_module_only_reports_target_errors () =
  Test_helpers.with_isolated_env (fun () ->
      with_temp_dir "blorp_target_typecheck" (fun dir ->
          let main_path = Filename.concat dir "main.brp" in
          let source =
            "func main(args: List[String]) -> Int:\n\
            \    missing_target_name + 1\n"
          in
          match Pipeline.typecheck_module_only ~filename:main_path ~source with
          | Error errors ->
              let found =
                List.exists
                  (fun (e : Ast.compiler_error) ->
                    mentions e.message
                      "Undefined identifier: missing_target_name")
                  errors
              in
              Alcotest.(check bool) "target error surfaced" true found
          | Ok _ ->
              Alcotest.fail
                "expected target type error from analysis-only typecheck"))

(* ============================================================================
   Trait registry (Phase: uniform trait inheritance, Step 2)
   ============================================================================

   The session-scoped trait registry is what makes the supertrait graph
   globally visible once a module is loaded, regardless of whether the
   current file imports it. These tests guard four invariants:

   1. Public trait decls land in the registry when their module loads.
   2. Lookup returns the original AST + owning [loaded_module].
   3. Private traits stay module-scoped (never registered).
   4. Sessions are independent — a registration in one never leaks. *)

let mk_trait_decl ?(supertraits = []) name : Ast.decl =
  let trait : Ast.trait_decl =
    {
      trait_name = name;
      trait_type_params = [];
      trait_supertraits = supertraits;
      trait_methods = [];
    }
  in
  { decl_desc = Ast.DTrait trait; decl_loc = Ast.dummy_loc; decl_doc = None }

let mk_private_trait_decl name : Ast.decl =
  let inner = mk_trait_decl name in
  { decl_desc = Ast.DPrivate inner; decl_loc = Ast.dummy_loc; decl_doc = None }

let mk_loaded_module ~name ~decls : Session.loaded_module =
  {
    name;
    path = "<test>";
    origin = Session.User_module;
    decls;
    exports = [];
    surface = None;
    typed_decls = None;
    typed_import_bindings = None;
  }

let mk_record_decl name : Ast.decl =
  let record : Ast.record_decl =
    {
      record_name = name;
      record_type_params = [];
      record_fields = [];
      record_is_value = false;
      record_is_builtin = false;
    }
  in
  { decl_desc = Ast.DRecord record; decl_loc = Ast.dummy_loc; decl_doc = None }

let test_reusable_reset_preserves_only_parse_cache () =
  let s = Session.create () in
  let parsed_entry : Session.parsed_module_cache_entry =
    {
      parsed_path = "<cached>";
      parsed_origin = Session.User_module;
      parsed_source_hash = "hash";
      parsed_trust_current_source = true;
      parsed_decls = [];
      parsed_exports = [];
      parsed_surface = None;
    }
  in
  let pkg : Session.source_package =
    {
      source_package_alias = "demo";
      source_package_name = "demo";
      source_package_root = "/tmp/demo";
      source_package_source_dir = "/tmp/demo/src";
      source_package_exports = [];
    }
  in
  s.search_paths <- [ "/tmp/search" ];
  s.package_roots <- [ "/tmp/pkg" ];
  s.source_packages <- [ pkg ];
  Hashtbl.add s.module_cache "demo/mod" (mk_loaded_module ~name:"demo/mod" ~decls:[]);
  Hashtbl.add s.parse_cache "demo/mod" parsed_entry;
  Hashtbl.add s.type_index "Widget" (Session.UniqueTypeHome "demo/mod");
  Hashtbl.add s.resource_cleanup_index "Widget"
    (Ast.ResourceCleanupBuiltin "cleanup_widget");
  Hashtbl.add s.trait_index "Renderable" "demo/mod";
  s.std_override_dir <- Some "/tmp/std";
  s.std_override_active <- true;
  s.std_source_dir <- Some "/tmp/std";
  s.load_errors <-
    [
      {
        Ast.message = "stale";
        loc = Ast.dummy_loc;
        phase = Ast.TypeCheck;
        kind = Ast.OtherError;
        notes = [];
        help = None;
      };
    ];
  s.prelude_modules_loaded <- true;
  Hashtbl.add s.overloads "f" [];
  Hashtbl.add s.impl_index "Renderable" [];
  Hashtbl.add s.ufcs_methods "label" [];
  s.builtins_populated <- true;
  s.def_id_counter <- 5;
  s.fresh_meta_counter <- 3;
  s.meta_origin <- [ (1, "T") ];
  Hashtbl.add s.meta_env 1 Types.ty_int;
  s.lower_destruct_counter <- 1;
  s.lower_param_counter <- 1;
  s.lower_question_bind_counter <- 1;
  s.lower_resource_counter <- 1;
  s.lower_task_scope_counter <- 4;
  s.lower_current_task_scope_id <- 2;
  s.desugar_counter <- 1;
  s.ssa_mut_counter <- 1;
  Session.reset_compilation_state_preserving_parse_cache s;
  Alcotest.(check bool)
    "parse cache preserved" true
    (Hashtbl.find_opt s.parse_cache "demo/mod" = Some parsed_entry);
  Alcotest.(check int) "module cache cleared" 0 (Hashtbl.length s.module_cache);
  Alcotest.(check int) "type index cleared" 0 (Hashtbl.length s.type_index);
  Alcotest.(check int)
    "resource cleanup index cleared" 0
    (Hashtbl.length s.resource_cleanup_index);
  Alcotest.(check int) "trait index cleared" 0 (Hashtbl.length s.trait_index);
  Alcotest.(check (list string)) "search paths cleared" [] s.search_paths;
  Alcotest.(check int) "package roots cleared" 0 (List.length s.package_roots);
  Alcotest.(check int)
    "source packages cleared" 0
    (List.length s.source_packages);
  Alcotest.(check bool) "std override inactive" false s.std_override_active;
  Alcotest.(check (option string)) "std dir cleared" None s.std_override_dir;
  Alcotest.(check (option string)) "std source cleared" None s.std_source_dir;
  Alcotest.(check int) "load errors cleared" 0 (List.length s.load_errors);
  Alcotest.(check bool)
    "prelude flag cleared" false s.prelude_modules_loaded;
  Alcotest.(check int) "overloads cleared" 0 (Hashtbl.length s.overloads);
  Alcotest.(check int) "impls cleared" 0 (Hashtbl.length s.impl_index);
  Alcotest.(check int) "ufcs cleared" 0 (Hashtbl.length s.ufcs_methods);
  Alcotest.(check bool) "builtins flag cleared" false s.builtins_populated;
  Alcotest.(check int) "def ids reset" 0 s.def_id_counter;
  Alcotest.(check int) "meta counter reset" 0 s.fresh_meta_counter;
  Alcotest.(check int) "meta origins cleared" 0 (List.length s.meta_origin);
  Alcotest.(check int) "meta env cleared" 0 (Hashtbl.length s.meta_env);
  Alcotest.(check int) "lower destruct reset" 0 s.lower_destruct_counter;
  Alcotest.(check int) "lower param reset" 0 s.lower_param_counter;
  Alcotest.(check int)
    "question bind reset" 0 s.lower_question_bind_counter;
  Alcotest.(check int) "resource reset" 0 s.lower_resource_counter;
  Alcotest.(check int) "task counter reset" 1 s.lower_task_scope_counter;
  Alcotest.(check int) "task scope reset" 0 s.lower_current_task_scope_id;
  Alcotest.(check int) "desugar reset" 0 s.desugar_counter;
  Alcotest.(check int) "ssa reset" 0 s.ssa_mut_counter

let test_modules_reset_clears_type_index () =
  let s = Session.create () in
  let m =
    mk_loaded_module ~name:"test/types" ~decls:[ mk_record_decl "Widget" ]
  in
  Session.register_module_types s m;
  Alcotest.(check (option string))
    "registered type home" (Some "test/types")
    (Session.find_type_home s "Widget");
  Modules.reset ~sess:s ();
  Alcotest.(check (option string))
    "type home cleared" None
    (Session.find_type_home s "Widget")

let test_type_index_preserves_ambiguous_homes () =
  let s = Session.create () in
  let a = mk_loaded_module ~name:"test/a" ~decls:[ mk_record_decl "Widget" ] in
  let b = mk_loaded_module ~name:"test/b" ~decls:[ mk_record_decl "Widget" ] in
  Session.register_module_types s a;
  Session.register_module_types s b;
  Alcotest.(check (option string))
    "ambiguous type has no single home" None
    (Session.find_type_home s "Widget");
  Alcotest.(check (list string))
    "ambiguous type homes" [ "test/a"; "test/b" ]
    (Session.find_type_homes s "Widget")

let test_modules_reset_clears_resource_cleanup_index () =
  let s = Session.create () in
  Session.register_resource_cleanup s ~type_name:"Widget"
    (Ast.ResourceCleanupBuiltin "close_widget");
  (match Session.find_resource_cleanup s "Widget" with
  | Some (Ast.ResourceCleanupBuiltin name) ->
      Alcotest.(check string) "registered cleanup" "close_widget" name
  | None -> Alcotest.fail "expected registered cleanup");
  Modules.reset ~sess:s ();
  Alcotest.(check bool)
    "resource cleanup cleared" true
    (Session.find_resource_cleanup s "Widget" = None)

let test_resource_cleanup_registry_isolated_across_sessions () =
  let s1 = Session.create () in
  let s2 = Session.create () in
  Session.register_resource_cleanup s1 ~type_name:"Widget"
    (Ast.ResourceCleanupBuiltin "close_widget");
  (match Session.find_resource_cleanup s1 "Widget" with
  | Some (Ast.ResourceCleanupBuiltin name) ->
      Alcotest.(check string) "registered cleanup" "close_widget" name
  | None -> Alcotest.fail "expected registered cleanup");
  Alcotest.(check bool)
    "s2 does not see s1 cleanup" true
    (Session.find_resource_cleanup s2 "Widget" = None)

(* ============================================================================
   DefId minting + UFCS def_id table
   ============================================================================ *)

let test_def_id_counter_independent_across_sessions () =
  let s1 = Session.create () in
  let s2 = Session.create () in
  let _ = Session.mint_def_id s1 in
  let _ = Session.mint_def_id s1 in
  let _ = Session.mint_def_id s1 in
  Alcotest.(check int) "s1 counter advanced" 3 s1.def_id_counter;
  Alcotest.(check int) "s2 counter untouched" 0 s2.def_id_counter

let test_mint_def_id_monotonic () =
  let s = Session.create () in
  let a = Session.mint_def_id s in
  let b = Session.mint_def_id s in
  let c = Session.mint_def_id s in
  Alcotest.(check bool) "strictly increasing" true (a < b && b < c);
  Alcotest.(check bool) "distinct" true (a <> b && b <> c && a <> c)

let test_reserve_def_id_floor () =
  let s = Session.create () in
  Alcotest.(check int) "first id" 0 (Session.mint_def_id s);
  Session.reserve_def_id_floor s 10;
  Alcotest.(check int) "reserved floor" 10 (Session.mint_def_id s);
  Session.reserve_def_id_floor s 5;
  Alcotest.(check int) "lower floor does not rewind" 11 (Session.mint_def_id s)

let test_trait_registration_populates_index () =
  let s = Session.create () in
  let m = mk_loaded_module ~name:"test/mymod" ~decls:[ mk_trait_decl "Foo" ] in
  Hashtbl.add s.module_cache m.name m;
  Session.register_module_traits s m;
  Alcotest.(check (option string))
    "Foo → test/mymod" (Some "test/mymod")
    (Hashtbl.find_opt s.trait_index "Foo")

let test_trait_lookup_returns_decl () =
  let s = Session.create () in
  let trait_decl = mk_trait_decl "Bar" ~supertraits:[ "Baseline" ] in
  let m = mk_loaded_module ~name:"test/x" ~decls:[ trait_decl ] in
  Hashtbl.add s.module_cache m.name m;
  Session.register_module_traits s m;
  match Session.find_trait_decl s "Bar" with
  | None -> Alcotest.fail "expected trait decl"
  | Some (td, owner) ->
      Alcotest.(check string) "trait name" "Bar" td.trait_name;
      Alcotest.(check (list string))
        "supertraits" [ "Baseline" ] td.trait_supertraits;
      Alcotest.(check string) "owning module" "test/x" owner.name

let test_private_traits_are_not_registered () =
  let s = Session.create () in
  let m =
    mk_loaded_module ~name:"test/secret"
      ~decls:[ mk_private_trait_decl "Hidden" ]
  in
  Hashtbl.add s.module_cache m.name m;
  Session.register_module_traits s m;
  Alcotest.(check (option string))
    "Hidden not in index" None
    (Hashtbl.find_opt s.trait_index "Hidden");
  Alcotest.(check bool)
    "lookup returns None" true
    (Session.find_trait_decl s "Hidden" = None)

let test_trait_registry_isolated_across_sessions () =
  let s1 = Session.create () in
  let s2 = Session.create () in
  let m = mk_loaded_module ~name:"test/one" ~decls:[ mk_trait_decl "Solo" ] in
  Hashtbl.add s1.module_cache m.name m;
  Session.register_module_traits s1 m;
  Alcotest.(check bool)
    "s1 has Solo" true
    (Session.find_trait_decl s1 "Solo" <> None);
  Alcotest.(check bool)
    "s2 does NOT have Solo" true
    (Session.find_trait_decl s2 "Solo" = None)

let test_trait_lookup_misses_return_none () =
  let s = Session.create () in
  Alcotest.(check bool)
    "unknown trait" true
    (Session.find_trait_decl s "Nonexistent" = None)

let test_same_module_re_registration_is_idempotent () =
  (* Loading the same module twice (e.g. via multiple import chains)
     must not flag a conflict. The trait_index points at the module
     name, and re-registering with the same name is a no-op. *)
  let s = Session.create () in
  let m = mk_loaded_module ~name:"solo/mod" ~decls:[ mk_trait_decl "Twice" ] in
  Hashtbl.add s.module_cache m.name m;
  Session.register_module_traits s m;
  Session.register_module_traits s m;
  Alcotest.(check int)
    "no load errors on re-registration" 0
    (List.length s.load_errors);
  Alcotest.(check bool)
    "trait still findable" true
    (Session.find_trait_decl s "Twice" <> None)

let test_cross_module_conflict_surfaces_error () =
  (* Two different modules declare [trait Clash] → conflict error
     written to session.load_errors. The first registration wins; the
     second is ignored (stale index replace would mask the issue on
     later lookups). *)
  let s = Session.create () in
  let m1 = mk_loaded_module ~name:"mod/a" ~decls:[ mk_trait_decl "Clash" ] in
  let m2 = mk_loaded_module ~name:"mod/b" ~decls:[ mk_trait_decl "Clash" ] in
  Hashtbl.add s.module_cache m1.name m1;
  Hashtbl.add s.module_cache m2.name m2;
  Session.register_module_traits s m1;
  Session.register_module_traits s m2;
  Alcotest.(check int) "one conflict error" 1 (List.length s.load_errors);
  (* Index still points at the first registration, so downstream
     lookups don't silently pick up the second module's version. *)
  match Session.find_trait_decl s "Clash" with
  | Some (_, owner) ->
      Alcotest.(check string) "first registration wins" "mod/a" owner.name
  | None -> Alcotest.fail "expected find to still succeed"

(* ============================================================================
   Suite
   ============================================================================ *)

let suite =
  [
    ( "meta_isolation",
      [
        Alcotest.test_case "fresh_meta_counters" `Quick
          test_fresh_meta_counters_independent;
        Alcotest.test_case "meta_env" `Quick test_meta_env_isolated;
        Alcotest.test_case "reset_meta" `Quick
          test_reset_meta_clears_only_that_session;
        Alcotest.test_case "raw source parse has no frontend selector" `Quick
          test_parse_raw_source_uses_session_without_frontend_selector;
      ] );
    ( "modules_isolation",
      [
        Alcotest.test_case "module_cache" `Quick test_module_cache_independent;
        Alcotest.test_case "load_errors" `Quick test_load_errors_independent;
        Alcotest.test_case "module origin policy" `Quick
          test_module_origin_policy_helpers;
        Alcotest.test_case "search_paths" `Quick test_search_paths_independent;
        Alcotest.test_case "reusable reset preserves only parse cache" `Quick
          test_reusable_reset_preserves_only_parse_cache;
        Alcotest.test_case "reset clears type index" `Quick
          test_modules_reset_clears_type_index;
        Alcotest.test_case "ambiguous type homes" `Quick
          test_type_index_preserves_ambiguous_homes;
        Alcotest.test_case "reset clears resource cleanup index" `Quick
          test_modules_reset_clears_resource_cleanup_index;
        Alcotest.test_case "resource cleanup registry isolated" `Quick
          test_resource_cleanup_registry_isolated_across_sessions;
        Alcotest.test_case "blorp.toml std path" `Quick
          test_blorp_toml_std_path_sets_override;
        Alcotest.test_case "BLORP_STD overrides blorp.toml" `Quick
          test_blorp_toml_is_lower_priority_than_env;
        Alcotest.test_case "existing std override wins" `Quick
          test_blorp_toml_does_not_replace_existing_override;
        Alcotest.test_case "std dir not guessed without config" `Quick
          test_std_dir_is_not_guessed_without_explicit_config;
        Alcotest.test_case "source origin uses configured std root" `Quick
          test_source_origin_uses_configured_std_root;
        Alcotest.test_case "import parse error keeps sibling imports" `Quick
          test_import_parse_error_does_not_block_sibling_import;
        Alcotest.test_case "load_imports uses module surface imports" `Quick
          test_load_imports_uses_module_surface_imports;
        Alcotest.test_case "preloaded module graph rejects invalid surface"
          `Quick test_preloaded_module_graph_rejects_invalid_module_surface;
        Alcotest.test_case "source package alias resolves" `Quick
          test_blorp_toml_source_package_alias_resolves;
        Alcotest.test_case "source package alias can differ from name" `Quick
          test_blorp_toml_source_package_alias_can_differ_from_package_name;
        Alcotest.test_case "package table requires path or hash" `Quick
          test_blorp_toml_package_table_requires_path_or_hash;
        Alcotest.test_case "package table rejects extra keys" `Quick
          test_blorp_toml_package_table_rejects_extra_keys;
        Alcotest.test_case "inline package rejects extra keys" `Quick
          test_blorp_toml_inline_package_rejects_extra_keys;
        Alcotest.test_case "package alias parses from" `Quick
          test_blorp_toml_package_alias_parses_from;
        Alcotest.test_case "package alias rejects missing export" `Quick
          test_blorp_toml_package_alias_rejects_missing_export;
        Alcotest.test_case "package alias accepts matching hash pin" `Quick
          test_blorp_toml_package_alias_accepts_matching_hash_pin;
        Alcotest.test_case "package alias rejects hash mismatch" `Quick
          test_blorp_toml_package_alias_rejects_hash_mismatch;
        Alcotest.test_case "hash-only package missing cache suggests fetch"
          `Quick test_blorp_toml_hash_only_missing_cache_suggests_fetch;
        Alcotest.test_case "package alias reports unexported module" `Quick
          test_source_package_alias_reports_unexported_module;
        Alcotest.test_case "source package rejects pkg import" `Quick
          test_source_package_rejects_pkg_import;
        Alcotest.test_case "source package rejects root project import" `Quick
          test_source_package_rejects_root_project_import;
        Alcotest.test_case "source package rejects other package alias import"
          `Quick test_source_package_rejects_other_package_alias_import;
        Alcotest.test_case "source package relative import origin" `Quick
          test_source_package_relative_import_keeps_package_origin;
        Alcotest.test_case "pkg root discovered from base dir" `Quick
          test_pkg_root_discovered_from_base_dir;
        Alcotest.test_case "pkg import resolves with package origin" `Quick
          test_pkg_import_resolves_with_package_origin;
        Alcotest.test_case "pkg nested import uses top-level package id" `Quick
          test_pkg_nested_import_uses_top_level_package_id;
        Alcotest.test_case "bare import skips package roots" `Quick
          test_bare_import_does_not_resolve_package_root;
      ] );
    ( "ambient",
      [
        Alcotest.test_case "with_current_restores" `Quick
          test_with_current_restores_previous;
        Alcotest.test_case "with_current_exception" `Quick
          test_with_current_restores_on_exception;
        Alcotest.test_case "fresh_meta_ambient" `Quick
          test_fresh_meta_uses_ambient;
      ] );
    ( "assert_in_scope",
      [
        Alcotest.test_case "raises outside frame" `Quick
          test_assert_in_scope_raises_outside_frame;
        Alcotest.test_case "ok inside frame" `Quick
          test_assert_in_scope_ok_inside_frame;
        Alcotest.test_case "nested frames" `Quick
          test_assert_in_scope_nested_frames;
      ] );
    ( "pipeline_isolation",
      [
        Alcotest.test_case "module_cache untouched" `Quick
          test_compile_isolates_caller_module_cache;
        Alcotest.test_case "no stale load_errors" `Quick
          test_compile_does_not_inherit_prior_load_errors;
        Alcotest.test_case "analysis dependency errors" `Quick
          test_typecheck_module_only_reports_dependency_errors;
        Alcotest.test_case "analysis target errors" `Quick
          test_typecheck_module_only_reports_target_errors;
      ] );
    ( "def_id",
      [
        Alcotest.test_case "counter independent" `Quick
          test_def_id_counter_independent_across_sessions;
        Alcotest.test_case "mint monotonic" `Quick test_mint_def_id_monotonic;
        Alcotest.test_case "reserve floor" `Quick test_reserve_def_id_floor;
      ] );
    ( "trait_registry",
      [
        Alcotest.test_case "populates index" `Quick
          test_trait_registration_populates_index;
        Alcotest.test_case "lookup returns decl" `Quick
          test_trait_lookup_returns_decl;
        Alcotest.test_case "private traits excluded" `Quick
          test_private_traits_are_not_registered;
        Alcotest.test_case "isolated across sessions" `Quick
          test_trait_registry_isolated_across_sessions;
        Alcotest.test_case "miss returns None" `Quick
          test_trait_lookup_misses_return_none;
        Alcotest.test_case "same module idempotent" `Quick
          test_same_module_re_registration_is_idempotent;
        Alcotest.test_case "cross-module conflict" `Quick
          test_cross_module_conflict_surfaces_error;
      ] );
  ]
