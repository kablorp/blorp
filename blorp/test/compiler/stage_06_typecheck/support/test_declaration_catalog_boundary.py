#!/usr/bin/env python3
"""Guard the declaration catalog's pre-assembly dependency boundary."""

from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[5]
CATALOG = ROOT / "blorp/src/compiler/stage_06_typecheck/headers/declaration_catalog.brp"
DECL = ROOT / "blorp/src/compiler/stage_06_typecheck/decl.brp"
INFER = ROOT / "blorp/src/compiler/stage_06_typecheck/infer.brp"
ENV = ROOT / "blorp/src/compiler/stage_06_typecheck/type_system/env.brp"
FRONTEND_PROFILE_FIXTURE = (
    ROOT / "blorp/benchmark/compiler/compiler_frontend_declaration_catalog_profile_fixture.brp"
)
ALIAS_GRAPH = (
    ROOT / "blorp/src/compiler/stage_06_typecheck/headers/accepted_alias_graph.brp"
)
ALIAS_AUTHORITY = (
    ROOT / "blorp/src/compiler/stage_06_typecheck/type_system/accepted_alias_authority.brp"
)
RECORD_GRAPH = (
    ROOT / "blorp/src/compiler/stage_06_typecheck/headers/accepted_record_graph.brp"
)
UNION_GRAPH = (
    ROOT / "blorp/src/compiler/stage_06_typecheck/headers/accepted_union_graph.brp"
)
TYPE_HEADER_INSTALL = (
    ROOT / "blorp/src/compiler/stage_06_typecheck/headers/type_header_install.brp"
)
GLOBAL_AUTHORITY = (
    ROOT
    / "blorp/src/compiler/stage_06_typecheck/type_system/accepted_global_authority.brp"
)
CALLABLE_AUTHORITY = (
    ROOT
    / "blorp/src/compiler/stage_06_typecheck/type_system/accepted_callable_authority.brp"
)
TRAIT_IMPLEMENTATION_AUTHORITY = (
    ROOT
    / "blorp/src/compiler/stage_06_typecheck/type_system/accepted_trait_implementation_authority.brp"
)
DECL_IMPORT = re.compile(r"(?m)^\s*\.\./decl(?:\s|:|$)")


def source_without_comments() -> str:
    lines = CATALOG.read_text(encoding="utf-8").splitlines()
    return "\n".join(line.split("--", 1)[0] for line in lines)


class DeclarationCatalogBoundaryTests(unittest.TestCase):
    def test_decl_import_pattern_covers_every_import_form(self) -> None:
        for import_line in ("\t../decl", "\t../decl:", "\t../decl as Decl"):
            with self.subTest(import_line=import_line):
                self.assertRegex(import_line, DECL_IMPORT)

        self.assertNotRegex("\t../declaration_skeleton: GlobalId", DECL_IMPORT)

    def test_catalog_does_not_depend_on_decl_graph_assembly(self) -> None:
        source = source_without_comments()

        self.assertNotRegex(source, DECL_IMPORT)

        for forbidden_name in (
            "AcceptedTypecheckGraph",
            "CompletedGlobalHeader",
            "CompletedGlobalHeaderGraph",
            "accepted_typecheck_graph_",
            "completed_global_header_",
        ):
            with self.subTest(forbidden_name=forbidden_name):
                self.assertNotIn(forbidden_name, source)

    def test_migration_only_zero_metrics_are_not_production_fields(self) -> None:
        production_sources = "\n".join(
            path.read_text(encoding="utf-8")
            for path in (
                ALIAS_GRAPH,
                RECORD_GRAPH,
                UNION_GRAPH,
                GLOBAL_AUTHORITY,
                CALLABLE_AUTHORITY,
                TRAIT_IMPLEMENTATION_AUTHORITY,
            )
        )

        for obsolete_metric in (
            "legacy_alias_graph_symbol_installs",
            "legacy_record_graph_symbol_installs",
            "legacy_union_graph_symbol_installs",
            "legacy_graph_global_installs",
            "global_exact_query_graph_scans",
            "legacy_graph_callable_env_installs",
            "legacy_graph_overload_installs",
            "module_view_callable_full_record_copies",
            "exact_callable_query_graph_scans",
            "module_view_coherence_overlap_checks",
            "legacy_graph_trait_env_installs",
            "legacy_graph_implementation_env_installs",
            "module_view_full_record_copies",
            "exact_query_graph_scans",
        ):
            with self.subTest(obsolete_metric=obsolete_metric):
                self.assertNotIn(obsolete_metric, production_sources)

    def test_frontend_profile_does_not_model_legacy_env_publication(self) -> None:
        decl_source = DECL.read_text(encoding="utf-8")
        fixture_source = FRONTEND_PROFILE_FIXTURE.read_text(encoding="utf-8")

        for obsolete_observation in (
            "imported_type_header_installations",
            "imported_constructor_installations",
            "imported_callable_header_installations",
            "imported_global_header_installations",
            "imported_trait_header_installations",
            "imported_implementation_header_installations",
            "local_header_installations",
            "scope_symbol_insertions",
            "scope_batch_insertions",
            "environment_publications",
            "total_graph_declaration_installations",
            "duplicate_installation_factor_millis",
            "ordinary_body_environment_rebuilds",
            "body_checks_started",
        ):
            with self.subTest(obsolete_observation=obsolete_observation):
                self.assertNotIn(obsolete_observation, decl_source)
                self.assertNotIn(obsolete_observation, fixture_source)

        self.assertNotIn(
            "CompilerFrontendDeclarationRepresentationModel", fixture_source
        )
        self.assertNotIn(
            "compiler_frontend_declaration_catalog_profile_representation_model",
            fixture_source,
        )

    def test_unreachable_declaration_adapters_are_absent(self) -> None:
        sources_by_obsolete_helper = {
            "accepted_record_graph_table": RECORD_GRAPH,
            "local_record_header_fields": TYPE_HEADER_INSTALL,
            "local_union_header_variants": TYPE_HEADER_INSTALL,
            "accepted_implementation_find_exact": TRAIT_IMPLEMENTATION_AUTHORITY,
        }

        for obsolete_helper, source_path in sources_by_obsolete_helper.items():
            with self.subTest(obsolete_helper=obsolete_helper):
                self.assertNotIn(
                    f"func {obsolete_helper}(",
                    source_path.read_text(encoding="utf-8"),
                )

    def test_accepted_alias_projection_skips_provisional_payload_conversion(self) -> None:
        source = TYPE_HEADER_INSTALL.read_text(encoding="utf-8")
        function = re.search(
            r"private pure func install_alias_header\(.*?"
            r"(?=\n\npure func typecheck_install_local_builtin_headers)",
            source,
            re.DOTALL,
        )

        self.assertIsNotNone(function)
        body = function.group(0)
        authority_branch = body.index(
            "match module_view_accepted_alias_authority(state.module_view)"
        )
        provisional_conversion = body.index("semantic_type_from_resolved_shape(")
        self.assertLess(authority_branch, provisional_conversion)
        self.assertIn("accepted_alias_contains(authority, type_name)", body)

    def test_accepted_alias_membership_does_not_materialize_payload(self) -> None:
        source = ALIAS_AUTHORITY.read_text(encoding="utf-8")
        function = re.search(
            r"pure func accepted_alias_contains\(.*?(?=\n\nprivate pure func)",
            source,
            re.DOTALL,
        )

        self.assertIsNotNone(function)
        body = function.group(0)
        self.assertNotIn("accepted_alias_find_transparent", body)
        self.assertNotIn("accepted_alias_find_opaque", body)
        self.assertNotIn("local_transparent_alias_value", body)
        self.assertNotIn("local_opaque_alias_value", body)
        self.assertNotIn(".get(binding.payload_index)", body)
        self.assertNotIn(".get(binding.canonical_redirect_index)", body)

    def test_accepted_graph_globals_do_not_use_legacy_env_publication(self) -> None:
        self.assertTrue(GLOBAL_AUTHORITY.is_file())

        decl_source = DECL.read_text(encoding="utf-8")
        infer_source = INFER.read_text(encoding="utf-8")
        env_source = ENV.read_text(encoding="utf-8")

        for forbidden_name in (
            "register_global_header_for_source",
            "register_local_global_headers",
            "install_completed_globals_for_initializer",
            "completed_global_header_for_decl",
        ):
            with self.subTest(forbidden_name=forbidden_name):
                self.assertNotIn(forbidden_name, decl_source)

        self.assertNotIn("env_get_module_var_symbol", infer_source)
        self.assertNotIn("env_get_module_var_symbol", env_source)

    def test_global_table_uses_the_prepared_definition_index_directly(self) -> None:
        decl_source = DECL.read_text(encoding="utf-8")
        function = re.search(
            r"private pure func accepted_global_declared_binding\(.*?"
            r"(?=\n\nprivate pure func)",
            decl_source,
            re.DOTALL,
        )

        self.assertIsNotNone(function)
        body = function.group(0)
        self.assertIn("definition_index_find_source_definition_id", body)
        self.assertNotIn("typecheck_state_for_prepared_module_scope", body)

    def test_global_table_completion_failure_is_not_silently_discarded(self) -> None:
        decl_source = DECL.read_text(encoding="utf-8")

        self.assertIn(
            "accepted_global_table: Option[AcceptedGlobalTable]", decl_source
        )
        self.assertNotIn(
            ").get_or(initial_global_table)", decl_source
        )
        self.assertIn(
            '"internal typecheck error: completed globals did not match the accepted global "',
            decl_source,
        )
        self.assertIn('+ "table"', decl_source)

    def test_resolved_calls_do_not_require_an_exact_env_function_index(self) -> None:
        infer_source = INFER.read_text(encoding="utf-8")
        env_source = ENV.read_text(encoding="utf-8")

        self.assertIn("bound_type_params: List[BoundTypeParam]", infer_source)
        self.assertIn("debug_only: Bool", infer_source)

        for removed_name in (
            "function_indexes_by_callable_id",
            "scope_find_func_by_def_id",
            "env_find_func_by_def_id",
        ):
            with self.subTest(removed_name=removed_name):
                self.assertNotIn(removed_name, env_source)

    def test_accepted_graph_callables_do_not_use_legacy_env_publication(self) -> None:
        self.assertTrue(CALLABLE_AUTHORITY.is_file())

        decl_source = DECL.read_text(encoding="utf-8")
        infer_source = INFER.read_text(encoding="utf-8")
        env_source = ENV.read_text(encoding="utf-8")

        for removed_name in (
            "env_get_module_func_symbol",
            "env_find_func_named_by_def_id",
            "env_add_overload",
            "env_get_overloads",
            "env_resolve_overload",
        ):
            with self.subTest(removed_name=removed_name):
                self.assertNotIn(removed_name, env_source)
                self.assertNotIn(removed_name, infer_source)

        self.assertNotIn("overloads: List[OverloadSet]", env_source)
        self.assertNotIn("ufcs_methods: List[OverloadSet]", env_source)
        self.assertNotIn("env_add_ufcs_method", env_source)
        self.assertNotIn("env_lookup_module_ufcs_methods", env_source)
        self.assertNotIn("infer_bare_overload_callee", infer_source)
        self.assertNotIn("missing_bare_overload_call_result", infer_source)
        self.assertIn("accepted_callable_table", decl_source)
        self.assertIn("module_view_with_accepted_callable_authority", decl_source)

        preparation = re.search(
            r"private pure func prepare_accepted_callable_header\(.*?"
            r"(?=\n\nprivate pure func)",
            decl_source,
            re.DOTALL,
        )
        self.assertIsNotNone(preparation)
        self.assertNotIn("env_add_func_with_info", preparation.group(0))
        self.assertNotIn("env_extract_graph_callables", decl_source)

        body_signature = re.search(
            r"private pure func body_signature_from_accepted_header\(.*?"
            r"(?=\n\nprivate pure func)",
            decl_source,
            re.DOTALL,
        )
        self.assertIsNotNone(body_signature)
        self.assertIn("accepted_callable_find_exact", body_signature.group(0))
        self.assertNotIn("callable_header_semantic_type", body_signature.group(0))

        authority_source = CALLABLE_AUTHORITY.read_text(encoding="utf-8")
        self.assertNotIn("owner_entry:", authority_source)
        self.assertNotIn("canonical_entry:", authority_source)

        graph_preparation = re.search(
            r"private pure func prepared_module_environments\(.*?"
            r"(?=\n\nprivate pure func)",
            decl_source,
            re.DOTALL,
        )
        self.assertIsNotNone(graph_preparation)
        self.assertEqual(
            graph_preparation.group(0).count(
                "for header in callable_header_graph_callables(callable_headers):"
            ),
            1,
        )
        self.assertIn("base_indices_by_module", graph_preparation.group(0))

if __name__ == "__main__":
    unittest.main()
