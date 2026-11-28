/* The probes' stand-in for landing 5's Blorp scheduler: carrier threads that run fibers from their own run queues and
 * idle on FIBER_RUNTIME's idle wait, the blorp_kernel_queue the runtime calls, and a watchdog that turns a lost wake into
 * a failure with a message, as Spike K's did. Included after the fiber runtime. A fiber stays on the carrier it was
 * spawned on. */
enum { MAX_CARRIERS = 4, QUEUE_SLOTS = 256, WATCHDOG_MS = 5000, WATCHDOG_EXIT = 3, WATCHDOG_TICK_MS = 10 };
struct carrier {
    struct blorp_kernel_lock lock; /* guards the queue */
    struct blorp_fiber *queue[QUEUE_SLOTS];
    int head, count;
    struct blorp_idle idle;
    pthread_t thread;
};
#define CARRIER {.lock = BLORP_KERNEL_LOCK_INITIALIZER}
static struct carrier carriers[MAX_CARRIERS] = {CARRIER, CARRIER, CARRIER, CARRIER};
static int carrier_count;
static atomic_int live;              /* fibers spawned and not finished */
static atomic_uint_fast64_t progress; /* what the watchdog watches: fibers run, or a case's own steps */
static atomic_int watching;

/* A harness fiber's argument: its body, its number, and the carrier it stays on. */
struct task {
    void (*body)(struct task *task);
    struct blorp_fiber *fiber;
    int index, carrier;
};

static void push(struct carrier *carrier, struct blorp_fiber *fiber) {
    blorp_kernel_lock(&carrier->lock);
    assert(carrier->count < QUEUE_SLOTS);
    carrier->queue[(carrier->head + carrier->count++) % QUEUE_SLOTS] = fiber;
    blorp_kernel_unlock(&carrier->lock);
    blorp_idle_notify(&carrier->idle);
}
static struct blorp_fiber *pop(struct carrier *carrier) {
    struct blorp_fiber *fiber = NULL;
    blorp_kernel_lock(&carrier->lock);
    if (carrier->count > 0) {
        fiber = carrier->queue[carrier->head];
        carrier->head = (carrier->head + 1) % QUEUE_SLOTS;
        carrier->count--;
    }
    blorp_kernel_unlock(&carrier->lock);
    return fiber;
}
void blorp_kernel_queue(struct blorp_fiber *fiber) {
    const struct task *const task = fiber->argument;
    push(&carriers[task->carrier], fiber);
}

static void use_carriers(int count) {
    assert(count >= 1 && count <= MAX_CARRIERS);
    carrier_count = count;
    for (int index = 0; index < count; index++) blorp_idle_init(&carriers[index].idle);
}
static void task_entry(void *argument) {
    struct task *const task = argument;
    task->body(task);
}
/* A fiber running body on carrier index mod the carrier count, once the carriers run. */
static struct blorp_fiber *spawn(int index, void (*body)(struct task *task)) {
    struct task *const task = calloc(1, sizeof *task);
    assert(task != NULL);
    *task = (struct task){body, NULL, index, index % carrier_count};
    task->fiber = blorp_fiber_create(task_entry, task);
    atomic_fetch_add(&live, 1);
    push(&carriers[task->carrier], task->fiber);
    return task->fiber;
}

static void *carrier_main(void *argument) {
    struct carrier *const self = argument;
    for (;;) {
        const uint64_t observed = blorp_idle_epoch(&self->idle);
        struct blorp_fiber *const fiber = pop(self);
        if (fiber == NULL) {
            if (atomic_load(&live) == 0) return NULL;
            blorp_idle_wait(&self->idle, observed);
            continue;
        }
        atomic_fetch_add_explicit(&progress, 1, memory_order_relaxed);
        const enum blorp_fiber_stop stop = blorp_fiber_run(fiber);
        if (stop == BLORP_FIBER_STOP_YIELDED) {
            push(self, fiber);
        } else if (stop == BLORP_FIBER_STOP_FINISHED) {
            free(fiber->argument);
            blorp_fiber_destroy(fiber);
            if (atomic_fetch_sub(&live, 1) == 1)
                for (int index = 0; index < carrier_count; index++) blorp_idle_notify(&carriers[index].idle);
        }
    }
}

/* Ends the process when `progress` stands still for WATCHDOG_MS while `watching` is set. */
static void *watchdog(void *argument) {
    (void)argument;
    uint_fast64_t seen = atomic_load(&progress);
    int still_ms = 0;
    const struct timespec tick = {0, (long)WATCHDOG_TICK_MS * 1000000};
    while (atomic_load(&watching)) {
        nanosleep(&tick, NULL);
        const uint_fast64_t now = atomic_load(&progress);
        still_ms = now == seen ? still_ms + WATCHDOG_TICK_MS : 0;
        seen = now;
        if (still_ms < WATCHDOG_MS) continue;
        fprintf(stderr, "watchdog: no progress for %d ms with %d fibers live: a lost wake\n", WATCHDOG_MS, atomic_load(&live));
        _exit(WATCHDOG_EXIT);
    }
    return NULL;
}
static pthread_t watchdog_thread;
static void watch(void) {
    atomic_store(&watching, 1);
    pthread_create(&watchdog_thread, NULL, watchdog, NULL);
}
static void unwatch(void) {
    atomic_store(&watching, 0);
    pthread_join(watchdog_thread, NULL);
}

/* Runs the carriers, watched, until every spawned fiber has finished. */
static void run_carriers(void) {
    watch();
    for (int index = 0; index < carrier_count; index++)
        pthread_create(&carriers[index].thread, NULL, carrier_main, &carriers[index]);
    for (int index = 0; index < carrier_count; index++) pthread_join(carriers[index].thread, NULL);
    unwatch();
}

/* xorshift64 for jitter, seeded from multiples of the 64-bit golden-ratio constant, which is odd and so never zero. A
 * jitter spins up to `mask` rounds of a volatile loop, a nanosecond or two each on every target. */
#define RANDOM_SEED UINT64_C(0x9E3779B97F4A7C15)
static uint64_t next_random(uint64_t *state) {
    *state ^= *state << 13;
    *state ^= *state >> 7;
    *state ^= *state << 17;
    return *state;
}
static void jitter(uint64_t *state, uint64_t mask) {
    for (volatile uint64_t round = next_random(state) & mask; round > 0; round--) {}
}
