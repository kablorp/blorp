#!/usr/bin/env python3
"""Guard the declaration catalog's pre-assembly dependency boundary."""

from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[5]
CATALOG = ROOT / "blorp/src/compiler/stage_06_typecheck/headers/declaration_catalog.brp"
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


if __name__ == "__main__":
    unittest.main()
