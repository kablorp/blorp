"""Native contracts for the test-only parked-child cancellation hook."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[3]
RUNTIME_INCLUDE = ROOT / "blorp/src/lib/runtime/native"

SOURCE = r'''
#define MINICORO_IMPL
#define BLORP_MEMORY_DIAGNOSTICS 1
#include "minicoro.h"
static mco_result probe_yield(mco_coro* coro);
#define mco_yield probe_yield
#include "runtime.c"
#undef mco_yield

enum { PROBE_DELAY = 1, PROBE_FIBER = 2, PROBE_CANCEL_PARENT = 3, PROBE_HOLD = 4 };
static int probe_mode;
static _Atomic int child_started;
static _Atomic int delay_entered;
static _Atomic int delay_finished;
static _Atomic int parent_returned;
static _Atomic int allow_child_yield;

static void* sleeping_child(void* env);

static mco_result probe_yield(mco_coro* coro) {
    blorp_Task* current = (blorp_Task*)__blorp_current_task;
    bool child_callback = current && current->func->func == (void*)sleeping_child;
    if (child_callback && probe_mode == PROBE_HOLD) {
        atomic_store(&delay_entered, 1);
        // Deterministic pre-suspension barrier, released by cancellation or
        // the observing test. Never changes the production scheduler.
        while (!atomic_load(&current->cancelled) && !atomic_load(&allow_child_yield)) {
            struct timespec backoff = {0, BLORP_NSEC_PER_MSEC};
            nanosleep(&backoff, NULL);
        }
        atomic_store(&delay_finished, 1);
    }
    if (child_callback && probe_mode == PROBE_DELAY) {
        // Model carrier preemption after parked=1, before actual suspension.
        atomic_store(&delay_entered, 1);
        struct timespec delay = {0, 200 * 1000000L};
        while (nanosleep(&delay, &delay) != 0 && errno == EINTR) {}
        atomic_store(&delay_finished, 1);
    }
    if (!child_callback && probe_mode == PROBE_CANCEL_PARENT) {
        blorp_Task* parent = (blorp_Task*)__blorp_current_task;
        atomic_store(&parent->cancelled, 1);
    }
    return mco_yield(coro);
}

static void* sleeping_child(void* env) {
    (void)env;
    atomic_store(&child_started, 1);
    blorp_sleep(10000);
    abort(); // Cancellation must not return past the sleep checkpoint.
}

static void* completed_child(void* env) {
    (void)env;
    return NULL;
}

static void* observing_parent(void* env) {
    blorp_Closure* child = ((blorp_Closure**)env)[0];
    long observed = blorp_test_cancel_after_parked(child);
    atomic_store(&parent_returned, 1);
    return (void*)(intptr_t)observed;
}

static void assert_balanced(void) {
    blorp_thread_pool_shutdown();
    assert(atomic_load(&global_mem_stats.total_allocations) ==
           atomic_load(&global_mem_stats.total_releases));
}

int main(int argc, char** argv) {
    assert(argc == 2);
    atomic_store(&__blorp_memory_gates, BLORP_GATE_COUNTERS);
    blorp_thread_pool_init(1);
    if (!strcmp(argv[1], "null")) {
        assert(blorp_test_cancel_after_parked(NULL) == 0);
    } else if (!strcmp(argv[1], "completed")) {
        blorp_Closure* child = blorp_closure_new((void*)completed_child, NULL);
        assert(blorp_test_cancel_after_parked(child) == 0);
        blorp_release(child);
    } else {
        blorp_Closure* child = blorp_closure_new((void*)sleeping_child, NULL);
        if (!strcmp(argv[1], "presuspend-deadline")) {
            probe_mode = PROBE_HOLD;
            blorp_Task* task = blorp_task_spawn(child);
            uint64_t deadline = blorp_monotonic_now_ns() + BLORP_NSEC_PER_SEC;
            while (!atomic_load(&delay_entered)) {
                assert(blorp_monotonic_now_ns() < deadline);
                struct timespec backoff = {0, BLORP_NSEC_PER_MSEC};
                nanosleep(&backoff, NULL);
            }
            blorp_TestParkObservation observation =
                blorp_test_observe_child_parked(task, 0);
            assert(observation.outcome == BLORP_TEST_PARK_DEADLINE);
            assert(observation.has_fiber && observation.parked && observation.running);
            blorp_task_cancel_join_release(task);
            assert(atomic_load(&delay_finished) == 1);
        } else if (!strcmp(argv[1], "deadline")) {
            probe_mode = PROBE_HOLD;
            assert(blorp_test_cancel_after_parked_with_timeout(child, 0) == 0);
        } else if (!strcmp(argv[1], "delay")) {
            probe_mode = PROBE_DELAY;
            assert(blorp_test_cancel_after_parked(child) == 1);
            assert(atomic_load(&child_started) == 1);
            assert(atomic_load(&delay_finished) == 1);
        } else {
            probe_mode = !strcmp(argv[1], "fiber")
                ? PROBE_FIBER : PROBE_CANCEL_PARENT;
            blorp_Closure* parent = blorp_closure_new_inline((void*)observing_parent, 1);
            // Inline capture is owned by the parent closure through its mask.
            ((void**)parent->env)[0] = blorp_retain(child);
            parent->env_release_mask = 1;
            blorp_Task* task = blorp_task_spawn(parent);
            __blorp_task_wait_completed_uncancellable(task);
            if (probe_mode == PROBE_FIBER) {
                assert((intptr_t)task->result == 1);
                assert(atomic_load(&parent_returned) == 1);
            } else {
                assert(atomic_load(&parent_returned) == 0);
            }
            blorp_task_cancel_join_release(task);
            blorp_release(parent);
        }
        blorp_release(child);
    }
    assert_balanced();
    return 0;
}
'''


class CancelAfterParkedContract(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="blorp-parking-contract-")
        cls.executable = Path(cls.temporary.name) / "contract"
        result = subprocess.run(
            [os.environ.get("CC", "cc"), "-O0", "-g", "-fwrapv", "-w",
             f"-I{RUNTIME_INCLUDE}", "-x", "c", "-", "-lm", "-lpthread",
             "-o", str(cls.executable)],
            cwd=ROOT, input=SOURCE, text=True, capture_output=True, timeout=60)
        if result.returncode:
            raise AssertionError(result.stderr)

    @classmethod
    def tearDownClass(cls):
        cls.temporary.cleanup()

    def run_case(self, case):
        result = subprocess.run([str(self.executable), case], cwd=ROOT,
                                text=True, capture_output=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stderr

    def test_waits_for_actual_suspension_after_carrier_delay(self):
        self.assertEqual(self.run_case("delay"), "")

    def test_single_worker_fiber_caller_allows_child_progress(self):
        self.assertEqual(self.run_case("fiber"), "")

    def test_parent_cancellation_releases_owned_child(self):
        self.assertEqual(self.run_case("cancel-parent"), "")

    def test_completed_child_reports_observation_failure(self):
        self.assertEqual(self.run_case("completed"),
                         "blorp: cancel_after_parked: child completed before suspension "
                         "(completed=1 fiber=0 parked=0 running=0; "
                         "no fiber observed (pending or fallback runner); observation_ns=5000000000). "
                         "Child must remain blocked until cancellation.\n")

    def test_short_deadline_reports_failure_and_releases_child(self):
        self.assertRegex(self.run_case("deadline"),
                         r"^blorp: cancel_after_parked: observation deadline expired "
                         r"\(completed=0 fiber=[01] parked=[01] running=[01]; "
                         r"(?:fiber runner|no fiber observed \(pending or fallback runner\)); "
                         r"observation_ns=0\)\. Ensure child reaches a blocking operation "
                         r"and scheduler can make progress\.\n$")

    def test_parked_flag_without_actual_suspension_is_not_success(self):
        self.assertEqual(self.run_case("presuspend-deadline"), "")

    def test_null_closure_remains_false_without_diagnostic(self):
        self.assertEqual(self.run_case("null"), "")


if __name__ == "__main__":
    unittest.main()
