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
GLOBAL_AUTHORITY = (
    ROOT
    / "blorp/src/compiler/stage_06_typecheck/type_system/accepted_global_authority.brp"
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
            '"internal typecheck error: completed globals did not match "',
            decl_source,
        )

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


if __name__ == "__main__":
    unittest.main()
