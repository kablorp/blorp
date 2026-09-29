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
    def test_first_append_to_shared_empty_list_starts_with_four_slots(self) -> None:
        source = textwrap.dedent(
            """\
            #define MINICORO_IMPL
            #include "minicoro.h"
            #include "runtime.c"

            static struct {
                blorp_Object header;
                long len;
                long capacity;
                void (*elem_release)(void*);
                int16_t elem_size;
                uint8_t storage_mode;
                char pad[5];
                void* data[1];
            } canonical_empty = {
                { BLORP_IMMORTAL_REFCOUNT, BLORP_ALLOC_CLASS_DIRECT, 0 },
                0, 1, NULL, sizeof(void*), BLORP_LIST_STORAGE_POINTER, { 0 }, { NULL }
            };

            int main(void) {
                blorp_List* empty = (blorp_List*)&canonical_empty;
                blorp_List* values = blorp_list_append(empty, (void*)1);
                if (values == empty || values->len != 1 || values->capacity != 4) return 1;
                if (empty->len != 0 || empty->capacity != 1) return 2;
                for (long item = 2; item <= 4; item++) {
                    blorp_List* previous = values;
                    values = blorp_list_append(values, (void*)item);
                    if (values != previous || values->capacity != 4) return 3;
                }
                blorp_release(values);
                blorp_release(empty);

                blorp_List* empty_inline = blorp_list_new_inline(1, sizeof(long));
                blorp_retain(empty_inline);
                blorp_List* inline_values = blorp_list_append_owned(empty_inline, (void*)1);
                if (inline_values == empty_inline || inline_values->len != 1 ||
                    inline_values->capacity != 4 ||
                    inline_values->storage_mode != BLORP_LIST_STORAGE_INLINE) return 4;
                if (empty_inline->len != 0) return 5;
                blorp_release(inline_values);
                blorp_release(empty_inline);

                blorp_List* empty_managed = blorp_list_new(1);
                blorp_list_init_elem_release(empty_managed, blorp_elem_release_fn);
                blorp_retain(empty_managed);
                blorp_Object* owned_element = blorp_alloc(sizeof(blorp_Object));
                blorp_List* managed_values = blorp_list_append_owned(empty_managed, owned_element);
                if (managed_values->capacity != 4 ||
                    managed_values->elem_release != blorp_elem_release_fn ||
                    managed_values->data[0] != owned_element ||
                    empty_managed->len != 0) return 6;
                blorp_release(managed_values);
                blorp_release(empty_managed);
                return 0;
            }
            """
        )
        with tempfile.TemporaryDirectory() as temp_name:
            executable = Path(temp_name) / "first-list-append"
            compiled = subprocess.run(
                [
                    os.environ.get("CC", "cc"),
                    "-O2",
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
            completed = subprocess.run(
                [str(executable)],
                cwd=ROOT,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                check=False,
            )
            self.assertEqual(completed.returncode, 0, completed.stderr)

    def test_unique_list_growth_moves_elements_and_shared_growth_retains(self) -> None:
        # Growing a uniquely owned list must move element ownership into the
        # larger allocation: no element retain on copy and no element release
        # when the old allocation dies. Growing a shared list is a real COW
        # copy: every element gains an owner and the original keeps its own.
        # The counting release hook observes the element releases that the old
        # copy-then-release growth path performed.
        source = textwrap.dedent(
            """\
            #define MINICORO_IMPL
            #include "minicoro.h"
            #include "runtime.c"

            enum { ELEMENT_COUNT = 40 };
            static long element_release_calls;

            static void counting_element_release(void* element) {
                element_release_calls++;
                blorp_release(element);
            }

            static long element_refcount(void* element) {
                return atomic_load(&((blorp_Object*)element)->refcount);
            }

            typedef blorp_List* (*grow_one)(blorp_List*, blorp_Object*);

            static blorp_List* grow_by_ensure_capacity(blorp_List* list, blorp_Object* element) {
                list = blorp_list_ensure_capacity(list, list->len + 1);
                blorp_list_store_raw(list, list->len++, element);
                return list;
            }

            static blorp_List* grow_by_append(blorp_List* list, blorp_Object* element) {
                list = blorp_list_append(list, element);
                blorp_release(element);
                return list;
            }

            static blorp_List* grow_by_append_owned(blorp_List* list, blorp_Object* element) {
                return blorp_list_append_owned(list, element);
            }

            static int check_unique_growth(grow_one grow, int failure_base) {
                blorp_Object* elements[ELEMENT_COUNT];
                blorp_List* values = blorp_list_new(1);
                blorp_list_init_elem_release(values, counting_element_release);
                element_release_calls = 0;
                for (long index = 0; index < ELEMENT_COUNT; index++) {
                    elements[index] = blorp_alloc(sizeof(blorp_Object));
                    values = grow(values, elements[index]);
                }
                if (values->len != ELEMENT_COUNT || values->capacity < ELEMENT_COUNT) return failure_base + 1;
                if (values->elem_release != counting_element_release) return failure_base + 2;
                if (element_release_calls != 0) return failure_base + 3;
                for (long index = 0; index < ELEMENT_COUNT; index++) {
                    if (values->data[index] != elements[index]) return failure_base + 4;
                    if (element_refcount(elements[index]) != 1) return failure_base + 5;
                }
                blorp_release(values);
                if (element_release_calls != ELEMENT_COUNT) return failure_base + 6;
                return 0;
            }

            static int check_shared_growth(void) {
                blorp_Object* elements[ELEMENT_COUNT];
                blorp_List* original = blorp_list_new(ELEMENT_COUNT);
                blorp_list_init_elem_release(original, counting_element_release);
                for (long index = 0; index < ELEMENT_COUNT; index++) {
                    elements[index] = blorp_alloc(sizeof(blorp_Object));
                    blorp_list_store_raw(original, original->len++, elements[index]);
                }
                element_release_calls = 0;
                blorp_retain(original);
                blorp_List* grown = blorp_list_ensure_capacity(original, ELEMENT_COUNT + 1);
                if (grown == original || !blorp_is_unique(original)) return 101;
                if (grown->len != ELEMENT_COUNT || grown->capacity <= ELEMENT_COUNT) return 102;
                if (element_release_calls != 0) return 103;
                for (long index = 0; index < ELEMENT_COUNT; index++) {
                    if (grown->data[index] != elements[index]) return 104;
                    if (original->data[index] != elements[index]) return 105;
                    if (element_refcount(elements[index]) != 2) return 106;
                }
                blorp_release(grown);
                if (element_release_calls != ELEMENT_COUNT) return 107;
                for (long index = 0; index < ELEMENT_COUNT; index++) {
                    if (element_refcount(elements[index]) != 1) return 108;
                }
                blorp_release(original);
                if (element_release_calls != 2 * ELEMENT_COUNT) return 109;
                return 0;
            }

            int main(void) {
                int failure = check_unique_growth(grow_by_ensure_capacity, 10);
                if (failure) return failure;
                failure = check_unique_growth(grow_by_append, 20);
                if (failure) return failure;
                failure = check_unique_growth(grow_by_append_owned, 30);
                if (failure) return failure;
                return check_shared_growth();
            }
            """
        )
        with tempfile.TemporaryDirectory() as temp_name:
            executable = Path(temp_name) / "list-growth-ownership"
            compiled = subprocess.run(
                [
                    os.environ.get("CC", "cc"),
                    "-O2",
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
            completed = subprocess.run(
                [str(executable)],
                cwd=ROOT,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                check=False,
            )
            self.assertEqual(completed.returncode, 0, completed.stderr)

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

            for setting in (None, "BLORP_LEAK_CHECK"):
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
                if setting == "BLORP_LEAK_CHECK":
                    leak_summary = re.search(
                        r"blorp: leak check: ([0-9]+) allocs, "
                        r"([0-9]+) releases, 0 leaked, 0 bytes",
                        completed.stderr,
                    )
                    self.assertIsNotNone(leak_summary, completed.stderr)
                    assert leak_summary is not None
                    allocations, releases = leak_summary.groups()
                    self.assertEqual(allocations, releases)

    def test_memory_stats_counters_do_not_enable_object_metadata(self) -> None:
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
                // -1 on a platform whose allocator cannot report block sizes.
                int bytes_supported = before.bytes_available;
                if (bytes_supported && before.bytes_allocated != 0) return 5;
                if (before.oracle_stats_active != 1) return 16;

                blorp_Object* object = blorp_alloc(sizeof(blorp_Object));
                blorp_MemStats after_object_alloc = blorp_get_mem_stats();
                if (after_object_alloc.total_allocations != 1) return 6;
                if (after_object_alloc.total_releases != 0) return 7;
                if (after_object_alloc.current_objects != 1) return 8;
                if (bytes_supported &&
                    after_object_alloc.bytes_allocated < (long)sizeof(blorp_Object)) return 17;
                blorp_release(object);

                blorp_MemStats after_object_release = blorp_get_mem_stats();
                if (after_object_release.total_allocations != 1) return 9;
                if (after_object_release.total_releases != 1) return 10;
                if (after_object_release.current_objects != 0) return 11;
                if (bytes_supported && after_object_release.bytes_allocated != 0) return 18;

                for (size_t slot = 0; slot < BLORP_ALLOC_META_SLOTS; slot++) {
                    if (__alloc_meta_table[slot] != NULL) return 12;
                }

                // Raw process memory moves allocator_bytes_in_use but never
                // the managed byte count.
                const size_t allocation_size = 64 * 1024 * 1024;
                void* allocation = malloc(allocation_size);
                if (!allocation) return 13;
                memset(allocation, 0x5a, allocation_size);

                blorp_MemStats during = blorp_get_mem_stats();
                if (bytes_supported && during.bytes_allocated != 0) return 19;
                if (during.allocator_bytes_in_use - before.allocator_bytes_in_use <
                    (long)(allocation_size / 2)) return 14;

                free(allocation);
                blorp_MemStats after = blorp_get_mem_stats();
                if (during.allocator_bytes_in_use - after.allocator_bytes_in_use <
                    (long)(allocation_size / 2)) return 15;
                return 0;
            }
            """
        )
        with tempfile.TemporaryDirectory() as temp_name:
            executable = Path(temp_name) / "memory-stats-counters"
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

    def _compile_harness(self, source: str, directory: str, name: str) -> Path:
        executable = Path(directory) / name
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
        return executable

    def test_bytes_allocated_is_managed_bytes_in_every_gate_state(self) -> None:
        # The same program under each way of turning counting on: the
        # environment counters gate (which keeps no per-object size, so bytes
        # are explicitly unavailable), leak tracking, and an explicit reset.
        # Where available, bytes_allocated is exactly the requested managed
        # bytes and returns to its baseline once they are released; raw
        # process memory belongs to allocator_bytes_in_use only.
        source = textwrap.dedent(
            """\
            #define MINICORO_IMPL
            #include "minicoro.h"
            #include "runtime.c"

            #define OBJECT_COUNT 100
            #define OBJECT_SIZE 200

            int main(void) {
                if (getenv("START_WITH_RESET")) blorp_reset_mem_stats();
                blorp_MemStats base = blorp_get_mem_stats();
                if (!base.memory_stats_active || !base.oracle_stats_active) return 20;
                // Bytes need a per-object size, which only leak tracking
                // records: counters alone report bytes_available == 0.
                int bytes_supported = base.bytes_available;
                if (getenv("EXPECT_BYTES") && !bytes_supported) return 21;
                if (getenv("EXPECT_NO_BYTES") && bytes_supported) return 22;
                void* objects[OBJECT_COUNT];
                for (int index = 0; index < OBJECT_COUNT; index++) {
                    objects[index] = blorp_alloc(OBJECT_SIZE);
                }
                blorp_MemStats live = blorp_get_mem_stats();
                if (live.current_objects - base.current_objects != OBJECT_COUNT) return 4;
                if (bytes_supported) {
                    long managed = live.bytes_allocated - base.bytes_allocated;
                    if (managed != OBJECT_COUNT * OBJECT_SIZE) return 2;
                }

                const size_t raw_size = 8 * 1024 * 1024;
                char* raw = malloc(raw_size);
                if (!raw) return 5;
                memset(raw, 1, raw_size);
                blorp_MemStats with_raw = blorp_get_mem_stats();
                if (with_raw.bytes_allocated != live.bytes_allocated) return 6;
                if (with_raw.allocator_bytes_in_use >= 0 &&
                    with_raw.allocator_bytes_in_use - live.allocator_bytes_in_use <
                        (long)(raw_size / 2)) return 7;
                free(raw);

                for (int index = 0; index < OBJECT_COUNT; index++) blorp_release(objects[index]);
                blorp_MemStats done = blorp_get_mem_stats();
                if (done.bytes_allocated != base.bytes_allocated) return 8;
                if (done.current_objects != base.current_objects) return 9;
                return 0;
            }
            """
        )
        with tempfile.TemporaryDirectory() as temp_name:
            executable = self._compile_harness(source, temp_name, "bytes-per-gate")
            gates = (
                ("counters", {"BLORP_MEMORY_STATS": "1", "EXPECT_NO_BYTES": "1"}),
                ("leak tracking", {"BLORP_LEAK_CHECK": "1", "EXPECT_BYTES": "1"}),
                ("explicit reset", {"START_WITH_RESET": "1", "EXPECT_BYTES": "1"}),
            )
            for label, gate_environment in gates:
                environment = dict(os.environ)
                for name in (
                    "BLORP_MEMORY_STATS", "BLORP_LEAK_CHECK", "START_WITH_RESET",
                    "EXPECT_BYTES", "EXPECT_NO_BYTES",
                ):
                    environment.pop(name, None)
                environment.update(gate_environment)
                completed = subprocess.run(
                    [str(executable)],
                    cwd=ROOT,
                    env=environment,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    text=True,
                    check=False,
                )
                self.assertEqual(completed.returncode, 0, f"{label}: {completed.stderr}")

    def test_reading_stats_never_starts_counting(self) -> None:
        source = textwrap.dedent(
            """\
            #define MINICORO_IMPL
            #include "minicoro.h"
            #include "runtime.c"

            int main(void) {
                blorp_MemStats first = blorp_get_mem_stats();
                if (first.memory_stats_active || first.oracle_stats_active) return 2;
                void* object = blorp_alloc(64);
                blorp_MemStats second = blorp_get_mem_stats();
                if (second.memory_stats_active || second.oracle_stats_active) return 3;
                if (second.total_allocations != 0 || second.current_objects != 0) return 4;
                if (__blorp_gates() != 0) return 5;
                blorp_release(object);
                blorp_reset_mem_stats();
                blorp_MemStats reset = blorp_get_mem_stats();
                if (!reset.memory_stats_active || !reset.oracle_stats_active) return 6;
                if (reset.current_objects != 0) return 7;
                return 0;
            }
            """
        )
        with tempfile.TemporaryDirectory() as temp_name:
            executable = self._compile_harness(source, temp_name, "read-only-stats")
            environment = dict(os.environ)
            for name in ("BLORP_MEMORY_STATS", "BLORP_LEAK_CHECK"):
                environment.pop(name, None)
            completed = subprocess.run(
                [str(executable)], cwd=ROOT, env=environment,
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, check=False,
            )
        self.assertEqual(completed.returncode, 0, completed.stderr)

    def test_reset_racing_concurrent_alloc_and_release_stays_balanced(self) -> None:
        # Worker threads allocate and release their own objects continuously
        # while the main thread escalates from "off" with a reset. Objects
        # allocated before the reset are released after it, so a release must
        # not be subtracted from an epoch that never counted its allocation.
        source = textwrap.dedent(
            """\
            #define MINICORO_IMPL
            #include "minicoro.h"
            #include "runtime.c"

            #define WORKER_COUNT 4
            #define BATCH 64
            #define SAMPLE_COUNT 3000
            static _Atomic int stop_workers;

            static void* worker(void* unused) {
                (void)unused;
                void* objects[BATCH];
                while (!atomic_load(&stop_workers)) {
                    for (int i = 0; i < BATCH; i++) objects[i] = blorp_alloc(48 + (i % 5) * 16);
                    for (int i = 0; i < BATCH; i++) blorp_release(objects[i]);
                }
                return NULL;
            }

            int main(void) {
                pthread_t threads[WORKER_COUNT];
                for (int i = 0; i < WORKER_COUNT; i++) pthread_create(&threads[i], NULL, worker, NULL);
                usleep(20000);
                blorp_reset_mem_stats();
                for (int sample = 0; sample < SAMPLE_COUNT; sample++) {
                    blorp_MemStats live = blorp_get_mem_stats();
                    if (live.current_objects < 0) return 2;
                    if (live.bytes_allocated < 0) return 3;
                    if (!live.bytes_available) return 4;
                    usleep(50);
                }
                atomic_store(&stop_workers, 1);
                for (int i = 0; i < WORKER_COUNT; i++) pthread_join(threads[i], NULL);
                blorp_MemStats done = blorp_get_mem_stats();
                if (done.total_allocations <= 0) return 5;
                if (done.total_allocations != done.total_releases) return 6;
                if (done.current_objects != 0) return 7;
                if (done.bytes_allocated != 0) return 8;
                return 0;
            }
            """
        )
        with tempfile.TemporaryDirectory() as temp_name:
            executable = self._compile_harness(source, temp_name, "reset-race")
            environment = dict(os.environ)
            for name in ("BLORP_MEMORY_STATS", "BLORP_LEAK_CHECK"):
                environment.pop(name, None)
            for attempt in range(3):
                completed = subprocess.run(
                    [str(executable)], cwd=ROOT, env=environment,
                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, check=False,
                )
                self.assertEqual(completed.returncode, 0, f"attempt {attempt}: {completed.stderr}")

    def test_strict_leak_check_reports_types_and_exits_99(self) -> None:
        source = textwrap.dedent(
            """\
            #define MINICORO_IMPL
            #include "minicoro.h"
            #include "runtime.c"

            int main(void) {
                void* leaked = blorp_alloc(64);
                BLORP_INSTALL_TAG(leaked, "LeakProbe");
                void* freed = blorp_alloc(64);
                blorp_release(freed);
                return 0;
            }
            """
        )
        with tempfile.TemporaryDirectory() as temp_name:
            executable = self._compile_harness(source, temp_name, "strict-leak")
            results = {}
            for mode in ("1", "strict"):
                environment = dict(os.environ)
                environment["BLORP_LEAK_CHECK"] = mode
                results[mode] = subprocess.run(
                    [str(executable)],
                    cwd=ROOT,
                    env=environment,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    text=True,
                    check=False,
                )
        for mode, completed in results.items():
            self.assertIn("2 allocs, 1 releases, 1 leaked", completed.stderr, mode)
            self.assertRegex(completed.stderr, r"LeakProbe\s+1\s", mode)
        self.assertEqual(results["1"].returncode, 0, results["1"].stderr)
        self.assertEqual(results["strict"].returncode, 99, results["strict"].stderr)


if __name__ == "__main__":
    unittest.main()
