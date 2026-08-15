#!/usr/bin/env python3
"""Native stack configuration contract for the Blorp LSP process."""

from __future__ import annotations

import os
import pathlib
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
NATIVE_RUNTIME = (
    ROOT / "compiler/blorp/src/stage_12_lsp/lsp_native_runtime.c"
)
NATIVE_INCLUDE = ROOT / "compiler/blorp/src/stage_12_lsp"
FIBER_STACK_ENVIRONMENT_VARIABLE = "BLORP_FIBER_STACK_SIZE"
COMPILER_FIBER_STACK_MINIMUM = str(2 * 1024 * 1024)
PROCESS_TIMEOUT_SECONDS = 10

HARNESS_SOURCE = r"""
#include "lsp_native_runtime.h"

#include <stdio.h>
#include <stdlib.h>

static const char* environment_value(void) {
    const char* value = getenv("BLORP_FIBER_STACK_SIZE");
    return value ? value : "<unset>";
}

int main(void) {
    printf("before=%s\n", environment_value());
    printf("configured=%ld\n", blorp_compiler_require_fiber_stack_size());
    printf("after=%s\n", environment_value());
    return 0;
}
"""


class NativeRuntimeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.temp_dir = tempfile.TemporaryDirectory(prefix="blorp-lsp-native-runtime-")
        temp_path = pathlib.Path(cls.temp_dir.name)
        harness = temp_path / "native_runtime_harness.c"
        cls.executable = temp_path / "native_runtime_harness"
        harness.write_text(HARNESS_SOURCE, encoding="utf-8")

        result = subprocess.run(
            [
                os.environ.get("CC", "cc"),
                "-D_GNU_SOURCE",
                "-Wall",
                "-Wextra",
                "-Werror",
                "-I",
                str(NATIVE_INCLUDE),
                str(harness),
                str(NATIVE_RUNTIME),
                "-o",
                str(cls.executable),
            ],
            cwd=ROOT,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=False,
        )
        if result.returncode != 0:
            raise AssertionError(result.stderr)

    @classmethod
    def tearDownClass(cls) -> None:
        cls.temp_dir.cleanup()

    def run_harness(self, configured: str | None) -> dict[str, str]:
        environment = os.environ.copy()
        if configured is None:
            environment.pop(FIBER_STACK_ENVIRONMENT_VARIABLE, None)
        else:
            environment[FIBER_STACK_ENVIRONMENT_VARIABLE] = configured

        result = subprocess.run(
            [str(self.executable)],
            cwd=ROOT,
            env=environment,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=PROCESS_TIMEOUT_SECONDS,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return dict(line.split("=", 1) for line in result.stdout.splitlines())

    def assert_configured(self, original: str | None) -> None:
        values = self.run_harness(original)
        expected_before = original if original is not None else "<unset>"
        expected_after = (
            original
            if original is not None and original.isdigit()
            and int(original) >= int(COMPILER_FIBER_STACK_MINIMUM)
            else COMPILER_FIBER_STACK_MINIMUM
        )
        self.assertEqual(
            values,
            {
                "before": expected_before,
                "configured": "1",
                "after": expected_after,
            },
        )

    def test_absent_environment_receives_lsp_minimum(self) -> None:
        self.assert_configured(None)

    def test_undersized_environment_is_raised(self) -> None:
        self.assert_configured(str(128 * 1024))

    def test_malformed_environment_is_replaced(self) -> None:
        self.assert_configured("not-a-size")

    def test_larger_environment_is_preserved(self) -> None:
        self.assert_configured(str(4 * 1024 * 1024))


if __name__ == "__main__":
    unittest.main()
