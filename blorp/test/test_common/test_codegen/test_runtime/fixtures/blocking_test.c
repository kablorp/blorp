/* Native probe of BLOCKING_RUNTIME, built with the unmodified production fragments: helpers on demand and their mask,
 * the cap and the kinds, withdrawal, and the cancel pipes. The suite writes thread_runtime.c, fiber_runtime.c,
 * process_helpers_runtime.c and blocking_runtime.c. Each case is the first argument, and the carrier count the second
 * where it applies; a case that passes returns 0 and prints nothing. */
#define _POSIX_C_SOURCE 200809L
#define _XOPEN_SOURCE 700
#define _DEFAULT_SOURCE
#if defined(__APPLE__)
#define _DARWIN_C_SOURCE
#endif
/* Before the renaming macros below, so that they rewrite the runtime's calls and not these headers' declarations. */
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <pthread.h>
#include <sched.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

/* The pool's thread starts and pipes go through these, which count helpers, hold a new helper before it runs while
 * `hold_helpers` is set, and fail on request. */
static atomic_int helpers_started, hold_helpers;
static int fail_thread, fail_pipe;
struct held {
    void *(*routine)(void *);
    void *argument;
};
static void *held_start(void *argument) {
    const struct held held = *(struct held *)argument;
    free(argument);
    while (atomic_load(&hold_helpers)) sched_yield();
    return held.routine(held.argument);
}
static int probe_pthread_create(pthread_t *thread, const pthread_attr_t *attributes, void *(*routine)(void *), void *argument) {
    if (fail_thread) return EAGAIN;
    atomic_fetch_add(&helpers_started, 1);
    struct held *const held = malloc(sizeof *held);
    assert(held != NULL);
    *held = (struct held){routine, argument};
    return pthread_create(thread, attributes, held_start, held);
}
static int probe_pipe(int ends[2]) {
    if (!fail_pipe) return pipe(ends);
    errno = EMFILE;
    return -1;
}
#define pthread_create probe_pthread_create
#define pipe probe_pipe

#include "thread_runtime.c"
#include "fiber_runtime.c"
#include "process_helpers_runtime.c"
#include "blocking_runtime.c"
#undef pthread_create
#undef pipe
#include "carrier_harness.h"

/* What a canceller that withdrew a job ends its wait with, as landing 5's cancelled code will. */
/* Signals 1 to 31, which Linux and macOS both define. */
enum { STANDARD_SIGNALS = 32 };
enum { WITHDRAWN_OUTCOME = -2, TOTAL_JOBS = 2 * BLORP_BLOCKING_BOUNDED_CAP + 1, RACE_ROUNDS = 100000, MAX_DESCRIPTOR = 1024 };
/* A probe's job: the pool's, then what its run and its canceller record. */
struct probe_job {
    struct blorp_blocking_job job;
    atomic_int ran, started, withdrawn, cancelled;
    int cancel;
};
/* On a fiber: arms its wait and submits `job`. */
static void submit(struct blorp_fiber *self, struct probe_job *job, enum blorp_job_kind kind, void (*run)(struct blorp_blocking_job *, int)) {
    job->job.run = run;
    job->job.kind = kind;
    job->job.waiter = self;
    job->job.generation = blorp_wait_arm(self);
    blorp_blocking_submit(&job->job);
}
static int64_t await(struct probe_job *job) {
    blorp_fiber_park(job->job.waiter);
    return blorp_wait_outcome(job->job.waiter, job->job.generation);
}
/* As a canceller that withdrew `job` does. */
static void end_withdrawn(struct probe_job *job) {
    atomic_store(&job->withdrawn, 1);
    const enum blorp_wait_claim claim = blorp_wait_end(job->job.waiter, job->job.generation, WITHDRAWN_OUTCOME);
    assert(claim != BLORP_WAIT_LOST);
    if (claim == BLORP_WAIT_QUEUE) blorp_kernel_queue(job->job.waiter);
}
static void until(atomic_int *flag) {
    while (!atomic_load(flag)) sched_yield();
}
static int readable(int descriptor) {
    struct pollfd poll_descriptor = {descriptor, POLLIN, 0};
    return poll(&poll_descriptor, 1, 0) == 1;
}
/* Jobs that record that they ran; that wait for the cancel; and that wait for `go`. */
static void note_run(struct blorp_blocking_job *job, int cancel) {
    struct probe_job *const probe = (struct probe_job *)job;
    probe->cancel = cancel;
    atomic_store(&probe->ran, 1);
}
static void await_cancel(struct blorp_blocking_job *job, int cancel) {
    struct probe_job *const probe = (struct probe_job *)job;
    note_run(job, cancel);
    atomic_store(&probe->started, 1);
    struct pollfd poll_descriptor = {cancel, POLLIN, 0};
    while (poll(&poll_descriptor, 1, -1) != 1) {}
    atomic_store(&probe->cancelled, 1);
}
/* Against the contract: consumes its cancel byte. */
static void read_cancel(struct blorp_blocking_job *job, int cancel) {
    char byte;
    await_cancel(job, cancel);
    if (read(cancel, &byte, 1) != 1) abort();
}
static atomic_int go;
static void await_go(struct blorp_blocking_job *job, int cancel) {
    note_run(job, cancel);
    atomic_store(&((struct probe_job *)job)->started, 1);
    until(&go);
}

/* ---- starting ------------------------------------------------------------------- */

/* No helper starts before the first submit. Its cancel pipe is above stderr even when stdin is closed, and a helper
 * started from a thread with SIGINT blocked sets the mask the pool recorded, here SIGUSR2 alone. */
static struct probe_job first_job;
static sigset_t first_mask;
static void note_mask(struct blorp_blocking_job *job, int cancel) {
    note_run(job, cancel);
    pthread_sigmask(SIG_SETMASK, NULL, &first_mask);
}
static void submit_with_sigint_blocked(struct task *task) {
    sigset_t interrupt, before, after;
    sigemptyset(&interrupt);
    sigaddset(&interrupt, SIGINT);
    pthread_sigmask(SIG_BLOCK, &interrupt, NULL);
    pthread_sigmask(SIG_SETMASK, NULL, &before);
    submit(task->fiber, &first_job, BLORP_JOB_CANCELLABLE, note_mask);
    assert(await(&first_job) == BLORP_BLOCKING_COMPLETED);
    /* Starting the helper blocked every signal on this carrier for a moment, and restored exactly its mask. */
    pthread_sigmask(SIG_SETMASK, NULL, &after);
    for (int number = 1; number < STANDARD_SIGNALS; number++) assert(sigismember(&after, number) == sigismember(&before, number));
}
static int starts(void) {
    sigset_t user;
    sigemptyset(&user);
    sigaddset(&user, SIGUSR2);
    pthread_sigmask(SIG_BLOCK, &user, NULL);
    blorp_blocking_start();
    pthread_sigmask(SIG_UNBLOCK, &user, NULL);
    close(STDIN_FILENO);
    use_carriers(1);
    spawn(0, submit_with_sigint_blocked);
    assert(atomic_load(&helpers_started) == 0);
    run_carriers();
    assert(atomic_load(&helpers_started) == 1 && atomic_load(&first_job.ran));
    assert(first_job.cancel > STDERR_FILENO && fcntl(STDIN_FILENO, F_GETFD) < 0);
    assert(sigismember(&first_mask, SIGUSR2) == 1 && sigismember(&first_mask, SIGINT) == 0);
    return 0;
}

/* ---- the kinds and the cap -------------------------------------------------------- */

/* TOTAL_JOBS jobs that can wait without bound, each blocked until all have started: one that queued would never start,
 * and the watchdog would report the rest blocked. */
static struct probe_job jobs[TOTAL_JOBS];
static pthread_mutex_t gate_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t gate_changed = PTHREAD_COND_INITIALIZER;
static int entered, running, most_running, gate_open; /* guarded by gate_lock */
static void wait_for_all(struct blorp_blocking_job *job, int cancel) {
    note_run(job, cancel);
    pthread_mutex_lock(&gate_lock);
    entered++;
    pthread_cond_broadcast(&gate_changed);
    while (entered < TOTAL_JOBS) pthread_cond_wait(&gate_changed, &gate_lock);
    pthread_mutex_unlock(&gate_lock);
}
static void submit_unbounded(struct task *task) {
    const enum blorp_job_kind kind = task->index % 2 == 0 ? BLORP_JOB_UNBOUNDED : BLORP_JOB_CANCELLABLE;
    submit(task->fiber, &jobs[task->index], kind, wait_for_all);
    assert(await(&jobs[task->index]) == BLORP_BLOCKING_COMPLETED);
}
static int never_queued(int count) {
    blorp_blocking_start();
    use_carriers(count);
    for (int index = 0; index < TOTAL_JOBS; index++) spawn(index, submit_unbounded);
    run_carriers();
    assert(atomic_load(&helpers_started) == TOTAL_JOBS);
    return 0;
}

/* TOTAL_JOBS bounded jobs, each held until the gate opens: exactly the cap run, so a job that has not started is
 * queued, and a cancel withdraws it. Once the gate opens, the rest run, never more than the cap at once. */
static atomic_int submitted;
static void hold_at_gate(struct blorp_blocking_job *job, int cancel) {
    note_run(job, cancel);
    pthread_mutex_lock(&gate_lock);
    if (++running > most_running) most_running = running;
    pthread_cond_broadcast(&gate_changed);
    while (!gate_open) pthread_cond_wait(&gate_changed, &gate_lock);
    running--;
    pthread_mutex_unlock(&gate_lock);
}
static void submit_bounded(struct task *task) {
    struct probe_job *const job = &jobs[task->index];
    submit(task->fiber, job, BLORP_JOB_BOUNDED, hold_at_gate);
    atomic_fetch_add(&submitted, 1);
    assert(await(job) == (atomic_load(&job->withdrawn) ? WITHDRAWN_OUTCOME : BLORP_BLOCKING_COMPLETED));
}
static void *withdraw_one_queued(void *argument) {
    (void)argument;
    for (int full = 0; !full || atomic_load(&submitted) < TOTAL_JOBS; sched_yield()) {
        pthread_mutex_lock(&gate_lock);
        full = running >= BLORP_BLOCKING_BOUNDED_CAP;
        pthread_mutex_unlock(&gate_lock);
    }
    struct probe_job *queued = NULL;
    for (int index = 0; index < TOTAL_JOBS && queued == NULL; index++)
        if (!atomic_load(&jobs[index].ran)) queued = &jobs[index];
    assert(queued != NULL && blorp_blocking_cancel(&queued->job) == BLORP_CANCEL_WITHDRAWN);
    end_withdrawn(queued);
    pthread_mutex_lock(&gate_lock);
    gate_open = 1;
    pthread_cond_broadcast(&gate_changed);
    pthread_mutex_unlock(&gate_lock);
    return NULL;
}
static int capped(int count) {
    blorp_blocking_start();
    use_carriers(count);
    for (int index = 0; index < TOTAL_JOBS; index++) spawn(index, submit_bounded);
    pthread_t controller;
    pthread_create(&controller, NULL, withdraw_one_queued, NULL);
    run_carriers();
    pthread_join(controller, NULL);
    int withdrawn = 0;
    for (int index = 0; index < TOTAL_JOBS; index++) {
        assert(atomic_load(&jobs[index].ran) != atomic_load(&jobs[index].withdrawn));
        withdrawn += atomic_load(&jobs[index].withdrawn);
    }
    if (withdrawn == 1 && most_running == BLORP_BLOCKING_BOUNDED_CAP) return 0;
    fprintf(stderr, "%d bounded jobs ran at once, against a cap of %d\n", most_running, BLORP_BLOCKING_BOUNDED_CAP);
    return 1;
}

/* ---- cancels ------------------------------------------------------------------- */

/* One fiber's calls, each met by the canceller thread in turn: a job its new helper has not taken is withdrawn and never
 * runs; a running cancellable job's descriptor becomes readable, once; the next job on that helper finds it drained;
 * and a running unbounded job, which gets no descriptor, is not reached. One helper serves them all. */
static struct probe_job calls[4];
static atomic_int stage;
static void cancelled_calls(struct task *task) {
    submit(task->fiber, &calls[0], BLORP_JOB_CANCELLABLE, note_run);
    atomic_store(&stage, 1);
    assert(await(&calls[0]) == WITHDRAWN_OUTCOME && !atomic_load(&calls[0].ran));
    submit(task->fiber, &calls[1], BLORP_JOB_CANCELLABLE, await_cancel);
    assert(await(&calls[1]) == BLORP_BLOCKING_COMPLETED && atomic_load(&calls[1].cancelled));
    submit(task->fiber, &calls[2], BLORP_JOB_CANCELLABLE, note_run);
    assert(await(&calls[2]) == BLORP_BLOCKING_COMPLETED && !readable(calls[2].cancel));
    submit(task->fiber, &calls[3], BLORP_JOB_UNBOUNDED, await_go);
    assert(await(&calls[3]) == BLORP_BLOCKING_COMPLETED && calls[3].cancel == -1);
}
static void *cancel_each(void *argument) {
    (void)argument;
    until(&stage);
    assert(blorp_blocking_cancel(&calls[0].job) == BLORP_CANCEL_WITHDRAWN);
    end_withdrawn(&calls[0]);
    atomic_store(&hold_helpers, 0);
    until(&calls[1].started);
    assert(blorp_blocking_cancel(&calls[1].job) == BLORP_CANCEL_SIGNALLED);
    assert(blorp_blocking_cancel(&calls[1].job) == BLORP_CANCEL_NOT_REACHED);
    until(&calls[3].started);
    assert(blorp_blocking_cancel(&calls[3].job) == BLORP_CANCEL_NOT_REACHED);
    atomic_store(&go, 1);
    return NULL;
}
static int cancels(void) {
    blorp_blocking_start();
    atomic_store(&hold_helpers, 1);
    use_carriers(1);
    spawn(0, cancelled_calls);
    pthread_t canceller;
    pthread_create(&canceller, NULL, cancel_each, NULL);
    run_carriers();
    pthread_join(canceller, NULL);
    assert(atomic_load(&helpers_started) == 1);
    return 0;
}

/* RACE_ROUNDS cancellable jobs over the carriers' fibers, one fiber and one canceller thread per carrier. Each job is
 * allocated for its call and freed as soon as its wait ends, so ASan reports any later touch. Its canceller races it
 * from its submit, or from its start when `after_start`, and holds `leave` while it cancels, which its waiter takes
 * before freeing the job, as landing 5's waiter will leave its wait. Each round, exactly one of the job and a canceller
 * that withdrew it ends the wait. A job that finds its cancel descriptor readable before its own cancel could reach it
 * met a stale one. */
enum { JITTER_MASK = 1023, STALE_EXIT = 5 };
static struct blorp_kernel_lock leave = BLORP_KERNEL_LOCK_INITIALIZER;
static struct probe_job *_Atomic current[MAX_CARRIERS]; /* cleared under `leave` */
static _Atomic uint64_t round_of[MAX_CARRIERS];
static atomic_int racing, after_start;
static void run_raced(struct blorp_blocking_job *job, int cancel) {
    struct probe_job *const probe = (struct probe_job *)job;
    note_run(job, cancel);
    if (atomic_load(&after_start) && readable(cancel)) {
        fprintf(stderr, "a stale cancel reached a job\n");
        _exit(STALE_EXIT);
    }
    atomic_store(&probe->started, 1);
    uint64_t random = RANDOM_SEED * ((uint64_t)(uintptr_t)job | 1);
    jitter(&random, JITTER_MASK);
    if (readable(cancel)) atomic_store(&probe->cancelled, 1);
}
static void race_entry(struct task *task) {
    for (int round = 0; round < RACE_ROUNDS / carrier_count; round++) {
        struct probe_job *const job = calloc(1, sizeof *job);
        assert(job != NULL);
        submit(task->fiber, job, BLORP_JOB_CANCELLABLE, run_raced);
        atomic_store(&current[task->index], job);
        atomic_fetch_add(&round_of[task->index], 1);
        const int64_t outcome = await(job);
        blorp_kernel_lock(&leave);
        atomic_store(&current[task->index], NULL);
        blorp_kernel_unlock(&leave);
        const int withdrawn = atomic_load(&job->withdrawn), ran = atomic_load(&job->ran);
        assert(withdrawn != ran && outcome == (withdrawn ? WITHDRAWN_OUTCOME : BLORP_BLOCKING_COMPLETED));
        free(job);
    }
    atomic_fetch_sub(&racing, 1);
}
static void *canceller_main(void *argument) {
    const int index = (int)(intptr_t)argument;
    uint64_t seen = 0, random = RANDOM_SEED * (uint64_t)(index + 1);
    while (atomic_load(&racing) > 0) {
        if (atomic_load(&round_of[index]) == seen) {
            sched_yield();
            continue;
        }
        seen = atomic_load(&round_of[index]);
        jitter(&random, JITTER_MASK);
        blorp_kernel_lock(&leave);
        struct probe_job *const job = atomic_load(&current[index]);
        if (job != NULL && atomic_load(&after_start)) {
            while (!atomic_load(&job->started)) {}
            jitter(&random, JITTER_MASK);
        }
        if (job != NULL && blorp_blocking_cancel(&job->job) == BLORP_CANCEL_WITHDRAWN) end_withdrawn(job);
        blorp_kernel_unlock(&leave);
    }
    return NULL;
}
/* Descriptors above stderr that `before` does not mark open, and whether each is close-on-exec; marks every open one in
 * `before` when `all_private` is NULL. A process may inherit descriptors that are not close-on-exec, so only new ones
 * count. */
static int opened(unsigned char before[MAX_DESCRIPTOR], int *all_private) {
    int count = 0;
    for (int descriptor = STDERR_FILENO + 1; descriptor < MAX_DESCRIPTOR; descriptor++) {
        const int flags = fcntl(descriptor, F_GETFD);
        if (flags < 0 || before[descriptor]) continue;
        if (all_private == NULL) {
            before[descriptor] = 1;
            continue;
        }
        count++;
        if (!(flags & FD_CLOEXEC)) *all_private = 0;
    }
    return count;
}
/* After the race, the process holds two descriptors per helper, each close-on-exec, however many jobs ran. */
static int race(int count, int from_start) {
    static unsigned char before[MAX_DESCRIPTOR];
    (void)opened(before, NULL);
    blorp_blocking_start();
    use_carriers(count);
    atomic_store(&racing, count);
    atomic_store(&after_start, from_start);
    pthread_t cancellers[MAX_CARRIERS];
    for (int index = 0; index < count; index++) {
        spawn(index, race_entry);
        pthread_create(&cancellers[index], NULL, canceller_main, (void *)(intptr_t)index);
    }
    run_carriers();
    for (int index = 0; index < count; index++) pthread_join(cancellers[index], NULL);
    int all_private = 1;
    const int descriptors = opened(before, &all_private);
    assert(atomic_load(&helpers_started) <= count);
    if (descriptors == 2 * atomic_load(&helpers_started) && all_private) return 0;
    fprintf(stderr, "%d new descriptors for %d helpers, %s close-on-exec\n", descriptors, atomic_load(&helpers_started),
            all_private ? "all" : "not all");
    return 1;
}

/* ---- refusals ------------------------------------------------------------------ */

/* The main thread runs one fiber that submits `refused`, then waits for the program to stop. */
static struct probe_job refused;
static int drain_consumed;
static void submit_refused(void *argument) {
    struct blorp_fiber *const self = *(struct blorp_fiber **)argument;
    submit(self, &refused, drain_consumed ? BLORP_JOB_CANCELLABLE : BLORP_JOB_UNBOUNDED, drain_consumed ? read_cancel : await_go);
    (void)await(&refused);
}
int main(int argc, char **argv) {
    if (argc < 2) return 2;
    const char *const mode = argv[1];
    const int count = argc == 3 ? atoi(argv[2]) : 1;
    if (strcmp(mode, "starts") == 0) return starts();
    if (strcmp(mode, "never_queued") == 0) return never_queued(count);
    if (strcmp(mode, "capped") == 0) return capped(count);
    if (strcmp(mode, "cancels") == 0) return cancels();
    if (strcmp(mode, "withdraw_race") == 0) return race(count, 0);
    if (strcmp(mode, "stale_cancel") == 0) return race(count, 1);
    /* The rest must stop the program with a message. */
    if (strcmp(mode, "cancel_unsubmitted") == 0) return (int)blorp_blocking_cancel(&refused.job);
    if (strcmp(mode, "thread_fails") == 0) {
        fail_thread = 1;
    } else if (strcmp(mode, "pipe_fails") == 0) {
        fail_pipe = 1;
    } else if (strcmp(mode, "drain_consumed") == 0) {
        drain_consumed = 1;
    } else if (strcmp(mode, "ended_elsewhere") != 0 && strcmp(mode, "before_start") != 0) {
        return 2;
    }
    if (strcmp(mode, "before_start") != 0) blorp_blocking_start();
    struct blorp_fiber *fiber;
    fiber = blorp_fiber_create(submit_refused, &fiber);
    assert(blorp_fiber_run(fiber) == BLORP_FIBER_STOP_PARKED);
    if (strcmp(mode, "ended_elsewhere") == 0) {
        until(&refused.started);
        assert(blorp_wait_end(fiber, refused.job.generation, WITHDRAWN_OUTCOME) == BLORP_WAIT_QUEUE);
        atomic_store(&go, 1);
    }
    if (drain_consumed) {
        until(&refused.started);
        assert(blorp_blocking_cancel(&refused.job) == BLORP_CANCEL_SIGNALLED);
    }
    const struct timespec second = {1, 0};
    for (;;) nanosleep(&second, NULL);
}
