#!/usr/bin/env python3
"""Keep the machine-owned Core ownership-node inventory synchronized."""

from __future__ import annotations

import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
CORE_ROOT = ROOT / "compiler" / "blorp" / "src" / "stage_09_core"
INVENTORY = (
    ROOT / "compiler" / "blorp" / "tests" / "core_ownership_node_inventory.txt"
)
OWNERSHIP_NODE = re.compile(r"\b(?:DupExpr|DropExpr)\(")


class PerceusOwnershipNodeInventoryTests(unittest.TestCase):
    def test_inventory_names_every_module_with_ownership_nodes(self) -> None:
        actual = {
            path.name
            for path in CORE_ROOT.glob("*.brp")
            if OWNERSHIP_NODE.search(path.read_text(encoding="utf-8"))
        }
        documented = {
            line.strip()
            for line in INVENTORY.read_text(encoding="utf-8").splitlines()
            if line.strip()
        }

        self.assertEqual(actual, documented)


if __name__ == "__main__":
    unittest.main()
