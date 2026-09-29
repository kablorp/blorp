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
        BLORP_INSTALL_DESTRUCTOR(object, test_destructor);
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


# A generated-code body compiled once through runtime_decl.c, with no
# BLORP_MEMORY_DIAGNOSTICS define, then linked against each runtime mode.
# This is the shape of a stage-2 compiler built with --diagnostic-output, so
# the allocation-site macros must discover the mode from the linked runtime.
SPLIT_LINK_BODY = textwrap.dedent(
    """\
    int blorp_memory_diagnostics_mode(void);

    static int probe_destructor_calls;
    static void probe_destroy(void* object) {
        (void)object;
        probe_destructor_calls++;
    }

    static void* probe_new(void) {
        void* object = blorp_alloc(32);
        BLORP_TAG(object, "InlineHeaderProbe");
        BLORP_SET_DESTRUCTOR(object, probe_destroy);
        return object;
    }

    int main(void) {
        if ((int)blorp_runtime_memory_diagnostics != blorp_memory_diagnostics_mode())
            return 1;
        // The first allocation registers the site's destructor id; the second
        // takes the inline cached path.
        void* first = probe_new();
        void* second = probe_new();
        blorp_release(first);
        blorp_release(second);
        if (probe_destructor_calls != 2) return 2;
        // Deliberately leaked so a diagnostic runtime reports its tag.
        (void)probe_new();
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


    def _compile_split_link(self, directory: Path) -> dict[int, Path]:
        compiler = os.environ.get("CC", "cc")
        body_object = directory / "body.o"
        body = subprocess.run(
            [
                compiler, "-O2", "-w", "-include", str(RUNTIME / "runtime_decl.c"),
                "-x", "c", "-", "-c", "-o", str(body_object),
            ],
            cwd=ROOT, input=SPLIT_LINK_BODY, text=True, capture_output=True, check=False,
        )
        self.assertEqual(body.returncode, 0, body.stderr)
        binaries: dict[int, Path] = {}
        for mode in (0, 1):
            runtime_object = directory / f"runtime-{mode}.o"
            runtime = subprocess.run(
                [
                    compiler, "-O2", "-w", "-fwrapv", "-D_GNU_SOURCE", "-DMINICORO_IMPL",
                    f"-DBLORP_MEMORY_DIAGNOSTICS={mode}",
                    "-include", str(RUNTIME / "minicoro.h"),
                    "-c", str(RUNTIME / "runtime.c"), "-o", str(runtime_object),
                ],
                cwd=ROOT, text=True, capture_output=True, check=False,
            )
            self.assertEqual(runtime.returncode, 0, runtime.stderr)
            binary = directory / f"split-link-{mode}"
            link = subprocess.run(
                [
                    compiler, str(body_object), str(runtime_object),
                    "-lm", "-lpthread", "-o", str(binary),
                ],
                cwd=ROOT, text=True, capture_output=True, check=False,
            )
            self.assertEqual(link.returncode, 0, link.stderr)
            binaries[mode] = binary
        return binaries

    def test_split_link_body_tags_and_destroys_under_both_runtime_modes(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            binaries = self._compile_split_link(Path(directory))
            environment = dict(os.environ)
            for name in ("BLORP_ALLOCATOR_STATS", "BLORP_COMPILER_MEMORY_PROFILE"):
                environment.pop(name, None)

            environment.pop("BLORP_LEAK_CHECK", None)
            normal = subprocess.run(
                [str(binaries[0])], env=environment, capture_output=True, text=True
            )
            self.assertEqual(normal.returncode, 0, normal.stderr)
            self.assertNotIn("InlineHeaderProbe", normal.stderr)

            environment["BLORP_LEAK_CHECK"] = "1"
            diagnostic = subprocess.run(
                [str(binaries[1])], env=environment, capture_output=True, text=True
            )
            self.assertEqual(diagnostic.returncode, 0, diagnostic.stderr)
            self.assertIn("Leaked by type:", diagnostic.stderr)
            self.assertRegex(diagnostic.stderr, r"InlineHeaderProbe\s+1\s")


if __name__ == "__main__":
    unittest.main()
