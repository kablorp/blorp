#!/usr/bin/env python3
"""The compiler self-profiling code must not ship in user-program runtimes.

Only the compiler's own runtime object (`-DBLORP_COMPILER_RUNTIME_SOURCES=1`)
carries the typecheck, Core-lowering, and Perceus metrics. Every other runtime
object (user programs, tests, packages) must keep only the no-op entry points
that compiler sources declare as `foreign func`s, so programs that import
compiler modules still link.
"""

from __future__ import annotations

import os
import re
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
NATIVE_DIRECTORY = ROOT / "blorp" / "src" / "lib" / "runtime" / "native"
METRICS_ENTRY_POINT = re.compile(
    r"^\s*(?:long|void)\s+(blorp_(?:typecheck_[a-z_]*metric[a-z_]*"
    r"|core_lowering_[a-z_]+|perceus_engine_[a-z_]+)_c)\("
)
METRICS_ENVIRONMENT_VARIABLES = (
    b"BLORP_TYPECHECK_BODY_METRICS",
    b"BLORP_CORE_LOWERING_TYPE_METRICS",
    b"BLORP_PERCEUS_ENGINE_METRICS",
)
COMPILER_DEFINE = "-DBLORP_COMPILER_RUNTIME_SOURCES=1"


def declared_metrics_entry_points() -> set[str]:
    names = set()
    for line in (NATIVE_DIRECTORY / "runtime_decl.c").read_text().splitlines():
        match = METRICS_ENTRY_POINT.match(line)
        if match:
            names.add(match.group(1))
    return names


def defined_symbols(object_path: Path) -> set[str]:
    listing = subprocess.run(
        ["nm", "-g", "--defined-only", str(object_path)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        check=True,
    ).stdout
    # Mach-O prefixes C symbols with an underscore; ELF does not.
    return {line.split()[-1].lstrip("_") for line in listing.splitlines() if line.strip()}


class RuntimeCompilerOnlyMetricsTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls._temp = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls._temp.cleanup)

    def _compile_runtime(self, name: str, memory_diagnostics: int, compiler_runtime: bool) -> Path:
        output = Path(self._temp.name) / name
        arguments = [
            os.environ.get("CC", "cc"),
            "-O0",
            "-w",
            "-fwrapv",
            "-D_GNU_SOURCE",
            "-DMINICORO_IMPL",
            f"-DBLORP_MEMORY_DIAGNOSTICS={memory_diagnostics}",
            "-include",
            str(NATIVE_DIRECTORY / "minicoro.h"),
            "-c",
            str(NATIVE_DIRECTORY / "runtime.c"),
            "-o",
            str(output),
        ]
        if compiler_runtime:
            arguments.insert(2, COMPILER_DEFINE)
        completed = subprocess.run(
            arguments,
            cwd=ROOT,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=False,
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        return output

    def test_declared_entry_points_are_discovered(self) -> None:
        # Guards the discovery regex: an empty set would make every check
        # below vacuous.
        self.assertGreaterEqual(len(declared_metrics_entry_points()), 28)

    def test_user_runtime_keeps_only_noop_entry_points_in_both_modes(self) -> None:
        declared = declared_metrics_entry_points()
        for memory_diagnostics in (0, 1):
            with self.subTest(memory_diagnostics=memory_diagnostics):
                object_path = self._compile_runtime(
                    f"user-{memory_diagnostics}.o", memory_diagnostics, compiler_runtime=False
                )
                symbols = defined_symbols(object_path)
                self.assertLessEqual(declared, symbols)
                metrics_symbols = {
                    name
                    for name in symbols
                    if re.search(r"metric|perceus_engine|core_lowering", name)
                }
                self.assertEqual(metrics_symbols, declared)
                contents = object_path.read_bytes()
                for variable in METRICS_ENVIRONMENT_VARIABLES:
                    self.assertNotIn(variable, contents)

    def test_compiler_runtime_still_carries_the_metrics(self) -> None:
        declared = declared_metrics_entry_points()
        for memory_diagnostics in (0, 1):
            with self.subTest(memory_diagnostics=memory_diagnostics):
                object_path = self._compile_runtime(
                    f"compiler-{memory_diagnostics}.o", memory_diagnostics, compiler_runtime=True
                )
                self.assertLessEqual(declared, defined_symbols(object_path))
                contents = object_path.read_bytes()
                for variable in METRICS_ENVIRONMENT_VARIABLES:
                    self.assertIn(variable, contents)
                self.assertIn(b"BLORP_TYPECHECK_BODY_METRICS schema=1", contents)


if __name__ == "__main__":
    unittest.main()
