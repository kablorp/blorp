"""Static contract for sharing the cancellation identity index."""

from __future__ import annotations

import re
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[4]
CANCELLATION_PLAN = (
    ROOT / "blorp" / "src" / "compiler" / "stage_09_core" / "cancellation_plan.brp"
)


class CancellationIdentityReuseTests(unittest.TestCase):
    def test_program_analysis_builds_and_shares_one_identity_index(self) -> None:
        source = CANCELLATION_PLAN.read_text(encoding="utf-8")

        self.assertEqual(
            source.count("identity_index(functions.map(function_identity))"),
            1,
        )
        # The one index reaches every consumer: each function's facts, the
        # function analysis (through those facts) and each global initializer.
        self.assertRegex(
            source,
            re.compile(
                r"facts:\s*List\[CancellationCallableFacts\]\s*=\s*functions\.map\(\s*"
                r"func\(function_info\):\s*callable_facts\(function_info,\s*identities\),?\s*\)"
            ),
        )
        self.assertRegex(
            source,
            re.compile(
                r"function_results:\s*List\[CancellationFunctionSummary\]\s*=\s*"
                r"analyze_function_cancellation\(\s*facts,?\s*\)"
            ),
        )
        self.assertRegex(
            source,
            re.compile(
                r"global_facts:\s*CancellationExprFacts\s*=\s*expression_cancellation_facts\(\s*"
                r"global\.init,\s*identities,?\s*\)"
            ),
        )


if __name__ == "__main__":
    unittest.main()
