/*
 * Exact-timing profiler runtime cases.
 *
 * What this tests: the runtime contracts of the exact-timing profiler
 * (BLORP_PROFILE_EXACT_TIMING=1), driven by test_runtime_profile_dense_ids.py.
 * Each case is a function that exercises the profiler directly and returns 0
 * on success or a distinct nonzero code naming the failed check. The Python
 * test asserts on the exit code and on the report written to stderr.
 *
 * Why the cases share one translation unit: they read and write runtime
 * statics (profile_entries, profile_root_execution_state, the profile_*
 * counters), so they must include runtime.c rather than link against it.
 * Compiling runtime.c under ASan and UBSan costs tens of seconds, so one
 * program with one case per process saves about 75 s over one program per
 * case. Each case runs in its own process because the profiler state is
 * global and must start fresh.
 *
 * How to add a case:
 *   1. Write `static int case_<name>(void)` below, with a `---` comment
 *      stating the contract and why it matters. Prefix its static helpers
 *      and globals with the case name; all cases share one namespace.
 *   2. Add a row to `cases[]` in this file.
 *   3. Add a test method in test_runtime_profile_dense_ids.py that calls
 *      run_case("<name>") and asserts on the exit code and output.
 *
 * How to run one case by hand (from the repository root):
 *   cc -O1 -g -fsanitize=address,undefined -fno-omit-frame-pointer -w \
 *       -Iblorp/src/lib/runtime/native \
 *       blorp/test/test_runtime/profile_exact_timing_cases.c \
 *       -lm -lpthread -o /tmp/profile_cases
 *   ASAN_OPTIONS=detect_leaks=0:halt_on_error=1 /tmp/profile_cases <name>
 */
#define BLORP_PROFILE_EXACT_TIMING 1
#define MINICORO_IMPL
#include "minicoro.h"
#include "runtime.c"

/*---
 * Fiber execution states and dynamic profile stacks.
 *
 * Contract: each execution state (root thread or fiber) keeps its own frame
 * stack, active-time clock, dropped-frame debt and abandoned-frame
 * accounting, and only completed frames reach the shared profile entries.
 * It covers failed stack growth, resume/suspend clock arithmetic, parent and
 * child self-time arithmetic, cancellation and window-crossing abandonment,
 * suppressed-epoch debt, interleaved fibers, a 5000-deep stack, and a fiber
 * that dies with an open frame.
 *
 * Why it matters: a wrong frame count or clock would silently misattribute
 * time in every exact-mode profile, and the report would still look
 * plausible. The final report is checked by the Python test.
 */
static const blorp_ProfileFunctionMetadata fiber_execution_states_functions[] = {
    {"parent", "brp_parent", NULL, 1, 0u},
    {"child", "brp_child", NULL, 2, 0u},
};

static void unbalanced_fiber(mco_coro* coroutine) {
    (void)coroutine;
    blorp_profile_start_id(1);
}

static int case_fiber_execution_states(void) {
    blorp_ProfileExecutionState failed_growth = {
        .depth = SIZE_MAX,
        .capacity = SIZE_MAX,
    };
    if (blorp_profile_execution_push(
            &failed_growth,
            (blorp_ProfileFrame){.id = 0, .epoch = 1})) return 2;
    if (failed_growth.dropped_depth != 1) return 3;
    if (atomic_load(&profile_stack_growth_failures) != 1) return 4;
    failed_growth.depth = 0;
    blorp_profile_execution_destroy(&failed_growth);

    blorp_ProfileExecutionState clock_state = {0};
    blorp_profile_execution_resume(&clock_state, 100);
    if (blorp_profile_execution_active_now(&clock_state, 140) != 40) return 5;
    blorp_profile_execution_suspend(&clock_state, 160);
    blorp_profile_execution_resume(&clock_state, 1000);
    if (blorp_profile_execution_active_now(&clock_state, 1030) != 90) return 6;
    blorp_profile_execution_suspend(&clock_state, 1050);
    if (clock_state.active_elapsed_ns != 110) return 7;

    if (blorp_profile_enable(BLORP_PROFILE_MODE_EXACT, fiber_execution_states_functions, 2, 2) != 0) return 8;

    unsigned long arithmetic_epoch = atomic_load(&profile_epoch);
    blorp_ProfileExecutionState arithmetic = {0};
    if (!blorp_profile_execution_push(
            &arithmetic,
            (blorp_ProfileFrame){
                .id = 0,
                .start_active_ns = 10,
                .epoch = arithmetic_epoch,
            })) return 60;
    if (!blorp_profile_execution_push(
            &arithmetic,
            (blorp_ProfileFrame){
                .id = 1,
                .start_active_ns = 20,
                .epoch = arithmetic_epoch,
            })) return 61;
    blorp_ProfileFrame arithmetic_child = arithmetic.frames[1];
    arithmetic.depth = 1;
    blorp_profile_record_completed_frame(
        &arithmetic, 1, arithmetic_child, 50, false);
    blorp_ProfileFrame arithmetic_parent = arithmetic.frames[0];
    arithmetic.depth = 0;
    blorp_profile_record_completed_frame(
        &arithmetic, 0, arithmetic_parent, 100, false);
    if (atomic_load(&profile_entries[0].total_ns) != 90) return 62;
    if (atomic_load(&profile_entries[0].self_ns) != 60) return 63;
    if (atomic_load(&profile_entries[1].total_ns) != 30) return 64;
    if (atomic_load(&profile_entries[1].self_ns) != 30) return 65;
    if (atomic_load(&profile_calls_completed) != 2) return 66;
    blorp_profile_execution_destroy(&arithmetic);
    for (size_t index = 0; index < 2; index++) {
        atomic_store(&profile_entries[index].total_ns, 0);
        atomic_store(&profile_entries[index].self_ns, 0);
        atomic_store(&profile_entries[index].call_count, 0);
    }
    atomic_store(&profile_calls_completed, 0);

    unsigned long cancellation_epoch = atomic_load(&profile_epoch);
    blorp_ProfileExecutionState cancellation_state = {
        .epoch = cancellation_epoch,
    };
    if (!blorp_profile_execution_push(
            &cancellation_state,
            (blorp_ProfileFrame){
                .id = 0,
                .epoch = cancellation_epoch,
            })) return 42;
    if (!blorp_profile_execution_push(
            &cancellation_state,
            (blorp_ProfileFrame){
                .id = 0,
                .epoch = BLORP_PROFILE_SUPPRESSED_EPOCH,
            })) return 43;
    if (!blorp_profile_execution_push(
            &cancellation_state,
            (blorp_ProfileFrame){
                .id = 0,
                .epoch = cancellation_epoch,
            })) return 44;
    cancellation_state.dropped_depth = 2;
    profile_root_execution_state = &cancellation_state;
    blorp_profile_abandon_current_to_depth(
        (blorp_ProfileExecutionDepth){.frame_depth = 1});
    profile_root_execution_state = NULL;
    if (cancellation_state.depth != 1) return 45;
    if (cancellation_state.dropped_depth != 0) return 46;
    if (atomic_load(&profile_cancellation_abandoned_frames) != 3)
        return 47;
    if (atomic_load(&profile_abandoned_frames) != 3) return 48;
    blorp_profile_execution_destroy(&cancellation_state);

    blorp_profile_window_begin();

    unsigned long crossing_epoch = atomic_load(&profile_epoch);
    blorp_ProfileExecutionState crossing_state = {
        .epoch = crossing_epoch,
    };
    if (!blorp_profile_execution_push(
            &crossing_state,
            (blorp_ProfileFrame){
                .id = 0,
                .epoch = crossing_epoch,
            })) return 72;
    blorp_ProfileExecutionDepth crossing_depth = {
        .frame_depth = crossing_state.depth,
    };
    if (!blorp_profile_execution_push(
            &crossing_state,
            (blorp_ProfileFrame){
                .id = 1,
                .epoch = crossing_epoch,
            })) return 73;
    blorp_profile_window_end();
    blorp_profile_window_begin();
    profile_root_execution_state = &crossing_state;
    blorp_profile_abandon_current_to_depth(crossing_depth);
    profile_root_execution_state = NULL;
    if (crossing_state.depth != 1) return 74;
    if (atomic_load(&profile_window_abandoned_frames) != 2)
        return 75;
    if (atomic_load(&profile_cancellation_abandoned_frames) != 0)
        return 76;
    if (atomic_load(&profile_abandoned_frames) != 2) return 77;
    blorp_profile_execution_destroy(&crossing_state);

    blorp_profile_window_begin();

    unsigned long debt_epoch = atomic_load(&profile_epoch);
    blorp_ProfileExecutionState debt_state = {
        .depth = SIZE_MAX,
        .capacity = SIZE_MAX,
        .epoch = debt_epoch,
    };
    if (blorp_profile_execution_push(
            &debt_state,
            (blorp_ProfileFrame){.id = 0, .epoch = debt_epoch})) return 52;
    debt_state.depth = 0;
    debt_state.capacity = 0;
    blorp_profile_window_end();
    blorp_profile_window_begin();
    unsigned long next_debt_epoch = atomic_load(&profile_epoch);
    blorp_profile_execution_sync_epoch(&debt_state, next_debt_epoch);
    if (debt_state.dropped_depth != 0) return 53;
    if (debt_state.suppressed_dropped_depth != 1) return 54;
    if (atomic_load(&profile_window_abandoned_frames) != 1) return 55;
    if (debt_epoch == next_debt_epoch) return 56;
    blorp_profile_execution_push(
        &debt_state,
        (blorp_ProfileFrame){.id = 0, .epoch = next_debt_epoch});
    if (debt_state.dropped_depth != 1) return 57;
    profile_root_execution_state = &debt_state;
    blorp_profile_end_id(0);
    blorp_profile_end_id(0);
    profile_root_execution_state = NULL;
    if (debt_state.dropped_depth != 0) return 58;
    if (debt_state.suppressed_dropped_depth != 0) return 59;
    blorp_profile_execution_destroy(&debt_state);

    blorp_profile_window_begin();

    blorp_profile_start_id(0);
    blorp_profile_start_id(1);
    blorp_profile_end_id(1);
    blorp_profile_end_id(0);
    if (atomic_load(&profile_entries[0].total_ns)
        < atomic_load(&profile_entries[1].total_ns)) return 49;
    if (atomic_load(&profile_entries[0].self_ns)
        > atomic_load(&profile_entries[0].total_ns)) return 50;
    if (atomic_load(&profile_entries[1].self_ns)
        > atomic_load(&profile_entries[1].total_ns)) return 51;

    blorp_Fiber first = {0};
    blorp_Fiber second = {0};
    __blorp_current_fiber = &first;
    blorp_profile_execution_resume(
        &first.profile_execution_state, blorp_profile_now_ns());
    blorp_profile_start_id(0);
    blorp_profile_execution_suspend(
        &first.profile_execution_state, blorp_profile_now_ns());

    __blorp_current_fiber = &second;
    blorp_profile_execution_resume(
        &second.profile_execution_state, blorp_profile_now_ns());
    blorp_profile_start_id(1);
    blorp_profile_end_id(1);
    blorp_profile_execution_suspend(
        &second.profile_execution_state, blorp_profile_now_ns());

    __blorp_current_fiber = &first;
    blorp_profile_execution_resume(
        &first.profile_execution_state, blorp_profile_now_ns());
    blorp_profile_end_id(0);
    blorp_profile_execution_suspend(
        &first.profile_execution_state, blorp_profile_now_ns());
    __blorp_current_fiber = NULL;

    if (first.profile_execution_state.depth != 0) return 9;
    if (second.profile_execution_state.depth != 0) return 10;
    if (atomic_load(&profile_entries[0].call_count) != 2) return 11;
    if (atomic_load(&profile_entries[1].call_count) != 2) return 12;
    if (atomic_load(&profile_out_of_order_ends) != 0) return 13;
    if (atomic_load(&profile_unmatched_ends) != 0) return 14;
    if (atomic_load(&profile_entries[0].self_ns)
        > atomic_load(&profile_entries[0].total_ns)) return 15;
    if (atomic_load(&profile_entries[1].self_ns)
        > atomic_load(&profile_entries[1].total_ns)) return 16;

    for (size_t index = 0; index < 5000; index++) {
        blorp_profile_start_id(0);
    }
    if (profile_root_execution_state == NULL) return 17;
    if (profile_root_execution_state->depth != 5000) return 18;
    if (profile_root_execution_state->capacity < 5000) return 19;
    for (size_t index = 0; index < 5000; index++) {
        blorp_profile_end_id(0);
    }
    if (atomic_load(&profile_stack_growth_failures) != 0) return 20;
    if (atomic_load(&profile_max_stack_depth) != 5000) return 21;

    blorp_Fiber* abandoned = blorp_fiber_create(unbalanced_fiber, NULL);
    if (!abandoned) return 67;
    __blorp_current_fiber = abandoned;
    blorp_profile_fiber_resume(abandoned);
    if (mco_resume(abandoned->coro) != MCO_SUCCESS) return 68;
    blorp_profile_fiber_suspend(abandoned);
    __blorp_current_fiber = NULL;
    if (mco_status(abandoned->coro) != MCO_DEAD) return 69;
    mco_destroy(abandoned->coro);
    abandoned->coro = NULL;
    blorp_fiber_object_recycle(abandoned);
    if (abandoned->profile_execution_state.frames != NULL) return 70;
    if (atomic_load(&profile_dead_or_shutdown_abandoned_frames) != 1)
        return 71;

    atomic_store(&profile_entries[0].total_ns, 90000000);
    atomic_store(&profile_entries[0].self_ns, 60000000);
    atomic_store(&profile_entries[0].call_count, 1);
    atomic_store(&profile_entries[1].total_ns, 30000000);
    atomic_store(&profile_entries[1].self_ns, 30000000);
    atomic_store(&profile_entries[1].call_count, 1);

    blorp_profile_execution_destroy(&first.profile_execution_state);
    blorp_profile_execution_destroy(&second.profile_execution_state);
    blorp_profile_execution_destroy(&clock_state);
    blorp_profile_window_end();
    blorp_profile_report();
    return 0;
}

/*---
 * Invalid profile operations are tolerated, counted and reported.
 *
 * Contract: out-of-range ids, unmatched or out-of-order ends, failed
 * metadata initialization and 5000 nested unmatched starts neither crash nor
 * trip ASan/UBSan, and each is counted in PROFILE_DIAGNOSTICS.
 *
 * Why it matters: a profiled program must never be broken by the profiler
 * itself. Counts are the only evidence that frames were dropped.
 */
static const blorp_ProfileFunctionMetadata invalid_operations_functions[] = {
    {"duplicate", "brp_10", "fixture/first", 10, BLORP_PROFILE_METADATA_HAS_MODULE},
    {"duplicate", "brp_11", "fixture/second", 11, BLORP_PROFILE_METADATA_HAS_MODULE},
};

static int case_invalid_operations(void) {
    if (blorp_profile_enable(BLORP_PROFILE_MODE_EXACT, NULL, 1, 1) == 0) return 2;
    if (blorp_profile_enable(BLORP_PROFILE_MODE_EXACT, invalid_operations_functions, 2, 2) != 0) return 3;

    blorp_profile_start_id(0);
    blorp_profile_window_begin();
    blorp_profile_start_id(1);
    blorp_profile_end_id(1);
    blorp_profile_end_id(0);

    blorp_profile_start_id(0);
    blorp_profile_start_id(0);
    blorp_profile_end_id(0);
    blorp_profile_end_id(0);
    blorp_profile_start_id(1);
    blorp_profile_end_id(1);
    blorp_profile_start_id(0);
    blorp_profile_start_id(1);
    blorp_profile_end_id(0);
    blorp_profile_end_id(1);

    blorp_profile_start_id(2);
    blorp_profile_end_id(2);
    blorp_profile_end_id(0);

    for (size_t index = 0; index < 5000; index++) {
        blorp_profile_start_id(0);
    }
    for (size_t index = 0; index < 5000; index++) {
        blorp_profile_end_id(0);
    }

    blorp_profile_window_end();
    blorp_profile_report();
    return 0;
}

/*---
 * Window changes, report and cleanup wait for in-flight profile operations.
 *
 * Contract: a window begin blocks while a frame operation is active, a
 * report blocks while the window mutex is held, and cleanup blocks while an
 * entry update is in flight; none of them frees or swaps state under a
 * running operation.
 *
 * Why it matters: these races corrupt entries or free memory that another
 * thread is still updating, and only show up under thread timing.
 */
static const blorp_ProfileFunctionMetadata window_and_cleanup_waits_functions[] = {
    {"worker", "brp_worker", NULL, 1, 0u},
};
static atomic_int worker_started = 0;
static atomic_int frame_holder_started = 0;
static atomic_int frame_holder_release = 0;
static atomic_int window_completed = 0;
static atomic_int report_started = 0;
static atomic_int report_completed = 0;

static void* hold_frame_operation(void* unused) {
    (void)unused;
    if (!blorp_profile_frame_operation_enter()) return (void*)1;
    atomic_store(&frame_holder_started, 1);
    while (!atomic_load(&frame_holder_release)) sched_yield();
    blorp_profile_frame_operation_leave();
    return NULL;
}

static void* begin_profile_window(void* unused) {
    (void)unused;
    blorp_profile_window_begin();
    atomic_store(&window_completed, 1);
    return NULL;
}

static void* report_profile(void* unused) {
    (void)unused;
    atomic_store(&report_started, 1);
    blorp_profile_report();
    atomic_store(&report_completed, 1);
    return NULL;
}

static void* profile_worker(void* unused) {
    (void)unused;
    atomic_fetch_add(&profile_active_update_operations, 1);
    blorp_ProfileEntry* entry = &profile_entries[0];
    atomic_store(&worker_started, 1);
    struct timespec delay = {.tv_sec = 0, .tv_nsec = 50000000};
    nanosleep(&delay, NULL);
    atomic_fetch_add(&entry->call_count, 1);
    atomic_fetch_sub(&profile_active_update_operations, 1);
    return NULL;
}

static int case_window_and_cleanup_waits(void) {
    if (blorp_profile_enable(BLORP_PROFILE_MODE_EXACT, window_and_cleanup_waits_functions, 1, 1) != 0) return 2;
    pthread_t frame_holder;
    pthread_t window_worker;
    if (pthread_create(
            &frame_holder, NULL, hold_frame_operation, NULL) != 0) return 6;
    while (!atomic_load(&frame_holder_started)) sched_yield();
    if (pthread_create(
            &window_worker, NULL, begin_profile_window, NULL) != 0) return 7;
    while (atomic_load(&profile_frame_operations_enabled)) sched_yield();
    if (atomic_load(&window_completed)) return 8;
    atomic_store(&frame_holder_release, 1);
    void* frame_result = NULL;
    if (pthread_join(frame_holder, &frame_result) != 0) return 9;
    if (frame_result != NULL) return 10;
    if (pthread_join(window_worker, NULL) != 0) return 11;
    if (!atomic_load(&window_completed)) return 12;

    pthread_mutex_lock(&profile_window_mutex);
    pthread_t report_worker;
    if (pthread_create(
            &report_worker, NULL, report_profile, NULL) != 0) return 13;
    while (!atomic_load(&report_started)) sched_yield();
    struct timespec report_delay = {
        .tv_sec = 0,
        .tv_nsec = 50000000,
    };
    nanosleep(&report_delay, NULL);
    if (atomic_load(&report_completed)) return 14;
    pthread_mutex_unlock(&profile_window_mutex);
    if (pthread_join(report_worker, NULL) != 0) return 15;
    if (!atomic_load(&report_completed)) return 16;

    pthread_t worker;
    if (pthread_create(&worker, NULL, profile_worker, NULL) != 0) return 3;
    while (!atomic_load(&worker_started)) sched_yield();
    blorp_profile_cleanup();
    if (pthread_join(worker, NULL) != 0) return 4;
    if (profile_entries != NULL || atomic_load(&profiling_enabled)) return 5;
    return 0;
}

/*---
 * A frame still open when its window ends is discarded, not mis-timed.
 *
 * Contract: a frame started in one window and still open in the next window
 * is suppressed (its epoch is stale). It is counted in
 * window_abandoned_frames, its end is absorbed, and the frames measured in
 * the new window are recorded intact.
 *
 * Why it matters: otherwise a call that straddles a window boundary would
 * add time from before the window to the measured window.
 */
static const blorp_ProfileFunctionMetadata start_between_windows_functions[] = {
    {"crossing", "brp_crossing", NULL, 1, 0u},
    {"measured", "brp_measured", NULL, 2, 0u},
};

static int case_start_between_windows(void) {
    if (blorp_profile_enable(BLORP_PROFILE_MODE_EXACT, start_between_windows_functions, 2, 2) != 0) return 2;
    blorp_profile_window_begin();
    blorp_profile_start_id(0);
    if (profile_root_execution_state == NULL) return 3;
    if (profile_root_execution_state->depth != 1) return 4;
    blorp_profile_window_end();
    blorp_profile_window_begin();
    blorp_profile_start_id(1);
    if (profile_root_execution_state->depth != 2) return 5;
    if (profile_root_execution_state->frames[0].epoch != BLORP_PROFILE_SUPPRESSED_EPOCH) return 6;
    blorp_profile_end_id(1);
    blorp_profile_end_id(0);
    blorp_profile_start_id(1);
    blorp_profile_end_id(1);
    blorp_profile_start_id(0);
    blorp_profile_window_end();
    blorp_profile_report();
    return 0;
}

typedef struct {
    const char* name;
    int (*run)(void);
} ProfileCase;

static const ProfileCase cases[] = {
    {"fiber_execution_states", case_fiber_execution_states},
    {"invalid_operations", case_invalid_operations},
    {"window_and_cleanup_waits", case_window_and_cleanup_waits},
    {"start_between_windows", case_start_between_windows},
};

int main(int argc, char** argv) {
    if (argc == 2) {
        for (size_t index = 0; index < sizeof(cases) / sizeof(cases[0]); index++) {
            if (strcmp(argv[1], cases[index].name) == 0) return cases[index].run();
        }
    }
    fprintf(stderr, "usage: %s <case>\ncases:", argv[0]);
    for (size_t index = 0; index < sizeof(cases) / sizeof(cases[0]); index++) {
        fprintf(stderr, " %s", cases[index].name);
    }
    fprintf(stderr, "\n");
    return 64;
}
