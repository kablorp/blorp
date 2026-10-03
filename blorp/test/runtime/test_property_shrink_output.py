"""Check the counterexample that property shrinking reports to callers."""

from __future__ import annotations

import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]


class PropertyShrinkOutputTests(unittest.TestCase):
    def test_reports_minimal_counterexamples_at_integer_boundaries(self) -> None:
        source = textwrap.dedent(
            """\
            import:
            \tproperty: check_shrink, gen_const

            func main(args: List[String]) -> Int:
            \tpositive: Bool = check_shrink(
            \t\t"positive threshold", 1, gen_const(80),
            \t\tpure func(value: Int): value < 50,
            \t)
            \tnegative: Bool = check_shrink(
            \t\t"negative threshold", 1, gen_const(-80),
            \t\tpure func(value: Int): value > -50,
            \t)
            \tzero: Bool = check_shrink(
            \t\t"zero", 1, gen_const(0),
            \t\tpure func(value: Int): value != 0,
            \t)
            \t-- Construct the most negative Int without an out-of-range literal.
            \tminimum_int: Int = -9223372036854775807 - 1
            \tminimum: Bool = check_shrink(
            \t\t"minimum Int", 1, gen_const(minimum_int),
            \t\tpure func(value: Int): value > -2,
            \t)
            \tif positive or negative or zero or minimum:
            \t\t1
            \telse:
            \t\t0
            """
        )
        with tempfile.TemporaryDirectory() as temp_name:
            program = Path(temp_name) / "property_shrink_output.brp"
            program.write_text(source, encoding="utf-8")
            completed = subprocess.run(
                [str(ROOT / "bin" / "blorp"), "run", str(program)],
                cwd=ROOT,
                capture_output=True,
                text=True,
                check=False,
            )

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(
            completed.stdout,
            "  FAIL: positive threshold — smallest counterexample: 50 (original: 80)\n"
            "  FAIL: negative threshold — smallest counterexample: -50 (original: -80)\n"
            "  FAIL: zero — smallest counterexample: 0 (original: 0)\n"
            "  FAIL: minimum Int — smallest counterexample: -2 "
            "(original: -9223372036854775808)\n",
        )


if __name__ == "__main__":
    unittest.main()
