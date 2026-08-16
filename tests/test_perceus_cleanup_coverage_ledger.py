#!/usr/bin/env python3
"""Contract checks for the executable Perceus cleanup coverage ledger."""

from __future__ import annotations

import csv
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
LEDGER = ROOT / "compiler" / "blorp" / "tests" / "perceus_cleanup_coverage_ledger.tsv"
EXPECTED_COLUMNS = (
    "area",
    "counterexample",
    "current_test",
    "required_test",
    "owning_slice",
    "oracle",
    "gate",
)


class PerceusCleanupCoverageLedgerTests(unittest.TestCase):
    def rows(self) -> list[dict[str, str]]:
        with LEDGER.open(encoding="utf-8", newline="") as ledger_file:
            reader = csv.DictReader(ledger_file, delimiter="\t")
            self.assertEqual(tuple(reader.fieldnames or ()), EXPECTED_COLUMNS)
            return list(reader)

    def test_every_counterexample_has_a_concrete_test_and_gate(self) -> None:
        rows = self.rows()
        self.assertGreaterEqual(len(rows), 25)
        for row in rows:
            with self.subTest(area=row["area"]):
                self.assertTrue(all(row[column].strip() for column in EXPECTED_COLUMNS))
                self.assertTrue(row["current_test"].startswith("test_"))
                self.assertTrue(row["required_test"].startswith("test_"))

    def test_areas_and_required_tests_are_unique(self) -> None:
        rows = self.rows()
        self.assertEqual(len({row["area"] for row in rows}), len(rows))
        self.assertEqual(len({row["required_test"] for row in rows}), len(rows))


if __name__ == "__main__":
    unittest.main()
