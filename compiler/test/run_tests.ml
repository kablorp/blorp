(** Main test runner — aggregates all unit test suites *)

let () =
  Alcotest.run "blorp"
    (List.map
       (fun (name, cases) -> ("Session." ^ name, cases))
       Test_session.suite
    @ List.map
        (fun (name, cases) -> ("TypedAst." ^ name, cases))
        Test_typed_ast.suite
    @ List.map
        (fun (name, cases) -> ("TypedAstDebug." ^ name, cases))
        Test_typed_ast_debug.suite
    @ List.map
        (fun (name, cases) -> ("CompileProfile." ^ name, cases))
        Test_compile_profile.suite
    @ List.map
        (fun (name, cases) -> ("LspHover." ^ name, cases))
        Test_lsp_hover.suite
    @ List.map
        (fun (name, cases) -> ("LspDiagnostics." ^ name, cases))
        Test_lsp_diagnostics.suite
    @ List.map
        (fun (name, cases) -> ("LspJson." ^ name, cases))
        Test_lsp_json.suite
    @ List.map
        (fun (name, cases) -> ("LspProtocol." ^ name, cases))
        Test_lsp_protocol.suite
    @ List.map
        (fun (name, cases) -> ("LspRpc." ^ name, cases))
        Test_lsp_rpc.suite
    @ List.map
        (fun (name, cases) -> ("LspState." ^ name, cases))
        Test_lsp_state.suite
    @ List.map
        (fun (name, cases) -> ("LspServer." ^ name, cases))
        Test_lsp_server.suite
    @ List.map
        (fun (name, cases) -> ("LspSymbols." ^ name, cases))
        Test_lsp_symbols.suite
    @ List.map
        (fun (name, cases) -> ("Diagnostics." ^ name, cases))
        Test_diagnostics.suite
    @ List.map
        (fun (name, cases) -> ("LspSignature." ^ name, cases))
        Test_lsp_signature.suite
    @ List.map
        (fun (name, cases) -> ("LspCompletion." ^ name, cases))
        Test_lsp_completion.suite
    @ List.map
        (fun (name, cases) -> ("LspDefinition." ^ name, cases))
        Test_lsp_definition.suite
    @ List.map
        (fun (name, cases) -> ("LspPosition." ^ name, cases))
        Test_lsp_position.suite
    @ List.map
        (fun (name, cases) -> ("TypeMetadataFormat." ^ name, cases))
        Test_type_metadata_format.suite
    @ List.map (fun (name, cases) -> ("Types." ^ name, cases)) Test_types.suite
    @ List.map
        (fun (name, cases) -> ("TypeResolution." ^ name, cases))
        Test_type_resolution.suite
    @ List.map
        (fun (name, cases) -> ("TypeWidening." ^ name, cases))
        Test_type_widening.suite
    @ List.map
        (fun (name, cases) -> ("Refinement." ^ name, cases))
        Test_refinement.suite
    @ List.map
        (fun (name, cases) -> ("InferTypeNormalization." ^ name, cases))
        Test_infer_type_normalization.suite
    @ List.map
        (fun (name, cases) -> ("TypeBoundaryHygiene." ^ name, cases))
        Test_type_boundary_hygiene.suite
    @ List.map
        (fun (name, cases) -> ("GenericParams." ^ name, cases))
        Test_generic_params.suite
    @ List.map
        (fun (name, cases) -> ("Parser." ^ name, cases))
        Test_parser.suite
    @ List.map
        (fun (name, cases) -> ("FmtExprJson." ^ name, cases))
        Test_fmt_expr_doc.suite
    @ List.map
        (fun (name, cases) -> ("FmtComment." ^ name, cases))
        Test_fmt_comment.suite
    @ List.map
        (fun (name, cases) -> ("FmtDeclDoc." ^ name, cases))
        Test_fmt_decl_doc.suite
    @ List.map
        (fun (name, cases) -> ("FmtEmbedding." ^ name, cases))
        Test_fmt_embedding.suite
    @ List.map
        (fun (name, cases) -> ("TraitObligationArchitecture." ^ name, cases))
        Test_trait_obligation_architecture.suite
    @ List.map (fun (name, cases) -> ("Infer." ^ name, cases)) Test_infer.suite
    @ List.map
        (fun (name, cases) -> ("PurityAnalysis." ^ name, cases))
        Test_purity_analysis.suite
    @ List.map
        (fun (name, cases) -> ("Pipeline." ^ name, cases))
        Test_pipeline.suite
    @ List.map (fun (name, cases) -> ("Env." ^ name, cases)) Test_env.suite
    @ List.map
        (fun (name, cases) -> ("Typecheck." ^ name, cases))
        Test_typecheck.suite
    @ List.map
        (fun (name, cases) -> ("FfiBoundary." ^ name, cases))
        Test_ffi_boundary.suite
    @ List.map (fun (name, cases) -> ("Core." ^ name, cases)) Test_core.suite
    @ List.map
        (fun (name, cases) -> ("CoreFlatten." ^ name, cases))
        Test_core_flatten.suite
    @ List.map
        (fun (name, cases) -> ("CoreLower." ^ name, cases))
        Test_core_lower.suite
    @ List.map
        (fun (name, cases) -> ("CoreFfiBoundary." ^ name, cases))
        Test_core_ffi_boundary.suite
    @ List.map
        (fun (name, cases) -> ("CoreEmit." ^ name, cases))
        Test_core_emit.suite
    @ List.map
        (fun (name, cases) -> ("CoreResolve." ^ name, cases))
        Test_core_resolve.suite
    @ List.map
        (fun (name, cases) -> ("CoreStdInline." ^ name, cases))
        Test_core_std_inline.suite
    @ List.map
        (fun (name, cases) -> ("CoreSpecialize." ^ name, cases))
        Test_core_specialize.suite
    @ List.map
        (fun (name, cases) -> ("CoreDce." ^ name, cases))
        Test_core_dce.suite
    @ List.map
        (fun (name, cases) -> ("CoreCodegenPrepare." ^ name, cases))
        Test_core_codegen_prepare.suite
    @ List.map
        (fun (name, cases) -> ("CoreTensorStorageProducer." ^ name, cases))
        Test_core_tensor_storage_producer.suite
    @ List.map
        (fun (name, cases) -> ("CoreTensorType." ^ name, cases))
        Test_core_tensor_type.suite
    @ List.map
        (fun (name, cases) -> ("CoreMono." ^ name, cases))
        Test_core_mono.suite
    @ List.map
        (fun (name, cases) -> ("CoreDesugar." ^ name, cases))
        Test_core_desugar.suite
    @ List.map
        (fun (name, cases) -> ("CoreSsa." ^ name, cases))
        Test_core_ssa.suite
    @ List.map
        (fun (name, cases) -> ("CoreMatch." ^ name, cases))
        Test_core_match.suite
    @ List.map
        (fun (name, cases) -> ("CoreEmitUtil." ^ name, cases))
        Test_core_emit_util.suite
    @ List.map
        (fun (name, cases) -> ("CoreTailrec." ^ name, cases))
        Test_core_tailrec.suite
    @ List.map
        (fun (name, cases) -> ("CoreTraitResolve." ^ name, cases))
        Test_core_trait_resolve.suite
    @ List.map
        (fun (name, cases) -> ("CoreIntrinsics." ^ name, cases))
        Test_core_intrinsics.suite
    @ List.map
        (fun (name, cases) -> ("CoreCollectionPipeline." ^ name, cases))
        Test_core_collection_pipeline.suite
    @ List.map
        (fun (name, cases) -> ("CoreParallelVectorPipeline." ^ name, cases))
        Test_core_parallel_tensor_pipeline.suite
    @ List.map
        (fun (name, cases) -> ("CoreStringPipeline." ^ name, cases))
        Test_core_string_pipeline.suite
    @ List.map
        (fun (name, cases) -> ("CoreTupleSroa." ^ name, cases))
        Test_core_tuple_sroa.suite
    @ List.map
        (fun (name, cases) -> ("CoreLayoutType." ^ name, cases))
        Test_core_layout_type.suite
    @ List.map
        (fun (name, cases) -> ("CoreListLayout." ^ name, cases))
        Test_core_list_layout.suite
    @ List.map
        (fun (name, cases) -> ("CoreTypeLayout." ^ name, cases))
        Test_core_type_layout.suite
    @ List.map
        (fun (name, cases) -> ("CoreOptionLayout." ^ name, cases))
        Test_core_option_layout.suite
    @ List.map
        (fun (name, cases) -> ("CoreResultLayout." ^ name, cases))
        Test_core_result_layout.suite
    @ List.map
        (fun (name, cases) -> ("CoreErasureInventory." ^ name, cases))
        Test_core_erasure_inventory.suite
    @ List.map
        (fun (name, cases) -> ("CoreOwnership." ^ name, cases))
        Test_core_ownership.suite
    @ List.map
        (fun (name, cases) -> ("CorePerceus." ^ name, cases))
        Test_core_perceus.suite
    @ List.map
        (fun (name, cases) -> ("CoreResource." ^ name, cases))
        Test_core_resource.suite
    @ List.map
        (fun (name, cases) -> ("CoreReuse." ^ name, cases))
        Test_core_reuse.suite
    @ List.map
        (fun (name, cases) -> ("CoreClosure." ^ name, cases))
        Test_core_closure.suite
    @ List.map
        (fun (name, cases) -> ("CorePerceusCheck." ^ name, cases))
        Test_core_perceus_check.suite
    @ List.map
        (fun (name, cases) -> ("BuiltinConsistency." ^ name, cases))
        Test_builtin_consistency.suite
    @ List.map
        (fun (name, cases) -> ("DimSolver." ^ name, cases))
        Test_dim_solver.suite
    @ List.map
        (fun (name, cases) -> ("CoreStage." ^ name, cases))
        Test_core_stage.suite
    @ List.map
        (fun (name, cases) -> ("CoreObservability." ^ name, cases))
        Test_core_observability.suite
    @ List.map
        (fun (name, cases) -> ("CoreError." ^ name, cases))
        Test_core_error.suite
    @ List.map
        (fun (name, cases) -> ("Invariants." ^ name, cases))
        Test_invariants.suite
    @ List.map
        (fun (name, cases) -> ("IntrinsicContract." ^ name, cases))
        Test_intrinsic_contract.suite
    @ List.map
        (fun (name, cases) -> ("Backend." ^ name, cases))
        Test_backend.suite
    @ List.map
        (fun (name, cases) -> ("TestRunner." ^ name, cases))
        Test_test_runner.suite
    @ List.map
        (fun (name, cases) -> ("DoctestRemap." ^ name, cases))
        Test_doctest_remap.suite
    @ List.map
        (fun (name, cases) -> ("CodegenNames." ^ name, cases))
        Test_codegen_names.suite)
