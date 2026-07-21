(** Main test runner — aggregates compiler-internal Alcotest suites. *)

type scope = Default | Deep | All

let timing_line_prefix = "BLORP_COMPILER_UNIT_TIMING"
let default_timing_run_id = "-"

type runner_config = {
  scope : scope;
  timings_enabled : bool;
  timing_run_id : string;
}

let scope_name = function
  | Default -> "default"
  | Deep -> "deep"
  | All -> "all"

let parse_scope = function
  | "default" -> Ok Default
  | "deep" -> Ok Deep
  | "all" -> Ok All
  | value ->
      Error
        ("unknown compiler-unit scope `" ^ value
       ^ "` (expected default, deep, or all)")

let timing_field text =
  String.map
    (function
      | '\t' | '\n' | '\r' -> ' '
      | ch -> ch)
    text

let default_runner_config =
  { scope = Default; timings_enabled = false; timing_run_id = default_timing_run_id }

let parse_runner_args argv =
  let rec loop index config alcotest_args =
    if index >= Array.length argv then
      Ok (config, Array.of_list (List.rev alcotest_args))
    else
      let arg = argv.(index) in
      if arg = "--timings" then
        loop (index + 1) { config with timings_enabled = true } alcotest_args
      else if String.starts_with ~prefix:"--scope=" arg then
        let value = String.sub arg 8 (String.length arg - 8) in
        match parse_scope value with
        | Ok scope -> loop (index + 1) { config with scope } alcotest_args
        | Error message -> Error message
      else if String.starts_with ~prefix:"--timing-run-id=" arg then
        let value = String.sub arg 16 (String.length arg - 16) in
        loop (index + 1)
          { config with timing_run_id = timing_field value }
          alcotest_args
      else loop (index + 1) config (arg :: alcotest_args)
  in
  let executable =
    if Array.length argv = 0 then "run_tests.exe" else argv.(0)
  in
  loop 1 default_runner_config [ executable ]

let suite_group prefix suite =
  List.map (fun (name, cases) -> (prefix ^ "." ^ name, cases)) suite

let default_suites =
  suite_group "TypedAst" Test_typed_ast.suite
  @ suite_group "TypedAstJson" Test_typed_ast_json.suite
  @ suite_group "Diagnostics" Test_diagnostics.suite
  @ suite_group "LanguageSurface" Test_language_surface.suite
  @ suite_group "TypeMetadataFormat" Test_type_metadata_format.suite
  @ suite_group "Types" Test_types.suite
  @ suite_group "TypeResolution" Test_type_resolution.suite
  @ suite_group "TypeWidening" Test_type_widening.suite
  @ suite_group "Refinement" Test_refinement.suite
  @ suite_group "InferTypeNormalization" Test_infer_type_normalization.suite
  @ suite_group "GenericParams" Test_generic_params.suite
  @ suite_group "ModuleSurface" Test_module_surface.suite
  @ suite_group "ModuleTypeIdentity" Test_module_type_identity.suite
  @ suite_group "ParsedAstJson" Test_parsed_ast_json.suite
  @ suite_group "Blake3" Test_blake3.suite
  @ suite_group "Infer" Test_infer.suite
  @ suite_group "PurityAnalysis" Test_purity_analysis.suite
  @ suite_group "Env" Test_env.suite
  @ suite_group "Typecheck" Test_typecheck.suite
  @ suite_group "FfiBoundary" Test_ffi_boundary.suite
  @ suite_group "Core" Test_core.suite
  @ suite_group "CoreFlatten" Test_core_flatten.suite
  @ suite_group "CoreLower" Test_core_lower.suite
  @ suite_group "CoreFfiBoundary" Test_core_ffi_boundary.suite
  @ suite_group "CoreResolve" Test_core_resolve.suite
  @ suite_group "CoreStdInline" Test_core_std_inline.suite
  @ suite_group "CoreSpecialize" Test_core_specialize.suite
  @ suite_group "CoreTensorType" Test_core_tensor_type.suite
  @ suite_group "CoreMono" Test_core_mono.suite
  @ suite_group "CoreDesugar" Test_core_desugar.suite
  @ suite_group "CoreSsa" Test_core_ssa.suite
  @ suite_group "CoreMatch" Test_core_match.suite
  @ suite_group "CoreTailrec" Test_core_tailrec.suite
  @ suite_group "CoreTraitResolve" Test_core_trait_resolve.suite
  @ suite_group "CoreIntrinsics" Test_core_intrinsics.suite
  @ suite_group "CoreCollectionPipeline" Test_core_collection_pipeline.suite
  @ suite_group "CoreParallelVectorPipeline"
      Test_core_parallel_tensor_pipeline.suite
  @ suite_group "CoreStringPipeline" Test_core_string_pipeline.suite
  @ suite_group "CoreTupleSroa" Test_core_tuple_sroa.suite
  @ suite_group "CoreLayoutType" Test_core_layout_type.suite
  @ suite_group "CoreListLayout" Test_core_list_layout.suite
  @ suite_group "CoreTypeLayout" Test_core_type_layout.suite
  @ suite_group "CoreOptionLayout" Test_core_option_layout.suite
  @ suite_group "CoreResultLayout" Test_core_result_layout.suite
  @ suite_group "CoreOwnership" Test_core_ownership.suite
  @ suite_group "OperationResultMetadata" Test_operation_result_metadata.suite
  @ suite_group "CoreClosure" Test_core_closure.suite
  @ suite_group "BuiltinConsistency" Test_builtin_consistency.suite
  @ suite_group "DimSolver" Test_dim_solver.suite
  @ suite_group "CoreStage" Test_core_stage.suite
  @ suite_group "CoreObservability" Test_core_observability.suite
  @ suite_group "Invariants" Test_invariants.suite
  @ suite_group "IntrinsicContract" Test_intrinsic_contract.suite
  @ suite_group "DoctestRemap" Test_doctest_remap.suite
  @ suite_group "CodegenNames" Test_codegen_names.suite
  @ suite_group "CompilerBlorpBridgeTransport"
      Test_compiler_blorp_bridge.transport_suite

let deep_suites =
  (* These suites cross larger compiler boundaries: process/session state, LSP,
     package lifecycle, module/pipeline orchestration, runtime test execution,
     or the Blorp bridge. Keeping them in a named deep gate makes the default
     unit loop unit-shaped without deleting the coverage. *)
  suite_group "Session" Test_session.suite
  @ suite_group "LspHover" Test_lsp_hover.suite
  @ suite_group "LspDiagnostics" Test_lsp_diagnostics.suite
  @ suite_group "LspJson" Test_lsp_json.suite
  @ suite_group "LspProtocol" Test_lsp_protocol.suite
  @ suite_group "LspRpc" Test_lsp_rpc.suite
  @ suite_group "LspState" Test_lsp_state.suite
  @ suite_group "LspServer" Test_lsp_server.suite
  @ suite_group "LspSymbols" Test_lsp_symbols.suite
  @ suite_group "LspSignature" Test_lsp_signature.suite
  @ suite_group "LspCompletion" Test_lsp_completion.suite
  @ suite_group "LspDefinition" Test_lsp_definition.suite
  @ suite_group "LspPosition" Test_lsp_position.suite
  @ suite_group "PackageManifest" Test_package_manifest.suite
  @ suite_group "PackageCheck" Test_package_check.suite
  @ suite_group "PackageHash" Test_package_hash.suite
  @ suite_group "PackageArtifact" Test_package_artifact.suite
  @ suite_group "PackageConfig" Test_package_config.suite
  @ suite_group "PackageCache" Test_package_cache.suite
  @ suite_group "Pipeline" Test_pipeline.suite
  @ suite_group "TestRunner" Test_test_runner.suite
  @ suite_group "CompilerTestRunner" Test_compiler_test_runner.suite
  @ suite_group "CompilerBlorpBridge" Test_compiler_blorp_bridge.suite
  @ suite_group "SemanticMiddleWorker" Test_semantic_middle_worker.suite

let suites_for_scope = function
  | Default -> default_suites
  | Deep -> deep_suites
  | All -> default_suites @ deep_suites

let timed_case config ~scope ~suite_name (case_name, speed, run) =
  let timed_run input =
    let started = Unix.gettimeofday () in
    Fun.protect
      ~finally:(fun () ->
        let elapsed = Unix.gettimeofday () -. started in
        Printf.printf "%s\t%s\t%s\t%s\t%s\t%.6f\n%!" timing_line_prefix
          config.timing_run_id (scope_name scope) (timing_field suite_name)
          (timing_field case_name) elapsed)
      (fun () -> run input)
  in
  (case_name, speed, timed_run)

let maybe_time_suites config scope suites =
  if not config.timings_enabled then suites
  else
    List.map
      (fun (suite_name, cases) ->
        (suite_name, List.map (timed_case config ~scope ~suite_name) cases))
      suites

let () =
  match parse_runner_args Sys.argv with
  | Error message ->
      prerr_endline ("Error: " ^ message);
      exit 2
  | Ok (config, alcotest_argv) ->
      Alcotest.run ~argv:alcotest_argv "blorp"
        (suites_for_scope config.scope
        |> maybe_time_suites config config.scope)
