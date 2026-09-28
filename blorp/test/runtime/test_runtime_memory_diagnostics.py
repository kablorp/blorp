#!/usr/bin/env python3
"""Native checks for compiled memory-diagnostics capability and fail-closed use."""

from __future__ import annotations

import os
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
RUNTIME = ROOT / "blorp" / "src" / "lib" / "runtime" / "native"
SOURCE = textwrap.dedent(
    """\
    #define _GNU_SOURCE
    #include <stdlib.h>
    static void* tracked_object;
    static int tracked_object_frees;
    static void real_free(void* pointer) { free(pointer); }
    static void tracked_free(void* pointer) {
        if (pointer == tracked_object) tracked_object_frees++;
        real_free(pointer);
    }
    #define free tracked_free
    #define MINICORO_IMPL
    #include "minicoro.h"
    #include "runtime.c"

    static int destructor_calls;
    static void test_destructor(void* object) {
        if (object == tracked_object) destructor_calls++;
    }

    int main(void) {
        if (blorp_memory_diagnostics_mode() != BLORP_MEMORY_DIAGNOSTICS) return 1;
        blorp_MemStats before = blorp_get_mem_stats();
        void* object = blorp_alloc(64);
        tracked_object = object;
        static _Atomic uint32_t destructor_id;
        blorp_set_destructor_id(
            object, blorp_get_destructor_id(&destructor_id, test_destructor));
        blorp_MemStats after = blorp_get_mem_stats();
        blorp_retain(object);
        blorp_release(object);
        if (tracked_object_frees != 0 || destructor_calls != 0) return 8;
        blorp_release(object);
        if (tracked_object_frees != 1 || destructor_calls != 1) return 9;
        if (before.memory_stats_active != BLORP_MEMORY_DIAGNOSTICS) return 2;
        if (after.memory_stats_active != BLORP_MEMORY_DIAGNOSTICS) return 3;
    #if BLORP_MEMORY_DIAGNOSTICS
        if (after.total_allocations - before.total_allocations != 1) return 4;
        if (after.oracle_stats_active != 1) return 5;
        if (after.backing_libc_malloc_events - before.backing_libc_malloc_events != 1)
            return 6;
    #else
        if (after.oracle_stats_active != 0) return 7;
    #endif
        return 0;
    }
    """
)


class RuntimeMemoryDiagnosticsTests(unittest.TestCase):
    def _compile(self, mode: int, output: Path) -> None:
        result = subprocess.run(
            [
                os.environ.get("CC", "cc"),
                "-O2",
                "-w",
                f"-DBLORP_MEMORY_DIAGNOSTICS={mode}",
                f"-I{RUNTIME}",
                "-x",
                "c",
                "-",
                "-lm",
                "-lpthread",
                "-o",
                str(output),
            ],
            cwd=ROOT,
            input=SOURCE,
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_normal_mode_returns_inactive_snapshot_and_rejects_requested_stats(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            binary = Path(directory) / "normal"
            self._compile(0, binary)
            environment = dict(os.environ)
            for name in (
                "BLORP_ALLOCATOR_STATS",
                "BLORP_COMPILER_MEMORY_PROFILE",
                "BLORP_LEAK_CHECK",
            ):
                environment.pop(name, None)
            normal = subprocess.run([str(binary)], env=environment, capture_output=True, text=True)
            self.assertEqual(normal.returncode, 0, normal.stderr)
            for request in ("BLORP_ALLOCATOR_STATS", "BLORP_LEAK_CHECK"):
                environment[request] = "1"
                rejected = subprocess.run([str(binary)], env=environment, capture_output=True, text=True)
                self.assertEqual(rejected.returncode, 2)
                self.assertIn(
                    f"{request} requires a runtime built with BLORP_MEMORY_DIAGNOSTICS=1",
                    rejected.stderr,
                )
                environment.pop(request)

    def test_diagnostic_mode_counts_managed_and_oracle_events(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            binary = Path(directory) / "diagnostic"
            self._compile(1, binary)
            environment = dict(os.environ)
            environment.pop("BLORP_LEAK_CHECK", None)
            environment["BLORP_ALLOCATOR_STATS"] = "1"
            measured = subprocess.run([str(binary)], env=environment, capture_output=True, text=True)
            self.assertEqual(measured.returncode, 0, measured.stderr)


if __name__ == "__main__":
    unittest.main()
