#!/usr/bin/env python3
"""Contract test for the runtime allocation oracle (allocation-contract
roadmap milestone 6): every backing allocator path the oracle claims to
count actually moves its counter when exercised, and every counter stays
at zero when its path is never touched. Follows
test_runtime_allocator_stats.py's small-C-harness-under-BLORP_ALLOCATOR_STATS
model.
"""

from __future__ import annotations

import os
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]


class RuntimeAllocOracleTests(unittest.TestCase):
    def _compile_and_run(self, source: str) -> subprocess.CompletedProcess:
        with tempfile.TemporaryDirectory() as temp_name:
            executable = Path(temp_name) / "alloc-oracle"
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
            return subprocess.run(
                [str(executable)],
                cwd=ROOT,
                env=environment,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                check=False,
            )

    def test_every_oracle_counter_moves_on_its_own_path(self) -> None:
        source = textwrap.dedent(
            """\
            #define MINICORO_IMPL
            #include "minicoro.h"
            #include "runtime.c"

            #define CHECK_MOVED(before, after, field_name, code) \\
                do { \\
                    long delta = (after).field_name - (before).field_name; \\
                    if (delta <= 0) { \\
                        fprintf(stderr, "expected %s to move, delta=%ld\\n", #field_name, delta); \\
                        return (code); \\
                    } \\
                } while (0)

            int main(void) {
                if (!getenv("BLORP_ALLOCATOR_STATS")) return 90;

                blorp_MemStats baseline = blorp_get_mem_stats();
                if (baseline.oracle_stats_active != 1) return 91;

                // 1. Managed allocation: total_allocations/total_releases.
                blorp_MemStats before_managed = blorp_get_mem_stats();
                blorp_Object* obj = blorp_alloc(sizeof(blorp_Object));
                blorp_MemStats after_managed_alloc = blorp_get_mem_stats();
                CHECK_MOVED(before_managed, after_managed_alloc, total_allocations, 2);
                blorp_release(obj);
                blorp_MemStats after_managed_release = blorp_get_mem_stats();
                CHECK_MOVED(after_managed_alloc, after_managed_release, total_releases, 3);

                // 2. Pool slab refill: exhaust the free list for the 32-byte
                // class (BLORP_POOL_REFILL_COUNT=64 objects per slab) so a
                // second refill is forced.
                blorp_MemStats before_pool = blorp_get_mem_stats();
                for (int i = 0; i < 200; i++) {
                    blorp_alloc(32);
                }
                blorp_MemStats after_pool = blorp_get_mem_stats();
                CHECK_MOVED(before_pool, after_pool, backing_pool_refill_events, 4);

                // 3. Backing libc malloc: a request larger than every pool
                // class (max class is 256 bytes) falls back to a direct malloc.
                blorp_MemStats before_libc = blorp_get_mem_stats();
                blorp_alloc(100000);
                blorp_MemStats after_libc = blorp_get_mem_stats();
                CHECK_MOVED(before_libc, after_libc, backing_libc_malloc_events, 5);

                // 4. Raw buffer malloc/calloc/realloc via the checked wrappers
                // every list/dict/set/I/O raw buffer in the runtime uses.
                blorp_MemStats before_raw = blorp_get_mem_stats();
                void* raw_m = blorp_malloc_checked(64);
                blorp_MemStats after_raw_malloc = blorp_get_mem_stats();
                CHECK_MOVED(before_raw, after_raw_malloc, raw_buffer_malloc_events, 6);

                void* raw_r = blorp_realloc_checked(raw_m, 128);
                blorp_MemStats after_raw_realloc = blorp_get_mem_stats();
                CHECK_MOVED(after_raw_malloc, after_raw_realloc, raw_buffer_realloc_events, 7);
                free(raw_r);

                void* raw_c = blorp_calloc_checked(4, 16);
                blorp_MemStats after_raw_calloc = blorp_get_mem_stats();
                CHECK_MOVED(after_raw_realloc, after_raw_calloc, raw_buffer_calloc_events, 8);
                free(raw_c);

                // 5. SIMD-aligned buffer.
                blorp_MemStats before_aligned = blorp_get_mem_stats();
                void* aligned = blorp_simd_alloc(64);
                blorp_MemStats after_aligned = blorp_get_mem_stats();
                CHECK_MOVED(before_aligned, after_aligned, raw_buffer_aligned_events, 9);
                free(aligned);

                // 6. Cleanup scratch: the generated iterative union
                // destructor's work-stack growth helper.
                blorp_MemStats before_scratch = blorp_get_mem_stats();
                void* scratch = blorp_union_destroy_stack_grow(NULL, sizeof(void*) * 64);
                blorp_MemStats after_scratch = blorp_get_mem_stats();
                CHECK_MOVED(before_scratch, after_scratch, cleanup_scratch_events, 10);
                free(scratch);

                // 7. Fiber stack mmap (first request, so the reuse pool is
                // necessarily empty).
                blorp_MemStats before_fiber = blorp_get_mem_stats();
                void* stack = blorp_fiber_stack_alloc(65536, NULL);
                blorp_MemStats after_fiber = blorp_get_mem_stats();
                CHECK_MOVED(before_fiber, after_fiber, fiber_mmap_events, 11);
                if (stack) {
                    size_t aligned_size = __blorp_page_align(65536);
                    munmap(stack, aligned_size + __blorp_page_size);
                }

                return 0;
            }
            """
        )
        completed = self._compile_and_run(source)
        self.assertEqual(completed.returncode, 0, completed.stderr)

    def test_idle_process_reports_zero_oracle_counters(self) -> None:
        source = textwrap.dedent(
            """\
            #define MINICORO_IMPL
            #include "minicoro.h"
            #include "runtime.c"

            int main(void) {
                blorp_MemStats before = blorp_get_mem_stats();
                blorp_MemStats after = blorp_get_mem_stats();
                if (before.oracle_stats_active != 1) return 2;
                if (after.oracle_stats_active != 1) return 3;
                if (after.total_allocations != before.total_allocations) return 4;
                if (after.backing_pool_refill_events != before.backing_pool_refill_events) return 5;
                if (after.backing_libc_malloc_events != before.backing_libc_malloc_events) return 6;
                if (after.raw_buffer_malloc_events != before.raw_buffer_malloc_events) return 7;
                if (after.raw_buffer_calloc_events != before.raw_buffer_calloc_events) return 8;
                if (after.raw_buffer_realloc_events != before.raw_buffer_realloc_events) return 9;
                if (after.raw_buffer_aligned_events != before.raw_buffer_aligned_events) return 10;
                if (after.cleanup_scratch_events != before.cleanup_scratch_events) return 11;
                if (after.fiber_mmap_events != before.fiber_mmap_events) return 12;
                return 0;
            }
            """
        )
        completed = self._compile_and_run(source)
        self.assertEqual(completed.returncode, 0, completed.stderr)

    def test_disabled_gate_reports_inactive_not_zero(self) -> None:
        source = textwrap.dedent(
            """\
            #define MINICORO_IMPL
            #include "minicoro.h"
            #include "runtime.c"

            int main(void) {
                blorp_MemStats stats = blorp_get_mem_stats();
                // Without BLORP_ALLOCATOR_STATS, oracle_stats_active must be
                // 0 (a disabled gate), never silently read as "0 events".
                if (stats.oracle_stats_active != 0) return 2;
                return 0;
            }
            """
        )
        with tempfile.TemporaryDirectory() as temp_name:
            executable = Path(temp_name) / "alloc-oracle-disabled"
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
            environment.pop("BLORP_ALLOCATOR_STATS", None)
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
