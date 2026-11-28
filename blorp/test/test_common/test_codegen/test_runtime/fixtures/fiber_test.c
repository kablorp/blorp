/* Native probe of FIBER_RUNTIME, built with the unmodified production fragments: the switch, fiber stacks and their
 * cache, and the kernel lock. The suite writes memory_runtime.c, release_runtime.c, thread_runtime.c and
 * fiber_runtime.c. Each case is the first argument, and the lock's thread count the second; a case that passes
 * returns 0 and prints nothing. */
#define _POSIX_C_SOURCE 200809L
#define _XOPEN_SOURCE 700
#define _DEFAULT_SOURCE
#if defined(__APPLE__)
#define _DARWIN_C_SOURCE
#endif
/* Before the renaming macros below, so that they rewrite the runtime's calls and not these headers' declarations. */
#include <assert.h>
#include <errno.h>
#include <execinfo.h>
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

/* Every mapping call the runtime makes goes through these, which count them, keep the latest mapping, and fail on
 * request. */
static atomic_int maps, unmaps;
static char *latest_mapping;
static int fail_map, fail_protect;
static void *probe_mmap(void *address, size_t length, int protection, int flags, int descriptor, off_t offset) {
    if (fail_map) {
        errno = ENOMEM;
        return MAP_FAILED;
    }
    void *const mapping = mmap(address, length, protection, flags, descriptor, offset);
    if (mapping != MAP_FAILED) {
        atomic_fetch_add(&maps, 1);
        latest_mapping = mapping;
    }
    return mapping;
}
static int probe_munmap(void *address, size_t length) {
    atomic_fetch_add(&unmaps, 1);
    return munmap(address, length);
}
static int probe_mprotect(void *address, size_t length, int protection) {
    if (fail_protect) {
        errno = ENOMEM;
        return -1;
    }
    return mprotect(address, length, protection);
}
#define mmap probe_mmap
#define munmap probe_munmap
#define mprotect probe_mprotect

#include "memory_runtime.c"
/* The deep drop's one counted layout, declared before the release runtime as emission declares its kinds. */
enum blorp_release_kind { node_kind, blorp_release_kinds };
#include "release_runtime.c"
#include "thread_runtime.c"
#include "fiber_runtime.c"

/* The main thread's own context. */
static struct blorp_fiber_context *thread;

static void nothing(void *argument) { (void)argument; }

/* Switches back to the main thread once, then returns. `argument` is where its fiber is kept. */
static void park_once(void *argument) {
    struct blorp_fiber *const *self = argument;
    blorp_fiber_switch(&(*self)->context, thread);
}

/* ---- registers ------------------------------------------------------------ */

/* probe_keeps(from, to, seed) sets every callee-saved register to seed plus a number of its own, and the rounding mode
 * to seed & 3, switches from `from` to `to`, and when something switches back returns a bit for each register that
 * changed, the rounding mode included. Each context runs it with its own seed, so a register the switch fails to keep
 * holds another context's value. x30 (arm64) is the return address, which a call does not keep. */
uint64_t probe_keeps(struct blorp_fiber_context *from, struct blorp_fiber_context *to, uint64_t seed);
#if defined(__APPLE__)
#define PROBE_SYMBOL(name) "_" #name
#define PROBE_SECTION ".pushsection __TEXT,__text,regular,pure_instructions\n"
#else
#define PROBE_SYMBOL(name) #name
#define PROBE_SECTION ".pushsection .text\n"
#endif
#if defined(__aarch64__)
/* A bit per register: x19-x29 are bits 0-10, d8-d15 bits 11-18 and FPCR's rounding mode bit 19. xn holds seed + n,
 * and dn seed + 30n written as digits (308 for d8, 3015 for d15), so no two registers hold one value. */
#define SET_D(n) "add x9,x2,#30" #n "\nfmov d" #n ",x9\n"
#define CHECK_X(n, bit) "add x9,x2,#" #n "\ncmp x" #n ",x9\ncset x10,ne\norr x0,x0,x10,lsl #" #bit "\n"
#define CHECK_D(n, bit) "fmov x11,d" #n "\nadd x9,x2,#30" #n "\ncmp x11,x9\ncset x10,ne\norr x0,x0,x10,lsl #" #bit "\n"
__asm__(PROBE_SECTION ".globl " PROBE_SYMBOL(probe_keeps) "\n.p2align 2\n" PROBE_SYMBOL(probe_keeps) ":\n"
        "sub sp,sp,#192\nstp x29,x30,[sp,#0]\nstp x19,x20,[sp,#16]\nstp x21,x22,[sp,#32]\nstp x23,x24,[sp,#48]\n"
        "stp x25,x26,[sp,#64]\nstp x27,x28,[sp,#80]\nstp d8,d9,[sp,#96]\nstp d10,d11,[sp,#112]\nstp d12,d13,[sp,#128]\n"
        "stp d14,d15,[sp,#144]\nmrs x9,fpcr\nstp x9,x2,[sp,#160]\n"
        "add x19,x2,#19\nadd x20,x2,#20\nadd x21,x2,#21\nadd x22,x2,#22\nadd x23,x2,#23\nadd x24,x2,#24\n"
        "add x25,x2,#25\nadd x26,x2,#26\nadd x27,x2,#27\nadd x28,x2,#28\nadd x29,x2,#29\n"
        SET_D(8) SET_D(9) SET_D(10) SET_D(11) SET_D(12) SET_D(13) SET_D(14) SET_D(15)
        "and x9,x2,#3\nlsl x9,x9,#22\nmsr fpcr,x9\n"
        "bl " PROBE_SYMBOL(blorp_fiber_switch) "\n"
        "ldr x2,[sp,#168]\nmov x0,#0\n"
        CHECK_X(19, 0) CHECK_X(20, 1) CHECK_X(21, 2) CHECK_X(22, 3) CHECK_X(23, 4) CHECK_X(24, 5) CHECK_X(25, 6)
        CHECK_X(26, 7) CHECK_X(27, 8) CHECK_X(28, 9) CHECK_X(29, 10)
        CHECK_D(8, 11) CHECK_D(9, 12) CHECK_D(10, 13) CHECK_D(11, 14) CHECK_D(12, 15) CHECK_D(13, 16) CHECK_D(14, 17) CHECK_D(15, 18)
        "mrs x11,fpcr\nubfx x11,x11,#22,#2\nand x9,x2,#3\ncmp x11,x9\ncset x10,ne\norr x0,x0,x10,lsl #19\n"
        "ldr x9,[sp,#160]\nmsr fpcr,x9\n"
        "ldp x19,x20,[sp,#16]\nldp x21,x22,[sp,#32]\nldp x23,x24,[sp,#48]\nldp x25,x26,[sp,#64]\nldp x27,x28,[sp,#80]\n"
        "ldp d8,d9,[sp,#96]\nldp d10,d11,[sp,#112]\nldp d12,d13,[sp,#128]\nldp d14,d15,[sp,#144]\n"
        "ldp x29,x30,[sp,#0]\nadd sp,sp,#192\nret\n.popsection\n");
#elif defined(__x86_64__)
/* rbx, rbp and r12-r15 are bits 0-5; MXCSR's control bits are bit 6 and the x87 control word bit 7. Locals: the seed,
 * the caller's MXCSR and control word, and scratch for both. */
#define CHECK_R(reg, offset, bit) \
    "lea " #offset "(%rdx),%rcx\ncmp %rcx,%" #reg "\nsetne %cl\nmovzbl %cl,%ecx\nshl $" #bit ",%ecx\nor %ecx,%eax\n"
__asm__(PROBE_SECTION ".globl " PROBE_SYMBOL(probe_keeps) "\n.p2align 4\n" PROBE_SYMBOL(probe_keeps) ":\n"
        "push %rbp\npush %rbx\npush %r12\npush %r13\npush %r14\npush %r15\nsub $40,%rsp\n"
        "mov %rdx,(%rsp)\nstmxcsr 8(%rsp)\nfnstcw 16(%rsp)\n"
        "lea 3(%rdx),%rbx\nlea 5(%rdx),%rbp\nlea 12(%rdx),%r12\nlea 13(%rdx),%r13\nlea 14(%rdx),%r14\nlea 15(%rdx),%r15\n"
        "mov %edx,%eax\nand $3,%eax\nshl $13,%eax\nor $0x1F80,%eax\nmov %eax,24(%rsp)\nldmxcsr 24(%rsp)\n"
        "mov %edx,%eax\nand $3,%eax\nshl $10,%eax\nor $0x037F,%eax\nmov %ax,32(%rsp)\nfldcw 32(%rsp)\n"
        "call " PROBE_SYMBOL(blorp_fiber_switch) "\n"
        "mov (%rsp),%rdx\nxor %eax,%eax\n"
        CHECK_R(rbx, 3, 0) CHECK_R(rbp, 5, 1) CHECK_R(r12, 12, 2) CHECK_R(r13, 13, 3) CHECK_R(r14, 14, 4) CHECK_R(r15, 15, 5)
        "stmxcsr 24(%rsp)\nmov 24(%rsp),%ecx\nand $0xFFC0,%ecx\nmov %edx,%esi\nand $3,%esi\nshl $13,%esi\nor $0x1F80,%esi\n"
        "cmp %esi,%ecx\nsetne %cl\nmovzbl %cl,%ecx\nshl $6,%ecx\nor %ecx,%eax\n"
        "fnstcw 32(%rsp)\nmovzwl 32(%rsp),%ecx\nmov %edx,%esi\nand $3,%esi\nshl $10,%esi\nor $0x037F,%esi\n"
        "cmp %esi,%ecx\nsetne %cl\nmovzbl %cl,%ecx\nshl $7,%ecx\nor %ecx,%eax\n"
        "ldmxcsr 8(%rsp)\nfldcw 16(%rsp)\nadd $40,%rsp\npop %r15\npop %r14\npop %r13\npop %r12\npop %rbx\npop %rbp\nret\n.popsection\n");
#endif

/* The main thread runs probe_keeps into fiber a, a into b, and b back to the main thread; then b and a resume in turn
 * and finish. Each of the three keeps its registers and its own rounding mode, 0, 1 and 2, while the others run. */
enum { THREAD_SEED = 0x1000, A_SEED = 0x2001, B_SEED = 0x3002 };
static struct blorp_fiber *a, *b;
static uint64_t a_changed, b_changed;
static void keeps_a(void *argument) { (void)argument; a_changed = probe_keeps(&a->context, &b->context, A_SEED); }
static void keeps_b(void *argument) { (void)argument; b_changed = probe_keeps(&b->context, thread, B_SEED); }
static int registers(void) {
    a = blorp_fiber_create(keeps_a, NULL);
    b = blorp_fiber_create(keeps_b, NULL);
    const uint64_t thread_changed = probe_keeps(thread, &a->context, THREAD_SEED);
    blorp_fiber_switch(thread, &b->context);
    blorp_fiber_switch(thread, &a->context);
    if (thread_changed != 0 || a_changed != 0 || b_changed != 0) {
        fprintf(stderr, "registers changed by a switch: main %#llx, a %#llx, b %#llx\n", (unsigned long long)thread_changed,
                (unsigned long long)a_changed, (unsigned long long)b_changed);
        return 1;
    }
    blorp_fiber_destroy(a);
    blorp_fiber_destroy(b);
    return 0;
}

/* ---- depth ------------------------------------------------------------------ */

/* An optimizer keeps all of a frame whose address escapes; it splits an array it can see whole, volatile or not. */
#define KEEP_FRAME(frame) __asm__ __volatile__("" : : "r"(frame) : "memory")

/* 1,000 frames of 4 KiB: about 4 MiB, half the main thread's usual 8 MiB, which Spike K's 256 KiB stacks or a thread's
 * default 512 KiB on macOS would overflow. */
enum { FRAME_BYTES = 4096, DEEP_FRAMES = 1000 };
static uint64_t deep(uint64_t frames) {
    unsigned char frame[FRAME_BYTES];
    frame[0] = (unsigned char)frames;
    frame[FRAME_BYTES - 1] = (unsigned char)frames;
    KEEP_FRAME(frame);
    if (frames == 0) return 0;
    return 1 + deep(frames - 1) + (uint64_t)(frame[0] - (unsigned char)frames) +
           (uint64_t)(frame[FRAME_BYTES - 1] - (unsigned char)frames);
}
static void deep_entry(void *argument) { *(uint64_t *)argument = deep(DEEP_FRAMES); }
static int depth(void) {
    uint64_t result = 0;
    struct blorp_fiber *const fiber = blorp_fiber_create(deep_entry, &result);
    blorp_fiber_switch(thread, &fiber->context);
    assert(result == DEEP_FRAMES);
    blorp_fiber_destroy(fiber);
    return 0;
}

/* A chain of a million counted nodes, built and released on a fiber through the release runtime's bounded scheduler,
 * as an emitted drop helper releases a deep value. */
enum { DROP_NODES = 1000000 };
struct node {
    _Atomic uint64_t references;
    struct node *child;
};
static void node_release(struct node *value, unsigned depth);
static void node_drop_at(struct node *value, unsigned depth) {
    if (value == NULL) return;
    if (atomic_fetch_sub_explicit(&value->references, UINT64_C(1), memory_order_acq_rel) != UINT64_C(1)) return;
    if (depth < BLORP_RELEASE_DEPTH_LIMIT) {
        node_release(value, depth + 1);
        return;
    }
    blorp_release_deep(node_kind, value);
}
static void node_release(struct node *value, unsigned depth) {
    node_drop_at(value->child, depth);
    blorp_memory_release(value);
}
static void blorp_release_dispatch(enum blorp_release_kind kind, void *dead) {
    assert(kind == node_kind);
    node_release(dead, 1);
}
static void drop_entry(void *argument) {
    (void)argument;
    struct node *head = NULL;
    for (int index = 0; index < DROP_NODES; index++) {
        struct node *const value = blorp_memory_allocate(sizeof *value);
        if (value == NULL) abort();
        atomic_init(&value->references, UINT64_C(1));
        value->child = head;
        head = value;
    }
    node_drop_at(head, 0);
}
static int deep_drop(void) {
    struct blorp_fiber *const fiber = blorp_fiber_create(drop_entry, NULL);
    blorp_fiber_switch(thread, &fiber->context);
    blorp_fiber_destroy(fiber);
    return blorp_memory_finish(0);
}

/* ---- the guard -------------------------------------------------------------- */

/* A fiber recurses without end. Its first write past the stack must fault in the guard, so that nothing beyond the
 * guard is written: the handler, on an alternate stack, checks where the fault was and ends the process, 0 when it was
 * in the guard. Frames of 1 KiB are well inside the guard's 64 KiB. */
enum { GUARD_FAULT_OUTSIDE = 3, GUARD_NO_FAULT = 4, ALTERNATE_STACK_BYTES = 64 * 1024 };
static char *guard_low;
static volatile int keep_recursing = 1;
static void on_fault(int number, siginfo_t *info, void *context) {
    (void)number;
    (void)context;
    const char *const address = info->si_addr;
    if (address >= guard_low && address < guard_low + BLORP_THREAD_GUARD_BYTES) _exit(0);
    static const char message[] = "a fault outside the guard\n";
    if (write(STDERR_FILENO, message, sizeof message - 1) < 0) _exit(GUARD_FAULT_OUTSIDE);
    _exit(GUARD_FAULT_OUTSIDE);
}
static void recurse(unsigned char *caller) {
    unsigned char frame[1024];
    frame[0] = caller[0];
    KEEP_FRAME(frame);
    if (keep_recursing) recurse(frame);
    frame[1] = frame[0];
    KEEP_FRAME(frame);
}
static void overflow_entry(void *argument) {
    (void)argument;
    unsigned char start = 0;
    recurse(&start);
}
static int overflow(void) {
    static unsigned char alternate[ALTERNATE_STACK_BYTES];
    stack_t stack;
    memset(&stack, 0, sizeof stack);
    stack.ss_sp = alternate;
    stack.ss_size = sizeof alternate;
    struct sigaction action;
    memset(&action, 0, sizeof action);
    action.sa_sigaction = on_fault;
    action.sa_flags = SA_SIGINFO | SA_ONSTACK;
    sigemptyset(&action.sa_mask);
    if (sigaltstack(&stack, NULL) != 0 || sigaction(SIGSEGV, &action, NULL) != 0 || sigaction(SIGBUS, &action, NULL) != 0)
        return 1;
    struct blorp_fiber *const fiber = blorp_fiber_create(overflow_entry, NULL);
    guard_low = latest_mapping;
    blorp_fiber_switch(thread, &fiber->context);
    return GUARD_NO_FAULT;
}

/* ---- scale and the cache ----------------------------------------------------- */

/* Each fiber is switched to and parks, then all are resumed in turn, finish and are destroyed. */
enum { SCALE_FIBERS = 10000 };
static int scale(void) {
    struct blorp_fiber **const fibers = calloc(SCALE_FIBERS, sizeof *fibers);
    if (fibers == NULL) return 1;
    for (int index = 0; index < SCALE_FIBERS; index++) {
        fibers[index] = blorp_fiber_create(park_once, &fibers[index]);
        blorp_fiber_switch(thread, &fibers[index]->context);
    }
    for (int index = 0; index < SCALE_FIBERS; index++) {
        blorp_fiber_switch(thread, &fibers[index]->context);
        blorp_fiber_destroy(fibers[index]);
    }
    free(fibers);
    return blorp_memory_finish(0);
}

/* A destroyed fiber's stack, record and all, comes back for the next fiber without a mapping. Past the bound, a
 * destroyed fiber's stack is unmapped, and the cache gives back exactly its bound. */
enum { BEYOND_BOUND = 3, CACHE_FIBERS = BLORP_FIBER_CACHED_STACKS + BEYOND_BOUND };
static int cache(void) {
    struct blorp_fiber *const first = blorp_fiber_create(nothing, NULL);
    blorp_fiber_switch(thread, &first->context);
    blorp_fiber_destroy(first);
    const int mapped = atomic_load(&maps);
    struct blorp_fiber *const second = blorp_fiber_create(nothing, NULL);
    assert(second == first && atomic_load(&maps) == mapped && atomic_load(&unmaps) == 0);
    blorp_fiber_destroy(second);
    static struct blorp_fiber *fibers[CACHE_FIBERS];
    for (int index = 0; index < CACHE_FIBERS; index++) fibers[index] = blorp_fiber_create(nothing, NULL);
    assert(atomic_load(&maps) == mapped + CACHE_FIBERS - 1);
    for (int index = 0; index < CACHE_FIBERS; index++) blorp_fiber_destroy(fibers[index]);
    assert(atomic_load(&unmaps) == BEYOND_BOUND);
    for (int index = 0; index < BLORP_FIBER_CACHED_STACKS; index++) fibers[index] = blorp_fiber_create(nothing, NULL);
    assert(atomic_load(&maps) == mapped + CACHE_FIBERS - 1);
    fibers[BLORP_FIBER_CACHED_STACKS] = blorp_fiber_create(nothing, NULL);
    assert(atomic_load(&maps) == mapped + CACHE_FIBERS);
    return 0;
}

/* ---- backtraces ------------------------------------------------------------------ */

/* From a fiber, backtrace() sees trace_inner, trace_middle, trace_entry and blorp_fiber_start, and stops there at the
 * null frame pointer and return address: two frames after trace_middle's, which is trace_inner's return address. An
 * interceptor's frame may come first, as ASan's does on Linux. Each call is followed by a volatile write, so none is a
 * tail call. */
enum { FRAMES_AFTER_MIDDLE = 2, MAX_FRAMES = 64 };
static int frames_seen, middle_frame = -1;
static volatile int after_call;
static BLORP_NOINLINE void trace_inner(void) {
    void *addresses[MAX_FRAMES];
    frames_seen = backtrace(addresses, MAX_FRAMES);
    for (int index = 0; index < frames_seen; index++)
        if (addresses[index] == __builtin_return_address(0)) middle_frame = index;
}
static BLORP_NOINLINE void trace_middle(void) {
    trace_inner();
    after_call = 1;
}
static void trace_entry(void *argument) {
    (void)argument;
    trace_middle();
    after_call = 2;
}
static int backtraces(void) {
    struct blorp_fiber *const fiber = blorp_fiber_create(trace_entry, NULL);
    blorp_fiber_switch(thread, &fiber->context);
    blorp_fiber_destroy(fiber);
    if (middle_frame >= 0 && frames_seen == middle_frame + 1 + FRAMES_AFTER_MIDDLE) return 0;
    fprintf(stderr, "backtrace() on a fiber saw %d frames, trace_middle's at %d\n", frames_seen, middle_frame);
    return 1;
}

/* ---- the kernel lock ------------------------------------------------------------- */

enum { LOCK_INCREMENTS = 50000, MAX_LOCK_THREADS = 8 };
static struct blorp_kernel_lock counter_lock = BLORP_KERNEL_LOCK_INITIALIZER;
static uint64_t counter; /* guarded by counter_lock */
static void *increment(void *argument) {
    (void)argument;
    for (int round = 0; round < LOCK_INCREMENTS; round++) {
        blorp_kernel_lock(&counter_lock);
        counter++;
        blorp_kernel_unlock(&counter_lock);
    }
    return NULL;
}
static int lock_totals(int threads) {
    pthread_t ids[MAX_LOCK_THREADS];
    if (threads < 1 || threads > MAX_LOCK_THREADS) return 2;
    for (int index = 0; index < threads; index++) pthread_create(&ids[index], NULL, increment, NULL);
    for (int index = 0; index < threads; index++) pthread_join(ids[index], NULL);
    assert(counter == (uint64_t)threads * LOCK_INCREMENTS);
    return 0;
}

/* The main thread holds the lock, asleep, for HOLD_MS; the thread waiting for it must sleep too, using less processor
 * time than a quarter of that. */
enum { HOLD_MS = 300, MILLISECONDS_PER_SECOND = 1000, NANOSECONDS_PER_MILLISECOND = 1000000 };
static atomic_int lock_held;
static int64_t waiter_cpu_ms;
static int64_t thread_cpu_ms(void) {
    struct timespec now;
    clock_gettime(CLOCK_THREAD_CPUTIME_ID, &now);
    return (int64_t)now.tv_sec * MILLISECONDS_PER_SECOND + now.tv_nsec / NANOSECONDS_PER_MILLISECOND;
}
static void *wait_for_lock(void *argument) {
    (void)argument;
    while (!atomic_load(&lock_held)) {}
    const int64_t start = thread_cpu_ms();
    blorp_kernel_lock(&counter_lock);
    waiter_cpu_ms = thread_cpu_ms() - start;
    blorp_kernel_unlock(&counter_lock);
    return NULL;
}
static int lock_sleeps(void) {
    pthread_t waiter;
    blorp_kernel_lock(&counter_lock);
    atomic_store(&lock_held, 1);
    pthread_create(&waiter, NULL, wait_for_lock, NULL);
    const struct timespec hold = {0, (long)HOLD_MS * NANOSECONDS_PER_MILLISECOND};
    nanosleep(&hold, NULL);
    blorp_kernel_unlock(&counter_lock);
    pthread_join(waiter, NULL);
    if (waiter_cpu_ms < HOLD_MS / 4) return 0;
    fprintf(stderr, "a waiter used %lld ms of processor time behind a holder asleep for %d ms\n", (long long)waiter_cpu_ms, HOLD_MS);
    return 1;
}

/* ---- refusals -------------------------------------------------------------------- */

/* A fiber destroys another that is suspended, which the runtime refuses. It does so on the fiber's stack, so ASan
 * reports its abort unless every switch told it which stack is running. */
static struct blorp_fiber *parked;
static void destroy_parked(void *argument) {
    (void)argument;
    blorp_fiber_destroy(parked);
}
static int destroy_suspended(void) {
    parked = blorp_fiber_create(park_once, &parked);
    blorp_fiber_switch(thread, &parked->context);
    struct blorp_fiber *const destroyer = blorp_fiber_create(destroy_parked, NULL);
    blorp_fiber_switch(thread, &destroyer->context);
    return 8;
}

/* Switches to a parked fiber from a second thread, which the runtime refuses. */
static void *resume_elsewhere(void *argument) {
    (void)argument;
    blorp_fiber_switch(blorp_fiber_thread_context(), &parked->context);
    return NULL;
}
static int other_thread(void) {
    pthread_t elsewhere;
    parked = blorp_fiber_create(park_once, &parked);
    blorp_fiber_switch(thread, &parked->context);
    pthread_create(&elsewhere, NULL, resume_elsewhere, NULL);
    pthread_join(elsewhere, NULL);
    return 6;
}

/* A fiber destroyed twice would be cached twice, and two creates would share one stack. */
static int double_destroy(void) {
    struct blorp_fiber *const fiber = blorp_fiber_create(nothing, NULL);
    blorp_fiber_destroy(fiber);
    blorp_fiber_destroy(fiber);
    return 9;
}

/* A fiber switched to after its destroy would run its entry on a cached stack. */
static int resume_destroyed(void) {
    struct blorp_fiber *const fiber = blorp_fiber_create(nothing, NULL);
    blorp_fiber_destroy(fiber);
    blorp_fiber_switch(thread, &fiber->context);
    return 10;
}

/* A second thread switches away from the first thread's context, which the runtime refuses. */
static void *leave_the_wrong_context(void *argument) {
    (void)argument;
    blorp_fiber_thread_context();
    blorp_fiber_switch(thread, &parked->context);
    return NULL;
}
static int wrong_context(void) {
    pthread_t elsewhere;
    parked = blorp_fiber_create(park_once, &parked);
    pthread_create(&elsewhere, NULL, leave_the_wrong_context, NULL);
    pthread_join(elsewhere, NULL);
    return 11;
}

int main(int argc, char **argv) {
    blorp_memory_start();
    if (argc < 2) return 2;
    const char *const mode = argv[1];
    thread = blorp_fiber_thread_context();
    if (strcmp(mode, "registers") == 0) return registers();
    if (strcmp(mode, "depth") == 0) return depth();
    if (strcmp(mode, "deep_drop") == 0) return deep_drop();
    if (strcmp(mode, "overflow") == 0) return overflow();
    if (strcmp(mode, "scale") == 0) return scale();
    if (strcmp(mode, "cache") == 0) return cache();
    if (strcmp(mode, "backtrace") == 0) return backtraces();
    if (strcmp(mode, "lock_totals") == 0 && argc == 3) return lock_totals(atoi(argv[2]));
    if (strcmp(mode, "lock_sleeps") == 0) return lock_sleeps();
    if (strcmp(mode, "other_thread") == 0) return other_thread();
    if (strcmp(mode, "destroy_suspended") == 0) return destroy_suspended();
    if (strcmp(mode, "double_destroy") == 0) return double_destroy();
    if (strcmp(mode, "resume_destroyed") == 0) return resume_destroyed();
    if (strcmp(mode, "wrong_context") == 0) return wrong_context();
    /* The rest must stop the program with a message. */
    struct blorp_fiber *fiber;
    if (strcmp(mode, "map_fails") == 0) {
        fail_map = 1;
    } else if (strcmp(mode, "protect_fails") == 0) {
        fail_protect = 1;
    } else if (strcmp(mode, "resume_finished") == 0) {
        fiber = blorp_fiber_create(nothing, NULL);
        blorp_fiber_switch(thread, &fiber->context);
        blorp_fiber_switch(thread, &fiber->context);
    } else {
        return 2;
    }
    (void)blorp_fiber_create(nothing, NULL);
    return 7;
}
