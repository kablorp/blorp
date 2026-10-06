#!/usr/bin/env python3
"""Guard what CTFE dependency preparation may and may not skip.

The typed frontend prepares CTFE dependencies from a plan built out of the
import trees of modules that own a compile-time global. A global can also live
in a module outside that plan, and its initializer's callables are still CTFE
roots. Whatever the preparation does with those roots, three things must hold:

* a compile-time global still evaluates to the same value;
* a global that cannot be evaluated still fails loudly with its diagnostic,
  never silently or with a wrong value;
* `blorp check` still reports a body error in any module, in or out of the
  plan, because diagnostics come from the ordinary body loop.
"""

from __future__ import annotations

import os
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[5]
COMPILER = ROOT / "bin/blorp"

# b is reached only through a's compile-time global, so it is in the CTFE
# dependency plan. c owns a compile-time global whose initializer calls c's own
# function, and nothing puts c in the plan: its callable is a CTFE root with no
# prepared registry.
MODULES = {
    "b.brp": """\
        pure func base_value() -> Int:
        \t7
    """,
    "a.brp": """\
        import:
        \t./b: base_value


        A_VALUE: Int = base_value() * 2
    """,
    "c.brp": """\
        private pure func local_value() -> Int:
        \t5


        C_VALUE: Int = local_value() + 1
    """,
    "main.brp": """\
        import:
        \tio: print
        \t./a: A_VALUE
        \t./c: C_VALUE


        func main(args: List[String]) -> Int:
        \tprint((A_VALUE + C_VALUE).to_string())
        \t0
    """,
}

BROKEN_BODY = """\
    pure func base_value() -> Int:
    \t"not an int"
"""

BROKEN_OUT_OF_PLAN_BODY = """\
    private pure func local_value() -> Int:
    \t"not an int"


    C_VALUE: Int = local_value() + 1
"""

IMPURE_GLOBAL = """\
    import:
    \tsystem: now_microseconds


    C_VALUE: Int = now_microseconds() + 1
"""


class CtfeDependencyDemandTests(unittest.TestCase):
    def setUp(self) -> None:
        self.assertTrue(COMPILER.exists(), f"missing {COMPILER}; run make first")
        # The module path becomes a C identifier, and the sanitizer does not
        # escape hyphens, so keep the project directory free of them.
        self.temp = tempfile.TemporaryDirectory(prefix="ctfe_demand_")
        self.project = Path(self.temp.name) / "project"
        self.project.mkdir()
        for name, source in MODULES.items():
            (self.project / name).write_text(textwrap.dedent(source))
        self.addCleanup(self.temp.cleanup)

    def write(self, name: str, source: str) -> None:
        (self.project / name).write_text(textwrap.dedent(source))

    def blorp(self, *args: str):
        return subprocess.run(
            [str(COMPILER), *args],
            cwd=ROOT,
            env=dict(os.environ),
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            check=False,
        )

    def test_compile_time_globals_keep_their_values(self) -> None:
        completed = self.blorp("run", "--no-format", str(self.project / "main.brp"))
        self.assertEqual(completed.returncode, 0, completed.stdout)
        # A_VALUE is 7 * 2 through the planned dependency, C_VALUE is 5 + 1
        # through the module the plan does not contain.
        self.assertIn("20", completed.stdout.splitlines())

    def test_check_reports_a_body_error_in_a_planned_dependency(self) -> None:
        self.write("b.brp", BROKEN_BODY)
        completed = self.blorp("check", "--no-format", str(self.project / "main.brp"))
        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("Function 'base_value' returns wrong type", completed.stdout)

    def test_check_reports_a_body_error_outside_the_plan(self) -> None:
        self.write("c.brp", BROKEN_OUT_OF_PLAN_BODY)
        completed = self.blorp("check", "--no-format", str(self.project / "main.brp"))
        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("Function 'local_value' returns wrong type", completed.stdout)

    def test_an_unevaluatable_global_fails_loudly(self) -> None:
        self.write("c.brp", IMPURE_GLOBAL)
        completed = self.blorp("check", "--no-format", str(self.project / "main.brp"))
        self.assertNotEqual(completed.returncode, 0)
        self.assertIn(
            "compile-time constant evaluation does not support impure function calls",
            completed.stdout,
        )

    def test_generated_c_is_stable_for_the_same_sources(self) -> None:
        first = Path(self.temp.name) / "first.c"
        second = Path(self.temp.name) / "second.c"
        for output in (first, second):
            completed = self.blorp(
                "compile",
                "--no-format",
                "-o",
                str(output),
                str(self.project / "main.brp"),
            )
            self.assertEqual(completed.returncode, 0, completed.stdout)
        self.assertEqual(first.read_bytes(), second.read_bytes())
        self.assertIn(b"14", first.read_bytes())


if __name__ == "__main__":
    unittest.main()
