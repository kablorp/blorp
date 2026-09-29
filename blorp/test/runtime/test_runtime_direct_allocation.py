#!/usr/bin/env python3
"""Native contract checks for directly malloc-owned managed objects."""

from __future__ import annotations

import os
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]


class RuntimeDirectAllocationTests(unittest.TestCase):
    def _compile_and_run(self, source: str, extra_env: dict) -> subprocess.CompletedProcess:
        with tempfile.TemporaryDirectory() as temp_name:
            executable = Path(temp_name) / "direct-allocation"
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
            environment.update(extra_env)
            return subprocess.run(
                [str(executable)],
                cwd=ROOT,
                env=environment,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                check=False,
            )

    def test_every_final_release_frees_its_exact_block(self) -> None:
        source = textwrap.dedent(
            """\
            #define _GNU_SOURCE
            #include <stdlib.h>
            static void* first_block;
            static void* second_block;
            static int object_frees;
            static void real_free(void* ptr) { free(ptr); }
            static void tracked_free(void* ptr) {
                if (ptr == first_block || ptr == second_block) object_frees++;
                real_free(ptr);
            }
            #define free tracked_free
            #define MINICORO_IMPL
            #include "minicoro.h"
            #include "runtime.c"

            int main(void) {
                void* first = blorp_alloc(32);
                void* second = blorp_alloc(32);
                first_block = first;
                second_block = second;
                blorp_MemStats allocated = blorp_get_mem_stats();
                if (allocated.backing_libc_malloc_events != 2) return 1;
                blorp_release(first);
                blorp_release(second);
                if (object_frees != 2) return 2;
                return 0;
            }
            """
        )
        completed = self._compile_and_run(source, {})
        self.assertEqual(completed.returncode, 0, completed.stderr)

    def test_final_release_after_producer_exit_frees_on_consumer(self) -> None:
        source = textwrap.dedent(
            """\
            #define _GNU_SOURCE
            #include <stdlib.h>
            #include <stdatomic.h>
            static void* target_block;
            static _Atomic int target_frees;
            static void real_free(void* ptr) { free(ptr); }
            static void tracked_free(void* ptr) {
                if (ptr == target_block)
                    atomic_fetch_add_explicit(&target_frees, 1, memory_order_relaxed);
                real_free(ptr);
            }
            #define free tracked_free
            #define MINICORO_IMPL
            #include "minicoro.h"
            #include "runtime.c"
            #include <pthread.h>

            static void* producer(void* unused) {
                (void)unused;
                return blorp_alloc(64);
            }
            static void* consumer(void* block) {
                blorp_release(block);
                return NULL;
            }

            int main(void) {
                pthread_t thread;
                void* block = NULL;
                if (pthread_create(&thread, NULL, producer, NULL) != 0) return 90;
                if (pthread_join(thread, &block) != 0) return 91;
                if (!block) return 1;
                target_block = block;
                if (pthread_create(&thread, NULL, consumer, block) != 0) return 92;
                if (pthread_join(thread, NULL) != 0) return 93;
                if (atomic_load_explicit(&target_frees, memory_order_relaxed) != 1)
                    return 2;
                return 0;
            }
            """
        )
        completed = self._compile_and_run(source, {})
        self.assertEqual(completed.returncode, 0, completed.stderr)

    def test_all_sizes_use_direct_header_and_malloc_backing(self) -> None:
        source = textwrap.dedent(
            """\
            #define _GNU_SOURCE
            #define MINICORO_IMPL
            #include "minicoro.h"
            #include "runtime.c"

            int main(void) {
                const size_t sizes[] =
                    {0, 1, sizeof(blorp_Object), 32, 64, 96, 128, 192, 256,
                     384, 512, 1024, 1025};
                const int count = sizeof(sizes) / sizeof(sizes[0]);
                blorp_MemStats before = blorp_get_mem_stats();
                for (int i = 0; i < count; i++) {
                    blorp_Object* object = blorp_alloc(sizes[i]);
                    if (object->alloc_class != BLORP_ALLOC_CLASS_DIRECT) return 1;
                    if (atomic_load_explicit(&object->refcount, memory_order_relaxed) != 1)
                        return 2;
                    blorp_release(object);
                }
                blorp_MemStats after = blorp_get_mem_stats();
                if (after.backing_libc_malloc_events -
                    before.backing_libc_malloc_events != count) return 3;
                return 0;
            }
            """
        )
        completed = self._compile_and_run(source, {})
        self.assertEqual(completed.returncode, 0, completed.stderr)


if __name__ == "__main__":
    unittest.main()
