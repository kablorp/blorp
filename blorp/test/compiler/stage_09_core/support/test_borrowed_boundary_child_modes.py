#!/usr/bin/env python3
"""Keep the Perceus borrowed-boundary child-mode inventory exhaustive."""

from __future__ import annotations

import importlib.util
import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[5]
IR_SOURCE = ROOT / "blorp" / "src" / "compiler" / "stage_09_core" / "ir.brp"
INVENTORY_SOURCE = Path(__file__).with_name(
    "test_borrowed_boundary_child_mode_inventory.py"
)


def load_inventory():
    spec = importlib.util.spec_from_file_location(
        "test_borrowed_boundary_child_mode_inventory",
        INVENTORY_SOURCE,
    )
    if spec is None or spec.loader is None:
        raise RuntimeError("could not load borrowed-boundary inventory")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def core_type_blocks(source: str) -> dict[str, str]:
    return {
        match.group(2): match.group(3)
        for match in re.finditer(
            r"^(record|struct|union) (Core\w+)[^\n]*(?::|\{)\n"
            r"((?:\t[^\n]*\n|\n)+)",
            source,
            re.MULTILINE,
        )
    }


def expression_bearing_composites(blocks: dict[str, str]) -> set[str]:
    expression_bearing = {"CoreExpr"}
    changed = True
    while changed:
        changed = False
        for name, body in blocks.items():
            if name in expression_bearing:
                continue
            if any(
                re.search(rf"\b{re.escape(child_type)}\b", body)
                for child_type in expression_bearing
            ):
                expression_bearing.add(name)
                changed = True
    expression_bearing.remove("CoreExpr")
    return expression_bearing


class BorrowedBoundaryChildModeInventoryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.source = IR_SOURCE.read_text(encoding="utf-8")
        cls.blocks = core_type_blocks(cls.source)
        cls.inventory = load_inventory()

    def test_inventory_names_every_core_expression_variant(self) -> None:
        variants = {
            match.group(1)
            for match in re.finditer(
                r"^\t(\w+)(?:\(|$)",
                self.blocks["CoreExpr"],
                re.MULTILINE,
            )
        }
        documented = set(self.inventory.BORROWED_BOUNDARY_CHILD_MODES)

        self.assertEqual(variants, documented)

    def test_inventory_names_every_expression_bearing_core_composite(self) -> None:
        actual = expression_bearing_composites(self.blocks)

        self.assertEqual(
            actual,
            set(self.inventory.EXPRESSION_BEARING_CORE_COMPOSITES),
        )

    def test_every_child_uses_closed_independent_mode_dimensions(self) -> None:
        allowed_call = {"skip", "traverse", "legacy_fallback", "boundary"}
        allowed_storage = {"skip", "traverse", "transfer", "conditional_transfer"}
        allowed_result = {"skip", "traverse", "terminal", "satisfied_traverse"}

        for variant, entry in self.inventory.BORROWED_BOUNDARY_CHILD_MODES.items():
            with self.subTest(variant=variant):
                self.assertIn(entry["classification"], {
                    "leaf",
                    "opaque",
                    "structural",
                    "boundary",
                })
                self.assertIsInstance(entry["children"], dict)
                for child, modes in entry["children"].items():
                    with self.subTest(variant=variant, child=child):
                        self.assertEqual(len(modes), 3)
                        self.assertIn(modes[0], allowed_call)
                        self.assertIn(modes[1], allowed_storage)
                        self.assertIn(modes[2], allowed_result)

    def test_expression_bearing_variants_document_children_or_opacity(self) -> None:
        expression_types = expression_bearing_composites(self.blocks) | {"CoreExpr"}
        for variant_match in re.finditer(
            r"^\t(\w+)(?:\(([^\n]*)\))?$",
            self.blocks["CoreExpr"],
            re.MULTILINE,
        ):
            variant, fields = variant_match.groups()
            fields = fields or ""
            bears_expression = any(
                re.search(rf"\b{re.escape(child_type)}\b", fields)
                for child_type in expression_types
            )
            entry = self.inventory.BORROWED_BOUNDARY_CHILD_MODES[variant]
            if bears_expression:
                self.assertTrue(
                    entry["children"] or entry["classification"] == "opaque",
                    f"{variant} has expression children but documents neither modes nor opacity",
                )


if __name__ == "__main__":
    unittest.main()
