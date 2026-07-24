#!/usr/bin/env python3
"""Contract test for lightweight runtime allocator statistics."""

from __future__ import annotations

import os
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent


class RuntimeAllocatorStatsTests(unittest.TestCase):
    def test_allocator_stats_do_not_enable_object_metadata(self) -> None:
        source = textwrap.dedent(
            """\
            #define MINICORO_IMPL
            #include "minicoro.h"
            #include "runtime.c"

            int main(void) {
                blorp_reset_mem_stats();
                blorp_MemStats* before = blorp_get_mem_stats();
                if (before->total_allocations != 0) return 2;
                if (before->total_releases != 0) return 3;
                if (before->current_objects != 0) return 4;
                if (before->bytes_allocated <= 0) return 5;
                long before_bytes = before->bytes_allocated;
                blorp_release(before);

                blorp_Object* object = blorp_alloc(sizeof(blorp_Object));
                blorp_MemStats* after_object_alloc = blorp_get_mem_stats();
                if (after_object_alloc->total_allocations != 0) return 6;
                if (after_object_alloc->total_releases != 0) return 7;
                if (after_object_alloc->current_objects != 0) return 8;
                blorp_release(after_object_alloc);
                blorp_release(object);

                const size_t allocation_size = 64 * 1024 * 1024;
                void* allocation = malloc(allocation_size);
                if (!allocation) return 9;
                memset(allocation, 0x5a, allocation_size);

                blorp_MemStats* during = blorp_get_mem_stats();
                long during_bytes = during->bytes_allocated;
                blorp_release(during);
                if (during_bytes - before_bytes < (long)(allocation_size / 2)) return 10;

                free(allocation);
                blorp_MemStats* after = blorp_get_mem_stats();
                long after_bytes = after->bytes_allocated;
                blorp_release(after);
                if (during_bytes - after_bytes < (long)(allocation_size / 2)) return 11;
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
                    f"-I{ROOT / 'compiler' / 'lib'}",
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


if __name__ == "__main__":
    unittest.main()
