#!/usr/bin/env python3
"""Native contract tests for runtime cooperative checkpoint amortization."""

from __future__ import annotations

import os
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
RUNTIME_INCLUDE = ROOT / "blorp" / "src" / "lib" / "runtime" / "native"


class CooperativeCheckpointContractTests(unittest.TestCase):
    def compile_and_run(self, source: str, name: str) -> subprocess.CompletedProcess[str]:
        with tempfile.TemporaryDirectory(prefix=f"blorp-{name}-") as temp_name:
            executable = Path(temp_name) / name
            compiled = subprocess.run(
                [
                    os.environ.get("CC", "cc"),
                    "-O0",
                    "-g",
                    "-fwrapv",
                    "-w",
                    f"-I{RUNTIME_INCLUDE}",
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
            return subprocess.run(
                [str(executable)],
                cwd=ROOT,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                check=False,
            )

    def test_budget_boundary_and_non_fiber_slow_poll(self) -> None:
        source = textwrap.dedent(
            """\
            #define MINICORO_IMPL
            #define BLORP_COOPERATIVE_CHECKPOINT_TESTING 1
            #include "minicoro.h"
            #include "runtime.c"

            int main(void) {
                __blorp_current_task = NULL;
                __blorp_current_fiber = NULL;
                __blorp_cooperative_checkpoint_test_reset(
                    BLORP_COOPERATIVE_CHECKPOINT_INTERVAL);

                for (long call = 1; call < BLORP_COOPERATIVE_CHECKPOINT_INTERVAL; call++) {
                    blorp_cooperative_checkpoint();
                    blorp_CooperativeCheckpointTestStats stats =
                        __blorp_cooperative_checkpoint_test_snapshot();
                    if (stats.checkpoint_slow_path_entries != 0) return 10 + (int)call;
                    if (stats.checkpoint_owned_cancellation_polls != 0) return 80 + (int)call;
                    if (__blorp_cooperative_checkpoint_budget !=
                        BLORP_COOPERATIVE_CHECKPOINT_INTERVAL - call) {
                        return 150 + (int)call;
                    }
                }

                blorp_cooperative_checkpoint();
                blorp_CooperativeCheckpointTestStats stats =
                    __blorp_cooperative_checkpoint_test_snapshot();
                if (stats.checkpoint_calls != BLORP_COOPERATIVE_CHECKPOINT_INTERVAL) return 2;
                if (stats.checkpoint_slow_path_entries != 1) return 3;
                if (stats.checkpoint_owned_cancellation_polls != 1) return 4;
                if (stats.yield_considerations != 0) return 5;
                if (__blorp_cooperative_checkpoint_budget !=
                    BLORP_COOPERATIVE_CHECKPOINT_INTERVAL) {
                    return 6;
                }
                return 0;
            }
            """
        )

        completed = self.compile_and_run(source, "checkpoint-boundary")
        self.assertEqual(completed.returncode, 0, completed.stderr)

    def test_cancellation_is_polled_at_every_remaining_budget_offset(self) -> None:
        source = textwrap.dedent(
            """\
            #define MINICORO_IMPL
            #define BLORP_COOPERATIVE_CHECKPOINT_TESTING 1
            #include "minicoro.h"
            #include "runtime.c"

            static void init_cancelled_task(blorp_Task* task) {
                memset(task, 0, sizeof(*task));
                pthread_mutex_init(&task->mutex, NULL);
                pthread_cond_init(&task->done_cond, NULL);
                atomic_store_explicit(&task->cancelled, 1, memory_order_relaxed);
            }

            int main(void) {
                blorp_Task task;
                init_cancelled_task(&task);
                __blorp_current_task = &task;
                __blorp_current_fiber = NULL;

                for (long offset = 1; offset <= BLORP_COOPERATIVE_CHECKPOINT_INTERVAL; offset++) {
                    __blorp_cooperative_checkpoint_test_reset(offset);
                    for (long call = 1; call < offset; call++) {
                        blorp_cooperative_checkpoint();
                        blorp_CooperativeCheckpointTestStats stats =
                            __blorp_cooperative_checkpoint_test_snapshot();
                        if (stats.checkpoint_owned_cancellation_polls != 0) {
                            return 10 + (int)offset;
                        }
                    }

                    blorp_cooperative_checkpoint();
                    blorp_CooperativeCheckpointTestStats stats =
                        __blorp_cooperative_checkpoint_test_snapshot();
                    if (stats.checkpoint_owned_cancellation_polls != 1) {
                        return 90 + (int)offset;
                    }
                    if (stats.checkpoint_slow_path_entries != 1) {
                        return 170 + (int)offset;
                    }
                    if (__blorp_cooperative_checkpoint_budget !=
                        BLORP_COOPERATIVE_CHECKPOINT_INTERVAL) {
                        return 250 + (int)offset;
                    }
                }

                pthread_cond_destroy(&task.done_cond);
                pthread_mutex_destroy(&task.mutex);
                __blorp_current_task = NULL;
                return 0;
            }
            """
        )

        completed = self.compile_and_run(source, "checkpoint-cancel-offsets")
        self.assertEqual(completed.returncode, 0, completed.stderr)

    def test_budget_resets_before_cancellation_longjmp(self) -> None:
        source = textwrap.dedent(
            """\
            #define MINICORO_IMPL
            #define BLORP_COOPERATIVE_CHECKPOINT_TESTING 1
            #include "minicoro.h"
            #include "runtime.c"

            int main(void) {
                blorp_Task task;
                memset(&task, 0, sizeof(task));
                atomic_store_explicit(&task.cancelled, 1, memory_order_relaxed);
                task.cancel_jmp_ready = true;
                __blorp_current_task = &task;
                __blorp_current_fiber = NULL;
                __blorp_cooperative_checkpoint_test_reset(1);

                if (setjmp(task.cancel_jmp) == 0) {
                    blorp_cooperative_checkpoint();
                    return 2;
                }

                blorp_CooperativeCheckpointTestStats stats =
                    __blorp_cooperative_checkpoint_test_snapshot();
                if (__blorp_cooperative_checkpoint_budget !=
                    BLORP_COOPERATIVE_CHECKPOINT_INTERVAL) {
                    return 3;
                }
                if (stats.checkpoint_slow_path_entries != 1) return 4;
                if (stats.checkpoint_owned_cancellation_polls != 1) return 5;
                __blorp_current_task = NULL;
                return 0;
            }
            """
        )

        completed = self.compile_and_run(source, "checkpoint-cancel-longjmp")
        self.assertEqual(completed.returncode, 0, completed.stderr)

    def test_budget_is_thread_local_and_survives_task_transitions_and_yield(self) -> None:
        source = textwrap.dedent(
            """\
            #define MINICORO_IMPL
            #define BLORP_COOPERATIVE_CHECKPOINT_TESTING 1
            #include "minicoro.h"
            #include "runtime.c"

            typedef struct ThreadProbe {
                long calls;
                long final_budget;
                long slow_paths;
            } ThreadProbe;

            static void init_stack_task(blorp_Task* task) {
                memset(task, 0, sizeof(*task));
                pthread_mutex_init(&task->mutex, NULL);
                pthread_cond_init(&task->done_cond, NULL);
            }

            static void destroy_stack_task(blorp_Task* task) {
                pthread_cond_destroy(&task->done_cond);
                pthread_mutex_destroy(&task->mutex);
            }

            static void* run_thread_probe(void* arg) {
                ThreadProbe* probe = (ThreadProbe*)arg;
                __blorp_current_task = NULL;
                __blorp_current_fiber = NULL;
                __blorp_cooperative_checkpoint_test_reset(
                    BLORP_COOPERATIVE_CHECKPOINT_INTERVAL);
                for (long i = 0; i < probe->calls; i++) {
                    blorp_cooperative_checkpoint();
                }
                blorp_CooperativeCheckpointTestStats stats =
                    __blorp_cooperative_checkpoint_test_snapshot();
                probe->final_budget = __blorp_cooperative_checkpoint_budget;
                probe->slow_paths = stats.checkpoint_slow_path_entries;
                return NULL;
            }

            int main(void) {
                ThreadProbe first = {1, 0, 0};
                ThreadProbe second = {BLORP_COOPERATIVE_CHECKPOINT_INTERVAL, 0, 0};
                pthread_t first_thread;
                pthread_t second_thread;
                if (pthread_create(&first_thread, NULL, run_thread_probe, &first) != 0) return 2;
                if (pthread_create(&second_thread, NULL, run_thread_probe, &second) != 0) return 3;
                if (pthread_join(first_thread, NULL) != 0) return 4;
                if (pthread_join(second_thread, NULL) != 0) return 5;
                if (first.final_budget != BLORP_COOPERATIVE_CHECKPOINT_INTERVAL - 1) return 6;
                if (first.slow_paths != 0) return 7;
                if (second.final_budget != BLORP_COOPERATIVE_CHECKPOINT_INTERVAL) return 8;
                if (second.slow_paths != 1) return 9;

                blorp_Task first_task;
                blorp_Task second_task;
                init_stack_task(&first_task);
                init_stack_task(&second_task);
                __blorp_current_fiber = NULL;
                __blorp_cooperative_checkpoint_test_reset(3);
                __blorp_task_enter_runner(&first_task);
                blorp_cooperative_checkpoint();
                __blorp_task_leave_runner(&first_task);
                if (__blorp_cooperative_checkpoint_budget != 2) return 10;

                __blorp_task_enter_runner(&second_task);
                blorp_cooperative_checkpoint();
                blorp_cooperative_checkpoint();
                blorp_CooperativeCheckpointTestStats stats =
                    __blorp_cooperative_checkpoint_test_snapshot();
                __blorp_task_leave_runner(&second_task);
                if (stats.checkpoint_slow_path_entries != 1) return 11;
                if (__blorp_cooperative_checkpoint_budget !=
                    BLORP_COOPERATIVE_CHECKPOINT_INTERVAL) {
                    return 12;
                }

                __blorp_cooperative_checkpoint_test_reset(7);
                blorp_yield_now();
                if (__blorp_cooperative_checkpoint_budget != 7) return 13;
                stats = __blorp_cooperative_checkpoint_test_snapshot();
                if (stats.checkpoint_slow_path_entries != 0) return 14;
                destroy_stack_task(&second_task);
                destroy_stack_task(&first_task);
                return 0;
            }
            """
        )

        completed = self.compile_and_run(source, "checkpoint-tls-transition")
        self.assertEqual(completed.returncode, 0, completed.stderr)


if __name__ == "__main__":
    unittest.main()
