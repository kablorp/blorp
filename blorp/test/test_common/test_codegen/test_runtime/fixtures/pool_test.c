#include <assert.h>
#include <errno.h>
#include <pthread.h>
#include <stdatomic.h>
#include <time.h>

/* Every thread the pool creates goes through this wrapper, which counts them, and
 * fails the next creation on request. */
static atomic_int threads_created;
static int fail_thread_creation;
static int counted_pthread_create(pthread_t *thread, const pthread_attr_t *attributes, void *(*body)(void *), void *argument) {
    if (fail_thread_creation) return EAGAIN;
    atomic_fetch_add(&threads_created, 1);
    return pthread_create(thread, attributes, body, argument);
}
#define pthread_create counted_pthread_create

/* The leapfrog_gap case arms this; the first thread to reach the gap between reading its
 * thief and stealing from it stands in for an OS preemption there. */
enum { GAP_PAUSE_NANOSECONDS = 50 * 1000 * 1000 };
static atomic_int pause_armed;
static void pause_before_leapfrog_steal(void) {
    const struct timespec pause = {0, GAP_PAUSE_NANOSECONDS};
    if (atomic_exchange(&pause_armed, 0)) nanosleep(&pause, NULL);
}
#define BLORP_JOIN_BEFORE_LEAPFROG_STEAL() pause_before_leapfrog_steal()

#include "memory_runtime.c"
#include "join_runtime.c"

/* Every case joins through a job like this one, in which each half writes only its own result slot. */
struct job {
    int64_t n;
    uint64_t left, right;
};

/* ---- nested joins ------------------------------------------------------- */

static uint64_t fibonacci(int64_t n);
static void fibonacci_left(void *job) { ((struct job *)job)->left = fibonacci(((struct job *)job)->n - 1); }
static void fibonacci_right(void *job) { ((struct job *)job)->right = fibonacci(((struct job *)job)->n - 2); }
/* A join at every call above 1: 75,024 joins for n = 24. */
static uint64_t fibonacci(int64_t n) {
    if (n < 2) return (uint64_t)n;
    struct job job = {n, 0, 0};
    blorp_join(fibonacci_left, fibonacci_right, &job);
    return job.left + job.right;
}
static uint64_t fibonacci_serial(int64_t n) { return n < 2 ? (uint64_t)n : fibonacci_serial(n - 1) + fibonacci_serial(n - 2); }

static int nested_joins(void) {
    assert(fibonacci(24) == fibonacci_serial(24));
    return 0;
}

/* ---- a balanced tree of joins over a leaf ------------------------------- */

/* The leaf of each case's tree, which has 2^depth of them; each result is summed. */
static uint64_t (*leaf)(void);
static uint64_t tree(int64_t depth);
static void tree_left(void *job) { ((struct job *)job)->left = tree(((struct job *)job)->n - 1); }
static void tree_right(void *job) { ((struct job *)job)->right = tree(((struct job *)job)->n - 1); }
static uint64_t tree(int64_t depth) {
    if (depth == 0) return leaf();
    struct job job = {depth, 0, 0};
    blorp_join(tree_left, tree_right, &job);
    return job.left + job.right;
}

/* ---- uneven halves ------------------------------------------------------ */

/* The right half of each pair does 1,000 times the work of the left. */
enum { UNIT_STEPS = 100, UNEVEN_RATIO = 1000, UNEVEN_TREE_DEPTH = 8 };
static uint64_t work(uint64_t steps, uint64_t seed) {
    uint64_t state = seed;
    for (uint64_t step = 0; step < steps; step++) state = state * 6364136223846793005u + 1442695040888963407u;
    return state;
}
static void uneven_left(void *job) { ((struct job *)job)->left = work(UNIT_STEPS, 1); }
static void uneven_right(void *job) { ((struct job *)job)->right = work(UNIT_STEPS * UNEVEN_RATIO, 2); }
static uint64_t uneven_pair(void) {
    struct job job = {0, 0, 0};
    blorp_join(uneven_left, uneven_right, &job);
    return job.left + job.right;
}

static int uneven_halves(void) {
    leaf = uneven_pair;
    assert(tree(UNEVEN_TREE_DEPTH) == (work(UNIT_STEPS, 1) + work(UNIT_STEPS * UNEVEN_RATIO, 2)) << UNEVEN_TREE_DEPTH);
    return 0;
}

/* ---- a full deque ------------------------------------------------------- */

/* Each level offers a right half that waits until the chain has reached its bottom, so
 * no right half finishes, and the offered ones pile up: the deque, which a test builds
 * with a capacity of 8, fills long before 100. Pool threads hold some, and then wait. */
enum { CHAIN_DEPTH = 100 };
static atomic_int chain_bottom_reached;
static uint64_t chain(int64_t depth);
static void chain_left(void *job) { ((struct job *)job)->left = chain(((struct job *)job)->n - 1); }
static void chain_right(void *job) {
    while (!atomic_load(&chain_bottom_reached)) {}
    ((struct job *)job)->right = (uint64_t)((struct job *)job)->n;
}
static uint64_t chain(int64_t depth) {
    if (depth == 0) {
        atomic_store(&chain_bottom_reached, 1);
        return 0;
    }
    struct job job = {depth, 0, 0};
    blorp_join(chain_left, chain_right, &job);
    return job.left + job.right;
}

static int deque_overflow(void) {
    assert(chain(CHAIN_DEPTH) == CHAIN_DEPTH * (CHAIN_DEPTH + 1) / 2);
    return 0;
}

/* ---- deep recursion on a pool thread ------------------------------------ */

/* Each leaf recurses through about 4 MiB, half the main thread's usual 8 MiB. A pool
 * thread with macOS's default 512 KiB stack would overflow. */
enum { FRAME_BYTES = 4096, DEEP_FRAMES = 1000, DEEP_TREE_DEPTH = 6 };
static uint64_t deep(uint64_t frames) {
    volatile unsigned char frame[FRAME_BYTES];
    frame[0] = (unsigned char)frames;
    frame[FRAME_BYTES - 1] = (unsigned char)frames;
    if (frames == 0) return 0;
    return 1 + deep(frames - 1) + (uint64_t)(frame[0] - (unsigned char)frames) + (uint64_t)(frame[FRAME_BYTES - 1] - (unsigned char)frames);
}
static uint64_t deep_leaf(void) { return deep(DEEP_FRAMES); }

static int deep_recursion(void) {
    leaf = deep_leaf;
    assert(tree(DEEP_TREE_DEPTH) == (uint64_t)DEEP_FRAMES << DEEP_TREE_DEPTH);
    return 0;
}

static void nothing(void *job) { (void)job; }

/* ---- the last task: the owner takes it back as a thief steals it --------- */

/* Each join's left half does nothing, so the owner takes its right half back at once,
 * while idle threads are stealing. The right half counts its runs: a task that both
 * the owner and a thief ran, or neither, makes the total wrong. */
enum { RACED_JOINS = 200000 };
static atomic_int runs;
static void count_run(void *job) { (void)job; atomic_fetch_add(&runs, 1); }
static int take_back_race(void) {
    for (int join = 0; join < RACED_JOINS; join++) blorp_join(nothing, count_run, NULL);
    assert(atomic_load(&runs) == RACED_JOINS);
    return 0;
}

/* ---- a waiting thread must not run unrelated work on its stack ----------- */

/* Serially no path is deeper than about 5 MiB: task `first` recurses 5 MiB and then
 * joins, and `second` recurses 5 MiB, but only after `first` is done. With three or
 * more threads, if the thread waiting at the bottom of `first`'s recursion helped by
 * running `second`, its stack would hold both and overflow. Each wait gives up after a
 * deadline, so the serial run cannot block. */
enum { HELPING_FRAMES = 1280, SHORT_WAIT_MS = 200, LONG_WAIT_MS = 1000 };
static atomic_int second_started, inner_right_started, deep_started;
static void wait_for(atomic_int *flag, int64_t milliseconds) {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    const int64_t end = (int64_t)now.tv_sec * 1000 + now.tv_nsec / 1000000 + milliseconds;
    while (!atomic_load(flag)) {
        clock_gettime(CLOCK_MONOTONIC, &now);
        if ((int64_t)now.tv_sec * 1000 + now.tv_nsec / 1000000 >= end) return;
    }
}
static void inner_left(void *job) { (void)job; wait_for(&inner_right_started, SHORT_WAIT_MS); }
static void inner_right(void *job) { (void)job; atomic_store(&inner_right_started, 1); wait_for(&deep_started, LONG_WAIT_MS); }
static void recurse_then_join(int64_t frames, void (*left)(void *), void (*right)(void *)) {
    volatile unsigned char frame[FRAME_BYTES];
    frame[0] = 1;
    if (frames > 0) recurse_then_join(frames - 1, left, right);
    else blorp_join(left, right, NULL);
    if (frame[0] != 1) abort();
}
static void first(void *job) { (void)job; wait_for(&second_started, SHORT_WAIT_MS); recurse_then_join(HELPING_FRAMES, inner_left, inner_right); }
static void deep_half(void *job) { (void)job; atomic_store(&deep_started, 1); deep(HELPING_FRAMES); }
static void waiting_half(void *job) { (void)job; wait_for(&deep_started, LONG_WAIT_MS); }
static void second(void *job) {
    (void)job;
    atomic_store(&second_started, 1);
    wait_for(&inner_right_started, LONG_WAIT_MS);
    blorp_join(waiting_half, deep_half, NULL);
}

static int helping_stack(void) {
    blorp_join(first, second, NULL);
    return 0;
}

/* ---- the thief may finish the awaited task before the steal --------------- */

/* As above, but the waiting thread's thief finishes the awaited task while the waiter is
 * paused before its steal. The thief's thread then goes idle, steals `rest`, and pushes
 * `deep_half` onto its deque: unrelated to the awaited task, and 5 MiB deep. A waiter
 * that won it would hold two 5 MiB paths, which the serial run never does. */
enum { QUICK_WORK_MS = 5 };
static atomic_int quick_finished, never;
static void quick_right(void *job) {
    (void)job;
    atomic_store(&inner_right_started, 1);
    wait_for(&never, QUICK_WORK_MS); /* still running when the waiter looks, done before it steals */
    atomic_store(&quick_finished, 1);
}
static void gap_first(void *job) {
    (void)job;
    wait_for(&second_started, SHORT_WAIT_MS);
    recurse_then_join(HELPING_FRAMES, inner_left, quick_right);
}
static void rest(void *job) { (void)job; blorp_join(waiting_half, deep_half, NULL); }
static void gap_second(void *job) {
    (void)job;
    atomic_store(&second_started, 1);
    wait_for(&quick_finished, LONG_WAIT_MS);
    blorp_join(waiting_half, rest, NULL);
}
static int leapfrog_gap(void) {
    atomic_store(&pause_armed, 1);
    blorp_join(gap_first, gap_second, NULL);
    return 0;
}

/* ---- starting and stopping ---------------------------------------------- */


/* Starts the pool with one join, then checks that it made one thread fewer than
 * BLORP_THREADS asks for, the caller being the first. */
static int thread_count(void) {
    const int expected = atoi(getenv("BLORP_THREADS")) - 1;
    assert(atomic_load(&threads_created) == 0);
    blorp_join(nothing, nothing, NULL);
    assert(atomic_load(&threads_created) == expected);
    return 0;
}

/* Joins, then returns at once, so the workers are idle, spinning or asleep, as the
 * program ends. */
static int exit_while_idle(void) {
    assert(fibonacci(12) == fibonacci_serial(12));
    return blorp_memory_finish(0);
}

int main(int argc, char **argv) {
    blorp_memory_start();
    assert(argc == 2);
    const char *mode = argv[1];
    if (strcmp(mode, "nested_joins") == 0) return nested_joins();
    if (strcmp(mode, "uneven_halves") == 0) return uneven_halves();
    if (strcmp(mode, "deque_overflow") == 0) return deque_overflow();
    if (strcmp(mode, "deep_recursion") == 0) return deep_recursion();
    if (strcmp(mode, "take_back_race") == 0) return take_back_race();
    if (strcmp(mode, "helping_stack") == 0) return helping_stack();
    if (strcmp(mode, "leapfrog_gap") == 0) return leapfrog_gap();
    if (strcmp(mode, "thread_count") == 0) return thread_count();
    if (strcmp(mode, "exit_while_idle") == 0) return exit_while_idle();
    /* "start" is the pool's first join, which a bad BLORP_THREADS stops. */
    if (strcmp(mode, "creation_fails") == 0) fail_thread_creation = 1;
    else if (strcmp(mode, "start") != 0) return 2;
    blorp_join(nothing, nothing, NULL);
    return 0;
}
