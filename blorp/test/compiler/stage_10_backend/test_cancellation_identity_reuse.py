"""Static contract for sharing the cancellation identity index."""

from __future__ import annotations

import re
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[4]
CANCELLATION_PLAN = (
    ROOT / "blorp" / "src" / "compiler" / "stage_10_backend" / "cancellation_plan.brp"
)


class CancellationIdentityReuseTests(unittest.TestCase):
    def test_program_analysis_builds_and_shares_one_identity_index(self) -> None:
        source = CANCELLATION_PLAN.read_text(encoding="utf-8")

        self.assertEqual(
            source.count("identity_index(functions.map(function_identity))"),
            1,
        )
        self.assertRegex(
            source,
            re.compile(
                r"private\s+pure\s+func\s+analyze_function_cancellation\(\s*"
                r"functions:\s*List\[CoreFunction\],\s*"
                r"identities:\s*CancellationIdentityIndex,\s*"
                r"\)\s*->\s*List\[CancellationFunctionSummary\]:"
            ),
        )
        self.assertRegex(
            source,
            re.compile(
                r"function_results:\s*List\[CancellationFunctionSummary\]\s*=\s*"
                r"analyze_function_cancellation\(\s*"
                r"functions,\s*identities,\s*\)"
            ),
        )
        self.assertRegex(
            source,
            re.compile(
                r"global_initializer_summary\(\s*"
                r"global,\s*identities,\s*summaries_by_def_id,\s*\)"
            ),
        )


if __name__ == "__main__":
    unittest.main()
