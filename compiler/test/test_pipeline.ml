(** Tests for the public Pipeline entry points.

    These cover cross-file/module orchestration bugs that are too broad
    for parser, infer, or individual Core-pass tests. *)

open Blorp

let contains = Test_helpers.contains_substring

let with_temp_dir prefix f =
  let dir = Filename.temp_file prefix "" in
  Sys.remove dir;
  Unix.mkdir dir 0o700;
  Fun.protect
    ~finally:(fun () ->
      let rec remove_tree path =
        if Sys.file_exists path && Sys.is_directory path then begin
          Array.iter
            (fun name -> remove_tree (Filename.concat path name))
            (try Sys.readdir path with _ -> [||]);
          try Unix.rmdir path with _ -> ()
        end
        else try Sys.remove path with _ -> ()
      in
      Array.iter
        (fun name -> remove_tree (Filename.concat dir name))
        (try Sys.readdir dir with _ -> [||]);
      try Unix.rmdir dir with _ -> ())
    (fun () -> f dir)

let write_file path contents =
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out oc)
    (fun () -> output_string oc contents)

let format_errors errors =
  String.concat "\n"
    (List.map (fun (e : Ast.compiler_error) -> e.message) errors)

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

let program_has_typed_expr (program : Ast.program) : bool =
  let rec expr_is_typed e =
    Option.is_some e.Ast.expr_type
    && List.for_all expr_is_typed (Ast.expr_children e)
  in
  let rec decl_has_typed_expr (decl : Ast.decl) =
    match decl.decl_desc with
    | DFunc f -> (
        match Ast.func_body_expr_opt f.func_body with
        | Some body -> expr_is_typed body
        | None -> false)
    | DVar v -> expr_is_typed v.var_value
    | DPrivate inner -> decl_has_typed_expr inner
    | _ -> false
  in
  List.exists decl_has_typed_expr program

let typecheck_typed ~filename ~source ?debug () =
  let sess = Session.create () in
  Pipeline.typecheck_only_typed_reusing_session ~sess ~filename ~source ?debug ()

let typecheck_ast ~filename ~source ?debug () =
  typecheck_typed ~filename ~source ?debug ()
  |> Result.map Typed_ast.program_ast

let test_reusable_typecheck_returns_typed_program () =
  Test_helpers.with_isolated_env (fun () ->
      let source =
        "func main(args: List[String]) -> Int:\n    x: Int = 1\n    x + 1\n"
      in
      match
        typecheck_typed ~filename:"pipeline_typed_result_api.brp"
          ~source ()
      with
      | Ok typed_program ->
          Alcotest.(check bool)
            "typed api returns validated program" true
            (program_has_typed_expr (Typed_ast.program_ast typed_program))
      | Error errors ->
          Alcotest.fail
            ("expected successful typed typecheck, got:\n"
           ^ format_errors errors))

let parse_typecheck_source_for_test ~path ~module_name =
  match
    Compiler_blorp_bridge.parse_source_file_via_command_at_phase
      ~phase:Compiler_blorp_bridge.TypecheckSourceProgram ~path ~module_name
  with
  | Error (_, message) ->
      Alcotest.fail ("expected Blorp parse bridge artifact: " ^ message)
  | Ok (Compiler_blorp_bridge.ParseSourceDiagnostics diagnostics) ->
      Alcotest.fail
        ("expected parsed bridge artifact, got diagnostics:\n"
       ^ format_errors diagnostics)
  | Ok (Compiler_blorp_bridge.ParsedSource parsed_source) -> parsed_source

let preloaded_source_for_test ~path ~module_name ~source parsed_source :
    Modules.preloaded_parsed_source =
  {
    Modules.preload_module_name = module_name;
    preload_path = path;
    preload_origin = Session.User_module;
    preload_source = source;
    preload_decls = parsed_source.Compiler_blorp_bridge.parsed_program;
    preload_surface = parsed_source.parsed_module_surface;
  }

let empty_preloaded_graph_context : Modules.preloaded_module_graph_context =
  {
    preload_graph_std_dir = None;
    preload_graph_source_packages = [];
    preload_graph_package_roots = [];
  }

let preloaded_graph_for_single_source ~path ~source ~parsed :
    Modules.preloaded_module_graph =
  {
    preload_graph_context = empty_preloaded_graph_context;
    preload_graph_sources =
      [
        preloaded_source_for_test ~path ~module_name:"main" ~source parsed;
      ];
    preload_graph_imports = [];
  }

let test_blorp_bridge_compile_reaches_core () =
  Test_helpers.with_isolated_env (fun () ->
      with_temp_dir "blorp_pipeline_compile_bridge_core" (fun dir ->
          let main_path = Filename.concat dir "main.brp" in
          let main_source =
            "private pure func add_two(value: Int) -> Int:\n\
            \    value + 2\n\n\
             VALUE: Int = add_two(40)\n\n\
             func main(args: List[String]) -> Int:\n\
            \    VALUE - 42\n"
          in
          write_file main_path main_source;
          let main_parsed =
            parse_typecheck_source_for_test ~path:main_path ~module_name:"main"
          in
          let preloaded_module_graph =
            preloaded_graph_for_single_source ~path:main_path
              ~source:main_source ~parsed:main_parsed
          in
          match
            Pipeline.compile_preloaded_graph_with_blorp_bridge
              ~embed_runtime:false ~filename:main_path ~preloaded_module_graph
              ()
          with
          | Ok (Pipeline.Compiled { c_code; _ }) ->
              Alcotest.(check bool)
                "generated C contains main" true
                (contains c_code "blorp_main")
          | Ok (Pipeline.Stopped_at _) ->
              Alcotest.fail
                "Blorp bridge compile preview unexpectedly stopped early"
          | Error errors ->
              Alcotest.fail
                ("expected Blorp bridge compile preview to reach Core:\n"
               ^ format_errors errors)))

let test_blorp_bridge_compile_uses_preloaded_target_source () =
  Test_helpers.with_isolated_env (fun () ->
      with_temp_dir "blorp_pipeline_compile_bridge_target_source" (fun dir ->
          let main_path = Filename.concat dir "main.brp" in
          let main_source =
            "func main(args: List[String]) -> Int:\n\
            \    0\n"
          in
          write_file main_path main_source;
          let main_parsed =
            parse_typecheck_source_for_test ~path:main_path ~module_name:"main"
          in
          let preloaded_module_graph =
            preloaded_graph_for_single_source ~path:main_path
              ~source:main_source ~parsed:main_parsed
          in
          write_file main_path "func main(args: List[String]) -> Int:\n    nope\n";
          match
            Pipeline.compile_preloaded_graph_with_blorp_bridge
              ~embed_runtime:false ~filename:main_path ~preloaded_module_graph
              ()
          with
          | Ok (Pipeline.Compiled { c_code; _ }) ->
              Alcotest.(check bool)
                "generated C comes from preloaded source" true
                (contains c_code "blorp_main")
          | Ok (Pipeline.Stopped_at _) ->
              Alcotest.fail
                "Blorp bridge compile preview unexpectedly stopped early"
          | Error errors ->
              Alcotest.fail
                ("expected Blorp bridge compile to use preloaded target \
                  source:\n" ^ format_errors errors)))

let test_blorp_bridge_compile_types_std_support_modules () =
  Test_helpers.with_isolated_env (fun () ->
      with_temp_dir "blorp_pipeline_compile_bridge_std_support" (fun dir ->
          let main_path = Filename.concat dir "main.brp" in
          let main_source =
            "func main(args: List[String]) -> Int:\n\
            \    msg: String = to_string(True)\n\
            \    print(msg)\n\
            \    0\n"
          in
          write_file main_path main_source;
          let main_parsed =
            parse_typecheck_source_for_test ~path:main_path ~module_name:"main"
          in
          let preloaded_module_graph =
            preloaded_graph_for_single_source ~path:main_path
              ~source:main_source ~parsed:main_parsed
          in
          match
            Pipeline.compile_preloaded_graph_with_blorp_bridge
              ~embed_runtime:false ~filename:main_path ~preloaded_module_graph
              ()
          with
          | Ok (Pipeline.Compiled { c_code; _ }) ->
              Alcotest.(check bool)
                "generated C contains bool support" true
                (contains c_code "Stringable_to_string_Bool")
          | Ok (Pipeline.Stopped_at _) ->
              Alcotest.fail
                "Blorp bridge compile preview unexpectedly stopped early"
          | Error errors ->
              Alcotest.fail
                ("expected Blorp bridge compile preview to type std support:\n"
               ^ format_errors errors)))

let find_core_function_def_id program name =
  List.find_map
    (fun (decl : Core.core_decl) ->
      match decl.cd_desc with
      | Core.CDFunc func when String.equal func.cf_name name ->
          Some func.cf_def_id
      | _ -> None)
    program

let has_prefix ~prefix value =
  let prefix_length = String.length prefix in
  String.length value >= prefix_length
  && String.sub value 0 prefix_length = prefix

let find_resolved_call_identity program source_function_name =
  let mono_prefix = source_function_name ^ "__mono_" in
  let call_identity_in_body body =
    Core.fold_tree
      (fun found node ->
        match found with
        | Some _ -> found
        | None -> (
            match node.Core.desc with
            | Core.CCall (kind, _, _) -> (
                match kind with
                | Core.CKUser (name, Some def_id)
                  when String.equal name source_function_name
                       || has_prefix ~prefix:mono_prefix name ->
                    Some (name, def_id)
                | _ -> None)
            | _ -> None))
      None body
  in
  List.find_map
    (fun (decl : Core.core_decl) ->
      match decl.cd_desc with
      | Core.CDFunc { cf_body = Some body; _ } -> call_identity_in_body body
      | _ -> None)
    program

let test_blorp_bridge_std_call_and_declaration_share_identity () =
  Test_helpers.with_isolated_env (fun () ->
      with_temp_dir "blorp_pipeline_compile_bridge_std_identity" (fun dir ->
          let main_path = Filename.concat dir "main.brp" in
          let main_source =
            "import:\n\
            \    channel: SendAttempt(SendAccepted), try_send_attempt\n\n\
             func main(args: List[String]) -> Int:\n\
            \    ch: Channel[Int] = channel(1)\n\
            \    attempt: SendAttempt = try_send_attempt(ch, 7)\n\
            \    match attempt:\n\
            \        SendAccepted:\n\
            \            0\n\
            \        _:\n\
            \            1\n"
          in
          write_file main_path main_source;
          let main_parsed =
            parse_typecheck_source_for_test ~path:main_path ~module_name:"main"
          in
          let preloaded_module_graph =
            preloaded_graph_for_single_source ~path:main_path
              ~source:main_source ~parsed:main_parsed
            |> fun graph ->
            {
              graph with
              preload_graph_imports =
                [
                  {
                    preload_import_from_path = main_path;
                    preload_import_from_module = "main";
                    preload_import_path = "channel";
                    preload_import_resolved_path = None;
                    preload_import_resolved_module = None;
                    preload_import_resolved_origin = None;
                  };
                ];
            }
          in
          let resolved = ref None in
          let on_stage stage program =
            if stage = Core_stage.Resolve then begin
              resolved := Some program;
              raise (Core_pipeline.Stopped_after stage)
            end
          in
          (match
             Pipeline.compile_preloaded_graph_with_blorp_bridge
               ~embed_runtime:false ~on_stage ~filename:main_path
               ~preloaded_module_graph ()
           with
          | Ok (Pipeline.Stopped_at Core_stage.Resolve) -> ()
          | Ok (Pipeline.Stopped_at stage) ->
              Alcotest.failf "unexpected stop after %s"
                (Core_stage.to_string stage)
          | Ok (Pipeline.Compiled _) ->
              Alcotest.fail "expected compile to stop after resolve"
          | Error errors ->
              Alcotest.fail
                ("expected Blorp graph to resolve channel call:\n"
               ^ format_errors errors));
          let resolved =
            match !resolved with
            | Some program -> program
            | None -> Alcotest.fail "resolve-stage callback did not run"
          in
          let source_function_name = "std_channel__try_send_attempt" in
          Alcotest.(check (option int))
            "projected boundary omits generic source declaration" None
            (find_core_function_def_id resolved source_function_name);
          let resolved_name, call_id =
            match
              find_resolved_call_identity resolved source_function_name
            with
            | Some identity -> identity
            | None -> Alcotest.fail "channel call was not resolved"
          in
          let declaration_id =
            match find_core_function_def_id resolved resolved_name with
            | Some id -> id
            | None -> Alcotest.fail "resolved channel declaration was not retained"
          in
          Alcotest.(check int)
            "resolved call and declaration identity" declaration_id call_id))

let test_typecheck_module_only_returns_typed_program () =
  Test_helpers.with_isolated_env (fun () ->
      let source = "func helper() -> Int:\n    x: Int = 1\n    x + 1\n" in
      match
        Pipeline.typecheck_module_only ~filename:"pipeline_typed_module.brp"
          ~source
      with
      | Ok (_state, program) ->
          Alcotest.(check bool)
            "returned module program contains typed expressions" true
            (program_has_typed_expr program)
      | Error errors ->
          Alcotest.fail
            ("expected successful module typecheck, got:\n"
           ^ format_errors errors))

let test_typecheck_module_only_typed_returns_typed_program () =
  Test_helpers.with_isolated_env (fun () ->
      let source = "func helper() -> Int:\n    x: Int = 1\n    x + 1\n" in
      match
        Pipeline.typecheck_module_only_typed
          ~filename:"pipeline_typed_module_api.brp" ~source
      with
      | Ok (_state, typed_program) ->
          Alcotest.(check bool)
            "typed module api returns validated program" true
            (program_has_typed_expr (Typed_ast.program_ast typed_program))
      | Error errors ->
          Alcotest.fail
            ("expected successful typed module typecheck, got:\n"
           ^ format_errors errors))

let test_typecheck_only_zonks_global_function_reference_initializer () =
  Test_helpers.with_isolated_env (fun () ->
      let source =
        "import:\n\
        \    list: zip\n\
        \    test: TestSuite\n\n\
         func zip_empty() -> Bool:\n\
        \    a: List[Int] = []\n\
        \    a\n\
        \        .zip([1, 2, 3])\n\
        \        .length() == 0\n\n\
         tests: TestSuite = {\n\
        \    description = \"global function reference inference\",\n\
        \    tests = [\n\
        \        (\"zip empty\", zip_empty)\n\
        \    ]\n\
         }\n"
      in
      match
        typecheck_ast ~filename:"pipeline_global_lambda_zonk.brp"
          ~source ()
      with
      | Ok program ->
          Alcotest.(check bool)
            "global initializer contains finalized expression types" true
            (program_has_typed_expr program)
      | Error errors ->
          Alcotest.fail
            ("expected global function reference initializer to typecheck, got:\n"
           ^ format_errors errors))

let test_reusable_typecheck_session_clears_semantic_state () =
  Test_helpers.with_isolated_env (fun () ->
      let sess = Session.create () in
      let first_source =
        "trait ReusableMarker:\n\
        \    pure func marker(value: Self) -> Int\n\n\
         record ReusableToken {value: Int}\n\n\
         implements ReusableMarker for ReusableToken:\n\
        \    pure func marker(value: ReusableToken) -> Int:\n\
        \        value.value\n"
      in
      let second_source =
        "record IndependentToken {value: Int}\n\n\
         pure func value_of(token: IndependentToken) -> Int:\n\
        \    token.value\n"
      in
      let run filename source =
        Pipeline.typecheck_only_typed_reusing_session ~sess ~filename ~source ()
      in
      match run "reusable_first.brp" first_source with
      | Error errors ->
          Alcotest.fail
            ("expected first reusable typecheck to succeed:\n"
           ^ format_errors errors)
      | Ok _ -> (
          Alcotest.(check bool)
            "custom impl registered during first typecheck" true
            (Hashtbl.mem sess.impl_index "ReusableMarker");
          match run "reusable_second.brp" second_source with
          | Error errors ->
              Alcotest.fail
                ("expected second reusable typecheck to succeed:\n"
               ^ format_errors errors)
          | Ok _ ->
              Alcotest.(check bool)
                "custom impl cleared before second typecheck" false
                (Hashtbl.mem sess.impl_index "ReusableMarker")))

let test_reusable_typecheck_session_reuses_parse_cache () =
  Test_helpers.with_isolated_env (fun () ->
      with_temp_dir "blorp_pipeline_reusable_parse_cache" (fun dir ->
          let sess = Session.create () in
          let helper_path = Filename.concat dir "helper.brp" in
          write_file helper_path "pure func helper_value() -> Int:\n    7\n";
          let main_path = Filename.concat dir "main.brp" in
          let source =
            "import:\n\
            \    ./helper: helper_value\n\n\
             pure func use_helper() -> Int:\n\
            \    helper_value()\n"
          in
          let run () =
            Pipeline.typecheck_only_typed_reusing_session ~sess
              ~filename:main_path ~source ()
          in
          match run () with
          | Error errors ->
              Alcotest.fail
                ("expected first reusable typecheck to succeed:\n"
               ^ format_errors errors)
          | Ok _ -> (
              let first_entry = Hashtbl.find sess.parse_cache "./helper" in
              match run () with
              | Error errors ->
                  Alcotest.fail
                    ("expected second reusable typecheck to succeed:\n"
                   ^ format_errors errors)
              | Ok _ ->
                  let second_entry = Hashtbl.find sess.parse_cache "./helper" in
                  Alcotest.(check bool)
                    "parse cache entry reused by identity" true
                    (first_entry == second_entry))))

let test_direct_std_source_check_does_not_conflict_with_embedded_std () =
  Test_helpers.with_isolated_env (fun () ->
      Modules.init_module_paths (Sys.getcwd ());
      match Modules.std_source_dir () with
      | None ->
          Alcotest.fail "could not locate configured project std directory"
      | Some std_dir -> (
          let result_path = Filename.concat std_dir "result.brp" in
          let source = Modules.read_file result_path in
          match typecheck_ast ~filename:result_path ~source () with
          | Ok _ -> ()
          | Error errors ->
              let text = format_errors errors in
              Alcotest.(check bool)
                "does not load embedded std/result as a duplicate dependency"
                false
                (contains text "conflicting implementation of trait");
              Alcotest.fail
                ("std/result source should typecheck without duplicate impls:\n"
               ^ text)))

let test_explicit_std_source_check_reports_unused_import_error () =
  Test_helpers.with_isolated_env (fun () ->
      Modules.init_module_paths (Sys.getcwd ());
      match Modules.std_source_dir () with
      | None ->
          Alcotest.fail "could not locate configured project std directory"
      | Some std_dir -> (
          let std_path =
            Filename.concat std_dir "__unused_import_lint_target.brp"
          in
          let source =
            "import:\n    vector: sum\n\nfunc lint_target() -> Int:\n    0\n"
          in
          match typecheck_ast ~filename:std_path ~source () with
          | Ok _ -> Alcotest.fail "expected explicit std source to fail"
          | Error errors ->
              let text = format_errors errors in
              Alcotest.(check bool)
                "reports unused import for explicit std check target" true
                (contains text "unused import 'sum' from module 'vector'")))

let test_std_prelude_reexport_source_skips_unused_import_error () =
  Test_helpers.with_isolated_env (fun () ->
      Modules.init_module_paths (Sys.getcwd ());
      match Modules.std_source_dir () with
      | None ->
          Alcotest.fail "could not locate configured project std directory"
      | Some std_dir -> (
          let std_path = Filename.concat std_dir "prelude.brp" in
          let source = Modules.read_file std_path in
          match typecheck_ast ~filename:std_path ~source () with
          | Error errors ->
              Alcotest.fail
                ("std/prelude source should typecheck:\n" ^ format_errors errors)
          | Ok _ -> ()))

let test_user_file_in_std_named_dir_rejects_builtin () =
  Test_helpers.with_isolated_env (fun () ->
      with_temp_dir "blorp_pipeline_fake_std" (fun dir ->
          let fake_std = Filename.concat dir "std" in
          Unix.mkdir fake_std 0o700;
          let main_path = Filename.concat fake_std "main.brp" in
          let source =
            "func sneaky() -> Int:\n\
            \    builtin\n\n\
             func main(args: List[String]) -> Int:\n\
            \    sneaky()\n"
          in
          match typecheck_ast ~filename:main_path ~source () with
          | Error errors ->
              let text = format_errors errors in
              Alcotest.(check bool)
                "rejects builtin outside configured std root" true
                (contains text "can only be used in the standard library")
          | Ok _ ->
              Alcotest.fail
                "user file in an arbitrary std-named directory received stdlib \
                 privileges"))

let test_path_under_dir_rejects_std_prefix_sibling () =
  with_temp_dir "blorp_path_boundary" (fun dir ->
      let std_dir = Filename.concat dir "std" in
      let sibling_dir = Filename.concat dir "std_backup" in
      Unix.mkdir std_dir 0o700;
      Unix.mkdir sibling_dir 0o700;
      let std_file = Filename.concat std_dir "main.brp" in
      let sibling_file = Filename.concat sibling_dir "main.brp" in
      write_file std_file "";
      write_file sibling_file "";
      Alcotest.(check bool)
        "std file is under std dir" true
        (Modules.is_path_under_dir ~dir:std_dir std_file);
      Alcotest.(check bool)
        "std prefix sibling is not under std dir" false
        (Modules.is_path_under_dir ~dir:std_dir sibling_file))

let test_configured_std_source_rejects_foreign () =
  Test_helpers.with_isolated_env (fun () ->
      Modules.init_module_paths (Sys.getcwd ());
      match Modules.std_source_dir () with
      | None ->
          Alcotest.fail "could not locate configured project std directory"
      | Some std_dir -> (
          let sess = Session.current () in
          Modules.set_std_override ~sess std_dir;
          let std_path = Filename.concat std_dir "native_policy_test.brp" in
          let source =
            "foreign(include: \"math.h\"):\n\
            \    func c_abs(x: Int) -> Int = \"abs\"\n"
          in
          match typecheck_ast ~filename:std_path ~source () with
          | Error errors ->
              let text = format_errors errors in
              Alcotest.(check bool)
                "rejects foreign in configured std root" true
                (contains text "cannot be used in the standard library")
          | Ok _ ->
              Alcotest.fail
                "configured std source accepted a foreign declaration"))

let test_configured_std_source_rejects_package_import () =
  Test_helpers.with_isolated_env (fun () ->
      Modules.init_module_paths (Sys.getcwd ());
      match Modules.std_source_dir () with
      | None ->
          Alcotest.fail "could not locate configured project std directory"
      | Some std_dir -> (
          let sess = Session.current () in
          Modules.set_std_override ~sess std_dir;
          let std_path = Filename.concat std_dir "pkg_policy_test.brp" in
          let source =
            "import:\n\
            \    pkg/crypto as Crypto\n\n\
             func harmless() -> Int:\n\
            \    0\n"
          in
          match typecheck_ast ~filename:std_path ~source () with
          | Error errors ->
              let text = format_errors errors in
              Alcotest.(check bool)
                "rejects package imports in configured std root" true
                (contains text
                   "standard library modules cannot import package modules")
          | Ok _ ->
              Alcotest.fail "configured std source accepted a package import"))

let test_bare_local_import_does_not_keep_failed_std_probe () =
  Test_helpers.with_isolated_env (fun () ->
      with_temp_dir "blorp_pipeline_bare_local_import" (fun dir ->
          write_file
            (Filename.concat dir "helper.brp")
            "func ok() -> Int:\n    1\n";
          let main_path = Filename.concat dir "main.brp" in
          let source =
            "import:\n\
            \    helper: ok\n\n\
             func main(args: List[String]) -> Int:\n\
            \    ok()\n"
          in
          match typecheck_ast ~filename:main_path ~source () with
          | Ok _ -> ()
          | Error errors ->
              Alcotest.fail
                ("bare local import kept failed std probe diagnostics:\n"
               ^ format_errors errors)))

let test_imported_module_uses_typecheck_source_finalization () =
  Test_helpers.with_isolated_env (fun () ->
      with_temp_dir "blorp_pipeline_imported_source_finalization" (fun dir ->
          write_file
            (Filename.concat dir "helper.brp")
            "func outer(x: Int) -> Int:\n\
            \    func inner(y: Int) -> Int:\n\
            \        y + 1\n\
            \    inner(x)\n";
          let main_path = Filename.concat dir "main.brp" in
          let source =
            "import:\n\
            \    ./helper: outer\n\n\
             func main(args: List[String]) -> Int:\n\
            \    outer(1)\n"
          in
          match typecheck_ast ~filename:main_path ~source () with
          | Ok _ -> ()
          | Error errors ->
              Alcotest.fail
                ("imported module did not use typecheck-source finalization:\n"
               ^ format_errors errors)))

let test_qualified_only_import_does_not_suppress_bare_missing_name () =
  Test_helpers.with_isolated_env (fun () ->
      with_temp_dir "blorp_pipeline_qualified_import" (fun dir ->
          write_file
            (Filename.concat dir "helper.brp")
            "func f() -> Int:\n    1\n";
          write_file
            (Filename.concat dir "bad.brp")
            "import:\n    ./helper as H\n\nfunc bad() -> Int:\n    f()\n";
          let main_path = Filename.concat dir "main.brp" in
          let source =
            "import:\n\
            \    ./bad as B\n\n\
             func main(args: List[String]) -> Int:\n\
            \    B.bad()\n"
          in
          match typecheck_ast ~filename:main_path ~source () with
          | Error errors ->
              let text = format_errors errors in
              Alcotest.(check bool)
                "reports bare missing function from module" true
                (contains text "Undefined identifier: f")
          | Ok _ ->
              Alcotest.fail
                "qualified-only import incorrectly made helper.f visible as \
                 bare f"))

let test_core_pipeline_rejects_untyped_loaded_module () =
  Test_helpers.with_isolated_env (fun () ->
      let sess = Session.current () in
      let raw_module = mk_loaded_module ~name:"test/raw" ~decls:[] in
      Hashtbl.add sess.module_cache raw_module.name raw_module;
      Test_helpers.check_core_error_raises
        ~phase:(Core_error.Stage Core_stage.Lower)
        ~msg_contains:"without typed declarations" (fun () ->
          ignore
            (Core_pipeline.compile_typed_with_modules
               (Test_helpers.expect_valid_typed_program []))))

let test_cross_module_coherence_distinguishes_same_named_local_types () =
  Test_helpers.with_isolated_env (fun () ->
      with_temp_dir "blorp_pipeline_type_identity" (fun dir ->
          let module_source =
            "record Widget {id: Int}\n\n\
             implements Equatable for Widget:\n\
            \    pure func equals(a: Widget, b: Widget) -> Bool:\n\
            \        a.id == b.id\n\n\
             implements Hashable for Widget:\n\
            \    pure func hash(self: Widget) -> Int:\n\
            \        self.id\n\n\
             pure func module_id() -> Int:\n\
            \    0\n"
          in
          write_file (Filename.concat dir "a.brp") module_source;
          write_file (Filename.concat dir "b.brp") module_source;
          let main_path = Filename.concat dir "main.brp" in
          let source =
            "import:\n\
            \    ./a as A\n\
            \    ./b as B\n\n\
             func main(args: List[String]) -> Int:\n\
            \    A.module_id() + B.module_id()\n"
          in
          match typecheck_ast ~filename:main_path ~source () with
          | Ok _ -> ()
          | Error errors ->
              Alcotest.fail
                ("same-named module-local types conflicted:\n"
               ^ format_errors errors)))

let test_duplicate_selective_type_import_requires_alias () =
  Test_helpers.with_isolated_env (fun () ->
      with_temp_dir "blorp_pipeline_import_identity" (fun dir ->
          write_file (Filename.concat dir "a.brp") "record Widget {id: Int}\n";
          write_file (Filename.concat dir "b.brp") "record Widget {id: Int}\n";
          let main_path = Filename.concat dir "main.brp" in
          let source =
            "import:\n\
            \    ./a: Widget\n\
            \    ./b: Widget\n\n\
             func main(args: List[String]) -> Int:\n\
            \    0\n"
          in
          match typecheck_ast ~filename:main_path ~source () with
          | Error errors ->
              let text = format_errors errors in
              Alcotest.(check bool)
                "rejects ambiguous imported type name" true
                (contains text "Ambiguous import: 'Widget' is already imported");
              Alcotest.(check bool)
                "suggests alias" true
                (contains text "Use an alias to disambiguate")
          | Ok _ ->
              Alcotest.fail
                "duplicate selective type imports should require an alias"))

let test_module_alias_rejects_builtin_type_name () =
  Test_helpers.with_isolated_env (fun () ->
      with_temp_dir "blorp_pipeline_module_alias_builtin_type" (fun dir ->
          let main_path = Filename.concat dir "main.brp" in
          let source =
            "import:\n\
            \    fixed as Fixed\n\n\
             func main(args: List[String]) -> Int:\n\
            \    0\n"
          in
          match typecheck_ast ~filename:main_path ~source () with
          | Error errors ->
              let text = format_errors errors in
              Alcotest.(check bool)
                "rejects module alias/type collision" true
                (contains text
                   "module alias 'Fixed' conflicts with existing type 'Fixed'")
          | Ok _ ->
              Alcotest.fail
                "module alias should not be allowed to reuse a builtin type \
                 name"))

let test_module_alias_rejects_local_type_name () =
  Test_helpers.with_isolated_env (fun () ->
      with_temp_dir "blorp_pipeline_module_alias_local_type" (fun dir ->
          write_file
            (Filename.concat dir "helper.brp")
            "func make() -> Int:\n    1\n";
          let main_path = Filename.concat dir "main.brp" in
          let source =
            "import:\n\
            \    ./helper as Widget\n\n\
             record Widget {id: Int}\n\n\
             func main(args: List[String]) -> Int:\n\
            \    Widget.make()\n"
          in
          match typecheck_ast ~filename:main_path ~source () with
          | Error errors ->
              let text = format_errors errors in
              Alcotest.(check bool)
                "rejects module alias/local type collision" true
                (contains text
                   "module alias 'Widget' conflicts with type 'Widget' \
                    declared in this module")
          | Ok _ ->
              Alcotest.fail
                "module alias should not be allowed to reuse a local type name"))

let test_aliased_selective_type_imports_keep_original_traits () =
  Test_helpers.with_isolated_env (fun () ->
      with_temp_dir "blorp_pipeline_import_alias_traits" (fun dir ->
          let module_source hash_offset =
            Printf.sprintf
              "record Widget {id: Int}\n\n\
               implements Equatable for Widget:\n\
              \    pure func equals(a: Widget, b: Widget) -> Bool:\n\
              \        a.id == b.id\n\n\
               implements Hashable for Widget:\n\
              \    pure func hash(self: Widget) -> Int:\n\
              \        self.id + %d\n"
              hash_offset
          in
          write_file (Filename.concat dir "a.brp") (module_source 10);
          write_file (Filename.concat dir "b.brp") (module_source 20);
          let main_path = Filename.concat dir "main.brp" in
          let source =
            "import:\n\
            \    ./a: Widget as WidgetA\n\
            \    ./b: Widget as WidgetB\n\n\
             func same_a(left: WidgetA, right: WidgetA) -> Bool:\n\
            \    left == right\n\n\
             func same_b(left: WidgetB, right: WidgetB) -> Bool:\n\
            \    left == right\n\n\
             func hash_a(value: WidgetA) -> Int:\n\
            \    value.hash()\n\n\
             func hash_b(value: WidgetB) -> Int:\n\
            \    value.hash()\n\n\
             func main(args: List[String]) -> Int:\n\
            \    a1: WidgetA = {id = 1}\n\
            \    a2: WidgetA = {id = 1}\n\
            \    b1: WidgetB = {id = 2}\n\
            \    b2: WidgetB = {id = 2}\n\
            \    if same_a(a1, a2) and same_b(b1, b2) and hash_a(a1) == 11 and \
             hash_b(b1) == 22:\n\
            \        0\n\
            \    else:\n\
            \        1\n"
          in
          match typecheck_ast ~filename:main_path ~source () with
          | Ok _ -> ()
          | Error errors ->
              Alcotest.fail
                ("aliased imported type traits did not typecheck:\n"
               ^ format_errors errors)))

let test_selective_imported_record_type_aliases_module_owned_type () =
  Test_helpers.with_isolated_env (fun () ->
      with_temp_dir "blorp_pipeline_import_record_type_alias" (fun dir ->
          write_file
            (Filename.concat dir "box.brp")
            "record Box {value: Int}\n\n\
             pure func new(value: Int) -> Box:\n\
            \    {value = value}\n";
          let main_path = Filename.concat dir "main.brp" in
          let source =
            "import:\n\
            \    ./box as B: Box\n\n\
             func main(args: List[String]) -> Int:\n\
            \    box: Box = B.new(1)\n\
            \    box.value\n"
          in
          match typecheck_ast ~filename:main_path ~source () with
          | Ok _ -> ()
          | Error errors ->
              Alcotest.fail
                ("selective imported record type did not alias module-owned \
                  type:\n" ^ format_errors errors)))

let test_selective_imported_union_constructor_uses_module_owned_type () =
  Test_helpers.with_isolated_env (fun () ->
      with_temp_dir "blorp_pipeline_import_union_type_alias" (fun dir ->
          write_file
            (Filename.concat dir "node.brp")
            "union Node:\n\
            \    Text(String)\n\n\
             pure func get_text(node: Node) -> String:\n\
            \    match node:\n\
            \        Text(value): value\n";
          let main_path = Filename.concat dir "main.brp" in
          let source =
            "import:\n\
            \    ./node as N: Node(Text)\n\n\
             func main(args: List[String]) -> Int:\n\
            \    node: Node = Text(\"hello\")\n\
            \    if N.get_text(node) == \"hello\":\n\
            \        0\n\
            \    else:\n\
            \        1\n"
          in
          match typecheck_ast ~filename:main_path ~source () with
          | Ok _ -> ()
          | Error errors ->
              Alcotest.fail
                ("selective imported union constructor did not use \
                  module-owned type:\n" ^ format_errors errors)))

let test_selective_imported_type_alias_uses_module_owned_target () =
  Test_helpers.with_isolated_env (fun () ->
      with_temp_dir "blorp_pipeline_import_type_alias" (fun dir ->
          write_file
            (Filename.concat dir "codec.brp")
            "union Value:\n\
            \    VInt(Int)\n\n\
             union DecodeError:\n\
            \    Bad\n\n\
             type alias Decoder[T] = pure (Value) -> Result[T, DecodeError]\n\n\
             pure func d_int(value: Value) -> Result[Int, DecodeError]:\n\
            \    match value:\n\
            \        VInt(n): Ok(n)\n\n\
             pure func identity_decoder[T](decoder: Decoder[T]) -> Decoder[T]:\n\
            \    decoder\n";
          let main_path = Filename.concat dir "main.brp" in
          let source =
            "import:\n\
            \    ./codec: Decoder, Value(VInt), d_int, identity_decoder\n\n\
             func main(args: List[String]) -> Int:\n\
            \    decoder: Decoder[Int] = identity_decoder(d_int)\n\
            \    match decoder(VInt(1)):\n\
            \        Ok(n): n\n\
            \        Err(_): 0\n"
          in
          match typecheck_ast ~filename:main_path ~source () with
          | Ok _ -> ()
          | Error errors ->
              Alcotest.fail
                ("selective imported type alias did not use module-owned target:\n"
               ^ format_errors errors)))

let test_exported_signature_keeps_imported_type_owner () =
  Test_helpers.with_isolated_env (fun () ->
      with_temp_dir "blorp_pipeline_export_imported_type_owner" (fun dir ->
          write_file
            (Filename.concat dir "json.brp")
            "union JsonValue:\n\
            \    JsonNull\n\n\
             pure func parse() -> JsonValue:\n\
            \    JsonNull\n";
          write_file
            (Filename.concat dir "bridge.brp")
            "import:\n\
            \    ./json: JsonValue(JsonNull)\n\n\
             pure func bridge(value: JsonValue) -> Int:\n\
            \    match value:\n\
            \        JsonNull: 0\n";
          let main_path = Filename.concat dir "main.brp" in
          let source =
            "import:\n\
            \    ./json as J\n\
            \    ./bridge: bridge\n\n\
             func main(args: List[String]) -> Int:\n\
            \    bridge(J.parse())\n"
          in
          match typecheck_ast ~filename:main_path ~source () with
          | Ok _ -> ()
          | Error errors ->
              Alcotest.fail
                ("exported signature did not preserve imported type owner:\n"
               ^ format_errors errors)))

let test_selective_import_uses_typed_semantic_export_signature () =
  Test_helpers.with_isolated_env (fun () ->
      with_temp_dir "blorp_pipeline_typed_semantic_export_signature" (fun dir ->
          write_file
            (Filename.concat dir "errors.brp")
            "union ErrorKind:\n    Boom\n";
          write_file
            (Filename.concat dir "producer.brp")
            "import:\n\
            \    ./errors: ErrorKind(Boom)\n\n\
             pure func checked() -> Result[Int, ErrorKind]:\n\
            \    Err(Boom)\n";
          let main_path = Filename.concat dir "main.brp" in
          let source =
            "import:\n\
            \    ./producer: checked\n\
            \    result: Result(Ok, Err)\n\n\
             func main(args: List[String]) -> Int:\n\
            \    r = checked()\n\
            \    match r:\n\
            \        Ok(v): v\n\
            \        Err(_): 0\n"
          in
          match
            typecheck_typed ~filename:main_path ~source ()
          with
          | Error errors ->
              Alcotest.fail
                ("typed semantic export signature was rejected:\n"
               ^ format_errors errors)
          | Ok typed -> (
              let body =
                match
                  Test_helpers.find_func_body
                    (Typed_ast.program_ast typed)
                    "main"
                with
                | Some body -> body
                | None -> Alcotest.fail "main body not found"
              in
              let call =
                match body.expr_desc with
                | EBlock
                    ({ expr_desc = EVarDecl ("r", _, value, false); _ } :: _) ->
                    value
                | _ -> Alcotest.fail "checked() binding not found"
              in
              let expected =
                Ast.TyNamed
                  ( "Result",
                    [
                      Ast.TyNamed ("Int", []);
                      Ast.TyNamed ("./errors::ErrorKind", []);
                    ] )
              in
              match call.expr_type_info with
              | Some info ->
                  Alcotest.(check bool)
                    "imported function call uses semantic exported return type"
                    true
                    (Types.types_equal expected info.semantic_ty)
              | None -> Alcotest.fail "checked() call is missing type metadata")))

let test_local_record_field_uses_imported_type_owner () =
  Test_helpers.with_isolated_env (fun () ->
      with_temp_dir "blorp_pipeline_record_field_imported_type_owner"
        (fun dir ->
          write_file
            (Filename.concat dir "dep.brp")
            "record Dep {value: Int}\n\n\
             pure func dep(value: Int) -> Dep:\n\
            \    {value = value}\n";
          write_file
            (Filename.concat dir "holder.brp")
            "import:\n\
            \    ./dep: Dep, dep\n\n\
             record Holder {dep: Dep}\n\n\
             pure func make() -> Holder:\n\
            \    {dep = dep(1)}\n";
          let main_path = Filename.concat dir "main.brp" in
          let source =
            "import:\n\
            \    ./holder: Holder, make\n\n\
             func main(args: List[String]) -> Int:\n\
            \    h: Holder = make()\n\
            \    h.dep.value\n"
          in
          match typecheck_ast ~filename:main_path ~source () with
          | Ok _ -> ()
          | Error errors ->
              Alcotest.fail
                ("local record field did not preserve imported type owner:\n"
               ^ format_errors errors)))

let test_qualified_module_value_uses_typed_export_annotation () =
  Test_helpers.with_isolated_env (fun () ->
      with_temp_dir "blorp_pipeline_qualified_value_typed_export" (fun dir ->
          write_file
            (Filename.concat dir "suite.brp")
            "import:\n\
            \    test: TestSuite\n\n\
             func test_a() -> Bool:\n\
            \    True\n\n\
             tests: TestSuite = {\n\
            \    description = \"A\",\n\
            \    tests = [(\"a\", test_a)]\n\
             }\n";
          let main_path = Filename.concat dir "main.brp" in
          let source =
            "import:\n\
            \    std/test: run_suite\n\
            \    ./suite as S\n\n\
             func main(args: List[String]) -> Int:\n\
            \    if run_suite(S.tests):\n\
            \        0\n\
            \    else:\n\
            \        1\n"
          in
          match typecheck_ast ~filename:main_path ~source () with
          | Ok _ -> ()
          | Error errors ->
              Alcotest.fail
                ("qualified module value did not use typed export annotation:\n"
               ^ format_errors errors)))

let test_alias_only_imports_do_not_expose_trait_methods () =
  Test_helpers.with_isolated_env (fun () ->
      with_temp_dir "blorp_pipeline_trait_method_scope" (fun dir ->
          write_file
            (Filename.concat dir "a.brp")
            "trait DescribeA:\n\
            \    pure func describe(value: Self) -> String\n\n\
             pure func marker() -> Int:\n\
            \    0\n";
          write_file
            (Filename.concat dir "b.brp")
            "trait DescribeB:\n\
            \    pure func describe(value: Self) -> String\n\n\
             pure func marker() -> Int:\n\
            \    0\n";
          let main_path = Filename.concat dir "main.brp" in
          let source =
            "import:\n\
            \    ./a as A\n\
            \    ./b as B\n\n\
             func main(args: List[String]) -> Int:\n\
            \    A.marker() + B.marker()\n"
          in
          match typecheck_ast ~filename:main_path ~source () with
          | Ok _ -> ()
          | Error errors ->
              Alcotest.fail
                ("alias-only imports exposed bare trait methods:\n"
               ^ format_errors errors)))

let test_selective_trait_imports_expose_method_collisions () =
  Test_helpers.with_isolated_env (fun () ->
      with_temp_dir "blorp_pipeline_trait_method_collision" (fun dir ->
          write_file
            (Filename.concat dir "a.brp")
            "trait DescribeA:\n    pure func describe(value: Self) -> String\n";
          write_file
            (Filename.concat dir "b.brp")
            "trait DescribeB:\n    pure func describe(value: Self) -> String\n";
          let main_path = Filename.concat dir "main.brp" in
          let source =
            "import:\n\
            \    ./a: DescribeA\n\
            \    ./b: DescribeB\n\n\
             func main(args: List[String]) -> Int:\n\
            \    0\n"
          in
          match typecheck_ast ~filename:main_path ~source () with
          | Error errors ->
              let text = format_errors errors in
              Alcotest.(check bool)
                "selective trait imports still report bare method collision"
                true
                (contains text "method 'describe' is already registered");
              Alcotest.(check bool)
                "collision names the second imported trait" true
                (contains text "DescribeB")
          | Ok _ ->
              Alcotest.fail
                "selectively importing two traits with the same bare method \
                 should fail"))

let test_direct_function_import_shadows_unrelated_trait_method () =
  Test_helpers.with_isolated_env (fun () ->
      with_temp_dir "blorp_pipeline_trait_method_direct_import" (fun dir ->
          write_file
            (Filename.concat dir "util.brp")
            "pure func is_even(x: Int) -> Bool:\n    x % 2 == 0\n";
          write_file
            (Filename.concat dir "parity.brp")
            "trait Parity:\n\
            \    pure func is_even(self: Self) -> Bool\n\n\
             record Nat {n: Int}\n\n\
             implements Parity for Nat:\n\
            \    pure func is_even(self: Nat) -> Bool:\n\
            \        self.n == 0\n\n\
             pure func marker() -> Int:\n\
            \    0\n";
          write_file
            (Filename.concat dir "consumer.brp")
            "import:\n\
            \    ./util: is_even\n\n\
             func check() -> Bool:\n\
            \    is_even(4)\n";
          let main_path = Filename.concat dir "main.brp" in
          let source =
            "import:\n\
            \    ./consumer as Consumer\n\
            \    ./parity as ParityMod\n\n\
             func main(args: List[String]) -> Int:\n\
            \    if Consumer.check() and ParityMod.marker() == 0:\n\
            \        0\n\
            \    else:\n\
            \        1\n"
          in
          match typecheck_ast ~filename:main_path ~source () with
          | Ok _ -> ()
          | Error errors ->
              Alcotest.fail
                ("direct function import was treated as trait dispatch:\n"
               ^ format_errors errors)))

let test_selective_function_import_allows_unimported_return_type_name () =
  Test_helpers.with_isolated_env (fun () ->
      with_temp_dir "blorp_pipeline_import_signature_type" (fun dir ->
          write_file
            (Filename.concat dir "factory.brp")
            "record Foo {value: Int}\n\n\
             pure func make_foo() -> Foo:\n\
            \    {value = 1}\n";
          let main_path = Filename.concat dir "main.brp" in
          let source =
            "import:\n\
            \    ./factory: make_foo\n\n\
             func main(args: List[String]) -> Int:\n\
            \    make_foo().value\n"
          in
          match typecheck_ast ~filename:main_path ~source () with
          | Ok _ -> ()
          | Error errors ->
              Alcotest.fail
                ("selective function import should not require importing an \
                  unused return type name:\n" ^ format_errors errors)))

let test_selective_function_import_allows_explicit_exposed_return_type () =
  Test_helpers.with_isolated_env (fun () ->
      with_temp_dir "blorp_pipeline_import_signature_type_ok" (fun dir ->
          write_file
            (Filename.concat dir "factory.brp")
            "record Foo {value: Int}\n\n\
             pure func make_foo() -> Foo:\n\
            \    {value = 1}\n";
          let main_path = Filename.concat dir "main.brp" in
          let source =
            "import:\n\
            \    ./factory: Foo, make_foo\n\n\
             func main(args: List[String]) -> Int:\n\
            \    foo: Foo = make_foo()\n\
            \    foo.value\n"
          in
          match typecheck_ast ~filename:main_path ~source () with
          | Ok _ -> ()
          | Error errors ->
              Alcotest.fail
                ("explicitly imported exposed return type was rejected:\n"
               ^ format_errors errors)))

let test_selective_record_import_allows_unimported_field_type_name () =
  Test_helpers.with_isolated_env (fun () ->
      with_temp_dir "blorp_pipeline_import_record_field_type" (fun dir ->
          write_file
            (Filename.concat dir "models.brp")
            "record Foo {value: Int}\n\nrecord Box {foo: Foo}\n";
          let main_path = Filename.concat dir "main.brp" in
          let source =
            "import:\n\
            \    ./models: Box\n\n\
             pure func takes_box(box: Box) -> Int:\n\
            \    0\n\n\
             func main(args: List[String]) -> Int:\n\
            \    0\n"
          in
          match typecheck_ast ~filename:main_path ~source () with
          | Ok _ -> ()
          | Error errors ->
              Alcotest.fail
                ("selective record import should not require importing an \
                  unused field type name:\n" ^ format_errors errors)))

let test_selective_record_import_allows_prelude_field_types () =
  Test_helpers.with_isolated_env (fun () ->
      with_temp_dir "blorp_pipeline_import_prelude_field_type" (fun dir ->
          write_file
            (Filename.concat dir "models.brp")
            "record Box {names: List[String]}\n";
          let main_path = Filename.concat dir "main.brp" in
          let source =
            "import:\n\
            \    ./models: Box\n\n\
             pure func takes_box(box: Box) -> Int:\n\
            \    0\n\n\
             func main(args: List[String]) -> Int:\n\
            \    0\n"
          in
          match typecheck_ast ~filename:main_path ~source () with
          | Ok _ -> ()
          | Error errors ->
              Alcotest.fail
                ("prelude field types should not require explicit imports:\n"
               ^ format_errors errors)))

let test_profiled_preloaded_graph_compile_emits_runtime_hooks () =
  Test_helpers.with_isolated_env (fun () ->
      with_temp_dir "blorp_pipeline_profiled_preloaded_graph" (fun dir ->
          let main_path = Filename.concat dir "main.brp" in
          let source = "func main(args: List[String]) -> Int:\n    0\n" in
          write_file main_path source;
          let parsed =
            parse_typecheck_source_for_test ~path:main_path ~module_name:"main"
          in
          let preloaded_module_graph =
            preloaded_graph_for_single_source ~path:main_path ~source ~parsed
          in
          match
            Pipeline.compile_preloaded_graph_with_blorp_bridge
              ~embed_runtime:false ~profile:true ~filename:main_path
              ~preloaded_module_graph ()
          with
          | Ok (Pipeline.Compiled { c_code; _ }) ->
              Alcotest.(check bool)
                "function hooks emitted" true
                (contains c_code "blorp_profile_start(");
              Alcotest.(check bool)
                "profile report emitted" true
                (contains c_code "atexit(blorp_profile_report)")
          | Ok (Pipeline.Stopped_at _) ->
              Alcotest.fail "profiled preloaded graph compile stopped unexpectedly"
          | Error errors ->
              Alcotest.fail
                ("profiled preloaded graph compile failed:\n"
               ^ format_errors errors)))

let suite =
  [
    ( "module_errors",
      [
        Alcotest.test_case
          "direct std source check does not conflict with embedded std" `Quick
          test_direct_std_source_check_does_not_conflict_with_embedded_std;
        Alcotest.test_case "reusable typecheck returns typed program" `Quick
          test_reusable_typecheck_returns_typed_program;
        Alcotest.test_case "Blorp bridge compile reaches Core" `Quick
          test_blorp_bridge_compile_reaches_core;
        Alcotest.test_case
          "Blorp bridge compile uses preloaded target source" `Quick
          test_blorp_bridge_compile_uses_preloaded_target_source;
        Alcotest.test_case "typecheck_module_only returns typed program" `Quick
          test_typecheck_module_only_returns_typed_program;
        Alcotest.test_case "typecheck_module_only_typed returns typed program"
          `Quick test_typecheck_module_only_typed_returns_typed_program;
        Alcotest.test_case
          "typecheck_only zonks global function reference initializer" `Quick
          test_typecheck_only_zonks_global_function_reference_initializer;
        Alcotest.test_case "reusable typecheck clears semantic state" `Quick
          test_reusable_typecheck_session_clears_semantic_state;
        Alcotest.test_case "reusable typecheck reuses parse cache" `Quick
          test_reusable_typecheck_session_reuses_parse_cache;
        Alcotest.test_case "explicit std source reports unused import" `Quick
          test_explicit_std_source_check_reports_unused_import_error;
        Alcotest.test_case "std prelude re-export skips unused imports" `Quick
          test_std_prelude_reexport_source_skips_unused_import_error;
        Alcotest.test_case "user file in std-named dir rejects builtin" `Quick
          test_user_file_in_std_named_dir_rejects_builtin;
        Alcotest.test_case "std path boundary rejects prefix sibling" `Quick
          test_path_under_dir_rejects_std_prefix_sibling;
        Alcotest.test_case "configured std source rejects foreign" `Quick
          test_configured_std_source_rejects_foreign;
        Alcotest.test_case "configured std source rejects package import" `Quick
          test_configured_std_source_rejects_package_import;
        Alcotest.test_case "bare local import does not keep failed std probe"
          `Quick test_bare_local_import_does_not_keep_failed_std_probe;
        Alcotest.test_case "imported module uses typecheck-source finalization"
          `Quick test_imported_module_uses_typecheck_source_finalization;
        Alcotest.test_case
          "qualified-only import does not suppress bare missing name" `Quick
          test_qualified_only_import_does_not_suppress_bare_missing_name;
        Alcotest.test_case "core lowering rejects untyped loaded module" `Quick
          test_core_pipeline_rejects_untyped_loaded_module;
        Alcotest.test_case
          "Blorp bridge compile types std support modules" `Quick
          test_blorp_bridge_compile_types_std_support_modules;
        Alcotest.test_case
          "Blorp bridge std call and declaration share identity" `Quick
          test_blorp_bridge_std_call_and_declaration_share_identity;
        Alcotest.test_case
          "cross-module coherence distinguishes same-named local types" `Quick
          test_cross_module_coherence_distinguishes_same_named_local_types;
        Alcotest.test_case "duplicate selective type import requires alias"
          `Quick test_duplicate_selective_type_import_requires_alias;
        Alcotest.test_case "module alias rejects builtin type name" `Quick
          test_module_alias_rejects_builtin_type_name;
        Alcotest.test_case "module alias rejects local type name" `Quick
          test_module_alias_rejects_local_type_name;
        Alcotest.test_case "aliased selective type imports keep original traits"
          `Quick test_aliased_selective_type_imports_keep_original_traits;
        Alcotest.test_case
          "selective imported record type aliases module-owned type" `Quick
          test_selective_imported_record_type_aliases_module_owned_type;
        Alcotest.test_case
          "selective imported union constructor uses module-owned type" `Quick
          test_selective_imported_union_constructor_uses_module_owned_type;
        Alcotest.test_case
          "selective imported type alias uses module-owned target" `Quick
          test_selective_imported_type_alias_uses_module_owned_target;
        Alcotest.test_case "exported signature keeps imported type owner" `Quick
          test_exported_signature_keeps_imported_type_owner;
        Alcotest.test_case "selective import uses semantic typed export" `Quick
          test_selective_import_uses_typed_semantic_export_signature;
        Alcotest.test_case "local record field uses imported type owner" `Quick
          test_local_record_field_uses_imported_type_owner;
        Alcotest.test_case "qualified module value uses typed export annotation"
          `Quick test_qualified_module_value_uses_typed_export_annotation;
        Alcotest.test_case "alias-only imports do not expose trait methods"
          `Quick test_alias_only_imports_do_not_expose_trait_methods;
        Alcotest.test_case "selective trait imports expose method collisions"
          `Quick test_selective_trait_imports_expose_method_collisions;
        Alcotest.test_case
          "direct function import shadows unrelated trait method" `Quick
          test_direct_function_import_shadows_unrelated_trait_method;
        Alcotest.test_case
          "selective function import allows unimported return type name" `Quick
          test_selective_function_import_allows_unimported_return_type_name;
        Alcotest.test_case
          "selective function import allows explicit exposed return type" `Quick
          test_selective_function_import_allows_explicit_exposed_return_type;
        Alcotest.test_case
          "selective record import allows unimported field type name" `Quick
          test_selective_record_import_allows_unimported_field_type_name;
        Alcotest.test_case "selective record import allows prelude field types"
          `Quick test_selective_record_import_allows_prelude_field_types;
        Alcotest.test_case "profiled preloaded graph emits runtime hooks" `Quick
          test_profiled_preloaded_graph_compile_emits_runtime_hooks;
      ] );
  ]
