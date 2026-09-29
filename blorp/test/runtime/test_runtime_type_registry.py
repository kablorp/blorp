#!/usr/bin/env python3
"""Native checks for the allocation-site type registry.

Every generated allocation site registers its (destructor, leak-report tag)
pair once; the object header stores only the registry id. These tests cover
the registry itself (deduplication, capacity, concurrent first registration)
and, most importantly, that C emitted by the pinned bootstrap compiler, which
still writes the two legacy macros BLORP_TAG and BLORP_SET_DESTRUCTOR, keeps
running destructors and keeps its tags in the leak report until the next
bootstrap rotation removes those macros.

Set BLORP_TEST_TSAN=1 to also run the registration race under
ThreadSanitizer.
"""

from __future__ import annotations

import os
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
RUNTIME = ROOT / "blorp" / "src" / "lib" / "runtime" / "native"
COMPILER = os.environ.get("CC", "cc")

# Bodies are compiled once through runtime_decl.c with no memory-diagnostics
# define, then linked against each runtime mode: the shape of generated code.
LEGACY_BODY = textwrap.dedent(
    """\
    static int destructor_calls;
    static void legacy_destroy(void* object) {
        (void)object;
        destructor_calls++;
    }

    // What the bootstrap emitter writes for a record with a destructor.
    static void* legacy_pair(void) {
        void* object = blorp_alloc(32);
        BLORP_TAG(object, "LegacyPair");
        BLORP_SET_DESTRUCTOR(object, legacy_destroy);
        return object;
    }
    // A record with no destructor: the tag alone.
    static void* legacy_tag_only(void) {
        void* object = blorp_alloc(32);
        BLORP_TAG(object, "LegacyTagOnly");
        return object;
    }
    // A closure environment: no tag at all.
    static void* legacy_destructor_only(void) {
        void* object = blorp_alloc(32);
        BLORP_SET_DESTRUCTOR(object, legacy_destroy);
        return object;
    }
    // A typed closure: the runtime tags it, then the generated caller installs
    // the environment destructor in a later statement.
    static void* legacy_split_tag(void) {
        void* object = blorp_alloc(32);
        BLORP_TAG(object, "LegacySplit");
        return object;
    }

    // Reverse order: destructor first, tag second.
    static void* legacy_reverse_pair(void) {
        void* object = blorp_alloc(32);
        BLORP_SET_DESTRUCTOR(object, legacy_destroy);
        BLORP_TAG(object, "LegacyReverse");
        return object;
    }

    int main(void) {
        blorp_release(legacy_pair());
        blorp_release(legacy_pair());
        if (destructor_calls != 2) return 2;
        blorp_release(legacy_tag_only());
        blorp_release(legacy_destructor_only());
        if (destructor_calls != 3) return 3;
        void* split = legacy_split_tag();
        BLORP_SET_DESTRUCTOR(split, legacy_destroy);
        blorp_release(split);
        if (destructor_calls != 4) return 4;
        blorp_release(legacy_reverse_pair());
        if (destructor_calls != 5) return 5;

        // Deliberately leaked so a diagnostic runtime reports the tags.
        (void)legacy_pair();
        (void)legacy_tag_only();
        (void)legacy_tag_only();
        (void)legacy_destructor_only();
        (void)legacy_reverse_pair();
        split = legacy_split_tag();
        BLORP_SET_DESTRUCTOR(split, legacy_destroy);
        return 0;
    }
    """
)

CURRENT_BODY = textwrap.dedent(
    """\
    static int destructor_calls;
    static void current_destroy(void* object) {
        (void)object;
        destructor_calls++;
    }

    static void* current_pair(void) {
        void* object = blorp_alloc(32);
        BLORP_INSTALL_TYPE(object, current_destroy, "CurrentPair");
        return object;
    }
    static void* current_tag_only(void) {
        void* object = blorp_alloc(32);
        BLORP_INSTALL_TAG(object, "CurrentTagOnly");
        return object;
    }
    static void* current_destructor_only(void) {
        void* object = blorp_alloc(32);
        BLORP_INSTALL_DESTRUCTOR(object, current_destroy);
        return object;
    }

    int main(void) {
        blorp_release(current_pair());
        blorp_release(current_pair());
        if (destructor_calls != 2) return 2;
        blorp_release(current_tag_only());
        blorp_release(current_destructor_only());
        if (destructor_calls != 3) return 3;

        (void)current_pair();
        (void)current_tag_only();
        (void)current_tag_only();
        (void)current_destructor_only();
        return 0;
    }
    """
)

# Includes runtime.c so the registry internals are visible.
REGISTRY_SOURCE_PREFIX = textwrap.dedent(
    """\
    #define _GNU_SOURCE
    #include <stdlib.h>
    #define MINICORO_IMPL
    #include "minicoro.h"
    #include "runtime.c"

    static int destructor_calls;
    static void destroy_a(void* object) { (void)object; destructor_calls++; }
    static void destroy_b(void* object) { (void)object; destructor_calls++; }
    """
)

DEDUP_MAIN = textwrap.dedent(
    """\
    static uint32_t id_of(void* object) { return ((blorp_Object*)object)->destructor_id; }

    // Two separate sites, one (fn, tag) pair: one registry entry.
    static void* site_one(void) {
        void* object = blorp_alloc(32);
        BLORP_INSTALL_TYPE(object, destroy_a, "Shared");
        return object;
    }
    static void* site_two(void) {
        void* object = blorp_alloc(32);
        BLORP_INSTALL_TYPE(object, destroy_a, "Shared");
        return object;
    }
    // Same tag text from a different literal object still deduplicates.
    static void* site_copy_of_tag(void) {
        char* tag = strdup("Shared");
        void* object = blorp_alloc(32);
        static _Atomic uint32_t cache = 0;
        blorp_install_type(object, &cache, destroy_a, tag);
        return object;
    }
    static void* site_other_fn(void) {
        void* object = blorp_alloc(32);
        BLORP_INSTALL_TYPE(object, destroy_b, "Shared");
        return object;
    }
    static void* site_other_tag(void) {
        void* object = blorp_alloc(32);
        BLORP_INSTALL_TYPE(object, destroy_a, "Other");
        return object;
    }
    static void* site_tag_only(void) {
        void* object = blorp_alloc(32);
        BLORP_INSTALL_TAG(object, "Shared");
        return object;
    }
    static void* site_untyped(void) {
        void* object = blorp_alloc(32);
        BLORP_INSTALL_TYPE(object, NULL, NULL);
        return object;
    }

    int main(void) {
        uint32_t before = atomic_load(&__blorp_type_registry_count);
        void* one = site_one();
        void* two = site_two();
        void* copy = site_copy_of_tag();
        if (id_of(one) == 0 || id_of(one) != id_of(two)) return 2;
        if (id_of(copy) != id_of(one)) return 3;
        void* other_fn = site_other_fn();
        void* other_tag = site_other_tag();
        void* tag_only = site_tag_only();
        if (id_of(other_fn) == id_of(one)) return 4;
        if (id_of(other_tag) == id_of(one)) return 5;
        if (id_of(tag_only) == id_of(one) || id_of(tag_only) == 0) return 6;
        // Four distinct pairs so far: (a,Shared) (b,Shared) (a,Other) (NULL,Shared).
        if (atomic_load(&__blorp_type_registry_count) - before != 4) return 7;
        void* untyped = site_untyped();
        if (id_of(untyped) != 0) return 8;
        if (atomic_load(&__blorp_type_registry_count) - before != 4) return 9;
        // The entry names exactly what the site registered.
        blorp_TypeRegistryEntry* entry = &__blorp_type_registry[id_of(tag_only)];
        if (entry->destructor != NULL || strcmp(entry->tag, "Shared") != 0) return 10;
        // A tag-only object releases without calling any destructor.
        blorp_release(tag_only);
        if (destructor_calls != 0) return 11;
        blorp_release(one);
        if (destructor_calls != 1) return 12;
        return 0;
    }
    """
)

CAPACITY_MAIN = textwrap.dedent(
    """\
    int main(void) {
        // BLORP_TYPE_REGISTRY_SLOTS is 64 here, so entry 63 is the last.
        for (int i = 0; i < 200; i++) {
            char* tag = (char*)malloc(32);
            snprintf(tag, 32, "Tag%d", i);
            _Atomic uint32_t cache = 0;
            uint32_t id = blorp_register_type(&cache, destroy_a, tag);
            if (id == 0 || id >= BLORP_TYPE_REGISTRY_SLOTS) return 2;
        }
        return 3;  // must not be reached
    }
    """
)

RACE_MAIN = textwrap.dedent(
    """\
    #include <pthread.h>
    #include <sched.h>

    #define THREADS 8
    #define KEYS 300

    // Strides coprime with KEYS, so every thread still visits every key once.
    static const int strides[THREADS] = {1, 7, 11, 13, 17, 19, 23, 29};
    static char tags[KEYS][16];
    static _Atomic uint32_t shared_caches[KEYS];
    static _Atomic int start_flag;
    static uint32_t ids[THREADS][KEYS];
    static _Atomic int failures;

    static void* worker(void* argument) {
        int thread = (int)(intptr_t)argument;
        while (!atomic_load_explicit(&start_flag, memory_order_acquire)) sched_yield();
        for (int step = 0; step < KEYS; step++) {
            // Each thread walks the keys in a different order so first
            // registrations of one key really contend.
            int key = (step * strides[thread] + thread) % KEYS;
            _Atomic uint32_t local_cache = 0;
            // Contend both through the shared site cache and through a fresh
            // per-thread cache (another site with the same pair).
            uint32_t shared_id = blorp_register_type(&shared_caches[key], destroy_a, tags[key]);
            uint32_t local_id = blorp_register_type(&local_cache, destroy_a, tags[key]);
            if (shared_id != local_id) atomic_fetch_add(&failures, 1);
            // The entry must be fully visible to a thread that only saw the id.
            if (__blorp_type_registry[shared_id].destructor != destroy_a ||
                strcmp(__blorp_type_registry[shared_id].tag, tags[key]) != 0)
                atomic_fetch_add(&failures, 1);
            ids[thread][key] = shared_id;
        }
        return NULL;
    }

    int main(void) {
        uint32_t before = atomic_load(&__blorp_type_registry_count);
        for (int key = 0; key < KEYS; key++) snprintf(tags[key], sizeof(tags[key]), "Race%d", key);
        pthread_t threads[THREADS];
        for (int t = 0; t < THREADS; t++)
            pthread_create(&threads[t], NULL, worker, (void*)(intptr_t)t);
        atomic_store_explicit(&start_flag, 1, memory_order_release);
        for (int t = 0; t < THREADS; t++) pthread_join(threads[t], NULL);
        if (atomic_load(&failures) != 0) return 2;
        for (int key = 0; key < KEYS; key++) {
            for (int t = 1; t < THREADS; t++)
                if (ids[t][key] != ids[0][key]) return 3;
            for (int other = 0; other < key; other++)
                if (ids[0][other] == ids[0][key]) return 4;
        }
        if (atomic_load(&__blorp_type_registry_count) - before != KEYS) return 5;
        return 0;
    }
    """
)


def run_compile(arguments: list[str], source: str | None = None) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [COMPILER, *arguments],
        cwd=ROOT,
        input=source,
        text=True,
        capture_output=True,
        check=False,
    )


def clean_environment() -> dict[str, str]:
    environment = dict(os.environ)
    for name in ("BLORP_ALLOCATOR_STATS", "BLORP_COMPILER_MEMORY_PROFILE", "BLORP_LEAK_CHECK"):
        environment.pop(name, None)
    return environment


class TypeRegistryTests(unittest.TestCase):
    def _link_body_against_both_modes(self, directory: Path, body: str) -> dict[int, Path]:
        body_object = directory / "body.o"
        compiled = run_compile(
            ["-O2", "-w", "-include", str(RUNTIME / "runtime_decl.c"),
             "-x", "c", "-", "-c", "-o", str(body_object)],
            body,
        )
        self.assertEqual(compiled.returncode, 0, compiled.stderr)
        binaries: dict[int, Path] = {}
        for mode in (0, 1):
            runtime_object = directory / f"runtime-{mode}.o"
            runtime = run_compile(
                ["-O2", "-w", "-fwrapv", "-D_GNU_SOURCE", "-DMINICORO_IMPL",
                 f"-DBLORP_MEMORY_DIAGNOSTICS={mode}",
                 "-include", str(RUNTIME / "minicoro.h"),
                 "-c", str(RUNTIME / "runtime.c"), "-o", str(runtime_object)]
            )
            self.assertEqual(runtime.returncode, 0, runtime.stderr)
            binary = directory / f"body-{mode}"
            link = run_compile(
                [str(body_object), str(runtime_object), "-lm", "-lpthread", "-o", str(binary)]
            )
            self.assertEqual(link.returncode, 0, link.stderr)
            binaries[mode] = binary
        return binaries

    def _check_both_modes(self, body: str, tags_and_counts: dict[str, int]) -> None:
        with tempfile.TemporaryDirectory() as directory:
            binaries = self._link_body_against_both_modes(Path(directory), body)
            environment = clean_environment()
            normal = subprocess.run(
                [str(binaries[0])], env=environment, capture_output=True, text=True
            )
            self.assertEqual(normal.returncode, 0, normal.stderr)

            environment["BLORP_LEAK_CHECK"] = "1"
            diagnostic = subprocess.run(
                [str(binaries[1])], env=environment, capture_output=True, text=True
            )
            self.assertEqual(diagnostic.returncode, 0, diagnostic.stderr)
            self.assertIn("Leaked by type:", diagnostic.stderr)
            for tag, count in tags_and_counts.items():
                self.assertRegex(diagnostic.stderr, rf"{tag}\s+{count}\s", diagnostic.stderr)

    def test_bootstrap_legacy_macros_run_destructors_and_keep_tags(self) -> None:
        self._check_both_modes(
            LEGACY_BODY,
            {"LegacyPair": 1, "LegacyTagOnly": 2, "LegacySplit": 1, "LegacyReverse": 1},
        )

    def test_install_macros_run_destructors_and_report_tags_including_tag_only_sites(self) -> None:
        self._check_both_modes(
            CURRENT_BODY,
            {"CurrentPair": 1, "CurrentTagOnly": 2},
        )

    def test_registry_deduplicates_pairs_and_keeps_untyped_id_zero(self) -> None:
        self._run_registry_program(DEDUP_MAIN, extra_flags=[])

    def test_registry_full_is_a_clear_named_failure(self) -> None:
        result = self._run_registry_program(
            CAPACITY_MAIN,
            extra_flags=["-DBLORP_TYPE_REGISTRY_SLOTS=64"],
            expect_success=False,
        )
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("type registry full", result.stderr)
        self.assertIn("BLORP_TYPE_REGISTRY_SLOTS = 64", result.stderr)

    def test_concurrent_first_registration_agrees_on_one_entry_per_pair(self) -> None:
        self._run_registry_program(RACE_MAIN, extra_flags=[])

    @unittest.skipUnless(
        os.environ.get("BLORP_TEST_TSAN") == "1",
        "set BLORP_TEST_TSAN=1 to run the registration race under ThreadSanitizer",
    )
    def test_concurrent_first_registration_is_clean_under_thread_sanitizer(self) -> None:
        result = self._run_registry_program(
            RACE_MAIN, extra_flags=["-fsanitize=thread", "-g"], optimization="-O1"
        )
        self.assertNotIn("ThreadSanitizer", result.stderr)

    def _run_registry_program(
        self,
        main_source: str,
        extra_flags: list[str],
        expect_success: bool = True,
        optimization: str = "-O2",
    ) -> subprocess.CompletedProcess[str]:
        with tempfile.TemporaryDirectory() as directory:
            binary = Path(directory) / "registry"
            compiled = run_compile(
                [optimization, "-w", "-fwrapv", "-D_GNU_SOURCE", "-DBLORP_MEMORY_DIAGNOSTICS=1",
                 *extra_flags, f"-I{RUNTIME}", "-x", "c", "-", "-lm", "-lpthread",
                 "-o", str(binary)],
                REGISTRY_SOURCE_PREFIX + main_source,
            )
            self.assertEqual(compiled.returncode, 0, compiled.stderr)
            result = subprocess.run(
                [str(binary)], env=clean_environment(), capture_output=True, text=True
            )
            if expect_success:
                self.assertEqual(result.returncode, 0, result.stderr)
            return result


if __name__ == "__main__":
    unittest.main()
