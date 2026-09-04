#!/usr/bin/env python3
"""Contract test for lightweight runtime allocator statistics."""

from __future__ import annotations

import os
import re
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]


class RuntimeAllocatorStatsTests(unittest.TestCase):
    def test_optimized_allocation_does_not_require_frame_pointers(self) -> None:
        source = textwrap.dedent(
            """\
            #define MINICORO_IMPL
            #include "minicoro.h"
            #include "runtime.c"

            int main(void) {
                blorp_List* values = blorp_list_new(1);
                blorp_release(values);
                return 0;
            }
            """
        )
        with tempfile.TemporaryDirectory() as temp_name:
            executable = Path(temp_name) / "optimized-allocation"
            compiled = subprocess.run(
                [
                    os.environ.get("CC", "cc"),
                    "-O2",
                    "-fomit-frame-pointer",
                    "-w",
                    f"-I{ROOT / 'blorp' / 'src' / 'lib' / 'runtime' / 'native'}",
                    "-x",
                    "c",
                    "-",
                    "-lm",
                    "-lpthread",
                    "-o",
                    str(executable),
                ],
                cwd=ROOT,
                input=source,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
            self.assertEqual(compiled.returncode, 0, compiled.stderr)

            for setting in (None, "BLORP_TRACE_ALLOCS", "BLORP_LEAK_CHECK"):
                environment = dict(os.environ)
                if setting is not None:
                    environment[setting] = "1"
                completed = subprocess.run(
                    [str(executable)],
                    cwd=ROOT,
                    env=environment,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    text=True,
                    check=False,
                )
                self.assertEqual(
                    completed.returncode,
                    0,
                    f"{setting or 'default'}: {completed.stderr}",
                )
                if setting == "BLORP_TRACE_ALLOCS":
                    self.assertRegex(
                        completed.stderr,
                        r"=== BLORP ALLOCATION TRACE \([1-9][0-9]* total\) ===",
                    )
                elif setting == "BLORP_LEAK_CHECK":
                    leak_summary = re.search(
                        r"blorp: leak check: ([0-9]+) allocs, "
                        r"([0-9]+) releases, 0 leaked, 0 bytes",
                        completed.stderr,
                    )
                    self.assertIsNotNone(leak_summary, completed.stderr)
                    assert leak_summary is not None
                    allocations, releases = leak_summary.groups()
                    self.assertEqual(allocations, releases)

    def test_allocator_stats_do_not_enable_object_metadata(self) -> None:
        source = textwrap.dedent(
            """\
            #define MINICORO_IMPL
            #include "minicoro.h"
            #include "runtime.c"

            int main(void) {
                blorp_MemStats before = blorp_get_mem_stats();
                if (before.total_allocations != 0) return 2;
                if (before.total_releases != 0) return 3;
                if (before.current_objects != 0) return 4;
                // A zero baseline is valid now that the stats snapshot itself
                // is returned by value and performs no allocation.
                if (before.bytes_allocated < 0) return 5;
                long before_bytes = before.bytes_allocated;

                blorp_Object* object = blorp_alloc(sizeof(blorp_Object));
                blorp_MemStats after_object_alloc = blorp_get_mem_stats();
                if (after_object_alloc.total_allocations != 1) return 6;
                if (after_object_alloc.total_releases != 0) return 7;
                if (after_object_alloc.current_objects != 1) return 8;
                blorp_release(object);

                blorp_MemStats after_object_release = blorp_get_mem_stats();
                if (after_object_release.total_allocations != 1) return 9;
                if (after_object_release.total_releases != 1) return 10;
                if (after_object_release.current_objects != 0) return 11;

                for (size_t slot = 0; slot < BLORP_ALLOC_META_SLOTS; slot++) {
                    if (__alloc_meta_table[slot] != NULL) return 12;
                }

                const size_t allocation_size = 64 * 1024 * 1024;
                void* allocation = malloc(allocation_size);
                if (!allocation) return 13;
                memset(allocation, 0x5a, allocation_size);

                blorp_MemStats during = blorp_get_mem_stats();
                long during_bytes = during.bytes_allocated;
                if (during_bytes - before_bytes < (long)(allocation_size / 2)) return 14;

                free(allocation);
                blorp_MemStats after = blorp_get_mem_stats();
                long after_bytes = after.bytes_allocated;
                if (during_bytes - after_bytes < (long)(allocation_size / 2)) return 15;
                return 0;
            }
            """
        )
        with tempfile.TemporaryDirectory() as temp_name:
            executable = Path(temp_name) / "allocator-stats"
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
                    str(executable),
                ],
                cwd=ROOT,
                input=source,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
            self.assertEqual(compiled.returncode, 0, compiled.stderr)

            environment = dict(os.environ)
            environment["BLORP_ALLOCATOR_STATS"] = "1"
            completed = subprocess.run(
                [str(executable)],
                cwd=ROOT,
                env=environment,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                check=False,
            )

        self.assertEqual(completed.returncode, 0, completed.stderr)

    def test_reset_starts_an_exact_metadata_tracked_epoch(self) -> None:
        source = textwrap.dedent(
            """\
            #define MINICORO_IMPL
            #include "minicoro.h"
            #include "runtime.c"

            static bool has_allocation_metadata(blorp_Object* object) {
                pthread_mutex_lock(&__alloc_meta_mutex);
                bool found = __alloc_meta_find_locked(object) != NULL;
                pthread_mutex_unlock(&__alloc_meta_mutex);
                return found;
            }

            int main(void) {
                blorp_Object* before_epoch = blorp_alloc(sizeof(blorp_Object));
                if (has_allocation_metadata(before_epoch)) return 2;

                blorp_reset_mem_stats();

                blorp_Object* measured = blorp_alloc(sizeof(blorp_Object));
                if (!has_allocation_metadata(measured)) return 3;

                blorp_MemStats live = blorp_get_mem_stats();
                if (live.total_allocations != 1) return 4;
                if (live.total_releases != 0) return 5;
                if (live.current_objects != 1) return 6;

                blorp_release(before_epoch);
                blorp_MemStats after_old_release = blorp_get_mem_stats();
                if (after_old_release.total_allocations != 1) return 7;
                if (after_old_release.total_releases != 0) return 8;
                if (after_old_release.current_objects != 1) return 9;

                blorp_release(measured);
                blorp_MemStats complete = blorp_get_mem_stats();
                if (complete.total_allocations != 1) return 10;
                if (complete.total_releases != 1) return 11;
                if (complete.current_objects != 0) return 12;
                return 0;
            }
            """
        )
        with tempfile.TemporaryDirectory() as temp_name:
            executable = Path(temp_name) / "allocator-stats-reset"
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
                    str(executable),
                ],
                cwd=ROOT,
                input=source,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
            self.assertEqual(compiled.returncode, 0, compiled.stderr)

            environment = dict(os.environ)
            environment["BLORP_ALLOCATOR_STATS"] = "1"
            completed = subprocess.run(
                [str(executable)],
                cwd=ROOT,
                env=environment,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                check=False,
            )

        self.assertEqual(completed.returncode, 0, completed.stderr)

    def test_compiler_memory_checkpoints_report_process_and_managed_memory(self) -> None:
        source = textwrap.dedent(
            """\
            #define MINICORO_IMPL
            #include "minicoro.h"
            #include "runtime.c"

            int main(void) {
                blorp_compiler_memory_checkpoint_c("start");
                blorp_List* values = blorp_list_new(1);
                blorp_compiler_memory_checkpoint_c("list_live");
                blorp_release(values);
                blorp_compiler_memory_checkpoint_c("list_released");
                return 0;
            }
            """
        )
        with tempfile.TemporaryDirectory() as temp_name:
            executable = Path(temp_name) / "compiler-memory-checkpoint"
            compiled = subprocess.run(
                [
                    os.environ.get("CC", "cc"),
                    "-O2",
                    "-w",
                    f"-I{ROOT / 'blorp' / 'src' / 'lib' / 'runtime' / 'native'}",
                    "-x",
                    "c",
                    "-",
                    "-lm",
                    "-lpthread",
                    "-o",
                    str(executable),
                ],
                cwd=ROOT,
                input=source,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
            self.assertEqual(compiled.returncode, 0, compiled.stderr)

            environment = dict(os.environ)
            environment["BLORP_COMPILER_MEMORY_PROFILE"] = "1"
            completed = subprocess.run(
                [str(executable)],
                cwd=ROOT,
                env=environment,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                check=False,
            )

        self.assertEqual(completed.returncode, 0, completed.stderr)
        lines = [
            line
            for line in completed.stderr.splitlines()
            if line.startswith("BLORP_COMPILER_MEMORY_CHECKPOINT ")
        ]
        self.assertEqual(len(lines), 3, completed.stderr)
        parsed = []
        for line in lines:
            fields = dict(item.split("=", 1) for item in line.split()[1:])
            self.assertEqual(fields["schema"], "1")
            for name in (
                "timestamp_microseconds",
                "total_allocations",
                "total_releases",
                "current_objects",
                "allocator_bytes",
                "rss_bytes",
                "peak_rss_bytes",
            ):
                self.assertGreaterEqual(int(fields[name]), 0, line)
            parsed.append(fields)

        self.assertEqual([fields["phase"] for fields in parsed], [
            "start",
            "list_live",
            "list_released",
        ])
        starting_objects = int(parsed[0]["current_objects"])
        starting_allocations = int(parsed[0]["total_allocations"])
        starting_releases = int(parsed[0]["total_releases"])
        self.assertEqual(int(parsed[1]["current_objects"]), starting_objects + 1)
        self.assertEqual(int(parsed[2]["current_objects"]), starting_objects)
        self.assertEqual(
            int(parsed[1]["total_allocations"]), starting_allocations + 1
        )
        self.assertEqual(int(parsed[2]["total_releases"]), starting_releases + 1)


if __name__ == "__main__":
    unittest.main()
