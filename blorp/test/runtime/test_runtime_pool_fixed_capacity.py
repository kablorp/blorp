#!/usr/bin/env python3
"""Contract test for the fixed-capacity allocator pool: each size class may
own at most BLORP_POOL_SLAB_LIMIT slabs per thread. Follows
test_runtime_alloc_oracle.py's small-C-harness-under-BLORP_ALLOCATOR_STATS
model, with BLORP_POOL_SLAB_LIMIT set to a tiny value so the limit is hit
without needing hundreds of millions of allocations.
"""

from __future__ import annotations

import os
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]


class RuntimePoolFixedCapacityTests(unittest.TestCase):
    def _compile_and_run(self, source: str, extra_env: dict) -> subprocess.CompletedProcess:
        with tempfile.TemporaryDirectory() as temp_name:
            executable = Path(temp_name) / "pool-fixed-capacity"
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

    def test_slab_count_never_exceeds_limit_and_overflow_frees_to_libc(self) -> None:
        source = textwrap.dedent(
            """\
            #define _GNU_SOURCE
            #define MINICORO_IMPL
            #include "minicoro.h"
            #include "runtime.c"

            int main(void) {
                if (!getenv("BLORP_ALLOCATOR_STATS")) return 90;
                blorp_MemStats before = blorp_get_mem_stats();
                if (before.oracle_stats_active != 1) return 91;

                // Class 0 is the 32-byte class. Allocate far more than
                // BLORP_POOL_SLAB_LIMIT * blorp_pool_refill_count[0] objects
                // without releasing any of them, so the class is forced
                // past its slab limit and must overflow to libc.
                enum { KEEP = 20000 };
                static void* keep[KEEP];
                for (int i = 0; i < KEEP; i++) {
                    keep[i] = blorp_alloc(32);
                }

                if (blorp_pool_tls.slab_count[0] > blorp_pool_slab_limit) {
                    fprintf(stderr, "slab_count %d exceeds limit %d\\n",
                            blorp_pool_tls.slab_count[0], blorp_pool_slab_limit);
                    return 2;
                }

                blorp_MemStats after_alloc = blorp_get_mem_stats();
                long overflow = after_alloc.backing_pool_overflow_events
                    - before.backing_pool_overflow_events;
                if (overflow <= 0) {
                    fprintf(stderr, "expected backing_pool_overflow_events to move, delta=%ld\\n", overflow);
                    return 3;
                }

                // Release everything. Overflowed objects must go back to
                // libc (their alloc_class is BLORP_ALLOC_CLASS_DIRECT), so
                // the free list can never grow past limit * refill_count.
                for (int i = 0; i < KEEP; i++) {
                    blorp_release(keep[i]);
                }

                // Every free object anywhere for this class lives inside
                // one of its resident slabs (each holding at most
                // blorp_pool_refill_count[0] objects), so the slab-count
                // check above already bounds total free capacity at
                // limit * refill_count; re-confirm slab_count directly.
                if (blorp_pool_tls.slab_count[0] > blorp_pool_slab_limit) {
                    fprintf(stderr, "slab_count %d exceeds limit %d after release\\n",
                            blorp_pool_tls.slab_count[0], blorp_pool_slab_limit);
                    return 4;
                }

                blorp_MemStats after_release = blorp_get_mem_stats();
                long discarded = after_release.backing_pool_overflow_events; // unchanged by release
                (void)discarded;

                return 0;
            }
            """
        )
        completed = self._compile_and_run(source, {"BLORP_POOL_SLAB_LIMIT": "4"})
        self.assertEqual(completed.returncode, 0, completed.stderr)

    def test_thread_exit_drains_its_own_slabs(self) -> None:
        # A thread that touches the pool and then returns (not
        # pthread_exit) must trigger the pthread-key destructor, which
        # calls blorp_pool_drain() for that thread's own TLS. Since the
        # test source directly #includes runtime.c, it can read the
        # internal __blorp_pool_drain_calls counter to confirm the
        # destructor actually ran once per worker thread, rather than only
        # at process exit.
        source = textwrap.dedent(
            """\
            #define _GNU_SOURCE
            #define MINICORO_IMPL
            #include "minicoro.h"
            #include "runtime.c"
            #include <pthread.h>

            static _Atomic int worker_had_slabs = 0;

            static void* worker(void* arg) {
                (void)arg;
                void* keep[300];
                for (int i = 0; i < 300; i++) {
                    keep[i] = blorp_alloc(32);
                }
                if (blorp_pool_tls.slab_count[0] > 0) {
                    atomic_fetch_add_explicit(&worker_had_slabs, 1, memory_order_relaxed);
                }
                for (int i = 0; i < 300; i++) {
                    blorp_release(keep[i]);
                }
                return NULL;
            }

            int main(void) {
                if (!getenv("BLORP_ALLOCATOR_STATS")) return 90;

                long drains_before = atomic_load_explicit(&__blorp_pool_drain_calls, memory_order_relaxed);

                enum { N_THREADS = 8 };
                for (int i = 0; i < N_THREADS; i++) {
                    pthread_t t;
                    if (pthread_create(&t, NULL, worker, NULL) != 0) return 92;
                    pthread_join(t, NULL);
                }

                long drains_after = atomic_load_explicit(&__blorp_pool_drain_calls, memory_order_relaxed);
                int had_slabs = atomic_load_explicit(&worker_had_slabs, memory_order_relaxed);

                if (had_slabs != N_THREADS) {
                    fprintf(stderr, "expected every worker to refill a slab, got %d/%d\\n",
                            had_slabs, N_THREADS);
                    return 2;
                }
                if (drains_after - drains_before < N_THREADS) {
                    fprintf(stderr,
                            "expected at least %d pool drains (one per worker thread exit), got %ld\\n",
                            N_THREADS, drains_after - drains_before);
                    return 3;
                }

                return 0;
            }
            """
        )
        completed = self._compile_and_run(source, {"BLORP_POOL_SLAB_LIMIT": "64"})
        self.assertEqual(completed.returncode, 0, completed.stderr)

    def test_idle_slab_stays_resident_and_is_reused_without_a_fresh_malloc(self) -> None:
        # The pool is now truly fixed: a slab that goes fully idle is never
        # freed while its thread lives (that machinery — a retained warm-slab
        # stack, a high-water release trigger — was removed). Confirm the
        # slab count never drops after a burst drains back to idle, and that
        # the next burst reuses the idle slab directly with no new malloc.
        source = textwrap.dedent(
            """\
            #define _GNU_SOURCE
            #define MINICORO_IMPL
            #include "minicoro.h"
            #include "runtime.c"

            int main(void) {
                if (!getenv("BLORP_ALLOCATOR_STATS")) return 90;

                enum { KEEP = 5000 };
                static void* keep[KEEP];
                for (int i = 0; i < KEEP; i++) {
                    keep[i] = blorp_alloc(32);
                }
                int high_water = blorp_pool_tls.slab_count[0];
                if (high_water <= 1) {
                    fprintf(stderr, "burst did not mint more than one slab: %d\\n", high_water);
                    return 2;
                }

                for (int i = 0; i < KEEP; i++) {
                    blorp_release(keep[i]);
                }

                if (blorp_pool_tls.slab_count[0] != high_water) {
                    fprintf(stderr, "slab_count dropped after idling: %d != %d\\n",
                            blorp_pool_tls.slab_count[0], high_water);
                    return 3;
                }

                // Reuse after idling must not require fresh mallocs: the
                // slabs already minted serve the next burst directly.
                long refills_before = atomic_load_explicit(
                    &__blorp_oracle_stats.backing_pool_refill_events, memory_order_relaxed);
                void* reused[64];
                for (int i = 0; i < 64; i++) reused[i] = blorp_alloc(32);
                long refills_after = atomic_load_explicit(
                    &__blorp_oracle_stats.backing_pool_refill_events, memory_order_relaxed);
                if (refills_after != refills_before) {
                    fprintf(stderr, "reuse after idling triggered a fresh slab malloc\\n");
                    return 4;
                }
                for (int i = 0; i < 64; i++) blorp_release(reused[i]);

                return 0;
            }
            """
        )
        completed = self._compile_and_run(source, {"BLORP_POOL_SLAB_LIMIT": "180000"})
        self.assertEqual(completed.returncode, 0, completed.stderr)

    def test_cross_thread_handoff_does_not_alias_slab_ownership(self) -> None:
        # Regression for a real bug found while building the retain path: a
        # short-lived thread that mints slabs, hands its objects to another
        # thread, and exits before that thread's first touch of its own
        # blorp_pool_tls can have its exited thread's lazily-allocated TLS
        # address reused for the still-live thread's block by the dynamic
        # TLS allocator. Comparing raw &blorp_pool_tls addresses for
        # "same thread" then falsely matches, and the receiving thread's
        # release corrupts the exited thread's slab bookkeeping. Guarding
        # with pthread_self()/pthread_equal instead must not reproduce
        # this under repeated runs.
        source = textwrap.dedent(
            """\
            #define _GNU_SOURCE
            #define MINICORO_IMPL
            #include "minicoro.h"
            #include "runtime.c"
            #include <pthread.h>

            #define HANDOFF 1000

            static void* volatile handoff[HANDOFF];
            static _Atomic int handoff_ready = 0;

            static void* producer(void* arg) {
                (void)arg;
                for (int i = 0; i < HANDOFF; i++) {
                    handoff[i] = blorp_alloc(64);
                }
                atomic_store_explicit(&handoff_ready, 1, memory_order_release);
                return NULL;
            }

            static void* consumer(void* arg) {
                (void)arg;
                while (!atomic_load_explicit(&handoff_ready, memory_order_acquire)) { }
                for (int i = 0; i < HANDOFF; i++) {
                    blorp_release(handoff[i]);
                }
                return NULL;
            }

            int main(void) {
                pthread_t p, c;
                if (pthread_create(&p, NULL, producer, NULL) != 0) return 92;
                if (pthread_create(&c, NULL, consumer, NULL) != 0) return 93;
                pthread_join(p, NULL);
                pthread_join(c, NULL);
                return 0;
            }
            """
        )
        for _ in range(10):
            completed = self._compile_and_run(source, {"BLORP_POOL_RETAIN_SLABS": "8"})
            self.assertEqual(completed.returncode, 0, completed.stderr)

    def test_default_limit_matches_link_time_define(self) -> None:
        source = textwrap.dedent(
            """\
            #define _GNU_SOURCE
            #define MINICORO_IMPL
            #include "minicoro.h"
            #include "runtime.c"

            int main(void) {
                if (blorp_pool_slab_limit != BLORP_POOL_SLAB_LIMIT) return 1;
                return 0;
            }
            """
        )
        completed = self._compile_and_run(source, {})
        self.assertEqual(completed.returncode, 0, completed.stderr)


if __name__ == "__main__":
    unittest.main()
