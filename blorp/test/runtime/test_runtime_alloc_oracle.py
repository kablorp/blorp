#!/usr/bin/env python3
"""Contract test for the runtime allocation oracle (allocation-contract
roadmap milestone 6): every backing allocator path the oracle claims to
count actually moves its counter when exercised, and every counter stays
at zero when its path is never touched. Follows
test_runtime_allocator_stats.py's small-C-harness-under-BLORP_MEMORY_STATS
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
                    "-DBLORP_MEMORY_DIAGNOSTICS=1",
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
            environment["BLORP_MEMORY_STATS"] = "1"
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
            #define _GNU_SOURCE
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
                if (!getenv("BLORP_MEMORY_STATS")) return 90;

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

                // 2. Every managed object requests backing directly from libc.
                blorp_MemStats before_managed_backing = blorp_get_mem_stats();
                void* small = blorp_alloc(32);
                blorp_MemStats after_managed_backing = blorp_get_mem_stats();
                CHECK_MOVED(before_managed_backing, after_managed_backing,
                            backing_libc_malloc_events, 4);
                blorp_release(small);

                // 3. Oversized managed objects use the same direct path.
                blorp_MemStats before_libc = blorp_get_mem_stats();
                void* large = blorp_alloc(100000);
                blorp_MemStats after_libc = blorp_get_mem_stats();
                CHECK_MOVED(before_libc, after_libc, backing_libc_malloc_events, 5);
                blorp_release(large);

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
                // The returned pointer sits one page above the mapping base
                // (the guard page is below it); release through the
                // runtime's own inverse rather than recomputing the base.
                if (stack) blorp_fiber_stack_unmap(stack, 65536);

                return 0;
            }
            """
        )
        completed = self._compile_and_run(source)
        self.assertEqual(completed.returncode, 0, completed.stderr)

    def test_dict_table_takes_one_raw_buffer_per_capacity(self) -> None:
        # A Dict's per-slot arrays share one backing buffer, and a shared
        # dict that an insert grows is copied straight into the grown table
        # instead of being copied and then rehashed.
        source = textwrap.dedent(
            """\
            #define _GNU_SOURCE
            #define MINICORO_IMPL
            #include "minicoro.h"
            #include "runtime.c"

            static long raw_events(blorp_MemStats stats) {
                return stats.raw_buffer_malloc_events + stats.raw_buffer_calloc_events
                    + stats.raw_buffer_realloc_events + stats.raw_buffer_aligned_events;
            }

            #define EXPECT_RAW(before, after, expected, code) \\
                do { \\
                    long delta = raw_events(after) - raw_events(before); \\
                    if (delta != (expected)) { \\
                        fprintf(stderr, "check %d: expected %d raw buffers, got %ld\\n", \\
                                (code), (expected), delta); \\
                        return (code); \\
                    } \\
                } while (0)

            #define KEY(v) ((void*)(intptr_t)(v))

            int main(void) {
                if (!getenv("BLORP_MEMORY_STATS")) return 90;

                blorp_MemStats before_new = blorp_get_mem_stats();
                blorp_Dict* dict = blorp_dict_new();
                blorp_MemStats after_new = blorp_get_mem_stats();
                EXPECT_RAW(before_new, after_new, 1, 2);

                // Fill to one below the growth threshold: no new buffers.
                long threshold = dict->grow_at;
                for (long key = 0; key < threshold - 1; key++) {
                    dict = blorp_dict_insert(dict, KEY(key), KEY(key));
                }
                blorp_MemStats after_fill = blorp_get_mem_stats();
                EXPECT_RAW(after_new, after_fill, 0, 3);

                // A shared dict grown by an insert takes exactly one buffer.
                blorp_Dict* shared = dict;
                blorp_retain(shared);
                long old_capacity = dict->capacity;
                dict = blorp_dict_insert(dict, KEY(1000), KEY(1000));
                blorp_MemStats after_shared_grow = blorp_get_mem_stats();
                EXPECT_RAW(after_fill, after_shared_grow, 1, 4);
                if (dict->capacity != old_capacity * 2) return 5;
                if (shared->capacity != old_capacity) return 6;

                // A unique dict grows with one buffer.
                shared = blorp_dict_insert(shared, KEY(2000), KEY(2000));
                blorp_MemStats after_unique_grow = blorp_get_mem_stats();
                EXPECT_RAW(after_shared_grow, after_unique_grow, 1, 7);
                if (shared->capacity != old_capacity * 2) return 8;

                // Copy of a shared dict on remove: one buffer.
                blorp_Dict* other = shared;
                blorp_retain(other);
                shared = blorp_dict_remove(shared, KEY(0));
                blorp_MemStats after_copy = blorp_get_mem_stats();
                EXPECT_RAW(after_unique_grow, after_copy, 1, 9);

                // Resize and reuse at a smaller capacity.
                blorp_dict_resize_to(shared, shared->capacity * 2);
                blorp_MemStats after_resize = blorp_get_mem_stats();
                EXPECT_RAW(after_copy, after_resize, 1, 10);
                shared = blorp_dict_reuse_alloc(shared, 16);
                blorp_MemStats after_reuse = blorp_get_mem_stats();
                EXPECT_RAW(after_resize, after_reuse, 0, 11);

                blorp_release(dict);
                blorp_release(shared);
                blorp_release(other);
                return 0;
            }
            """
        )
        completed = self._compile_and_run(source)
        self.assertEqual(completed.returncode, 0, completed.stderr)

    def test_set_noop_update_on_shared_set_allocates_nothing(self) -> None:
        # Adding a present key to, or removing a missing key from, a shared
        # set returns the original object without copying it: no managed
        # object, no raw buffer, and every holder keeps its reference count.
        # A real change to a shared set still copies.
        source = textwrap.dedent(
            """\
            #define _GNU_SOURCE
            #define MINICORO_IMPL
            #include "minicoro.h"
            #include "runtime.c"

            static long raw_events(blorp_MemStats stats) {
                return stats.raw_buffer_malloc_events + stats.raw_buffer_calloc_events
                    + stats.raw_buffer_realloc_events + stats.raw_buffer_aligned_events;
            }

            #define EXPECT_NO_ALLOCATION(before, after, code) \\
                do { \\
                    long raw = raw_events(after) - raw_events(before); \\
                    long managed = (after).total_allocations - (before).total_allocations; \\
                    if (raw != 0 || managed != 0) { \\
                        fprintf(stderr, "check %d: %ld raw buffers, %ld managed objects\\n", \\
                                (code), raw, managed); \\
                        return (code); \\
                    } \\
                } while (0)

            #define KEY(v) ((void*)(intptr_t)(v))

            static long refcount_of(void* obj) {
                return (long)atomic_load(&((blorp_Object*)obj)->refcount);
            }

            int main(void) {
                if (!getenv("BLORP_MEMORY_STATS")) return 90;

                blorp_Set* set = blorp_set_new();
                for (long key = 0; key < 20; key++) set = blorp_set_add(set, KEY(key));
                blorp_Set* other = set;
                blorp_retain(other);
                long shared_refcount = refcount_of(set);

                blorp_MemStats before_add = blorp_get_mem_stats();
                blorp_Set* added = blorp_set_add(set, KEY(7));
                blorp_MemStats after_add = blorp_get_mem_stats();
                EXPECT_NO_ALLOCATION(before_add, after_add, 2);
                if (added != other) return 3;
                if (refcount_of(other) != shared_refcount) return 4;
                if (added->size != 20) return 5;

                blorp_Set* removed = blorp_set_remove(added, KEY(1000));
                blorp_MemStats after_remove = blorp_get_mem_stats();
                EXPECT_NO_ALLOCATION(after_add, after_remove, 6);
                if (removed != other) return 7;
                if (refcount_of(other) != shared_refcount) return 8;
                if (removed->size != 20) return 9;

                // A real insert into the shared set still copies it and
                // leaves the other holder untouched.
                blorp_Set* grown = blorp_set_add(removed, KEY(1000));
                if (grown == other) return 10;
                if (grown->size != 21 || other->size != 20) return 11;
                if (refcount_of(other) != shared_refcount - 1) return 12;

                blorp_release(grown);
                blorp_release(other);

                // A NULL set is an empty set, as blorp_set_remove and
                // blorp_set_cow treat it: adding to it yields a one-element set.
                blorp_Set* from_null = blorp_set_add(NULL, KEY(5));
                if (!from_null || from_null->size != 1) return 13;
                if (!set_contains_internal(from_null, KEY(5))) return 14;
                blorp_release(from_null);
                return 0;
            }
            """
        )
        completed = self._compile_and_run(source)
        self.assertEqual(completed.returncode, 0, completed.stderr)

    def test_idle_process_reports_zero_oracle_counters(self) -> None:
        source = textwrap.dedent(
            """\
            #define _GNU_SOURCE
            #define MINICORO_IMPL
            #include "minicoro.h"
            #include "runtime.c"

            int main(void) {
                blorp_MemStats before = blorp_get_mem_stats();
                blorp_MemStats after = blorp_get_mem_stats();
                if (before.oracle_stats_active != 1) return 2;
                if (after.oracle_stats_active != 1) return 3;
                if (after.total_allocations != before.total_allocations) return 4;
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
            #define _GNU_SOURCE
            #define MINICORO_IMPL
            #include "minicoro.h"
            #include "runtime.c"

            int main(void) {
                blorp_MemStats stats = blorp_get_mem_stats();
                // Without BLORP_MEMORY_STATS, oracle_stats_active must be
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
                    "-DBLORP_MEMORY_DIAGNOSTICS=1",
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
            environment.pop("BLORP_MEMORY_STATS", None)
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
