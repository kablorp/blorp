#!/usr/bin/env python3
"""Keep the reviewed Core ownership-node inventory synchronized."""

from __future__ import annotations

import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
CORE_ROOT = ROOT / "compiler" / "blorp" / "src" / "stage_09_core"
INVENTORY = ROOT / "docs" / "PERCEUS_OWNERSHIP_NODE_INVENTORY.md"
OWNERSHIP_NODE = re.compile(r"\b(?:DupExpr|DropExpr)\(")
MODULE_REFERENCE = re.compile(r"`(core_[a-z0-9_]+[.]brp)`")


class PerceusOwnershipNodeInventoryTests(unittest.TestCase):
    def test_inventory_names_every_module_with_ownership_nodes(self) -> None:
        actual = {
            path.name
            for path in CORE_ROOT.glob("*.brp")
            if OWNERSHIP_NODE.search(path.read_text(encoding="utf-8"))
        }
        documented = set(MODULE_REFERENCE.findall(INVENTORY.read_text(encoding="utf-8")))

        self.assertEqual(actual, documented)


if __name__ == "__main__":
    unittest.main()
