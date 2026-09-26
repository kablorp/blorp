#!/usr/bin/env python3
"""Contract test for opt-in typecheck cost attribution.

`BLORP_TYPECHECK_BODY_METRICS=1` prints one row per graph-construction phase and
one row per checked body, plus project and dependency totals. With the variable
unset the compiler must print nothing and produce the same C.
"""

from __future__ import annotations

import os
import re
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[5]
COMPILER = ROOT / "bin/blorp"

PROGRAM = textwrap.dedent(
    """\
    import:
    \tio: print


    pure func doubled(value: Int) -> Int:
    \tvalue * 2


    func main(args: List[String]) -> Int:
    \tprint(doubled(21).to_string())
    \t0
    """
)

ROW = re.compile(
    r"^BLORP_TYPECHECK_BODY scope=(project|dependency) microseconds=(\d+) "
    r"allocations=(\d+) source_lines=(-?\d+) module=(\S+) callable=(\S*)$"
)
PHASE = re.compile(
    r"^BLORP_TYPECHECK_PHASE phase=(\S+) microseconds=(\d+) allocations=(\d+)$"
)
TOTAL = re.compile(
    r"^BLORP_TYPECHECK_BODY_TOTAL scope=(project|dependency|all) bodies=(\d+) "
    r"microseconds=(\d+) allocations=(\d+)$"
)


class TypecheckBodyMetricsTests(unittest.TestCase):
    def compile_program(self, source_path: Path, output_path: Path, metrics: bool):
        environment = dict(os.environ)
        environment.pop("BLORP_TYPECHECK_BODY_METRICS", None)
        if metrics:
            environment["BLORP_TYPECHECK_BODY_METRICS"] = "1"
        completed = subprocess.run(
            [
                str(COMPILER),
                "compile",
                "--no-format",
                "-o",
                str(output_path),
                str(source_path),
            ],
            cwd=ROOT,
            env=environment,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=False,
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        return completed

    def test_metrics_are_opt_in_and_do_not_change_the_generated_c(self) -> None:
        self.assertTrue(COMPILER.exists(), f"missing {COMPILER}; run make first")
        with tempfile.TemporaryDirectory() as temp_name:
            temp = Path(temp_name)
            source = temp / "body_metrics_probe.brp"
            source.write_text(PROGRAM)
            quiet_output = temp / "quiet.c"
            metrics_output = temp / "metrics.c"

            quiet = self.compile_program(source, quiet_output, metrics=False)
            self.assertNotIn("BLORP_TYPECHECK", quiet.stderr)

            loud = self.compile_program(source, metrics_output, metrics=True)
            self.assertEqual(
                quiet_output.read_bytes(),
                metrics_output.read_bytes(),
                "per-body metrics must not change the generated C",
            )

            phases = []
            rows = []
            totals = {}
            previous_microseconds = None
            for line in loud.stderr.splitlines():
                phase = PHASE.match(line)
                if phase:
                    phases.append(phase.group(1))
                    continue
                row = ROW.match(line)
                if row:
                    microseconds = int(row.group(2))
                    if previous_microseconds is not None:
                        self.assertLessEqual(
                            microseconds,
                            previous_microseconds,
                            "rows must be sorted by cost",
                        )
                    previous_microseconds = microseconds
                    rows.append(
                        {
                            "scope": row.group(1),
                            "microseconds": microseconds,
                            "allocations": int(row.group(3)),
                            "module": row.group(5),
                            "callable": row.group(6),
                        }
                    )
                    continue
                total = TOTAL.match(line)
                if total:
                    totals[total.group(1)] = {
                        "bodies": int(total.group(2)),
                        "microseconds": int(total.group(3)),
                        "allocations": int(total.group(4)),
                    }

            self.assertTrue(rows, "expected one row per checked body")
            for expected in (
                "indexed_graph",
                "bound_modules",
                "declaration_skeletons",
                "type_headers",
                "callable_headers",
                "implementation_headers",
                "prepare_products",
                "prepare_bases",
                "prepare_traits",
                "prepare_trait_authority",
                "prepare_callables",
                "prepare_impls",
                "prepare_environments",
                "global_header_completion",
                "module_bodies",
            ):
                self.assertIn(expected, phases, "expected a row for every phase")
            preparation_phases = [
                "prepare_products",
                "prepare_bases",
                "prepare_traits",
                "prepare_trait_authority",
                "prepare_callables",
                "prepare_impls",
                "prepare_environments",
            ]
            self.assertEqual(
                sorted(preparation_phases, key=phases.index),
                preparation_phases,
                "module preparation rows must preserve execution order",
            )
            self.assertLess(
                phases.index("bound_modules"),
                phases.index("module_bodies"),
                "phase rows are printed in the order the frontend runs them",
            )
            self.assertEqual({"project", "dependency", "all"}, set(totals))

            project_rows = [row for row in rows if row["scope"] == "project"]
            dependency_rows = [row for row in rows if row["scope"] == "dependency"]
            self.assertTrue(dependency_rows, "standard-library bodies are dependencies")
            self.assertIn(
                "doubled",
                {row["callable"] for row in project_rows},
                "the program's own body belongs to the project scope",
            )

            for scope, scope_rows in (
                ("project", project_rows),
                ("dependency", dependency_rows),
                ("all", rows),
            ):
                self.assertEqual(totals[scope]["bodies"], len(scope_rows), scope)
                self.assertEqual(
                    totals[scope]["allocations"],
                    sum(row["allocations"] for row in scope_rows),
                    scope,
                )
                self.assertEqual(
                    totals[scope]["microseconds"],
                    sum(row["microseconds"] for row in scope_rows),
                    scope,
                )

            self.assertGreater(
                totals["dependency"]["allocations"],
                0,
                "the allocation counter must be live under the metrics flag",
            )


if __name__ == "__main__":
    unittest.main()
