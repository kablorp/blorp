#!/usr/bin/env python3
"""Contract test for the runtime's fatal allocation-size and out-of-memory
messages: each one reaches stderr as a single line ending in a real newline,
not a literal backslash followed by `n`. Follows
test_runtime_alloc_oracle.py's small-C-harness model.
"""

from __future__ import annotations

import os
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]

# Each scenario name selects one fatal path in the harness below.
HARNESS_SOURCE = textwrap.dedent(
    """\
    #define MINICORO_IMPL
    #include "minicoro.h"
    #include "runtime.c"

    int main(int argc, char** argv) {
        if (argc != 2) return 2;
        if (strcmp(argv[1], "negative_mul") == 0) {
            blorp_checked_mul(-1, 8);
        } else if (strcmp(argv[1], "overflow_mul") == 0) {
            blorp_checked_mul(LONG_MAX, LONG_MAX);
        } else if (strcmp(argv[1], "overflow_add") == 0) {
            blorp_checked_add(SIZE_MAX, 1);
        } else if (strcmp(argv[1], "malloc_too_large") == 0) {
            blorp_malloc_checked(SIZE_MAX);
        } else if (strcmp(argv[1], "realloc_too_large") == 0) {
            blorp_realloc_checked(NULL, SIZE_MAX);
        } else if (strcmp(argv[1], "calloc_too_large") == 0) {
            blorp_calloc_checked(SIZE_MAX, SIZE_MAX);
        } else {
            return 3;
        }
        return 4;
    }
    """
)

EXPECTED_MESSAGES = {
    "negative_mul": "blorp: negative allocation size (-1 * 8)",
    "overflow_mul": "blorp: allocation size overflow (",
    "overflow_add": "blorp: allocation size overflow (",
    "malloc_too_large": "blorp: out of memory (malloc ",
    "realloc_too_large": "blorp: out of memory (realloc ",
    "calloc_too_large": "blorp: out of memory (calloc ",
}


class RuntimeFatalMessageTests(unittest.TestCase):
    temp_dir: tempfile.TemporaryDirectory
    executable: Path

    @classmethod
    def setUpClass(cls) -> None:
        cls.temp_dir = tempfile.TemporaryDirectory()
        cls.executable = Path(cls.temp_dir.name) / "fatal-messages"
        compiled = subprocess.run(
            [
                os.environ.get("CC", "cc"),
                "-O0",
                "-w",
                f"-I{ROOT / 'blorp' / 'src' / 'lib' / 'runtime' / 'native'}",
                "-x",
                "c",
                "-",
                "-lm",
                "-lpthread",
                "-o",
                str(cls.executable),
            ],
            cwd=ROOT,
            input=HARNESS_SOURCE,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        if compiled.returncode != 0:
            cls.temp_dir.cleanup()
            raise AssertionError(compiled.stderr)

    @classmethod
    def tearDownClass(cls) -> None:
        cls.temp_dir.cleanup()

    def _fatal_message_line(self, scenario: str) -> str:
        """Run one scenario and return the runtime's fatal line with its
        terminator. The system allocator may print its own diagnostics
        before ours, so only the line starting with `blorp:` is checked."""
        completed = subprocess.run(
            [str(self.executable), scenario],
            cwd=ROOT,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=False,
        )
        self.assertEqual(completed.returncode, 1, completed.stderr)
        stderr = completed.stderr
        start = stderr.find("blorp:")
        self.assertNotEqual(start, -1, stderr)
        return stderr[start:]

    def test_fatal_messages_end_with_a_real_newline(self) -> None:
        for scenario, expected_prefix in EXPECTED_MESSAGES.items():
            with self.subTest(scenario=scenario):
                message = self._fatal_message_line(scenario)
                self.assertTrue(message.startswith(expected_prefix), repr(message))
                self.assertNotIn("\\n", message, repr(message))
                self.assertTrue(message.endswith(")\n"), repr(message))
                self.assertEqual(message.count("\n"), 1, repr(message))


if __name__ == "__main__":
    unittest.main()
